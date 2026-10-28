# pr-closed-cleanup-reusable.yml

`workflow_call` reusable workflow: cancels queued/in-progress workflow runs
left behind on a just-closed PR's branch and, opt-in, deletes the PR's
`expo-ota-preview.yml` releases.

**cancel-queued-runs** (always): pages through `queued` then `in_progress`
runs on `github.event.pull_request.head.ref`, filters to runs belonging to
this PR number in this repository (excluding the currently running
cancellation run itself), and cancels each one via the GitHub API. Intended
for a serialized self-hosted fleet where a closed PR's queued/running jobs
would otherwise sit there starving the next PR's runs.

With `ota-preview-release-tag-prefix` set, the job then **waits for those
runs to stop**: a cancel request only asks a run to stop, and a run still
finishing could otherwise publish a preview release just after the cleanup
deleted it. Every 15 seconds it lists the branch's `queued`, `in_progress`,
`waiting`, `requested` and `pending` runs of this pull request (a run on the
branch that lists no pull request at all counts too, since a closed pull
request can drop out of a run's `pull_requests`), cancels any still active
again, and returns once none is left. A run still active after
`wait-for-runs-timeout-minutes`, or a run list the API refuses, fails the job,
and the deletion below never runs: the previews stay until the job is re-run.
A run with a job in progress is never force-cancelled, so its `always()`
cleanup steps (simulator leases, emulator containers) still run. A run that is
still `queued`, `waiting`, `requested` or `pending` after two minutes of cancel
requests has no job running and nothing to tear down; GitHub sometimes leaves
such a run queued indefinitely, so the job then force-cancels it.

The workflow runs in its own concurrency group, keyed on the pull request,
with `cancel-in-progress: false`, and its cancel step excludes its own run, so
nothing it starts can cancel the cleanup halfway through a deletion.

**delete-ota-previews** (only when `ota-preview-release-tag-prefix` is set,
and skipped for a fork pull request, which never gets a preview; it runs only
after the wait above succeeded): deletes every
release, draft or published, whose tag is
`<prefix>-<app-scope>-pr-<number>-<40-hex sha>` — the tag `expo-ota-preview.yml`
gives each preview of a pull request — and then every remaining git tag of that
shape, so a release deleted earlier without its tag does not leave the tag
behind. Previews of other pull requests and of branches are never touched;
`pr-4` does not match `pr-42`. A release or tag that is already gone (HTTP 404,
or 422 "Reference does not exist") counts as deleted; any other API error fails
the job rather than reporting a cleanup that did not happen. The job talks to
the REST API with `curl` and `jq` and does not need `gh`; a runner without
either fails with an error naming the missing tool.

## Inputs

| Input                                | Required | Default             | Description |
| ------------------------------------ | -------- | ------------------- | ----------- |
| `ota-preview-release-tag-prefix`     | no       | `''`                | The `release-tag-prefix` the caller passes to `expo-ota-preview.yml` (its default is `ota`). Set it to delete the closed PR's previews; empty leaves releases untouched. Must be `[A-Za-z0-9._-]`. Requires `contents: write` on the calling job. |
| `ota-preview-cleanup-runner-labels`  | no       | `'["ubuntu-latest"]'` | JSON array of runner labels for the preview cleanup job. The runner needs `curl` and `jq`. |
| `control-runner-labels` | no | `'["ubuntu-latest"]'` | JSON array of runner labels for the lightweight control jobs (detect/status/collect/validate-manifest/cancel-queued-runs), which need no self-hosted hardware. Set it when the org has no hosted runners, e.g. an ephemeral RunsOn label set; it is passed on to `expo-base-plan.yml` by the workflows that call it. |
| `wait-for-runs-timeout-minutes`      | no       | `10`                | With `ota-preview-release-tag-prefix` set, how long to wait after cancelling for every run of the closed pull request to stop. A run still active at the deadline fails the cleanup and nothing is deleted; `0` checks once. |

Everything else — the PR's head branch, PR number, and current run id —
comes from `github.event.pull_request.*` and `github.run_id` in the *calling*
workflow's own event context, which is why the caller must be triggered by
`pull_request: types: [closed]`.

## Secrets

None. Both jobs use the calling job's `GITHUB_TOKEN`.

## Permissions

The calling job needs `actions: write` — cancelling a run requires it.

With `ota-preview-release-tag-prefix` set it also needs `contents: write`;
the cleanup job declares no permissions of its own and inherits the calling
job's, so an existing caller that grants only `actions: write` keeps working
until it opts in. Without `contents: write` the cleanup job fails on its first
delete with an error naming the permission.

## Examples

### Minimal

```yaml
# .github/workflows/pr-closed-cleanup.yml
name: pr-closed-cleanup
on:
    pull_request:
        types: [closed]
permissions:
    actions: write
jobs:
    cleanup:
        permissions:
            actions: write
        uses: rnw-community/mobile-ci/.github/workflows/pr-closed-cleanup-reusable.yml@v4.5.0 # v4.5.0
```

### Full

With OTA preview cleanup, for a caller of `expo-ota-preview.yml` on the
default `release-tag-prefix`:

```yaml
name: pr-closed-cleanup
on:
    pull_request:
        types: [closed]
jobs:
    cleanup:
        permissions:
            actions: write
            contents: write
        uses: rnw-community/mobile-ci/.github/workflows/pr-closed-cleanup-reusable.yml@v4.5.0 # v4.5.0
        with:
            ota-preview-release-tag-prefix: ota
            wait-for-runs-timeout-minutes: 30
```

Complete caller workflows for whole apps, linted and checked against this
workflow's inputs in CI, live in [docs/examples/](../examples/README.md).
