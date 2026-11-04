# rerun-infra-failures

Re-runs a failed workflow run's failed jobs **once** when every failure is
infrastructure, and never otherwise. Each failed job is classified from its
check-run annotations by the same rules as
[`scripts/ci-metrics.py`](../../scripts/ci-metrics.py), so the retry and the
weekly report agree on what counts as infra:

- **Infra:** a timeout, or a job whose failure annotations name a lost runner, an action's own `Infrastructure failure:` error (e.g. `run-maestro-android` losing its emulator, or `e2e-suite` on a run with no report, no test executed or a run error), `Exec format error`, a job not started or not acquired, a shutdown signal, a full disk, network errors (a `git fetch` cut off mid-pack included), an unresolvable action, or exit codes 127, 137 or 143, and nothing else except the runner's bare `Process completed with exit code N.` line. Warnings and notices do not count.
- **Ignored:** roll-up jobs that report other jobs with an `::error::Required jobs did not succeed` annotation. A roll-up that only `echo`es its verdict leaves the bare exit-code line, so it reads as a test failure and blocks the retry.
- **Test:** everything else, including a failure with no annotation.

A single test failure means nothing is re-run, because GitHub's re-run of
failed jobs would retry it too. Composite action; needs `python3` on the runner.

A job past its `timeout-minutes` concludes `cancelled`, not `timed_out`, and its
run concludes `cancelled` too. So the action also reads `cancelled` runs, counting
a `cancelled` job only when it carries `exceeded the maximum execution time`, and
classifying it by the rules above. A run with no such job was cancelled by a user
or a concurrency group: `nothing-failed`, whatever else failed in it. Have the
`workflow_run` job run for `cancelled` too, or a timed-out run never reaches the
action.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `run-id` | required | Workflow run to inspect, e.g. `${{ github.event.workflow_run.id }}`. |
| `repository` | `${{ github.repository }}` | `owner/name` of the run. |
| `max-attempts` | `1` | Automatic retries per run; a run whose attempt is above this is left alone. |
| `dry-run` | `false` | `true` classifies and reports without re-running. |
| `github-token` | `${{ github.token }}` | Needs `actions: write` and `checks: read`. |

## Outputs

| Output | Description |
| --- | --- |
| `decision` | `rerun`, `test-failure`, `retries-exhausted`, `unclassified`, `nothing-failed` or `not-finished`. |
| `infra-jobs` | Failed jobs classified as infrastructure. |
| `test-jobs` | Failed jobs classified as test failures. |

```yaml
# .github/workflows/retry-infra.yml
name: Retry infra failures
on:
    workflow_run:
        workflows: [Pull Request, Mobile E2E]
        types: [completed]
permissions:
    contents: read
jobs:
    retry:
        if: contains(fromJSON('["failure", "timed_out", "cancelled"]'), github.event.workflow_run.conclusion)
        runs-on: [self-hosted, trf-linux-amd64-2x4]
        timeout-minutes: 10
        permissions:
            actions: write
            checks: read
        steps:
            - uses: rnw-community/mobile-ci/actions/rerun-infra-failures@v4.10.1 # v4.10.1
              with:
                  run-id: ${{ github.event.workflow_run.id }}
```

The job checks out nothing and runs no code from the triggering run. It only
reads that run through the API and asks GitHub to re-run it.
