# expo-ota-preview.yml

Publishes an over-the-air JS preview for a development build **without EAS
Update** — no `eas-cli`, no `EXPO_TOKEN`, no EAS cloud, no separate hosting
surface. It exports the app, generates [Expo Updates protocol
v1](https://docs.expo.dev/technical-specs/expo-updates-1/) manifests, publishes
them and the bundle to a **GitHub Release** (the same channel the native
development `.ipa`/`.apk` uses), and posts the `expo-development-client` deep
links plus an ASCII QR code on the pull request.

The installed development build loads the exact preview through
`<scheme>://expo-development-client/?url=<manifest-url>`. Because the manifest
is a release asset, the dev-client's own Updates list is never involved — there
is no branch list to drown in unrelated production releases.

The workflow composes three pieces:

1. `native-fingerprint` computes each platform's runtime version tokenlessly
   when `runtime-version-*` is not supplied, so a JS-only preview matches the
   fingerprint a fingerprint-policy dev build baked into its native shell.
2. `expo-ota-manifest` converts the `expo export` output into per-platform v1
   manifests with base64url SHA-256 asset hashes, using `url-style: release`
   so asset URLs match the flattened GitHub Release asset names.
3. `github-release-publish` creates the release for the preview tag, uploads
   every file as an asset, and prunes older preview releases.

## How hosting works

GitHub Releases store assets flat, so nested paths are flattened by replacing
`/` with `__`: `assets/<md5>` → `assets__<md5>`, `ios/manifest.json` →
`ios__manifest.json`. The manifest references exactly those names, and the deep
link points at
`https://github.com/<owner>/<repo>/releases/download/<tag>/ios__manifest.json`.
`github.com/.../releases/download/...` redirects to the asset CDN; both
`expo-dev-client` and `expo-updates` follow the redirect and parse the JSON body
regardless of the intermediate content type.

Tags are `<release-tag-prefix>-<slug>` (default `ota-pr-<number>`). The release
is recreated each run, so it always holds only the current preview, and older
preview releases are pruned to `prune-keep`. Assets are hash-named and
immutable; only the manifest is replaced.

## Preconditions

- The repository is **public**. A private repository requires an authenticated
  asset download, which a device cannot provide anonymously.
- `expo-updates` is installed and enabled in the development build, and the
  build's runtime version matches the manifest's `runtimeVersion`. A
  fingerprint-policy build matches when the native surface is unchanged; if the
  preview branch changes native inputs, rebuild the dev app first.
- The calling job grants `permissions: contents: write` and
  `pull-requests: write`; the reusable workflow cannot elevate beyond the
  caller.

## Caveats

- Publishing is skipped on fork pull requests, because the automatic
  `github.token` is read-only there. Pass a `RELEASE_TOKEN` secret with
  `contents: write` if fork previews are required.
- Recreating the release each run means an in-flight download of a superseded
  preview can 404. Previews are transient, so this is acceptable; long-lived
  previews should not rely on a stale manifest.
- The manifest omits the protocol's optional response headers
  (`expo-protocol-version`, `expo-manifest-filters`, …). The current
  `expo-updates` client tolerates their absence for a JSON manifest.

## Inputs

| Name                     | Required | Default                        | Description                                                                                   |
| ------------------------ | -------- | ------------------------------ | --------------------------------------------------------------------------------------------- |
| `app-dir`                | **yes**  | —                              | App directory containing `app.json` / `app.config.js`.                                          |
| `scheme`                 | **yes**  | —                              | App URL scheme (`expo.scheme`) used to build the dev-client deep links.                         |
| `platforms`              | no       | `ios,android`                  | Platforms to export and manifest.                                                               |
| `runtime-version-ios`    | no       | `''`                           | iOS runtime version; empty computes it with `native-fingerprint`.                               |
| `runtime-version-android`| no       | `''`                           | Android runtime version; empty computes it with `native-fingerprint`.                           |
| `public-base-url`        | no       | `''`                           | Asset URL prefix; empty derives the GitHub Releases download prefix for the tag.                |
| `url-style`              | no       | `release`                      | `release` flattens `/` to `__`; `path` keeps export-relative paths for a directory host.        |
| `release-tag-prefix`     | no       | `ota`                          | Release tag prefix; the tag is `<prefix>-<slug>`.                                               |
| `prune-keep`             | no       | `5`                            | Number of preview releases to keep, including the current one.                                   |
| `publish`                | no       | `true`                         | Upload the exported dist to a GitHub Release.                                                    |
| `post-comment`           | no       | `true`                         | Post deep links and an ASCII QR code on the pull request.                                        |
| `include-expo-config`    | no       | `true`                         | Include `extra.expoClient`. Set `false` to omit app config from a public manifest.               |
| `project-id`             | no       | `''`                           | Optional EAS project id exposed as `extra.eas.projectId`.                                        |
| `runner-labels`          | no       | `["self-hosted","linux","x64"]`| JSON array of self-hosted runner labels.                                                        |
| `node-version`           | no       | `22`                           | Node version.                                                                                   |
| `install-command`        | no       | `pnpm install --frozen-lockfile`| Dependency install command; must match the resolved package manager.                           |
| `enable-corepack`        | no       | `true`                         | Run `corepack enable` when the manager is not pnpm.                                             |
| `package-manager`        | no       | `''`                           | `pnpm`, `yarn`, `npm`, or empty to auto-detect.                                                 |
| `build-command`          | no       | `''`                           | Optional workspace JS build command run before `expo export`.                                   |
| `timeout-minutes`        | no       | `30`                           | Job timeout.                                                                                    |

## Secrets

| Name            | Required | Description                                                              |
| --------------- | -------- | ------------------------------------------------------------------------ |
| `RELEASE_TOKEN` | no       | Token with `contents: write` for the release; defaults to `github.token`. |

## Outputs

| Name          | Description                                          |
| ------------- | ---------------------------------------------------- |
| `url-ios`     | Public URL of the iOS manifest.                      |
| `url-android` | Public URL of the Android manifest.                  |
| `release-tag` | The GitHub Release tag the preview was published to. |

## Permissions

The calling job must request:

```yaml
permissions:
    contents: write
    pull-requests: write
```

## Example

```yaml
name: OTA preview
on: pull_request

jobs:
    preview:
        permissions:
            contents: write
            pull-requests: write
        uses: rnw-community/mobile-ci/.github/workflows/expo-ota-preview.yml@v1.13.0 # v1.13.0
        with:
            app-dir: packages/app
            scheme: budgie
            platforms: ios,android
            build-command: pnpm exec turbo build --filter=@budgie/contracts --filter=@budgie/ai
```

Add a gate that only calls this workflow for mobile-impacting changes (for
example `rnw-community/mobile-ci/actions/turbo-affected`, or a path filter) so
documentation-only pull requests do not export a bundle.
