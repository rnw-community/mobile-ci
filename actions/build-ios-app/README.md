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

**Prebuilt/precompiled flags are applied at `pod install`, not just the build
step (behavior fix).** `RCT_USE_PREBUILT_RNCORE`, `RCT_USE_RN_DEP`, and
`EXPO_USE_PRECOMPILED_MODULES` are read by React Native's and Expo's CocoaPods
scripts while the Pods project is being generated — not by `xcodebuild`. They
used to be set only on the `xcodebuild` step, which made them no-ops unless
the consumer independently pinned the same switches through
`expo-build-properties`. They are now exported for `pod install` as well (and
the reusable workflows export them for the `expo prebuild` step, which runs
`pod install` itself).

They are also **omitted entirely** when their input is not `true`, instead of
being exported as an empty string: the Ruby side tests for the variable's
presence (`ENV['RCT_USE_PREBUILT_RNCORE']` is truthy even when `""`), so an
empty export read as *enabled*. If your build previously behaved as if a flag
was off while it was set to `false`, that is now actually the case — and
because the flags now reach `pod install`/prebuild, the generated Pods project
(and therefore the native fingerprint the caching workflows compute) can
change, invalidating an existing native-app cache once.

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
| `rct-use-prebuilt-rncore`        | no       | `false`   | Exports `RCT_USE_PREBUILT_RNCORE=1` for `pod install` **and** `xcodebuild` when `true`; exports nothing at all otherwise. |
| `rct-use-rn-dep`                 | no       | `false`   | Exports `RCT_USE_RN_DEP=1` for `pod install` **and** `xcodebuild` when `true`; exports nothing at all otherwise. |
| `expo-use-precompiled-modules`   | no       | `false`   | Exports `EXPO_USE_PRECOMPILED_MODULES=1` for `pod install` **and** `xcodebuild` when `true`; exports nothing at all otherwise. |

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
