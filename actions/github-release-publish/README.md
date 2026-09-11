# github-release-publish

Publishes a directory to a **GitHub Release** as assets under a stable tag,
giving every file an immutable public download URL:
`https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>`. This is the
same channel the native development `.ipa`/`.apk` uses, so it needs no separate
hosting surface and no `EXPO_TOKEN`.

GitHub Releases store assets flat, so this action flattens nested paths by
replacing `/` with `__`: `assets/<md5>` becomes `assets__<md5>`, and
`ios/manifest.json` becomes `ios__manifest.json`. Pair it with
`expo-ota-manifest`'s `url-style: release` so the manifest references the same
names. `github.com/.../releases/download/...` responds with a redirect; the
`expo-updates` client and `expo-dev-client` both follow it and parse the JSON
body regardless of the intermediary's content type.

The release is created as a **draft**, assets are uploaded (non-manifest assets
are content-addressed and uploaded only when absent; `manifest.json` files are
uploaded last with `--clobber`), and the release is then **published**. This
supports repositories with **immutable releases**: a published immutable release
cannot accept new assets, so when an existing tag's release is already published
and immutable it is recreated as a draft before the upload. With `clean: true`,
assets absent from the upload are removed while the release is still a draft,
before it is published. `clean` defaults to `false` so two concurrent publishes
for the same tag cannot delete each other's assets — enable it when publishes for
a tag are serialized (the `expo-ota-preview` workflow does, via its concurrency
group). Releases are public for public repositories; a private repository would
require an authenticated download, so this action is intended for public repos.
Retention (`prune-prefix` + `prune-keep`) orders releases by **last update**,
not creation, so a republished preview — whose assets were just clobbered — is
not pruned as if it were old. `expo-ota-preview` scopes the prefix to the app so
one app never prunes another's previews.

## Inputs

| Name            | Required | Default | Description                                                                       |
| --------------- | -------- | ------- | --------------------------------------------------------------------------------- |
| `source-dir`    | yes      | —       | Directory whose files are uploaded as release assets.                             |
| `tag`           | yes      | —       | Release tag, e.g. `ota-pr-42`.                                                    |
| `token`         | yes      | —       | Token with `contents: write`.                                                     |
| `title`         | no       | `''`    | Release title; defaults to the tag.                                               |
| `prune-prefix`  | no       | `''`    | Delete older releases whose tag starts with this prefix. Empty disables pruning.  |
| `prune-keep`    | no       | `5`     | Number of prefix-matching releases to keep, including the current one.            |
| `clean`         | no       | `false` | Delete assets absent from this upload after the manifest switch. Only enable when publishes for the tag are serialized. |
| `prune-grace-minutes` | no | `10`    | Never delete a release updated within this many minutes, protecting a concurrently published preview. |
| `dry-run`       | no       | `false` | Stage and validate without creating, uploading, or pruning.                       |

## Outputs

| Name       | Description                                                                  |
| ---------- | ---------------------------------------------------------------------------- |
| `tag`      | The release tag published under.                                              |
| `base-url` | `https://github.com/<repo>/releases/download/<tag>`.                          |
| `uploaded` | Number of assets staged.                                                      |

## Permissions

The calling job needs `contents: write`.

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/github-release-publish@v1
  id: publish
  with:
      source-dir: packages/app/dist
      tag: ota-pr-42
      token: ${{ github.token }}
      prune-prefix: ota-pr-
      prune-keep: '3'

- run: echo "${{ steps.publish.outputs.base-url }}/ios__manifest.json"
```
