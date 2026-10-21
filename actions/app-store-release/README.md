# app-store-release

Submits an already-uploaded, processed iOS build for App Review through the
App Store Connect API. A dependency-free Node script (`node:crypto` signs the
ES256 JWT, global `fetch` calls the API): no fastlane, no Ruby, no Mac, so it
runs on any Linux runner with Node 18 or newer.

What a run does, in order:

1. Resolves the build: `build-number` of `version`, or the newest `VALID`,
   unexpired build of `version`. A build that is still processing, or that
   does not exist, fails the step.
2. Finds the App Store version for `version`. If it is already past the
   editable states (`WAITING_FOR_REVIEW`, `IN_REVIEW`, `PENDING_DEVELOPER_RELEASE`,
   `READY_FOR_DISTRIBUTION`, ...) with the same build, the step reports
   `result=already-submitted` and succeeds without a change; with another
   build it fails, because App Store Connect only changes the build of an
   editable version.
3. Fails closed when the build has no export compliance answer
   (`usesNonExemptEncryption` unset): set `ITSAppUsesNonExemptEncryption` in
   `Info.plist` (Expo: `ios.config.usesNonExemptEncryption`) so every build
   carries the answer.
4. Creates the version when none exists, or renames the one editable version
   App Store Connect allows (`PREPARE_FOR_SUBMISSION`, `REJECTED`, ...) to
   `version`, and sets `release-type` (plus `scheduled-release-date`).
5. Attaches the build, then adds or removes the phased release.
6. Reuses an open review submission (`READY_FOR_REVIEW` or
   `UNRESOLVED_ISSUES`) or creates one, adds the version to it, and submits it.

With `dry-run: true` (the default) only `GET` requests are made; the step
summary lists every step as `would do`, `unchanged` or `resolved`. A rejected
call fails the step with App Store Connect's own error list, including the
`associatedErrors` that name a missing screenshot set or metadata field.

Version metadata, screenshots and the review contact are not touched: upload
them first (for example with fastlane `deliver`, or
[`store-screenshots.yml`](../../docs/workflows/store-screenshots.md)'s upload).

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `app-id` | yes | - | Numeric App Store Connect app id (App Information > Apple ID), e.g. `6449440933`. |
| `version` | yes | - | Marketing version (`CFBundleShortVersionString`) to submit. |
| `build-number` | no | `''` | Build number (`CFBundleVersion`) to attach. Empty picks the newest `VALID`, unexpired build of `version`. |
| `release-type` | no | `MANUAL` | `MANUAL`, `AFTER_APPROVAL` or `SCHEDULED`. |
| `scheduled-release-date` | no | `''` | ISO-8601 date-time of the earliest release; required with `SCHEDULED`, rejected otherwise. |
| `phased-release` | no | `'false'` | `true` adds Apple's 7-day phased release to the version; `false` removes it. |
| `dry-run` | no | `'true'` | `true` resolves and prints the plan with read-only calls; `false` changes App Store Connect. |
| `asc-key-path` | yes | - | Path to the App Store Connect API key (`.p8`) file. |
| `asc-key-id` | yes | - | App Store Connect API key ID. |
| `asc-issuer-id` | yes | - | App Store Connect API issuer ID (a UUID). |

The API key needs the App Manager role (or Admin).

## Outputs

| Name | Description |
| --- | --- |
| `version` | The marketing version submitted. |
| `build-number` | The build number attached to the version. |
| `result` | `submitted`, `already-submitted`, or `planned` (dry run). |

## Example

```yaml
- name: Write App Store Connect API key
  env:
      ASC_API_KEY: ${{ secrets.ASC_API_KEY }}
  run: |
      set -euo pipefail
      printf '%s' "$ASC_API_KEY" > "$RUNNER_TEMP/asc-api-key.p8"
      chmod 600 "$RUNNER_TEMP/asc-api-key.p8"

- uses: rnw-community/mobile-ci/actions/app-store-release@e6c4d187e50efde57472cb7f4e7ac1032f4b67f3 # feat/store-release-workflow fleet-validation pin
  with:
      app-id: '6449440933'
      version: 2.35.0
      release-type: AFTER_APPROVAL
      dry-run: 'false'
      asc-key-path: ${{ runner.temp }}/asc-api-key.p8
      asc-key-id: ${{ secrets.ASC_KEY_ID }}
      asc-issuer-id: ${{ secrets.ASC_ISSUER_ID }}

- name: Remove App Store Connect API key
  if: always()
  run: rm -f "$RUNNER_TEMP/asc-api-key.p8"
```

[`store-release.yml`](../../docs/workflows/store-release.md) wraps this
action and [`play-store-release`](../play-store-release/README.md) in one
gated, dry-run-by-default job.
