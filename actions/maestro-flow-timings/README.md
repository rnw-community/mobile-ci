# maestro-flow-timings

Keeps the per-flow Maestro durations that `ios-maestro.yml` and
`android-maestro.yml` balance shards on when `balance-shards: true`
([#267](https://github.com/rnw-community/mobile-ci/issues/267)). The workflows
call it in three places:

- **fetch** (planner): prints the newest unexpired `flow-timings.json`
  artifact named `artifact-name` that `branch` recorded, as one aggregate
  `{"version": 1, "targets": {"<target>": {"<flow>": seconds}}}`. It is read
  once per run and handed to every shard, so all shards balance on the same
  numbers.
- **select** (each shard): writes one target's timings as the
  `shard-timings-file` the `run-maestro-*` actions take.
- **record** (after the shards, default branch only): folds every per-shard
  `flow-timings.tsv` artifact under `records-dir` into the aggregate as an
  exponentially weighted average (α = 0.3) of passed flows, and uploads it as
  `artifact-name`.

No recorded history, or an unreadable one, never fails a run: fetch and
select warn and fall back to the index-modulo split. Record fails when no
shard left a record, rather than publishing timings nothing measured.

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `mode` | yes | — | `fetch`, `select` or `record`. |
| `artifact-name` | no | `''` | Name of the timings artifact (fetch, record), e.g. `maestro-flow-timings-ios`. |
| `branch` | no | `${{ github.event.repository.default_branch }}` | Branch whose recorded timings fetch reads. |
| `repository` | no | `${{ github.repository }}` | `owner/name` of the repository whose artifacts fetch reads. |
| `github-token` | no | `${{ github.token }}` | Token with `actions: read` on the repository (fetch). |
| `timings` | no | `''` | Aggregate timings JSON that fetch printed (select, record). |
| `target` | no | `''` | Target whose timings select writes. |
| `records-dir` | no | `''` | Directory of this run's downloaded per-shard timing artifacts, one subdirectory per artifact (record). |
| `artifact-prefix` | no | `''` | Name prefix, before the target name, of the per-shard timing artifacts, e.g. `maestro-flow-timings-ios-` (record). |
| `retention-days` | no | `'90'` | Retention of the recorded timings artifact (record). |

## Outputs

| Name | Description |
| --- | --- |
| `timings` | Aggregate timings JSON (fetch); `{"version": 1, "targets": {}}` when none is recorded. |
| `file` | Path of the target's `shard-timings-file` (select). |

## Example

```yaml
- id: timings
  uses: rnw-community/mobile-ci/actions/maestro-flow-timings@v4.7.0 # v4.7.0
  with:
      mode: fetch
      artifact-name: maestro-flow-timings-ios
```
