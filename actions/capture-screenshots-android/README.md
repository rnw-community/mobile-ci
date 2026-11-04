# capture-screenshots-android

Drives an **already-booted** Android device over adb — a Redroid container
(pair with [`redroid-container`](../redroid-container/README.md)), an AVD
(pair with [`android-emulator`](../android-emulator/README.md)), or a
physical device — and captures one screenshot per `locale` x `appearance` x
deep-link scene from a JSON scene manifest. This action never manages the device lifecycle itself — it
takes the device's adb serial as an input and leaves start/teardown to the
caller.

**Output layout is fixed and not configurable:**
`<output-dir>/raw/android/<device-slug>/<locale>/<appearance>/<scene>.png`,
where `<device-slug>` is `device-name` lowercased with every run of
non-alphanumeric characters collapsed to a single hyphen. `device-name` is a
free-form label (`^[A-Za-z0-9 ._-]+$`) used *only* for that path segment —
it selects nothing; the device is whatever `android-serial` points at.
Device shape comes from `width`/`height`/`density` instead, applied via
`wm size` / `wm density` before the app is installed or launched. The
`raw/android/<device-slug>` directory is cleared at the start of every run,
so a reused `output-dir` never republishes stale screenshots from a
previous matrix.

## Requirements and device prep

- **Below API 33 fails closed.** Locales are applied per-app via
  `cmd locale set-app-locales` (persistent, no reboot), which needs API 33+;
  the action reads `ro.build.version.sdk` up front and fails closed below
  that. The default Redroid image (`redroid/redroid:15.0.0_64only-latest`, API 35) is fine.
- **Appearance** is applied via `cmd uimode night yes|no` per appearance
  value.
- **`status-bar-override: 'true'`** (default) enables SystemUI demo mode
  before capture: clock 09:41, full wifi, no mobile data type, battery 100%
  unplugged, notifications hidden. Failure of the
  demo-mode broadcasts fails closed; set the input to `'false'` to skip.
- **Landscape is not supported** — there is no `orientation` input. Rotating
  captured pixels the way the iOS action does relies on macOS-only `sips`,
  and this action runs on Linux hosts; a landscape Android matrix entry is a
  documented v1.6.0 non-goal.

## Scene manifest

`scenes` is the same JSON shape `store-screenshots.yml`'s `capture-scenes`
input uses (see
[docs/workflows/store-screenshots.md](../../docs/workflows/store-screenshots.md)
for the full schema): each scene has a unique path-safe `name` and exactly
one of

- `deepLink` — per cell, the app is `am force-stop`ped, optionally seeded
  (`seed-command`), launched via
  `am start -W -a android.intent.action.VIEW -d <deepLink> <app-id>`,
  allowed `settle-seconds` (or the scene's `settleSeconds`) to settle, then
  captured with `adb exec-out screencap -p`.

Optional per-scene `platforms`/`locales`/`appearances` filters restrict
where a scene is captured; scenes whose `platforms` excludes `android` are
skipped entirely (all of them being skipped fails closed). Each failing cell
gets 1 retry (2 attempts); a seed failure marks its cell failed with no
capture and no retry. A per-cell timing table is appended to
`$GITHUB_STEP_SUMMARY`, and the step fails at the end if any cell failed.

## Seed hook

`seed-command` runs once per locale x appearance x scene cell, from the repo
root, with the app installed and force-stopped, and with `SCENE`, `LOCALE`,
`APPEARANCE`, `APP_ID`, `PLATFORM=android`, `DEVICE_SLUG`,
`ANDROID_SERIAL`, and `APK_PATH` in its environment. Redroid's stock image
does **not** run adbd as root — `adb pull`/`adb push` into the app's data
directory is denied until the hook elevates: run `adb root`, then (because
that restarts adbd and drops a TCP serial's connection) retry
`adb connect "$ANDROID_SERIAL"` and probe `adb shell id` until it reports
`uid=0`. See the seed-hook contract in
[docs/workflows/store-screenshots.md](../../docs/workflows/store-screenshots.md).

## Inputs

| Name                   | Required | Default    | Description |
| ----------------------- | -------- | ---------- | -------------- |
| `android-serial`        | yes      | —          | adb serial of an already-booted API 33+ device this action drives. |
| `apk-path`              | yes      | —          | Path to the packaged `.apk` to install (`adb install -r`). |
| `app-id`                | yes      | —          | Application ID the scenes are captured from. |
| `scenes`                | yes      | —          | JSON array of scene objects; see [Scene manifest](#scene-manifest). |
| `device-name`           | yes      | —          | Free-form label (`^[A-Za-z0-9 ._-]+$`) deriving the `raw/android/<device-slug>` path segment. |
| `width`                 | yes      | —          | Emulated display width in px (`wm size`). |
| `height`                | yes      | —          | Emulated display height in px (`wm size`). |
| `density`               | yes      | —          | Emulated display density in dpi (`wm density`). |
| `locales`               | yes      | —          | Space- or comma-separated locale identifiers, e.g. `en,de`; each applied via `cmd locale set-app-locales` (fails closed). |
| `appearances`           | yes      | —          | Space- or comma-separated list of `light` and/or `dark` (`cmd uimode night`). |
| `seed-command`          | no       | `''`       | Consumer-owned per-cell seed hook; see [Seed hook](#seed-hook). Failure fails the cell closed (no capture, no retry). |
| `settle-seconds`        | no       | `3`        | Seconds (integer 0–120) between a deep-link launch and its screenshot; a scene's `settleSeconds` overrides it. |
| `status-bar-override`   | no       | `true`     | Reapply the SystemUI demo status bar per cell after seeding; wait up to 10 s for active demo mode and fail closed on unsupported devices or failed commands. |
| `output-dir`            | yes      | —          | Root output directory; see the fixed layout above. |

## Outputs

| Name          | Description |
| --------------- | -------------- |
| `device-slug`  | Slugified `device-name`. |
| `raw-dir`      | This run's output root — `output-dir/raw/android/<device-slug>`. |

## Example

```yaml
- name: Start Redroid
  id: redroid
  uses: rnw-community/mobile-ci/actions/redroid-container@v5.0.0 # v5.0.0
  with:
      mode: start
      container-name: redroid-screenshots-${{ strategy.job-index }}

- uses: rnw-community/mobile-ci/actions/capture-screenshots-android@v5.0.0 # v5.0.0
  with:
      android-serial: ${{ steps.redroid.outputs.android-serial }}
      apk-path: .ci-artifacts/store-screenshots-apk-bare/app-release.apk
      app-id: com.example.app
      scenes: >-
          [{"name":"home","deepLink":"myapp://home"},
           {"name":"stats","deepLink":"myapp://stats","settleSeconds":5}]
      device-name: phone-6.7
      width: 1080
      height: 2340
      density: 440
      locales: en,de
      appearances: light,dark
      output-dir: ${{ github.workspace }}/screenshots-output

- name: Teardown Redroid
  if: always()
  uses: rnw-community/mobile-ci/actions/redroid-container@v5.0.0 # v5.0.0
  with:
      mode: teardown
      container-name: redroid-screenshots-${{ strategy.job-index }}
```

On an x86_64 Linux runner with `/dev/kvm`, boot an AVD instead; nothing about
the capture itself changes. Give it its own `avd-name` and `wipe-data: 'true'`
so the `wm size`/`wm density` and demo-mode settings this action applies never
leak into, or come from, another job's AVD on a persistent host:

```yaml
- name: Start emulator
  id: emulator
  uses: rnw-community/mobile-ci/actions/android-emulator@v5.0.0 # v5.0.0
  with:
      mode: start
      avd-name: mobile-ci-screenshots
      wipe-data: 'true'

- uses: rnw-community/mobile-ci/actions/capture-screenshots-android@v5.0.0 # v5.0.0
  with:
      android-serial: ${{ steps.emulator.outputs.android-serial }}
      # ...the same inputs as above

- name: Stop emulator
  if: always()
  uses: rnw-community/mobile-ci/actions/android-emulator@v5.0.0 # v5.0.0
  with:
      mode: stop
```

`store-screenshots.yml` wires both: its `android-driver` input selects
`avd` (default, x86_64 Linux KVM) or `redroid`. Redroid consumers must
explicitly set both `android-driver: redroid` and compatible
`android-capture-runner-labels`.

SystemUI demo overrides are applied after the seed hook for every capture
cell, including after light/dark transitions. The action waits up to 10 seconds
for SystemUI to report demo mode as available and active before broadcasting
the 9:41 clock and icon settings. Missing demo support or a failed command
fails capture; set `status-bar-override: 'false'` for a device without it.
