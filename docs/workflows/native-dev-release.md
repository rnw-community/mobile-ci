# native-dev-release.yml

`workflow_call` reusable workflow: EAS local development build per enabled
platform, published as a GitHub Release rather than to a store.

Two independent jobs, each gated by its own `enable-*` input:
**ios-dev-release** and **android-dev-release**. Each: computes a
deterministic build number (`run_number.run_attempt`), runs `eas build
--local --profile <build-profile>` for its platform, uploads the artifact,
computes a `build-meta.json` + `SHA256SUMS` pair describing that artifact,
creates a draft GitHub Release tagged `<tag-prefix>-<platform>-<run_number>`,
attaches the build artifact plus those two files, publishes the release,
then prunes older published releases under that platform's tag prefix down
to `keep-releases`, always excluding the release the current run just
published (so a re-run of an older workflow run can never prune the release
it just created). Pruning keys only on each release's `tag_name`/`draft`
fields, so the extra `build-meta.json`/`SHA256SUMS` assets never affect
which releases are kept or deleted. A final **status** job aggregates the
enabled jobs into a single required check. Both jobs need `permissions:
contents: write` to create/prune releases.

## Release assets

Every dev release carries three assets: the build artifact (`app.ipa` /
`app.aab`), a `SHA256SUMS` file, and a `build-meta.json` file.

`SHA256SUMS` is the standard `shasum -a 256`-format checksum file for the
build artifact, one line, `<hash>  <filename>` (two spaces), e.g.:

```
1d8cbc804fa48c3e137986dbedc500e83c2e0aee6bdf195caa63e97d699dcf5a  app.ipa
```

`build-meta.json` is a structured description of the build, so consumer
code never has to hand-parse the release tag or scrape release notes:

```json
{
    "platform": "ios",
    "version": "1.4.2",
    "buildNumber": "482.1",
    "commitSha": "b0389d2c2c3f9e1d1234567890abcdef1234567",
    "branch": "main",
    "builtAt": "2026-08-10T12:34:56Z",
    "workflowUrl": "https://github.com/<owner>/<repo>/actions/runs/123456789",
    "tagName": "dev-ios-482",
    "assetName": "app.ipa",
    "sha256": "1d8cbc804fa48c3e137986dbedc500e83c2e0aee6bdf195caa63e97d699dcf5a"
}
```

| Field         | Always present | Description |
| ------------- | --------------- | -------------- |
| `platform`    | yes              | `"ios"` or `"android"`. |
| `version`     | no               | The app version read from `<app-dir>/app.json`'s `expo.version`. Omitted entirely (not `null`, not empty string) when `app.json` does not exist or has no `expo.version` — e.g. apps using a dynamic `app.config.js`/`.ts`. Never guessed. |
| `buildNumber` | yes              | `<run_number>.<run_attempt>`, the same deterministic build number used elsewhere in the job. |
| `commitSha`   | yes              | `github.sha` for the run that produced the build. |
| `branch`      | yes              | `github.ref_name` for the run that produced the build. |
| `builtAt`     | yes              | UTC build timestamp, ISO 8601 (`date -u +%Y-%m-%dT%H:%M:%SZ`). |
| `workflowUrl` | yes              | Direct link to the workflow run that produced this release. |
| `tagName`     | yes              | The release tag this asset was attached to (`<tag-prefix>-<platform>-<run_number>`). |
| `assetName`   | yes              | Basename of the build artifact in this release (`app.ipa` / `app.aab`). |
| `sha256`      | yes              | SHA-256 of the build artifact, same value as in `SHA256SUMS`. |

On a re-run of the same workflow run (same tag), `build-meta.json` and
`SHA256SUMS` are re-uploaded with `--clobber`, same as the build artifact —
consumers always see the metadata for the artifact currently attached to
that tag, never a stale copy from an earlier attempt.

### The `/releases/latest` trap

Dev releases are ordinary (non-prerelease) published GitHub Releases, but
GitHub's `GET /repos/<owner>/<repo>/releases/latest` endpoint (and the
`/releases/latest` web page) only ever considers the most recent release
that is **not** a draft and **not marked `prerelease`** — and it applies
that filter per-repository, not per-tag-prefix. In a repo where both
`dev-ios-*` and `dev-android-*` releases (or dev releases alongside
proper store releases) are being published, `/releases/latest` can just as
easily return the wrong platform's release, or a non-dev release entirely.
**Always list releases and filter by tag prefix client-side** — never rely
on `/releases/latest` to find "the latest dev build for platform X".

### Recommended consumer discovery pattern

1. `GET /repos/<owner>/<repo>/releases` (paginate as needed).
2. Filter to `tag_name` starting with the platform's tag prefix (e.g.
   `dev-ios-`) and `draft == false`.
3. Sort by `created_at` descending and take the first match.
4. Download that release's `build-meta.json` asset and read it for
   `assetName`/`sha256`/`version`/`buildNumber` — **prefer this over parsing
   `tag_name` or the release notes body**, both of which are incidental
   formatting, not a contract. `build-meta.json` is the contract.
5. Download the asset named `build-meta.json.assetName`, verify it against
   `sha256` (or against `SHA256SUMS`) before installing/running it.

If the consumer calls the GitHub API from a context with a low unauthenticated
rate limit (e.g. a public web page fetching on every visitor request) or the
releases live in a private repository, pass a bearer token
(`Authorization: Bearer <token>`) with at least `contents: read` on the
repository — a fine-grained PAT scoped to this single repo is sufficient,
no write access is needed for discovery.

## Inputs

| Name                     | Required | Default                             | Description |
| --------------------------- | -------- | -------------------------------------- | -------------- |
| `enable-ios`                 | no       | `true`                                  | Run the `ios-dev-release` job. |
| `enable-android`             | no       | `false`                                 | Run the `android-dev-release` job. |
| `ios-runner-labels`          | no       | `["self-hosted","macOS","ARM64"]`         | JSON array of self-hosted runner labels for the iOS dev-release job. |
| `android-runner-labels`      | no       | `["self-hosted","macOS","ARM64"]`         | JSON array of self-hosted runner labels for the Android dev-release job. Defaults to macOS because Google's Android NDK build tooling used by EAS local builds is x86_64-only on Linux. |
| `app-dir`                    | **yes**  | —                                        | App directory containing `app.json`/`eas.json`. |
| `node-version`               | no       | `22`                                     | Node version for `actions/setup-node`. |
| `install-command`            | no       | `yarn install --immutable`                | JS dependency install command. |
| `enable-corepack`            | no       | `true`                                    | Run `corepack enable` before install. |
| `build-command`              | no       | `''`                                      | Optional workspace JS build command run at repo root before the dev build. |
| `eas-cli-version`            | no       | `20.5.1`                                  | Pinned `eas-cli` npm version invoked via `npx eas-cli@<version>`. |
| `build-profile`              | no       | `development`                             | EAS build profile (`eas.json` `build.<profile>`) used for both platforms. |
| `tag-prefix`                 | no       | `dev`                                     | Release tag prefix. Tags are created as `<tag-prefix>-ios-<run_number>` and `<tag-prefix>-android-<run_number>`. |
| `keep-releases`              | no       | `5`                                       | Number of newest *other* published releases (per platform tag) to keep in addition to the one the current run just published; older ones are pruned. |
| `asc-key-path`               | no       | `''`                                       | Optional path, relative to `app-dir`, the App Store Connect API key (`.p8`) is written to and removed from. Only used when the `ASC_API_KEY` secret is set. Leave empty (default) to write the key under `$RUNNER_TEMP` instead, keeping it out of the `eas build --local` archive; set it only when `eas.json` requires the key at a specific `app-dir`-relative location. |
| `build-timeout-minutes`      | no       | `120`                                     | Dev-release job timeout (both platforms). |
| `publish-env`                | no       | `''`                                      | Newline-separated `KEY=VALUE` pairs of non-secret env appended to `$GITHUB_ENV` at the start of `ios-dev-release` and `android-dev-release`, before `eas build`. Rejects (fails closed) any line without `=` or whose name does not match `^[A-Za-z_][A-Za-z0-9_]*$`. For secret values use the `EAS_EXTRA_ENV` secret instead — inputs are not masked in logs. |

## Secrets

| Name                | Required | Description |
| ---------------------- | -------- | -------------- |
| `EXPO_TOKEN`             | no*      | Expo access token, required by both dev-release jobs. |
| `ASC_API_KEY`            | no       | Optional App Store Connect API key contents (`.p8`), used by `ios-dev-release` when the development profile needs automatic device/credential management. |
| `ASC_KEY_ID`             | no       | App Store Connect API key ID matching `ASC_API_KEY`. Exported to the build step as `EXPO_ASC_KEY_ID`; set alongside `ASC_API_KEY`/`ASC_ISSUER_ID` so EAS can resolve the key non-interactively. |
| `ASC_ISSUER_ID`          | no       | App Store Connect API key issuer ID matching `ASC_API_KEY`. Exported to the build step as `EXPO_ASC_ISSUER_ID`; set alongside `ASC_API_KEY`/`ASC_KEY_ID` so EAS can resolve the key non-interactively. |
| `EAS_EXTRA_ENV`          | no       | Newline-separated `KEY=VALUE` pairs of secret env appended to `$GITHUB_ENV` at the start of `ios-dev-release` and `android-dev-release`. Same fail-closed parser as `publish-env`, but each value is masked (`::add-mask::`) before being written to `$GITHUB_ENV`, so it never appears unredacted in logs (empty values are not masked). Use this for secrets `eas build` needs on the environment — e.g. `EXPO_APPLE_APP_SPECIFIC_PASSWORD`. |

\* `EXPO_TOKEN` is declared optional at the `workflow_call` level, but each
enabled dev-release job validates it is present at the start of the job and
fails fast with a clear error if it is missing. Pass secrets via `secrets:
inherit` or an explicit `secrets:` block in the caller workflow.

## Permissions

The caller workflow needs `permissions: contents: write` (or an equivalent
token) — both jobs create and prune GitHub Releases and tags.

## Example

```yaml
# .github/workflows/native-dev-release.yml
name: Native dev release
on:
    workflow_dispatch:
    push:
        branches: [main]
permissions:
    contents: write
jobs:
    dev-release:
        uses: rnw-community/mobile-ci/.github/workflows/native-dev-release.yml@main
        with:
            app-dir: apps/mobile
            enable-ios: true
        secrets: inherit
```

To thread a secret into the eas build environment (e.g. an Apple
app-specific password), pass it through `EAS_EXTRA_ENV` rather than a plain
input:

```yaml
# .github/workflows/native-dev-release.yml
name: Native dev release
on:
    workflow_dispatch:
    push:
        branches: [main]
permissions:
    contents: write
jobs:
    dev-release:
        uses: rnw-community/mobile-ci/.github/workflows/native-dev-release.yml@main
        with:
            app-dir: apps/mobile
            enable-ios: true
        secrets:
            EXPO_TOKEN: ${{ secrets.EXPO_TOKEN }}
            EAS_EXTRA_ENV: EXPO_APPLE_APP_SPECIFIC_PASSWORD=${{ secrets.APPLE_PASSWORD }}
```
