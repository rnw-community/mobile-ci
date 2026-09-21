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

## Slim leases

A **stock** simulator is expensive. Measured inside pony-labirinth's live
UI-test VM (`maestro` profile, 7 GiB), the stock lease was running **272
RuntimeRoot processes** — Calendar, News and Maps widgets, a Safari extension,
Spotlight — with roughly **2 GB sitting in the compressor and about 14 MB of
free pages**. The UI-test step was not CPU-bound; it was memory-starved.

[simslim](https://github.com/MobAI-App/simslim) fixes that by writing
persistent `launchctl disable` overrides into one simulator's launchd database.
Point `slim-profile` at a committed profile
(`{"name": "ci", "except": [], "keep": []}`) and the booted lease is verified
against it, repaired if it drifts, and measured into the job summary.

Two ways to get a slim lease, in preference order:

1. **`template-device`** — clone a prewarmed, already-slimmed, **shut-down**
   device that the host image ships. `xcrun simctl clone` copies the launchd
   overrides with the device, so the lease is slim from its first boot and
   pays **no** repair reboot. The template's own `deviceTypeIdentifier` and
   runtime are checked against the requested `device-type`/`runtime` before the
   clone, so a stale template can never quietly run the tests on a different
   device or OS than the lease claims. Set `slim-repair: false` alongside it so a
   template that is *not* slim surfaces as an error rather than being silently
   repaired on every run. The action fails closed if the named template is
   booted — a template is provisioning state, never a job's device.
2. **`slim-profile` alone** — the action creates a stock device and applies the
   profile in-job with `simslim on`, which reboots it. That is why
   `slim-repair` defaults to `true` here and to `false` in `run-maestro-ios`:
   this action *creates* the device it leases, so "stock" is expected rather
   than a provisioning defect.

`simslim` itself is resolved exactly as `run-maestro-ios` resolves it: an
existing binary on PATH whose `simslim version` matches `simslim-version` is
reused; otherwise the pinned release asset is downloaded, verified against
`simslim-sha256`, and extracted into a job-private directory.

## Inputs

| Name                   | Required | Default             | Description                                                                 |
| ---------------------- | -------- | ------------------- | ----------------------------------------------------------------------------- |
| `mode`                 | no       | `acquire`           | `acquire` or `release`.                                                        |
| `device-type`          | no       | `''`                | Exact device type name, e.g. `iPad Pro 11-inch (M4)`. Required for `acquire`.  |
| `runtime`              | no       | `latest`            | `latest`, or an exact runtime identifier.                                      |
| `name-prefix`          | no       | `mobile-ci-lease`   | Device-name prefix; run id, attempt and a random suffix are appended.          |
| `lease-file`           | no       | `''`                | Lease file path. Defaults to `$RUNNER_TEMP/simulator-lease-<udid>.json`.       |
| `boot-timeout-seconds` | no       | `300`               | Bound on `xcrun simctl bootstatus -b`.                                         |
| `template-device`      | no       | `''`                | Exact name of a shut-down device to `simctl clone` instead of creating one.    |
| `slim-profile`         | no       | `''`                | Repo-relative simslim JSON profile. Empty leases a stock device.               |
| `slim-repair`          | no       | `true`              | Apply the profile in-job (a reboot) when the lease does not match it.          |
| `simslim-version`      | no       | `0.8.0`             | Pinned simslim CLI version.                                                    |
| `simslim-sha256`       | no       | `c7d33ba0…d9b19`    | Digest of that version's `macos-arm64` release asset.                          |

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
| `slimmed`    | `true` when the lease was verified against `slim-profile`. |
| `footprint`  | What `simslim measure` reported for the lease.  |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/simulator-lease@v1
  id: simulator
  with:
      device-type: 'iPad Pro 11-inch (M4)'
      runtime: latest
      slim-profile: e2e/simslim.ci.json

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
