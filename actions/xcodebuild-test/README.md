# xcodebuild-test

Compiles a scheme's tests **once** with `xcodebuild build-for-testing`, then
runs them with `test-without-building` against a simulator that is already
booted (lease one with [`simulator-lease`](../simulator-lease/README.md)). The
run writes an `.xcresult` bundle, uploads it as an artifact, and publishes a
pass/fail table to the job summary.

**Zero executed tests fails the job.** A `test` invocation that matched nothing
— a renamed target, a shard that selected no identifiers, a test plan that
skipped everything — otherwise exits 0 and ships a green no-op. So does a
missing or unreadable result bundle: no evidence is never a pass.

Every run adds `-skipMacroValidation -skipPackagePluginValidation` (a CI
checkout can never answer Xcode's interactive macro/plugin trust prompt) and
`-parallel-testing-enabled` with the caller's `parallel-testing` value, which
defaults to `NO`. When a `Package.resolved` is found — at the
working directory root, or inside the project/workspace's
`xcshareddata/swiftpm/` — `-disableAutomaticPackageResolution` is added too, so
a pinned dependency graph is never silently re-resolved mid-run.

## Parallel testing boots a clone, so it is off by default

`-parallel-testing-enabled YES` makes Xcode **clone the destination simulator**
and run the tests on `Clone 1 of <destination>` — even with a single worker.
The job then pays for two simulators: the leased one it booted, slimmed and
verified, and a clone that boots stock unless `slim-workers` slims it (see
[Slimming the worker clones](#slimming-the-worker-clones)).

Measured on a 4 CPU / 7 GiB VM
([#155](https://github.com/rnw-community/mobile-ci/issues/155)): with the clone,
two shards took ~30 minutes each and produced **4 timeout failures**; without
it, the same 71 XCUITests finished in **20m18s** on one simulator. The VM was
memory-bound before the clone existed, which is the same finding
[#147](https://github.com/rnw-community/mobile-ci/issues/147) measured for the
UI-test video encoder.

So `parallel-testing` defaults to **`NO`**: the leased device *is* the
isolation, and on one worker the clone buys nothing. Asking for `'YES'` with an
empty `parallel-testing-worker-count` **fails the step** rather than silently
booting a clone — `'YES'` only makes sense when the caller states how many
workers it is buying, and only on a runner profile with the memory for them
(the 6x12 builder profile, not the 4x7 test profile).

```yaml
with:
    parallel-testing: 'YES'
    parallel-testing-worker-count: '2' # required; each worker is one more simulator
```

## Slimming the worker clones

Xcode creates one clone of the destination per worker, in its own `testing`
device set (`~/Library/Developer/XCTestDevices`), and deletes them when the run
ends. A clone never inherits the lease's slimming — simslim keeps disable
overrides on the host keyed by UDID, and a clone gets a new UDID
([#161](https://github.com/rnw-community/mobile-ci/issues/161)) — so without
help every worker boots **stock**: ~272 processes and ~2 GB of compressor per
clone in a 7 GiB guest, multiplying the footprint the lease just removed.

Pass the lease's `slim-profile` and this action runs
[`simslim watch`](https://github.com/MobAI-App/simslim#slimming-parallel-testing-clones)
for exactly the length of `test-without-building`:

```yaml
with:
    parallel-testing: 'YES'
    parallel-testing-worker-count: '2'
    slim-profile: bundled # the lease's own profile
```

- `simslim watch --profile <slim-profile>` is started detached before the
  test run, its PID recorded under `RUNNER_TEMP`. Every 3 s it scans the
  `default` and `testing` device sets and slims each newly booted simulator
  **no-reboot**, so a worker is slim a few seconds into its life and stays slim
  for the rest of the run.
- An `if: always()` step stops it with `SIGINT` (simslim's clean stop) after
  the run, prints its log, and adds to the job summary how many worker clones
  it slimmed (the lease itself, already slim, is re-checked and not counted).
- `simslim` is installed with the same pinned version and SHA-256 as
  `simulator-lease` (`simslim-version` / `simslim-sha256`), or reused from
  `PATH` at that exact version.
- The watch slims *every* simulator that boots in those device sets for this
  macOS user, not only this run's clones. On the fleet a guest runs one job,
  so that is only the lease and its clones; on a host that runs several jobs as
  one user, other jobs' simulators get this profile too. Use the lease's own
  profile, since the watch re-applies it to the lease.

`slim-workers` decides what happens when the watch cannot do its job:

| `slim-workers` | Watch runs when | Watch fails to start, dies mid-run, or slims no clone in a green run |
| -------------- | --------------- | --------------------------------------------------------------------- |
| `auto` (default) | `parallel-testing: YES` and `slim-profile` set | `::warning::`; the tests still run and still decide the job. |
| `true`         | always; refused (fails) without `YES` and a profile | the job fails. |
| `false`        | never           | — |

The asymmetry is deliberate: slimming is a **capacity** optimisation, not a
correctness property. A stock worker runs the same tests with the same result,
only with more memory, so under `auto` a broken watch must not turn a correct
test run red. A caller that sized its runner profile on the assumption of slim
workers sets `true` and gets a fail-closed guarantee instead. A configuration
error — an unknown `slim-workers` value, or a `slim-profile` that does not exist
— fails in every mode, and so does a `simslim` download that does not match its
digest.

## Screen capture: screenshots, not video

Xcode 26 records a **video** of every UI test. That is one
`VTEncoderXPCService` process, and on a 4 CPU / 7 GiB CI guest it was measured
at **~1 GB RSS and a full core** — the single largest consumer in a run whose
free memory never left ~50 MB
([#147](https://github.com/rnw-community/mobile-ci/issues/147)). The video is
also thrown away on success (`deleteOnSuccess`), so a green run pays a
gigabyte and a core for a file nobody ever opens.

`screen-capture` therefore defaults to **`screenshots`**. Failure evidence is
unchanged — screenshots are still attached to the `.xcresult` this action
uploads. Set `screen-capture: screenRecording` to get Xcode's video back on a
host with memory to spare.

It is applied by rewriting every `PreferredScreenCaptureFormat` in the
generated `.xctestrun`, which is also the file `shard-count > 1` reads to
enumerate tests. Finding it needs `-derivedDataPath` in `xcodebuild-args`
(`xcode-cache` supplies it). Without one, sharding fails as it always did and
the capture format is left at the scheme's own setting with a warning — this
action never silently claims to have changed a setting it could not reach.

## Modes, and sharding across jobs

`mode` decides which halves run:

| `mode`           | Runs                                                              |
| ---------------- | ------------------------------------------------------------------- |
| `build-and-test` | `build-for-testing` then `test-without-building` (default).          |
| `build`          | `build-for-testing` only. `destination-id` may be empty, in which case it targets `generic/platform=iOS Simulator`. |
| `test`           | `test-without-building` only, against products already on disk.      |

Splitting them is how N shards share **one** compile: a build job runs
`mode: build` and saves DerivedData with
[`xcode-cache`](../xcode-cache/README.md); every shard job restores that same
cache key and runs `mode: test`. Because the cache key is
`toolchain + project fingerprint`, the shards hit the entry the build job just
wrote without any extra plumbing.

The restored `-derivedDataPath` is an **absolute** path, so the build job and
its shard jobs must share a workspace path — true across a homogeneous
self-hosted pool, and the reason this composition targets one runner label
rather than a mixed set.

## Sharding

With `shard-count` > 1 the action splits the test identifiers index-modulo
across shards:

- If `only-testing` is set, **that list** is what gets split.
- Otherwise the **individual tests** are enumerated with
  `xcodebuild test-without-building -enumerate-tests` against the `.xctestrun`
  `build-for-testing` produced under `<derivedDataPath>/Build/Products`. This
  needs `-derivedDataPath` in `xcodebuild-args` (which
  [`xcode-cache`](../xcode-cache/README.md) supplies); without it the step
  fails closed rather than guessing.
- If enumeration fails, the step warns and falls back to the whole test targets
  declared by the `.xctestrun`.

Enumerating tests rather than targets is what makes sharding useful for the
common shape of a UI-test suite: one target, one class, dozens of methods.
Target-level sharding would give one identifier and fail.

A shard that selects zero identifiers fails the job — `shard-count` higher
than the number of test identifiers is a configuration error, not a free pass.

## Inputs

| Name                 | Required | Default                     | Description                                                             |
| -------------------- | -------- | --------------------------- | ------------------------------------------------------------------------- |
| `mode`               | no       | `build-and-test`            | `build`, `test`, or `build-and-test`.                                     |
| `project`            | no       | `''`                        | Path to the `.xcodeproj`. Exactly one of `project`/`workspace`.           |
| `workspace`          | no       | `''`                        | Path to the `.xcworkspace`. Exactly one of `project`/`workspace`.         |
| `scheme`             | yes      | —                           | Scheme to build and test.                                                 |
| `configuration`      | no       | `Debug`                     | Build configuration.                                                      |
| `sdk`                | no       | `iphonesimulator`           | SDK passed to `xcodebuild`.                                               |
| `destination-id`     | no       | `''`                        | UDID of a booted simulator, e.g. `simulator-lease`'s `udid`. Required unless `mode` is `build`. |
| `test-plan`          | no       | `''`                        | Test plan name passed as `-testPlan`.                                     |
| `only-testing`       | no       | `''`                        | Newline- or space-separated test identifiers to run (and to shard).       |
| `shard-index`        | no       | `0`                         | Zero-based shard index.                                                   |
| `shard-count`        | no       | `1`                         | Number of shards; `1` disables sharding.                                  |
| `result-bundle-path` | no       | `build/TestResults.xcresult` | `.xcresult` path, relative to `working-directory`.                       |
| `xcodebuild-args`    | no       | `''`                        | Extra arguments, e.g. `xcode-cache`'s `xcodebuild-args`. Word-split.      |
| `working-directory`  | no       | `.`                         | Directory the project/workspace and result bundle resolve against.        |
| `parallel-testing`   | no       | `NO`                        | Value for `-parallel-testing-enabled`. `YES` boots `Clone 1 of <destination>` and is refused without an explicit `parallel-testing-worker-count`. |
| `parallel-testing-worker-count` | no | `''`                | `-parallel-testing-worker-count` for the test run. Each worker is a clone of the leased simulator, stock unless `slim-workers` slims it; raise it only on a 6x12 profile. Required when `parallel-testing` is `YES`. |
| `slim-workers`       | no       | `auto`                      | `auto`, `true` or `false`: run `simslim watch` during the test run so every worker clone is slimmed as it boots. `auto` watches when `parallel-testing` is `YES` and `slim-profile` is set, and only warns on a watch failure; `true` fails the job instead. See [Slimming the worker clones](#slimming-the-worker-clones). |
| `slim-profile`       | no       | `''`                        | simslim profile for the worker clones; pass the lease's own. `bundled` is this release's `profiles/ci.json`, anything else a repository-relative path. Empty leaves the workers stock. |
| `simslim-version`    | no       | `0.12.2`                    | Pinned simslim version, installed only when the watch runs; an exact match already on `PATH` is reused. Same as `simulator-lease`. |
| `simslim-sha256`     | no       | `b47302da…70887`            | SHA-256 of the `simslim-v<version>-macos-arm64.tar.gz` asset; empty refuses to download. Bump with `simslim-version`. |
| `screen-capture`     | no       | `screenshots`               | `screenshots` or `screenRecording`, written into the `.xctestrun`. Video costs ~1 GB and a core on a 7 GiB guest. |
| `artifact-name`      | no       | `xcresult-<scheme>-<shard-index>` | Name of the uploaded `.xcresult` artifact.                          |
| `retention-days`     | no       | `7`                         | Retention for that artifact.                                              |

## Outputs

| Name                 | Description                                  |
| -------------------- | ---------------------------------------------- |
| `result-bundle-path` | Path of the `.xcresult` bundle.                 |
| `tests-total`        | Total number of tests executed.                 |
| `tests-failed`       | Number of failed tests.                         |
| `slimmed-workers`    | Worker clones `simslim watch` slimmed; empty when no watch ran. |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/simulator-lease@v4.5.0 # v4.5.0
  id: simulator
  with:
      device-type: 'iPad Pro 11-inch (M4)'

- uses: rnw-community/mobile-ci/actions/xcodebuild-test@v4.5.0 # v4.5.0
  with:
      project: MyApp.xcodeproj
      scheme: MyApp
      destination-id: ${{ steps.simulator.outputs.udid }}
      xcodebuild-args: ${{ steps.cache.outputs.xcodebuild-args }}

- uses: rnw-community/mobile-ci/actions/simulator-lease@v4.5.0 # v4.5.0
  if: always()
  with:
      mode: release
      lease-file: ${{ steps.simulator.outputs.lease-file }}
```

### Two shards sharing one compile

```yaml
jobs:
    build:
        runs-on: [self-hosted, trf-macos-arm64-4x7]
        steps:
            # ... setup-xcode-pinned, xcode-cache restore ...
            - uses: rnw-community/mobile-ci/actions/xcodebuild-test@v4.5.0 # v4.5.0
              with:
                  project: MyApp.xcodeproj
                  scheme: MyApp
                  mode: build
                  xcodebuild-args: ${{ steps.cache.outputs.xcodebuild-args }}
            # ... xcode-cache save ...

    test:
        needs: build
        runs-on: [self-hosted, trf-macos-arm64-4x7]
        strategy:
            fail-fast: false
            matrix:
                shard: [0, 1]
        steps:
            # ... setup-xcode-pinned, xcode-cache restore, simulator-lease ...
            - uses: rnw-community/mobile-ci/actions/xcodebuild-test@v4.5.0 # v4.5.0
              with:
                  project: MyApp.xcodeproj
                  scheme: MyApp
                  mode: test
                  destination-id: ${{ steps.simulator.outputs.udid }}
                  shard-index: ${{ matrix.shard }}
                  shard-count: 2
                  result-bundle-path: build/TestResults-${{ matrix.shard }}.xcresult
                  xcodebuild-args: ${{ steps.cache.outputs.xcodebuild-args }}
```
