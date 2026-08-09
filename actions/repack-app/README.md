# repack-app

Injects a freshly exported JS bundle into an already-built native `.app`
(ios) or `.apk` (android) in place, via `npx @expo/repack-app`, without
rerunning the native build. Intended for a `native-app-cache` hit: the native
shell is safe to reuse, but the embedded JS bundle may be stale relative to
the commit under test. After repacking, this action validates the result —
an expected bundle id/package name and JS bundle presence — and fails closed
if either check does not pass. It does not fall back to a native build
itself; run it with `continue-on-error: true` and branch on the outcome in
the calling workflow (see `ios-maestro.yml` / `android-maestro.yml`'s
`repack-on-hit` input for the reference integration).

## Inputs

| Name                       | Required | Default | Description                                                                                     |
| --------------------------- | -------- | ------- | ------------------------------------------------------------------------------------------------ |
| `platform`                  | yes      | —       | `ios` or `android`.                                                                                |
| `app-path`                  | yes      | —       | Path to the cached native app to repack in place: a `Base.app` directory (ios) or an `.apk` file (android). |
| `app-id`                    | yes      | —       | Expected bundle identifier (ios) or package name (android), validated after repack.               |
| `app-dir`                   | no       | `.`     | App/project directory `@expo/repack-app` runs against (its `project-root` argument) to export a fresh JS bundle. |
| `repack-version`            | no       | `0.7.2` | Pinned `@expo/repack-app` npm version.                                                             |
| `working-directory`         | no       | `''`    | Scratch directory `@expo/repack-app` uses for intermediate artifacts. Tool default when empty.    |
| `android-build-tools-dir`   | no       | `''`    | Android SDK build-tools directory, passed as `--android-build-tools-dir` and reused for this action's own `aapt2` validation. Ignored for ios; falls back to `aapt2` on `PATH` when empty. |
| `js-bundle-only`            | no       | `true`  | Passes `--js-bundle-only` — repacks only the JS bundle/assets, skipping native config updates.     |
| `embed-bundle-assets`       | no       | `false` | Passes `--embed-bundle-assets`.                                                                     |
| `keystore-path`             | no       | `''`    | Android signing keystore, passed as `--ks`. Ignored for ios; omitted (tool default) when empty.    |
| `keystore-password`         | no       | `''`    | Android keystore password, passed as `--ks-pass`. Ignored when `keystore-path` is empty.           |
| `keystore-key-alias`        | no       | `''`    | Android keystore key alias, passed as `--ks-key-alias`. Ignored when `keystore-path` is empty.     |
| `keystore-key-password`     | no       | `''`    | Android keystore key password, passed as `--ks-key-pass`. Ignored when `keystore-path` is empty.   |
| `verbose`                   | no       | `false` | Passes `--verbose` to `@expo/repack-app`.                                                            |

## Outputs

| Name       | Description                                                       |
| ---------- | ------------------------------------------------------------------- |
| `app-path` | Path to the repacked native app (same path as the `app-path` input). |

## Example

```yaml
- name: Repack fresh JS into cached native app
  id: repack
  if: steps.native-app-cache.outputs.cache-hit == 'true'
  continue-on-error: true
  uses: rnw-community/mobile-ci/actions/repack-app@v1
  with:
      platform: ios
      app-path: .ci-cache/ios-native-app/bare/Base.app
      app-id: com.example.app
      app-dir: apps/mobile

- name: Fall back to a full build if repack failed
  if: steps.native-app-cache.outputs.cache-hit == 'true' && steps.repack.outcome == 'failure'
  run: echo "repack-app failed; the calling workflow's build steps run instead."
```
