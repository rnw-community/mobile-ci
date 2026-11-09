# install-cache

Caches files a dependency's install script downloads outside the package
manager's store, such as a postinstall that fetches native binaries into its own
package directory. [`node-pm-cache`](../node-pm-cache/README.md) never covers
those files, so every job downloads them again. One example is `llama.rn`, whose
postinstall writes about 320 MB into
`node_modules/.pnpm/llama.rn@<peer hash>/node_modules/llama.rn/{android/src/main/jniLibs,ios/rnllama.xcframework}`
on every install. A slow or failing release host then fails every lane.

You choose the paths and the key. The action restores them **before** the
install. The calling workflow saves them after the install, off pull requests,
on a miss, as a bounded `continue-on-error` step. The save cannot live in this
action, because the runner rejects `timeout-minutes` on a composite-action step.
With `paths` and `key` both empty the action does nothing, and the save is
skipped.

Every reusable workflow that runs the consumer's `install-command` wraps it this
way when you set its `install-cache-paths` and `install-cache-key` inputs:
`android-maestro`, `ios-maestro`, `expo-base-plan`, `seed-native-cache`,
`store-screenshots`, `native-publish`, `native-dev-release`,
`expo-ota-preview`, `expo-fingerprint-guard` (the head tree),
`assert-distinct-fingerprints` and `eas-channel-cleanup-reusable`. The e2e
project's `e2e-install-command` is a separate project and is not wrapped.

## When it works: the restored files must survive the install

The cache helps only when the package manager leaves the restored files where
they are, and the dependency's script then finds them and skips its download.
Measured on a fresh `node_modules` with a stand-in package whose postinstall
writes into its own directory and skips when its marker matches:

| Package manager | Restored before `install --frozen-lockfile` |
| --------------- | ------------------------------------------- |
| pnpm 12.16.1    | Kept. The postinstall finds the marker and skips the download. |
| pnpm 11.28.3, 10.33.0 | Removed. pnpm re-imports the package directory and the postinstall downloads again. |

When pnpm's side-effects cache already holds the package's built files, pnpm
re-imports them from the store instead. Those files are the same bytes, so that
case downloads nothing either.

With a manager that removes the files, nothing breaks: the install downloads
exactly as it does without this cache. The cache saves nothing there.

Correctness comes from the dependency, not from this action. Use it only for an
install script that checks what it finds against what it expects and downloads
again on a mismatch. `llama.rn` compares the sha256 marker inside each artifact
directory with `install/native-artifacts.json`. A key that falls behind the
dependency then costs a download on every run, but never installs stale files.

Restored files are the bytes an earlier install downloaded, so anything hashed
from them, such as an Expo fingerprint over autolinked native sources, is
unchanged.

## Key

The full key is `install-cache-v1-<runner os>-<key>`. There are no restore-keys,
because a prefix match would restore files from another version. Derive the key
from what decides the downloaded files, usually the dependency's version. A
reusable workflow's `with:` cannot call `hashFiles`, so pass a literal and change
it in the same commit that bumps the dependency. A key built from the whole
lockfile also works, but it stores another copy of the files on every lockfile
change.

`paths` are `actions/cache` patterns, relative to the workspace (the repository
root, where every wrapped `install-command` runs). Globs resolve on save, so
`llama.rn@*` matches pnpm's peer-hash directory. The restore extracts the
archived paths as they were saved. Use the same `paths` string for the restore
and the save: `actions/cache` hashes the literal patterns into the entry's
version.

## Inputs

| Name    | Required | Default | Description |
| ------- | -------- | ------- | ----------- |
| `paths` | no       | `''`    | Newline-separated paths or globs, relative to the workspace, that the install writes. Set together with `key`. |
| `key`   | no       | `''`    | Your cache key, prefixed `install-cache-v1-<runner os>-`. No commas. Set together with `paths`. |

Setting only one of the two fails the step.

## Outputs

| Name        | Description |
| ----------- | ----------- |
| `cache-hit` | `true` when the exact key was restored. |
| `cache-key` | The full key; empty when the action is off. |
| `paths`     | The `paths` input, for `actions/cache/save`. |

## Example

A reusable workflow caller, for `llama.rn` under pnpm:

```yaml
jobs:
    e2e:
        permissions:
            contents: read
            packages: write
            actions: read
        uses: rnw-community/mobile-ci/.github/workflows/ios-maestro.yml@v4.11.2 # v4.11.2
        with:
            targets: >-
                [{"name":"app","appDir":"packages/app","workspace":"App.xcworkspace","scheme":"App","appId":"com.example.app","prebuildCommand":"npx expo prebuild -p ios"}]
            flows-dir: packages/app/e2e/flows
            install-command: pnpm install --frozen-lockfile
            install-cache-paths: |
                node_modules/.pnpm/llama.rn@*/node_modules/llama.rn/android/src/main/jniLibs
                node_modules/.pnpm/llama.rn@*/node_modules/llama.rn/ios/rnllama.xcframework
            install-cache-key: llama.rn-0.13.0-rc.7
```

Composing the action yourself:

```yaml
- name: Restore install cache
  id: install-cache
  uses: rnw-community/mobile-ci/actions/install-cache@v4.12.0 # v4.12.0
  with:
      paths: |
          node_modules/.pnpm/llama.rn@*/node_modules/llama.rn/android/src/main/jniLibs
          node_modules/.pnpm/llama.rn@*/node_modules/llama.rn/ios/rnllama.xcframework
      key: llama.rn-0.13.0-rc.7
- run: pnpm install --frozen-lockfile
- name: Save install cache
  if: github.event_name != 'pull_request' && steps.install-cache.outputs.cache-key != '' && steps.install-cache.outputs.cache-hit != 'true'
  uses: actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0
  timeout-minutes: 10
  continue-on-error: true
  with:
      path: ${{ steps.install-cache.outputs.paths }}
      key: ${{ steps.install-cache.outputs.cache-key }}
```
