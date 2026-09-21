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
`-parallel-testing-enabled YES`. When a `Package.resolved` is found — at the
working directory root, or inside the project/workspace's
`xcshareddata/swiftpm/` — `-disableAutomaticPackageResolution` is added too, so
a pinned dependency graph is never silently re-resolved mid-run.

## Sharding

With `shard-count` > 1 the action splits the test identifiers index-modulo
across shards:

- If `only-testing` is set, **that list** is what gets split.
- Otherwise the test targets are discovered from the `.xctestrun` file
  `build-for-testing` produced under `<derivedDataPath>/Build/Products`. This
  needs `-derivedDataPath` in `xcodebuild-args` (which
  [`xcode-cache`](../xcode-cache/README.md) supplies); without it the step
  fails closed rather than guessing.

A shard that selects zero identifiers fails the job — `shard-count` higher
than the number of test identifiers is a configuration error, not a free pass.

## Inputs

| Name                 | Required | Default                     | Description                                                             |
| -------------------- | -------- | --------------------------- | ------------------------------------------------------------------------- |
| `project`            | no       | `''`                        | Path to the `.xcodeproj`. Exactly one of `project`/`workspace`.           |
| `workspace`          | no       | `''`                        | Path to the `.xcworkspace`. Exactly one of `project`/`workspace`.         |
| `scheme`             | yes      | —                           | Scheme to build and test.                                                 |
| `configuration`      | no       | `Debug`                     | Build configuration.                                                      |
| `sdk`                | no       | `iphonesimulator`           | SDK passed to `xcodebuild`.                                               |
| `destination-id`     | yes      | —                           | UDID of a booted simulator, e.g. `simulator-lease`'s `udid`.              |
| `test-plan`          | no       | `''`                        | Test plan name passed as `-testPlan`.                                     |
| `only-testing`       | no       | `''`                        | Newline- or space-separated test identifiers to run (and to shard).       |
| `shard-index`        | no       | `0`                         | Zero-based shard index.                                                   |
| `shard-count`        | no       | `1`                         | Number of shards; `1` disables sharding.                                  |
| `result-bundle-path` | no       | `build/TestResults.xcresult` | `.xcresult` path, relative to `working-directory`.                       |
| `xcodebuild-args`    | no       | `''`                        | Extra arguments, e.g. `xcode-cache`'s `xcodebuild-args`. Word-split.      |
| `working-directory`  | no       | `.`                         | Directory the project/workspace and result bundle resolve against.        |
| `parallel-testing`   | no       | `YES`                       | Value for `-parallel-testing-enabled`.                                    |
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
