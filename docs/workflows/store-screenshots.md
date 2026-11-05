# store-screenshots.yml

`workflow_call` reusable workflow: fleet-native store screenshot capture for
**iOS simulators leased from a simlock farm and Android emulators or Redroid
containers**. Scenes come from a `capture-scenes` JSON manifest shared across
every device entry. iOS cells are captured by your e2e project
([E2E capture](#e2e-capture)); Android cells over adb from a deep link
(app force-stopped → optional `seed-command` → launch → settle → OS screenshot).
One call captures one platform: an iOS and an Android manifest are two calls.

Nine jobs: **validate-manifest** (hosted `ubuntu-latest`; loads and resolves
the optional [config file](#config-file) — including `build-strategy` — then
fails closed on a malformed `capture-manifest`/`capture-scenes` or any
target cross-check; every downstream job reads its resolved values from
this job's outputs) → **plan-ios** and **plan-android** (each calls the
reusable [`expo-base-plan.yml`](../../.github/workflows/expo-base-plan.yml) on
the Linux repack pool for its single target — compute the native key with
[`expo-native-key`](../../actions/expo-native-key), look up the base binary
published for it with [`expo-base-binary`](../../actions/expo-base-binary),
and, when one exists, produce this run's binary from it with
[`expo-repack`](../../actions/expo-repack) instead of compiling anything; each
job's `native-targets` output is the set of targets whose key had no base) →
**build-ios** (same build-job shape as `ios-e2e.yml`'s `build` job, and it
runs **only** when `plan-ios` found no base for the `ios-target`; on the
default branch it publishes the base it just built) and **build-android** (the
same, from `plan-android` and the `android-target`) → **capture-ios** (one job per
iOS manifest entry — download the built `.app`, run your e2e project against
simulators of that device leased from simlock, one PNG per
`locales x appearances x scenes` cell, optional `post-capture-command`, upload
`raw-screenshots-ios-<device-slug>`) and
**capture-android** (one job per Android entry —
[`redroid-container`](../../actions/redroid-container/README.md) start, or
[`android-emulator`](../../actions/android-emulator/README.md) start with
`android-driver: avd` →
[`capture-screenshots-android`](../../actions/capture-screenshots-android/README.md)
→ optional `post-capture-command` → upload
`raw-screenshots-android-<device-slug>` → `if: always()` teardown) →
**upload** (gated by `upload-screenshots`; requires every platform with
manifest entries to have captured successfully — a capture job skipped by a
failed build blocks the upload, only a platform with no manifest entries may
stay skipped — merges every `raw-screenshots-*` artifact, runs an optional
[`compose-command`](#compose-command) on the collected set, optionally
validates iOS resolutions against `apple-screenshot-slots`, runs a
consumer-owned `upload-command`, and optionally verifies/repairs App Store
Connect duplicates via `asc-dedupe-screenshots`) → **status** (single required check with
honest-skip semantics: a platform's plan and capture jobs must succeed
whenever the manifest has entries for it, and its build job may be `skipped`
only when the plan found a published base for every target it names — a
skipped build with a non-empty `native-targets` is a failure; `skipped`
across the board only passes for a platform with no entries).

The normal outcome of a run is that **no build slot is taken at all**: the
plan job repacks a published base on Linux and the capture jobs install what
it uploaded. See [Build strategy](#build-strategy) below.

## capture-manifest

One capture job per entry. `platform` defaults to `"ios"` (v1.5.x manifests
keep working unchanged).

```json
[
  {"platform":"ios","device":"iPhone 17 Pro Max","locales":["en","de"],"appearances":["light","dark"],"orientation":"portrait"},
  {"platform":"ios","device":"iPad Pro 13-inch (M4)","locales":[{"id":"en"},"de"],"appearances":["light"],"orientation":"landscape"},
  {"platform":"android","device":"phone-6.7","width":1080,"height":2340,"density":440,"locales":["en","de"],"appearances":["light","dark"]}
]
```

Validation rules (all fail closed in `validate-manifest`):

- `platform` — optional, `"ios"` (default) or `"android"`.
- **iOS entries**: `device` is an exact simulator name, `locales` a non-empty array of
  non-empty strings, `appearances` ⊆ `["light","dark"]`; `orientation` must be
  absent or `portrait`.
- **Android entries**: `device` is a free-form label matching
  `^[A-Za-z0-9 ._-]+$` used **only** for the output/artifact slug — the
  actual device shape comes from required positive-integer
  `width`/`height`/`density` (applied via `wm size`/`wm density`);
  `orientation` must be absent or `portrait` (**Android landscape is a
  v1.6.0 non-goal** — the pixel-rotation bake relies on macOS-only `sips`).
- **Locale items** are plain strings (`"de"`); the same locale may not be
  listed twice in one entry.
- Device slugs (lowercased, non-alphanumeric runs collapsed to `-`) must be
  unique **per platform** — artifact names are platform-prefixed, so
  `iPhone 17 Pro` (iOS) and an Android label slugifying identically may
  coexist.
- iOS entries require `ios-target`; Android entries require
  `android-target`; at least one entry overall; at most 256 entries per
  platform.

## capture-scenes

One shared scene list; per-scene filters narrow where each scene runs.

```json
[
  {"name":"home","deepLink":"sudoku://home","readySelector":{"id":"HomeScreenSelectors.Root"}},
  {"name":"game","deepLink":"sudoku://game/continue","readySelector":{"id":"GameScreenSelectors.Root"},"settleSeconds":5},
  {"name":"win","test":"14-win"},
  {"name":"stats","deepLink":"sudoku://stats","readySelector":{"id":"StatsScreenSelectors.Root"},"platforms":["ios"],"appearances":["dark"],"locales":["en"]}
]
```

- `name` — required, `^[A-Za-z0-9_-]+$`, unique; becomes the output path
  segment `raw/<platform>/<device-slug>/<locale>/<appearance>/<name>.png`.
- Exactly one of `deepLink` (non-empty string) or `test` (an e2e scene name,
  `^[A-Za-z0-9_.-]+$`, iOS only; see [E2E capture](#e2e-capture)). Any other
  driver, such as a `flow` key, fails closed.
- `readySelector` — **required on every `deepLink` scene that applies to
  `ios`, rejected on `test` scenes** (a test asserts its own readiness).
  Either a non-empty string, matched as text/regex, or an object
  `{"id": "<testID>"}` matched by accessibility id. The capture waits for it
  to be visible before the screenshot, and the cell fails closed if it never
  appears. Pick an element the scene renders unconditionally: a screen root is
  a better anchor than a value that a setting can hide.

  When a cell fails this check the job fails, but the
  `raw-screenshots-<platform>-<device-slug>` artifact is still uploaded with
  whatever cells did succeed (`if: always()`), so a failed capture can be
  diagnosed from the pixels that were produced rather than from the log
  alone.

  Android capture does not consume `readySelector` yet, so it is required
  only of scenes that apply to `ios`; an `android`-only deep-link scene may
  omit it, and a shared scene's selector is simply ignored on the Android
  leg.
- Optional `settleSeconds` — integer 0–120, overriding the workflow-level
  `settle-seconds` for deep-link scenes.
- Optional `platforms` — non-empty subset of `["ios","android"]`; default
  both. Every platform with manifest entries must be covered by at least one
  scene.
- Optional `locales`/`appearances` — filters; the scene is captured only for
  cells in the intersection with the device entry's lists.

## Seed hook contract

`seed-command` (Android only; an iOS capture seeds from its e2e project and
fails closed if one is set) runs once per `locale x appearance x scene` cell,
from the repo root, with the app installed and force-stopped, before the scene's
launch. A seed failure marks that cell failed closed — no capture, no retry
— and the capture job fails at the end. Environment:

| Var              | Value |
| ----------------- | -------------- |
| `SCENE`           | scene name |
| `LOCALE`          | current locale |
| `APPEARANCE`      | `light`/`dark` |
| `APP_ID`          | application id |
| `PLATFORM`        | `android` |
| `DEVICE_SLUG`     | slugified device |
| `ANDROID_SERIAL`  | adb serial of the Android device |
| `APK_PATH`        | packaged `.apk` path |

Reference recipe (a redux-persist state in expo-sqlite): `adb pull` the DB, rewrite it, `adb push` it back, and delete
any stale `-wal`/`-shm` sidecar files so SQLite does not replay them over
the seeded state. To rewrite the DB the hook can shell out to a host
`sqlite3` binary, or — on Node >= 22.13 — use the built-in `node:sqlite`
module with no host prerequisite at all. **Redroid's stock image does
_not_ run adbd as root** — `adb pull`/`push` into
`/data/data/<app-id>/...` is denied until the hook elevates: run
`adb root` first, and because that restarts adbd (dropping a TCP serial's
connection), retry `adb connect "$ANDROID_SERIAL"` and probe
`adb shell id` until it reports `uid=0` before touching app data.

**Persisted-state migration pitfall.** If the fixture the seed hook writes
carries a state-management library's own persisted-version marker (e.g.
redux-persist), do not stamp it with the *live* app's current persist
version — that skips every migration between the fixture's actual shape and
what the running app expects, so the seeded state silently lacks fields a
later migration would have backfilled. suuudokuuu#388 hit this as a
`SpringBoard` capture: a screen crashed at render on every locale/appearance
cell because a field a migration normally adds was simply absent. Stamp the
fixture with a baseline version *below* its own state instead, so the
persistence library runs the newer migrations against it on the app's first
launch after seeding — the same path a real upgrading user goes through —
and verify those migrations are safe no-ops against the fixture's actual
values before relying on this.

## E2E capture

The iOS cells are captured by your
[tester-army e2e](https://github.com/tester-army/e2e) project: one Linux job per
`capture-manifest` iOS entry (`capture-ios`) leases simulators of that `device`
from simlock, the same way
[ios-e2e.yml's e2e suite](ios-e2e.md#e2e-suite-on-simlock) does. The app is
built or repacked as usual, and the upload job is unchanged. `e2e-dir`,
`simlock-url` and the `simlock-token` secret are required with iOS entries.

Scenes name what drives them:

- `deepLink` (with its required `readySelector`) — the suite opens the link
  and waits for the selector, then settles `settleSeconds`.
- `test` — the name of a scene your e2e project implements (a walk from a
  freshly launched app to the screen). `test` is refused on an Android capture.

`seed-command` is refused too: there is no capture host to run it on, so the
suite seeds each cell itself on the leased simulator.

The job writes a plan, a JSON array with one object per
locale × appearance × scene cell, filtered by each scene's `platforms`,
`locales` and `appearances` exactly:

```json
[{"scene":"01-home","locale":"en","appearance":"light","settleSeconds":6,
  "deepLink":"myapp://","readySelector":{"id":"Home.Root"},
  "path":"/home/runner/work/app/app/screenshots-output/raw/ios/iphone-17-pro-max/en/light/01-home.png"},
 {"scene":"03-analytics","locale":"en","appearance":"light","settleSeconds":6,"test":"03-analytics",
  "path":".../raw/ios/iphone-17-pro-max/en/light/03-analytics.png"}]
```

`e2e-command` runs in `e2e-dir` with:

| Variable | Value |
| --- | --- |
| `SCREENSHOT_PLAN` | absolute path of the plan |
| `SCREENSHOT_DEVICE` / `SCREENSHOT_DEVICE_SLUG` | the entry's `device` (lease that model) and its slug |
| `SCREENSHOT_STATUS_BAR` | `override` (9:41, full bars, charged) or `real`, from `status-bar-override` |
| `E2E_APP_PATH`, `E2E_APP_ID`, `E2E_TARGET` | the `.app`, `ios-target.appId` and `ios-target.name` |
| `E2E_WORKERS`, `E2E_RETRIES`, `E2E_SESSION` | as in [ios-e2e.yml](ios-e2e.md#e2e-suite-on-simlock) |
| `SIMLOCK_URL`, `SIMLOCK_TOKEN` | the farm |

It must write each cell's PNG to its `path` (a recorded clip may sit beside
it as `<scene>.mp4`). The job fails closed when the command fails, when its
report (`e2e-dir/.e2e/report.json`) is missing, executed nothing or did not
pass, and when any planned path holds no PNG. `post-capture-command` then
runs, and `raw-screenshots-ios-<device-slug>` is uploaded, so `apple-screenshot-slots`, `compose-command` and
the upload see no difference. The e2e report is uploaded as
`e2e-screenshots-ios-<device-slug>`, and leases a cancelled run left behind
are released from `e2e-dir/.e2e/simlock-leases.json`. As in the e2e job,
[`@mobile-ci/e2e-simlock`](../../packages/e2e-simlock/README.md) is installed
into `e2e-dir` from this workflow's tag after `e2e-install-command`, so the
same e2e project captures and tests.

```yaml
jobs:
    screenshots:
        permissions:
            contents: read
            packages: write
            actions: read
        uses: rnw-community/mobile-ci/.github/workflows/store-screenshots.yml@v5.0.0 # v5.0.0
        with:
            control-runner-labels: '["self-hosted","linux"]'
            config-path: .github/store-screenshots.config.json
            e2e-dir: e2e
            e2e-runner-labels: '["self-hosted","linux","4x8"]'
            e2e-command: npx e2e run --config media.config.ts --target ios
            e2e-workers: '4'
            simlock-url: https://simlock.vitaliiyehorov.dev
        secrets:
            simlock-token: ${{ secrets.SIMLOCK_TOKEN }}
```

## Android capture

`android-driver` picks the device the capture job boots; the capture itself
(`wm size`/`wm density`, per-app locales, demo-mode status bar, the scene
loop) is identical on both:

- **`redroid`** — a Redroid container via
  [`redroid-container`](../../actions/redroid-container/README.md),
  configured by the `redroid-*` inputs. Needs a Linux Redroid host per
  [docs/self-hosted-runners.md](../self-hosted-runners.md) (binder_linux
  module, privileged containers, prewarm manifest).
- **`avd`** (default) — Google's emulator via
  [`android-emulator`](../../actions/android-emulator/README.md), configured by
  the `emulator-*` inputs. Needs an x86_64 Linux runner with `/dev/kvm` and no Docker, privileged
  container or `binder_linux`. It fails closed on another architecture, and
  when `emulator -accel-check` reports no hardware acceleration. The guest's
  RAM and cores are derived from the capture container's cgroup limits unless
  set, `emulator-slots-dir` caps emulators per host, and the always-run stop kills only this job's emulator
  processes. Every capture job boots a dedicated `mobile-ci-screenshots` AVD
  with `-wipe-data`, so no app state or device-wide setting crosses between a
  capture job and another job sharing a persistent host. A `google_apis`
  image carries real Google Play Services, which Redroid's stock images do
  not (see the rendering caveat below).

`android-capture-runner-labels` must name a pool for the chosen driver.
The default is `["self-hosted","trf-linux-amd64-4x8"]`, the x86_64 Linux KVM
pool, matching the default `avd` driver.

### Migrating from the Redroid defaults

This default change requires a major release. Existing callers that use a
Redroid host must pin both inputs when upgrading:

```yaml
with:
    android-driver: redroid
    android-capture-runner-labels: '["self-hosted","linux-tiered","linux-xl"]'
```

Use your fleet's own Redroid labels if they differ. Callers moving to the
x86_64 KVM pool can omit both inputs. Explicit `redroid-*` settings remain
available when `android-driver: redroid` is selected.

- `android-capture-runner-labels` deliberately does **not** fall back to
  `runner-labels`, whose macOS default can run neither driver.
- The Android **build** happens elsewhere: `android-build-runner-labels` →
  `build-runner-labels` → `runner-labels` (the macOS default is correct —
  Google publishes no `linux-aarch64` NDK/cmake, so the Redroid pool cannot
  build).
- The device must run **API 33+** (`cmd locale set-app-locales`);
  `capture-screenshots-android` fails closed below that. The default
  `redroid/redroid:15.0.0_64only-latest` image (API 35) and the default
  `emulator-api-level` (34) are both fine.
- `status-bar-override` maps to SystemUI demo mode (clock 09:41, full wifi,
  no mobile data type, battery 100% unplugged, notifications hidden).
- **Rendering fidelity caveat** (`redroid`): Redroid runs with guest-mode GPU rendering
  and a GMS-free image — an app that hard-depends on Play services may
  render "Play services required" dialogs into its screenshots. Validate
  captures against a local emulator before shipping them to a listing.

## compose-command

Optional consumer-owned command, run in the upload job once every capture job's
artifact is merged under `screenshots-download-dir`. It runs before the
`apple-screenshot-slots` check and before `upload-command`. This is the hook
for composing the store set from the collected raw captures: framing each
device, adding captions, laying out the canvas. Whatever it writes is then
checked against the slots and uploaded. It runs in the resolved app directory
with `SCREENSHOTS_DIR` (the resolved `screenshots-download-dir`) in its
environment. Its failure fails the upload job. It only runs when the upload job
runs, which needs `upload-screenshots: true`. Empty (the default) composes
nothing and leaves the upload job unchanged.

It is consumer-owned code with the same trust as `upload-command`: it is
`eval`ed with the upload job's environment, which includes the `EXPO_TOKEN`
secret (set job-wide) and every `publish-env` and `EAS_EXTRA_ENV` variable
(exported through `$GITHUB_ENV` before it runs). The `ASC_API_KEY`,
`ASC_KEY_ID` and `ASC_ISSUER_ID` secrets are not in its environment. Do not
build it from untrusted data such as a pull request title or branch name.

Use it to call your own composer, or mobile-ci's
[`compose-media`](../../actions/compose-media/README.md) scripts fetched at a
pinned tag. Captions and store copy are always the consumer's; the shared
scripts only frame the device:

```yaml
compose-command: |
    ref=<mobile-ci tag>
    media="$RUNNER_TEMP/mobile-ci-media"
    mkdir -p "$media"
    for f in media-common.sh frame-device.sh; do
        curl -fsSL "https://raw.githubusercontent.com/rnw-community/mobile-ci/$ref/scripts/media/$f" -o "$media/$f"
    done
    bash "$media/frame-device.sh" --input-dir "$SCREENSHOTS_DIR/ios/iphone-17-pro-max" \
        --output-dir fastlane/screenshots/framed/ios --background '#F8F8F8-#F1F1F1' --fit 0.78
```

The upload runner needs the composer's tools: ImageMagick 7 and fastlane's
frameit assets (`fastlane frameit download_frames`) for the example above.
`post-capture-command` is the per-capture-job counterpart. It sees one
device's captures before they are uploaded as an artifact, whereas
`compose-command` sees the merged set from every device.

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
version this run just uploaded to; use `READY_FOR_DISTRIBUTION` to audit the
live listing - the deprecated `READY_FOR_SALE` is still accepted and translated), groups each set by file name, deletes all but the oldest copy of
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

## Config file

Everything app-shaped about a caller — targets, manifest, scenes, build and
upload knobs — can live in a checked-in JSON file instead of being passed as
JSON-in-YAML string blobs through `with:`. Point `config-path` at it:

```yaml
jobs:
    screenshots:
        uses: rnw-community/mobile-ci/.github/workflows/store-screenshots.yml@v5.0.0 # v5.0.0
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
Either associate it by filename in your editor's `json.schemas` settings, or
add a top-level `"$schema"` key pointing at it directly in the config file —
`load-consumer-config` strips `$schema` before checking the file against the
loadable-key allowlist (see below), so it is tolerated without needing to be
(and must not be) added to that list. The schema is a convenience only; the
workflow's own `jq` allowlist is the source of truth and the only thing CI
runs.

### Precedence

**explicit workflow input > config file value > built-in default.**

Every config-loadable input whose old `default:` was a non-empty literal
(`settle-seconds`, `install-command`,
`android-gradle-task`,
`build-strategy`, `screenshots-download-dir`, `asc-dedupe-version-state`) now
declares
`default: ''` and applies that literal at resolution time instead. **The
effective default is unchanged** — a caller that passes no `config-path` and
no value for these behaves exactly as before.

`build-strategy` is the one exception to that guarantee: a caller with neither
a `config-path` entry nor an explicit value resolves to `auto` and repacks a
published base, where v2 compiled natively. That is the behaviour change this
major exists for — see [Migrating from v2](#migrating-from-v2).

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
- **Booleans:** the six boolean keys (`status-bar-override`,
  `rct-use-prebuilt-rncore`, `rct-use-rn-dep`, `upload-screenshots`,
  `asc-dedupe-screenshots`, `asc-fail-on-duplicates`)
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

Exactly these 33 keys may appear in the config file (plus the tolerated
`$schema` key described above, which is not a workflow input and is stripped
before this list is checked). Anything else fails closed:

`ios-target`, `android-target`, `capture-manifest`,
`capture-scenes`, `seed-command`, `settle-seconds`,
`status-bar-override`, `apple-screenshot-slots`, `build-env`, `install-command`, `build-command`,
`android-gradle-task`,
`android-gradle-args`, `build-strategy`, `rct-use-prebuilt-rncore`,
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
- An Android capture assumes you already have a working
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
                "en",
                "de",
                "es",
                "fr",
                "pt",
                "sv",
                "hi",
                "ar",
                "id"
            ],
            "appearances": ["light"]
        }
    ],
    "capture-scenes": [
        { "name": "home", "deepLink": "suuudokuuu://", "readySelector": { "id": "HomeScreenSelectors.Root" } },
        { "name": "game", "deepLink": "suuudokuuu://game", "readySelector": { "id": "GameScreenSelectors.Root" } },
        { "name": "stats", "deepLink": "suuudokuuu://history", "readySelector": { "id": "HistoryScreenSelectors.Root" } }
    ],
    "settle-seconds": 5,
    "status-bar-override": true,
    "rct-use-prebuilt-rncore": true,
    "rct-use-rn-dep": true,
    "build-env": "APP_VARIANT=production\n",
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
        uses: rnw-community/mobile-ci/.github/workflows/store-screenshots.yml@v5.0.0 # v5.0.0
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
        uses: rnw-community/mobile-ci/.github/workflows/store-screenshots.yml@v5.0.0 # v5.0.0
        with:
            config-path: .github/store-screenshots.config.json
            build-runner-labels: '["self-hosted","macOS","ARM64","macos-builder"]'
            e2e-runner-labels: '["self-hosted","linux-portable-4x8"]'
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
| `runner-labels`                    | no       | `["self-hosted","macOS","ARM64"]`         | JSON array of self-hosted runner labels for the iOS build job. |
| `control-runner-labels` | no | `'["ubuntu-latest"]'` | JSON array of runner labels for the lightweight control jobs (detect/status/collect/validate-manifest/cancel-queued-runs), which need no self-hosted hardware. Set it when the org has no hosted runners, e.g. an ephemeral RunsOn label set; it is passed on to `expo-base-plan.yml` by the workflows that call it. |
| `runs-on-cache-bypass` | no | `false` | Opt-in. When a job lands on a RunsOn runner started with `extras=s3-cache`, whose cache proxy takes over the Actions results URL and breaks `actions/upload-artifact`/`download-artifact`, run a SHA-pinned `runs-on/action` first (via the [`runs-on-cache-bypass`](../../actions/runs-on-cache-bypass/README.md) action). A logged no-op on every other runner. |
| `build-runner-labels`               | no       | `''`                                     | JSON array of runner labels for the iOS build job (and the Android build job, unless `android-build-runner-labels` is set). Falls back to `runner-labels`. |
| `ios-simulator-archs`               | no       | `arm64`                                   | Simulator slice the iOS build produces: `arm64` or `x86_64`, anything else fails closed. Same contract as [`ios-e2e.yml`'s](ios-e2e.md#x86_64-simulator-builds): `x86_64` builds with `EXCLUDED_ARCHS=arm64`, gets its own native key, and the capture job checks the host can run it (natively, or under Rosetta 2) before a simulator boots. |
| `upload-runner-labels`              | no       | `''`                                     | JSON array of runner labels for the gated upload job. Falls back to `runner-labels`. |
| `ios-target`                        | when the manifest has iOS entries | `''`   | Single iOS build target JSON object: `{name, appDir, workspace, scheme, appId, prebuildCommand}`. Renamed from `target` in v1.6.0. **cfg** |
| `android-target`                    | when the manifest has Android entries | `''` | Single Android build target JSON object: `{name, appDir, appId, prebuildCommand}` — the same per-target shape as `android-e2e.yml`'s `targets` entries. **cfg** |
| `capture-manifest`                  | **yes**, as the input or a `config-path` key | — | JSON array of capture matrix entries, one job per entry; see [capture-manifest](#capture-manifest). Declared `required: false` since v1.11.0 so it can come from `config-path` instead; an empty resolved value still fails closed. **cfg** |
| `capture-scenes`                    | **yes** | `''`          | JSON array of scenes; see [capture-scenes](#capture-scenes). **cfg** |
| `seed-command`                      | no       | `''`                                     | Per-cell seed hook, Android only (fails closed with iOS entries); see [Seed hook contract](#seed-hook-contract). **cfg** |
| `settle-seconds`                    | no       | `3`                                       | Seconds (integer 0–120) between a deep-link launch and its screenshot; per-scene `settleSeconds` overrides it. **cfg** |
| `status-bar-override`               | no       | `true`                                    | Store-clean status bar (Android SystemUI demo mode; an iOS capture sets its own in the e2e project). Fails closed if it cannot be applied. **cfg** |
| `apple-screenshot-slots`            | no       | `''`                                     | JSON object `{"<W>x<H>": "<slot-label>"}`; non-empty enables the fail-closed upload-job resolution check. See [apple-screenshot-slots](#apple-screenshot-slots). **cfg** |
| `e2e-dir` | with `e2e` | `''` | Directory of the e2e project (its `package.json`, lockfile and e2e config), relative to the repository root. |
| `e2e-runner-labels` | no | `''` (falls back to `control-runner-labels`) | JSON array of Linux runner labels for the e2e capture job; any runner with Node that reaches `simlock-url`. It hosts one worker per leased device. |
| `e2e-node-version` | no | `^24.8.0` | Node.js version the e2e capture job runs the e2e project with. |
| `e2e-install-command` | no | `npm ci --no-audit --no-fund` | Installs the e2e project's dependencies, in `e2e-dir`. |
| `e2e-command` | no | `npx e2e run --target ios` | Captures one device's cells, in `e2e-dir`. Gets the [capture contract](#e2e-capture); must write every planned PNG and its report under `e2e-dir/.e2e`. |
| `e2e-workers` | no | `1` | Devices leased and cells captured at once per device entry (`E2E_WORKERS`), lowered to the farm's free capacity when the farm reports it. |
| `e2e-retries` | no | `1` | Retries per failed cell inside the run (`E2E_RETRIES`). |
| `simlock-url` | with `e2e` | `''` | Base URL of the simlock gateway the e2e capture leases simulators from (`SIMLOCK_URL`). |
| `post-capture-command`              | no       | `''`                                     | Optional consumer-owned command run in each capture job (both platforms) after capture, before upload — e.g. a device-bezel framing script. Runs with `SCREENSHOTS_OUTPUT_DIR` and `DEVICE_SLUG` in its environment. Its failure fails the capture job. |
| `xcode-version`                     | no       | `26.4.1`                                  | Xcode version string. |
| `xcode-build`                       | no       | `17E202`                                  | Xcode build number. |
| `expo-fingerprint-version`          | no       | `0.20.6`                                  | Pinned `@expo/fingerprint` npm version. |
| `node-version`                      | no       | `22.x`                                    | Node version for `actions/setup-node`. |
| `install-command`                   | no       | `yarn install --immutable`                | JS dependency install command. **cfg** |
| `enable-corepack`                   | no       | `true`                                    | Run `corepack enable` before install. Skipped when the resolved package manager is `pnpm` (provisioned by `pnpm/action-setup`). |
| `package-manager`                   | no       | `''` (auto-detect)                        | Override the JS package manager (`yarn`, `pnpm`, `npm`). Empty auto-detects at the repo root: `devEngines.packageManager` / `packageManager` in `package.json` (needs `jq` on the runner), else exactly one root lockfile (`yarn.lock` / `pnpm-lock.yaml` / `package-lock.json` or `npm-shrinkwrap.json`); no match, an ambiguous match or an unsupported value fails the job. Drives pnpm provisioning and, in the jobs that configure one, the package-manager dependency cache (`node-pm-cache`: restored on every event, saved only off pull requests) — set `install-command` to match (e.g. `pnpm install --frozen-lockfile`). Resolving to `pnpm` also requires a pnpm version in `package.json`. See [Package manager](../../README.md#package-manager). |
| `build-command`                     | no       | `''`                                     | Optional workspace JS build command run at repo root before the native build (both build jobs). **cfg** |
| `rct-use-prebuilt-rncore`           | no       | `false`                                    | Exports `RCT_USE_PREBUILT_RNCORE=1` for the iOS `expo prebuild` step, `pod install`, and the iOS build step when `true`; exports nothing at all otherwise (an empty export reads as *enabled* on the Ruby side). **cfg** |
| `rct-use-rn-dep`                    | no       | `false`                                    | Exports `RCT_USE_RN_DEP=1` for the iOS `expo prebuild` step, `pod install`, and the iOS build step when `true`; exports nothing at all otherwise (an empty export reads as *enabled* on the Ruby side). **cfg** |
| `expo-use-precompiled-modules`      | no       | `false`                                    | Exports `EXPO_USE_PRECOMPILED_MODULES=1` for the iOS `expo prebuild` step, `pod install`, and the iOS build step when `true`; exports nothing at all otherwise (an empty export reads as *enabled* on the Ruby side). |
| `ccache-max-size`                   | no       | `2G`                                     | Bounded, compressed ccache maximum size (iOS build). |
| `build-env`                         | no       | `''`                                     | Newline-separated `KEY=VALUE` pairs appended to `$GITHUB_ENV` at the start of each build job. Fails closed on a malformed line. **cfg** |
| `build-strategy`                    | no       | `auto`                                    | How this run gets the binaries its capture jobs install, on both platforms. `auto` computes the native key, looks up the base binary published for it, and repacks that base with this run's JavaScript on the Linux pool; only a key with no published base reaches a build job — and when it does on the default branch, the base it builds is published for the next run. `repack` refuses to compile native code at all: a missing base fails the plan job instead of quietly taking a build slot. `native` is the escape hatch and a regression — every run then compiles native code again, and that run publishes no base. See [Build strategy](#build-strategy). **cfg** |
| `repack-runner-labels`              | no       | `["self-hosted","trf-linux-amd64-2x4"]`   | JSON array of self-hosted runner labels for the `plan-ios`/`plan-android` repack jobs of both platforms. The default is the 2 vCPU / 4 GiB x86_64 pool without `/dev/kvm`, so these jobs never queue on the KVM emulator lane ([#169](https://github.com/rnw-community/mobile-ci/issues/169)); keep it x86_64 (Google ships Android build-tools for x86_64 Linux only) and move to the 4x8 pool if bundling the JavaScript needs more than about 3 GiB. |
| `native-build-label`                | no       | `mobile: force native build`              | Pull-request label forcing `build-strategy: native` for that one pull request. Set together with `build-strategy: repack` it fails closed rather than silently picking a winner. Only a `pull_request` event carries labels; on `workflow_dispatch`/`schedule` runs it is inert. |
| `base-backend`                      | no       | `ghcr`                                    | Where base binaries live: `ghcr` (an immutable OCI artifact needing `packages: write` to publish and `packages: read` to fetch) or `artifact` (workflow artifacts, default-branch runs only, needing `actions: read`). See [`expo-base-binary`](../../actions/expo-base-binary). |
| `base-flavor`                       | no       | `e2e`                                     | Flavor segment of the base binary's address. |
| `fingerprint-config`                | no       | `fingerprint.config.js`                   | Path, relative to a target's `appDir`, of the `@expo/fingerprint` config whose ignore list is the correctness boundary of every repack. Its hash is part of the native key. |
| `fingerprint-env`                   | no       | `''`                                     | Newline-separated `KEY=VALUE` pairs exported while the native key is computed, for an `app.config` that branches on env. Must be byte-identical to what the warm-up (`seed-native-cache.yml`) and the e2e workflows pass, or the two never agree on a key and every run takes a build slot. |
| `repack-env`                        | no       | `''`                                     | Newline-separated `KEY=VALUE` pairs exported for the re-bundle, so the consumer's `app.config` writes this build's API URL, version and build number into the repacked binary. |
| `expect-config`                     | no       | `''`                                     | Newline-separated `<dotted.path>=<value>` assertions the repacked binary's embedded `app.config` must satisfy exactly. Every value `repack-env` is expected to have rewritten belongs here: a config rewrite nobody checked is a repack nobody can trust. |
| `repack-app-version`                | no       | `0.7.2`                                    | Pinned `@expo/repack-app` npm version, used by both plan/repack jobs. |
| `repack-timeout-minutes`            | no       | `30`                                      | Timeout of each plan/repack job (`plan-ios` and `plan-android` alike). |
| `build-timeout-minutes`             | no       | `60`                                      | iOS build job timeout. |
| `capture-timeout-minutes`           | no       | `90`                                      | iOS capture job timeout. Default is generous: one job runs the full `locales x appearances x scenes` loop on a single booted simulator. |
| `android-build-runner-labels`       | no       | `''`                                     | Runner labels for the Android build job. Fallback chain: this → `build-runner-labels` → `runner-labels`. |
| `android-capture-runner-labels`     | no       | `["self-hosted","trf-linux-amd64-4x8"]` | Runner labels for Android capture. Defaults to the x86_64 Linux KVM pool for `avd`; no fallback to the macOS `runner-labels`. With `android-driver: redroid`, explicitly select your Redroid-capable pool. See [Android capture](#android-capture). |
| `android-cmdline-tools-version`     | no       | `12266719`                                | See `build-android-app` README — pin explicitly. |
| `android-gradle-task`               | no       | `assembleRelease`                         | `gradlew` task for the Android build. **cfg** |
| `android-gradle-args`               | no       | `''`                                     | Extra whitespace-split arguments appended after `android-gradle-task`. **cfg** |
| `android-build-tools-version`       | no       | `35.0.0`                                  | Android build-tools version the `plan-android` repack job installs via `android-actions/setup-android`, for the `zipalign` and `apksigner` a repacked APK is aligned and signed with. The Gradle build installs whatever its `compileSdkVersion` resolves to; the repack job never runs Gradle, so it asks for build-tools explicitly. |
| `android-build-tools-dir`           | no       | `''`                                     | Path to the build-tools directory holding `zipalign` and `apksigner`, used by the repack job. Empty uses the `android-build-tools-version` directory the repack job installs under the SDK (`$ANDROID_SDK_ROOT/build-tools/<version>`); a version the SDK does not hold fails the repack, naming the path. |
| `android-keystore-path`             | no       | `android/app/debug.keystore`              | Keystore, relative to `android-target`'s `appDir`, the repacked APK is signed with. The default is the React Native debug keystore an `expo prebuild` app ships and Gradle signs its release build with — sign the repack with anything else and the device refuses to install it over the base. These are the published debug-keystore constants, not secrets; a release key belongs in `native-publish.yml`, never here. Empty leaves `@expo/repack-app`'s own default in place. |
| `android-keystore-password`         | no       | `android`                                 | Password of `android-keystore-path`. Ignored when that is empty. |
| `android-keystore-key-alias`        | no       | `androiddebugkey`                         | Key alias inside `android-keystore-path`. Ignored when that is empty. |
| `android-keystore-key-password`     | no       | `android`                                 | Key password inside `android-keystore-path`. Ignored when that is empty. |
| `android-build-timeout-minutes`     | no       | `60`                                      | Android build job timeout. |
| `android-capture-timeout-minutes`   | no       | `90`                                      | Android capture job timeout. |
| `android-driver`                    | no       | `avd`                                     | Device backend of the Android capture job: `redroid` (a Redroid container, `redroid-*` inputs) or `avd` (Google's emulator through `android-emulator`, `emulator-*` inputs; x86_64 Linux with `/dev/kvm`). Anything else fails the capture job. See [Android capture](#android-capture). |
| `emulator-api-level`                | no       | `34`                                      | `avd` only. System image API level; must be 33+. |
| `emulator-target`                   | no       | `google_apis`                             | `avd` only. System image target. |
| `emulator-arch`                     | no       | `x86_64`                                  | `avd` only. System image architecture. |
| `emulator-profile`                  | no       | `pixel_6`                                 | `avd` only. `avdmanager` hardware profile. |
| `emulator-ram-size`                 | no       | `''`                                      | `avd` only. Emulator RAM in MB. Empty derives it from the capture runner's cgroup memory limit (256 MB per GiB, clamped 1536–4096; 2048 on a 4 vCPU / 8 GiB container); with no limit detected the profile default applies. |
| `emulator-heap-size`                | no       | `''`                                      | `avd` only. Android VM heap size in MB. |
| `emulator-cores`                    | no       | `''`                                      | `avd` only. Emulator CPU cores. Empty derives half the cgroup CPU quota, clamped 2–4. |
| `emulator-slots-dir`                | no       | `''`                                      | `avd` only. Host directory of fleet-provisioned `slot-*` files capping concurrent emulators per host, shared with `android-e2e.yml`'s input of the same name. Empty takes no slot; a missing or empty directory fails the capture job. |
| `emulator-slot-timeout-minutes`     | no       | `60`                                      | `avd` only. Minutes to wait for a free slot; counts against `android-capture-timeout-minutes`. |
| `redroid-image`                     | no       | `redroid/redroid:15.0.0_64only-latest`    | Redroid image tag, used on a prewarm-manifest miss. Must resolve to API 33+. |
| `redroid-memory`                    | no       | `3g`                                      | Container memory limit. |
| `redroid-cpus`                      | no       | `2`                                       | Container CPU limit. |
| `redroid-prewarm-manifest-path`     | no       | `$HOME/.rnw-ci/android-emulator.json`     | Host-side prewarm manifest path; see [docs/self-hosted-runners.md](../self-hosted-runners.md). |
| `redroid-boot-timeout-seconds`      | no       | `600`                                     | Seconds to wait for `sys.boot_completed`. |
| `upload-screenshots`                | no       | `false`                                    | Run the gated upload job. **cfg** |
| `upload-command`                    | no       | `''`                                     | Consumer-owned command run in the upload job, e.g. `bundle exec fastlane ios ios_screenshots`. Required when `upload-screenshots` is `true`; runs in the resolved app dir (`ios-target`'s `appDir` when set, `android-target`'s otherwise) with `SCREENSHOTS_DIR` (the resolved `screenshots-download-dir`) in its environment. **cfg** |
| `compose-command`                   | no       | `''`                                     | Optional consumer-owned command run in the upload job on the collected screenshots, after every artifact is merged and before the `apple-screenshot-slots` check and `upload-command`. For example, a device-frame composer such as [`compose-media`](../../actions/compose-media/README.md)'s `frame-device.sh`. Runs in the resolved app dir with `SCREENSHOTS_DIR` in its environment. Its failure fails the upload job. See [compose-command](#compose-command). |
| `screenshots-download-dir`          | no       | `fastlane/screenshots/raw`                 | Path, relative to the resolved app dir, every capture job's artifact is merged into before `upload-command` runs — iOS under its `ios/` subdirectory, Android under `android/`. **cfg** |
| `asc-key-path`                      | no       | `''`                                     | Optional path, relative to the resolved app dir, the App Store Connect API key (`.p8`) is written to and removed from for `upload-command`. Leave empty (default) to write it under `$RUNNER_TEMP` instead. |
| `publish-env`                       | no       | `''`                                     | Newline-separated `KEY=VALUE` pairs of non-secret env appended to `$GITHUB_ENV` at the start of the upload job. Fails closed on a malformed line. For secret values use `EAS_EXTRA_ENV` instead. **cfg** |
| `asc-dedupe-screenshots`            | no       | `false`                                   | Post-upload App Store Connect duplicate-screenshot verification/repair gate; see [App Store Connect dedupe gate](#app-store-connect-dedupe-gate). Requires `ASC_API_KEY` + `ASC_KEY_ID` + `ASC_ISSUER_ID` secrets and an `ios-target`. **cfg** |
| `asc-dedupe-version-state`          | no       | `PREPARE_FOR_SUBMISSION`                  | Which version's localizations are deduped (an App Store Connect `AppVersionState`; `READY_FOR_DISTRIBUTION` audits the live listing). **cfg** |
| `asc-dedupe-app-id`                 | no       | `''` (→ `ios-target.appId`)               | Bundle id of the ASC app whose listing is deduped; set it when the capture build uses a suffixed/e2e bundle id. **cfg** |
| `asc-fail-on-duplicates`            | no       | `true`                                    | Fail the upload job when any duplicate had to be deleted; set `false` to treat a successful repair as success. **cfg** |

## Build strategy

A screenshot run should not compile native code. Its native surface is almost
always identical to the default branch's, so the only thing that actually
changed is JavaScript — and swapping JavaScript into an already-built binary
is a Linux job measured in minutes, not a Mac or Gradle build measured in tens
of them. Three actions state that:
[`expo-native-key`](../../actions/expo-native-key) computes the one key a base
is addressed by, [`expo-base-binary`](../../actions/expo-base-binary) fetches
or publishes the base under that key, and
[`expo-repack`](../../actions/expo-repack) turns the base into this run's
binary and asserts the result against `expect-config`. Both platforms follow
the identical rule, and it is the same rule `ios-e2e.yml`,
`android-e2e.yml` and `seed-native-cache.yml` apply — a base warmed by one
is repacked by the others, as long as `fingerprint-env`, `fingerprint-config`,
`base-flavor` and the pinned toolchain match byte for byte.

**`auto` (the default).** `plan-ios` / `plan-android` compute the target's
native key and ask for the base published under it.

- *First run on a new native surface (no base yet).* The lookup reports
  `found=false`, the target lands in the plan's `native-targets` output, and
  the platform's `build` job compiles it exactly as v1.x did — `build-ios` on
  the macOS pool, `build-android` on `android-build-runner-labels`. When that
  run is on the default branch, the build job then **publishes** the base
  binary it built under that key. The **next** run on that same native
  surface finds the base and repacks, taking no build slot at all. A
  `found=false` is the signal to build; a lookup that *cannot tell* (registry
  error, artifacts API failure) fails the job instead, because an unreadable
  store is not an absent base.
- *Every subsequent run.* The base is found, `expo-repack` re-bundles this
  run's JavaScript into it on the Linux pool, the assertions in
  `expect-config` are checked, and the repacked binary is uploaded under the
  very artifact name the capture jobs already download
  (`store-screenshots-app-<target>` on iOS, `store-screenshots-apk-<target>`
  on Android). The build job's matrix is empty and no Mac or Gradle slot is
  touched.

Publishing only happens when `github.ref_name` is the repository's default
branch, and never under `build-strategy: native`. So after a change that moves
the native surface — an Expo or React Native upgrade, a new native module —
warm the new key on the default branch first, ideally with
[`seed-native-cache.yml`](seed-native-cache.md), which exists for exactly
that; the next screenshot run already repacks.

**`repack`.** The same lookup, but compiling native code is forbidden: a
missing base fails the plan job with the key it looked for, rather than
quietly queueing a Mac or Gradle build. Use it where a build slot is a scarce
resource you would rather see a red check than silently consume.

**`native`.** Every target compiles native code and the run publishes no
base. This is the escape hatch, and using it is a **regression**: it is the
v1.x behaviour, it costs a full native build per run, and the run emits a
`::warning::` saying so. Reach for it only to prove a repack-specific
suspicion, and take it back out. The same escape hatch is available per pull
request, without editing the caller, by applying the `native-build-label`
label (default `mobile: force native build`); combining that label with
`build-strategy: repack` fails closed instead of picking a winner.

Because `build-strategy` is a [config-file](#config-file) key like any other,
the resolution order is the usual one — explicit `with:` value > `config-path`
value > the built-in `auto` — and the `validate-manifest` job logs which of
the three it took.

## Outputs

| Name | Description |
| ---- | ----------- |
| `result` | The `status` job's verdict: `passed` or `failed`. |

Read it from a caller job that `needs:` this one. GitHub skips a dependent
job when its need fails, so a notification job must opt in with `if:
always()` (or `!cancelled()`) to see a `failed` result:

```yaml
    notify:
        needs: screenshots
        if: always()
        runs-on: ubuntu-latest
        steps:
            - env:
                  RESULT: ${{ needs.screenshots.outputs.result }}
              run: echo "store-screenshots: $RESULT"
```

## Secrets

| Name                | Required | Description |
| --------------------- | -------- | -------------- |
| `EXPO_TOKEN`          | no       | Forwarded to the upload job's environment if `upload-command` needs it. |
| `ASC_API_KEY`         | no       | App Store Connect API key contents (`.p8`). When set, written to `asc-key-path` (or `$RUNNER_TEMP`) before `upload-command` runs and removed afterward - same contract as `native-publish.yml`'s `ASC_API_KEY`. Also the key the dedupe gate signs with. |
| `ASC_KEY_ID`          | with `asc-dedupe-screenshots` | App Store Connect API key ID for the dedupe gate's JWT. |
| `ASC_ISSUER_ID`       | with `asc-dedupe-screenshots` | App Store Connect API issuer ID (UUID) for the dedupe gate's JWT. |
| `EAS_EXTRA_ENV`       | no       | Newline-separated `KEY=VALUE` pairs of secret env appended to `$GITHUB_ENV` at the start of the upload job, each value masked before being written - parsed by [`apply-secret-env`](../../actions/apply-secret-env/README.md), the same parser as `native-publish.yml`'s `EAS_EXTRA_ENV`. |
| `build-secrets-env`   | no       | Masked `KEY=VALUE` entries (`KEY<<DELIMITER` for a multi-line value) exported after `build-env` in both plan/repack legs and the `build-ios`/`build-android` jobs, parsed by [`apply-secret-env`](../../actions/apply-secret-env/README.md). Only a SHA-256 digest enters the native key, never a value, so the warm-up must be passed the same secret. See [ios-e2e.md](ios-e2e.md#secrets). |
| `e2e-secrets-env` | no | Masked `KEY=VALUE` entries, one line each, exported to the capture jobs' environment. A capture job uploads only screenshots. |
| `simlock-token` | with iOS entries | simlock agent token (`SIMLOCK_TOKEN`) the e2e capture leases simulators with. Reaches only the e2e capture job's run and lease-release steps. A call that needs it and lacks it fails in `validate-manifest`. |

Unlike `native-publish.yml`, none of these secrets are hard-required even
when `upload-screenshots` is `true` - `upload-command` is entirely
consumer-owned, and some fastlane setups authenticate a different way (e.g.
`FASTLANE_SESSION` threaded through `EAS_EXTRA_ENV`). The two capture
pipelines themselves need no secrets at all; `build-secrets-env` and
`e2e-secrets-env` are there for an app whose build or seed hook does, and
with neither passed every job behaves exactly as before.

## Concurrency

The workflow sets its own `concurrency` group of the caller's workflow name,
the `config-path` input and, for a `pull_request` run, the pull request's ref. Only a
`pull_request` run is cancelled when a newer push to the same pull request
supersedes it. Every other run — a push to the default branch, a schedule, a
manual dispatch — gets a group unique to its run id, so a newer push never
cancels or displaces an older default-branch run. A caller that sets its own
workflow-level `concurrency` should follow the same rule: a group of
`${{ github.event_name == 'pull_request' && github.ref || github.run_id }}`,
so a pull request's runs share one group while every other run gets its
own, together with
`cancel-in-progress: ${{ github.event_name == 'pull_request' }}`. Making
only `cancel-in-progress` conditional is not enough: a group shared by
default-branch pushes still lets a third pending run replace the second.

## Permissions

**The calling job must declare its own `permissions:` block.** A reusable
workflow's job-level `permissions:` can only *narrow* the token its caller
granted — it can never add a scope. The plan jobs ask for `packages: read` +
`actions: read` and the build jobs for `packages: write`, but in a repository
whose default workflow token permission is **read** (the GitHub default for
new organisations) those requests resolve to nothing and publishing the base
fails. The repository then builds natively on every run and never warms a key,
which looks like "repacking does not work" rather than like a permissions
problem.

Grant them on the job that calls this workflow:

```yaml
jobs:
    screenshots:
        permissions:
            contents: read
            packages: write
            actions: read
        uses: rnw-community/mobile-ci/.github/workflows/store-screenshots.yml@v5.0.0 # v5.0.0
```

- `contents: read` — checkout.
- `packages: write` — publishing the base binary to GHCR from a default-branch
  run (`base-backend: ghcr`, the default). `packages: read` alone is enough
  for a repository whose bases are published by something else (a
  `seed-native-cache.yml` warm-up, say), but then a key this repository does
  not already have a base for can never be warmed by this workflow.
- `actions: read` — the `artifact` backend's cross-run artifact lookup;
  harmless and recommended on the `ghcr` backend too.

With `base-backend: artifact` no package scope is needed at all —
`contents: read` + `actions: read` suffices — at the cost of workflow
artifacts expiring, so a key can go cold and cost a native build again.

This workflow still never writes to the repository.

## Examples

### Minimal

iOS only, deep-link scenes through the e2e project, no upload:

```yaml
on: workflow_dispatch
jobs:
    screenshots:
        permissions:
            contents: read
            packages: write
            actions: read
        uses: rnw-community/mobile-ci/.github/workflows/store-screenshots.yml@v5.0.0 # v5.0.0
        with:
            ios-target: >-
                {"name":"app","appDir":"apps/mobile","workspace":"MyApp.xcworkspace","scheme":"MyApp","appId":"com.example.app","prebuildCommand":"npx expo prebuild -p ios"}
            capture-manifest: >-
                [{"device":"iPhone 17 Pro Max","locales":["en"],"appearances":["light"]}]
            capture-scenes: >-
                [{"name":"home","deepLink":"myapp://home","readySelector":{"id":"HomeScreen.Root"}}]
            e2e-dir: e2e
            simlock-url: https://simlock.example.com
        secrets:
            simlock-token: ${{ secrets.SIMLOCK_TOKEN }}
```

### Full

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
        # Required: a reusable workflow can only narrow what the caller grants.
        permissions:
            contents: read
            packages: write
            actions: read
        uses: rnw-community/mobile-ci/.github/workflows/store-screenshots.yml@v5.0.0 # v5.0.0
        with:
            ios-target: >-
                {"name":"bare","appDir":"apps/mobile","workspace":"MyApp.xcworkspace","scheme":"MyApp","appId":"com.example.app","prebuildCommand":""}
            capture-manifest: >-
                [
                  {"device":"iPhone 17 Pro Max","locales":["en","de"],"appearances":["light","dark"]},
                ]
            capture-scenes: >-
                [
                  {"name":"home","deepLink":"myapp://home","readySelector":{"id":"HomeScreen.Root"}},
                  {"name":"stats","deepLink":"myapp://stats","readySelector":{"id":"StatsScreen.Root"},"settleSeconds":5},
                  {"name":"win","test":"14-win"}
                ]
            e2e-dir: e2e
            simlock-url: https://simlock.example.com
            apple-screenshot-slots: >-
                {"1320x2868":"IPHONE_69"}
            upload-screenshots: true
            upload-command: bundle exec fastlane ios ios_screenshots
            asc-dedupe-screenshots: true
            # build-strategy: auto is the default — repack a published base on
            # Linux, and compile only a native key that has none.
            repack-env: |
                API_URL=https://staging.example.com
                APP_VERSION=1.2.3
            expect-config: |
                extra.apiUrl=https://staging.example.com
                version=1.2.3
        secrets:
            ASC_API_KEY: ${{ secrets.ASC_API_KEY }}
            ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
            ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
```

`fingerprint-env` must pass exactly what the default-branch warm-up passes; a
single differing byte gives this run a different native key, and every run
takes a build slot again.

Complete caller workflows for whole apps, linted and checked against this
workflow's inputs in CI, live in [docs/examples/](../examples/README.md).

## Why the native build no longer reads a host cache

A `native-app-cache` entry is keyed on the native key, and the native key
deliberately excludes JavaScript. Restoring one and handing it to a test or
capture job would test whatever bundle the cached shell happened to carry —
exactly the hole `repack-on-hit` existed to paper over in v2. The base binary
store is the cross-run cache now, and what it holds is always repacked with
this commit's JavaScript before anything installs it, so this job simply builds
when it runs — and it only runs for a key nothing has published a base for.
`seed-native-cache.yml` still keeps a host cache, because what it produces
becomes a base to be repacked, never a test artifact. `cache-profile` is gone
with it.
