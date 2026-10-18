# native-publish.yml

`workflow_call` reusable workflow: signed store publishing via `eas build
--local` (fleet compute, not EAS cloud compute) followed by `eas submit`.

A **plan** job runs first, on `control-runner-labels`: it expands the publish
targets (see [Targets](#targets)), resolves each target's `eas.json` build
profile env following `extends` (see [eas.json profile env](#easjson-profile-env)),
resolves the build number and marketing version (see
[Build number](#build-number-and-marketing-version)), and in `mode: auto` /
`ota-only` decides whether this release needs a store build at all (see
[Native or OTA](#native-or-ota-mode-and-the-store-build-record)). With the
defaults it only does the first three and always decides `native`, so the
publish jobs run as before.

Then one of each publish job per target: **ios-publish** (writes the App Store Connect API key to a temp
file, `eas build --local --platform ios`, uploads the `.ipa`, `eas submit`,
removes the key in `always()`) — **android-lint-gate** (optional, prebuilds
the Android project and runs `gradlew :app:lintVitalRelease` plus a
merged-manifest scan for Play-policy restricted permissions on a hosted
runner; takes the same `publish-env`/`EAS_EXTRA_ENV` env as the publish jobs
so its prebuild sees consumer variables like `APP_VARIANT`, and its own
`android-lint-gate-gradle-args` input so its lint pass can be scoped the same
way `build-android-app`'s `gradle-args` scopes a build, e.g. to a single ABI
to avoid an all-ABI lint OOMing D8; restores a Gradle cache before lint and
uploads the `lint-results-*` reports when it fails — see
[Android lint gate](#android-lint-gate-gradle-cache-and-reports)) —
**android-publish** (needs
`android-lint-gate`; `eas build --local --platform android`, verifies the
built `.aab` contains the required 64-bit ABI, uploads the artifact, writes
the Google service account key to `$RUNNER_TEMP` (or `google-key-path` if
set), `eas submit`, removes the key in `always()`). When a store build record
is kept, a **record** job writes it to the release after the submits. A final
**status** job aggregates every job into a single required check; a run that
decided `ota` passes it without building.

## Inputs

| Name                          | Required | Default                             | Description |
| -------------------------------- | -------- | -------------------------------------- | -------------- |
| `enable-ios`                      | no       | `true`                                  | Run the `ios-publish` job. |
| `enable-android`                  | no       | `false`                                 | Run the `android-lint-gate`/`android-publish` jobs. |
| `ios-runner-labels`                | no       | `["self-hosted","macOS","ARM64"]`         | JSON array of self-hosted runner labels for the iOS publish job. |
| `control-runner-labels` | no | `'["ubuntu-latest"]'` | JSON array of runner labels for the lightweight control jobs (detect/status/collect/validate-manifest/cancel-queued-runs), which need no self-hosted hardware. In this workflow also the `plan` and `record` jobs: they need `jq`, `gh` when the plan reads releases or the run API, and Node when it fingerprints (`mode: auto` / `ota-only`, `write-store-record`), all on `ubuntu-latest`. Set it when the org has no hosted runners, e.g. an ephemeral RunsOn label set; it is passed on to `expo-base-plan.yml` by the workflows that call it. |
| `runs-on-cache-bypass` | no | `false` | Opt-in. When a job lands on a RunsOn runner started with `extras=s3-cache`, whose cache proxy takes over the Actions results URL and breaks `actions/upload-artifact`/`download-artifact`, run a SHA-pinned `runs-on/action` first (via the [`runs-on-cache-bypass`](../../actions/runs-on-cache-bypass/README.md) action). A logged no-op on every other runner. |
| `android-runner-labels`            | no       | `["self-hosted","trf-linux-amd64-4x8"]`         | JSON array of self-hosted runner labels for the Android publish job. The default is the x86_64 Linux pool (4 vCPU / 8 GiB): the NDK `eas build --local` needs ships for x86_64 Linux and macOS only, never linux-aarch64, and the build needs no Mac. Proven there by suuudokuuu's `native-publish` Android job. |
| `lint-runner-labels`               | no       | `["ubuntu-latest"]`                       | JSON array of hosted runner labels for the `android-lint-gate` job. |
| `app-dir`                          | **yes**  | —                                        | App directory containing `app.json`/`eas.json` (and `android`/`ios` once prebuilt). |
| `node-version`                     | no       | `22`                                     | Node version for `actions/setup-node`. |
| `install-command`                  | no       | `yarn install --immutable`                | JS dependency install command. |
| `enable-corepack`                  | no       | `true`                                    | Run `corepack enable` before install. Skipped when the resolved package manager is `pnpm` (provisioned by `pnpm/action-setup`). |
| `package-manager`                  | no       | `''` (auto-detect)                        | Override the JS package manager (`yarn`, `pnpm`, `npm`). Empty auto-detects at the repo root: `devEngines.packageManager` / `packageManager` in `package.json` (needs `jq` on the runner), else exactly one root lockfile (`yarn.lock` / `pnpm-lock.yaml` / `package-lock.json` or `npm-shrinkwrap.json`); no match, an ambiguous match or an unsupported value fails the job. Drives pnpm provisioning and, in the jobs that configure one, `actions/setup-node`'s `cache:` — set `install-command` to match (e.g. `pnpm install --frozen-lockfile`). Resolving to `pnpm` also requires a pnpm version in `package.json`. See [Package manager](../../README.md#package-manager). |
| `build-command`                    | no       | `''`                                      | Optional workspace JS build command run at repo root before publishing. |
| `eas-cli-version`                  | no       | `20.5.1`                                  | Pinned `eas-cli` npm version invoked via `npx eas-cli@<version>`. |
| `build-profile`                    | no       | `production`                              | EAS build profile (`eas.json` `build.<profile>`) used for both platforms, and the default of a `targets` entry's `buildProfile`. |
| `submit-profile`                   | no       | `production`                              | EAS submit profile (`eas.json` `submit.<profile>`) used for both platforms, and the default of a `targets` entry's `submitProfile`. |
| `targets`                          | no       | `''`                                      | JSON array of publish targets replacing `enable-ios` / `enable-android` / `build-profile` / `submit-profile` when non-empty. See [Targets](#targets). |
| `mode`                             | no       | `native`                                  | `native` always builds and submits (today's behaviour). `auto` builds only when a target's native runtime changed since the last store build, else outputs `decision=ota`. `ota-only` never builds and fails when it would have to. See [Native or OTA](#native-or-ota-mode-and-the-store-build-record). |
| `release-tag`                      | no       | `''`                                      | Tag whose GitHub Release carries the store build record. Empty uses the triggering tag on a tag-triggered run. Required (directly or via the trigger) by `mode: auto` / `ota-only` and `write-store-record`. |
| `write-store-record`               | no       | `false`                                   | Write the store build record in `mode: native` too, to seed a baseline before switching to `auto`. |
| `build-number`                     | no       | `''`                                      | `''` exports nothing. `auto` exports `STORE_BUILD_NUMBER` = whole minutes since the Unix epoch at which the workflow run was created. A positive integer up to `2100000000` is exported as is. See [Build number](#build-number-and-marketing-version). |
| `marketing-version`                | no       | `auto`                                    | `auto` exports `STORE_MARKETING_VERSION` from a release tag shaped `[<prefix>@][v]X[.Y[.Z]]` and nothing otherwise; `tag` fails without such a tag; `none` exports nothing; any other value must be `X[.Y[.Z]]` and is exported as is. |
| `fingerprint-version`              | no       | `0.20.6`                                  | Pinned `@expo/fingerprint` version the plan job fingerprints targets with (only in `mode: auto` / `ota-only` or with `write-store-record`). |
| `plan-timeout-minutes`             | no       | `30`                                      | `plan` and `record` job timeout. |
| `ios-pre-submit-command`           | no       | `''`                                      | Optional consumer-owned command (e.g. a fastlane lane) run in `app-dir` before the iOS build, after the App Store Connect key is written. Receives the profile env and `EXPO_ASC_API_KEY_PATH` — see [Hook environment](#hook-environment). |
| `ios-post-submit-command`          | no       | `''`                                      | Optional consumer-owned command (e.g. fastlane metadata/screenshots) run in `app-dir` after `eas submit` succeeds. Receives `EXPO_ASC_API_KEY_PATH` — see [Hook environment](#hook-environment). |
| `android-pre-submit-command`       | no       | `''`                                      | Optional consumer-owned command run in `app-dir` before the Android build. Does **not** receive the Google key path: the key is written only after the build — see [Hook environment](#hook-environment). |
| `android-post-submit-command`      | no       | `''`                                      | Optional consumer-owned command run in `app-dir` after `eas submit` succeeds. Receives the Google key path as `GOOGLE_APPLICATION_CREDENTIALS` and `GOOGLE_SERVICE_ACCOUNT_KEY_PATH` — see [Hook environment](#hook-environment). |
| `android-lint-gate`                | no       | `true`                                    | Require the `android-lint-gate` job (Play policy manifest check + `lintVitalRelease`) to pass before `android-publish` runs. |
| `required-android-abi`             | no       | `arm64-v8a`                                | ABI that must be present in the built `.aab` (Google Play 64-bit requirement). Empty string disables the check. |
| `asc-key-path`                     | no       | `''`                                       | Optional path, relative to `app-dir`, the App Store Connect API key (`.p8`) is written to and removed from. Leave empty (default) to write the key under `$RUNNER_TEMP` instead, keeping it out of the `eas build --local` archive; set it only when `eas.json` requires the key at a specific `app-dir`-relative location. |
| `google-key-path`                  | no       | `''`                                       | Optional path, relative to `app-dir`, the Google Play service account key (`.json`) is written to and removed from. Leave empty (default) to write the key under `$RUNNER_TEMP` instead, keeping it out of the `eas build --local` archive; set it only when `eas.json` or fastlane requires the key at a specific `app-dir`-relative location. |
| `build-timeout-minutes`            | no       | `120`                                     | Publish job timeout (both platforms). |
| `lint-timeout-minutes`             | no       | `30`                                      | `android-lint-gate` job timeout. |
| `android-lint-gate-gradle-args`    | no       | `''`                                      | Extra whitespace-split arguments appended after `:app:lintVitalRelease` in the `android-lint-gate` job, e.g. `-PreactNativeArchitectures=arm64-v8a`. Not shell-quoted. |
| `android-lint-gate-gradle-cache`   | no       | `true`                                    | Restore/save the Gradle User Home (`caches` + `wrapper`) in the `android-lint-gate` job via `gradle/actions/setup-gradle` with `cache-provider: basic`. Saved only from default-branch runs, read-only elsewhere. `false` skips `setup-gradle` entirely. See [Android lint gate](#android-lint-gate-gradle-cache-and-reports). |
| `publish-env`                      | no       | `''`                                      | Newline-separated `KEY=VALUE` pairs of non-secret env appended to `$GITHUB_ENV` at the start of `ios-publish`, `android-lint-gate`, and `android-publish`, after the resolved `eas.json` profile env (overriding it outside `eas build`, with a warning when the values differ) and before `eas build`/`eas submit` (or, for `android-lint-gate`, `expo prebuild`) and the pre/post-submit-command hooks. Rejects (fails closed) any line without `=` or whose name does not match `^[A-Za-z_][A-Za-z0-9_]*$`. For secret values use the `EAS_EXTRA_ENV` secret instead — inputs are not masked in logs. |

## Outputs

| Name                | Description |
| ------------------- | ----------- |
| `decision`          | `native` when the run built and submitted, `ota` when every target's native runtime matches the baseline and nothing was built. Always `native` in `mode: native`. |
| `changed-targets`   | Comma-separated targets whose fingerprint differs from the baseline (every target when there is none). Empty in `mode: native`. |
| `baseline-tag`      | Release tag of the store build record compared against; empty when none. |
| `fingerprints`      | JSON object of target name to `@expo/fingerprint` hash: the runtime version an OTA for that target must carry under `runtimeVersion: {policy: "fingerprint"}`. Empty unless the plan fingerprinted. |
| `build-number`      | The exported `STORE_BUILD_NUMBER`, empty when none. |
| `marketing-version` | The exported `STORE_MARKETING_VERSION`, empty when none. |

## Targets

With `targets` empty (the default) the targets are `ios` (when `enable-ios`)
and `android` (when `enable-android`), both on `build-profile` /
`submit-profile`, and every artifact keeps its pre-`targets` name
(`ios-publish-build`, `android-publish-build`,
`android-lint-gate-reports-attempt-<n>`).

A non-empty `targets` replaces those four inputs with a matrix, typically
brand x platform:

```yaml
targets: >-
    [{"name":"acme-ios","platform":"ios","buildProfile":"acme","submitProfile":"acme"},
     {"name":"acme-android","platform":"android","buildProfile":"acme","submitProfile":"acme"},
     {"name":"globex-ios","platform":"ios","buildProfile":"globex","submitProfile":"globex"}]
```

| Key             | Required | Default                       | Description |
| --------------- | -------- | ----------------------------- | ----------- |
| `platform`      | **yes**  | —                             | `ios` or `android`. |
| `buildProfile`  | no       | `build-profile`               | `eas.json` `build.<profile>`; its env is resolved per target. |
| `submitProfile` | no       | `submit-profile`              | `eas.json` `submit.<profile>`. |
| `name`          | no       | `<buildProfile>-<platform>`   | `[A-Za-z0-9._-]+`, unique. Names the job, the artifacts (`ios-publish-build-<name>`, ...) and the record entry. |

Targets of one platform that are different apps (different bundle id or
package) must have distinct native fingerprints, or a native change visible to
one brand only can slip past the fingerprint. This workflow does not know each
target's `appId`, so run
[`assert-distinct-fingerprints.yml`](assert-distinct-fingerprints.md) once per
platform as a `needs:` of the publish job (its example shows exactly that).

Each target is its own `ios-publish` / `android-lint-gate` /
`android-publish` matrix job with `fail-fast: false`, so one brand failing
never cancels another brand's submit. A non-array, an empty array, an unknown
key, an unknown platform, or a duplicate name fails the plan job before
anything builds.

## eas.json profile env

EAS applies a build profile's `env` inside `eas build` only. Before this
workflow resolved it, `eas submit` and the hooks ran without it, so a caller
had to repeat it in `publish-env`, and when the two drifted, `eas submit`
evaluated a different app config than the build (a different bundle id or
brand).

The plan job resolves every target's `build.<buildProfile>.env` from
`<app-dir>/eas.json`, following `extends` the way EAS merges it (each
profile's env over its parent's, the child winning), and every publish and
lint-gate job appends it to `$GITHUB_ENV` first, so `eas build --local`,
`eas submit`, `expo prebuild` in the lint gate, and every hook see the same
variables. It fails closed on:

- a missing or non-object `eas.json`;
- an unknown profile, including one named by `extends` (the error names the
  profile extending it);
- an `extends` cycle (the error prints the chain, e.g. `a -> b -> a`);
- an env name not matching `^[A-Za-z_][A-Za-z0-9_]*$`, or a value that is not
  a single-line string.

`publish-env` keeps working and is applied after the profile env, so it still
overrides a variable for `eas submit` and the hooks; the job warns whenever it
does with a different value, because inside `eas build` EAS applies the
profile's value regardless and the two can again resolve different app
configs.

## Build number and marketing version

`build-number: auto` exports `STORE_BUILD_NUMBER` as
`floor(created_at / 60)`, the whole minutes since the Unix epoch at which the
workflow run was created, read from the Actions API
(`GET /repos/{owner}/{repo}/actions/runs/{run_id}`). The calling job must
grant `actions: read` on a private repository; the step fails closed when the
API cannot be read.

- **Why `created_at`, not `run_started_at`.** The `github` context exposes no
  run start time. The run API's `run_started_at` is the start of the *latest
  attempt* and moves on every re-run; `created_at` is the run's own creation
  time and is shared by every attempt. A re-run therefore reuses the same
  number, which is what you want after a failed build or submit (nothing was
  uploaded under it). After a successful upload, a "re-run all jobs" fails at
  submit on the duplicate build number instead of shipping the same commit
  twice; use "re-run failed jobs" to finish the rest of a partial run.
- **Range.** Minutes since the epoch are about 29.9 million in 2026 and reach
  Google Play's `versionCode` ceiling of 2,100,000,000 only in the year 5962,
  so the number fits for the life of any app. iOS `CFBundleVersion` accepts the
  plain integer. Both stores require it to increase, which it does as long as
  your previous builds used a smaller number; an app already above ~30 million
  (e.g. a `YYYYMMDDnn` scheme) must keep its own scheme and pass an explicit
  number instead.
- **Resolution.** Two runs created in the same minute get the same number; the
  workflow's concurrency group serializes runs per ref, but two refs released
  within a minute collide and the second submit is rejected.

`marketing-version: auto` (default) exports `STORE_MARKETING_VERSION` from the
release tag when it is shaped `[<prefix>@][v]X[.Y[.Z]]` (`v1.4.0` gives
`1.4.0`, `mobile@2.1` gives `2.1`), and nothing otherwise.

Neither variable does anything until `app.config` reads it — e.g.
`version: process.env.STORE_MARKETING_VERSION ?? '1.0.0'`,
`ios.buildNumber: process.env.STORE_BUILD_NUMBER`,
`android.versionCode: Number(process.env.STORE_BUILD_NUMBER)` — with
`eas.json` `cli.appVersionSource: local` so EAS does not replace them. Both
are exported to the publish jobs (build, submit, hooks) after `publish-env`.

## Native or OTA: `mode` and the store build record

`mode: native` (default) builds and submits every target, as before.

`mode: auto` and `mode: ota-only` first fingerprint every target with
`@expo/fingerprint` (`fingerprint-version`, the same tool and the same
`fingerprint.config.js` in `app-dir` that `native-fingerprint`,
`expo-fingerprint-guard.yml` and `expo-ota-preview.yml` use) under the env its
build gets: `EAS_BUILD_PROFILE`, the resolved profile env, `publish-env`, then
`STORE_BUILD_NUMBER` / `STORE_MARKETING_VERSION`. The `EAS_EXTRA_ENV` secret is
not part of it. They then compare each fingerprint with the one recorded for
that target in the **baseline**: among every non-draft release other than this
run's tag, the store build record with the latest `recordedAt` whose targets
include every current target (same name and platform).

| Mode       | No baseline | Every fingerprint equal  | Any fingerprint changed |
| ---------- | ----------- | ------------------------ | ----------------------- |
| `native`   | build       | build                    | build                   |
| `auto`     | build       | `decision=ota`, no build | build                   |
| `ota-only` | **fail**    | `decision=ota`, no build | **fail**                |

The decision is all-or-nothing: if any target changed, every target is built,
so the release's record always describes one consistent set of shipped
binaries. A step summary lists each target's shipped and current runtime.

**The OTA itself is the caller's.** This repository's only EAS-free OTA path,
`expo-ota-preview.yml`, publishes pull-request previews for development
builds; it is not a production update channel. So `decision=ota` builds
nothing and the caller publishes the update through whatever channel its
production app is configured for, gated on the output:

```yaml
jobs:
    publish:
        uses: rnw-community/mobile-ci/.github/workflows/native-publish.yml@<sha> # <tag>
        permissions:
            contents: write
            actions: read
        with:
            app-dir: apps/mobile
            enable-android: true
            mode: auto
            build-number: auto
        secrets: inherit
    ota:
        needs: publish
        if: needs.publish.outputs.decision == 'ota'
        runs-on: ubuntu-latest
        steps:
            - uses: actions/checkout@<sha> # <tag>
            - run: npx eas-cli update --channel production --non-interactive
```

**Correctness boundary.** The comparison is only as good as the fingerprint
is the runtime: use `runtimeVersion: {policy: "fingerprint"}`, and, with
`build-number: auto`, add `sourceSkips: ['ExpoConfigVersions']` to
`fingerprint.config.js`. Without that skip the per-run build number is part
of every fingerprint, so `auto` always builds and `ota-only` always fails —
the safe direction, but no OTA ever ships.

**The store build record.** In `mode: auto` / `ota-only`, or with
`write-store-record: true`, each publish job writes a marker after its
`eas submit` succeeds (before the post-submit hook, whose failure does not
un-ship a binary), and the `record` job merges the markers into
`store-record-<app-dir scope>.json` (e.g. `store-record-apps-mobile.json`, or
`store-record-root.json` for `.`) and uploads it to the release-tag's GitHub
Release, creating a release from the existing tag when there is none:

```json
{
  "schema": 1, "tag": "v1.4.0", "commit": "<sha>", "runId": "...", "runAttempt": "1",
  "recordedAt": "2026-10-18T09:42:10Z", "buildNumber": "29871930", "marketingVersion": "1.4.0",
  "targets": {"ios": {"platform": "ios", "buildProfile": "production", "submitProfile": "production", "fingerprint": "<hash>"}}
}
```

Only targets that submitted are recorded, so a run where one platform failed
writes a partial record that is never a baseline; re-running the failed job
merges into the record for the same commit. A published immutable release
accepts no new assets: run `native-publish` before publishing such a release,
or let the record job create it. A record that is not schema 1 fails the plan
job rather than being skipped. All of this needs a release tag: `mode: auto` /
`ota-only` without one fails the plan job, because an unrecorded store build
would leave a stale baseline that a later run could wrongly match.

## Hook environment

The four `*-pre-submit-command` / `*-post-submit-command` hooks run with
exactly this environment, and nothing more:

| Variable                          | iOS pre | iOS post | Android pre | Android post | Value |
| --------------------------------- | ------- | -------- | ----------- | ------------ | ----- |
| `EXPO_TOKEN`                      | yes     | yes      | yes         | yes          | The `EXPO_TOKEN` secret (job env). |
| profile env entries               | yes     | yes      | yes         | yes          | The target's `eas.json` build profile `env`, `extends` resolved. |
| `publish-env` entries             | yes     | yes      | yes         | yes          | Every `KEY=VALUE` line of the `publish-env` input. |
| `STORE_BUILD_NUMBER`, `STORE_MARKETING_VERSION` | yes | yes | yes     | yes          | When `build-number` / `marketing-version` resolved one. |
| `EAS_EXTRA_ENV` entries           | yes     | yes      | yes         | yes          | Every `KEY=VALUE` line of the `EAS_EXTRA_ENV` secret, masked. |
| `EXPO_ASC_API_KEY_PATH`           | yes     | yes      | —           | —            | Absolute path of the written App Store Connect API key (`asc-key-path`, or under `$RUNNER_TEMP`). |
| `GOOGLE_APPLICATION_CREDENTIALS`  | —       | —        | —           | yes          | Absolute path of the written Google Play service account key (`google-key-path`, or under `$RUNNER_TEMP`). |
| `GOOGLE_SERVICE_ACCOUNT_KEY_PATH` | —       | —        | —           | yes          | Same value as `GOOGLE_APPLICATION_CREDENTIALS`, e.g. for a fastlane `json_key_file(ENV["GOOGLE_SERVICE_ACCOUNT_KEY_PATH"])`. |

plus the runner's own variables (`GITHUB_*`, `RUNNER_*`, the `PATH` the Node
and package-manager setup steps built). The App Store Connect key is written
before the iOS pre-submit hook and removed in `always()` after the post-submit
hook. The Google key is written only after `eas build --local`, so that an
`app-dir`-relative `google-key-path` never enters the build archive; the
Android pre-submit hook therefore runs before it exists and gets no path.

Hooks see the target's resolved `eas.json` build profile `env` (see
[eas.json profile env](#easjson-profile-env)), so `expo config` or fastlane in
a hook resolves the same app config the build does. `ASC_KEY_ID` /
`ASC_ISSUER_ID` are exported to the EAS steps only; pass them through
`EAS_EXTRA_ENV` if a hook needs them.

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
| `EAS_EXTRA_ENV`                     | no       | Newline-separated `KEY=VALUE` pairs of secret env appended to `$GITHUB_ENV` at the start of `plan` (before its install and `build-command`, so a remote cache token reaches them; the per-target fingerprint unsets every `EAS_EXTRA_ENV` name, keeping it out of the recorded fingerprints as before), `ios-publish`, `android-lint-gate`, and `android-publish`. Parsed by [`apply-secret-env`](../../actions/apply-secret-env/README.md): fails closed on a malformed line without echoing it, masks each value (`::add-mask::`) before writing it to `$GITHUB_ENV` with a collision-proof delimiter, so it never appears unredacted in logs (empty values are not masked), and accepts `KEY<<DELIMITER` … `DELIMITER` for a multi-line value. Use this for secrets `eas build`/`eas submit`, the `android-lint-gate` prebuild, or a pre/post-submit-command hook need on the environment — e.g. `EXPO_APPLE_APP_SPECIFIC_PASSWORD`. |

\* `ASC_KEY_ID` and `ASC_ISSUER_ID` must accompany `ASC_API_KEY`: without them EAS cannot
resolve the key non-interactively and falls back to an interactive prompt that cannot be
answered in CI, so `ios-publish` fails closed when any of the three is missing.

\* `EXPO_TOKEN`, `ASC_API_KEY`, and `GOOGLE_SERVICE_ACCOUNT_JSON` are declared
optional at the `workflow_call` level (so a caller that only enables one
platform need not declare the other's secrets), but each enabled publish job
validates its own required secrets at the start of the job and fails fast
with a clear error if any are missing. Pass them via `secrets: inherit` or an
explicit `secrets:` block in the caller workflow.

## Android lint gate: Gradle cache and reports

**Gradle cache.** With `android-lint-gate-gradle-cache: true` (the default)
the gate runs `gradle/actions/setup-gradle` after `expo prebuild` and before
`gradlew :app:lintVitalRelease`. It uses `cache-provider: basic`, the MIT
provider that wraps `actions/cache`, rather than setup-gradle's default
`enhanced` provider, whose proprietary caching library is free for public
repositories but under "Free Preview" terms for private ones. The basic
provider:

- caches `~/.gradle/caches` and `~/.gradle/wrapper` as one entry keyed on a
  hash of every `**/*.gradle*`, `**/gradle-wrapper.properties`,
  `gradle/*.versions.toml` and `**/versions.properties` in the workspace —
  which is why the step sits after prebuild: `--clean` regenerates
  `android/`, and the key must hash its build files (and the native modules'
  `build.gradle` files under `node_modules`). No restore keys: a changed
  dependency starts from an empty cache and writes a fresh entry.
- writes only from a run on the repository's default branch; any other ref
  (a tag, a release branch) restores read-only. A store release cut from a
  tag therefore never writes the cache it reads.
- does nothing on a self-hosted runner whose `$GRADLE_USER_HOME/caches`
  already exists (setup-gradle never overwrites a pre-existing Gradle User
  Home, and the basic provider does not support `cache-overwrite-existing`);
  that runner's persistent home is already the cache.
- validates every `gradle-wrapper.jar` in the workspace against Gradle's
  published checksums (setup-gradle's `validate-wrappers` default) and fails
  the gate on an unknown jar.

The cache never reaches the shipped binary: `android-publish` builds with
`eas build --local` in its own job and does not restore it. Set
`android-lint-gate-gradle-cache: false` to run the gate exactly as before,
with no `setup-gradle` step.

**Lint reports.** When any gate step fails, the job uploads
`<app-dir>/android/**/build/reports/lint-results-*.html` and `.xml` as the
artifact `android-lint-gate-reports-attempt-<run attempt>` (14-day
retention; nothing is uploaded, and no error raised, when the failure came
before lint wrote a report).

## Permissions

With the defaults, `contents: read` is sufficient in the caller workflow and
this workflow writes nothing to the repository. Two opt-ins need more on the
calling job:

| Opt-in                                                   | Calling job grant |
| -------------------------------------------------------- | ----------------- |
| `build-number: auto` (private repository)                | `actions: read`   |
| `mode: auto` / `ota-only`, or `write-store-record: true` | `contents: write` |

The workflow declares no workflow-level `permissions:`: a called workflow's
job that asks for more than its caller grants fails the whole run at startup,
even when that job would be skipped, so pinning `plan` and `record` to the
write grant would break every caller that only grants `contents: read`. They
inherit the caller's grant instead, and every other job pins
`contents: read`.

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

### Local build output

Local EAS build output from stdout and stderr passes through a filter that
redacts long encoded payload tokens before they reach the job log. Diagnostic
text is retained. A failed build or output filter still fails the job; filtering
never turns a failed build into a published release.
