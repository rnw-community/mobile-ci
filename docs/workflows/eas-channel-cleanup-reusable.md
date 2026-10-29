# eas-channel-cleanup-reusable.yml

`workflow_call` reusable workflow that deletes EAS Update channels nobody will
publish to again — the EAS counterpart of
[`pr-closed-cleanup-reusable.yml`](pr-closed-cleanup-reusable.md) and
[`preview-sweep-reusable.yml`](preview-sweep-reusable.md). Wire it on
`pull_request: types: [closed]` for per-PR channels, on a `schedule:` for a
pattern sweep (release candidates, feature channels), or both.

**cleanup**: one job, one step, eas-cli at `eas-cli-version`:

1. **The closed pull request's channel.** `channel-template` with `{number}`
   replaced by `pr-number` (default: the triggering pull request) names it. The
   channel is deleted, then the branch of the same name — the one
   `eas update --channel` creates, never a branch another channel was pointed
   at. A pull request that never published (no channel, no branch) succeeds
   with nothing deleted. A run without a pull request number skips this part.
2. **The sweep.** With `sweep-pattern` set (a shell glob such as `rc-*`), every
   channel is listed (`eas channel:list`, every page, before anything is
   deleted) and each matching one whose newest activity — creation, last edit,
   or the latest update on any branch it serves — is older than
   `max-age-days` is deleted with its same-name branch.

**Never deleted**, whatever the template or pattern says:

- a name matching any glob in `protected-channels` (default `production` and
  `main`; the branch of the same name is protected by the same list);
- any `channel` an `eas.json` build profile sets — those are baked into store
  and development binaries, so deleting one strands every install. An
  `eas.json` that is not readable JSON fails the job instead of skipping this
  check;
- a channel EAS marks protected (`eas channel:protect`, newer eas-cli).

**Channels builds still subscribe to.** EAS refuses to delete a channel that
builds subscribe to (a pull request's cloud builds, say). By default such a
channel is kept and the job fails naming it; `delete-subscribed-builds: true`
deletes every build on the channel first (`eas build:list --channel`, then
`eas build:delete`, permanently), then the channel.

`dry-run: true` logs `Would delete channel <name> and branch <name>` and
deletes nothing. A channel list EAS cannot read fails the job before anything
is deleted; a channel that cannot be read or deleted for any reason other than
"not found" is kept, the remaining deletions still run, and the job fails at
the end. The step summary lists what was deleted.

eas-cli reads the project id from the app config in `app-dir`. An `app.json`
or a dependency-free `app.config.js` needs nothing installed; an app config
that requires packages needs `install-command`.

## Inputs

| Input                | Required | Default               | Description |
| -------------------- | -------- | --------------------- | ----------- |
| `app-dir`            | no       | `'.'`                 | App directory holding the app config and `eas.json`; eas-cli runs there. |
| `channel-template`   | no       | `pr-{number}`         | Closed pull request's channel, `{number}` replaced. Empty skips it. |
| `pr-number`          | no       | `''`                  | Pull request number; empty uses the triggering pull request's. |
| `sweep-pattern`      | no       | `''`                  | Shell glob of channels to sweep; empty sweeps nothing. |
| `max-age-days`       | no       | `30`                  | Days without activity after which a matching channel is swept. At least `1`. |
| `protected-channels` | no       | `production`, `main`  | Newline-separated globs of channel and branch names never deleted, on top of `eas.json`'s channels. Replacing it replaces the defaults — list them again if you still want them. |
| `delete-subscribed-builds` | no | `false`               | Delete the builds that subscribe to a channel so the channel can be deleted. Permanent. |
| `dry-run`            | no       | `false`               | Log what would be deleted and delete nothing. |
| `eas-cli-version`    | no       | `20.5.1`              | Pinned eas-cli npm version. |
| `install-command`    | no       | `''`                  | Command run at the repository root first, for an app config that requires packages. |
| `node-version`       | no       | `22`                  | Node version. |
| `runner-labels`      | no       | `'["ubuntu-latest"]'` | JSON array of runner labels. |
| `timeout-minutes`    | no       | `15`                  | Job timeout. |

## Secrets

| Secret       | Required | Description |
| ------------ | -------- | ----------- |
| `EXPO_TOKEN` | **yes**  | Expo access token allowed to delete the project's channels and branches. The job fails before eas-cli runs without it. A job that calls a reusable workflow cannot name a GitHub Environment, so this secret comes from the repository or organisation: keep production channels in `protected-channels` (and in `eas.json` profiles, which are never deleted), and keep the production-capable token for jobs that run in an Environment. |

## Permissions

`contents: read` (checkout). The calling job grants nothing more.

Each call runs in its own concurrency group per app, channel template, pull
request and sweep pattern, so several cleanups in one run (a matrix over
channels, a PR cleanup next to a sweep) never cancel each other.

**Why not a `pr-closed-cleanup-reusable.yml` input.** That workflow needs no
secret and runs no Node; folding EAS deletion into it would make every
consumer of it pass `EXPO_TOKEN` to a job that today holds only
`GITHUB_TOKEN`. Wire this workflow as a second job of the same
`pull_request: closed` caller instead (see the example).

## Examples

### Minimal

Delete a closed pull request's `pr-<number>` channel and branch:

```yaml
on:
    pull_request:
        types: [closed]
jobs:
    cleanup:
        permissions:
            contents: read
        uses: rnw-community/mobile-ci/.github/workflows/eas-channel-cleanup-reusable.yml@v4.7.0 # v4.7.0
        with:
            app-dir: apps/mobile
        secrets:
            EXPO_TOKEN: ${{ secrets.EXPO_TOKEN }}
```

### Full

```yaml
# .github/workflows/eas-channel-cleanup.yml
name: eas-channel-cleanup
on:
    pull_request:
        types: [closed]
    schedule:
        - cron: '0 3 * * 0'
    workflow_dispatch:
permissions:
    contents: read
jobs:
    cleanup:
        if: github.event_name == 'pull_request'
        uses: rnw-community/mobile-ci/.github/workflows/eas-channel-cleanup-reusable.yml@v4.7.0 # v4.7.0
        with:
            app-dir: apps/mobile
            channel-template: myapp-pr-{number}
            protected-channels: |
                production
                main
                *-production
            install-command: corepack enable && pnpm install --frozen-lockfile
        secrets:
            EXPO_TOKEN: ${{ secrets.EXPO_TOKEN }}
    sweep:
        if: github.event_name != 'pull_request'
        uses: rnw-community/mobile-ci/.github/workflows/eas-channel-cleanup-reusable.yml@v4.7.0 # v4.7.0
        with:
            app-dir: apps/mobile
            channel-template: ''
            sweep-pattern: myapp-rc-*
            protected-channels: |
                production
                main
                *-production
            install-command: corepack enable && pnpm install --frozen-lockfile
        secrets:
            EXPO_TOKEN: ${{ secrets.EXPO_TOKEN }}
```

The sweep is its own job rather than a `sweep-pattern` expression: in
`${{ github.event_name == 'pull_request' && '' || 'rc-*' }}` the empty string
is falsy, so a pull-request close would sweep too.

Run once with `dry-run: true` and read the log before letting it delete.

Complete caller workflows for whole apps, linted and checked against this
workflow's inputs in CI, live in [docs/examples/](../examples/README.md).
