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
`STATE_ERROR`). Auditing `READY_FOR_SALE` therefore reports undeletable
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
  (`READY_FOR_SALE`) as an audit.

It never touches metadata, binaries, or non-duplicate screenshots; a clean
listing is a read-only pass that appends a coverage table to the job summary.

## Inputs

| Name                  | Required | Default                     | Description |
| ----------------------- | -------- | ----------------------------- | -------------- |
| `app-id`                 | yes      | —                             | Bundle identifier, resolved to exactly one App Store Connect app or fail-closed. |
| `asc-key-path`           | yes      | —                             | Path to the `.p8` API key file. Write it from a secret in a prior step (see example) and remove it afterwards. |
| `asc-key-id`             | yes      | —                             | App Store Connect API key ID. |
| `asc-issuer-id`          | yes      | —                             | App Store Connect API issuer ID (UUID). |
| `version-state`           | no       | `PREPARE_FOR_SUBMISSION`      | Which version's localizations to dedupe (any `appStoreState` enum value). |
| `fail-on-duplicates`      | no       | `true`                        | Fail the step when any duplicate had to be deleted. |

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

- uses: rnw-community/mobile-ci/actions/asc-dedupe-screenshots@v1
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
