# rn-prebuilt-cache

Restores React Native's prebuilt iOS tarball cache, `~/Library/Caches/ReactNative`.
`pod install` keeps the ReactNativeCore and ReactNativeDependencies debug and release
tarballs there when `rct-use-prebuilt-rncore` and the prebuilt dependencies are on.
On an ephemeral macOS guest that directory starts empty, so every build otherwise
downloads all four from `repo.reactnative.dev` (`[ReactNativeCore] Cache miss:
downloading ...`). The key is the installed `react-native` version, exact match
only. React Native verifies each tarball's checksum before using it.

Restore-only, like [`node-pm-cache`](../node-pm-cache/README.md). The calling
workflow saves with its own bounded, non-fatal `actions/cache/save` step after
the build, off pull requests and only on a miss. The `ios-maestro`,
`store-screenshots` and `seed-native-cache` iOS build jobs already do this.

| Input | Default | Description |
| --- | --- | --- |
| `app-dir` | `.` | Directory whose `node_modules` resolves `react-native`. Install dependencies first; an unresolvable `react-native` fails the step. |

| Output | Description |
| --- | --- |
| `cache-hit` | `true` when the entry for this `react-native` version was restored. |
| `cache-key` | `rn-prebuilts-v1-<os>-<arch>-<react-native version>`. |
| `path` | The cache directory, for the save step. |

```yaml
- name: Restore the React Native prebuilt cache
  id: rn-prebuilts
  uses: rnw-community/mobile-ci/actions/rn-prebuilt-cache@v4.6.0 # v4.6.0
  with:
      app-dir: apps/mobile
# ... pod install / build-ios-app ...
- name: Save the React Native prebuilt cache
  if: github.event_name != 'pull_request' && steps.rn-prebuilts.outputs.cache-hit != 'true'
  uses: actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0
  timeout-minutes: 10
  continue-on-error: true
  with:
      path: ${{ steps.rn-prebuilts.outputs.path }}
      key: ${{ steps.rn-prebuilts.outputs.cache-key }}
```
