# capture-screenshots-ios

Boots a pinned iOS Simulator, installs a packaged `.app`, then captures one
screenshot per `locale` x `appearance` x scene, reusing the same booted
simulator across the whole matrix rather than paying a fresh boot/install per
cell. A scene is any top-level `*.flow.yaml` file directly inside
`screenshots-dir` (subflows and fixtures live in subdirectories and are never
swept in, same convention as `run-maestro-ios`'s `flows-dir`) named
`<number>.<name>.flow.yaml` - the leading number is stripped to produce the
scene name used in the output path.

**Output layout is fixed and not configurable:**
`<output-dir>/raw/ios/<device-slug>/<locale>/<appearance>/<scene>.png`, where
`<device-slug>` is `simulator-device` lowercased with every run of
non-alphanumeric characters collapsed to a single hyphen (e.g.
`iPhone 17 Pro Max` -> `iphone-17-pro-max`).

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

Each scene gets up to 2 attempts (1 retry, not configurable). A scene is
expected to produce exactly one `takeScreenshot` output per run; zero or more
than one fails that scene closed with an explicit error rather than guessing
which file was intended. A per-locale/appearance/scene timing table is
appended to `$GITHUB_STEP_SUMMARY`.

## Inputs

| Name                     | Required | Default       | Description |
| -------------------------- | -------- | ------------- | -------------- |
| `app-path`                  | yes      | —             | Path to a packaged `.app` directory to install. |
| `app-id`                    | yes      | —             | Bundle identifier passed to Maestro as `APP_ID`. |
| `screenshots-dir`           | yes      | —             | Directory whose top-level files are the runnable screenshot scenes. |
| `scenes-name-pattern`       | no       | `*.flow.yaml` | Space-separated `find -name` globs (OR'd together) selecting scenes directly inside `screenshots-dir`. |
| `scenes-exclude-pattern`    | no       | `''`          | Optional `find ! -name` glob excluding matched scenes by basename. |
| `simulator-device`          | **yes**  | —             | Exact simulator device name to boot, matched with no fuzzy matching; also fails closed if more than one available simulator shares that exact name. Required here (unlike `run-maestro-ios`'s optional input) - deterministic capture needs a pinned device. |
| `locales`                   | yes      | —             | Space- or comma-separated locale identifiers, e.g. `en,de,fr`. |
| `appearances`               | yes      | —             | Space- or comma-separated list of `light` and/or `dark`. |
| `orientation`               | no       | `portrait`    | `portrait` or `landscape`; see [Orientation](#orientation). |
| `maestro-env`               | no       | `''`          | Newline-separated `KEY=VALUE` pairs, each passed as an additional `-e KEY=VALUE` argument on top of the always-passed `APP_ID`/`LOCALE`/`APPEARANCE`. Rejects (fails closed) any line without `=` or whose name does not match `^[A-Za-z_][A-Za-z0-9_]*$`. |
| `maestro-version`           | no       | `2.8.0`       | Pinned Maestro CLI version, installed the same way as `run-maestro-ios`'s `maestro-version`. |
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
