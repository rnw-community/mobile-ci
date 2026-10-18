# run-maestro-device-cloud

Runs a Maestro flow selection on hosted devices at
[devicecloud.dev](https://devicecloud.dev) instead of a simulator or emulator
the runner boots itself. The job needs only a Linux runner with Node: no
Xcode, simulator, `/dev/kvm` or `binder_linux`. It is the test leg of
`ios-maestro.yml`'s `ios-driver: device-cloud` and `android-maestro.yml`'s
`android-driver: device-cloud`.

What it does:

1. **Selects the flows the way the local drivers do.** It runs the same
   `find` over `flows-dir` with `flows-max-depth`, `flows-name-pattern` and
   `flows-exclude-pattern`, and writes the exact list into a generated
   workspace config's `flows:`. Device Cloud then runs neither a subflow nor a
   stray top-level YAML that `run-maestro-ios` / `run-maestro-android` would
   skip. A `maestro-config` is copied into that config, so its other settings
   (`executionOrder`, `platform`, `includeTags`, …) still apply. One that sets
   its own top-level `flows:` is refused, because it would change the selection
   on Device Cloud only.
2. **Submits once** with the pinned `@devicecloud.dev/dcd` (`cli-version`)
   and waits. Device Cloud runs the selected flows in parallel itself.
   - The API key reaches the CLI only as `DEVICE_CLOUD_API_KEY`, never on its
     command line.
   - The CLI's telemetry is off, and its config dir is job-scoped, so a
     `dcd login` session left on a self-hosted host is never used instead.
3. **Downloads the run's artifacts** — logs, screenshots and videos for every
   flow, plus the JUnit report when `junit-report` is true. It unpacks them
   into `artifacts-dir` (`device-cloud/`, `junit/report.xml`,
   `device-cloud-result.json`), redacts `redact-env-names`, and uploads the
   result as `artifact-name`. The download and upload run on failure too.
4. **Fails closed.** The step passes only when the CLI exits 0 *and* reports
   `PASSED` for at least one flow. Each other outcome is a red check:

   | Outcome | Reported as | Shows |
   | --- | --- | --- |
   | Failed run (CLI exit 2) | `FAILED` | One `::error` per failed flow, with its device and Device Cloud's fail reason. |
   | Rejected submission (exit 1, e.g. a 401/403 key, a 402 quota, an unsupported device or Maestro version) | `REJECTED` | The CLI's own error message. |
   | Superseded or empty run, or output that is not JSON | `REJECTED` | — |

## Inputs

| Name                    | Required | Default         | Description |
| ----------------------- | -------- | --------------- | ----------- |
| `platform`              | yes      | —               | `ios` or `android`. |
| `app-path`              | yes      | —               | `.apk` on android; an iOS Simulator `.app` directory, or a `.zip`/`.tar.gz` holding exactly one, on ios. |
| `api-key`               | yes      | —               | Device Cloud API key, normally `secrets.device-cloud-api-key`. Empty fails the step. |
| `cli-version`           | no       | `5.7.1`         | Exact `@devicecloud.dev/dcd` npm version; a range is refused. |
| `node-version`          | no       | `22.x`          | Node the CLI runs on (it needs 22+). |
| `flows-dir`             | yes      | —               | Directory containing the Maestro flows. |
| `flows-max-depth`       | no       | `1`             | `find -maxdepth` under `flows-dir`; `0` is unbounded. |
| `flows-name-pattern`    | no       | `*.flow.yaml`   | Space-separated `find -name` globs selecting runnable flows. |
| `flows-exclude-pattern` | no       | `''`            | Comma/newline-separated `find ! -name` globs. |
| `include-tags`          | no       | `''`            | Comma-separated tags, `--include-tags`. A selection left with no flow fails. |
| `exclude-tags`          | no       | `''`            | Comma-separated tags, `--exclude-tags`. Exclusion wins. |
| `maestro-config`        | no       | `''`            | Workspace config sent with the run; may not set a top-level `flows:`. |
| `maestro-env`           | no       | `''`            | Newline-separated `KEY=VALUE`, each passed as `-e`. Fails closed on a malformed line. |
| `maestro-version`       | no       | `''`            | `--maestro-version`; empty uses Device Cloud's default. |
| `retries`               | no       | `0`             | `--retry`: times Device Cloud retries a failed flow. |
| `android-api-level`     | no       | `''`            | [android] `--android-api-level`. |
| `android-device`        | no       | `''`            | [android] `--android-device`, e.g. `pixel-7`. |
| `ios-device`            | no       | `''`            | [ios] `--ios-device`, e.g. `iphone-16`. |
| `ios-version`           | no       | `''`            | [ios] `--ios-version`, e.g. `18`. |
| `junit-report`          | no       | `'true'`        | Download the run's JUnit report to `junit/report.xml`. |
| `run-name`              | no       | `''`            | Name the run carries in the Device Cloud console. |
| `artifacts-dir`         | yes      | —               | Where the run's artifacts are unpacked. |
| `artifact-name`         | yes      | —               | Uploaded artifact name. |
| `retention-days`        | no       | `7`             | Uploaded artifact retention in days. |
| `redact-env-names`      | no       | `''`            | Names of job env variables whose values are replaced with `***` in every text artifact before upload (as in `run-maestro-ios`). |

## Outputs

| Name          | Description |
| ------------- | ----------- |
| `result`      | `PASSED`, `FAILED`, or `REJECTED` when Device Cloud never ran the flows. |
| `upload-id`   | Device Cloud upload id, when a run was created. |
| `console-url` | Device Cloud console URL of the run. |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/run-maestro-device-cloud@v4.0.0 # v4.0.0
  with:
      platform: android
      app-path: .ci-artifacts/app-release.apk
      api-key: ${{ secrets.DEVICE_CLOUD_API_KEY }}
      flows-dir: apps/mobile/e2e/flows
      android-api-level: '34'
      artifacts-dir: ${{ github.workspace }}/artifacts/maestro-android
      artifact-name: maestro-android-shard-0
```
