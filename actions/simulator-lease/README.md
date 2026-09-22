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
profile, repaired if it drifts, and measured into the job summary. The same
profile is what [`scripts/slim-simulator.sh`](../../scripts/slim-simulator.sh)
applies on a developer's Mac, so a local run reproduces the CI simulator.

Three ways to get a slim lease, in preference order:

1. **`template-device`** — clone a prewarmed, already-slimmed, **shut-down**
   device that the host image ships. `xcrun simctl clone` copies the launchd
   overrides with the device, so the lease is slim from its first boot and
   pays **no** repair reboot. The template is selected by **name, device type,
   runtime and `Shutdown` state together** — not by name alone — so a host with
   several devices of that name cannot hand the job an old runtime or a booted
   one, and a stale template can never quietly run the tests on a different
   device or OS than the lease claims. When nothing matches, every device with
   that name is printed with its runtime, type and state. Set `slim-repair: false` alongside it so a
   template that is *not* slim surfaces as an error rather than being silently
   repaired on every run. The action fails closed if the named template is
   booted — a template is provisioning state, never a job's device.
2. **`template-strategy: auto`** — the same clone, without the consumer
   knowing anything about the host image. The action looks for a shut-down,
   available device on this host whose name starts with `mobile-ci-template-`
   and whose **device type and runtime both match this lease**, and clones it.
   The template is trusted by prefix, device type and runtime; what gets
   verified is the **booted clone**, because
   [`simslim verify` compares a booted simulator](https://github.com/MobAI-App/simslim)
   and reports a mismatch for any shut-down device — verifying the template
   itself meant no template was ever cloned and every lease paid
   create + boot + slim. When no such template exists, the lease is created and
   slimmed as usual and a shut-down copy named
   **`mobile-ci-template-<device-type-slug>-<runtime-slug>`** is left behind
   for the next lease on that host — so the create-boot-slim cycle is paid once
   per host instead of once per job. The slug is the name lowercased with every
   run of non-alphanumeric characters replaced by `-`, so
   `iPad Pro 11-inch (M4)` on `com.apple.CoreSimulator.SimRuntime.iOS-26-0`
   gives `mobile-ci-template-ipad-pro-11-inch-m4-ios-26-0`.

   The rules the action holds to:

   - **Never more than one template per device type + runtime.** A clone whose
     booted `simslim verify` fails is repaired in-job with `simslim on` and the
     stale template is reported as a `::warning::` naming it — never deleted
     and never replaced behind the image's back; the host image is the place to
     fix it.
   - **A template is never a job's device.** `mode: release` refuses to delete
     any device named `mobile-ci-template-*`, and a booted template is refused:
     it is neither cloned nor replaced, because something else is using it.
   - **`slim-profile` is required**, because a clone nothing verified after
     boot would hand the tests a device nothing checked.
   - Baking is host-local and idempotent, guarded by a lock directory under
     `$HOME/.mobile-ci-simulator-templates`, so two concurrent jobs leave one
     template, not two.

   On a fleet whose VMs are fresh clones of a base image per job, the copy left
   behind dies with the VM — the win there comes from **baking the templates
   into the image**; see
   [docs/self-hosted-runners.md](../../docs/self-hosted-runners.md#templates-the-image-can-bake)
   for the exact `simctl` recipe and naming rule.
3. **`slim-profile` alone** — the action creates a stock device and applies the
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
| `lease-file`           | no       | `''`                | Lease file path. Defaults to `$RUNNER_TEMP/simulator-lease-<udid>.json`, which is unique per device. An explicit path is written with `noclobber`, so a second job cannot overwrite the first job's lease and make one `release` delete the other's device. |
| `boot-timeout-seconds` | no       | `300`               | Bound on `xcrun simctl bootstatus -b`.                                         |
| `template-device`      | no       | `''`                | Exact name of a shut-down device to `simctl clone` instead of creating one.    |
| `template-strategy`    | no       | `none`              | `auto` clones the host's shut-down `mobile-ci-template-<device-type>-<runtime>` device for this lease (verifying the booted clone, not the template), and leaves one behind when there is none. Mutually exclusive with `template-device`; requires `slim-profile`. |
| `slim-profile`         | no       | `bundled`           | `bundled` uses this release's [`profiles/ci.json`](../../profiles/ci.json); a repo-relative path uses that profile instead; `''` leases a stock device. |
| `slim-repair`          | no       | `true`              | Apply the profile in-job (a reboot) when the lease does not match it; a cloned template that produced a non-slim lease is also warned about as stale. |
| `simslim-version`      | no       | `0.10.0`             | Pinned simslim CLI version.                                                    |
| `simslim-sha256`       | no       | `eec00b27…f4a1d`    | Digest of that version's `macos-arm64` release asset.                          |

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
- uses: rnw-community/mobile-ci/actions/simulator-lease@v1
  id: simulator
  with:
      device-type: 'iPad Pro 11-inch (M4)'
      runtime: latest
      template-strategy: auto

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
