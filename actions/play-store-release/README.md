# play-store-release

Promotes an already-uploaded Android build from one Google Play track to
another through the Play Developer API
[edits](https://developers.google.com/android-publisher/edits) flow. A
dependency-free Node script (`node:crypto` signs the RS256 service-account
JWT, global `fetch` calls the API): no fastlane, no Ruby, any runner with
Node 18 or newer.

What a run does, in order:

1. Exchanges the service account key for an access token and opens an edit.
2. Reads `from-track` and resolves the version code: `version-code`, which
   must be on `from-track`, or the highest version code there.
3. Reads `to-track`. When it already carries that version code completed, or
   in progress at the requested `rollout`, the step reports
   `result=already-released`, discards the edit and succeeds.
4. Writes one release to `to-track`, named like the source release and, with
   `release-notes-from-source`, carrying its release notes: `completed` for
   `rollout: 1`, otherwise `inProgress` with `userFraction: <rollout>` (a
   larger fraction on a re-run moves an existing staged rollout forward).
   Then commits the edit.

With `dry-run: true` (the default) the step opens an edit to read the tracks
(the API has no other way to read them), prints the plan in the step summary
and discards the edit: no track is updated and nothing is committed. Every
uncommitted edit is discarded, including after a failure.

The service account needs the "Release to production, exclude devices, and use
Play App Signing" permission (or "Release apps to testing tracks" when
`to-track` is a testing track) on the app.

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `package-name` | yes | - | Android application id, e.g. `com.example.app`. |
| `from-track` | no | `internal` | Track the build is promoted from. |
| `to-track` | no | `production` | Track the build is promoted to. |
| `version-code` | no | `''` | Version code to promote; it must be on `from-track`. Empty picks the highest version code on `from-track`. |
| `rollout` | no | `'1'` | User fraction in (0, 1]. `1` completes the release; anything lower is a staged `inProgress` rollout. |
| `release-notes-from-source` | no | `'true'` | Copy the source release's release notes. |
| `dry-run` | no | `'true'` | `true` resolves and prints the plan without updating a track or committing; `false` changes Google Play. |
| `service-account-key-path` | yes | - | Path to the Google Play service account JSON key file. |

## Outputs

| Name | Description |
| --- | --- |
| `version-code` | The version code promoted. |
| `result` | `released`, `already-released`, or `planned` (dry run). |

## Example

```yaml
- name: Write Google Play service account key
  env:
      GOOGLE_SERVICE_ACCOUNT_JSON: ${{ secrets.GOOGLE_SERVICE_ACCOUNT_JSON }}
  run: |
      set -euo pipefail
      printf '%s' "$GOOGLE_SERVICE_ACCOUNT_JSON" > "$RUNNER_TEMP/google-service-account.json"
      chmod 600 "$RUNNER_TEMP/google-service-account.json"

- uses: rnw-community/mobile-ci/actions/play-store-release@v4.6.0 # v4.6.0
  with:
      package-name: com.example.app
      rollout: '0.2'
      dry-run: 'false'
      service-account-key-path: ${{ runner.temp }}/google-service-account.json

- name: Remove Google Play service account key
  if: always()
  run: rm -f "$RUNNER_TEMP/google-service-account.json"
```

[`store-release.yml`](../../docs/workflows/store-release.md) wraps this
action and [`app-store-release`](../app-store-release/README.md) in one
gated, dry-run-by-default job.
