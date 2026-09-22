# expo-native-key

Computes the one key a base binary is published and looked up under. It is the
`@expo/fingerprint` hash of the platform's native surface — evaluated under the
same `extra-env` every consumer of the key uses, so a warm-up and a pull request
agree — folded together with three things a fingerprint cannot see on its own:

- the hash of the mobile-ci build action that produced the base
  (`build-ios-app` + `setup-xcode-pinned` on ios, `build-android-app` on
  android), so changing how the base is built invalidates every base built the
  old way;
- the pinned `toolchain` identity (`xcode-<version>-<build>`,
  `cmdline-<version>`), so a base is never repacked onto by a different
  toolchain;
- the hash of the `fingerprint.config.js` whose ignore list is the correctness
  boundary, so relaxing an ignore rule invalidates every base published under
  the old one.

The fingerprint itself comes from [`native-fingerprint`](../native-fingerprint) —
one fingerprint implementation, used by this action, `expo-fingerprint-guard.yml`
and `expo-ota-preview.yml` alike. An empty fingerprint fails the step: a base
binary must never be stored or fetched under an empty key.

`extra-env` is the one thing to get right twice: every variable the app's
`app.config` branches on must appear both here and in the caller's `build-env`.
A variable set for the fingerprint but not for the build gives a key that
describes a native surface no build produces, and every run then repacks onto a
base built from something else. The key deliberately does **not** export
`flavor` for that reason — the native build does not export it either.

Read [docs/repack.md](../../docs/repack.md) for the `fingerprint.config.js`
contract and what the ignore list does and does not cover.

## Inputs

| Name                   | Required | Default                 | Description                                                                              |
| ---------------------- | -------- | ----------------------- | ---------------------------------------------------------------------------------------- |
| `platform`             | yes      | —                       | `ios` or `android`.                                                                       |
| `working-directory`    | no       | `.`                     | App directory whose native surface is fingerprinted.                                      |
| `flavor`               | no       | `e2e`                   | Flavor the base is published for. A segment of the key's address; deliberately not exported. |
| `extra-env`            | no       | `''`                    | Newline-separated `KEY=VALUE` exported for the fingerprint evaluation.                    |
| `toolchain`            | no       | `''`                    | Pinned toolchain identity folded into the key.                                            |
| `fingerprint-config`   | no       | `fingerprint.config.js` | Path, relative to `working-directory`, of the fingerprint config whose hash enters the key. |
| `fingerprint-version`  | no       | `0.20.6`                | Pinned `@expo/fingerprint` npm version.                                                   |

## Outputs

| Name                | Description                                                                 |
| ------------------- | ---------------------------------------------------------------------------- |
| `key`               | `<fingerprint>-<12 hex of the build identity>`.                              |
| `fingerprint`       | The bare `@expo/fingerprint` hash, without the build identity.               |
| `config-hash`       | SHA-256 of the fingerprint config, or `none` when the file is absent.        |
| `build-action-hash` | SHA-256 of the mobile-ci build action(s) that produce this platform's base.  |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/expo-native-key@v3.0.1 # v3.0.1
  id: key
  with:
      platform: ios
      working-directory: apps/mobile
      flavor: e2e
      toolchain: xcode-26.4.1-17E202

- run: echo "${{ steps.key.outputs.key }}"
```
