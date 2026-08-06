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

| Name                | Required | Default | Description                                                |
| -------------------- | -------- | ------- | ---------------------------------------------------------------- |
| `app-path`           | yes      | —       | Path to a packaged `.app` directory to install.                   |
| `app-id`             | yes      | —       | Bundle identifier passed to Maestro as `APP_ID`.                  |
| `flows-dir`          | yes      | —       | Directory containing Maestro flow `.yaml`/`.yml` files.           |
| `flows-max-depth`    | no       | `1`     | `find -maxdepth` under `flows-dir`. `0` means unbounded recursion. Default keeps subflows (invoked via `runFlow`, conventionally in subdirectories) out of the shard. |
| `flows-name-pattern` | no       | `*.yaml`| `find -name` glob selecting runnable flows.                        |
| `flows-exclude-pattern` | no    | —       | Optional `find ! -name` glob excluding matched flows by basename.  |
| `shard-manifest-dir` | no       | —       | Directory of hand-curated `shard-<index>.txt` files (one `flows-dir`-relative path per line) overriding the index-modulo split. Unset falls back to modulo entirely; once set, every shard-index this job can run must have its own file — a partial manifest fails closed. |
| `shard-index`        | yes      | —       | Zero-based shard index this job runs.                             |
| `shard-count`        | yes      | —       | Total number of shards flows are distributed across.              |
| `maestro-version`    | no       | `2.8.0` | Pinned Maestro CLI version.                                        |
| `artifacts-dir`      | yes      | —       | Directory Maestro debug output and final-state capture is written to. |
| `artifact-name`      | yes      | —       | Uploaded artifact name.                                            |
| `retention-days`     | no       | `7`     | Uploaded artifact retention in days.                               |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/run-maestro-ios@v1
  with:
      app-path: .ci-artifacts/ios-e2e-app-bare/Base.app
      app-id: org.reactjs.native.example.ReactNativePaymentsExample
      flows-dir: packages/react-native-payments-example/e2e/flows
      shard-index: ${{ matrix.shard-index }}
      shard-count: 2
      artifacts-dir: ${{ github.workspace }}/artifacts/maestro-ios-bare-${{ matrix.shard-index }}
      artifact-name: maestro-ios-bare-shard-${{ matrix.shard-index }}
```
