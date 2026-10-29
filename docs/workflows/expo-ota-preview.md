# expo-ota-preview.yml

Publishes an over-the-air JS preview for a development build **without EAS
Update** — no `eas-cli`, no `EXPO_TOKEN`, no EAS cloud, no separate hosting
surface. It exports the app, generates [Expo Updates protocol
v1](https://docs.expo.dev/technical-specs/expo-updates-1/) manifests, publishes
them and the bundle to a **GitHub Release** (the same channel the native
development `.ipa`/`.apk` uses), and writes the `expo-development-client` deep
links plus an ASCII QR code into the pull request's sticky preview comment.

The installed development build loads the exact preview through
`<scheme>://expo-development-client/?url=<manifest-url>`. Because the manifest
is a release asset, the dev-client's own Updates list is never involved — there
is no branch list to drown in unrelated production releases.

The workflow composes three pieces:

1. [`ota-runtime-version`](../../actions/ota-runtime-version/README.md)
   resolves each platform's runtime version with the project's own
   `expo-updates` (under `eas-profile`'s env, when set) unless
   `runtime-version-*` is supplied — the value the development build's
   `expo-updates` compares against, for any runtime policy. (Before v4.2.0 this
   was the pinned `@expo/fingerprint` of `native-fingerprint`; it now agrees
   with the build by construction.)
2. `expo-ota-manifest` converts the `expo export` output into per-platform v1
   manifests with base64url SHA-256 asset hashes, using `url-style: release`
   so asset URLs match the flattened GitHub Release asset names.
3. `github-release-publish` creates the release for the preview tag, uploads
   every file as an asset, and prunes older preview releases.
4. `pr-preview-comment` updates the pull request's single sticky preview
   comment in place (see [The preview comment](#the-preview-comment)).

With `ota-backend: eas` the same workflow publishes the preview as an **EAS
Update** instead, for private repositories — see
[EAS Update backend](#eas-update-backend-ota-backend-eas). Which one to pick:
[Choosing an OTA backend](../../README.md#choosing-an-ota-backend).

## The preview comment

Every push edits **one** comment, found by its hidden
`<!-- mobile-ci:preview -->` marker, instead of adding a new one, so a long
pull request does not fill up with stale QR codes. The comment is created only
when it does not exist yet. This workflow owns the `ios-ota` and `android-ota`
sections. Each one shows the commit, the update's runtime version, the
deep link and its QR code. A platform the run produced no link for has its
section cleared. `native-dev-release.yml` with `pr-comment: true` writes the
`ios-dev-build` / `android-dev-build` sections of the same comment, and
neither writer touches the other's sections. See the
[`pr-preview-comment` README](../../actions/pr-preview-comment/README.md) for
how concurrent writers are reconciled.

With `dev-release-tag-prefix` set (the `tag-prefix` the repository passes to
`native-dev-release.yml`, `dev` by default there), each OTA section also
answers "can I load this?". It links the newest published
`<prefix>-<platform>-*` development build whose release notes carry the same
runtime version (`native-dev-release.yml` records it, from v4.2.0 with the same
`ota-runtime-version`), or it says **Native build needed** when there is none.
The lookup reads the releases list with `gh`, and an unreadable list fails the
job. Dev builds published before v4.2.0 carry a `@expo/fingerprint` hash, which
may not match.

Development builds distributed on EAS instead (`eas build`, or
`native-dev-release.yml`'s EAS distribution) are found with
`dev-build-source: eas`: the newest finished EAS build of the platform with
the update's runtime version (`eas build:list --runtime-version`, optionally
`dev-build-profile`), linked to its expo.dev page. It needs `EXPO_TOKEN`, and
an unreadable build list fails the job.

**A stale run never touches the comment.** On a pull request, a run whose head
is no longer the pull request's head (a re-run of an older push) publishes
nothing and leaves the comment and its links alone (`skipped-reason:
stale-head`); an unreadable head fails the job. With `ota-backend: eas`,
`eas-update` makes that check and also skips a commit the channel's branch
already has (`already-published`), still refreshing the comment from that
update.

## How hosting works

GitHub Releases store assets flat, so nested paths are flattened by replacing
`/` with `__`: `assets/<md5>` → `assets__<md5>`, `ios/manifest.json` →
`ios__manifest.json`. A flattened name that would start with `.` (e.g.
`.well-known/...`) is prefixed with `_`, because GitHub renames leading-dot
asset names. The manifest references exactly those names, and the deep
link points at
`https://github.com/<owner>/<repo>/releases/download/<tag>/ios__manifest.json`.
`github.com/.../releases/download/...` redirects to the asset CDN; both
`expo-dev-client` and `expo-updates` follow the redirect and parse the JSON body
regardless of the intermediate content type.

Tags are `<release-tag-prefix>-<app-scope>-<slug>`, where `app-scope` is the
sanitized `app-dir` plus an 8-hex hash of it (so two Expo apps in one repository
never share a tag), and `slug` is `pr-<number>-<full-sha>` for pull requests or
the sanitized ref plus an 8-hex ref hash plus the full commit SHA for other
runs. The full commit SHA makes each publish a **fresh tag**, which is required
because repositories with **immutable releases** (budgie enables this) reject
uploads to a published release, and repositories that **restrict tag creation**
reject re-creating a deleted tag. Each publish creates the release with all
assets in one atomic `gh release create`; an existing tag is treated as already
published and skipped. Zero-byte files (for example `expo export`'s empty
`_global.css`) are skipped, because GitHub Releases cannot store 0-byte assets.
Older preview releases are pruned to `prune-keep`, scoped to this app's tag
prefix (`<prefix>-<app-scope>-`) and ordered by last update, and never deletes a
release updated within the grace window. To delete a pull request's previews
when it closes, pass the same prefix to
[`pr-closed-cleanup-reusable.yml`](pr-closed-cleanup-reusable.md)'s
`ota-preview-release-tag-prefix`, and call
[`preview-sweep-reusable.yml`](preview-sweep-reusable.md) on a schedule to
catch the ones a cleanup missed. Assets are hash-named and immutable;
the manifest referenced by the comment is the one published with that commit.

When `public-base-url` is empty the workflow publishes to GitHub Releases and
forces `url-style: release`, because the release host stores assets flat. Set
`public-base-url` only when an **external deployment step** uploads the export
to that directory-preserving host (with `url-style: path`); this workflow
itself never publishes outside GitHub Releases.

## EAS Update backend: `ota-backend: eas`

A private repository's release assets cannot be downloaded anonymously by a
device, so the GitHub Release backend cannot serve it. With `ota-backend: eas`
the job installs dependencies and resolves the runtime versions with
`ota-runtime-version` as usual, then skips `expo export`, `expo-ota-manifest`
and `github-release-publish` and runs
[`eas-update`](../../actions/eas-update/README.md) instead:

- the channel is `eas-channel` with `{number}` replaced by the pull request
  number (default `pr-{number}`); eas-cli creates it with a same-name branch on
  the first push. A run outside a pull request needs a channel without
  `{number}`, e.g. `development`;
- `eas-profile` evaluates the update under that `eas.json` build profile's env
  (`extends` resolved) and `environment`, as the matching build was;
- the deep links point the development build (`scheme`) at the EAS update
  group's manifest (`<updates.url>/group/<group>`), and the comment sections
  are the same as above — QR code, runtime version (EAS's, per platform), the
  channel, and the matching `native-dev-release.yml` build when
  `dev-release-tag-prefix` is set.

It needs the `EXPO_TOKEN` secret (`EAS_EXTRA_ENV` optionally) and works for
public and private repositories alike. Delete the channels of closed pull
requests with [`eas-channel-cleanup-reusable.yml`](eas-channel-cleanup-reusable.md).
`public-base-url`, `url-style`, `release-tag-prefix`, `prune-keep`, `publish`,
`runtime-version-*`, `include-expo-config` and `project-id` apply to the
GitHub Release backend only.

Inputs that configure only one backend fail the job on the other instead of
being ignored: `runtime-version-*`, `public-base-url`, `url-style`,
`release-tag-prefix`, `prune-keep`, `publish: false`, `include-expo-config:
false` and `project-id` on `eas`; `eas-channel`, `eas-environment`,
`eas-rollout-percentage`, `eas-private-key-path` and the `EAS_EXTRA_ENV`
secret on `github-release`. `eas-profile` applies to both (it resolves the
runtime version on `github-release` too).

### The GitHub Release backend is previews-only

A GitHub Release is a static host. It cannot send the protocol's response
headers, sign an update (`expo-signature`), roll an update out to a
percentage, or roll one back; a device just fetches the manifest URL the deep
link names. Use it for pull-request previews of development builds. An app
whose config sets `updates.codeSigningCertificate` fails the job on this
backend (its `expo-updates` would reject every unsigned manifest); use
`ota-backend: eas` with `eas-private-key-path`. Production channels belong on
EAS Update — see [Choosing an OTA backend](../../README.md#choosing-an-ota-backend).

## Preconditions

With `ota-backend: github-release` (default):

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

- **Fork pull requests are not previewed at all.** The whole `preview` job is
  skipped before checkout when the head repository differs from
  `github.repository`, so untrusted fork code never runs on a self-hosted
  runner and the release token is never exposed to it. Run previews from
  branches in this repository.
- **Previews are serialized per ref, not per app.** The concurrency group is
  `release-tag-prefix` + `app-dir` + the caller's `github.ref`, with
  `cancel-in-progress: false`: a new push to the same pull request queues
  behind its running preview rather than cancelling it. GitHub keeps only
  one pending run per group, so a still newer push replaces a preview that
  is pending (not yet running), and the latest commit's preview is the one
  published. Previews of different pull requests run independently. A group
  shared by every pull
  request would let GitHub cancel one PR's pending preview whenever another
  PR's run queued (it keeps one pending run per group). Runs of different
  refs do share the release-pruning prefix; pruning tolerates that by never
  deleting a release updated within the last ten minutes and by treating a
  release another run already deleted as pruned.
- Every publish uses a **fresh, per-commit tag**, so nothing is updated in place:
  a release is created once, with all of its assets, and an existing tag is
  skipped. Deep links always point at the release for the commit that produced
  them, and a superseded preview is removed only by retention, not by an
  in-place asset replacement.
- The manifest omits the protocol's optional response headers
  (`expo-protocol-version`, `expo-manifest-filters`, …). The current
  `expo-updates` client tolerates their absence for a JSON manifest.

## Inputs

| Name                     | Required | Default                        | Description                                                                                   |
| ------------------------ | -------- | ------------------------------ | --------------------------------------------------------------------------------------------- |
| `app-dir`                | **yes**  | —                              | App directory containing `app.json` / `app.config.js`.                                          |
| `scheme`                 | **yes**  | —                              | App URL scheme (`expo.scheme`) used to build the dev-client deep links.                         |
| `ota-backend`            | no       | `github-release`               | `github-release` (EAS-free, public repositories) or `eas` (EAS Update; needs `EXPO_TOKEN`). See [EAS Update backend](#eas-update-backend-ota-backend-eas). |
| `eas-channel`            | no       | `pr-{number}`                  | `eas`: channel to publish for, `{number}` replaced with the pull request number.               |
| `eas-profile`            | no       | `''`                           | `eas.json` build profile whose env the runtime version is resolved under (both backends), and the EAS update evaluated under. Use the development build's profile. |
| `eas-environment`        | no       | `''`                           | `eas`: EAS environment for `eas update --environment`; empty uses `eas-profile`'s.              |
| `eas-cli-version`        | no       | `20.5.1`                       | Pinned eas-cli npm version (`eas`, `dev-build-source: eas`).                                   |
| `eas-rollout-percentage` | no       | `''`                           | `eas`: publish as a rollout to this percentage of the channel's users.                         |
| `eas-private-key-path`   | no       | `''`                           | `eas`: code-signing private key, relative to `app-dir`, for an app with `updates.codeSigningCertificate`. |
| `dev-build-source`       | no       | `github-release`               | Where the comment looks for the matching development build: `github-release` (`dev-release-tag-prefix`) or `eas` (needs `EXPO_TOKEN`). |
| `dev-build-profile`      | no       | `''`                           | `dev-build-source: eas`: only EAS builds of this build profile.                                 |
| `platforms`              | no       | `ios,android`                  | Platforms to export and manifest.                                                               |
| `runtime-version-ios`    | no       | `''`                           | `github-release`: iOS runtime version; empty resolves it with `ota-runtime-version`.            |
| `runtime-version-android`| no       | `''`                           | `github-release`: Android runtime version; empty resolves it with `ota-runtime-version`.        |
| `public-base-url`        | no       | `''`                           | Asset URL prefix; empty derives the GitHub Releases download prefix for the tag. Must be `https://` (http only for localhost), credential-free, no query/fragment. Required when `publish` is `false`. |
| `url-style`              | no       | `release`                      | `release` flattens `/` to `__`; `path` keeps export-relative paths for a directory host. Forced to `release` when `public-base-url` is empty. |
| `release-tag-prefix`     | no       | `ota`                          | Release tag prefix; the tag is `<prefix>-<app-scope>-<slug>`.                                   |
| `prune-keep`             | no       | `5`                            | Number of preview releases to keep, including the current one.                                   |
| `publish`                | no       | `true`                         | Upload the exported dist to a GitHub Release (`github-release` only).                           |
| `post-comment`           | no       | `true`                         | Write deep links, an ASCII QR code and the runtime version into the pull request's sticky preview comment, edited in place on every push. |
| `dev-release-tag-prefix` | no       | `''`                           | `native-dev-release.yml`'s `tag-prefix` (`dev` there by default). When set, each platform section links the newest published dev build with the same runtime fingerprint, or says a native build is needed. Must be `[A-Za-z0-9._-]`. |
| `include-expo-config`    | no       | `true`                         | Include `extra.expoClient`. Set `false` to omit app config from a public manifest.               |
| `project-id`             | no       | `''`                           | Optional EAS project id exposed as `extra.eas.projectId`.                                        |
| `runner-labels`          | no       | `["self-hosted","linux","x64"]`| JSON array of self-hosted runner labels.                                                        |
| `node-version`           | no       | `22`                           | Node version.                                                                                   |
| `install-command`        | no       | `''`                           | Dependency install command; empty derives pnpm/yarn/npm from the resolved package manager.     |
| `enable-corepack`        | no       | `true`                         | Run `corepack enable` when the manager is not pnpm.                                             |
| `package-manager`        | no       | `''`                           | `pnpm`, `yarn`, `npm`, or empty to auto-detect.                                                 |
| `build-command`          | no       | `''`                           | Optional workspace JS build command run before `expo export`.                                   |
| `timeout-minutes`        | no       | `30`                           | Job timeout.                                                                                    |

## Secrets

| Name            | Required | Description                                                              |
| --------------- | -------- | ------------------------------------------------------------------------ |
| `RELEASE_TOKEN` | no       | Token with `contents: write` for the release; defaults to `github.token`. Never exposed to fork code (the job is skipped for forks). |
| `EXPO_TOKEN`    | `eas`    | Expo access token for `eas update` (and `dev-build-source: eas`); the job fails before publishing without it. A token that can reach production channels belongs in a GitHub Environment, not a repository secret every pull request can use. |
| `EAS_EXTRA_ENV` | no       | `eas`: newline-separated `KEY=VALUE` secret env, masked and exported before `eas update`. |

## Outputs

| Name          | Description                                          |
| ------------- | ---------------------------------------------------- |
| `published`, `skipped-reason` | Whether this run published, else why not: `stale-head`, `already-published` (`eas`) or `publish-disabled`. |
| `ios-update-id`, `android-update-id` | Update id per platform (the manifest id on `github-release`). |
| `ios-runtime-version`, `android-runtime-version` | Runtime version per platform. |
| `ios-deep-link`, `android-deep-link` | `expo-dev-client` deep link per platform. |
| `url-ios`     | URL of the iOS manifest (the EAS update group's with `eas`). |
| `url-android` | URL of the Android manifest (the EAS update group's with `eas`). |
| `release-tag` | The GitHub Release tag the preview was published to; empty with `eas`. |
| `eas-channel` | The EAS channel the update was published for; empty with `github-release`. |

## Permissions

The calling job must request:

```yaml
permissions:
    contents: write
    pull-requests: write
```

## Examples

### Minimal

A public repository on the default GitHub Release backend:

```yaml
name: OTA preview
on: pull_request

jobs:
    preview:
        permissions:
            contents: write
            pull-requests: write
        uses: rnw-community/mobile-ci/.github/workflows/expo-ota-preview.yml@v4.6.0 # v4.6.0
        with:
            app-dir: packages/app
            scheme: budgie
            platforms: ios,android
            build-command: pnpm exec turbo build --filter=@budgie/contracts --filter=@budgie/ai
```

### Full

A private repository on EAS Update, linking the newest matching EAS
development build:

```yaml
name: OTA preview
on:
    pull_request:
        paths:
            - 'apps/mobile/**'
            - 'pnpm-lock.yaml'
jobs:
    preview:
        permissions:
            contents: write
            pull-requests: write
        uses: rnw-community/mobile-ci/.github/workflows/expo-ota-preview.yml@v4.6.0 # v4.6.0
        with:
            app-dir: apps/mobile
            scheme: myapp
            ota-backend: eas
            eas-channel: myapp-pr-{number}
            eas-profile: development
            dev-build-source: eas
            dev-build-profile: development
            platforms: ios,android
            install-command: pnpm install --frozen-lockfile
        secrets:
            EXPO_TOKEN: ${{ secrets.EXPO_PREVIEW_TOKEN }}
```

Add a gate that only calls this workflow for mobile-impacting changes (for
example `rnw-community/mobile-ci/actions/turbo-affected`, or a path filter) so
documentation-only pull requests do not export a bundle. Delete what a closed
pull request leaves behind with
[`pr-closed-cleanup-reusable.yml`](pr-closed-cleanup-reusable.md)
(`ota-preview-release-tag-prefix`) on the GitHub Release backend, or
[`eas-channel-cleanup-reusable.yml`](eas-channel-cleanup-reusable.md) on EAS.

Complete caller workflows for whole apps, linted and checked against this
workflow's inputs in CI, live in [docs/examples/](../examples/README.md).
