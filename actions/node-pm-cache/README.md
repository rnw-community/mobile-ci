# node-pm-cache

Caches the package manager's download store (`pnpm store path`,
`yarn cache dir` / `yarn config get cacheFolder` on Yarn 2+,
`npm config get cache`) in place of `actions/setup-node`'s `cache:` option.

Why not `setup-node`'s cache: its save runs in a post step on every event. A
post step cannot carry a `timeout-minutes`, so a stalled upload turned a
finished job into a cancelled one (a 1.1 GB pnpm store sent 0 bytes for 22
minutes). A pull-request save is also scoped to that PR's ref, so no other run
can restore it. This action instead:

- restores on every event (a pull request still restores the default branch's
  cache);
- saves only when `github.event_name != 'pull_request'` and the restore was not
  an exact hit, as an ordinary step with `timeout-minutes` and
  `continue-on-error: true`, so a save failure or stall never fails the job.

Key: `node-pm-v1-<os>-<arch>-<pm>-<sha256 of the lockfile>`; restore falls back
to the `node-pm-v1-<os>-<arch>-<pm>-` prefix. The lockfile must exist (fail
closed). The package manager must already be on `PATH` (run `pnpm/action-setup`
and `corepack enable` first).

Call it twice: `mode: restore` before installing, `mode: save` after.

## Inputs

| Name                   | Required | Default | Description                                                                |
| ---------------------- | -------- | ------- | -------------------------------------------------------------------------- |
| `mode`                 | yes      |         | `restore` or `save`.                                                       |
| `package-manager`      | yes      |         | `npm`, `yarn` or `pnpm`.                                                   |
| `working-directory`    | no       | `.`     | Directory holding the lockfile.                                            |
| `cache-hit`            | no       | `''`    | `save` mode: the restore call's `cache-hit`; an exact hit is not re-saved. |
| `save-timeout-minutes` | no       | `10`    | Bound for the save step; a stall past it is abandoned, not fatal.          |

## Outputs

| Name        | Description                                  |
| ----------- | -------------------------------------------- |
| `cache-hit` | `true` when an exact-key entry was restored. |
| `cache-key` | The computed cache key.                      |

## Example

```yaml
- uses: actions/setup-node@... # no `cache:`
- id: pm-cache
  uses: rnw-community/mobile-ci/actions/node-pm-cache@v4
  with:
      mode: restore
      package-manager: pnpm
- run: pnpm install --frozen-lockfile
- uses: rnw-community/mobile-ci/actions/node-pm-cache@v4
  with:
      mode: save
      package-manager: pnpm
      cache-hit: ${{ steps.pm-cache.outputs.cache-hit }}
```
