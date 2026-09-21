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

The cache key is `<key-prefix>-<RUNNER_OS>-<RUNNER_ARCH>-<toolchain>-<fingerprint>`, where
`toolchain` is `setup-xcode-pinned`'s `toolchain-key` output and `fingerprint`
is a SHA-256 over the contents of every file matched by `fingerprint-paths`.
Matching **zero** files fails the step: a key computed over an empty
fingerprint would collide across unrelated projects and hand one project
another's DerivedData.

A `**` is expanded with `find`, so `**/*.swift` and `Sources/**/*.swift` both
work. The three cache directories, `.git` and `.build` are never matched, so a
`Package.resolved` or a `.swift` restored *into* the cache cannot perturb its
own key — and that holds whether the directory was given relatively or as an
absolute path under `working-directory`, because the exclusion is a literal
path-prefix test rather than a regex built from the input.

`RUNNER_ARCH` is in the key because compiled products are not portable between
Intel and Apple-silicon runners.

**The default fingerprint covers the build inputs on purpose.** Sources,
project files, lockfiles, xcconfigs, plists and entitlements — everything a
plain Xcode/SwiftPM app compiles from. A build job
and its test shards share this key (see
[`xcodebuild-test`](../xcodebuild-test/README.md)'s `mode`), so a key that did
not move with the sources would let a shard restore the previous commit's
compiled products and report `test-without-building` green without testing the
current source. Narrow `fingerprint-paths` only if nothing downstream reuses
the compiled products.

It is **deliberately not exhaustive, and cannot be**: a project with an asset
catalog, generated resources, or a script phase that reads files outside these
globs must add them to `fingerprint-paths`. What the default guarantees is that
no *cache directory's own contents* ever enter the fingerprint, on any glob
form — recursive or not. The Xcode 26 CAS is what keeps a source change cheap:
the key misses, but the unchanged translation units are still content-addressed
hits.

`key-prefix` is the place to put anything else that changes the identity of the
compiled products — most importantly the **scheme and configuration** when one
`derived-data-dir` is shared between them. `swift-ios.yml` passes
`xcode-cache-v1-<scheme>-<configuration>` for exactly that reason.

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
Each save stages into its own `mktemp -d` directory, so two matrix jobs on
different hosts sharing one mount cannot collide on a staging path.
A restore only counts as a hit when `.complete` exists, so a save interrupted
mid-copy is never read back as a cache. Saves stage into a scratch directory
and swap it in with `mv`, so a concurrent reader never observes a half-written
entry.

**There are no fallback keys, on either backend.** A prefix-matched restore
would populate DerivedData from an *older* fingerprint while reporting
`cache-hit: false`, and a `test-without-building` shard would then run the
wrong revision's products and pass. Only an exact-key hit is a hit. The Xcode
26 CAS is the safe version of the same idea: it is content-addressed, so a
partial reuse after a key miss can never be a stale one.

The computed key must be a single safe path component — `key-prefix` and
`toolchain` may not contain `/` or `..`, which the `local` backend would
otherwise follow out of `local-dir`.

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
| `fingerprint-paths`  | no       | `**/*.pbxproj`, `Package.swift`, `**/Package.resolved`, `**/*.swift`, `**/*.xcconfig`, `**/*.plist`, `**/*.entitlements` | Newline- or space-separated globs hashed into the key. |
| `working-directory`  | no       | `.`                                         | Directory the globs and cache directories resolve against.                   |
| `key-prefix`         | no       | `xcode-cache-v1`                            | Key namespace; bump it to invalidate every entry at once.                    |

## Outputs

| Name              | Description                                                                          |
| ----------------- | -------------------------------------------------------------------------------------- |
| `cache-hit`       | `true` when an exact-key entry was restored.                                            |
| `cache-key`       | The computed cache key.                                                                 |
| `cache-paths`     | Newline-separated resolved absolute paths of the three cached directories.              |
| `xcodebuild-args` | Shell word list to append to every `xcodebuild` invocation in the job.                  |

`xcodebuild-args` is a plain shell word list, so none of the three directories
may contain whitespace or a shell glob metacharacter (`*`, `?`, `[`) — the
action fails closed if one does, rather than letting the caller's unquoted
expansion mangle the path.

None of them may contain a `.` or `..` segment, or resolve (through symlinks)
to the working directory or to `/`. The `local` backend restores into them with
`rsync -a --delete`, so a `derived-data-dir` of `.` would delete the checkout. Relative inputs
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
