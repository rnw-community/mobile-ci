# expo-ota-manifest

Turns an existing `expo export` output directory into [Expo Updates protocol
v1](https://docs.expo.dev/technical-specs/expo-updates-1/) manifests — one per
platform — so an installed development build can load the bundle from any
static host, with **no EAS Update, no `eas-cli`, and no `EXPO_TOKEN`**.

The generated manifest is what `expo-dev-client` fetches when you open a
deep link of the form
`<scheme>://expo-development-client/?url=<manifest-url>`. For every referenced
file it computes the two hashes the client verifies:

- `hash`: base64url-encoded SHA-256 of the file bytes.
- `key`: MD5 hex of the file bytes (matches Metro's `assets/<md5>` filename).

`launchAsset` is the exported JS/Hermes bundle; `assets` are the exported
images/fonts referenced by `metadata.json`. `extra.expoClient` is populated from
an `expo config --json` dump when present, because many Expo modules read it.
This action is intentionally the Expo-authored
[`custom-expo-updates-server`](https://github.com/expo/custom-expo-updates-server)
manifest algorithm, minus the server.

Consumers must first run `expo export`, then publish the whole output directory
(including the generated `ios/manifest.json` and `android/manifest.json`) to a
static host. See `github-release-publish` for a GitHub Releases publisher — the
same channel the native development `.ipa`/`.apk` uses — or point
`public-base-url` at your own file server.

Because GitHub Releases stores assets flat (no directories), pass
`url-style: release` when publishing there: the manifest then references each
file by its flattened asset name (`assets/<md5>` → `assets__<md5>`), matching
what `github-release-publish` uploads.

## Inputs

| Name                     | Required | Default     | Description                                                                       |
| ------------------------ | -------- | ----------- | --------------------------------------------------------------------------------- |
| `dist-dir`               | no       | `dist`      | `expo export` output directory.                                                   |
| `public-base-url`        | yes      | —           | URL prefix the published dist is served from, no trailing slash.                  |
| `url-style`              | no       | `path`      | `path` keeps export-relative URLs; `release` flattens `/` to `__` for GitHub Releases. |
| `platforms`              | no       | `ios,android` | Platforms to emit manifests for.                                                |
| `runtime-version-ios`    | no       | `''`        | iOS runtime version (fingerprint) the update targets. Required when ios is listed. |
| `runtime-version-android`| no       | `''`        | Android runtime version (fingerprint) the update targets. Required when android is listed. |
| `created-at`             | no       | `''`        | ISO-8601 timestamp; defaults to `metadata.json` mtime.                             |
| `expo-config-path`       | no       | `''`        | `expo config --json` output path; defaults to `<dist-dir>/expoConfig.json`.        |
| `include-expo-config`    | no       | `true`      | Set `false` to omit `extra.expoClient` (e.g. to avoid publishing app config).      |
| `project-id`             | no       | `''`        | Optional value exposed as `extra.eas.projectId`.                                   |

## Outputs

| Name              | Description                              |
| ----------------- | ---------------------------------------- |
| `manifest-ios`    | Absolute path of the iOS manifest.        |
| `manifest-android`| Absolute path of the Android manifest.    |
| `url-ios`         | Public URL of the iOS manifest.           |
| `url-android`     | Public URL of the Android manifest.       |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/expo-ota-manifest@v1
  id: manifest
  with:
      dist-dir: dist
      public-base-url: https://example.github.io/app/previews/pr-42
      runtime-version-ios: ${{ steps.fingerprint-ios.outputs.hash }}
      runtime-version-android: ${{ steps.fingerprint-android.outputs.hash }}

- run: |
      echo "iOS: ${{ steps.manifest.outputs.url-ios }}"
      echo "Android: ${{ steps.manifest.outputs.url-android }}"
```
