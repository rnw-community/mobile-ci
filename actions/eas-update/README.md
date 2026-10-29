# eas-update

Publishes an [EAS Update](https://docs.expo.dev/eas-update/introduction/) with
`eas update --json --non-interactive` and returns what a pull-request comment
or a release pipeline needs: the update and group ids, the runtime version, a
manifest URL and an `expo-dev-client` deep link, per platform.

- **Channel first.** With `branch` empty the update is published through the
  channel (`eas update --channel`), which eas-cli creates together with a
  same-name branch when it is missing. With `branch` set, the update goes to
  that branch; a missing channel is created and pointed at it afterwards, and
  an existing channel that serves a different branch fails the step before
  anything is published. `auto-create-channel: false` fails when the channel
  does not exist (or cannot be read).
- **Same app config as the build.** `eas-profile` applies the profile's `env`
  (`extends` resolved by [`eas-profile-env`](../eas-profile-env/README.md)),
  exports `EAS_BUILD_PROFILE`, and passes the profile's `environment` as
  `--environment` unless `environment` overrides it — so a multi-brand app
  publishes the brand's bundle, not the default one. `extra-env` adds masked
  secrets through [`apply-secret-env`](../apply-secret-env/README.md).
- **The runtime it was meant for.** Pass the runtime versions
  [`ota-runtime-version`](../ota-runtime-version/README.md) resolved as
  `ios-runtime-version` / `android-runtime-version`. Before publishing, the
  step resolves the runtime again under the exact env `eas update` will run
  with and fails, publishing nothing, when it differs — the update would be
  evaluated under a different app config than the build it targets. After
  publishing it checks the runtime eas-cli reports too: a server-side EAS
  environment variable can still move it, and that failure says to roll back.
- **Idempotent and stale-safe.** When the branch's latest update for every
  platform already carries this commit (`gitCommitHash`), nothing is
  published and the outputs describe that update (`published: false`,
  `skipped-reason: already-published`), so a re-run does not stack duplicates.
  On a `pull_request` event, a run whose pull request has since moved to a
  newer head publishes nothing (`skipped-reason: stale-head`) and sets no
  other output, so a late re-run can never replace the current preview; an
  unreadable head fails the step.
- **Pass-through.** `rollout-percentage` (`--rollout-percentage`),
  `private-key-path` (code signing, `--private-key-path`) and `input-dir`
  (`--skip-bundler --input-dir`, publishing an existing `expo export`).
- **Fails closed** on a missing token, an app config without
  `extra.eas.projectId`, a failing `eas update`, output that is not the JSON
  array eas-cli documents, a requested platform missing from it, and a runtime
  other than the expected one.

**Protect the token.** Run any job whose `EXPO_TOKEN` can publish to a
production channel in a [GitHub Environment](https://docs.github.com/actions/deployment/targeting-different-environments/using-environments-for-deployment)
with required reviewers or a branch policy, and keep a separate, narrower
token (or project) for pull-request previews.

The app's dependencies must be installed: eas-cli runs `expo export` and the
action reads `npx expo config` for the project id, `updates.url` and slug.

## Inputs

| Name                  | Required | Default  | Description |
| --------------------- | -------- | -------- | ----------- |
| `app-dir`             | no       | `'.'`    | App directory holding the Expo app config and `eas.json`. |
| `channel`             | **yes**  | —        | Channel the update must reach. `[A-Za-z0-9._/-]`, starting with a letter or digit. |
| `branch`              | no       | `''`     | Branch to publish to. Empty publishes through the channel to the branch it serves. |
| `platform`            | no       | `all`    | `all`, `ios` or `android`. |
| `message`             | no       | `''`     | Update message. Empty uses the commit's short SHA and subject. |
| `environment`         | no       | `''`     | EAS environment for `--environment`. Empty uses `eas-profile`'s `environment`, if any. |
| `eas-profile`         | no       | `''`     | `eas.json` build profile whose env and environment the update is evaluated under. |
| `extra-env`           | no       | `''`     | Newline-separated `KEY=VALUE` secret env, masked and exported first. |
| `eas-cli-version`     | no       | `20.5.1` | Pinned eas-cli npm version. |
| `auto-create-channel` | no       | `'true'` | `false` fails when the channel does not exist. |
| `scheme`              | no       | `''`     | Development build URL scheme for the deep links. Empty uses `exp+<slug>`, which `expo-dev-client` registers. |
| `ios-runtime-version` / `android-runtime-version` | no | `''` | Expected runtime versions; the step fails when eas-cli publishes another. |
| `rollout-percentage`  | no       | `''`     | Publish as a rollout to 1–100% of the channel's users. |
| `private-key-path`    | no       | `''`     | Code-signing private key, relative to `app-dir`. |
| `input-dir`           | no       | `''`     | Existing `expo export` output, relative to `app-dir`; publishes it without bundling again. |
| `skip-if-published`   | no       | `'true'` | Skip when the branch's latest update already carries this commit. |
| `skip-stale`          | no       | `'true'` | On `pull_request`, skip when the pull request's head moved on. |
| `github-token`        | no       | `github.token` | Token reading the pull request's current head (`pull-requests: read`). |
| `expo-token`          | no       | `''`     | Expo access token. Empty uses `EXPO_TOKEN` from the job env. |

## Outputs

| Name                                              | Description |
| ------------------------------------------------- | ----------- |
| `published`                                       | `true` when this run published; `false` when it skipped. |
| `skipped-reason`                                  | Empty when published; `already-published` (the outputs describe the existing update) or `stale-head` (nothing else is set). |
| `channel`                                         | The channel the update was published for. |
| `branch`                                          | The branch the update landed on. |
| `update-group-id`                                 | The update group, when every platform shares one. A fingerprint runtime differs per platform, and eas-cli then publishes one group per runtime: this is empty and the per-platform outputs carry the values. |
| `runtime-version`                                 | The runtime version, when every platform shares one. |
| `manifest-url` / `deep-link`                      | Manifest URL (`<updates.url>/group/<group>`) and `<scheme>://expo-development-client/?url=<encoded manifest URL>` of the shared group. |
| `ios-update-id` / `android-update-id`             | Update id per platform. |
| `ios-runtime-version` / `android-runtime-version` | Runtime version per platform. |
| `ios-manifest-url` / `android-manifest-url`       | Manifest URL per platform. |
| `ios-deep-link` / `android-deep-link`             | Deep link per platform. |
| `updates`                                         | The JSON array `eas update` printed. |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/eas-update@v4.7.0 # v4.7.0
  id: update
  with:
      app-dir: apps/mobile
      channel: pr-${{ github.event.pull_request.number }}
      eas-profile: preview
      expo-token: ${{ secrets.EXPO_TOKEN }}
- run: echo "Open $LINK in the development build"
  env:
      LINK: ${{ steps.update.outputs.ios-deep-link }}
```

`expo-ota-preview.yml` with `ota-backend: eas` wraps this action and posts the
links and QR codes into the pull request's sticky preview comment.
