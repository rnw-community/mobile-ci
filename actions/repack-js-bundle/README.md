# repack-js-bundle

Re-bundles JS from the current checkout and replaces the embedded bundle
inside an already-packaged native app — the fix for the correctness gap in
`native-app-cache`: a fingerprint cache hit only guarantees the native surface
is unchanged, not that the embedded JS reflects the current commit. Call this
action on every `native-app-cache` restore hit, immediately before install, so
a JS-only change is never tested against a stale bundle baked in when that
cache entry was last built. Native compilation (`xcodebuild` / `gradlew`)
stays skipped either way — that remains the point of the cache.

- **iOS** — re-bundles directly into `<app-path>/main.jsbundle` plus its
  loose asset tree, the same layout `react-native-xcode.sh` produces at build
  time. No re-signing: the packaged `.app` this fleet builds is unsigned
  (`CODE_SIGNING_ALLOWED=NO`), simulator-only.
- **Android** — bundles to a staging directory, replaces
  `assets/index.android.bundle` inside the `.apk` in place, then re-signs
  (rewriting a zip entry invalidates the existing APK Signature Scheme v2/v3
  block). New drawable resources introduced by a change are not merged this
  way — that gap does not apply to a JS-only change, and a change that adds a
  new image asset shifts the native fingerprint (a new file under the app
  tree) and takes the full-rebuild path instead of hitting this action at all.

## Inputs

| Name                   | Required | Description                                                              |
| ----------------------- | -------- | --------------------------------------------------------------------------- |
| `platform`              | yes      | `ios` or `android`.                                                          |
| `app-dir`               | yes      | App directory containing the JS entry point and `ios/`/`android/` folder.    |
| `app-path`              | yes      | The `.app` directory (iOS) or `.apk` file (Android) to repack in place.      |
| `entry-file`            | no       | Metro entry file, relative to `app-dir`. Default `index.js`.                 |
| `bundle-command`        | no       | Full override for the bundling command (`BUNDLE_OUTPUT`/`ASSETS_DEST` exported). Only for a non-standard Metro setup. |
| `keystore-path`         | no       | Android only, relative to `app-dir`. Default `android/app/debug.keystore` — the React Native CLI template's checked-in debug keystore location. |
| `key-alias`             | no       | Android only. Default `androiddebugkey`.                                    |
| `store-password`        | no       | Android only. Default `android`.                                            |
| `key-password`          | no       | Android only. Default `android`.                                            |
| `build-tools-version`   | no       | Android build-tools version providing `apksigner`/`zipalign`. Empty (default) auto-detects the highest installed under `ANDROID_HOME`. |

## Example

```yaml
- name: native-app-cache (restore)
  id: native-app-cache
  uses: rnw-community/mobile-ci/actions/native-app-cache@v1
  with:
      mode: restore
      path: .ci-cache/android-native-app/bare
      profile: android-native-v1-bare
      arch: x86_64
      toolchain: cmdline-12266719
      fingerprint: ${{ steps.fingerprint.outputs.hash }}

- name: repack-js-bundle (cache hit)
  if: steps.native-app-cache.outputs.cache-hit == 'true'
  uses: rnw-community/mobile-ci/actions/repack-js-bundle@v1
  with:
      platform: android
      app-dir: apps/bare
      app-path: .ci-cache/android-native-app/bare/app-release.apk
```

Android re-signing needs `ANDROID_HOME` and `apksigner`/`zipalign` on `PATH` —
run `android-actions/setup-android` (or `build-android-app`, which sets it up
internally) before this action on the Android path, even on a cache hit.
