# setup-xcode-pinned

Selects a pre-installed Xcode toolchain by exact version and build number. The
runner is expected to already have `/Applications/Xcode_<version>.app`
installed (self-hosted macOS fleets typically carry several pinned Xcode
installations side by side). This action never installs or switches Xcode via
`xcode-select -s` globally — it only exports `DEVELOPER_DIR` for the current
job, and hard-asserts both the version string and the build number reported by
`xcodebuild -version` before any build step runs. A drifted or missing
toolchain fails the job immediately instead of silently building with the
wrong compiler.

## Inputs

| Name      | Required | Description                                             |
| --------- | -------- | -------------------------------------------------------- |
| `version` | yes      | Xcode version string, e.g. `26.4.1`.                     |
| `build`   | yes      | Xcode build number, e.g. `17E202`.                       |

## Outputs

| Name             | Description                                              |
| ---------------- | ---------------------------------------------------------- |
| `developer-dir`   | Resolved `DEVELOPER_DIR` path for the selected Xcode.      |
| `toolchain-key`   | Cache-key segment: `xcode-<version>-<build>`.              |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/setup-xcode-pinned@v1
  id: xcode
  with:
      version: '26.4.1'
      build: '17E202'

- run: xcodebuild -version
```
