# build-ios-app

Builds a Release, ad-hoc-signed (entitlements preserved) iOS Simulator `.app`
via `xcodebuild`, verifies the embedded `main.jsbundle` is present, and
packages the result into `<output-dir>/Base.app`. Restores/saves a CocoaPods
cache around `pod install --repo-update`.

**Why Release, never a dev-CLI launcher.** `expo run:ios` (and equivalent
dev-client launchers) expect an attached Metro/dev server and crash headless
on CI. This action always builds `Release` with the JS bundle embedded at
build time, so the resulting `.app` runs standalone on a simulator with no
Metro process attached — the only build shape that survives a headless
runner.

**Why ad-hoc signing instead of `CODE_SIGNING_ALLOWED=NO`.** Simulator builds
never need a real signing identity, but skipping codesign entirely also skips
embedding entitlements — any consumer app using an entitlement-gated API
(Keychain/SecureStore, App Groups) then crashes at boot even on Simulator.
`CODE_SIGN_IDENTITY=- AD_HOC_CODE_SIGNING_ALLOWED=YES
PROVISIONING_PROFILE_SPECIFIER=` signs the build ad hoc — no certificate or
provisioning profile lookup required — while still embedding the project's
entitlements.

Run `setup-xcode-pinned` and (optionally) `setup-ccache-ios` before this
action so `DEVELOPER_DIR` and the ccache toolchain are already in place.

## Inputs

| Name                            | Required | Default   | Description                                                |
| -------------------------------- | -------- | --------- | -------------------------------------------------------------- |
| `app-dir`                        | yes      | —         | App directory containing `ios/`.                                |
| `workspace`                      | yes      | —         | Xcode workspace file name.                                      |
| `scheme`                         | yes      | —         | Xcode scheme name.                                               |
| `derived-data-dir`               | yes      | —         | DerivedData directory for the build.                             |
| `output-dir`                     | yes      | —         | Directory the packaged `.app` is copied into as `Base.app`.      |
| `pods-cache-key`                 | yes      | —         | Exact cache key for the CocoaPods cache.                         |
| `pods-cache-restore-keys`        | no       | `''`      | Newline-separated fallback prefixes.                             |
| `configuration`                  | no       | `Release` | xcodebuild configuration.                                        |
| `archs`                          | no       | `arm64`   | xcodebuild `ARCHS`.                                              |
| `excluded-archs`                 | no       | `x86_64`  | xcodebuild `EXCLUDED_ARCHS`.                                     |
| `rct-use-prebuilt-rncore`        | no       | `false`   | Sets `RCT_USE_PREBUILT_RNCORE=1` when `true`.                    |
| `rct-use-rn-dep`                 | no       | `false`   | Sets `RCT_USE_RN_DEP=1` when `true`.                             |
| `expo-use-precompiled-modules`   | no       | `false`   | Sets `EXPO_USE_PRECOMPILED_MODULES=1` when `true`.               |

## Outputs

| Name       | Description                            |
| ---------- | ------------------------------------------ |
| `app-path` | Path to the packaged `.app` (`<output-dir>/Base.app`). |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/build-ios-app@v1
  id: build
  with:
      app-dir: apps/mobile
      workspace: MyApp.xcworkspace
      scheme: MyApp
      derived-data-dir: ${{ github.workspace }}/.ci-cache/DerivedData/bare
      output-dir: .ci-cache/ios-native-app/bare
      pods-cache-key: pods-bare-${{ runner.os }}-xcode-26.4.1-${{ hashFiles('yarn.lock') }}
      rct-use-prebuilt-rncore: true
```
