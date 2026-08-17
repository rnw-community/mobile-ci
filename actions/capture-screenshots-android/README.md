# capture-screenshots-android

Drives an **already-booted** Android device over adb — a Redroid container
(pair with [`redroid-container`](../redroid-container/README.md)), an AVD, or
a physical device — and captures one screenshot per `locale` x `appearance` x
scene from a JSON scene manifest. Unlike
[`capture-screenshots-ios`](../capture-screenshots-ios/README.md), there is
no flow-discovery mode: Android capture is scene-manifest-driven (direct
mode) only, and this action never manages the device lifecycle itself — it
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
  value; `-e APPEARANCE=<value>` is additionally passed to flow-backed
  scenes for apps with an in-app theme switch.
- **`status-bar-override: 'true'`** (default) enables SystemUI demo mode
  before capture: clock 09:41, full wifi, no mobile data type, battery 100%
  unplugged, notifications hidden — the Android equivalent of
  `capture-screenshots-ios`'s `simctl status_bar` override. Failure of the
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
- `flow` — a Maestro flow path relative to `screenshots-dir`, run with
  `ANDROID_SERIAL` set and expected to produce **exactly one**
  `takeScreenshot` output (zero or more than one fails that cell closed).
  Maestro is run from a fresh per-cell scratch working directory, because
  it writes a relative `takeScreenshot` name into the process CWD (not
  into `--test-output-dir`); the PNG is collected from the union of that
  scratch CWD and `--test-output-dir`'s `takeScreenshot/` subdirectory.
  Flow-internal `runFlow` references are unaffected — Maestro resolves
  them against the flow file, not the CWD. Maestro itself is installed
  lazily, only when at least one android-applicable scene declares a flow.

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
`ANDROID_SERIAL`, and `APK_PATH` in its environment. On Redroid, adbd runs
as root already — `adb pull`/`adb push` into the app's data directory works
without any `adb root` dance. See the seed-hook contract in
[docs/workflows/store-screenshots.md](../../docs/workflows/store-screenshots.md).

## Inputs

| Name                   | Required | Default    | Description |
| ----------------------- | -------- | ---------- | -------------- |
| `android-serial`        | yes      | —          | adb serial of an already-booted API 33+ device this action drives. |
| `apk-path`              | yes      | —          | Path to the packaged `.apk` to install (`adb install -r`). |
| `app-id`                | yes      | —          | Application ID the scenes are captured from; passed to Maestro as `APP_ID`. |
| `scenes`                | yes      | —          | JSON array of scene objects; see [Scene manifest](#scene-manifest). |
| `screenshots-dir`       | no       | `''`       | Directory flow-backed scenes' paths are resolved against; required only when an android-applicable scene declares a `flow`. |
| `device-name`           | yes      | —          | Free-form label (`^[A-Za-z0-9 ._-]+$`) deriving the `raw/android/<device-slug>` path segment. |
| `width`                 | yes      | —          | Emulated display width in px (`wm size`). |
| `height`                | yes      | —          | Emulated display height in px (`wm size`). |
| `density`               | yes      | —          | Emulated display density in dpi (`wm density`). |
| `locales`               | yes      | —          | Space- or comma-separated locale identifiers, e.g. `en,de`; each applied via `cmd locale set-app-locales` (fails closed). |
| `appearances`           | yes      | —          | Space- or comma-separated list of `light` and/or `dark` (`cmd uimode night`). |
| `seed-command`          | no       | `''`       | Consumer-owned per-cell seed hook; see [Seed hook](#seed-hook). Failure fails the cell closed (no capture, no retry). |
| `settle-seconds`        | no       | `3`        | Seconds (integer 0–120) between a deep-link launch and its screenshot; a scene's `settleSeconds` overrides it. |
| `status-bar-override`   | no       | `true`     | Enable the SystemUI demo-mode status bar; fails closed if the broadcasts fail. |
| `maestro-env`           | no       | `''`       | Newline-separated `KEY=VALUE` pairs passed as extra `-e` arguments to every `maestro test` (flow-backed scenes only). Fails closed on a malformed line. |
| `maestro-version`       | no       | `2.8.0`    | Pinned Maestro CLI version, installed lazily and the same way as `run-maestro-android-redroid`'s. |
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
  uses: rnw-community/mobile-ci/actions/redroid-container@v1
  with:
      mode: start
      container-name: redroid-screenshots-${{ strategy.job-index }}

- uses: rnw-community/mobile-ci/actions/capture-screenshots-android@v1
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
  uses: rnw-community/mobile-ci/actions/redroid-container@v1
  with:
      mode: teardown
      container-name: redroid-screenshots-${{ strategy.job-index }}
```
