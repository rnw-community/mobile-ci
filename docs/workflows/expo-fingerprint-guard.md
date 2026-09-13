# expo-fingerprint-guard.yml

`workflow_call` reusable workflow: fails a pull request that silently changes
an Expo app's native runtime fingerprint.

An app on `runtimeVersion: { policy: 'fingerprint' }` only accepts an OTA
update whose runtime version equals the fingerprint baked into the installed
binary. Any pull request that touches a native input — a dependency bump, a
config plugin, a `patchedDependencies` entry, an `app.config.js` native key —
moves that fingerprint, and every `eas update` published after it merges
targets a runtime no shipped build has. Nothing fails; OTA delivery just
stops. This workflow turns that silent event into a required PR check.

Single job, **guard**:

1. Checks out `github.event.pull_request.head.sha` with full history.
2. Appends `app-env` to `$GITHUB_ENV`, so the variant the store actually
   ships (`APP_VARIANT=production`) is what gets hashed on both sides.
3. Installs dependencies and computes the head fingerprint per platform via
   [`native-fingerprint`](../../actions/native-fingerprint/README.md).
4. Adds a `git worktree` at the merge base of the PR's base and head, installs
   dependencies there, and computes the base fingerprint the same way.
5. Compares the hashes. Equal → pass. Different → prints the changed
   fingerprint sources from `@expo/fingerprint fingerprint:diff`, writes a
   summary table, and fails with the required action.

The `@expo/fingerprint` version, the package manager, and the install/build
commands are shared by both sides, so the two hashes are only ever compared
under identical tooling.

## Override label

A native change is legitimate — it just cannot ship as OTA. Label the pull
request with `override-label` (default `native-change-acknowledged`) and
re-run the job: the failure becomes a `::warning::` and the job passes. The
label is read live from the API on every run, so re-running an existing job
after labelling is enough; no new push is needed. When the API read fails,
the workflow falls back to the labels carried by the triggering event payload
and emits a warning saying so.

## Inputs

| Name                  | Required | Default                       | Description                                                                                  |
| ---------------------- | -------- | ----------------------------- | --------------------------------------------------------------------------------------------- |
| `working-directory`    | no       | `.`                           | Expo project root whose native surface is fingerprinted.                                      |
| `platforms`            | no       | `ios,android`                 | Comma-separated platforms to fingerprint and compare.                                         |
| `app-env`              | no       | `''`                          | Newline-separated `KEY=VALUE` pairs appended to `$GITHUB_ENV` before any fingerprint is computed. |
| `override-label`       | no       | `native-change-acknowledged`  | PR label that downgrades a fingerprint change to a warning.                                   |
| `base-ref`             | no       | `''`                          | Commit-ish to compare against; empty means the merge base of the PR's base and head.          |
| `fingerprint-version`  | no       | `0.20.6`                      | Pinned `@expo/fingerprint` npm version, used for both sides and for the diff.                 |
| `runner-labels`        | no       | `'["self-hosted","linux","x64"]'` | JSON array of runner labels for the guard job.                                            |
| `node-version`         | no       | `22`                          | Node version.                                                                                 |
| `install-command`      | no       | `''`                          | Install command run in both trees; empty derives it from the resolved package manager.        |
| `enable-corepack`      | no       | `true`                        | Run `corepack enable` (skipped when the resolved manager is pnpm).                            |
| `package-manager`      | no       | `''`                          | `yarn` / `pnpm` / `npm`; empty auto-detects from `package.json` and the single root lockfile.  |
| `build-command`        | no       | `''`                          | Optional workspace JS build run at the repository root in both trees before fingerprinting.   |
| `timeout-minutes`      | no       | `45`                          | Job timeout. Both trees are installed, so budget roughly two installs.                        |

## Outputs

| Name           | Description                                                                    |
| -------------- | ------------------------------------------------------------------------------- |
| `hash-ios`     | iOS fingerprint of the PR head; empty when `ios` is not in `platforms`.         |
| `hash-android` | Android fingerprint of the PR head; empty when `android` is not in `platforms`. |
| `changed`      | `'true'` when any compared platform fingerprint differs from the base.          |
| `acknowledged` | `'true'` when the override label was present on the pull request.               |

`hash-ios` / `hash-android` are the same values a publish workflow should
record alongside the binary it submits, so a later OTA can be matched to a
shipped runtime.

## Secrets

None. The job reads labels with the automatic `github.token`.

## Permissions

The calling job needs `contents: read` and `pull-requests: read` — the second
only so the override label can be read live rather than from the (possibly
stale) event payload.

## Requirements

The calling workflow must be triggered by `pull_request`; the job fails
closed on any other event, because there is no base to compare against.

## Release note

The workflow's internal `native-fingerprint` self-references pin to `v1.23.0`,
the release that first exposes that action's `file` output. Nothing earlier
than `v1.23.0` can run this workflow.

## Example

```yaml
jobs:
    fingerprint-guard:
        name: Native runtime fingerprint
        permissions:
            contents: read
            pull-requests: read
        uses: rnw-community/mobile-ci/.github/workflows/expo-fingerprint-guard.yml@v1.23.0 # v1.23.0
        with:
            working-directory: packages/app
            platforms: ios,android
            app-env: |
                APP_VARIANT=production
            install-command: pnpm install --frozen-lockfile
            package-manager: pnpm
            runner-labels: '["self-hosted","linux","x64"]'
```
