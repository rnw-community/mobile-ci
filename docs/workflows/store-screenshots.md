# store-screenshots.yml

`workflow_call` reusable workflow: fleet-native store screenshot capture for
iOS, driven by a Maestro flow matrix. **iOS only in this release** - Android
(`capture-screenshots-android` + the Android side of this workflow) is
tracked separately and lands in a follow-up minor release; `enable-ios`/
`enable-android` toggles do not exist yet.

Five jobs: **validate-manifest** (hosted `ubuntu-latest`; fails closed on a
malformed `capture-manifest`) → **build** (same build-job shape as
`ios-maestro.yml`'s `build` job, but for a single `target` rather than a
`targets` array - Xcode select, native fingerprint, native-app-cache
restore, optional repack-on-hit, ccache, `xcodebuild`, artifact upload) →
**capture** (one job per `capture-manifest` entry - download the built
`.app`, boot that entry's pinned simulator once, then loop
`locales x appearances x scenes` inside the job reusing that one booted
simulator, optional `post-capture-command` hook, upload
`raw-screenshots-<device-slug>`) → **upload** (gated by `upload-screenshots`;
downloads every capture job's artifact and runs a consumer-owned
`upload-command`, e.g. a fastlane `deliver` lane) → **status** (aggregates
the above into a single required check, with a `cancelled`-result hint
pointing at `build-timeout-minutes`/`capture-timeout-minutes`).

## Flow convention

Screenshot scenes are numbered top-level `*.flow.yaml` files directly inside
`screenshots-dir`, exactly like `ios-maestro.yml`'s `flows-dir` convention:

```
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
`-e LOCALE=<value> -e APPEARANCE=<value>` into every scene. An app that
follows the system setting needs no flow changes at all; an app with its own
in-app language/theme switcher needs its scenes to read `${LOCALE}`/
`${APPEARANCE}` and apply them - the reference convention (mirrored from
`apply-language.flow.yaml`/`apply-appearance.flow.yaml` in
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

## Inputs

| Name                          | Required | Default                             | Description |
| -------------------------------- | -------- | -------------------------------------- | -------------- |
| `runner-labels`                    | no       | `["self-hosted","macOS","ARM64"]`         | JSON array of self-hosted runner labels for the build/capture jobs. |
| `build-runner-labels`               | no       | `''`                                     | JSON array of self-hosted runner labels for the build job only. Falls back to `runner-labels`. |
| `capture-runner-labels`             | no       | `''`                                     | JSON array of self-hosted runner labels for the capture job only. Falls back to `runner-labels`. Must be an arm64 macOS pool, same constraint as `ios-maestro.yml`'s `test-runner-labels`. |
| `upload-runner-labels`              | no       | `''`                                     | JSON array of runner labels for the gated upload job. Falls back to `runner-labels`. |
| `target`                            | **yes**  | —                                        | Single build target JSON object: `{name, appDir, workspace, scheme, appId, prebuildCommand}`. Singular, unlike `ios-maestro.yml`'s `targets` array. |
| `capture-manifest`                  | **yes**  | —                                        | JSON array of capture matrix entries, one job per entry: `{"device": "iPhone 17 Pro Max", "locales": ["en","de"], "appearances": ["light","dark"], "orientation": "portrait"}`. `orientation` defaults to `"portrait"` when omitted. |
| `screenshots-dir`                   | **yes**  | —                                        | Directory (relative to repo root) whose top-level files are the runnable screenshot scenes. |
| `scenes-name-pattern`               | no       | `*.flow.yaml`                             | Space-separated `find -name` globs selecting scenes directly inside `screenshots-dir`. |
| `scenes-exclude-pattern`            | no       | `''`                                     | Optional `find ! -name` glob excluding matched scenes by basename. |
| `maestro-env`                       | no       | `''`                                     | Newline-separated `KEY=VALUE` pairs, each passed as an additional `-e KEY=VALUE` argument on top of the always-passed `APP_ID`/`LOCALE`/`APPEARANCE`. Fails closed on a malformed line. |
| `maestro-version`                   | no       | `2.8.0`                                   | Pinned Maestro CLI version. |
| `post-capture-command`              | no       | `''`                                     | Optional consumer-owned command run in the capture job after capture completes, before upload - e.g. a device-bezel framing script. Runs with `SCREENSHOTS_OUTPUT_DIR` and `DEVICE_SLUG` in its environment. Its failure fails the capture job. |
| `xcode-version`                     | no       | `26.4.1`                                  | Xcode version string. |
| `xcode-build`                       | no       | `17E202`                                  | Xcode build number. |
| `cache-profile`                     | no       | `ios-native-v1`                           | Cache-key prefix distinguishing this consumer/app. |
| `expo-fingerprint-version`          | no       | `0.20.6`                                  | Pinned `@expo/fingerprint` npm version. |
| `node-version`                      | no       | `22.x`                                    | Node version for `actions/setup-node`. |
| `install-command`                   | no       | `yarn install --immutable`                | JS dependency install command. |
| `enable-corepack`                   | no       | `true`                                    | Run `corepack enable` before install. |
| `build-command`                     | no       | `''`                                     | Optional workspace JS build command run at repo root before the native build. |
| `rct-use-prebuilt-rncore`           | no       | `false`                                    | Sets `RCT_USE_PREBUILT_RNCORE=1` for the build step when `true`. |
| `rct-use-rn-dep`                    | no       | `false`                                    | Sets `RCT_USE_RN_DEP=1` for the build step when `true`. |
| `expo-use-precompiled-modules`      | no       | `false`                                    | Sets `EXPO_USE_PRECOMPILED_MODULES=1` for the build step when `true`. |
| `ccache-max-size`                   | no       | `2G`                                     | Bounded, compressed ccache maximum size. |
| `build-env`                         | no       | `''`                                     | Newline-separated `KEY=VALUE` pairs appended to `$GITHUB_ENV` at the start of the build job. Fails closed on a malformed line. |
| `repack-on-hit`                     | no       | `false`                                    | On a native-app-cache hit, run `repack-app` to inject a freshly exported JS bundle into the cached shell instead of reusing it unchanged. |
| `repack-app-version`                | no       | `0.7.2`                                    | Pinned `@expo/repack-app` npm version, used only when `repack-on-hit` is true. |
| `build-timeout-minutes`             | no       | `60`                                      | Build job timeout. |
| `capture-timeout-minutes`           | no       | `90`                                      | Capture job timeout. Default is generous: one job runs the full `locales x appearances x scenes` loop for its device (e.g. 13 locales x 2 appearances x 10 scenes) on a single booted simulator. |
| `upload-screenshots`                | no       | `false`                                    | Run the gated upload job. |
| `upload-command`                    | no       | `''`                                     | Consumer-owned command run in the upload job, e.g. `bundle exec fastlane ios ios_screenshots`. Required when `upload-screenshots` is `true`; runs in `fromJSON(inputs.target).appDir`. |
| `screenshots-download-dir`          | no       | `fastlane/screenshots/raw`                 | Path, relative to `fromJSON(inputs.target).appDir`, every capture job's `raw-screenshots-<device-slug>` artifact is merged into before `upload-command` runs. Defaults to the reference implementation's convention so an unmodified fastlane `Deliverfile` pointed at that path works unchanged. |
| `asc-key-path`                      | no       | `''`                                     | Optional path, relative to `fromJSON(inputs.target).appDir`, the App Store Connect API key (`.p8`) is written to and removed from for `upload-command`. Leave empty (default) to write it under `$RUNNER_TEMP` instead. |
| `publish-env`                       | no       | `''`                                     | Newline-separated `KEY=VALUE` pairs of non-secret env appended to `$GITHUB_ENV` at the start of the upload job, before `upload-command` runs. Fails closed on a malformed line. For secret values use `EAS_EXTRA_ENV` instead. |

## Secrets

| Name                | Required | Description |
| --------------------- | -------- | -------------- |
| `EXPO_TOKEN`          | no       | Forwarded to the upload job's environment if `upload-command` needs it. |
| `ASC_API_KEY`         | no       | App Store Connect API key contents (`.p8`). When set, written to `asc-key-path` (or `$RUNNER_TEMP`) before `upload-command` runs and removed afterward - same contract as `native-publish.yml`'s `ASC_API_KEY`. |
| `EAS_EXTRA_ENV`       | no       | Newline-separated `KEY=VALUE` pairs of secret env appended to `$GITHUB_ENV` at the start of the upload job, each value masked before being written - same fail-closed parser and masking as `native-publish.yml`'s `EAS_EXTRA_ENV`. |

Unlike `native-publish.yml`, none of these secrets are hard-required even
when `upload-screenshots` is `true` - `upload-command` is entirely
consumer-owned, and some fastlane setups authenticate a different way (e.g.
`FASTLANE_SESSION` threaded through `EAS_EXTRA_ENV`).

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
            target: >-
                {"name":"bare","appDir":"apps/mobile","workspace":"MyApp.xcworkspace","scheme":"MyApp","appId":"com.example.app","prebuildCommand":""}
            screenshots-dir: apps/mobile/e2e/flows/screenshots
            capture-manifest: >-
                [
                  {"device":"iPhone 17 Pro Max","locales":["en","de","fr"],"appearances":["light","dark"]},
                  {"device":"iPhone SE (3rd generation)","locales":["en"],"appearances":["light"]}
                ]
            upload-screenshots: true
            upload-command: bundle exec fastlane ios ios_screenshots
        secrets:
            ASC_API_KEY: ${{ secrets.ASC_API_KEY }}
```

See [README.md](../../README.md#reusable-workflow-catalog) for the full
action/workflow catalog and
[actions/capture-screenshots-ios/README.md](../../actions/capture-screenshots-ios/README.md)
for the à-la-carte composite action this workflow's capture job wraps.
