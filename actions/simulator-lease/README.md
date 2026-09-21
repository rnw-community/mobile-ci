# simulator-lease

Leases an **isolated** iOS Simulator for the duration of one job: it creates a
brand-new, run-scoped device of the requested device type and runtime, boots
it, and waits for `xcrun simctl bootstatus <udid> -b` under a bounded timeout.
Nothing is shared with another job, so two concurrent runs on the same
self-hosted host never fight over one device, and `xcodebuild test` never pays
for a cold boot inside its own timeout.

Composite actions cannot declare a `post:` step — that is a
JavaScript-action-only feature — so the teardown is a paired call with
`mode: release`, guarded by `if: always()`. The `acquire` call writes a JSON
lease file (`udid`, `name`, `deviceType`, `runtime`, `createdAt`); `release`
reads it back, shuts the device down and deletes it. Leaving `lease-file`
unset on `release` sweeps every `simulator-lease-*.json` under `RUNNER_TEMP`,
so a job that acquired more than one device still cleans up all of them.

`release` succeeds with a warning when there is no lease file at all (the
`acquire` call never got far enough to create a device), and fails when a
device it *did* record cannot be deleted — a leaked simulator is a fleet
problem, not something to swallow.

## Inputs

| Name                   | Required | Default             | Description                                                                 |
| ---------------------- | -------- | ------------------- | ----------------------------------------------------------------------------- |
| `mode`                 | no       | `acquire`           | `acquire` or `release`.                                                        |
| `device-type`          | no       | `''`                | Exact device type name, e.g. `iPad Pro 11-inch (M4)`. Required for `acquire`.  |
| `runtime`              | no       | `latest`            | `latest`, or an exact runtime identifier.                                      |
| `name-prefix`          | no       | `mobile-ci-lease`   | Device-name prefix; run id, attempt and a random suffix are appended.          |
| `lease-file`           | no       | `''`                | Lease file path. Defaults to `$RUNNER_TEMP/simulator-lease-<udid>.json`.       |
| `boot-timeout-seconds` | no       | `300`               | Bound on `xcrun simctl bootstatus -b`.                                         |

`device-type` and `runtime` are matched exactly against
`xcrun simctl list devicetypes -j` / `list runtimes -j`; no fuzzy matching and
no "last available device" heuristic. A miss prints the installed set and
fails the job, so a runner image that lost a device type is visible
immediately instead of silently testing on something else.

## Outputs

| Name         | Description                                  |
| ------------ | ---------------------------------------------- |
| `udid`       | UDID of the leased simulator.                   |
| `name`       | Name of the created device.                     |
| `lease-file` | Path of the JSON lease file.                    |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/simulator-lease@v1
  id: simulator
  with:
      device-type: 'iPad Pro 11-inch (M4)'
      runtime: latest

- name: Test
  run: |
      xcodebuild test -project MyApp.xcodeproj -scheme MyApp \
        -destination "platform=iOS Simulator,id=${{ steps.simulator.outputs.udid }}"

- uses: rnw-community/mobile-ci/actions/simulator-lease@v1
  if: always()
  with:
      mode: release
      lease-file: ${{ steps.simulator.outputs.lease-file }}
```
