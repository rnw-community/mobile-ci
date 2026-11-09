# e2e-suite

The e2e job of `ios-maestro.yml` and `android-maestro.yml`: one implementation of
a tester-army e2e suite run against devices leased from a simlock farm, for both
platforms. The calling job checks out, sets up Node and downloads the app; this
action does the rest in three modes.

- **`validate`** (the workflows' `detect` job) does nothing for
  `test-framework: maestro`. Otherwise it fails closed, naming every problem at
  once, on any of these:
  - a missing `e2e-dir`, `simlock-url` or `simlock-token`;
  - a non-numeric `workers` or `retries`, or fewer than 1 worker;
  - an app built without the farm's ABI (`arm64` on iOS, `arm64-v8a` on
    Android);
  - `test-framework: e2e` with a Maestro-only driver.
- **`run`** installs the e2e project (`install-command`) and
  [`@mobile-ci/e2e-simlock`](../e2e-simlock-install/README.md), then runs
  `command` with the suite's environment.
  - It lowers `workers` to the farm's free devices of the platform (`GET
    /v1/status`, `capacity.<platform>`), split across `targets`. Fewer free
    devices than half of what an idle farm would give the run (its `limit`
    split across `targets`, up to `workers`) would not finish within the job
    limit, so the run polls every 30 seconds for up to `capacity-wait-minutes`
    and then fails with an `Infrastructure failure:` error without starting the
    suite.
  - A run passes only on its `.e2e/report.json`: `status: passed`, at least one
    executed test, none failed, every count a whole number. It clears `.e2e`
    first, so a stale report never counts.
  - A run that tested nothing, or that hit an infrastructure error, fails with an
    `Infrastructure failure:` error quoting the `ERROR` the run printed, which
    [`rerun-infra-failures`](../rerun-infra-failures/README.md) retries once: no
    valid report, none executed, a run error in the report, or a report with
    `status: error` or `interrupted`. Configuration errors exit this way too, so
    they get that one retry.
  - `tolerated` passes the step with a warning only when tests ran and failed. Every
    other failure, including the ones above, still fails.
  - `shadow` turns every failure into warnings; the caller's `continue-on-error`
    keeps it from gating.
- **`release`** (`if: always()`) releases every lease listed in
  `.e2e/simlock-leases.json`, so a cancelled run frees the farm at once. A lease
  that is already gone, or that fails to release, warns and never fails the job.

The suite's environment: `E2E_PLATFORM`, `E2E_APP_PATH`, `E2E_APP_ID`,
`E2E_TARGET`, `E2E_WORKERS`, `E2E_RETRIES`, `E2E_SESSION`, `SIMLOCK_URL`,
`SIMLOCK_TOKEN` and `E2E_TELEMETRY_DISABLED=1`. The token goes to `curl` on
stdin, never on its command line.

## Inputs

| Name | Modes | Default | Description |
| --- | --- | --- | --- |
| `mode` | all | — (required) | `validate`, `run` or `release`; anything else fails. |
| `platform` | all | — (required) | `ios` or `android`. |
| `test-framework` | validate | `e2e` | The caller's `test-framework`: `maestro`, `e2e` or `both`. |
| `driver` | validate | `''` | The caller's `ios-driver` or `android-driver`. |
| `abis` | validate | `''` | Comma-separated ABIs the app is built for (`ios-simulator-archs`, or the resolved `android-abis`); empty for every ABI the project declares. |
| `e2e-dir` | all | `''` | The e2e project's directory. |
| `install-command` | run | `npm ci --no-audit --no-fund` | Installs the e2e project, in `e2e-dir`. |
| `command` | run | `''` | Runs the suite, in `e2e-dir`; writes its report under `.e2e`. |
| `app-path` | run | `''` | Absolute path of the `.app` (iOS) or `.apk` (Android). |
| `app-id` | run | `''` | The app's bundle id or package (`E2E_APP_ID`). |
| `target` | run | `''` | The target's name (`E2E_TARGET`). |
| `targets` | run | `'[]'` | JSON array of the call's targets, which split the free devices. |
| `workers` | validate, run | `'1'` | Devices leased and tests run at once (`E2E_WORKERS`). |
| `capacity-wait-minutes` | run | `'10'` | How long a run waits for a busy farm to free half the devices an idle farm would give it, before failing as infrastructure. |
| `retries` | validate, run | `'1'` | Retries per failed test (`E2E_RETRIES`). |
| `session` | run | `''` | agent-device session name (`E2E_SESSION`). |
| `shadow` | run | `'false'` | `true` when the suite runs as a non-gating shadow. |
| `tolerated` | run | `'false'` | `true` when the target tolerates test failures. |
| `simlock-url` | all | `''` | The simlock gateway or worker. |
| `simlock-token` | all | `''` | The simlock agent token. |

## Example

```yaml
- name: Run the e2e suite
  id: run
  uses: rnw-community/mobile-ci/actions/e2e-suite@v4.12.0 # v4.12.0
  with:
      mode: run
      platform: android
      e2e-dir: e2e
      command: npx e2e run --target android
      app-path: ${{ github.workspace }}/app-release.apk
      app-id: com.example.app
      target: app
      session: e2e-${{ github.run_id }}-${{ github.run_attempt }}
      simlock-url: https://simlock.vitaliiyehorov.dev
      simlock-token: ${{ secrets.SIMLOCK_TOKEN }}
- name: Release the devices the suite left leased
  if: ${{ always() && steps.run.outcome != 'skipped' }}
  uses: rnw-community/mobile-ci/actions/e2e-suite@v4.12.0 # v4.12.0
  with:
      mode: release
      platform: android
      e2e-dir: e2e
      simlock-url: https://simlock.vitaliiyehorov.dev
      simlock-token: ${{ secrets.SIMLOCK_TOKEN }}
```
