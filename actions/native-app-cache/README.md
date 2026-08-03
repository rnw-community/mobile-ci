# native-app-cache

Restores or saves the canonical packaged native app (a `.app` bundle or
`.apk`) keyed on `<profile>-<os>-<arch>-<toolchain>-<fingerprint>`. This is the
"repack" cache at the core of the fleet's build-skip optimization: as long as
the native fingerprint (see `native-fingerprint`) has not moved, the packaged
shell from a previous run is reused and the native build (`xcodebuild` /
`gradlew`) never runs.

Call this action twice per job: once with `mode: restore` before the
conditional build steps, and once with `mode: save` after packaging — guarded
by `if: steps.<restore-id>.outputs.cache-hit != 'true'` so a warm cache never
re-saves the same key.

A restore hit only guarantees the native surface (package.json, native
folders, autolinking config) is unchanged — it does **not** guarantee the
embedded JS bundle reflects the current commit's application-layer JS.
Consumers that need JS-current warm builds should reseed on a schedule (see
the `seed-native-cache` reusable workflow) rather than rely solely on
fingerprint hits.

## Inputs

| Name          | Required | Description                                                         |
| ------------- | -------- | --------------------------------------------------------------------- |
| `mode`        | yes      | `restore` or `save`.                                                  |
| `path`        | yes      | Directory holding the packaged native app.                            |
| `profile`     | yes      | Cache-key segment for the build profile/target (e.g. `bare`, `expo`). |
| `arch`        | yes      | Cache-key segment for the target architecture.                        |
| `toolchain`   | yes      | Cache-key segment for the toolchain (Xcode build, cmdline-tools version). |
| `fingerprint` | yes      | Native fingerprint hash.                                               |

## Outputs

| Name        | Description                                    |
| ----------- | ------------------------------------------------ |
| `cache-hit` | `true` when an exact-key entry was restored.      |
| `cache-key` | The computed cache key.                           |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/native-app-cache@v1
  id: native-app-cache
  with:
      mode: restore
      path: .ci-cache/ios-native-app/bare
      profile: bare
      arch: arm64
      toolchain: ${{ steps.xcode.outputs.toolchain-key }}
      fingerprint: ${{ steps.fingerprint.outputs.hash }}

# ... build only when steps.native-app-cache.outputs.cache-hit != 'true' ...

- uses: rnw-community/mobile-ci/actions/native-app-cache@v1
  if: steps.native-app-cache.outputs.cache-hit != 'true'
  with:
      mode: save
      path: .ci-cache/ios-native-app/bare
      profile: bare
      arch: arm64
      toolchain: ${{ steps.xcode.outputs.toolchain-key }}
      fingerprint: ${{ steps.fingerprint.outputs.hash }}
```
