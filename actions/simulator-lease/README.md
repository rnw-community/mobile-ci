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
`slim-profile` defaults to `bundled`, this release's own
[`profiles/ci.json`](../../profiles/ci.json) — the `store` (App Store, push,
StoreKit) and `web` (Safari sync, universal links) categories stay on, every
other category is disabled — so a consumer commits no profile of its own. Point
it at a repository-relative path to use a different one, or set it to `''` to
lease a stock device. Either way the booted lease is verified against the
profile and measured into the job summary. The same
profile is what [`scripts/slim-simulator.sh`](../../scripts/slim-simulator.sh)
applies on a developer's Mac, so a local run reproduces the CI simulator.

**One boot, already slim.** simslim keeps a device's disable overrides on the
host, in a store keyed by the device's UDID that `launchd_sim` reads when the
device starts ([simslim `disabled_store.go`](https://github.com/MobAI-App/simslim/blob/main/disabled_store.go)).
So with `slim-profile` set and `slim-repair: true` (both defaults), `acquire`
creates the device and leaves it **shut down**, and the slim step runs
`simslim on --profile` against it: simslim writes the overrides offline and
boots the device once, reading the result back from the booted device (and
falling back to the live `launchctl` path if a runtime ignores the store).
The lease is then waited for with `bootstatus -b`, verified, and measured. That
replaces the previous boot → verify → `simslim on` (spawn per label, then
reboot) sequence, which cost about a minute per lease.

**Templates do not carry slimming.** Because the store is keyed by UDID,
`xcrun simctl clone` of a slimmed device produces a **stock** clone
(rnw-community/mobile-ci#161). `template-device` is still honoured for a device
that carries something else, and its clone is slimmed before first boot like a
created one; `template-strategy: auto` is deprecated and leases exactly like
`none`, since cloning or baking a template bought nothing. Devices named
`mobile-ci-template-*` are still never deleted by `mode: release`.

**XCUITest lanes.** A controlled A/B in #161 measured a slim lease ~1.23×
slower than a stock one on an XCUITest subset (simslim 0.10.0). simslim 0.12.0
keeps `gamed` enabled because disabling it added a ~10 s delay to every
XCUITest app launch, which plausibly accounts for much of that; re-measure
before choosing `slim-profile: ''` for an XCUITest lane, and keep `bundled` for
Maestro lanes, where slimming was measured as a win.

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
| `lease-file`           | no       | `''`                | Lease file path. Defaults to `$RUNNER_TEMP/simulator-lease-<udid>.json`, which is unique per device. An explicit path is written with `noclobber`, so a second job cannot overwrite the first job's lease and make one `release` delete the other's device. |
| `boot-timeout-seconds` | no       | `300`               | Bound on `xcrun simctl bootstatus -b`, and on each `simslim on` slim-and-boot. |
| `template-device`      | no       | `''`                | Exact name of a shut-down device to `simctl clone` instead of creating one. The clone does not inherit slimming; with `slim-profile` it is slimmed before first boot like a created device. |
| `template-strategy`    | no       | `none`              | Deprecated: `auto` now leases exactly like `none` and prints a notice. |
| `slim-profile`         | no       | `bundled`           | `bundled` uses this release's [`profiles/ci.json`](../../profiles/ci.json); a repo-relative path uses that profile instead; `''` leases a stock device. |
| `slim-repair`          | no       | `true`              | Slim the shut-down lease with `simslim on` (offline overrides, one boot) before verifying it. `false` boots the lease as it is and only verifies, which fails for any device this action leases. |
| `simslim-version`      | no       | `0.12.2`             | Pinned simslim CLI version.                                                    |
| `simslim-sha256`       | no       | `b47302da…70887`    | Digest of that version's `macos-arm64` release asset.                          |

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
| `template`   | Name of the template the lease was cloned from, empty when the device was created fresh. |
| `slimmed`    | `true` when the lease was verified against `slim-profile`. |
| `footprint`  | What `simslim measure` reported for the lease.  |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/simulator-lease@v4.5.0 # v4.5.0
  id: simulator
  with:
      device-type: 'iPad Pro 11-inch (M4)'
      runtime: latest

- name: Test
  run: |
      xcodebuild test -project MyApp.xcodeproj -scheme MyApp \
        -destination "platform=iOS Simulator,id=${{ steps.simulator.outputs.udid }}"

- uses: rnw-community/mobile-ci/actions/simulator-lease@v4.5.0 # v4.5.0
  if: always()
  with:
      mode: release
      lease-file: ${{ steps.simulator.outputs.lease-file }}
```
