# store-release.yml

`workflow_call` reusable workflow that **releases a build already in the
stores**: it submits an iOS version for App Review and promotes an Android
build from one Play track to another. It builds and uploads nothing —
[`native-publish.yml`](native-publish.md) does that, landing the build in
TestFlight and on a Play testing track; this workflow is the step after, once
the build is tested.

One `release` job on `control-runner-labels` (no Mac, no fastlane): it
validates the selected platforms and their credentials, resolves the iOS
version, writes the keys to `$RUNNER_TEMP`, runs
[`app-store-release`](../../actions/app-store-release/README.md) and
[`play-store-release`](../../actions/play-store-release/README.md), and
removes the keys in `always()`. The Android step still runs when the iOS step
failed, and the job fails if either did.

**Dry run by default.** With `dry-run: true` the job resolves everything —
build, version, tracks, version code — and writes the plan to the job summary
(`would do` / `unchanged` / `resolved` per step) without changing either
store. Pass `dry-run: false` to release.

**Idempotent.** A re-run against a version already waiting for or in review
with the same build, or a track that already carries the version code at the
requested rollout, reports and succeeds without a change.

**Gate it with an Environment.** `github-environment` names a GitHub
Environment for the job, so its protection rules (required reviewers, wait
timer, deployment branches) hold the release until someone approves it.
Store secrets kept only in that environment work too, but the caller must
still pass each one **by name** in its `secrets:` block
(`ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}`): the release job declares the
environment, so GitHub resolves the name to the environment's value there.
A secret the caller does not name arrives empty, with no error from GitHub;
the first step then fails naming it.

## iOS

1. Build: `ios-build-number` of the version, or the newest `VALID`, unexpired
   build of the version.
2. App Store version: the version string's own version if it exists; else the
   one editable version (App Store Connect allows one) renamed to it; else a
   new one. `ios-release-type` (and `ios-scheduled-release-date` for
   `SCHEDULED`) is set on it; empty (the default) leaves an existing
   version's release type as App Store Connect has it and creates a new
   version as `MANUAL`.
3. The build must carry an export compliance answer, or the job fails before
   any change: set `ITSAppUsesNonExemptEncryption` in `Info.plist` (Expo:
   `ios.config.usesNonExemptEncryption: false`).
4. The build is attached, the phased release added or removed per
   `ios-phased-release`, and the version is added to an open review
   submission (or a new one) that is then submitted.

A rejected call fails with App Store Connect's error list, including the
`associatedErrors` naming a missing screenshot set or metadata field. Upload
metadata and screenshots before this runs. Full behaviour:
[`app-store-release`](../../actions/app-store-release/README.md).

The marketing version comes from `ios-version`, or, when it is empty, from
the top-level `"version"` of `version-file` (a JSON file in the caller's
repository, read through a sparse checkout of that one file).

## Android

The Play Developer API edits flow: open an edit, read `android-from-track`,
resolve the version code (`android-version-code`, which must be on the source
track, or the highest there), write one release to `android-to-track` named
like the source release and, with `android-release-notes-from-source`,
carrying its release notes, then commit. `android-rollout: 1` completes the
release; a lower fraction is a staged `inProgress` rollout, and a re-run with a
larger fraction moves it forward. A dry run opens an edit only to read the
tracks and discards it. Full behaviour:
[`play-store-release`](../../actions/play-store-release/README.md).

## Inputs

| Name | Type | Required | Default | Description |
| ---- | ---- | -------- | ------- | ----------- |
| `platforms` | string | yes | - | Comma-separated platforms to release: `ios`, `android`, or `ios,android`. Anything else fails the job. |
| `dry-run` | boolean | no | `true` | Resolve and print the plan, changing nothing. `false` submits and promotes. |
| `github-environment` | string | no | `''` | GitHub Environment the job runs in, so its protection rules gate the release. Empty runs without one. |
| `control-runner-labels` | string | no | `'["ubuntu-latest"]'` | JSON array of runner labels for the `release` job, which only runs Node against the store APIs. Set it when the org has no hosted runners, e.g. an ephemeral RunsOn label set. |
| `timeout-minutes` | number | no | `15` | Job timeout. |
| `node-version` | string | no | `22.x` | Node version for `actions/setup-node`. |
| `version-file` | string | no | `''` | Repository-relative JSON file whose top-level `"version"` is the iOS marketing version, e.g. `apps/mobile/package.json`; read when `ios-version` is empty. |
| `ios-app-id` | string | for `ios`, or `ios-bundle-id` | `''` | Numeric App Store Connect app id (App Information > Apple ID). Empty resolves it from `ios-bundle-id`. |
| `ios-bundle-id` | string | for `ios`, or `ios-app-id` | `''` | Bundle identifier, e.g. `com.example.app`, resolved to the app id through App Store Connect. With both set they must name the same app. |
| `ios-version` | string | no | `''` | Marketing version to submit. Empty reads `version-file`; one of the two is required for `ios`. |
| `ios-build-number` | string | no | `''` | Build number to attach. Empty picks the newest `VALID`, unexpired build of the version. |
| `ios-release-type` | string | no | `''` | `MANUAL`, `AFTER_APPROVAL` or `SCHEDULED`: what happens once the version is approved. Empty keeps an existing version's release type and creates a new version as `MANUAL`. |
| `ios-scheduled-release-date` | string | no | `''` | ISO-8601 earliest release date-time; required with `SCHEDULED`, rejected otherwise. |
| `ios-phased-release` | boolean | no | `false` | Release over Apple's 7-day phased rollout once the version goes live. |
| `android-package` | string | for `android` | `''` | Android application id. |
| `android-from-track` | string | no | `internal` | Track the build is promoted from. |
| `android-to-track` | string | no | `production` | Track the build is promoted to. |
| `android-version-code` | string | no | `''` | Version code to promote. Empty picks the highest on `android-from-track`. |
| `android-rollout` | string | no | `'1'` | User fraction in (0, 1]: `1` completes the release, lower starts a staged rollout. `0`, above `1` or a percentage fails the job. |
| `android-release-notes-from-source` | boolean | no | `true` | Copy the source release's release notes to the promoted release. |

The config-file mode of [`store-screenshots.yml`](store-screenshots.md#config-file)
is not offered: every input here is a scalar, so a caller is already a short
`with:` block.

## Secrets

> `ASC_API_KEY` is the raw `.p8` contents, exactly as
> [`native-publish.yml`](native-publish.md#secrets) takes it, so both
> workflows can share one set of secrets. `ASC_API_KEY_BASE64` takes the
> same key base64-encoded, the form `apple-signing`, `xcode-archive-upload`
> and `swift-ios.yml` use; set one of the two.

| Name | Required | Description |
| ---- | -------- | ----------- |
| `ASC_API_KEY` | for `ios`, or `ASC_API_KEY_BASE64` | App Store Connect API key contents (`.p8`); the key needs the App Manager role. |
| `ASC_API_KEY_BASE64` | for `ios`, or `ASC_API_KEY` | The same `.p8` key, base64-encoded. Setting both fails the job. |
| `ASC_KEY_ID` | for `ios` | App Store Connect API key ID. |
| `ASC_ISSUER_ID` | for `ios` | App Store Connect API issuer ID. |
| `GOOGLE_SERVICE_ACCOUNT_JSON` | for `android` | Google Play service account key JSON contents; the account needs release permission on the target track. |

All of them are optional at the `workflow_call` level so a single-platform caller
passes only its own. The first step fails the job, before either store is
called, naming every secret and input the selected platforms need and lack.

## Permissions

The calling job grants `contents: read` (the sparse checkout of
`version-file`). Nothing is written to the repository.

## Concurrency

Runs are serialized per repository, `ios-app-id`, `ios-bundle-id` and
`android-package`, never
cancelled: two overlapping releases of one app would race on the same review
submission or edit.

## Examples

### Minimal

A dry run of both stores, for the build `native-publish.yml` uploaded last:

```yaml
jobs:
    release:
        permissions:
            contents: read
        uses: rnw-community/mobile-ci/.github/workflows/store-release.yml@v4.6.0 # v4.6.0
        with:
            platforms: ios,android
            ios-app-id: '1234567890'
            version-file: apps/mobile/package.json
            android-package: com.example.app
        secrets:
            ASC_API_KEY: ${{ secrets.ASC_API_KEY }}
            ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
            ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
            GOOGLE_SERVICE_ACCOUNT_JSON: ${{ secrets.GOOGLE_SERVICE_ACCOUNT_JSON }}
```

### Full

A manual release behind an approval, with a dry-run switch, a staged Android
rollout and an iOS release on approval:

```yaml
name: Release to stores
on:
    workflow_dispatch:
        inputs:
            dry-run:
                type: boolean
                default: true
            android-rollout:
                type: string
                default: '0.2'
jobs:
    release:
        permissions:
            contents: read
        uses: rnw-community/mobile-ci/.github/workflows/store-release.yml@v4.6.0 # v4.6.0
        with:
            platforms: ios,android
            dry-run: ${{ inputs.dry-run }}
            github-environment: production
            ios-app-id: '1234567890'
            version-file: apps/mobile/package.json
            ios-release-type: AFTER_APPROVAL
            ios-phased-release: true
            android-package: com.example.app
            android-from-track: internal
            android-to-track: production
            android-rollout: ${{ inputs.android-rollout }}
            android-release-notes-from-source: true
        secrets:
            ASC_API_KEY: ${{ secrets.ASC_API_KEY }}
            ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
            ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
            GOOGLE_SERVICE_ACCOUNT_JSON: ${{ secrets.GOOGLE_SERVICE_ACCOUNT_JSON }}
```

Complete caller workflows for whole apps, linted and checked against this
workflow's inputs in CI, live in [docs/examples/](../examples/README.md).
