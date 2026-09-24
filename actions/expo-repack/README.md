# expo-repack

Turns a published base binary into this build's binary without compiling native
code. `@expo/repack-app --embed-bundle-assets` re-bundles the JavaScript with
the repository's own Metro and Hermes under `NODE_ENV=production`, swaps the
bundle and assets into the simulator `.app` or the APK, and rewrites the
embedded Expo config with the values `repack-env` supplies (API URL, version,
build number, anything else the consumer's `app.config` reads).

Then it **asserts**: every `expect-config` entry, plus the bundle identifier or
package name, must be exactly what the embedded `app.config` carries. On android
the repacked APK is additionally signed with the consumer's keystore (the same
debug keystore the base was signed with, or the emulator refuses the upgrade)
and the signature is verified with `apksigner`.

Three things it refuses rather than works around:

- a base with no embedded bundle (`main.jsbundle` / `assets/index.android.bundle`)
  — that is a Debug build whose JavaScript comes from a dev server;
- a repacked binary with no embedded `app.config` — a rewrite nobody can check;
- any assertion that does not hold.

There is no fallback to the base's own JavaScript. A broken repack fails the
build, which is the only way the artifact a Maestro shard installs can be
trusted to be this commit's app.

## Running on Linux

The repack is meant for a Linux host with no Xcode, and two tools it needs are
provided rather than assumed:

- **`plutil` (ios).** `@expo/repack-app` converts the base's `Info.plist` with
  `plutil -convert xml1 <file>` before reading it and `plutil -convert binary1
  <file>` after writing it. On a host with no `plutil` the action puts a
  `python3` stand-in on the repack's `PATH` implementing exactly those two
  in-place conversions with `plistlib`; any other `plutil` invocation fails,
  naming itself, so a future `@expo/repack-app` needing more is caught rather
  than mishandled. A host with a real `plutil` keeps it. The host needs
  `python3`.
- **`apksigner` and `zipalign` (android).** With `android-build-tools-dir`
  empty, the build-tools directory is resolved under the SDK
  `android-actions/setup-android` installed (`ANDROID_SDK_ROOT`, or
  `ANDROID_HOME`) — the `android-build-tools-version` directory when set — and
  used both by `@expo/repack-app` and by the signature check.

## Inputs

| Name                      | Required | Default  | Description                                                                          |
| ------------------------- | -------- | -------- | ------------------------------------------------------------------------------------- |
| `platform`                | yes      | —        | `ios` or `android`.                                                                   |
| `base-path`               | yes      | —        | The base binary: a `.tar.gz` holding one `.app` on ios, an `.apk` on android.         |
| `output-path`             | yes      | —        | Where the repacked binary is written, in the same shape the test job consumes.        |
| `app-id`                  | yes      | —        | Expected bundle identifier / package name, asserted against the embedded config.      |
| `app-dir`                 | no       | `.`      | App/project directory `@expo/repack-app` runs against.                                |
| `repack-env`              | no       | `''`     | Newline-separated `KEY=VALUE` exported for the re-bundle.                             |
| `expect-config`           | no       | `''`     | Newline-separated `<dotted.path>=<value>` assertions on the embedded `app.config`.    |
| `repack-version`          | no       | `0.7.2`  | Pinned `@expo/repack-app` npm version.                                                |
| `android-build-tools-dir` | no       | `''`     | Build-tools directory holding `zipalign`/`apksigner`. Empty resolves it under `ANDROID_SDK_ROOT` (or `ANDROID_HOME`): the `android-build-tools-version` directory, else the newest installed one holding both tools (none fails the step); `PATH` only when no SDK is installed. |
| `android-build-tools-version` | no   | `''`     | Build-tools version resolved under the SDK when `android-build-tools-dir` is empty. A version the SDK does not hold fails the step, naming the path. |
| `keystore-path`           | no       | `''`     | Android signing keystore. Empty leaves `@expo/repack-app`'s default in place.         |
| `keystore-password`       | no       | `''`     | Keystore password.                                                                    |
| `keystore-key-alias`      | no       | `''`     | Keystore key alias.                                                                   |
| `keystore-key-password`   | no       | `''`     | Keystore key password.                                                                |
| `verbose`                 | no       | `false`  | Passes `--verbose` to `@expo/repack-app`.                                             |

## Outputs

| Name       | Description                                            |
| ---------- | ------------------------------------------------------- |
| `app-path` | Path to the repacked binary (the same as `output-path`). |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/expo-repack@v3.1.0 # v3.1.0
  with:
      platform: ios
      base-path: ${{ steps.base.outputs.path }}
      output-path: .ci-artifacts/ios-e2e-app-bare.tar.gz
      app-dir: apps/mobile
      app-id: com.example.app
      repack-env: |
          API_URL=https://staging.example.com
          APP_VERSION=1.4.0
      expect-config: |
          version=1.4.0
          extra.apiUrl=https://staging.example.com
```
