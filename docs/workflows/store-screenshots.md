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
  URL → settle → [open-confirmation sheet check](#ios-open-confirmation-sheet)
  on iOS → OS screenshot) or a **Maestro flow** (for scenes that need real
  interaction). Required for Android.

Seven jobs: **validate-manifest** (hosted `ubuntu-latest`; loads and resolves
the optional [config file](#config-file), then fails closed on a malformed
`capture-manifest`/`capture-scenes` or any mode/target cross-check — every
downstream job reads its resolved values from this job's outputs) →
**build-ios** (same build-job shape as `ios-maestro.yml`'s
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
validates iOS resolutions against `apple-screenshot-slots`, runs a
consumer-owned `upload-command`, and optionally verifies/repairs App Store
Connect duplicates via `asc-dedupe-screenshots`) → **status** (single required check with
honest-skip semantics: a platform's build/capture jobs must succeed whenever
the manifest has entries for it — `skipped` only passes for a platform with
no entries).

## capture-manifest

One capture job per entry. `platform` defaults to `"ios"` (v1.5.x manifests
keep working unchanged).

```json
[
  {"platform":"ios","device":"iPhone 17 Pro Max","locales":["en","de"],"appearances":["light","dark"],"orientation":"portrait"},
  {"platform":"ios","device":"iPad Pro 13-inch (M4)","locales":[{"id":"en"},{"id":"de","env":{"LOCALE_IDENTIFIER":"de-DE"}}],"appearances":["light"],"orientation":"landscape"},
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
- **Locale items** may be a plain string (`"de"`) or an object
  `{"id": "de", "env": {"LOCALE_IDENTIFIER": "de-DE"}}`. The object's `id`
  must match `^[A-Za-z0-9_-]+$`, its optional `env` maps env names
  (`^[A-Za-z_][A-Za-z0-9_]*$`) to string values, and the reserved names
  `APP_ID`/`LOCALE`/`APPEARANCE` fail closed — the capture actions always
  pass those themselves and an override would be order-dependent. The same
  locale may not be listed twice in one entry. See
  [Per-locale flow env](#per-locale-flow-env) for why this exists.
- Device slugs (lowercased, non-alphanumeric runs collapsed to `-`) must be
  unique **per platform** — artifact names are platform-prefixed, so
  `iPhone 17 Pro` (iOS) and an Android label slugifying identically may
  coexist.
- iOS entries require `ios-target`; Android entries require
  `android-target`; at least one entry overall; at most 256 entries per
  platform.

## Per-locale flow env

**The problem:** a screenshot flow often needs Maestro env inputs that must
*vary per locale* — suuudokuuu's flows read `LOCALE_IDENTIFIER` (the BCP-47
tag the in-app language switcher applies) and `OS_LANGUAGE_MODE`, which
cannot be derived from the bare `${LOCALE}` path segment. The workflow-level
`maestro-env` input is one static list applied to every cell of every device,
so the only pre-v1.8 workarounds were splitting the manifest into one entry
per locale (one simulator boot each) or templating files inside a
`seed-command`.

**The contract:** declare a locale as an object instead:

```json
{"platform":"ios","device":"iPhone 17 Pro Max",
 "locales":[
   "en",
   {"id":"de","env":{"LOCALE_IDENTIFIER":"de-DE","OS_LANGUAGE_MODE":"german"}},
   {"id":"fr","env":{"LOCALE_IDENTIFIER":"fr-FR"}}
 ],
 "appearances":["light","dark"]}
```

Every flow-backed scene captured for `de` then receives `-e LOCALE=de -e
LOCALE_IDENTIFIER=de-DE -e OS_LANGUAGE_MODE=german ...`; `en` receives only
the global `maestro-env`. Precedence is documented and deterministic:
global `maestro-env` pairs first, then the locale's own pairs (Maestro's
last `-e` wins). Deep-link scenes run no Maestro and receive nothing.

**When not to use it:** if the value is identical for every locale it
belongs in `maestro-env`; if it varies per scene rather than per locale,
give the scene its own flow that derives the value from `${LOCALE}`.

## capture-scenes (direct mode)

One shared scene list; per-scene filters narrow where each scene runs.

```json
[
  {"name":"home","deepLink":"sudoku://home","readySelector":{"id":"HomeScreenSelectors.Root"}},
  {"name":"game","deepLink":"sudoku://game/continue","readySelector":{"id":"GameScreenSelectors.Root"},"settleSeconds":5},
  {"name":"win","flow":"14.win.flow.yaml"},
  {"name":"stats","deepLink":"sudoku://stats","readySelector":{"id":"StatsScreenSelectors.Root"},"platforms":["ios"],"appearances":["dark"],"locales":["en"]}
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
- `readySelector` — **required on every `deepLink` scene that applies to
  `ios`, rejected on `flow` scenes** (a flow asserts its own readiness).
  Either a non-empty string, matched by Maestro as text/regex, or an object
  `{"id": "<testID>"}` matched by accessibility id. iOS capture asserts it
  visible — via `extendedWaitUntil`, bounded by the cell's effective settle
  seconds with a 5s floor — after the open-confirmation sheet is dismissed
  and immediately before `simctl io screenshot`; the cell fails closed if it
  never appears. Pick an element the scene renders unconditionally: a screen
  root is a better anchor than a value that a setting can hide.

  Android capture does not consume `readySelector` yet, so it is required
  only of scenes that apply to `ios`; an `android`-only deep-link scene may
  omit it, and a shared scene's selector is simply ignored on the Android
  leg. The Android driver has no equivalent of the SpringBoard
  open-confirmation sheet, but it has the same blind spot about which
  activity is actually resumed — extending the probe there is tracked
  separately.
- Optional `settleSeconds` — integer 0–120, overriding the workflow-level
  `settle-seconds` for deep-link scenes.
- Optional `platforms` — non-empty subset of `["ios","android"]`; default
  both. Every platform with manifest entries must be covered by at least one
  scene.
- Optional `locales`/`appearances` — filters; the scene is captured only for
  cells in the intersection with the device entry's lists.

Maestro is only installed on a capture job when its scene set actually
contains a flow, or — on iOS — a deep link, which needs it for the
open-confirmation sheet check below. An all-deep-link Android manifest never
touches Maestro.

## iOS open-confirmation sheet

On newer iOS runtimes SpringBoard answers a `simctl openurl` deep link with
an **`Open in "<app>"?` / Cancel / Open** confirmation sheet, drawn over the
home screen with the target app deactivated behind it, so the screencap that
follows is a picture of SpringBoard rather than of the app. Nothing in
`simctl` reports which bundle is frontmost, and pre-launching the app before
the `openurl` does not avoid the sheet, so `capture-screenshots-ios` runs a
generated one-flow Maestro check on every deep-link cell, after its settle
and immediately before its screencap: it taps the sheet's confirm button when
the sheet is on screen, then `assertNotVisible`s it. A sheet still up fails
that cell (retried once, then the capture job fails naming the scene, locale
and appearance) instead of writing a screenshot of it.

The sheet is localised to the **simulator's own** language, which this
workflow never changes — the `locales` axis writes app-scoped preferences
only — so it is English on a stock CoreSimulator device.
`deeplink-confirm-title`/`deeplink-confirm-button` default to the English
strings; a simulator provisioned in another language fails the capture
closed up front until **both** are set to that language's strings. Both are
rejected, not just the title, because a simulator that already carries a
persisted approval never shows the sheet and would leave a wrong button label
unvalidated.

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

## App Store Connect dedupe gate

`asc-dedupe-screenshots: true` adds a post-upload verification/repair step to
the upload job, implemented by
[`asc-dedupe-screenshots`](../../actions/asc-dedupe-screenshots/README.md)
with no dependencies beyond `curl`/`jq`/`openssl` (it signs its own ES256
App Store Connect API JWT).

**Why:** fastlane's `deliver` occasionally reports a freshly uploaded
screenshot as "missing on App Store Connect", retries it, and both copies
survive — the listing then shows the same image twice. This was first hit by
a consumer whose bespoke Spaceship lane had to delete duplicates by hand;
the gate folds that lane into the workflow so every caller gets it.

**What it does:** walks every screenshot set of the target version
(default `asc-dedupe-version-state: PREPARE_FOR_SUBMISSION`, the editable
version this run just uploaded to; use `READY_FOR_SALE` to audit the live
listing), groups each set by file name, deletes all but the oldest copy of
every duplicate, and appends a per-locale coverage table to the job summary.
Duplicates on an already-submitted version cannot be modified (ASC returns
HTTP 409) - they are counted in `undeletable-count`, warned about, and, with
the default `fail-on-duplicates: true`, still fail the job.

**Fail-closed stance:** deleting duplicates repairs the listing but still
fails the job by default (`asc-fail-on-duplicates: true`) — duplicates are
evidence your upload lane double-uploads under retry and should be fixed.
Set it to `false` if a successful repair should count as success.

**When:** enable it whenever `upload-command` uploads iOS screenshots to App
Store Connect. It requires the `ASC_API_KEY`, `ASC_KEY_ID`, and
`ASC_ISSUER_ID` secrets and an `ios-target`; Android-only runs have nothing
to dedupe and fail closed if enabled without an `ios-target`.

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

## Config file

Everything app-shaped about a caller — targets, manifest, scenes, build and
upload knobs — can live in a checked-in JSON file instead of being passed as
JSON-in-YAML string blobs through `with:`. Point `config-path` at it:

```yaml
jobs:
    screenshots:
        uses: rnw-community/mobile-ci/.github/workflows/store-screenshots.yml@v1.11.0 # v1.11.0
        with:
            config-path: .github/store-screenshots.config.json
            build-runner-labels: '["self-hosted","macOS","ARM64","macos-builder"]'
```

The file is **one flat JSON object** whose keys are workflow input names
(kebab-case). Inputs that are JSON blobs today (`ios-target`,
`android-target`, `capture-manifest`, `capture-scenes`,
`apple-screenshot-slots`) take the **real JSON structure** — an object or an
array, not a string. Everything else is a JSON scalar; numbers and booleans
are accepted where the input is a string (`"settle-seconds": 5` works).

A machine-readable schema for editor autocomplete lives at
[`schemas/store-screenshots.schema.json`](../../schemas/store-screenshots.schema.json).
Associate it by filename in your editor's `json.schemas` settings — do **not**
add a `"$schema"` key to the config file itself, because the workflow rejects
every top-level key that is not loadable (see below) and `$schema` is not one.
The schema is a convenience only; the workflow's own `jq` allowlist is the
source of truth and the only thing CI runs.

### Precedence

**explicit workflow input > config file value > built-in default.**

Every config-loadable input whose old `default:` was a non-empty literal
(`capture-mode`, `settle-seconds`, `deeplink-confirm-title`,
`deeplink-confirm-button`, `screenshots-dir`, `install-command`,
`cache-profile`, `android-cache-profile`, `android-gradle-task`,
`screenshots-download-dir`, `asc-dedupe-version-state`) now declares
`default: ''` and applies that literal at resolution time instead. **The
effective default is unchanged** — a caller that passes no `config-path` and
no value for these behaves exactly as before.

**"Explicit" means "different from the declared default".** GitHub gives a
called workflow no signal for *whether* an input was passed — the `inputs`
context holds only resolved values, and an omitted input is filled in with
its `default:` before the workflow sees it (there is no `workflow_call`
equivalent of `github.event.inputs`, which only exists for
`workflow_dispatch`). So "the caller set this" is necessarily inferred as
"the value differs from the declared default", which has two consequences:

- **Strings:** `with: {upload-command: ''}` is indistinguishable from
  omitting `upload-command`, so an explicitly empty string **cannot**
  override a non-empty config value. To turn a config-file value off, remove
  its key from the config file rather than blanking it in `with:`.
- **Booleans:** the seven boolean keys (`status-bar-override`,
  `repack-on-hit`, `rct-use-prebuilt-rncore`, `rct-use-rn-dep`,
  `upload-screenshots`, `asc-dedupe-screenshots`, `asc-fail-on-duplicates`)
  follow the same rule: passing the **non-default** value wins over the
  config file, leaving the input at its declared default lets the config file
  decide. Pass `status-bar-override: false` to override a config file that
  says `true`; to override one that says `false`, remove the key from the
  file.

Either way the config file is authoritative for a key it declares, and
`with:` overrides it only by naming a *different* value — which is the
intended split: `with:` is for per-call deviations, the file is for the
app's standing configuration.

The `validate-manifest` job logs which inputs were resolved from the
workflow input, from `config-path`, and from the built-in default — read
that line first when a value is not what you expected.

### Loadable keys

Exactly these 32 keys may appear in the config file. Anything else fails
closed:

`ios-target`, `android-target`, `capture-manifest`, `capture-mode`,
`capture-scenes`, `screenshots-dir`, `seed-command`, `settle-seconds`,
`deeplink-confirm-title`, `deeplink-confirm-button`,
`status-bar-override`, `apple-screenshot-slots`, `maestro-env`,
`maestro-config`, `build-env`, `install-command`, `build-command`,
`cache-profile`, `android-cache-profile`, `android-gradle-task`,
`android-gradle-args`, `repack-on-hit`, `rct-use-prebuilt-rncore`,
`rct-use-rn-dep`, `upload-screenshots`, `upload-command`,
`screenshots-download-dir`, `publish-env`, `asc-dedupe-screenshots`,
`asc-dedupe-version-state`, `asc-dedupe-app-id`, `asc-fail-on-duplicates`.

**Why runner labels and timeouts are excluded.** Every `*-runner-labels` and
`*-timeout-minutes` input is *plan-time*: GitHub evaluates `runs-on` and
`timeout-minutes` when it schedules the job, before any step of any job has
run, so a file that can only be read by a step on an already-scheduled runner
can never feed them. They stay in `with:` — which is also where they belong,
since the pool a repository's jobs may target is infrastructure, not app
configuration. The same reasoning excludes every other input not in the list
above; nothing is silently ignored, an unlisted key is an error.

### Fail-closed behavior

With a non-empty `config-path`, the run fails — naming the path and the
offending key — when:

- the file does not exist in the checkout, or is not a regular readable file;
- the file is not valid JSON;
- the top level is not a JSON object;
- a top-level key is not in the loadable list (this is what catches typos —
  a silently ignored `capture-scene` key would otherwise leave the run using
  defaults nobody asked for);
- a value has the wrong shape for its key (a scalar where an object/array is
  expected, a non-`true`/`false` boolean, an array where a string is
  expected).

With `config-path` left empty (the default) none of this runs: no extra
checkout, no config step, and every input resolves to exactly what it
resolved to before this feature existed.

### Notes and limits

- `upload-command` assumes a working consumer-owned uploader (fastlane or
  otherwise) already exists in the app directory — the config file can supply
  the command string, never the lane itself; if you have no uploader, keep
  `upload-screenshots: false` and consume the `raw-screenshots-*` artifacts.
- `capture-mode: direct` on Android assumes you already have a working
  Android build target (`android-target`); this workflow builds it, it does
  not create one.
- `apple-screenshot-slots` **keys** must match `^[0-9]+x[0-9]+$`; the
  **values** are free-form non-empty label strings passed to nothing but your
  own coverage table, so both `{"1320x2868":"IPHONE_69"}` and
  `{"1320x2868":"iPhone 6.9\""}` are conformant. Use whatever label your
  uploader (e.g. a fastlane `Deliverfile`) expects.

### Full example

`.github/store-screenshots.config.json` (suuudokuuu's real configuration):

```json
{
    "ios-target": {
        "name": "production",
        "appDir": "packages/app",
        "workspace": "suuudokuuu.xcworkspace",
        "scheme": "suuudokuuu",
        "appId": "com.vitalyiegorov.suuudokuuu",
        "prebuildCommand": "npx expo prebuild -p ios --clean --no-install"
    },
    "capture-manifest": [
        {
            "platform": "ios",
            "device": "iPhone 17 Pro Max",
            "locales": [
                { "id": "en", "env": { "LOCALE_IDENTIFIER": "en-US", "OS_LANGUAGE_MODE": "true" } },
                { "id": "de", "env": { "LOCALE_IDENTIFIER": "de-DE", "OS_LANGUAGE_MODE": "true" } },
                { "id": "es", "env": { "LOCALE_IDENTIFIER": "es-ES", "OS_LANGUAGE_MODE": "true" } },
                { "id": "fr", "env": { "LOCALE_IDENTIFIER": "fr-FR", "OS_LANGUAGE_MODE": "true" } },
                { "id": "pt", "env": { "LOCALE_IDENTIFIER": "pt-BR", "OS_LANGUAGE_MODE": "true" } },
                { "id": "sv", "env": { "LOCALE_IDENTIFIER": "sv-SE", "OS_LANGUAGE_MODE": "true" } },
                { "id": "hi", "env": { "LOCALE_IDENTIFIER": "hi-IN", "OS_LANGUAGE_MODE": "true" } },
                { "id": "ar", "env": { "LOCALE_IDENTIFIER": "ar-SA", "OS_LANGUAGE_MODE": "true" } },
                { "id": "id", "env": { "LOCALE_IDENTIFIER": "id-ID", "OS_LANGUAGE_MODE": "true" } }
            ],
            "appearances": ["light"]
        }
    ],
    "capture-mode": "direct",
    "capture-scenes": [
        { "name": "home", "deepLink": "suuudokuuu://", "readySelector": { "id": "HomeScreenSelectors.Root" } },
        { "name": "game", "deepLink": "suuudokuuu://game", "readySelector": { "id": "GameScreenSelectors.Root" } },
        { "name": "stats", "deepLink": "suuudokuuu://history", "readySelector": { "id": "HistoryScreenSelectors.Root" } }
    ],
    "screenshots-dir": "tests/app-tests/flows/screenshots",
    "seed-command": "node tests/app-tests/scripts/ci-seed-scene.ts",
    "settle-seconds": 5,
    "status-bar-override": true,
    "cache-profile": "suuudokuuu-ios-prod-v1",
    "repack-on-hit": true,
    "rct-use-prebuilt-rncore": true,
    "rct-use-rn-dep": true,
    "build-env": "APP_VARIANT=production\n",
    "maestro-env": "OS_LANGUAGE_MODE=true\n",
    "apple-screenshot-slots": {
        "1320x2868": "iPhone 6.9\"",
        "1290x2796": "iPhone 6.9\"",
        "1284x2778": "iPhone 6.5\"",
        "1242x2688": "iPhone 6.5\"",
        "1206x2622": "iPhone 6.3\"",
        "1179x2556": "iPhone 6.1\"",
        "2064x2752": "iPad 13\"",
        "2752x2064": "iPad 13\"",
        "2048x2732": "iPad 12.9\"",
        "2732x2048": "iPad 12.9\""
    },
    "upload-screenshots": true,
    "upload-command": "export PATH=\"$HOME/.rbenv/shims:/opt/homebrew/bin:/opt/homebrew/sbin:$PATH\"\nexport SCREENSHOT_VARIANT=ci\nfastlane ios ios_screenshots\n",
    "screenshots-download-dir": "fastlane/screenshots/variants/ci",
    "asc-dedupe-screenshots": true,
    "asc-dedupe-app-id": "com.vitalyiegorov.suuudokuuu"
}
```

### Caller before and after

The caller that carries the config above shrinks from a 49-line `with:`
block to five lines — only the plan-time runner pools stay:

```yaml
# before: 72-line caller, 49 lines of `with:`
jobs:
    screenshots:
        uses: rnw-community/mobile-ci/.github/workflows/store-screenshots.yml@v1.8.0 # v1.8.0
        with:
            ios-target: >-
                {"name":"production","appDir":"packages/app","workspace":"suuudokuuu.xcworkspace", ...}
            capture-manifest: >-
                [ ...40 lines of JSON-in-YAML... ]
            # ...24 more inputs...
        secrets:
            ASC_API_KEY: ${{ secrets.EXPO_IOS_ASC_API_KEY }}
            ASC_KEY_ID: ${{ secrets.EXPO_IOS_ASC_KEY_ID }}
            ASC_ISSUER_ID: ${{ secrets.EXPO_IOS_ASC_ISSUER_ID }}
```

```yaml
# after: 28-line caller, 5 lines of `with:`
jobs:
    screenshots:
        uses: rnw-community/mobile-ci/.github/workflows/store-screenshots.yml@v1.11.0 # v1.11.0
        with:
            config-path: .github/store-screenshots.config.json
            build-runner-labels: '["self-hosted","macOS","ARM64","macos-builder"]'
            capture-runner-labels: '["self-hosted","macOS","ARM64","macos-maestro"]'
            upload-runner-labels: '["self-hosted","macOS","ARM64","macos-builder"]'
        secrets:
            ASC_API_KEY: ${{ secrets.EXPO_IOS_ASC_API_KEY }}
            ASC_KEY_ID: ${{ secrets.EXPO_IOS_ASC_KEY_ID }}
            ASC_ISSUER_ID: ${{ secrets.EXPO_IOS_ASC_ISSUER_ID }}
```

## Inputs

The **Default** column is the *effective* default — what the input resolves
to with no `config-path` and no explicit value. Inputs marked **cfg** are
loadable from `config-path`; for those, the declared `default:` in
`workflow_call` is `''` and the literal below is applied at resolution time
(see [Precedence](#precedence)).

| Name                          | Required | Default                             | Description |
| -------------------------------- | -------- | -------------------------------------- | -------------- |
| `config-path`                      | no       | `''`                                     | Repository-relative path to a JSON config file holding this workflow's app-shaped configuration; see [Config file](#config-file). Empty (the default) changes nothing. |
| `runner-labels`                    | no       | `["self-hosted","macOS","ARM64"]`         | JSON array of self-hosted runner labels for the iOS build/capture jobs. |
| `build-runner-labels`               | no       | `''`                                     | JSON array of runner labels for the iOS build job (and the Android build job, unless `android-build-runner-labels` is set). Falls back to `runner-labels`. |
| `capture-runner-labels`             | no       | `''`                                     | JSON array of runner labels for the **iOS** capture job only (Android uses `android-capture-runner-labels` — a deliberate asymmetry, the pools can never overlap). Falls back to `runner-labels`. Must be an arm64 macOS pool. |
| `upload-runner-labels`              | no       | `''`                                     | JSON array of runner labels for the gated upload job. Falls back to `runner-labels`. |
| `ios-target`                        | when the manifest has iOS entries | `''`   | Single iOS build target JSON object: `{name, appDir, workspace, scheme, appId, prebuildCommand}`. Renamed from `target` in v1.6.0. **cfg** |
| `android-target`                    | when the manifest has Android entries | `''` | Single Android build target JSON object: `{name, appDir, appId, prebuildCommand}` — the same per-target shape as `android-maestro.yml`'s `targets` entries. **cfg** |
| `capture-manifest`                  | **yes**, as the input or a `config-path` key | — | JSON array of capture matrix entries, one job per entry; see [capture-manifest](#capture-manifest). Declared `required: false` since v1.11.0 so it can come from `config-path` instead; an empty resolved value still fails closed. **cfg** |
| `capture-mode`                      | no       | `flows`                                   | `flows` (legacy discovery, iOS-only) or `direct` (scene-manifest-driven). Anything else fails closed. **cfg** |
| `capture-scenes`                    | when `capture-mode: direct` | `''`          | JSON array of scenes; see [capture-scenes](#capture-scenes-direct-mode). Fails closed if set in `flows` mode. **cfg** |
| `seed-command`                      | no       | `''`                                     | Per-cell seed hook, direct mode only (fails closed in `flows` mode); see [Seed hook contract](#seed-hook-contract). **cfg** |
| `settle-seconds`                    | no       | `3`                                       | Seconds (integer 0–120) between a deep-link launch and its screenshot; per-scene `settleSeconds` overrides it. **cfg** |
| `deeplink-confirm-title`            | no       | `Open in .*\?`                            | iOS direct mode only. Maestro text pattern matching the title of the [open-confirmation sheet](#ios-open-confirmation-sheet); tapped away and then asserted gone before every deep-link screencap. The trailing `\?` anchors the default to the sheet's own title rather than to app content that merely starts with `Open in`. Fails closed when the simulator's own language is not English and this or `deeplink-confirm-button` is still the default. **cfg** |
| `deeplink-confirm-button`           | no       | `Open`                                    | iOS direct mode only. Label of the confirm button on the sheet matched by `deeplink-confirm-title`. Also fails closed when the simulator's own language is not English and it is still the default. **cfg** |
| `status-bar-override`               | no       | `true`                                    | Store-clean status bar in both modes (iOS `simctl status_bar` 9:41 override; Android SystemUI demo mode). Fails closed if it cannot be applied. **cfg** |
| `apple-screenshot-slots`            | no       | `''`                                     | JSON object `{"<W>x<H>": "<slot-label>"}`; non-empty enables the fail-closed upload-job resolution check. See [apple-screenshot-slots](#apple-screenshot-slots). **cfg** |
| `screenshots-dir`                   | in `flows` mode, or when a scene has a `flow` | `''` | Scene-discovery root (`flows` mode) / the directory flow-backed scenes resolve against (`direct` mode). **cfg** |
| `scenes-name-pattern`               | no       | `*.flow.yaml`                             | Space-separated `find -name` globs selecting scenes directly inside `screenshots-dir` (`flows` mode only). |
| `scenes-exclude-pattern`            | no       | `''`                                     | Optional `find ! -name` glob excluding matched scenes by basename (`flows` mode only). |
| `maestro-env`                       | no       | `''`                                     | Newline-separated `KEY=VALUE` pairs, each passed as an additional `-e KEY=VALUE` argument on top of the always-passed `APP_ID`/`LOCALE`/`APPEARANCE` (flow-backed scenes in either mode). Fails closed on a malformed line or a reserved-name override. **cfg** |
| `maestro-config`                    | no       | `''`                                     | Path to the consumer's Maestro workspace config (`config.yaml`), passed as `--config` to every `maestro test` invocation. Maestro only auto-discovers a workspace `config.yaml` when it is pointed at a **directory**, and the actions below always pass individual flow files, so without this input a workspace config is silently ignored — e.g. `platform.ios.snapshotKeyHonorModalViews: false`, which an `@expo/ui` SwiftUI `.sheet()` modal needs before its React Native content appears in the XCUITest hierarchy at all. Relative paths resolve against the job's working directory. Fails closed when set to a path that is not a file. Passed to both capture actions. **cfg** |
| `maestro-version`                   | no       | `2.8.0`                                   | Pinned Maestro CLI version; still used by flow-backed scenes in either mode, installed lazily in direct mode — on iOS also for deep-link scenes, which need it for the [open-confirmation sheet](#ios-open-confirmation-sheet) check. |
| `post-capture-command`              | no       | `''`                                     | Optional consumer-owned command run in each capture job (both platforms) after capture, before upload — e.g. a device-bezel framing script. Runs with `SCREENSHOTS_OUTPUT_DIR` and `DEVICE_SLUG` in its environment. Its failure fails the capture job. |
| `xcode-version`                     | no       | `26.4.1`                                  | Xcode version string. |
| `xcode-build`                       | no       | `17E202`                                  | Xcode build number. |
| `cache-profile`                     | no       | `ios-native-v1`                           | Cache-key prefix distinguishing this consumer/app (iOS build). **cfg** |
| `expo-fingerprint-version`          | no       | `0.20.6`                                  | Pinned `@expo/fingerprint` npm version. |
| `node-version`                      | no       | `22.x`                                    | Node version for `actions/setup-node`. |
| `install-command`                   | no       | `yarn install --immutable`                | JS dependency install command. **cfg** |
| `enable-corepack`                   | no       | `true`                                    | Run `corepack enable` before install. Skipped when the resolved package manager is `pnpm` (provisioned by `pnpm/action-setup`). |
| `package-manager`                   | no       | `''` (auto-detect)                        | Override the JS package manager (`yarn`, `pnpm`, `npm`). Empty auto-detects at the repo root: `devEngines.packageManager` / `packageManager` in `package.json` (needs `jq` on the runner), else exactly one root lockfile (`yarn.lock` / `pnpm-lock.yaml` / `package-lock.json` or `npm-shrinkwrap.json`); no match, an ambiguous match or an unsupported value fails the job. Drives pnpm provisioning and, in the jobs that configure one, `actions/setup-node`'s `cache:` — set `install-command` to match (e.g. `pnpm install --frozen-lockfile`). Resolving to `pnpm` also requires a pnpm version in `package.json`. See [Package manager](../../README.md#package-manager). |
| `build-command`                     | no       | `''`                                     | Optional workspace JS build command run at repo root before the native build (both build jobs). **cfg** |
| `rct-use-prebuilt-rncore`           | no       | `false`                                    | Exports `RCT_USE_PREBUILT_RNCORE=1` for the iOS `expo prebuild` step, `pod install`, and the iOS build step when `true`; exports nothing at all otherwise (an empty export reads as *enabled* on the Ruby side). **cfg** |
| `rct-use-rn-dep`                    | no       | `false`                                    | Exports `RCT_USE_RN_DEP=1` for the iOS `expo prebuild` step, `pod install`, and the iOS build step when `true`; exports nothing at all otherwise (an empty export reads as *enabled* on the Ruby side). **cfg** |
| `expo-use-precompiled-modules`      | no       | `false`                                    | Exports `EXPO_USE_PRECOMPILED_MODULES=1` for the iOS `expo prebuild` step, `pod install`, and the iOS build step when `true`; exports nothing at all otherwise (an empty export reads as *enabled* on the Ruby side). |
| `ccache-max-size`                   | no       | `2G`                                     | Bounded, compressed ccache maximum size (iOS build). |
| `build-env`                         | no       | `''`                                     | Newline-separated `KEY=VALUE` pairs appended to `$GITHUB_ENV` at the start of each build job. Fails closed on a malformed line. **cfg** |
| `repack-on-hit`                     | no       | `false`                                    | On a native-app-cache hit (either platform), run `repack-app` instead of reusing the cached shell unchanged. **cfg** |
| `repack-app-version`                | no       | `0.7.2`                                    | Pinned `@expo/repack-app` npm version, used only when `repack-on-hit` is true. |
| `build-timeout-minutes`             | no       | `60`                                      | iOS build job timeout. |
| `capture-timeout-minutes`           | no       | `90`                                      | iOS capture job timeout. Default is generous: one job runs the full `locales x appearances x scenes` loop on a single booted simulator. |
| `android-build-runner-labels`       | no       | `''`                                     | Runner labels for the Android build job. Fallback chain: this → `build-runner-labels` → `runner-labels`. |
| `android-capture-runner-labels`     | no       | `["self-hosted","linux-tiered","linux-xl"]` | Runner labels for the Android capture job (the Redroid pool). No fallback to `runner-labels`. |
| `android-cmdline-tools-version`     | no       | `12266719`                                | See `build-android-app` README — pin explicitly. |
| `android-gradle-task`               | no       | `assembleRelease`                         | `gradlew` task for the Android build. **cfg** |
| `android-gradle-args`               | no       | `''`                                     | Extra whitespace-split arguments appended after `android-gradle-task`. **cfg** |
| `android-cache-profile`             | no       | `android-native-v1`                       | Cache-key prefix for the Android build (`cache-profile` stays iOS-only). **cfg** |
| `android-build-tools-version`       | no       | `35.0.0`                                  | Build-tools installed on a cache hit for repack-app's aapt2 validation; used only when `repack-on-hit` is true. |
| `android-build-tools-dir`           | no       | `''`                                     | Explicit build-tools dir for repack-app; used only when `repack-on-hit` is true. |
| `android-build-timeout-minutes`     | no       | `60`                                      | Android build job timeout. |
| `android-capture-timeout-minutes`   | no       | `90`                                      | Android capture job timeout. |
| `redroid-image`                     | no       | `redroid/redroid:15.0.0_64only-latest`    | Redroid image tag, used on a prewarm-manifest miss. Must resolve to API 33+. |
| `redroid-memory`                    | no       | `3g`                                      | Container memory limit. |
| `redroid-cpus`                      | no       | `2`                                       | Container CPU limit. |
| `redroid-prewarm-manifest-path`     | no       | `$HOME/.rnw-ci/android-emulator.json`     | Host-side prewarm manifest path; see [docs/self-hosted-runners.md](../self-hosted-runners.md). |
| `redroid-boot-timeout-seconds`      | no       | `600`                                     | Seconds to wait for `sys.boot_completed`. |
| `upload-screenshots`                | no       | `false`                                    | Run the gated upload job. **cfg** |
| `upload-command`                    | no       | `''`                                     | Consumer-owned command run in the upload job, e.g. `bundle exec fastlane ios ios_screenshots`. Required when `upload-screenshots` is `true`; runs in the resolved app dir (`ios-target`'s `appDir` when set, `android-target`'s otherwise) with `SCREENSHOTS_DIR` (the resolved `screenshots-download-dir`) in its environment. **cfg** |
| `screenshots-download-dir`          | no       | `fastlane/screenshots/raw`                 | Path, relative to the resolved app dir, every capture job's artifact is merged into before `upload-command` runs — iOS under its `ios/` subdirectory, Android under `android/`. **cfg** |
| `asc-key-path`                      | no       | `''`                                     | Optional path, relative to the resolved app dir, the App Store Connect API key (`.p8`) is written to and removed from for `upload-command`. Leave empty (default) to write it under `$RUNNER_TEMP` instead. |
| `publish-env`                       | no       | `''`                                     | Newline-separated `KEY=VALUE` pairs of non-secret env appended to `$GITHUB_ENV` at the start of the upload job. Fails closed on a malformed line. For secret values use `EAS_EXTRA_ENV` instead. **cfg** |
| `asc-dedupe-screenshots`            | no       | `false`                                   | Post-upload App Store Connect duplicate-screenshot verification/repair gate; see [App Store Connect dedupe gate](#app-store-connect-dedupe-gate). Requires `ASC_API_KEY` + `ASC_KEY_ID` + `ASC_ISSUER_ID` secrets and an `ios-target`. **cfg** |
| `asc-dedupe-version-state`          | no       | `PREPARE_FOR_SUBMISSION`                  | Which version's localizations are deduped (`READY_FOR_SALE` audits the live listing). **cfg** |
| `asc-dedupe-app-id`                 | no       | `''` (→ `ios-target.appId`)               | Bundle id of the ASC app whose listing is deduped; set it when the capture build uses a suffixed/e2e bundle id. **cfg** |
| `asc-fail-on-duplicates`            | no       | `true`                                    | Fail the upload job when any duplicate had to be deleted; set `false` to treat a successful repair as success. **cfg** |

## Secrets

| Name                | Required | Description |
| --------------------- | -------- | -------------- |
| `EXPO_TOKEN`          | no       | Forwarded to the upload job's environment if `upload-command` needs it. |
| `ASC_API_KEY`         | no       | App Store Connect API key contents (`.p8`). When set, written to `asc-key-path` (or `$RUNNER_TEMP`) before `upload-command` runs and removed afterward - same contract as `native-publish.yml`'s `ASC_API_KEY`. Also the key the dedupe gate signs with. |
| `ASC_KEY_ID`          | with `asc-dedupe-screenshots` | App Store Connect API key ID for the dedupe gate's JWT. |
| `ASC_ISSUER_ID`       | with `asc-dedupe-screenshots` | App Store Connect API issuer ID (UUID) for the dedupe gate's JWT. |
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
                  {"device":"iPhone 17 Pro Max","locales":["en",{"id":"de","env":{"LOCALE_IDENTIFIER":"de-DE"}}],"appearances":["light","dark"]},
                  {"platform":"android","device":"phone-6.7","width":1080,"height":2340,"density":440,"locales":["en","de"],"appearances":["light","dark"]}
                ]
            capture-mode: direct
            capture-scenes: >-
                [
                  {"name":"home","deepLink":"myapp://home","readySelector":{"id":"HomeScreen.Root"}},
                  {"name":"stats","deepLink":"myapp://stats","readySelector":{"id":"StatsScreen.Root"},"settleSeconds":5},
                  {"name":"win","flow":"14.win.flow.yaml","platforms":["ios"]}
                ]
            screenshots-dir: apps/mobile/e2e/flows/screenshots
            seed-command: yarn tsx scripts/seed-app-state.ts
            apple-screenshot-slots: >-
                {"1320x2868":"IPHONE_69"}
            upload-screenshots: true
            upload-command: bundle exec fastlane ios ios_screenshots
            asc-dedupe-screenshots: true
        secrets:
            ASC_API_KEY: ${{ secrets.ASC_API_KEY }}
            ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
            ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
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
