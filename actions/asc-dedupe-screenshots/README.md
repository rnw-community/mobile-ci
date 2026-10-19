# asc-dedupe-screenshots

Verifies (and repairs) that an App Store Connect app version carries no
duplicate screenshots, with **zero dependencies beyond `curl`, `jq`, and
`openssl`** - no fastlane, no Ruby, no Node. It signs its own ES256 App Store
Connect API JWT from the `.p8` key, walks every localization of the target
version's screenshot sets, groups each set by file name, and deletes all but
the oldest copy of every duplicate.

## Why this exists

fastlane's `deliver` sometimes double-uploads a screenshot: its post-upload
verification occasionally reports a freshly uploaded screenshot as "missing
on App Store Connect", retries it, and both copies survive. The listing then
shows the same image twice until someone notices. This action is the
post-upload gate that closes that hole; it was extracted from a consumer's
bespoke fastlane/Spaceship lane (`ios_dedupe_screenshots`) so every
`store-screenshots.yml` caller gets it as a built-in.

**Fail-closed stance:** finding duplicates and repairing them still fails the
step by default (`fail-on-duplicates: true`) - duplicates are evidence the
upload lane is flaky, so the run stays red even though the listing is now
correct. Set `fail-on-duplicates: false` to treat a successful repair as
success.

**Submitted versions are detect-only.** App Store Connect forbids modifying
a version's screenshots once it has been submitted for review (HTTP 409
`STATE_ERROR`). Auditing `READY_FOR_DISTRIBUTION` therefore reports undeletable
duplicates via the `undeletable-count` output and a `::warning::`, and - with
the default `fail-on-duplicates: true` - still fails the run: someone must
clean those up manually or they age out with the next version submission.
Dedupe *before* submitting by targeting `PREPARE_FOR_SUBMISSION`.

## When to use

- **After every screenshot upload to App Store Connect** - wire it into
  `store-screenshots.yml` via its `asc-dedupe-screenshots: true` input, or
  call it directly after your own upload step.
- Against the editable version (`PREPARE_FOR_SUBMISSION`, default) in the
  same run that uploaded, or against the live version
  (`READY_FOR_DISTRIBUTION`) as an audit.
- As a standalone maintenance run (e.g. `workflow_dispatch`) with
  `missing-version: skip`, so a moment when the app has no version in
  `version-state` is a zero-count notice instead of a failure.

It never touches metadata, binaries, or non-duplicate screenshots; a clean
listing is a read-only pass that appends a coverage table to the job summary.

## Inputs

| Name                  | Required | Default                     | Description |
| ----------------------- | -------- | ----------------------------- | -------------- |
| `app-id`                 | yes      | —                             | Bundle identifier, resolved to exactly one App Store Connect app or fail-closed. |
| `asc-key-path`           | yes      | —                             | Path to the `.p8` API key file. Write it from a secret in a prior step (see example) and remove it afterwards. |
| `asc-key-id`             | yes      | —                             | App Store Connect API key ID. |
| `asc-issuer-id`          | yes      | —                             | App Store Connect API issuer ID (UUID). |
| `version-state`           | no       | `PREPARE_FOR_SUBMISSION`      | Which version's localizations to dedupe; an App Store Connect `AppVersionState` value (see [Version states](#version-states)). |
| `fail-on-duplicates`      | no       | `true`                        | Fail the step when any duplicate had to be deleted. |
| `missing-version`         | no       | `error`                       | When no version is in `version-state`: `error` fails the step; `skip` logs a `::notice::`, sets both counts to `0` and succeeds. Any other value fails the step. See [Missing version](#missing-version). |

## Version states

The version is selected with `filter[appVersionState]`, which replaced the
`appStoreState` filter Apple deprecated in
[App Store Connect API 3.7](https://developer.apple.com/documentation/appstoreconnectapi/app-store-connect-api-3-7-release-notes).
`version-state` must be one of the
[`AppVersionState`](https://developer.apple.com/documentation/appstoreconnectapi/appversionstate)
values: `ACCEPTED`, `DEVELOPER_REJECTED`, `IN_REVIEW`, `INVALID_BINARY`,
`METADATA_REJECTED`, `PENDING_APPLE_RELEASE`, `PENDING_DEVELOPER_RELEASE`,
`PREPARE_FOR_SUBMISSION`, `PROCESSING_FOR_DISTRIBUTION`,
`READY_FOR_DISTRIBUTION`, `READY_FOR_REVIEW`, `REJECTED`,
`REPLACED_WITH_NEW_VERSION`, `WAITING_FOR_EXPORT_COMPLIANCE`,
`WAITING_FOR_REVIEW`.

The two deprecated `appStoreState` values that have a direct equivalent keep
working with a `::warning::`: `READY_FOR_SALE` becomes
`READY_FOR_DISTRIBUTION` and `PROCESSING_FOR_APP_STORE` becomes
`PROCESSING_FOR_DISTRIBUTION`. The other `appStoreState`-only values
(`DEVELOPER_REMOVED_FROM_SALE`, `REMOVED_FROM_SALE`, `PREORDER_READY_FOR_SALE`,
`PENDING_CONTRACT`, `NOT_APPLICABLE`) describe distribution status rather than
a version state, so they fail the step instead of guessing a mapping.

## Missing version

Right after an upload, the version in `version-state` must exist - its absence
means the upload targeted a different version - so the default
`missing-version: error` fails the step. A standalone maintenance run has no
such guarantee (for example, no `PREPARE_FOR_SUBMISSION` version exists
between a release and the next version being created); pass
`missing-version: skip` there.

## Outputs

| Name             | Description |
| ------------------ | -------------- |
| `removed-count`     | Number of duplicate screenshots deleted. |
| `undeletable-count` | Duplicates detected on an already-submitted version (detect-only; see above). |

## Example

```yaml
- name: Write App Store Connect API key
  env:
      ASC_API_KEY: ${{ secrets.ASC_API_KEY }}
  run: |
      set -euo pipefail
      key_path="$RUNNER_TEMP/asc-api-key.p8"
      printf '%s' "$ASC_API_KEY" > "$key_path"
      chmod 600 "$key_path"
      echo "KEY_PATH=$key_path" >> "$GITHUB_ENV"

- uses: rnw-community/mobile-ci/actions/asc-dedupe-screenshots@v4.2.0 # v4.2.0
  id: dedupe
  with:
      app-id: com.example.app
      asc-key-path: ${{ env.KEY_PATH }}
      asc-key-id: ${{ secrets.ASC_KEY_ID }}
      asc-issuer-id: ${{ secrets.ASC_ISSUER_ID }}

- name: Remove App Store Connect API key
  if: always()
  run: rm -f "$RUNNER_TEMP/asc-api-key.p8"
```

Inside [`store-screenshots.yml`](../../docs/workflows/store-screenshots.md)
this whole dance is one input pair:

```yaml
with:
    upload-screenshots: true
    upload-command: bundle exec fastlane ios ios_screenshots
    asc-dedupe-screenshots: true
secrets:
    ASC_API_KEY: ${{ secrets.ASC_API_KEY }}
    ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
    ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
```
