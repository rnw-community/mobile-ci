# store-screenshots.yml

`workflow_call` reusable workflow: fleet-native store screenshot capture for
**iOS simulators and Android Redroid containers**, in one of two capture
modes:

- **`capture-mode: flows`** (default) — the legacy v1.5.x behavior,
  byte-for-byte: scenes are numbered Maestro flow files discovered under
  `screenshots-dir`. iOS-only; Android entries in the manifest fail closed.
- **`capture-mode: direct`** — scenes come from a `capture-scenes` JSON
  manifest shared across every device entry. Each scene is either a
  **deep link** (app terminated → optional `seed-command` → launch → open
  URL → settle → OS screenshot; no Maestro involved at all) or a **Maestro
  flow** (for scenes that need real interaction). Required for Android.

Seven jobs: **validate-manifest** (hosted `ubuntu-latest`; fails closed on a
malformed `capture-manifest`/`capture-scenes` or any mode/target
cross-check) → **build-ios** (same build-job shape as `ios-maestro.yml`'s
`build` job for the single `ios-target`; runs only when the manifest has iOS
entries) and **build-android** (same build-job shape as
`android-maestro.yml`'s `build` job for the single `android-target`; runs
only when the manifest has Android entries) → **capture-ios** (one job per
iOS manifest entry — download the built `.app`, boot that entry's pinned
simulator once via [`capture-screenshots-ios`](../../actions/capture-screenshots-ios/README.md),
loop `locales x appearances x scenes` on it, optional
`post-capture-command`, upload `raw-screenshots-ios-<device-slug>`) and
**capture-android** (one job per Android entry —
[`redroid-container`](../../actions/redroid-container/README.md) start →
[`capture-screenshots-android`](../../actions/capture-screenshots-android/README.md)
→ optional `post-capture-command` → upload
`raw-screenshots-android-<device-slug>` → `if: always()` teardown) →
**upload** (gated by `upload-screenshots`; requires every platform with
manifest entries to have captured successfully — a capture job skipped by a
failed build blocks the upload, only a platform with no manifest entries may
stay skipped — merges every `raw-screenshots-*` artifact, optionally
validates iOS resolutions against `apple-screenshot-slots`, then runs a
consumer-owned `upload-command`) → **status** (single required check with
honest-skip semantics: a platform's build/capture jobs must succeed whenever
the manifest has entries for it — `skipped` only passes for a platform with
no entries).

## capture-manifest

One capture job per entry. `platform` defaults to `"ios"` (v1.5.x manifests
keep working unchanged).

```json
[
  {"platform":"ios","device":"iPhone 17 Pro Max","locales":["en","de"],"appearances":["light","dark"],"orientation":"portrait"},
  {"platform":"ios","device":"iPad Pro 13-inch (M4)","locales":["en"],"appearances":["light"],"orientation":"landscape"},
  {"platform":"android","device":"phone-6.7","width":1080,"height":2340,"density":440,"locales":["en","de"],"appearances":["light","dark"]}
]
```

Validation rules (all fail closed in `validate-manifest`):

- `platform` — optional, `"ios"` (default) or `"android"`.
- **iOS entries**: `device` is an exact simulator name (matched with no
  fuzziness by `capture-screenshots-ios`), `locales` a non-empty array of
  non-empty strings, `appearances` ⊆ `["light","dark"]`, optional
  `orientation` `portrait` (default) or `landscape`.
- **Android entries**: `device` is a free-form label matching
  `^[A-Za-z0-9 ._-]+$` used **only** for the output/artifact slug — the
  actual device shape comes from required positive-integer
  `width`/`height`/`density` (applied via `wm size`/`wm density`);
  `orientation` must be absent or `portrait` (**Android landscape is a
  v1.6.0 non-goal** — the pixel-rotation bake relies on macOS-only `sips`).
  Android entries also require `capture-mode: direct`.
- Device slugs (lowercased, non-alphanumeric runs collapsed to `-`) must be
  unique **per platform** — artifact names are platform-prefixed, so
  `iPhone 17 Pro` (iOS) and an Android label slugifying identically may
  coexist.
- iOS entries require `ios-target`; Android entries require
  `android-target`; at least one entry overall; at most 256 entries per
  platform.

## capture-scenes (direct mode)

One shared scene list; per-scene filters narrow where each scene runs.

```json
[
  {"name":"home","deepLink":"sudoku://home"},
  {"name":"game","deepLink":"sudoku://game/continue","settleSeconds":5},
  {"name":"win","flow":"14.win.flow.yaml"},
  {"name":"stats","deepLink":"sudoku://stats","platforms":["ios"],"appearances":["dark"],"locales":["en"]}
]
```

- `name` — required, `^[A-Za-z0-9_-]+$`, unique; becomes the output path
  segment `raw/<platform>/<device-slug>/<locale>/<appearance>/<name>.png`.
- Exactly one of `deepLink` (non-empty string) or `flow` (path relative to
  `screenshots-dir`; absolute paths and `..` segments fail closed; existence
  is checked at capture time). Any flow scene makes `screenshots-dir`
  required. In direct mode the `<number>.<name>.flow.yaml` naming convention
  is **not** required — the scene name comes from the manifest, and each
  flow must still produce exactly one `takeScreenshot` output. Flow scenes
  are validated against the default Maestro (2.8.x): older 2.6.x releases
  store `takeScreenshot` output in a layout the collector does not search,
  so a downgraded `maestro-version` fails closed with the zero-screenshot
  error rather than silently capturing nothing.
- Optional `settleSeconds` — integer 0–120, overriding the workflow-level
  `settle-seconds` for deep-link scenes.
- Optional `platforms` — non-empty subset of `["ios","android"]`; default
  both. Every platform with manifest entries must be covered by at least one
  scene.
- Optional `locales`/`appearances` — filters; the scene is captured only for
  cells in the intersection with the device entry's lists.

Maestro is only installed on a capture job when its scene set actually
contains a flow — an all-deep-link manifest never touches Maestro.

## Seed hook contract

`seed-command` (direct mode only) runs once per
`locale x appearance x scene` cell, from the repo root, with the app
installed and terminated (iOS) / force-stopped (Android), before the scene's
launch. A seed failure marks that cell failed closed — no capture, no retry
— and the capture job fails at the end. Environment:

| Var              | iOS                    | Android |
| ----------------- | ---------------------- | -------------- |
| `SCENE`           | scene name             | same |
| `LOCALE`          | current locale         | same |
| `APPEARANCE`      | `light`/`dark`         | same |
| `APP_ID`          | bundle id              | application id |
| `PLATFORM`        | `ios`                  | `android` |
| `DEVICE_SLUG`     | slugified device       | same |
| `SIMULATOR_UDID`  | booted simulator UDID  | — |
| `ANDROID_SERIAL`  | —                      | adb serial of the Redroid container |
| `APP_PATH`        | packaged `.app` path   | — |
| `APK_PATH`        | —                      | packaged `.apk` path |

Reference recipe (the suuudokuuu app's redux-persist state): on iOS, resolve
the app's data container via
`xcrun simctl get_app_container "$SIMULATOR_UDID" "$APP_ID" data`, then
write the seed JSON into the expo-sqlite DB under it — creating the DB
directory itself if the app has never launched (expo-sqlite's directory does
not exist before first launch; the hook must `mkdir -p` it). On Android,
`adb pull` the DB, rewrite it, `adb push` it back, and delete
any stale `-wal`/`-shm` sidecar files so SQLite does not replay them over
the seeded state. To rewrite the DB the hook can shell out to a host
`sqlite3` binary, or — on Node >= 22.13 — use the built-in `node:sqlite`
module with no host prerequisite at all. **Redroid's stock image does
_not_ run adbd as root** — `adb pull`/`push` into
`/data/data/<app-id>/...` is denied until the hook elevates: run
`adb root` first, and because that restarts adbd (dropping a TCP serial's
connection), retry `adb connect "$ANDROID_SERIAL"` and probe
`adb shell id` until it reports `uid=0` before touching app data.

## Android capture

- Runs on the `android-capture-runner-labels` pool (default
  `["self-hosted","linux-tiered","linux-xl"]`) — a Linux Redroid host per
  [docs/self-hosted-runners.md](../self-hosted-runners.md) (binder_linux
  module, privileged containers, prewarm manifest). This input deliberately
  does **not** fall back to `runner-labels`, whose macOS default can never
  run a Redroid container; `capture-runner-labels` stays iOS-only for the
  same reason.
- The Android **build** happens elsewhere: `android-build-runner-labels` →
  `build-runner-labels` → `runner-labels` (the macOS default is correct —
  Google publishes no `linux-aarch64` NDK/cmake, so the Redroid pool cannot
  build).
- The device must run **API 33+** (`cmd locale set-app-locales`);
  `capture-screenshots-android` fails closed below that. The default
  `redroid/redroid:15.0.0_64only-latest` image (API 35) is fine.
- `status-bar-override` maps to SystemUI demo mode (clock 09:41, full wifi,
  no mobile data type, battery 100% unplugged, notifications hidden).
- **Rendering fidelity caveat**: Redroid runs with guest-mode GPU rendering
  and a GMS-free image — an app that hard-depends on Play services may
  render "Play services required" dialogs into its screenshots. Validate
  captures against a local emulator before shipping them to a listing.

## apple-screenshot-slots

Optional fail-closed guard between artifact download and `upload-command`:
a JSON object mapping pixel resolutions to your slot labels, e.g.

```json
{"1320x2868": "IPHONE_69", "2064x2752": "IPAD_PRO_3GEN_129"}
```

When non-empty, the upload job reads every downloaded iOS PNG's IHDR
width/height (dependency-free, via `python3`) and fails — listing every
offending file and its resolution — unless each one matches a key (`WxH` or
`HxW`, so landscape-baked captures match their portrait slot). Zero iOS
PNGs also fails closed (e.g. an Android-only run with slots configured). A
slot → screenshot-count coverage table is appended to the job summary.

## Flow convention (`capture-mode: flows`)

Unchanged from v1.5.x — screenshot scenes are numbered top-level
`*.flow.yaml` files directly inside `screenshots-dir`:

```text
apps/mobile/e2e/flows/screenshots/
├── 01.home.flow.yaml          # runnable scene -> raw/ios/<device-slug>/<locale>/<appearance>/home.png
├── 02.settings.flow.yaml      # runnable scene -> .../settings.png
└── subflows/                  # never auto-discovered or run standalone
    ├── apply-language.flow.yaml
    └── apply-appearance.flow.yaml
```

The scene name used in the output path is the filename with its numeric
prefix and `.flow.yaml` suffix stripped (`01.home.flow.yaml` -> `home`) -
`capture-screenshots-ios` fails closed if a discovered file does not match
that `<number>.<name>.flow.yaml` shape.

**Locale/appearance are applied at two layers.** `capture-screenshots-ios`
sets both at the OS level before each locale's/appearance's scenes run
(`xcrun simctl ui <udid> appearance light|dark`, and a best-effort
`defaults write <app-id> AppleLanguages/AppleLocale`), *and* passes
`-e LOCALE=<value> -e APPEARANCE=<value>` into every flow-backed scene. An
app that follows the system setting needs no flow changes at all; an app
with its own in-app language/theme switcher needs its scenes to read
`${LOCALE}`/`${APPEARANCE}` and apply them - the reference convention
(mirrored from `apply-language.flow.yaml`/`apply-appearance.flow.yaml` in
[vitalyiegorov/suuudokuuu](https://github.com/vitalyiegorov/suuudokuuu)) is a
subflow under `screenshots-dir`'s `subflows/` directory that each scene
`runFlow`s at its start:

```yaml
# screenshots/subflows/apply-appearance.flow.yaml
appId: ${APP_ID}
---
- runFlow:
      when:
          true: ${APPEARANCE == 'dark'}
          visible:
              id: 'SettingsScreenSelectors.DarkModeSwitch'
              checked: false
      commands:
          - tapOn:
                id: 'SettingsScreenSelectors.DarkModeSwitch'
```

```yaml
# screenshots/01.home.flow.yaml
appId: ${APP_ID}
---
- runFlow: subflows/reset-app.flow.yaml
- runFlow:
      file: subflows/apply-language.flow.yaml
      env:
          LOCALE: ${LOCALE}
- runFlow:
      file: subflows/apply-appearance.flow.yaml
      env:
          APPEARANCE: ${APPEARANCE}
- takeScreenshot: 'home'
```

## Maestro workspace config

Maestro only auto-discovers a workspace `config.yaml` when the CLI is pointed
at a **directory**. Both capture actions hand the CLI one scene flow file per
invocation, so a workspace `config.yaml` is never read and nothing warns about
it. `maestro-config` passes it explicitly (`--config`) to every `maestro test`
a flow-backed scene runs.

The case that motivated it: an `@expo/ui` SwiftUI `.sheet()` modal renders its
React Native content outside the app's main window, so the XCUITest hierarchy
Maestro snapshots never contains it and every selector inside the sheet times
out at its assertion budget. The fix is one workspace-config key —
`platform.ios.snapshotKeyHonorModalViews: false` — which is inert unless
`--config` actually reaches the CLI.

## Inputs

| Name                          | Required | Default                             | Description |
| -------------------------------- | -------- | -------------------------------------- | -------------- |
| `runner-labels`                    | no       | `["self-hosted","macOS","ARM64"]`         | JSON array of self-hosted runner labels for the iOS build/capture jobs. |
| `build-runner-labels`               | no       | `''`                                     | JSON array of runner labels for the iOS build job (and the Android build job, unless `android-build-runner-labels` is set). Falls back to `runner-labels`. |
| `capture-runner-labels`             | no       | `''`                                     | JSON array of runner labels for the **iOS** capture job only (Android uses `android-capture-runner-labels` — a deliberate asymmetry, the pools can never overlap). Falls back to `runner-labels`. Must be an arm64 macOS pool. |
| `upload-runner-labels`              | no       | `''`                                     | JSON array of runner labels for the gated upload job. Falls back to `runner-labels`. |
| `ios-target`                        | when the manifest has iOS entries | `''`   | Single iOS build target JSON object: `{name, appDir, workspace, scheme, appId, prebuildCommand}`. Renamed from `target` in v1.6.0. |
| `android-target`                    | when the manifest has Android entries | `''` | Single Android build target JSON object: `{name, appDir, appId, prebuildCommand}` — the same per-target shape as `android-maestro.yml`'s `targets` entries. |
| `capture-manifest`                  | **yes**  | —                                        | JSON array of capture matrix entries, one job per entry; see [capture-manifest](#capture-manifest). |
| `capture-mode`                      | no       | `flows`                                   | `flows` (legacy discovery, iOS-only) or `direct` (scene-manifest-driven). Anything else fails closed. |
| `capture-scenes`                    | when `capture-mode: direct` | `''`          | JSON array of scenes; see [capture-scenes](#capture-scenes-direct-mode). Fails closed if set in `flows` mode. |
| `seed-command`                      | no       | `''`                                     | Per-cell seed hook, direct mode only (fails closed in `flows` mode); see [Seed hook contract](#seed-hook-contract). |
| `settle-seconds`                    | no       | `3`                                       | Seconds (integer 0–120) between a deep-link launch and its screenshot; per-scene `settleSeconds` overrides it. |
| `status-bar-override`               | no       | `true`                                    | Store-clean status bar in both modes (iOS `simctl status_bar` 9:41 override; Android SystemUI demo mode). Fails closed if it cannot be applied. |
| `apple-screenshot-slots`            | no       | `''`                                     | JSON object `{"<W>x<H>": "<slot-label>"}`; non-empty enables the fail-closed upload-job resolution check. See [apple-screenshot-slots](#apple-screenshot-slots). |
| `screenshots-dir`                   | in `flows` mode, or when a scene has a `flow` | `''` | Scene-discovery root (`flows` mode) / the directory flow-backed scenes resolve against (`direct` mode). |
| `scenes-name-pattern`               | no       | `*.flow.yaml`                             | Space-separated `find -name` globs selecting scenes directly inside `screenshots-dir` (`flows` mode only). |
| `scenes-exclude-pattern`            | no       | `''`                                     | Optional `find ! -name` glob excluding matched scenes by basename (`flows` mode only). |
| `maestro-env`                       | no       | `''`                                     | Newline-separated `KEY=VALUE` pairs, each passed as an additional `-e KEY=VALUE` argument on top of the always-passed `APP_ID`/`LOCALE`/`APPEARANCE` (flow-backed scenes in either mode). Fails closed on a malformed line. |
| `maestro-config`                    | no       | `''`                                     | Path to the consumer's Maestro workspace config (`config.yaml`), passed as `--config` to every `maestro test` invocation. Maestro only auto-discovers a workspace `config.yaml` when it is pointed at a **directory**, and the actions below always pass individual flow files, so without this input a workspace config is silently ignored — e.g. `platform.ios.snapshotKeyHonorModalViews: false`, which an `@expo/ui` SwiftUI `.sheet()` modal needs before its React Native content appears in the XCUITest hierarchy at all. Relative paths resolve against the job's working directory. Fails closed when set to a path that is not a file. Passed to both capture actions. |
| `maestro-version`                   | no       | `2.8.0`                                   | Pinned Maestro CLI version; still used by flow-backed scenes in either mode, installed lazily in direct mode. |
| `post-capture-command`              | no       | `''`                                     | Optional consumer-owned command run in each capture job (both platforms) after capture, before upload — e.g. a device-bezel framing script. Runs with `SCREENSHOTS_OUTPUT_DIR` and `DEVICE_SLUG` in its environment. Its failure fails the capture job. |
| `xcode-version`                     | no       | `26.4.1`                                  | Xcode version string. |
| `xcode-build`                       | no       | `17E202`                                  | Xcode build number. |
| `cache-profile`                     | no       | `ios-native-v1`                           | Cache-key prefix distinguishing this consumer/app (iOS build). |
| `expo-fingerprint-version`          | no       | `0.20.6`                                  | Pinned `@expo/fingerprint` npm version. |
| `node-version`                      | no       | `22.x`                                    | Node version for `actions/setup-node`. |
| `install-command`                   | no       | `yarn install --immutable`                | JS dependency install command. |
| `enable-corepack`                   | no       | `true`                                    | Run `corepack enable` before install. |
| `build-command`                     | no       | `''`                                     | Optional workspace JS build command run at repo root before the native build (both build jobs). |
| `rct-use-prebuilt-rncore`           | no       | `false`                                    | Sets `RCT_USE_PREBUILT_RNCORE=1` for the iOS build step when `true`. |
| `rct-use-rn-dep`                    | no       | `false`                                    | Sets `RCT_USE_RN_DEP=1` for the iOS build step when `true`. |
| `expo-use-precompiled-modules`      | no       | `false`                                    | Sets `EXPO_USE_PRECOMPILED_MODULES=1` for the iOS build step when `true`. |
| `ccache-max-size`                   | no       | `2G`                                     | Bounded, compressed ccache maximum size (iOS build). |
| `build-env`                         | no       | `''`                                     | Newline-separated `KEY=VALUE` pairs appended to `$GITHUB_ENV` at the start of each build job. Fails closed on a malformed line. |
| `repack-on-hit`                     | no       | `false`                                    | On a native-app-cache hit (either platform), run `repack-app` instead of reusing the cached shell unchanged. |
| `repack-app-version`                | no       | `0.7.2`                                    | Pinned `@expo/repack-app` npm version, used only when `repack-on-hit` is true. |
| `build-timeout-minutes`             | no       | `60`                                      | iOS build job timeout. |
| `capture-timeout-minutes`           | no       | `90`                                      | iOS capture job timeout. Default is generous: one job runs the full `locales x appearances x scenes` loop on a single booted simulator. |
| `android-build-runner-labels`       | no       | `''`                                     | Runner labels for the Android build job. Fallback chain: this → `build-runner-labels` → `runner-labels`. |
| `android-capture-runner-labels`     | no       | `["self-hosted","linux-tiered","linux-xl"]` | Runner labels for the Android capture job (the Redroid pool). No fallback to `runner-labels`. |
| `android-cmdline-tools-version`     | no       | `12266719`                                | See `build-android-app` README — pin explicitly. |
| `android-gradle-task`               | no       | `assembleRelease`                         | `gradlew` task for the Android build. |
| `android-gradle-args`               | no       | `''`                                     | Extra whitespace-split arguments appended after `android-gradle-task`. |
| `android-cache-profile`             | no       | `android-native-v1`                       | Cache-key prefix for the Android build (`cache-profile` stays iOS-only). |
| `android-build-tools-version`       | no       | `35.0.0`                                  | Build-tools installed on a cache hit for repack-app's aapt2 validation; used only when `repack-on-hit` is true. |
| `android-build-tools-dir`           | no       | `''`                                     | Explicit build-tools dir for repack-app; used only when `repack-on-hit` is true. |
| `android-build-timeout-minutes`     | no       | `60`                                      | Android build job timeout. |
| `android-capture-timeout-minutes`   | no       | `90`                                      | Android capture job timeout. |
| `redroid-image`                     | no       | `redroid/redroid:15.0.0_64only-latest`    | Redroid image tag, used on a prewarm-manifest miss. Must resolve to API 33+. |
| `redroid-memory`                    | no       | `3g`                                      | Container memory limit. |
| `redroid-cpus`                      | no       | `2`                                       | Container CPU limit. |
| `redroid-prewarm-manifest-path`     | no       | `$HOME/.rnw-ci/android-emulator.json`     | Host-side prewarm manifest path; see [docs/self-hosted-runners.md](../self-hosted-runners.md). |
| `redroid-boot-timeout-seconds`      | no       | `600`                                     | Seconds to wait for `sys.boot_completed`. |
| `upload-screenshots`                | no       | `false`                                    | Run the gated upload job. |
| `upload-command`                    | no       | `''`                                     | Consumer-owned command run in the upload job, e.g. `bundle exec fastlane ios ios_screenshots`. Required when `upload-screenshots` is `true`; runs in the resolved app dir (`ios-target`'s `appDir` when set, `android-target`'s otherwise) with `SCREENSHOTS_DIR` (the resolved `screenshots-download-dir`) in its environment. |
| `screenshots-download-dir`          | no       | `fastlane/screenshots/raw`                 | Path, relative to the resolved app dir, every capture job's artifact is merged into before `upload-command` runs — iOS under its `ios/` subdirectory, Android under `android/`. |
| `asc-key-path`                      | no       | `''`                                     | Optional path, relative to the resolved app dir, the App Store Connect API key (`.p8`) is written to and removed from for `upload-command`. Leave empty (default) to write it under `$RUNNER_TEMP` instead. |
| `publish-env`                       | no       | `''`                                     | Newline-separated `KEY=VALUE` pairs of non-secret env appended to `$GITHUB_ENV` at the start of the upload job. Fails closed on a malformed line. For secret values use `EAS_EXTRA_ENV` instead. |

## Secrets

| Name                | Required | Description |
| --------------------- | -------- | -------------- |
| `EXPO_TOKEN`          | no       | Forwarded to the upload job's environment if `upload-command` needs it. |
| `ASC_API_KEY`         | no       | App Store Connect API key contents (`.p8`). When set, written to `asc-key-path` (or `$RUNNER_TEMP`) before `upload-command` runs and removed afterward - same contract as `native-publish.yml`'s `ASC_API_KEY`. |
| `EAS_EXTRA_ENV`       | no       | Newline-separated `KEY=VALUE` pairs of secret env appended to `$GITHUB_ENV` at the start of the upload job, each value masked before being written - same fail-closed parser and masking as `native-publish.yml`'s `EAS_EXTRA_ENV`. |

Unlike `native-publish.yml`, none of these secrets are hard-required even
when `upload-screenshots` is `true` - `upload-command` is entirely
consumer-owned, and some fastlane setups authenticate a different way (e.g.
`FASTLANE_SESSION` threaded through `EAS_EXTRA_ENV`). The two capture
pipelines themselves need no secrets at all.

## Permissions

`contents: read` is sufficient in the caller workflow; this workflow does not
write to the repository.

## Example

`workflow_call` cannot self-schedule, so a nightly capture needs a thin
caller workflow with both `workflow_dispatch` (for on-demand runs) and
`schedule` (for the nightly cron):

```yaml
# .github/workflows/store-screenshots.yml (in your app repo)
name: Store screenshots
on:
    workflow_dispatch:
    schedule:
        - cron: '0 4 * * 1'
jobs:
    screenshots:
        uses: rnw-community/mobile-ci/.github/workflows/store-screenshots.yml@<full-commit-sha>
        with:
            ios-target: >-
                {"name":"bare","appDir":"apps/mobile","workspace":"MyApp.xcworkspace","scheme":"MyApp","appId":"com.example.app","prebuildCommand":""}
            android-target: >-
                {"name":"bare","appDir":"apps/mobile","appId":"com.example.app","prebuildCommand":""}
            capture-manifest: >-
                [
                  {"device":"iPhone 17 Pro Max","locales":["en","de","fr"],"appearances":["light","dark"]},
                  {"platform":"android","device":"phone-6.7","width":1080,"height":2340,"density":440,"locales":["en","de","fr"],"appearances":["light","dark"]}
                ]
            capture-mode: direct
            capture-scenes: >-
                [
                  {"name":"home","deepLink":"myapp://home"},
                  {"name":"stats","deepLink":"myapp://stats","settleSeconds":5},
                  {"name":"win","flow":"14.win.flow.yaml","platforms":["ios"]}
                ]
            screenshots-dir: apps/mobile/e2e/flows/screenshots
            seed-command: yarn tsx scripts/seed-app-state.ts
            apple-screenshot-slots: >-
                {"1320x2868":"IPHONE_69"}
            upload-screenshots: true
            upload-command: bundle exec fastlane ios ios_screenshots
        secrets:
            ASC_API_KEY: ${{ secrets.ASC_API_KEY }}
```

## Migrating from v1.5.x

v1.6.0 is a **documented breaking release** for this workflow. What breaks:

1. **`target` → `ios-target`.** Rename the input; the JSON shape is
   unchanged. It is now optional — required only when the manifest has iOS
   entries.
2. **Capture artifact names are platform-prefixed.** What was
   `raw-screenshots-<device-slug>` is now
   `raw-screenshots-ios-<device-slug>` (and
   `raw-screenshots-android-<device-slug>` for Android entries). The
   workflow's own upload job still merges via the `raw-screenshots-*`
   pattern, but anything of yours that downloads a capture artifact by
   exact name (a follow-up job, a `gh run download -n ...` script) must add
   the platform segment. The merged download layout also gains a platform
   level: screenshots that previously landed at
   `<screenshots-download-dir>/ios/<slug>/...` are unchanged, since the
   `raw/` tree always contained an `ios/` level — but Android entries now
   add a sibling `android/` tree your fastlane lane should ignore or
   consume explicitly.
3. **`screenshots-dir` is no longer hard-required** — only in `flows` mode
   or when a scene declares a `flow`. Existing callers keep passing it and
   are unaffected.
4. **`status-bar-override` defaults to `true`.** Every capture — including
   unchanged `flows`-mode pipelines — now gets the 9:41/full-bars/100%
   status bar. This is an intentional behavior change; pass
   `status-bar-override: false` to restore the previous real-status-bar
   captures.

Everything else is additive and inert by default: `capture-mode` defaults to
`flows`, which preserves v1.5.x capture behavior byte-for-byte (and rejects
every direct-mode-only input — `capture-scenes`, `seed-command` — fail
closed rather than silently ignoring them).

See [README.md](../../README.md#reusable-workflow-catalog) for the full
action/workflow catalog, and the à-la-carte composite actions this
workflow's capture jobs wrap:
[capture-screenshots-ios](../../actions/capture-screenshots-ios/README.md),
[capture-screenshots-android](../../actions/capture-screenshots-android/README.md),
[redroid-container](../../actions/redroid-container/README.md).
