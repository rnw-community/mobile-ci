# ota-runtime-version

The one source of the runtime version an over-the-air update must target. It
runs the project's **own** `expo-updates`
(`npx --no-install expo-updates runtimeversion:resolve --platform <p>`): the
value `eas update` publishes under and the `expo-updates` client in the
binary compares against, for every runtime policy (`fingerprint`,
`appVersion`, `nativeVersion`, a fixed string). A downloaded, pinned
`@expo/fingerprint` can disagree with the project's after an Expo upgrade;
this cannot.

Used by both `expo-ota-preview.yml` backends, both `native-publish.yml`
`ota-baseline`s, `native-dev-release.yml`'s build marker (which the preview
comment matches against) and [`eas-channel-fingerprint`](../eas-channel-fingerprint/README.md).
`native-fingerprint` stays the cache key of native builds only.

Each platform (or target) resolves under, in order: its `eas.json` build
profile env (`extends` resolved by [`eas-profile-env`](../eas-profile-env/README.md))
with `EAS_BUILD_PROFILE`, then `env`; names in `unset-env` are removed first.
That is the env the matching `eas build` evaluates the app config under.

Fails closed: a resolution that fails or prints no runtime version (no
`expo-updates` installed, an app config that throws), an `env` line without
`=` or with an invalid name, an invalid `unset-env` name, and malformed
`targets` all fail the step.

## Inputs

| Name          | Required | Default | Description |
| ------------- | -------- | ------- | ----------- |
| `app-dir`     | no       | `'.'`   | App directory holding the app config and the installed `expo-updates`. |
| `platform`    | no       | `all`   | `all`, `ios` or `android`. Ignored with `targets`. |
| `eas-profile` | no       | `''`    | `eas.json` build profile whose env applies. Ignored with `targets`. |
| `targets`     | no       | `''`    | JSON array `[{"name", "platform", "envLines"?, "buildProfile"?}]`, one resolution each (`native-publish.yml`'s resolved targets fit as they are). |
| `env`         | no       | `''`    | `KEY=VALUE` lines applied after the profile env, for every resolution. |
| `unset-env`   | no       | `''`    | Variable names removed first, e.g. secrets the build never sees. |

## Outputs

| Name                      | Description |
| ------------------------- | ----------- |
| `runtime-versions`        | JSON object of target name (the platform without `targets`) to runtime version. |
| `ios-runtime-version`     | iOS runtime version, without `targets`. |
| `android-runtime-version` | Android runtime version, without `targets`. |

## Example

```yaml
- id: runtime
  uses: rnw-community/mobile-ci/actions/ota-runtime-version@v4.4.0 # v4.4.0
  with:
      app-dir: apps/mobile
      eas-profile: development
- uses: rnw-community/mobile-ci/actions/eas-update@v4.4.0 # v4.4.0
  with:
      app-dir: apps/mobile
      channel: development
      eas-profile: development
      ios-runtime-version: ${{ steps.runtime.outputs.ios-runtime-version }}
      android-runtime-version: ${{ steps.runtime.outputs.android-runtime-version }}
      expo-token: ${{ secrets.EXPO_TOKEN }}
```
