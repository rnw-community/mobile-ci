# pr-closed-cleanup-reusable.yml

`workflow_call` reusable workflow: cancels queued/in-progress workflow runs
left behind on a just-closed PR's branch.

Single job, **cancel-queued-runs**: pages through `queued` then
`in_progress` runs on `github.event.pull_request.head.ref`, filters to runs
belonging to this PR number in this repository (excluding the currently
running cancellation run itself), and cancels each one via the GitHub API.
Intended for a serialized self-hosted fleet where a closed PR's queued/
running jobs would otherwise sit there starving the next PR's runs.

## Inputs

None. Everything this workflow needs — the PR's head branch, PR number, and
current run id — comes from `github.event.pull_request.*` and `github.run_id`
in the *calling* workflow's own event context, which is why the caller must
be triggered by `pull_request: types: [closed]`.

## Secrets

None.

## Permissions

The caller workflow (and this reusable workflow itself) needs
`permissions: actions: write` — cancelling a run requires it.

## Example

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
        uses: rnw-community/mobile-ci/.github/workflows/pr-closed-cleanup-reusable.yml@v1.6.2 # v1.6.2
```
