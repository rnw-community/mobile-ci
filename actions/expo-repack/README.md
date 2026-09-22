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
| `android-build-tools-dir` | no       | `''`     | Build-tools directory holding `zipalign`/`apksigner`. Empty falls back to `PATH`.     |
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
- uses: rnw-community/mobile-ci/actions/expo-repack@v3.0.0 # v3.0.0
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
