# native-dev-release.yml

`workflow_call` reusable workflow: EAS development build per enabled
platform, published as a GitHub Release (default) or to EAS internal
distribution (`distribution: eas`, see [EAS distribution](#eas-distribution))
rather than to a store.

Two independent jobs, each gated by its own `enable-*` input:
**ios-dev-release** and **android-dev-release**. Each: computes a
deterministic build number (`run_number.run_attempt`), runs `eas build
--local --profile <build-profile>` for its platform, reads back the build
number and version the binary actually embeds (see [Embedded build
number](#embedded-build-number)), runs the optional post-build hook, uploads
the artifact, computes a `build-meta.json` + `SHA256SUMS` pair describing that artifact,
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

## EAS distribution

A GitHub Release asset is only downloadable by someone who can read the
repository, and it is a file, not an install link: a signed `.ipa` reaches a
registered iPhone only through Xcode or Apple Configurator on a Mac.
`distribution: eas` hands testers an EAS internal distribution link they open
on the device instead:

- With the default `build-location: local`, the job builds with `eas build
  --local` as before, runs the embedded build number read-back and the
  post-build hook, then uploads the binary with `eas upload --platform
  <platform> --build-path <artifact> --non-interactive --json`. EAS records it
  as an internal distribution build and returns its build page.
- With `build-location: cloud`, the job runs `eas build --non-interactive
  --json --wait` on EAS servers instead, and reads the finished build from that
  JSON. The build profile must have `distribution: internal`, and on Android
  produce an `.apk` (`android.buildType: apk`). Nothing is built on the runner,
  so a cloud build cannot run a post-build command or
  `ios-verify-embedded-build-number`; asking for either fails the job rather
  than skipping it. The runner's environment does not reach the EAS builder
  either: `publish-env`, `EAS_EXTRA_ENV` and `DEVELOPMENT_BUILD_NUMBER` apply
  only to the steps on the runner (the pre-build hook, and `eas build`'s local
  evaluation of the app config). A value the build itself needs must be in the
  build profile's `env` or an EAS environment variable.

Either way the job outputs the build page,
`https://expo.dev/accounts/<owner>/projects/<slug>/builds/<id>`, as
`install-url` and its id as `build-id`, and links it from the job summary and,
with `pr-comment`, the pull request comment. Testers open the page on the
device to install; an iOS device must be registered in the profile's ad hoc
provisioning (`eas device:create`). No GitHub Release is created or pruned;
EAS's own build retention applies.

The step fails closed when `eas upload` exits 0 without a build URL, when the
URL is not an EAS build page, and, for a cloud build, when the build did not
finish, is not internal distribution, has no artifact, or is an Android
`.aab`. Combining `distribution: eas` with `android-artifact-extension: aab`
fails before the build: no device can install an `.aab`.

`EXPO_TOKEN` must belong to an account that can upload to the project in
`app.json` / `app.config.*`.

Access to the link is governed by EAS, not by the repository: per Expo's
[internal distribution](https://docs.expo.dev/build/internal-distribution/)
documentation, anyone with an internal build's URL can open it by default.
When the binary must stay restricted, turn off unauthenticated access to
internal builds in the EAS project settings, so testers must sign in to an
Expo account with access to the project.

## Outputs

| Name                  | Description |
| --------------------- | ----------- |
| `ios-install-url`     | EAS build page of the iOS build with `distribution: eas`; empty otherwise. |
| `ios-build-id`        | EAS build id of the iOS build with `distribution: eas`; empty otherwise. |
| `ios-release-url`     | GitHub Release of the iOS build with `distribution: github-release`; empty otherwise. |
| `ios-fingerprint`     | [Runtime fingerprint](#runtime-fingerprint) of the iOS build. |
| `android-install-url` | EAS build page of the Android build with `distribution: eas`; empty otherwise. |
| `android-build-id`    | EAS build id of the Android build with `distribution: eas`; empty otherwise. |
| `android-release-url` | GitHub Release of the Android build with `distribution: github-release`; empty otherwise. |
| `android-fingerprint` | [Runtime fingerprint](#runtime-fingerprint) of the Android build. |

A caller's notification job reads them as `needs.<job>.outputs.<name>`:

```yaml
jobs:
    dev-release:
        uses: rnw-community/mobile-ci/.github/workflows/native-dev-release.yml@v4.5.0 # v4.5.0
        with:
            app-dir: apps/mobile
            enable-ios: false
            enable-android: true
            distribution: eas
        secrets:
            EXPO_TOKEN: ${{ secrets.EXPO_TOKEN }}
    notify:
        needs: dev-release
        runs-on: ubuntu-latest
        steps:
            - env:
                  INSTALL_URL: ${{ needs.dev-release.outputs.android-install-url }}
              run: echo "Android dev build - $INSTALL_URL"
```

## Release assets

With `distribution: github-release` (the default):

Every dev release carries three assets: the build artifact (`app.ipa` /
`app.apk` by default, or `app.aab`), a `SHA256SUMS` file, and a `build-meta.json` file.

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
    "embeddedBuildNumber": "482.1",
    "embeddedVersion": "1.4.2",
    "fingerprint": "4f1c0e9b2a7d8c6e5f4a3b2c1d0e9f8a7b6c5d4e",
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
| `buildNumber` | yes              | `<run_number>.<run_attempt>`, the same deterministic build number used elsewhere in the job. This is what the workflow exported to the build as `DEVELOPMENT_BUILD_NUMBER`, not what the binary carries — read `embeddedBuildNumber` for that. |
| `embeddedBuildNumber` | no       | The build number read back from the built binary: iOS `CFBundleVersion` from the `.ipa`'s `Info.plist`, Android `versionCode` (`aapt2 dump badging` for an `.apk`, `bundletool dump manifest` for an `.aab`). Omitted when the Android host has no `aapt2`/`bundletool` (the job warns); never omitted on iOS, where an unreadable `Info.plist` fails the job. See [Embedded build number](#embedded-build-number). |
| `embeddedVersion` | no           | The version read back from the built binary: iOS `CFBundleShortVersionString`, Android `versionName`. Omitted when it could not be read or is empty. |
| `fingerprint` | no               | The platform's runtime version (`ota-runtime-version`), the one an `expo-ota-preview.yml` update must carry to load on this build. See [Runtime fingerprint](#runtime-fingerprint). |
| `commitSha`   | yes              | `github.sha` for the run that produced the build. |
| `branch`      | yes              | `github.ref_name` for the run that produced the build. |
| `builtAt`     | yes              | UTC build timestamp, ISO 8601 (`date -u +%Y-%m-%dT%H:%M:%SZ`). |
| `workflowUrl` | yes              | Direct link to the workflow run that produced this release. |
| `tagName`     | yes              | The release tag this asset was attached to (`<tag-prefix>-<platform>-<run_number>`). |
| `assetName`   | yes              | Basename of the build artifact in this release (`app.ipa` / `app.apk` or `app.aab`). |
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
   `assetName`/`sha256`/`version`/`buildNumber`/`embeddedBuildNumber` — **prefer this over parsing
   `tag_name` or the release notes body**, both of which are incidental
   formatting, not a contract. `build-meta.json` is the contract.
5. Download the release asset whose name equals the `assetName` value read
   from `build-meta.json`, then verify it against `sha256` (or against
   `SHA256SUMS`) before installing/running it.

If discovery needs a higher rate limit than unauthenticated requests allow,
or the releases live in a private repository, authenticate with a bearer
token (`Authorization: Bearer <token>`, a fine-grained PAT scoped to this
single repo with at least `contents: read`) **only from a trusted
server-side context** — a backend the consumer controls, a CI job, or a
build script. Never embed that token in a public web page or any other
client the token's owner does not control: a token sent in a browser
request is visible to every visitor via devtools/network inspection, and a
`contents: read` PAT for a private repository would hand out read access
to that repository's contents to anyone who copies it out of the request.
A public "latest dev build" page should call unauthenticated discovery
directly (public repo) or proxy the authenticated call through a trusted
backend it controls (private repo) — never ship the token to the browser.

## Embedded build number

`buildNumber` records what the workflow *handed* the build; whether the app
actually wires `DEVELOPMENT_BUILD_NUMBER` into its binary is the app's
configuration, so the two can silently disagree. Right after the EAS build,
each job therefore reads back what the binary embeds and publishes it as
`embeddedBuildNumber` / `embeddedVersion` in `build-meta.json`:

- **iOS** extracts `Payload/<name>.app/Info.plist` from the `.ipa` and reads
  `CFBundleVersion` / `CFBundleShortVersionString` with `plutil` (falling back
  to `/usr/libexec/PlistBuddy`). An `.ipa` without exactly one readable
  top-level `Info.plist` and `CFBundleVersion` fails the job — it is a broken
  artifact.
- **Android** reads `versionCode` / `versionName` with `aapt2 dump badging`
  for an `.apk` (`aapt2` on `PATH`, else the numerically newest `build-tools/*/aapt2` under
  `$ANDROID_HOME` or `$ANDROID_SDK_ROOT`) or `bundletool dump manifest` for an
  `.aab` (`bundletool` on `PATH`). A host without the tool gets a
  `::warning::` and the fields are omitted; a tool that is present but cannot
  read the artifact, or reads no integer `versionCode`, fails the job.

Set `ios-verify-embedded-build-number: true` to fail the iOS job — before any
release is created — when `CFBundleVersion` differs from
`DEVELOPMENT_BUILD_NUMBER`. It is off by default because it holds only when
the app wires the variable in, e.g.:

```js
// app.config.js
export default ({ config }) => ({
    ...config,
    ios: { ...config.ios, buildNumber: process.env.DEVELOPMENT_BUILD_NUMBER },
});
```

with `"cli": { "appVersionSource": "local" }` in `eas.json` so EAS does not
substitute its own remote build number. There is no Android equivalent:
`versionCode` must be an integer and can never equal
`<run_number>.<run_attempt>`, so compare it yourself in
`android-post-build-command` against whatever integer your config derives.

`ios-post-build-command` / `android-post-build-command` run in `app-dir`
after the read-back and before the draft release is created, so a non-zero
exit stops publication. They see the job's env plus `ARTIFACT_PATH`,
`EMBEDDED_BUILD_NUMBER` and `EMBEDDED_VERSION`, e.g. to assert a derived
`versionCode`:

```yaml
android-post-build-command: test "$EMBEDDED_BUILD_NUMBER" = "$GITHUB_RUN_NUMBER"
```

## Inputs

| Name                     | Required | Default                             | Description |
| --------------------------- | -------- | -------------------------------------- | -------------- |
| `enable-ios`                 | no       | `true`                                  | Run the `ios-dev-release` job. |
| `enable-android`             | no       | `false`                                 | Run the `android-dev-release` job. |
| `ios-runner-labels`          | no       | `["self-hosted","macOS","ARM64"]`         | JSON array of self-hosted runner labels for the iOS dev-release job. |
| `control-runner-labels` | no | `'["ubuntu-latest"]'` | JSON array of runner labels for the lightweight control jobs (detect/status/collect/validate-manifest/cancel-queued-runs), which need no self-hosted hardware. Set it when the org has no hosted runners, e.g. an ephemeral RunsOn label set; it is passed on to `expo-base-plan.yml` by the workflows that call it. |
| `runs-on-cache-bypass` | no | `false` | Opt-in. When a job lands on a RunsOn runner started with `extras=s3-cache`, whose cache proxy takes over the Actions results URL and breaks `actions/upload-artifact`/`download-artifact`, run a SHA-pinned `runs-on/action` first (via the [`runs-on-cache-bypass`](../../actions/runs-on-cache-bypass/README.md) action). A logged no-op on every other runner. |
| `android-runner-labels`      | no       | `["self-hosted","trf-linux-amd64-4x8"]`         | JSON array of self-hosted runner labels for the Android dev-release job. The default is the x86_64 Linux pool (4 vCPU / 8 GiB): the NDK `eas build --local` needs ships for x86_64 Linux and macOS only, never linux-aarch64, and the build needs no Mac. Proven there by suuudokuuu's `native-publish` Android job. |
| `app-dir`                    | **yes**  | —                                        | App directory containing `app.json`/`eas.json`. |
| `node-version`               | no       | `22`                                     | Node version for `actions/setup-node`. |
| `install-command`            | no       | `yarn install --immutable`                | JS dependency install command. |
| `enable-corepack`            | no       | `true`                                    | Run `corepack enable` before install. Skipped when the resolved package manager is `pnpm` (provisioned by `pnpm/action-setup`). |
| `package-manager`            | no       | `''` (auto-detect)                        | Override the JS package manager (`yarn`, `pnpm`, `npm`). Empty auto-detects at the repo root: `devEngines.packageManager` / `packageManager` in `package.json` (needs `jq` on the runner), else exactly one root lockfile (`yarn.lock` / `pnpm-lock.yaml` / `package-lock.json` or `npm-shrinkwrap.json`); no match, an ambiguous match or an unsupported value fails the job. Drives pnpm provisioning and, in the jobs that configure one, `actions/setup-node`'s `cache:` — set `install-command` to match (e.g. `pnpm install --frozen-lockfile`). Resolving to `pnpm` also requires a pnpm version in `package.json`. See [Package manager](../../README.md#package-manager). |
| `build-command`              | no       | `''`                                      | Optional workspace JS build command run at repo root before the dev build. |
| `eas-cli-version`            | no       | `20.5.1`                                  | Pinned `eas-cli` npm version invoked via `npx eas-cli@<version>`. |
| `build-profile`              | no       | `development`                             | EAS build profile (`eas.json` `build.<profile>`) used for both platforms. |
| `distribution`               | no       | `github-release`                          | `github-release` attaches the build to a pruned GitHub Release. `eas` uploads it to EAS internal distribution and outputs its install page — see [EAS distribution](#eas-distribution). Needs an `apk` on Android. Fails closed on any other value. |
| `build-location`             | no       | `local`                                   | `local` runs `eas build --local` on the runner. `cloud` builds on EAS servers (`eas build --json --wait`); it needs `distribution: eas`, a build profile with `distribution: internal`, and no post-build command or `ios-verify-embedded-build-number`. `publish-env`, `EAS_EXTRA_ENV` and `DEVELOPMENT_BUILD_NUMBER` do not reach the EAS builder; put build-time values in the profile's `env` or EAS environment variables. Fails closed on any other value. |
| `ios-pre-build-command`      | no       | `''`                                      | Optional consumer-owned command (e.g. patching `eas.json` or asserting a computed build number) run in `app-dir` before the iOS EAS build, after the App Store Connect key (if any) is written. Receives `DEVELOPMENT_BUILD_NUMBER` and `EXPO_ASC_API_KEY_PATH` — see [Hook environment](#hook-environment). |
| `android-pre-build-command`  | no       | `''`                                      | Optional consumer-owned command run in `app-dir` before the Android EAS build. Receives `DEVELOPMENT_BUILD_NUMBER` — see [Hook environment](#hook-environment). |
| `ios-verify-embedded-build-number` | no | `false`                                | Fail the iOS job, before any release is created, when the built `.ipa`'s `CFBundleVersion` differs from `DEVELOPMENT_BUILD_NUMBER`. Turn on only once the app wires that variable into its build number — see [Embedded build number](#embedded-build-number). No Android equivalent: `versionCode` is an integer and can never equal `<run_number>.<run_attempt>`. |
| `ios-post-build-command`     | no       | `''`                                      | Optional consumer-owned command run in `app-dir` after the iOS EAS build and the embedded build number read-back, before the build is published (GitHub Release or `eas upload`); a non-zero exit stops publication. Runs with the job's env plus `ARTIFACT_PATH` (the `.ipa`), `EMBEDDED_BUILD_NUMBER` (`CFBundleVersion`) and `EMBEDDED_VERSION` (`CFBundleShortVersionString`). |
| `android-post-build-command` | no       | `''`                                      | Optional consumer-owned command run in `app-dir` after the Android EAS build and the embedded build number read-back, before the build is published (GitHub Release or `eas upload`); a non-zero exit stops publication. Runs with the job's env plus `ARTIFACT_PATH` (the `.apk`/`.aab`), `EMBEDDED_BUILD_NUMBER` (`versionCode`) and `EMBEDDED_VERSION` (`versionName`), both empty when the host has no tool to read them. |
| `android-artifact-extension`        | no       | `apk`                                  | Container EAS produces for the Android dev build (`apk` or `aab`), inferred from the `--output` extension. Defaults to `apk`: a dev release is internal distribution that testers sideload, and an `aab` cannot be installed on a device. Fails closed on any other value. |
| `tag-prefix`                 | no       | `dev`                                     | Release tag prefix. Tags are created as `<tag-prefix>-ios-<run_number>` and `<tag-prefix>-android-<run_number>`; with `call-scope`, `<tag-prefix>-<call-scope>-<platform>-<run_number>`. |
| `call-scope`                 | no       | `''`                                      | Names this call's build artifacts (`<platform>-dev-build-<call-scope>`), release tags and the prefix it prunes (`<tag-prefix>-<call-scope>-<platform>-`), preview comment sections and concurrency group, so one call per brand in a matrix cannot overwrite, prune, queue behind or cancel another. Calls that share a run must each set a distinct, non-empty value. `[A-Za-z0-9._]` with single `-` between them; anything else fails the job before it builds. Empty keeps today's names. See [Several calls in one run](#several-calls-in-one-run-call-scope). |
| `keep-releases`              | no       | `5`                                       | Number of newest *other* published releases (per platform tag) to keep in addition to the one the current run just published; older ones are pruned. |
| `pr-comment`                 | no       | `false`                                   | On a `pull_request` event, write each enabled platform's build (release and install link, runtime fingerprint, or the failure and the run link) into the pull request's sticky preview comment, the one `expo-ota-preview.yml` writes too. The calling job must then also grant `pull-requests: write`. |
| `asc-key-path`               | no       | `''`                                       | Optional path, relative to `app-dir`, the App Store Connect API key (`.p8`) is written to and removed from. Only used when the `ASC_API_KEY` secret is set. Leave empty (default) to write the key under `$RUNNER_TEMP` instead, keeping it out of the `eas build --local` archive; set it only when `eas.json` requires the key at a specific `app-dir`-relative location. |
| `build-timeout-minutes`      | no       | `120`                                     | Dev-release job timeout (both platforms). |
| `publish-env`                | no       | `''`                                      | Newline-separated `KEY=VALUE` pairs of non-secret env appended to `$GITHUB_ENV` at the start of `ios-dev-release` and `android-dev-release`, before `eas build` and the pre-build-command hook. Rejects (fails closed) any line without `=` or whose name does not match `^[A-Za-z_][A-Za-z0-9_]*$`. For secret values use the `EAS_EXTRA_ENV` secret instead — inputs are not masked in logs. |

## Hook environment

`ios-pre-build-command` and `android-pre-build-command` run with exactly this
environment, and nothing more:

| Variable                   | iOS pre-build | Android pre-build | Value |
| -------------------------- | ------------- | ----------------- | ----- |
| `EXPO_TOKEN`               | yes           | yes               | The `EXPO_TOKEN` secret (job env). |
| `DEVELOPMENT_BUILD_NUMBER` | yes           | yes               | `<run_number>.<run_attempt>`, exported by the "Compute deterministic build number" step. |
| `publish-env` entries      | yes           | yes               | Every `KEY=VALUE` line of the `publish-env` input. |
| `EAS_EXTRA_ENV` entries    | yes           | yes               | Every `KEY=VALUE` line of the `EAS_EXTRA_ENV` secret, masked. |
| `EXPO_ASC_API_KEY_PATH`    | yes           | —                 | Absolute path of the written App Store Connect API key (`asc-key-path`, or under `$RUNNER_TEMP`); empty when the `ASC_API_KEY` secret is not set. |

plus the runner's own variables (`GITHUB_*`, `RUNNER_*`, the `PATH` the Node
and package-manager setup steps built). The App Store Connect key is written
before the iOS pre-build hook and removed in `always()` after `eas build`.

Hooks do **not** see an `eas.json` build profile's `env`: EAS applies that only
inside `eas build`, not to commands a hook runs such as `expo config`. A
variable a hook needs — `APP_VARIANT`, for instance — must come from
`publish-env` (or `EAS_EXTRA_ENV` if secret). `ASC_KEY_ID` / `ASC_ISSUER_ID`
are exported to the build step only; pass them through `EAS_EXTRA_ENV` if a
hook needs them.

## Secrets

> **Secret values must be the raw file contents, not base64.** Every key secret
> below is written to disk verbatim by these workflows — no decoding step. If a
> secret was previously stored base64-encoded for an action such as
> `MobileDevOps/secret-to-file-action` (which decodes on write), re-store it as
> the plain file contents or `eas submit`/fastlane will read a corrupt key.

| Name                | Required | Description |
| ---------------------- | -------- | -------------- |
| `EXPO_TOKEN`             | no*      | Expo access token, required by both dev-release jobs. |
| `ASC_API_KEY`            | no       | Optional App Store Connect API key contents (`.p8`), used by `ios-dev-release` when the development profile needs automatic device/credential management. |
| `ASC_KEY_ID`             | no       | App Store Connect API key ID matching `ASC_API_KEY`. Exported to the build step as `EXPO_ASC_KEY_ID`; set alongside `ASC_API_KEY`/`ASC_ISSUER_ID` so EAS can resolve the key non-interactively. |
| `ASC_ISSUER_ID`          | no       | App Store Connect API key issuer ID matching `ASC_API_KEY`. Exported to the build step as `EXPO_ASC_ISSUER_ID`; set alongside `ASC_API_KEY`/`ASC_KEY_ID` so EAS can resolve the key non-interactively. |
| `EAS_EXTRA_ENV`          | no       | Newline-separated `KEY=VALUE` pairs of secret env appended to `$GITHUB_ENV` at the start of `ios-dev-release` and `android-dev-release`. Parsed by [`apply-secret-env`](../../actions/apply-secret-env/README.md): fails closed on a malformed line without echoing it, masks each value (`::add-mask::`) before writing it to `$GITHUB_ENV` with a collision-proof delimiter, so it never appears unredacted in logs (empty values are not masked), and accepts `KEY<<DELIMITER` … `DELIMITER` for a multi-line value. Use this for secrets `eas build` or a pre-build-command hook need on the environment — e.g. `EXPO_APPLE_APP_SPECIFIC_PASSWORD`. |

\* `EXPO_TOKEN` is declared optional at the `workflow_call` level, but each
enabled dev-release job validates it is present at the start of the job and
fails fast with a clear error if it is missing. Pass secrets via `secrets:
inherit` or an explicit `secrets:` block in the caller workflow.

## Permissions

The caller workflow needs `permissions: contents: write` (or an equivalent
token) — both jobs create and prune GitHub Releases and tags. With
`distribution: eas` no release is touched, but the jobs still declare
`contents: write`, so the caller must keep granting it.

With `pr-comment: true` it also needs `pull-requests: write`. The comment job
requests no permissions of its own and inherits the calling job's, so a
caller that does not opt in needs no new grant. A job that requested
`pull-requests: write` would make GitHub refuse to start the whole run for
every caller that does not grant it, even with the job skipped. For the same
reason the workflow no longer sets a top-level `permissions:` block. Every
other job declares its own (`contents: write` for the build jobs, none for
`status`).

## Runtime fingerprint

Each job resolves the platform's runtime version with
[`ota-runtime-version`](../../actions/ota-runtime-version/README.md) — the
project's own `expo-updates`, under `build-profile`'s `eas.json` env, the same
source `expo-ota-preview.yml` uses for the update — after installing
dependencies and before any pre-build hook. It records it as `fingerprint` in
`build-meta.json`, and in the release notes as a visible line plus a
`<!-- mobile-ci:fingerprint:<runtime> -->` marker. That marker is how
`expo-ota-preview.yml`'s `dev-release-tag-prefix` finds the dev build an OTA
update can load on. A runtime version that cannot be resolved fails the job.
Before v4.2.0 the marker carried the pinned `@expo/fingerprint` hash of
`native-fingerprint`, which can differ from the build's real runtime; builds
from then on match by construction.

## Examples

### Minimal

```yaml
# .github/workflows/native-dev-release.yml
name: Native dev release
on:
    workflow_dispatch:
    push:
        branches: [main]
jobs:
    dev-release:
        permissions:
            contents: write
        uses: rnw-community/mobile-ci/.github/workflows/native-dev-release.yml@v4.5.0 # v4.5.0
        with:
            app-dir: apps/mobile
            enable-ios: true
        secrets:
            EXPO_TOKEN: ${{ secrets.EXPO_TOKEN }}
```

### Full

Both platforms on every pull request and on `main`, with the install links in
the pull request's sticky comment. For a public repository keep the default
`distribution: github-release`; a private repository's testers need
`distribution: eas` (see [EAS distribution](#eas-distribution)).

```yaml
# .github/workflows/native-dev-release.yml
name: Native dev release
on:
    pull_request:
    push:
        branches: [main]
jobs:
    dev-release:
        permissions:
            contents: write
            pull-requests: write
        uses: rnw-community/mobile-ci/.github/workflows/native-dev-release.yml@v4.5.0 # v4.5.0
        with:
            app-dir: apps/mobile
            enable-ios: true
            enable-android: true
            build-profile: development
            distribution: eas
            build-location: local
            pr-comment: true
            install-command: pnpm install --frozen-lockfile
            publish-env: |
                APP_VARIANT=development
        secrets:
            EXPO_TOKEN: ${{ secrets.EXPO_TOKEN }}
            EAS_EXTRA_ENV: SENTRY_AUTH_TOKEN=${{ secrets.SENTRY_AUTH_TOKEN }}
```

### Several calls in one run: `call-scope`

Without it, every call in a run uses the same build artifact names
(`ios-dev-build`, `android-dev-build`), release tags
(`<tag-prefix>-<platform>-<run_number>`) and concurrency group, so a second call
— a brand matrix, say — fails its artifact upload, publishes over the first
call's release, or waits behind it. Give each call its own `call-scope`:

```yaml
# .github/workflows/dev-build.yml
name: Dev build
on:
    workflow_dispatch:
permissions: {}
jobs:
    dev-build:
        strategy:
            fail-fast: false
            matrix:
                brand: [acme, globex]
        permissions:
            contents: write
        uses: rnw-community/mobile-ci/.github/workflows/native-dev-release.yml@v4.5.0 # v4.5.0
        with:
            app-dir: apps/mobile
            enable-android: true
            build-profile: development-${{ matrix.brand }}
            distribution: eas
            call-scope: ${{ matrix.brand }}
        secrets:
            EXPO_TOKEN: ${{ secrets.EXPO_TOKEN }}
```

Each call then uploads `<platform>-dev-build-<call-scope>`, tags its releases
`<tag-prefix>-<call-scope>-<platform>-<run_number>` and prunes only those (a
prune keeps to tags whose remainder after its prefix is a run number, so
neither an unscoped call nor another scope's releases are ever pruned), writes
its own `<platform>-dev-build-<call-scope>` section of the preview comment, and
runs in its own concurrency group. For `expo-ota-preview.yml` to find a brand's
dev build, pass it `dev-release-tag-prefix: <tag-prefix>-<call-scope>`. Two
calls that still share a scope fail closed: the artifact upload rejects the
duplicate name, and a release step that finds its tag already holding this run
attempt's build number refuses to publish over it. The outputs of a matrix call
are those of whichever leg finished last, so read each brand's install page from
its job summary, or call the workflow once per brand without a matrix. A
complete caller is
[docs/examples/private-multi-brand-expo-app/dev-build.yml](../examples/private-multi-brand-expo-app/dev-build.yml).

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
        uses: rnw-community/mobile-ci/.github/workflows/native-dev-release.yml@v4.5.0 # v4.5.0
        with:
            app-dir: apps/mobile
            enable-ios: true
        secrets:
            EXPO_TOKEN: ${{ secrets.EXPO_TOKEN }}
            EAS_EXTRA_ENV: EXPO_APPLE_APP_SPECIFIC_PASSWORD=${{ secrets.APPLE_PASSWORD }}
```

Complete caller workflows for whole apps, linted and checked against this
workflow's inputs in CI, live in [docs/examples/](../examples/README.md).

### Local build output

Local EAS build output from stdout and stderr passes through a filter that
redacts long encoded payload tokens before they reach the job log. Diagnostic
text is retained. A failed build or output filter still fails the job; filtering
never turns a failed build into a published release.
