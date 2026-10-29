# preview-sweep-reusable.yml

`workflow_call` reusable workflow for a `schedule:` trigger: deletes the
`expo-ota-preview.yml` releases that
[`pr-closed-cleanup-reusable.yml`](pr-closed-cleanup-reusable.md) missed — a
pull request closed before that cleanup was wired, a cleanup run that failed
closed, or a branch preview nobody prunes. It **defaults to a dry run**: the
first runs only log what they would delete.

**sweep**: lists every release (drafts included) whose tag starts with
`<release-tag-prefix>-` and ends in `-<40-hex sha>`, the shape
`expo-ota-preview.yml` gives every preview. Any other release — a store
release, a `native-dev-release.yml` build — is never considered. Oldest first,
each preview is then:

| Preview | Deleted when | Kept when |
| ------- | ------------ | --------- |
| any | — | created less than `grace-period-hours` ago, whatever else holds, so a run that is still publishing is never raced |
| of a pull request (`<prefix>-<app-scope>-pr-<number>-<sha>`) | the pull request is **closed** (merged or not), whatever its age | the pull request is **open**, whatever its age; or the tag names a pull request the repository does not have (logged as a `::warning::`) |
| of a branch (`<prefix>-<app-scope>-<branch>-<hash>-<sha>`) | it is at least `max-age-days` old | younger than that |

A deleted release takes its git tag with it. At most `max-deletions` releases
go per run; the rest are counted in a `::notice::` and wait for the next run.
A release or tag already gone (HTTP 404, or 422 "Reference does not exist")
counts as deleted. Any other API error — the release list, a pull request
lookup, a delete — fails the job, so a sweep never reports a cleanup that did
not happen and never deletes a preview whose pull request it could not read.
The step summary reports how many releases were (or would be) deleted.

The job talks to the REST API with `curl` and `jq` and does not need `gh`.
It runs in a concurrency group per repository and prefix with
`cancel-in-progress: false`, so two sweeps never interleave.

## Inputs

| Input                | Required | Default               | Description |
| -------------------- | -------- | --------------------- | ----------- |
| `release-tag-prefix` | no       | `ota`                 | The `release-tag-prefix` the caller passes to `expo-ota-preview.yml`. Must be `[A-Za-z0-9._-]`. |
| `dry-run`            | no       | `true`                | Log `Would delete <tag> (<reason>)` and delete nothing. Set `false` once a dry run lists only what you expect. |
| `max-age-days`       | no       | `30`                  | Delete a branch preview once it is this many days old. A pull request's previews go once it is closed, whatever their age. |
| `grace-period-hours` | no       | `24`                  | Never delete a preview created less than this many hours ago. |
| `max-deletions`      | no       | `50`                  | Most releases deleted per run, oldest first. At least `1`; use `dry-run` to delete nothing. |
| `runner-labels`      | no       | `'["ubuntu-latest"]'` | JSON array of runner labels for the sweep job. The runner needs `curl` and `jq`. |

## Secrets

None. The job uses the calling job's `GITHUB_TOKEN`.

## Permissions

The sweep job requests `contents: write` (delete releases and tags) and
`pull-requests: read` (read each pull request's state), so the calling job
must grant both; GitHub refuses to start the run otherwise.

## Examples

### Minimal

A dry run: logs what it would delete.

```yaml
on:
    schedule:
        - cron: '17 4 * * *'
jobs:
    sweep:
        permissions:
            contents: write
            pull-requests: read
        uses: rnw-community/mobile-ci/.github/workflows/preview-sweep-reusable.yml@v4.6.0 # v4.6.0
```

### Full

```yaml
# .github/workflows/preview-sweep.yml
name: preview-sweep
on:
    schedule:
        - cron: '17 4 * * *'
    workflow_dispatch:
permissions:
    contents: read
jobs:
    sweep:
        permissions:
            contents: write
            pull-requests: read
        uses: rnw-community/mobile-ci/.github/workflows/preview-sweep-reusable.yml@v4.6.0 # v4.6.0
        with:
            release-tag-prefix: ota
            dry-run: false
            max-age-days: 14
            grace-period-hours: 24
            max-deletions: 50
```

Leave `dry-run` at its default for the first scheduled runs and read the log
before setting it to `false`.

Complete caller workflows for whole apps, linted and checked against this
workflow's inputs in CI, live in [docs/examples/](../examples/README.md).
