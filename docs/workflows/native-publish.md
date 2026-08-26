# native-publish.yml

`workflow_call` reusable workflow: signed store publishing via `eas build
--local` (fleet compute, not EAS cloud compute) followed by `eas submit`.

Three jobs: **ios-publish** (writes the App Store Connect API key to a temp
file, `eas build --local --platform ios`, uploads the `.ipa`, `eas submit`,
removes the key in `always()`) — **android-lint-gate** (optional, prebuilds
the Android project and runs `gradlew :app:lintVitalRelease` plus a
merged-manifest scan for Play-policy restricted permissions on a hosted
runner; takes the same `publish-env`/`EAS_EXTRA_ENV` env as the publish jobs
so its prebuild sees consumer variables like `APP_VARIANT`, and its own
`android-lint-gate-gradle-args` input so its lint pass can be scoped the same
way `build-android-app`'s `gradle-args` scopes a build, e.g. to a single ABI
to avoid an all-ABI lint OOMing D8) — **android-publish** (needs
`android-lint-gate`; `eas build --local --platform android`, verifies the
built `.aab` contains the required 64-bit ABI, uploads the artifact, writes
the Google service account key to `$RUNNER_TEMP` (or `google-key-path` if
set), `eas submit`, removes the key in `always()`). A final **status** job
aggregates the enabled jobs into a single required check.

## Inputs

| Name                          | Required | Default                             | Description |
| -------------------------------- | -------- | -------------------------------------- | -------------- |
| `enable-ios`                      | no       | `true`                                  | Run the `ios-publish` job. |
| `enable-android`                  | no       | `false`                                 | Run the `android-lint-gate`/`android-publish` jobs. |
| `ios-runner-labels`                | no       | `["self-hosted","macOS","ARM64"]`         | JSON array of self-hosted runner labels for the iOS publish job. |
| `android-runner-labels`            | no       | `["self-hosted","macOS","ARM64"]`         | JSON array of self-hosted runner labels for the Android publish job. Defaults to macOS because Google's Android NDK build tooling used by EAS local builds is x86_64-only on Linux. |
| `lint-runner-labels`               | no       | `["ubuntu-latest"]`                       | JSON array of hosted runner labels for the `android-lint-gate` job. |
| `app-dir`                          | **yes**  | —                                        | App directory containing `app.json`/`eas.json` (and `android`/`ios` once prebuilt). |
| `node-version`                     | no       | `22`                                     | Node version for `actions/setup-node`. |
| `install-command`                  | no       | `yarn install --immutable`                | JS dependency install command. |
| `enable-corepack`                  | no       | `true`                                    | Run `corepack enable` before install. Skipped when the resolved package manager is `pnpm` (provisioned by `pnpm/action-setup`). |
| `package-manager`                  | no       | `''` (auto-detect)                        | Override the JS package manager (`yarn`, `pnpm`, `npm`). Empty auto-detects at the repo root: `packageManager` in `package.json`, else exactly one root lockfile (`yarn.lock` / `pnpm-lock.yaml` / `package-lock.json`); no match or an ambiguous match fails the job. Drives `actions/setup-node`'s `cache:` and pnpm provisioning — set `install-command` to match (e.g. `pnpm install --frozen-lockfile`). See [Package manager](../../README.md#package-manager). |
| `build-command`                    | no       | `''`                                      | Optional workspace JS build command run at repo root before publishing. |
| `eas-cli-version`                  | no       | `20.5.1`                                  | Pinned `eas-cli` npm version invoked via `npx eas-cli@<version>`. |
| `build-profile`                    | no       | `production`                              | EAS build profile (`eas.json` `build.<profile>`) used for both platforms. |
| `submit-profile`                   | no       | `production`                              | EAS submit profile (`eas.json` `submit.<profile>`) used for both platforms. |
| `ios-pre-submit-command`           | no       | `''`                                      | Optional consumer-owned command (e.g. a fastlane lane) run in `app-dir` before the iOS build, with the job's env (including `EXPO_TOKEN`). |
| `ios-post-submit-command`          | no       | `''`                                      | Optional consumer-owned command (e.g. fastlane metadata/screenshots) run in `app-dir` after `eas submit` succeeds. |
| `android-pre-submit-command`       | no       | `''`                                      | Optional consumer-owned command run in `app-dir` before the Android build. |
| `android-post-submit-command`      | no       | `''`                                      | Optional consumer-owned command run in `app-dir` after `eas submit` succeeds. |
| `android-lint-gate`                | no       | `true`                                    | Require the `android-lint-gate` job (Play policy manifest check + `lintVitalRelease`) to pass before `android-publish` runs. |
| `required-android-abi`             | no       | `arm64-v8a`                                | ABI that must be present in the built `.aab` (Google Play 64-bit requirement). Empty string disables the check. |
| `asc-key-path`                     | no       | `''`                                       | Optional path, relative to `app-dir`, the App Store Connect API key (`.p8`) is written to and removed from. Leave empty (default) to write the key under `$RUNNER_TEMP` instead, keeping it out of the `eas build --local` archive; set it only when `eas.json` requires the key at a specific `app-dir`-relative location. |
| `google-key-path`                  | no       | `''`                                       | Optional path, relative to `app-dir`, the Google Play service account key (`.json`) is written to and removed from. Leave empty (default) to write the key under `$RUNNER_TEMP` instead, keeping it out of the `eas build --local` archive; set it only when `eas.json` or fastlane requires the key at a specific `app-dir`-relative location. |
| `build-timeout-minutes`            | no       | `120`                                     | Publish job timeout (both platforms). |
| `lint-timeout-minutes`             | no       | `30`                                      | `android-lint-gate` job timeout. |
| `android-lint-gate-gradle-args`    | no       | `''`                                      | Extra whitespace-split arguments appended after `:app:lintVitalRelease` in the `android-lint-gate` job, e.g. `-PreactNativeArchitectures=arm64-v8a`. Not shell-quoted. |
| `publish-env`                      | no       | `''`                                      | Newline-separated `KEY=VALUE` pairs of non-secret env appended to `$GITHUB_ENV` at the start of `ios-publish`, `android-lint-gate`, and `android-publish`, before `eas build`/`eas submit` (or, for `android-lint-gate`, `expo prebuild`) and the pre/post-submit-command hooks. Rejects (fails closed) any line without `=` or whose name does not match `^[A-Za-z_][A-Za-z0-9_]*$`. For secret values use the `EAS_EXTRA_ENV` secret instead — inputs are not masked in logs. |

## Secrets

> **Secret values must be the raw file contents, not base64.** Every key secret
> below is written to disk verbatim by these workflows — no decoding step. If a
> secret was previously stored base64-encoded for an action such as
> `MobileDevOps/secret-to-file-action` (which decodes on write), re-store it as
> the plain file contents or `eas submit`/fastlane will read a corrupt key.

| Name                            | Required | Description |
| ---------------------------------- | -------- | -------------- |
| `EXPO_TOKEN`                        | no*      | Expo access token, required by `ios-publish` and `android-publish`. |
| `ASC_API_KEY`                       | no*      | App Store Connect API key contents (`.p8`), required by `ios-publish`. |
| `ASC_KEY_ID`                        | no*      | App Store Connect API key ID matching `ASC_API_KEY`, exported to the iOS build and submit steps as `EXPO_ASC_KEY_ID`. |
| `ASC_ISSUER_ID`                     | no*      | App Store Connect API key issuer ID matching `ASC_API_KEY`, exported as `EXPO_ASC_ISSUER_ID`. |
| `GOOGLE_SERVICE_ACCOUNT_JSON`       | no*      | Google Play service account key JSON contents, required by `android-publish`. Written to disk at the path resolved by the `google-key-path` input (or `$RUNNER_TEMP` if empty). |
| `EAS_EXTRA_ENV`                     | no       | Newline-separated `KEY=VALUE` pairs of secret env appended to `$GITHUB_ENV` at the start of `ios-publish`, `android-lint-gate`, and `android-publish`. Same fail-closed parser as `publish-env`, but each value is masked (`::add-mask::`) before being written to `$GITHUB_ENV`, so it never appears unredacted in logs (empty values are not masked). Use this for secrets `eas build`/`eas submit`, the `android-lint-gate` prebuild, or a pre/post-submit-command hook need on the environment — e.g. `EXPO_APPLE_APP_SPECIFIC_PASSWORD`. |

\* `ASC_KEY_ID` and `ASC_ISSUER_ID` must accompany `ASC_API_KEY`: without them EAS cannot
resolve the key non-interactively and falls back to an interactive prompt that cannot be
answered in CI, so `ios-publish` fails closed when any of the three is missing.

\* `EXPO_TOKEN`, `ASC_API_KEY`, and `GOOGLE_SERVICE_ACCOUNT_JSON` are declared
optional at the `workflow_call` level (so a caller that only enables one
platform need not declare the other's secrets), but each enabled publish job
validates its own required secrets at the start of the job and fails fast
with a clear error if any are missing. Pass them via `secrets: inherit` or an
explicit `secrets:` block in the caller workflow.

## Permissions

`contents: read` is sufficient in the caller workflow; this workflow does not
write to the repository (unlike `native-dev-release.yml`, it never creates a
release).

## Example

```yaml
# .github/workflows/native-publish.yml
name: Native publish
on:
    workflow_dispatch:
jobs:
    publish:
        uses: rnw-community/mobile-ci/.github/workflows/native-publish.yml@v1.7.0 # v1.7.0
        with:
            app-dir: apps/mobile
            enable-ios: true
            enable-android: true
        secrets: inherit
```

To thread a secret into the eas build/submit environment (e.g. an Apple
app-specific password), pass it through `EAS_EXTRA_ENV` rather than a plain
input:

```yaml
# .github/workflows/native-publish.yml
name: Native publish
on:
    workflow_dispatch:
jobs:
    publish:
        uses: rnw-community/mobile-ci/.github/workflows/native-publish.yml@v1.7.0 # v1.7.0
        with:
            app-dir: apps/mobile
            enable-ios: true
        secrets:
            EXPO_TOKEN: ${{ secrets.EXPO_TOKEN }}
            ASC_API_KEY: ${{ secrets.ASC_API_KEY }}
            ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
            ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
            EAS_EXTRA_ENV: EXPO_APPLE_APP_SPECIFIC_PASSWORD=${{ secrets.APPLE_PASSWORD }}
```
