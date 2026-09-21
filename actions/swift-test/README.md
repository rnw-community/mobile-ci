# swift-test

Runs a Swift Package's test suite with `swift test --parallel` and publishes a
pass/fail step summary. The package's `.build` directory is cached on the same
`<prefix>-<os>-<toolchain>-<fingerprint>` key scheme
[`xcode-cache`](../xcode-cache/README.md) uses, with the same two backends
(`github` via `actions/cache`, or `local` — a plain directory on a self-hosted
fleet's shared mount, no network).

This is the cheapest test lane a native Swift app has: pure-logic targets run
in seconds without a simulator, so a simulator-bound `xcodebuild test` only
has to cover what genuinely needs UIKit.

A fingerprint that matches **zero** files fails the step rather than producing
a key over nothing, and `.git` / `.build` are excluded from every glob form, so
a pattern like `.build/*.json` cannot make the key depend on generated build
output. `.build` must resolve to a physical child of
`package-path`: a symlink redirecting it would make a save copy whatever it
points at into the cache, and a restore `rsync --delete` into it. That check
runs once, in the key step, so it covers both modes and both backends. A restore hit suppresses the matching save, so a warm run
never rewrites the same key.

## Inputs

| Name                | Required | Default                        | Description                                                        |
| ------------------- | -------- | ------------------------------ | -------------------------------------------------------------------- |
| `package-path`      | no       | `.`                            | Directory holding `Package.swift`.                                   |
| `extra-args`        | no       | `''`                           | Extra arguments appended to `swift test --parallel`.                 |
| `toolchain`         | yes      | —                              | Toolchain key segment, e.g. `setup-xcode-pinned`'s `toolchain-key`.  |
| `cache`             | no       | `true`                         | Restore and save `.build`.                                           |
| `backend`           | no       | `github`                       | `github` (actions/cache) or `local` (a directory under `local-dir`). |
| `local-dir`         | no       | `''`                           | Cache root for `backend: local`. Required when `backend` is `local`. |
| `fingerprint-paths` | no       | `Package.swift`, `Package.resolved` | Newline- or space-separated globs hashed into the key.          |
| `key-prefix`        | no       | `swift-build-v1`               | Key namespace; bump it to invalidate every entry at once.            |

## Outputs

| Name        | Description                                            |
| ----------- | -------------------------------------------------------- |
| `cache-hit` | `true` when an exact-key `.build` entry was restored.     |
| `cache-key` | The computed `.build` cache key.                          |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/setup-xcode-pinned@v1
  id: xcode
  with:
      version: '26.4.1'
      build: '17E202'

- uses: rnw-community/mobile-ci/actions/swift-test@v1
  with:
      toolchain: ${{ steps.xcode.outputs.toolchain-key }}
      package-path: .
      extra-args: --disable-sandbox
```
