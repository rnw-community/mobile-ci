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
defaults to `YES`. When a `Package.resolved` is found — at the
working directory root, or inside the project/workspace's
`xcshareddata/swiftpm/` — `-disableAutomaticPackageResolution` is added too, so
a pinned dependency graph is never silently re-resolved mid-run.

## Parallel workers and memory

`-parallel-testing-enabled` makes Xcode **clone the destination simulator**
once per worker, so `parallel-testing-worker-count: 2` costs two simulators'
memory, not one. On a 7 GiB CI VM a stock simulator already runs hundreds of
RuntimeRoot daemons, and two of them will swap rather than go faster.

Lease a *slim* device and the arithmetic changes: `simctl clone` copies the
launchd disable overrides with the device, so every worker clone inherits the
slimming — see [`simulator-lease`](../simulator-lease/README.md)'s
`slim-profile` / `template-device`. Raise `parallel-testing-worker-count` only
on a slimmed lease.

This action does nothing else about slimming: the lease owns the device's
shape, and `destination-id` is all this action needs to know about it.

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
| `parallel-testing`   | no       | `YES`                       | Value for `-parallel-testing-enabled`.                                    |
| `parallel-testing-worker-count` | no | `''`                | `-parallel-testing-worker-count` for the test run. Each worker is a clone of the leased simulator; raise it only on a slimmed lease. |
| `artifact-name`      | no       | `xcresult-<scheme>-<shard-index>` | Name of the uploaded `.xcresult` artifact.                          |
| `retention-days`     | no       | `7`                         | Retention for that artifact.                                              |

## Outputs

| Name                 | Description                                  |
| -------------------- | ---------------------------------------------- |
| `result-bundle-path` | Path of the `.xcresult` bundle.                 |
| `tests-total`        | Total number of tests executed.                 |
| `tests-failed`       | Number of failed tests.                         |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/simulator-lease@v1
  id: simulator
  with:
      device-type: 'iPad Pro 11-inch (M4)'

- uses: rnw-community/mobile-ci/actions/xcodebuild-test@v1
  with:
      project: MyApp.xcodeproj
      scheme: MyApp
      destination-id: ${{ steps.simulator.outputs.udid }}
      xcodebuild-args: ${{ steps.cache.outputs.xcodebuild-args }}

- uses: rnw-community/mobile-ci/actions/simulator-lease@v1
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
            - uses: rnw-community/mobile-ci/actions/xcodebuild-test@v1
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
            - uses: rnw-community/mobile-ci/actions/xcodebuild-test@v1
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
