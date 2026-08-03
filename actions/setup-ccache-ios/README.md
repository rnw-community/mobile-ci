# setup-ccache-ios

Installs (via Homebrew, if missing) and configures a bounded, compressed
`ccache` for `xcodebuild` invocations, then restores or saves a layered cache
of compiled objects. `USE_CCACHE`, `CCACHE_COMPRESS`, `CCACHE_MAXSIZE`,
`CCACHE_NOHASHDIR`, `CCACHE_DIR`, and `CCACHE_BASEDIR` are exported to
`GITHUB_ENV` so a subsequent `xcodebuild` step picks up ccache transparently
via the `ccache`-shimmed compiler on `PATH`.

Call this action twice per job: `mode: restore` before the build step, then
`mode: save` after — guarded the same way as `native-app-cache`, so a native
cache hit skips both the build and the ccache save.

## Inputs

| Name                 | Required | Default   | Description                                          |
| --------------------- | -------- | --------- | ------------------------------------------------------ |
| `mode`                | no       | `restore` | `restore` or `save`.                                    |
| `ccache-dir`          | yes      | —         | Directory ccache uses as its store.                     |
| `derived-data-dir`    | no       | `''`      | DerivedData directory created alongside the ccache dir. |
| `max-size`            | no       | `2G`      | Bounded, compressed ccache maximum size.                |
| `key`                 | yes      | —         | Exact cache key for restore/save.                       |
| `restore-keys`        | no       | `''`      | Newline-separated fallback prefixes for restore.        |

## Outputs

| Name        | Description                               |
| ----------- | -------------------------------------------- |
| `cache-hit` | `true` when an exact-key entry was restored.  |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/setup-ccache-ios@v1
  if: steps.native-app-cache.outputs.cache-hit != 'true'
  with:
      mode: restore
      ccache-dir: ${{ github.workspace }}/.ci-cache/ccache/ios-bare
      derived-data-dir: ${{ github.workspace }}/.ci-cache/DerivedData/bare
      key: ccache-ios-bare-${{ runner.os }}-xcode-26.4.1-${{ hashFiles('yarn.lock') }}

# ... xcodebuild step runs here, transparently using ccache ...

- uses: rnw-community/mobile-ci/actions/setup-ccache-ios@v1
  if: steps.native-app-cache.outputs.cache-hit != 'true'
  with:
      mode: save
      ccache-dir: ${{ github.workspace }}/.ci-cache/ccache/ios-bare
      key: ccache-ios-bare-${{ runner.os }}-xcode-26.4.1-${{ hashFiles('yarn.lock') }}
```
