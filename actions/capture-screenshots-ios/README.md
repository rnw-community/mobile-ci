# capture-screenshots-ios

Boots a pinned iOS Simulator, installs a packaged `.app`, then captures one
screenshot per `locale` x `appearance` x scene, reusing the same booted
simulator across the whole matrix rather than paying a fresh boot/install per
cell. Scenes come from one of two modes:

- **Flow-discovery mode (legacy, `scenes` empty).** A scene is any top-level
  `*.flow.yaml` file directly inside `screenshots-dir` (subflows and
  fixtures live in subdirectories and are never swept in, same convention as
  `run-maestro-ios`'s `flows-dir`) named `<number>.<name>.flow.yaml` - the
  leading number is stripped to produce the scene name used in the output
  path.
- **Direct mode (`scenes` set).** Scenes come from a JSON manifest - see
  [Direct mode](#direct-mode-scene-manifest) below. The
  `<number>.<name>.flow.yaml` convention is not required; the scene name
  comes from the manifest.

**Output layout is fixed and not configurable:**
`<output-dir>/raw/ios/<device-slug>/<locale>/<appearance>/<scene>.png`, where
`<device-slug>` is `simulator-device` lowercased with every run of
non-alphanumeric characters collapsed to a single hyphen (e.g.
`iPhone 17 Pro Max` -> `iphone-17-pro-max`). The `raw/ios/<device-slug>`
directory is cleared at the start of every run, so a reused `output-dir`
never republishes stale screenshots from a previous matrix.

## Direct mode (scene manifest)

`scenes` is the same JSON shape `store-screenshots.yml`'s `capture-scenes`
input uses (see
[docs/workflows/store-screenshots.md](../../docs/workflows/store-screenshots.md)
for the full schema): each scene has a unique path-safe `name` and exactly
one of

- `deepLink` - per cell, the app is `simctl terminate`d, optionally seeded
  (`seed-command`), launched with
  `simctl launch <udid> <app-id> -AppleLanguages '("<locale>")' -AppleLocale <locale>`,
  sent the deep link via `simctl openurl`, allowed `settle-seconds` (or the
  scene's own `settleSeconds`) to settle, checked against the
  [open-confirmation sheet](#ios-open-confirmation-sheet) and against the
  scene's required `readySelector`, then captured with
  `simctl io screenshot`.
- `flow` - a Maestro flow path relative to `screenshots-dir`, run with the
  same single-`takeScreenshot` contract as flow-discovery mode.

Every deep-link scene must also carry a `readySelector` - a Maestro selector,
either a non-empty string matched as text/regex or a `{"id": "<testID>"}`
object - naming an element the scene always renders. It is asserted visible
before the screencap; see
[iOS open-confirmation sheet](#ios-open-confirmation-sheet). A deep-link
scene without one fails manifest validation.

Maestro is installed lazily in direct mode, only when at least one
ios-applicable scene declares a `flow` **or** a `deepLink` (deep-link scenes
need it for the open-confirmation sheet and readiness checks).

Optional per-scene `platforms`/`locales`/`appearances` filters restrict
where a scene is captured; scenes whose `platforms` excludes `ios` are
skipped entirely (all of them being skipped fails closed).

`seed-command` (direct mode only - setting it in flow-discovery mode fails
closed) runs once per locale x appearance x scene cell, from the repo root,
with the app installed and terminated, and with `SCENE`, `LOCALE`,
`APPEARANCE`, `APP_ID`, `PLATFORM=ios`, `DEVICE_SLUG`, `SIMULATOR_UDID`,
and `APP_PATH` in its environment. Its failure marks that cell failed with
no capture and no retry.

## iOS open-confirmation sheet

On newer iOS runtimes SpringBoard answers a `simctl openurl` deep link with
an **`Open in "<app>"?` / Cancel / Open** confirmation sheet, drawn over the
home screen with the target app deactivated behind it. A `simctl io
screenshot` taken while that sheet is up is a picture of SpringBoard, not of
the app — and nothing in `simctl` reports which bundle is frontmost, so
without a check the capture step stays green and ships store-worthless PNGs.
Pre-launching the app before the `openurl` (which this action already does)
does **not** avoid the sheet.

So in direct mode every deep-link cell, after its settle and immediately
before its screencap, runs a generated one-flow Maestro check that

1. taps the confirm button when the sheet is on screen,
2. `assertNotVisible`s the sheet afterwards, and
3. waits, with `extendedWaitUntil`, for the scene's `readySelector` to be
   visible.

Any of those failing fails that cell (retried once, then the step fails with
an error naming the scene, locale and appearance) instead of writing a
screenshot of it. Approving the sheet is a persistent per-simulator choice,
so after the first cell the tap is a no-op and only the assertions run.

Step 3 is not redundant with step 2. The sheet being absent is equally true
of a bare home screen, so up to v1.11.0 — when the check stopped at
`assertNotVisible` — a cell whose app never came forward at all passed and
shipped a SpringBoard screenshot as a store asset. `readySelector` is the
only positive evidence available that the app, and the right scene within
it, owns the screen; it is therefore required on every deep-link scene
rather than optional. Its wait is bounded by the cell's effective settle
seconds with a 5-second floor.

The sheet is localised to the **simulator's own** language — which this
action never changes (the `locale` axis writes app-scoped preferences only),
so it is English on a stock CoreSimulator device. `deeplink-confirm-title`
and `deeplink-confirm-button` default to the English strings; on a simulator
provisioned in another language the capture **fails closed** up front unless
**both** have been set to that language's strings. Both are rejected, not just
the title: a simulator that already carries a persisted approval never shows
the sheet, so a wrong button label would otherwise go unvalidated until the
one run that actually needs it.

## Device resolution

`simulator-device` is matched exactly (no fuzzy matching) against the names in
`xcrun simctl list -j devices available`, which needs `jq` on the host — see
[docs/self-hosted-runners.md](../../docs/self-hosted-runners.md#common-to-every-pool-jq).

- **No match** — fails closed, printing the available device listing.
- **One match** — booted.
- **Several matches under different runtimes** — the same device model
  provisioned under two runtimes (what happens when a second Xcode lands on a
  host) no longer hard-fails: the candidate under the **newest runtime
  version** is booted, and a `::notice::` names every candidate with its UDID
  and runtime plus which one was chosen. Runtime versions are compared
  component-wise as numbers, so `iOS-26-10` beats `iOS-26-9`. The
  deterministic-device guarantee holds — the ordering is total, not
  listing-order-dependent.
- **Several matches under the same runtime** (cloned devices) — still fails
  closed, now listing each candidate's UDID and runtime so the operator knows
  exactly which simulator to delete. No runtime ordering can break that tie,
  and it fails closed even when the duplicated pair sits under an *older*
  runtime than the one that would have won the tie-break.

Among several candidates, a runtime identifier with no parseable version, or
two distinct runtime identifiers resolving to the same version, also fail
closed rather than being ordered arbitrarily.

## Status bar

`status-bar-override: 'true'` (default) applies
`xcrun simctl status_bar <udid> override` once after boot in **both** modes:
time 9:41, wifi active with 3 bars, cellular active with 4 bars, battery
100% charged. A failing override call fails closed; set the input to
`'false'` to capture with the real status bar.

## Two-layer locale/appearance model

Both axes are applied at the OS level *and* passed into every scene as `-e`
Maestro env vars, so either an app that follows the system setting or an app
with its own in-app switcher produces correct screenshots:

- **Appearance** - `xcrun simctl ui <udid> appearance light|dark` is run once
  per `appearance` value before that appearance's scenes, in addition to
  `-e APPEARANCE=<value>`. Only `light`/`dark` are accepted; anything else
  fails closed.
- **Locale** - `xcrun simctl spawn <udid> defaults write <app-id>
  AppleLanguages/AppleLocale` is attempted once per `locale` value before
  that locale's scenes, in addition to `-e LOCALE=<value>`. This is
  best-effort (a `::warning::`, not a failure, if it does not apply) and is
  authoritative only for an app that reads the system locale (e.g. via
  `NSLocale`/`react-native-localize`); an app with its own in-app language
  switcher still needs its scenes to read `${LOCALE}` and apply it
  themselves - see the `apply-language.flow.yaml` /
  `apply-appearance.flow.yaml` subflow convention documented in
  [docs/workflows/store-screenshots.md](../../docs/workflows/store-screenshots.md).

## Per-locale flow env

`locale-env` closes the contract gap where a flow needs inputs that must
**vary per locale** (e.g. `LOCALE_IDENTIFIER`, `OS_LANGUAGE_MODE`) while the
global `maestro-env` input is one static list for the whole capture job:

```json
{"de": {"LOCALE_IDENTIFIER": "de-DE", "OS_LANGUAGE_MODE": "german"}, "fr": {"LOCALE_IDENTIFIER": "fr-FR"}}
```

Every flow-backed scene of that locale's cells receives the global
`maestro-env` pairs followed by the locale's own pairs. Deep-link scenes run
Maestro only for the [open-confirmation sheet](#ios-open-confirmation-sheet)
check, which is passed neither `maestro-env`/`locale-env` nor
`maestro-config`. Reserved names (`APP_ID`, `LOCALE`,
`APPEARANCE`) are rejected in both inputs, fail-closed, because a duplicate
`-e` would make behavior depend on argument order.

## Orientation

`orientation: landscape` does **not** rotate the Simulator's own UI - there
is no supported `simctl` UI-rotation call, and adding one would mean
depending on a third-party automation tool this repo does not otherwise use.
Instead, each captured PNG is rotated 90 degrees in place via the
macOS-builtin `sips` after capture (same idea as the reference
`bake-landscape-screenshot.ts`). This changes pixels only, not the app's own
layout during capture - a scene whose landscape presentation is meaningfully
different from portrait needs its own landscape-aware flow.

## Retry and failure handling

Each failing cell gets up to 2 attempts (1 retry, not configurable) in both
modes; a `seed-command` failure marks its cell failed with no capture and no
retry. A flow-backed scene is expected to produce exactly one
`takeScreenshot` output per run; zero or more than one fails that scene
closed with an explicit error rather than guessing which file was intended.
Every `maestro` invocation this action makes — flow-backed scenes and the
open-confirmation probe alike — passes `--device <udid>` for the simulator
this action booted, so a second booted simulator on a shared runner can never
be the one Maestro drives while `simctl` targets the pinned one.
Maestro is run from a fresh per-cell scratch working directory, because it
writes a relative `takeScreenshot` name into the process CWD (not into
`--test-output-dir`); the PNG is collected from the union of that scratch
CWD and `--test-output-dir`'s `takeScreenshot/` subdirectory.
Flow-internal `runFlow` references are unaffected — Maestro resolves them
against the flow file, not the CWD.
Flow scenes are validated against the default Maestro (2.8.x): older 2.6.x
releases store `takeScreenshot` output in a layout the collector does not
search, so a downgraded `maestro-version` fails closed with the
zero-screenshot error rather than silently capturing nothing.
A per-locale/appearance/scene timing table is appended to
`$GITHUB_STEP_SUMMARY`.

## Maestro workspace config

Maestro only auto-discovers a workspace `config.yaml` when the CLI is pointed
at a **directory**. This action passes the CLI one scene flow file per
invocation, so a workspace config sitting next to those flows is never read
and nothing warns about it. Point `maestro-config` at that file and it is
passed as `--config` to **every** `maestro test` this action runs for a
flow-backed scene.

The case that motivated the input: an `@expo/ui` SwiftUI `.sheet()` modal
renders its React Native content outside the app's main window, so the
XCUITest hierarchy Maestro snapshots never contains it and every selector
inside the sheet times out at its assertion budget. The fix lives entirely in
the workspace config —

```yaml
platform:
    ios:
        snapshotKeyHonorModalViews: false
```

— and is inert unless `--config` actually reaches the CLI.

## Inputs

| Name                     | Required | Default       | Description |
| -------------------------- | -------- | ------------- | -------------- |
| `app-path`                  | yes      | —             | Path to a packaged `.app` directory to install. |
| `app-id`                    | yes      | —             | Bundle identifier passed to Maestro as `APP_ID`. |
| `scenes`                    | no       | `''`          | JSON array of scene objects switching the action into [direct mode](#direct-mode-scene-manifest); empty keeps flow-discovery mode byte-for-byte. Every `deepLink` scene requires a `readySelector`. |
| `seed-command`              | no       | `''`          | Consumer-owned per-cell seed hook, direct mode only (fails closed if set while `scenes` is empty). Failure fails the cell closed (no capture, no retry). |
| `settle-seconds`            | no       | `3`           | Seconds (integer 0–120) between a deep-link launch and its screenshot in direct mode; a scene's `settleSeconds` overrides it. |
| `deeplink-confirm-title`    | no       | `Open in .*\?` | Maestro text pattern matching the title of the iOS open-confirmation sheet, direct mode only. Tapped away and then asserted gone before every deep-link screencap; see [iOS open-confirmation sheet](#ios-open-confirmation-sheet). The trailing `\?` anchors the default to the sheet's own title rather than to app content that merely starts with `Open in`. Fails closed when the simulator's own language is not English and this or `deeplink-confirm-button` is still the default. |
| `deeplink-confirm-button`   | no       | `Open`        | Label of the confirm button on the sheet matched by `deeplink-confirm-title`, direct mode only. Also fails closed when the simulator's own language is not English and it is still the default. |
| `status-bar-override`       | no       | `true`        | Apply the `simctl status_bar` 9:41 override once after boot (both modes); fails closed if the call fails. |
| `screenshots-dir`           | no       | `''`          | Discovery root in flow-discovery mode; the directory flow-backed manifest scenes resolve against in direct mode. Required in flow-discovery mode, and in direct mode when an ios-applicable scene declares a `flow`. |
| `scenes-name-pattern`       | no       | `*.flow.yaml` | Space-separated `find -name` globs (OR'd together) selecting scenes directly inside `screenshots-dir`. Flow-discovery mode only. |
| `scenes-exclude-pattern`    | no       | `''`          | Optional `find ! -name` glob excluding matched scenes by basename. Flow-discovery mode only. |
| `simulator-device`          | **yes**  | —             | Exact simulator device name to boot, matched with no fuzzy matching against `xcrun simctl list -j devices available`; fails closed when nothing matches. Identical-name ties across runtimes resolve to the newest runtime version (reported in a `::notice::` naming every candidate); two same-name simulators under the **same** runtime still fail closed — see [Device resolution](#device-resolution). Required here (unlike `run-maestro-ios`'s optional input) - deterministic capture needs a pinned device. |
| `locales`                   | yes      | —             | Space- or comma-separated locale identifiers, e.g. `en,de,fr`. |
| `appearances`               | yes      | —             | Space- or comma-separated list of `light` and/or `dark`. |
| `orientation`               | no       | `portrait`    | `portrait` or `landscape`; see [Orientation](#orientation). |
| `maestro-env`               | no       | `''`          | Newline-separated `KEY=VALUE` pairs, each passed as an additional `-e KEY=VALUE` argument on top of the always-passed `APP_ID`/`LOCALE`/`APPEARANCE`. Rejects (fails closed) any line without `=`, any name not matching `^[A-Za-z_][A-Za-z0-9_]*$`, and any reserved `APP_ID`/`LOCALE`/`APPEARANCE` override (a duplicate `-e` would be order-dependent). |
| `locale-env`                | no       | `''`          | JSON object mapping a locale from `locales` to extra env pairs applied only to that locale's cells - e.g. `{"de": {"LOCALE_IDENTIFIER": "de-DE"}}`. Precedence: global `maestro-env`, then these (Maestro's last `-e` wins). Fails closed on invalid JSON, an unknown locale key, a reserved name, a non-string value, or a value containing a newline/tab. See [Per-locale flow env](#per-locale-flow-env). |
| `maestro-config`             | no       | `''`          | Path to the consumer's Maestro workspace config (`config.yaml`), passed as `--config` to every `maestro test` invocation. Maestro only auto-discovers a workspace `config.yaml` when it is pointed at a **directory**, and this action always passes individual flow files, so without this input a workspace config is silently ignored — see [Maestro workspace config](#maestro-workspace-config). Relative paths resolve against the job's working directory. Fails closed when set to a path that is not a file. |
| `maestro-version`           | no       | `2.8.0`       | Pinned Maestro CLI version, installed the same way as `run-maestro-ios`'s `maestro-version` — and lazily: in direct mode only when an ios-applicable scene declares a `flow` or a `deepLink`. |
| `output-dir`                | yes      | —             | Root output directory; see the fixed layout above. |

## Outputs

| Name          | Description |
| --------------- | -------------- |
| `device-slug`  | Slugified `simulator-device`. |
| `raw-dir`      | This run's output root - `output-dir/raw/ios/<device-slug>`. |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/capture-screenshots-ios@v1
  with:
      app-path: .ci-artifacts/store-screenshots-app/Base.app
      app-id: com.example.app
      screenshots-dir: apps/mobile/e2e/flows/screenshots
      simulator-device: iPhone 17 Pro Max
      locales: en,de,fr
      appearances: light,dark
      output-dir: ${{ github.workspace }}/screenshots-output
```
