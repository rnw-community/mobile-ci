# runs-on-cache-bypass

Opt-in guard for jobs that may land on a [RunsOn](https://runs-on.com) runner
started with `extras=s3-cache`. There the runner points the Actions results URL
at the RunsOn cache proxy, so `actions/upload-artifact` and
`actions/download-artifact` fail until [`runs-on/action`](https://github.com/runs-on/action)
has run in the job. This action runs a SHA-pinned `runs-on/action` once when
`enabled` is `true` and the runner is a RunsOn runner (detected by the
`ZCTIONS_RESULTS_URL` / `ZCTIONS_CACHE_URL` variables the RunsOn runner sets);
on any other runner it logs a notice and does nothing, so one setting is safe
on a mixed fleet. Place it before the first step that touches artifacts.

| Input | Default | Description |
| --- | --- | --- |
| `enabled` | `false` | `true` to apply the bypass on a RunsOn runner. Any value other than `true`/`false` fails the step. |

| Output | Description |
| --- | --- |
| `applied` | `true` when `runs-on/action` ran in this job. |

```yaml
- uses: rnw-community/mobile-ci/actions/runs-on-cache-bypass@v4.4.1 # v4.4.1
  with:
      enabled: ${{ inputs.runs-on-cache-bypass }}
```

The reusable workflows expose this as their `runs-on-cache-bypass` input.
