# github-release-publish

Publishes a directory to a **GitHub Release** as assets under a tag, giving
every file an immutable public download URL:
`https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>`. This is the
same channel the native development `.ipa`/`.apk` uses, so it needs no separate
hosting surface and no `EXPO_TOKEN`.

GitHub Releases store assets flat, so this action flattens nested paths by
replacing `/` with `__`: `assets/<md5>` becomes `assets__<md5>`, and
`ios/manifest.json` becomes `ios__manifest.json`. A flattened name that would
start with `.` (e.g. `.well-known/...`) is prefixed with `_`, because GitHub
renames leading-dot asset names. Pair it with
`expo-ota-manifest`'s `url-style: release` so the manifest references the same
names. `github.com/.../releases/download/...` responds with a redirect; the
`expo-updates` client and `expo-dev-client` both follow it and parse the JSON
body regardless of the intermediary's content type.

The release is created with **all assets in a single atomic `gh release create`
call**, and an existing tag is treated as already published and skipped. That is
required because:
- GitHub repositories with **immutable releases** reject uploading assets to a
  published release (`HTTP 422`), and
- repositories that **restrict tag creation** reject re-creating a deleted tag
  (`pre_receive ... Cannot create ref`), so each publish must use a **fresh
  tag** — pass a unique tag (the `expo-ota-preview` workflow includes the short
  commit SHA).

Zero-byte files (e.g. `expo export`'s empty `_global.css`) are skipped, because
GitHub Releases cannot store 0-byte assets. Releases are public for public
repositories; a private repository would require an authenticated download, so
this action is intended for public repos. The `clean` input is retained for
compatibility and has no effect.
Retention (`prune-prefix` + `prune-keep`) orders releases by **last update**.
`expo-ota-preview` scopes the prefix to the app so one app never prunes another's
previews.

## Inputs

| Name            | Required | Default | Description                                                                       |
| --------------- | -------- | ------- | --------------------------------------------------------------------------------- |
| `source-dir`    | yes      | —       | Directory whose files are uploaded as release assets.                             |
| `tag`           | yes      | —       | Release tag; use a **fresh** one per publish (an existing tag is skipped).         |
| `token`         | yes      | —       | Token with `contents: write`.                                                     |
| `title`         | no       | `''`    | Release title; defaults to the tag.                                               |
| `prune-prefix`  | no       | `''`    | Delete older releases whose tag starts with this prefix. Empty disables pruning.  |
| `prune-keep`    | no       | `5`     | Number of prefix-matching releases to keep, including the current one.            |
| `clean`         | no       | `false` | Retained for compatibility; has no effect.                                        |
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
