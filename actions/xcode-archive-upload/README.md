# xcode-archive-upload

Archives a scheme for `generic/platform=iOS` with **manual** signing, then
exports it — either straight to App Store Connect using an API key
(`destination=upload`), or into a local directory when `upload: false`, which
never contacts Apple at all. The `ExportOptions.plist` is generated from the
inputs and linted with `plutil -lint` before `xcodebuild -exportArchive` sees
it.

Pair it with [`apple-signing`](../apple-signing/README.md), which supplies
`profile-uuid` and `asc-key-path`. No secret reaches this action's log: only
the build number, paths and the destination are printed.

`upload: false` is the dry lane — it proves the Release configuration archives
and exports with the real profile without submitting a build, which is what a
first fleet validation or a release-candidate check wants.

## Inputs

| Name                  | Required | Default                   | Description                                                            |
| --------------------- | -------- | ------------------------- | ------------------------------------------------------------------------ |
| `project`             | no       | `''`                      | Path to the `.xcodeproj`. Exactly one of `project`/`workspace`.          |
| `workspace`           | no       | `''`                      | Path to the `.xcworkspace`. Exactly one of `project`/`workspace`.        |
| `scheme`              | yes      | —                         | Scheme to archive.                                                       |
| `configuration`       | no       | `Release`                 | Build configuration.                                                     |
| `team-id`             | yes      | —                         | `DEVELOPMENT_TEAM` and exportOptions `teamID`.                           |
| `bundle-id`           | yes      | —                         | Bundle identifier the exported profile is keyed on.                      |
| `build-number`        | yes      | —                         | `CURRENT_PROJECT_VERSION` for this build.                                |
| `profile-uuid`        | yes      | —                         | Provisioning profile UUID, e.g. `apple-signing`'s `profile-uuid`.        |
| `signing-certificate` | no       | `Apple Distribution`      | `CODE_SIGN_IDENTITY` and exportOptions `signingCertificate`.             |
| `asc-key-id`          | no       | `''`                      | ASC API key ID. Required when `upload` is `true`.                        |
| `asc-issuer-id`       | no       | `''`                      | ASC API issuer ID. Required when `upload` is `true`.                     |
| `asc-key-path`        | no       | `''`                      | Path of `AuthKey_<id>.p8`. Required when `upload` is `true`.             |
| `archive-path`        | no       | `build/<scheme>.xcarchive` | Path of the produced `.xcarchive`.                                      |
| `export-path`         | no       | `build/AppStoreUpload`    | Directory `-exportArchive` writes into.                                  |
| `upload`              | no       | `true`                    | `true` submits to App Store Connect; `false` exports locally only.        |
| `export-method`       | no       | `app-store-connect`       | exportOptions `method`.                                                  |
| `xcodebuild-args`     | no       | `''`                      | Extra arguments appended to the archive invocation. Word-split.          |
| `working-directory`   | no       | `.`                       | Directory every path resolves against.                                   |

## Outputs

| Name           | Description                                |
| -------------- | -------------------------------------------- |
| `archive-path` | Path of the produced `.xcarchive`.            |
| `export-path`  | Directory `-exportArchive` wrote into.        |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/apple-signing@v1
  id: signing
  with:
      certificate-base64: ${{ secrets.APPLE_DISTRIBUTION_CERTIFICATE_BASE64 }}
      certificate-password: ${{ secrets.APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD }}
      profile-base64: ${{ secrets.APP_STORE_PROVISIONING_PROFILE_BASE64 }}
      asc-key-base64: ${{ secrets.ASC_PRIVATE_KEY_BASE64 }}
      asc-key-id: ${{ secrets.ASC_KEY_ID }}
      expected-application-identifier: 3R8589YV24.com.example.app

- uses: rnw-community/mobile-ci/actions/xcode-archive-upload@v1
  with:
      project: MyApp.xcodeproj
      scheme: MyApp
      team-id: 3R8589YV24
      bundle-id: com.example.app
      build-number: ${{ github.run_number }}
      profile-uuid: ${{ steps.signing.outputs.profile-uuid }}
      asc-key-id: ${{ secrets.ASC_KEY_ID }}
      asc-issuer-id: ${{ secrets.ASC_ISSUER_ID }}
      asc-key-path: ${{ steps.signing.outputs.asc-key-path }}
```
