# run-maestro-ios

Boots an available iOS Simulator, waits for `simctl bootstatus -b` before
installing (installing before the simulator finishes booting is a reliable
source of flaky first-run failures), installs the packaged `.app`, runs a
Maestro flow shard, and — regardless of pass/fail — captures a final
screenshot and uploads it plus `MAESTRO_DEBUG_OUTPUT_DIRECTORY` contents as an
artifact. The simulator is always shut down at the end (`if: always()`), so a
failed shard never leaves a booted simulator behind on a persistent
self-hosted runner.

## Inputs

| Name                | Required | Default        | Description                                                |
| -------------------- | -------- | -------------- | ---------------------------------------------------------------- |
| `app-path`           | yes      | —              | Path to a packaged `.app` directory to install.                   |
| `app-id`             | yes      | —              | Bundle identifier passed to Maestro as `APP_ID`.                  |
| `flows-dir`          | yes      | —              | Directory whose top-level files are the runnable Maestro flows. Subdirectories are deliberately not searched; see `flows-name-pattern`. |
| `flows-name-pattern` | no       | `*.flow.yaml`  | `find -name` pattern selecting runnable flows directly inside `flows-dir`. Keeps reusable subflows and capture-only flows in subdirectories out of the shard. |
| `shard-index`        | yes      | —              | Zero-based shard index this job runs.                             |
| `shard-count`        | yes      | —              | Total number of shards flows are distributed across.              |
| `pre-run-flow`       | no       | `''`           | Path to a single priming flow run once before this shard's flows, excluded from sharding. Its failure fails the step immediately. |
| `flow-retries`       | no       | `0`            | Non-negative retry budget per flow; each flow gets up to `1 + flow-retries` attempts. |
| `maestro-version`    | no       | `2.8.0`        | Pinned Maestro CLI version.                                        |
| `artifacts-dir`      | yes      | —              | Directory Maestro debug output and final-state capture is written to. |
| `artifact-name`      | yes      | —              | Uploaded artifact name.                                            |
| `retention-days`     | no       | `7`            | Uploaded artifact retention in days.                               |

A per-flow timing table (flow, duration, status, attempts) is appended to
`$GITHUB_STEP_SUMMARY` after every shard run, including a priming-flow row
when `pre-run-flow` is set.

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/run-maestro-ios@v1
  with:
      app-path: .ci-artifacts/ios-e2e-app-bare/Base.app
      app-id: com.example.app
      flows-dir: apps/mobile/e2e/flows
      shard-index: ${{ matrix.shard-index }}
      shard-count: 2
      artifacts-dir: ${{ github.workspace }}/artifacts/maestro-ios-bare-${{ matrix.shard-index }}
      artifact-name: maestro-ios-bare-shard-${{ matrix.shard-index }}
```
