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
- leaves the save to the calling workflow, as a plain `actions/cache/save`
  step guarded by `github.event_name != 'pull_request'` and a non-exact hit,
  with `timeout-minutes` and `continue-on-error: true`, so a save failure or
  stall never fails the job. The save cannot live in this action: the runner
  rejects `timeout-minutes` on a composite-action step at job set-up.

Key: `node-pm-v1-<os>-<arch>-<pm>-<sha256 of the lockfile>`; restore falls back
to the `node-pm-v1-<os>-<arch>-<pm>-` prefix. The lockfile must exist (fail
closed). The package manager must already be on `PATH` (run `pnpm/action-setup`
and `corepack enable` first).

Call it before installing; the calling workflow saves after installing (see
[Example](#example)).

## Inputs

| Name                   | Required | Default | Description                                                                |
| ---------------------- | -------- | ------- | -------------------------------------------------------------------------- |
| `package-manager`      | yes      |         | `npm`, `yarn` or `pnpm`.                                                   |
| `working-directory`    | no       | `.`     | Directory holding the lockfile.                                            |

## Outputs

| Name        | Description                                  |
| ----------- | -------------------------------------------- |
| `cache-hit` | `true` when an exact-key entry was restored. |
| `cache-key` | The computed cache key.                      |
| `path`      | The resolved store path.                     |

## Example

```yaml
- uses: actions/setup-node@... # no `cache:`
- name: Restore package manager cache
  id: pm-cache
  uses: rnw-community/mobile-ci/actions/node-pm-cache@v4.3.1 # v4.3.1
  with:
      package-manager: pnpm
- run: pnpm install --frozen-lockfile
- name: Save package manager cache
  if: github.event_name != 'pull_request' && steps.pm-cache.outputs.cache-hit != 'true'
  uses: actions/cache/save@0057852bfaa89a56745cba8c7296529d2fc39830 # v4.3.0
  timeout-minutes: 10
  continue-on-error: true
  with:
      path: ${{ steps.pm-cache.outputs.path }}
      key: ${{ steps.pm-cache.outputs.cache-key }}
```
