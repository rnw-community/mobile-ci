# xcode-cache

Restores or saves the three directories an incremental `xcodebuild` actually
reuses between runs:

- **DerivedData** (`-derivedDataPath`) — the module cache, index, and build
  products.
- **Resolved Swift Package clones** (`-clonedSourcePackagesDirPath`) — so a
  cold run never re-clones every package dependency.
- **The Xcode 26 compilation cache / CAS** (`COMPILATION_CACHE_ENABLE_CACHING=YES`,
  `COMPILATION_CACHE_CAS_PATH`) — content-addressed compiled outputs, which
  survive a DerivedData path change and are shareable across checkouts.

The cache key is `<key-prefix>-<RUNNER_OS>-<toolchain>-<fingerprint>`, where
`toolchain` is `setup-xcode-pinned`'s `toolchain-key` output and `fingerprint`
is a SHA-256 over the contents of every file matched by `fingerprint-paths`.
Matching **zero** files fails the step: a key computed over an empty
fingerprint would collide across unrelated projects and hand one project
another's DerivedData.

Call the action twice per job — `mode: restore` before the build, `mode: save`
after it — and guard the save with
`if: steps.<restore-id>.outputs.cache-hit != 'true'` so a warm run never
rewrites the same key.

## Backends

| `backend` | Storage                                                                 |
| --------- | ------------------------------------------------------------------------- |
| `github`  | `actions/cache` (default). Works anywhere, costs a network round trip and counts against the repository cache quota. |
| `local`   | A plain directory under `local-dir`, copied with `rsync`. No network at all — meant for a self-hosted fleet where every VM mounts the same `ci-shared` host directory. |

A `local` entry is a directory named after the cache key holding
`derived-data/`, `spm-clones/`, `cas/`, and a `.complete` marker written last.
A restore only counts as a hit when `.complete` exists, so a save interrupted
mid-copy is never read back as a cache. Saves stage into a scratch directory
and swap it in with `mv`, so a concurrent reader never observes a half-written
entry. `restore-keys` is a `github`-only concept; the `local` backend takes
exact-key hits only.

## Inputs

| Name                 | Required | Default                                     | Description                                                                 |
| -------------------- | -------- | ------------------------------------------- | --------------------------------------------------------------------------- |
| `mode`               | yes      | —                                           | `restore` or `save`.                                                         |
| `backend`            | no       | `github`                                    | `github` (actions/cache) or `local` (a directory under `local-dir`).         |
| `local-dir`          | no       | `''`                                        | Cache root for `backend: local`. Required when `backend` is `local`.         |
| `derived-data-dir`   | no       | `build/DerivedData`                         | DerivedData directory, relative to `working-directory` or absolute.          |
| `spm-clones-dir`     | no       | `build/SourcePackages`                      | Swift Package clone directory.                                               |
| `cas-dir`            | no       | `build/CompilationCache`                    | Xcode 26 compilation-cache (CAS) directory.                                  |
| `toolchain`          | yes      | —                                           | Toolchain key segment, e.g. `setup-xcode-pinned`'s `toolchain-key`.          |
| `fingerprint-paths`  | no       | `**/*.pbxproj`, `Package.swift`, `**/Package.resolved` | Newline- or space-separated globs hashed into the key.            |
| `working-directory`  | no       | `.`                                         | Directory the globs and cache directories resolve against.                   |
| `key-prefix`         | no       | `xcode-cache-v1`                            | Key namespace; bump it to invalidate every entry at once.                    |
| `restore-keys`       | no       | `''`                                        | Newline-separated fallback prefixes for a `github` restore.                  |

## Outputs

| Name              | Description                                                                          |
| ----------------- | -------------------------------------------------------------------------------------- |
| `cache-hit`       | `true` when an exact-key entry was restored.                                            |
| `cache-key`       | The computed cache key.                                                                 |
| `cache-paths`     | Newline-separated resolved absolute paths of the three cached directories.              |
| `xcodebuild-args` | Shell word list to append to every `xcodebuild` invocation in the job.                  |

`xcodebuild-args` is a plain shell word list, so none of the three directories
may contain whitespace — the action fails closed if one does. Relative inputs
are resolved against `working-directory` and absolute ones are used as given;
both backends operate on those resolved paths (`cache-paths`), so an absolute
`derived-data-dir` caches the directory `xcodebuild` actually writes to rather
than an empty one under the workspace.

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/setup-xcode-pinned@v1
  id: xcode
  with:
      version: '26.4.1'
      build: '17E202'

- uses: rnw-community/mobile-ci/actions/xcode-cache@v1
  id: cache
  with:
      mode: restore
      toolchain: ${{ steps.xcode.outputs.toolchain-key }}

- name: Build
  env:
      XCODEBUILD_ARGS: ${{ steps.cache.outputs.xcodebuild-args }}
  run: |
      # shellcheck disable=SC2086
      xcodebuild -project MyApp.xcodeproj -scheme MyApp $XCODEBUILD_ARGS build

- uses: rnw-community/mobile-ci/actions/xcode-cache@v1
  if: always() && steps.cache.outputs.cache-hit != 'true'
  with:
      mode: save
      toolchain: ${{ steps.xcode.outputs.toolchain-key }}
```
