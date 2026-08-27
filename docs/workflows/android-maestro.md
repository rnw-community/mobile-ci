# android-maestro.yml

`workflow_call` reusable workflow: Android Maestro e2e on self-hosted
runners, defaulting to the Redroid driver.

Four jobs: **detect** (turbo-affected gate + shard-index computation, hosted
`ubuntu-latest`) → **build** (one job per `targets` entry — native
fingerprint, native-app-cache restore, optional repack-on-hit, `gradlew
--no-daemon <gradle-task>` (default `assembleRelease`), artifact upload) →
**test** (one job per `targets` ×
`shard-count` — download the built `.apk`, boot Redroid or an AVD emulator
per `android-driver`, run a Maestro flow shard) → **status** (aggregates
detect/build/test into a single required check). `build` and `test` default
to a self-hosted `linux-tiered`/`linux-xl` pool; `detect` and `status` always
run on `ubuntu-latest`.

The `status` job reports three distinct outcomes, in its log and in
`$GITHUB_STEP_SUMMARY`: **passed**, **failed** (naming the job and result
that broke the run, with a `::notice::` hint when a `cancelled` result
likely means a hit timeout), and **skipped** — every build/test leg skipped
because the target packages were untouched, reported explicitly as "zero
Maestro flows ran (not a pass)" rather than blending into a green check
silently.

## Inputs

| Name                        | Required | Default                                       | Description |
| ------------------------------ | -------- | ------------------------------------------------ | -------------- |
| `runner-labels`                 | no       | `["self-hosted","linux-tiered","linux-xl"]`        | JSON array of self-hosted runner labels for the build/test jobs. |
| `build-runner-labels`           | no       | `''`                                               | JSON array of self-hosted runner labels for the build job only. Falls back to `runner-labels` when empty; set this and `test-runner-labels` together to split build/test across separate runner pools. |
| `test-runner-labels`            | no       | `''`                                               | JSON array of self-hosted runner labels for the test job only. Falls back to `runner-labels` when empty. |
| `targets`                       | **yes**  | —                                                  | JSON array of build targets: `{name, appDir, appId, prebuildCommand}`. `prebuildCommand` may be an empty string. |
| `flows-dir`                     | **yes**  | —                                                  | Directory (relative to repo root) whose top-level files are the runnable Maestro flows by default. Subdirectories are not searched unless `flows-max-depth` is raised. |
| `flows-max-depth`               | no       | `1`                                                 | `find -maxdepth` under `flows-dir`. `0` means unbounded recursion. Default keeps subflows (invoked via `runFlow`, conventionally in subdirectories) out of the shard. |
| `flows-name-pattern`            | no       | `*.flow.yaml`                                      | Space-separated `find -name` globs (OR'd together) selecting runnable flows directly inside `flows-dir`. Keeps reusable subflows and capture-only flows in subdirectories out of the shard by default. |
| `flows-exclude-pattern`         | no       | `''`                                                | Optional `find ! -name` glob excluding matched flows by basename. |
| `shard-manifest-dir`            | no       | `''`                                                | Optional directory (relative to repo root) of hand-curated `shard-<index>.txt` files (one `flows-dir`-relative flow path per line) overriding the computed index-modulo split. Unset falls back to modulo entirely; once set, every shard-index this job can run must have its own file — a partial manifest fails closed. |
| `pre-run-flow`                  | no       | `''`                                               | Path to a single priming flow run once before each shard's flows, excluded from sharding. Its failure fails that shard immediately. |
| `flow-recovery-flow`            | no       | `''`                                               | Path to a single best-effort recovery flow run after a **failed** flow attempt — before the same flow's next retry attempt, and before the next flow starts — so one failure cannot strand the app in a state that cascades into the flows after it. Never run after a passing attempt, and not after a shard's last flow. Its own failure only logs a `::warning::` and never fails the shard. Like `pre-run-flow`, it is removed from the shard's discovered flow list, so it never also runs as a scenario of its own. Its duration is excluded from the per-flow timing table; a line below that table reports how many times it ran and how many of those runs failed. Passed to both `android-driver` options. |
| `pre-test-command`              | no       | `''`                                               | Optional consumer-owned shell command run once after the app is installed on the device/container and before any flow (including `pre-run-flow`) executes, e.g. seeding a fixture into the app's data container. Runs with `ANDROID_SERIAL`, `APP_ID`, and `APK_PATH` in its environment. Its failure fails that shard immediately. Passed to both `android-driver` options. |
| `pre-flow-command`              | no       | `''`                                               | Consumer-owned shell command run **before every flow attempt**, each retry included, after `pre-run-flow` and the warm-up. Never run before `pre-run-flow` or `flow-recovery-flow` themselves. Runs with `FLOW_PATH`, `FLOW_NAME`, `APP_ID`, `ANDROID_SERIAL` and `MAESTRO_FLOW_ENV_FILE` in its environment. Unlike the best-effort `flow-recovery-flow` it is a **precondition**: a non-zero exit fails that attempt without running the flow, consuming one of its `1 + flow-retries` attempts and triggering the recovery flow like any other failed attempt. Every `KEY=VALUE` line it appends to `$MAESTRO_FLOW_ENV_FILE` becomes an extra `-e KEY=VALUE` argument for that one flow's `maestro test` — see [Per-flow preconditions](#per-flow-preconditions). Passed to both `android-driver` options. |
| `maestro-env`                   | no       | `''`                                               | Newline-separated `KEY=VALUE` pairs, each passed as an additional `-e KEY=VALUE` argument to every `maestro test` invocation (`pre-run-flow` and shard flows alike). Rejects (fails closed) any line without `=` or whose name does not match `^[A-Za-z_][A-Za-z0-9_]*$`. Passed to both `android-driver` options. |
| `maestro-config`                | no       | `''`                                               | Path to the consumer's Maestro workspace config (`config.yaml`), passed as `--config` to every `maestro test` invocation. Maestro only auto-discovers a workspace `config.yaml` when it is pointed at a **directory**, and the actions below always pass individual flow files, so without this input a workspace config is silently ignored — e.g. `platform.ios.snapshotKeyHonorModalViews: false`, which an `@expo/ui` SwiftUI `.sheet()` modal needs before its React Native content appears in the XCUITest hierarchy at all. Relative paths resolve against the job's working directory. Fails closed when set to a path that is not a file. Passed to both `android-driver` options. |
| `flow-retries`                  | no       | `0`                                                | Non-negative retry budget per flow; each flow gets up to `1 + flow-retries` attempts. |
| `app-warm-seconds`              | no       | `20`                                               | Seconds the app is left running during a one-off warm-up (launch via `monkey`, settle, `am force-stop`) performed after install and before `pre-test-command` or any flow runs, so first-launch cold-start cost is not absorbed by the first flow's own timeout budget. `0` disables warming. Passed to both `android-driver` options. |
| `shard-count`                   | no       | `2`                                                | Number of test shards per target. |
| `cmdline-tools-version`         | no       | `12266719`                                         | `android-actions/setup-android` cmdline-tools-version — pin explicitly, do not trust upstream defaults (see `build-android-app` README). |
| `gradle-task`                   | no       | `assembleRelease`                                  | `gradlew` task to build, e.g. `:app:assembleRelease` to scope to one module (see `build-android-app` README). |
| `gradle-args`                   | no       | `''`                                                | Extra whitespace-split arguments appended after `gradle-task`, e.g. `-x lint -x lintVitalAnalyzeRelease` (see `build-android-app` README). |
| `cache-profile`                  | no       | `android-native-v1`                                | Cache-key prefix distinguishing this consumer/app. |
| `turbo-version`                 | no       | `2.10.8`                                           | Pinned turbo npm version used by the detect job. |
| `target-packages`               | no       | `''`                                               | Newline-separated package names gating this pipeline on `pull_request` events. |
| `expo-fingerprint-version`      | no       | `0.20.6`                                           | Pinned `@expo/fingerprint` npm version. |
| `maestro-version`               | no       | `2.8.0`                                            | Pinned Maestro CLI version. |
| `android-driver`                | no       | `redroid`                                          | `redroid` (default) or `avd`. Google publishes no `linux-aarch64` build of the Android emulator/NDK/cmake, so `avd` cannot boot on this workflow's default self-hosted `runner-labels`; `redroid` runs Android as a privileged container over `binder_linux` instead and needs none of those packages. Pick `avd` only when overriding `runner-labels` to a host with a working emulator (e.g. GitHub-hosted x86_64 runners, which carry KVM out of the box, or a self-hosted x86_64 Linux KVM host). Both drivers are fully supported self-hosted host shapes — see [self-hosted-runners.md#linux-x86_64-kvm-hosts-android-avd-driver](../self-hosted-runners.md#linux-x86_64-kvm-hosts-android-avd-driver) for the `avd` host's requirements. Stock `redroid` images ship no Google Play Services — see [self-hosted-runners.md#google-play-services-gms](../self-hosted-runners.md#google-play-services-gms) for GMS-dependent apps. |
| `emulator-api-level`            | no       | `34`                                               | Android emulator API level (`avd` driver only). |
| `emulator-target`               | no       | `google_apis`                                      | Android emulator system image target (`avd` driver only). |
| `emulator-arch`                 | no       | `x86_64`                                           | Android emulator system image architecture (`avd` driver only) — also used as the native-app-cache `arch` key segment for both drivers. |
| `emulator-profile`              | no       | `pixel_6`                                          | Android emulator hardware profile (`avd` driver only). |
| `redroid-image`                 | no       | `redroid/redroid:15.0.0_64only-latest`             | Redroid image tag, used on a `redroid-prewarm-manifest-path` miss. Verified against a `6.17` host kernel — older `13.x` tags are known to never finish boot on that kernel, and `14.x` images hard-lock the guest kernel version. |
| `redroid-memory`                | no       | `3g`                                               | Container memory limit (`docker --memory` / `--memory-swap`). |
| `redroid-cpus`                  | no       | `2`                                                 | Container CPU limit (`docker --cpus`). |
| `redroid-prewarm-manifest-path` | no       | `$HOME/.rnw-ci/android-emulator.json`              | Path to a host-side Redroid prewarm manifest (`{"image","dataDir"}`); see [self-hosted-runners.md](../self-hosted-runners.md). |
| `redroid-boot-timeout-seconds`  | no       | `600`                                              | Seconds to wait for `sys.boot_completed` before failing the shard. |
| `node-version`                  | no       | `22.x`                                             | Node version for `actions/setup-node`. |
| `install-command`               | no       | `yarn install --immutable`                         | JS dependency install command. |
| `enable-corepack`               | no       | `true`                                             | Run `corepack enable` before install. Skipped when the resolved package manager is `pnpm` (provisioned by `pnpm/action-setup`). |
| `package-manager`               | no       | `''` (auto-detect)                                 | Override the JS package manager (`yarn`, `pnpm`, `npm`). Empty auto-detects at the repo root: `devEngines.packageManager` / `packageManager` in `package.json` (needs `jq` on the runner), else exactly one root lockfile (`yarn.lock` / `pnpm-lock.yaml` / `package-lock.json` or `npm-shrinkwrap.json`); no match, an ambiguous match or an unsupported value fails the job. Drives pnpm provisioning and, in the jobs that configure one, `actions/setup-node`'s `cache:` — set `install-command` to match (e.g. `pnpm install --frozen-lockfile`). Resolving to `pnpm` also requires a pnpm version in `package.json`. See [Package manager](../../README.md#package-manager). |
| `build-command`                 | no       | `''`                                               | Optional workspace JS build command run at repo root before the native build. |
| `build-env`                     | no       | `''`                                               | Newline-separated `KEY=VALUE` pairs appended to `$GITHUB_ENV` at the start of the build job. Rejects (fails closed) any line without `=` or whose name does not match `^[A-Za-z_][A-Za-z0-9_]*$`. |
| `repack-on-hit`                 | no       | `false`                                            | On a native-app-cache hit, run `repack-app` to inject a freshly exported JS bundle into the cached shell instead of reusing it unchanged. Falls back to a full native build if the repack fails. |
| `repack-app-version`            | no       | `0.7.2`                                            | Pinned `@expo/repack-app` npm version, used only when `repack-on-hit` is true. |
| `android-build-tools-dir`       | no       | `''`                                               | Path to the Android SDK build-tools directory, used by `repack-app` (its `--android-build-tools-dir` and `aapt2` validation) when `repack-on-hit` is true. Leave empty to rely on an `aapt2` already on `PATH` (see `android-build-tools-version`, which populates `PATH` via `setup-android` on a cache hit when `repack-on-hit` is true). |
| `android-build-tools-version`   | no       | `35.0.0`                                           | Android build-tools version installed via `android-actions/setup-android` on a native-app-cache hit, used only when `repack-on-hit` is true. `build-android-app`'s own Gradle build (cache-miss path) installs whatever build-tools its `compileSdkVersion` resolves to, but that path never runs on a cache hit, so `repack-app`'s `aapt2` validation needs build-tools requested explicitly instead. |
| `build-timeout-minutes`         | no       | `60`                                               | Build job timeout. |
| `test-timeout-minutes`          | no       | `60`                                               | Test job timeout. |

No `secrets:` block — this workflow never touches a signing credential or an
Expo/EAS token.

## Between-flows recovery

A Maestro flow that fails leaves the app wherever the failure stranded it —
mid-modal, mid-game, on an unexpected screen. Without a reset, the next flow in
the shard starts from that state and fails for reasons that have nothing to do
with it, so one genuine failure cascades into a run of spurious ones.

`flow-recovery-flow` closes that gap. It runs after **every failed attempt**:
before the same flow's next retry attempt (when `flow-retries` allows one) and
before the shard moves on to the next flow. It never runs after a passing
attempt, and it is skipped after the shard's last flow, where nothing would
benefit from it. It is invoked exactly like `pre-run-flow` — same
`-e APP_ID=…`, `--debug-output`, `maestro-env`, and `maestro-config`
passthrough — so its debug artifacts land alongside the shard's.

Recovery is **best-effort**: if the recovery flow itself fails, the shard logs a
`::warning::` and carries on with the next flow. A recovery that cannot run must
never be the reason a shard goes red.

Point it at one flow that chains whatever your app needs to get back to a clean
state. suuudokuuu's proven sequence is a state reset followed by a deep-link
prime, which a single file expresses with `runFlow`:

```yaml
# e2e/flows/setup/recover-after-failure.flow.yaml
appId: ${APP_ID}
---
- runFlow: reset-app-state.flow.yaml
- runFlow: prime-deep-links.flow.yaml
```

```yaml
flow-recovery-flow: e2e/flows/setup/recover-after-failure.flow.yaml
```

The convention is still to keep it in a subdirectory of `flows-dir` alongside
your other non-scenario flows, but nothing depends on that: like `pre-run-flow`,
the recovery flow is filtered out of the shard's discovered flow list by file
identity, so it never also runs as an ordinary scenario — even at the top level
of `flows-dir`, or when `flows-max-depth` is raised past the subdirectory it
lives in.

The per-flow timing table in the step summary excludes time spent in recovery;
a line below the table reports how many times recovery ran and how many of
those runs failed.

## Per-flow preconditions

`pre-test-command` runs **once per shard**. `pre-flow-command` runs **before
every flow attempt** — each retry of the same flow included — so a consumer
whose flows each need their own fixture can seed it per flow instead of
driving an import through the app's UI.

It runs after `pre-run-flow` and the warm-up, and is never run before
`pre-run-flow` or `flow-recovery-flow` themselves. Unlike the best-effort
`flow-recovery-flow` it is a **precondition**: a non-zero exit fails that
attempt and the flow is not run for it. That failed attempt still consumes one
of the flow's `1 + flow-retries` attempts and still triggers the recovery
flow, so a transient seeding failure can recover on the next attempt instead
of taking the shard down.

The command is executed by its own `bash` under `set -euo pipefail`, with
these variables in its environment on top of everything the step already
exports:

| Variable                | Value                                                                   |
| ----------------------- | ----------------------------------------------------------------------- |
| `FLOW_PATH`             | The flow's path exactly as it is passed to `maestro test`.               |
| `FLOW_NAME`             | `basename` of `FLOW_PATH`.                                              |
| `APP_ID`                | The `app-id` input.                                                     |
| `ANDROID_SERIAL`        | adb serial of the device/container this shard drives.                   |
| `MAESTRO_FLOW_ENV_FILE` | A fresh, empty file created under `$RUNNER_TEMP` for this flow attempt. Its directory is deleted when the shard finishes. |

### Contributing per-flow `-e` pairs

Every `KEY=VALUE` line the command appends to `$MAESTRO_FLOW_ENV_FILE` becomes
an extra `-e KEY=VALUE` argument on **that one flow's** `maestro test`
invocation and on no other — the file is recreated empty before every
attempt. Empty lines and lines whose first character is `#` are ignored. Every
other line must contain `=` and have a name matching
`^[A-Za-z_][A-Za-z0-9_]*$`, or the step fails closed with an `::error::`
naming the offending line, exactly as `maestro-env` already does. Only the
**first** `=` splits a line, so values may themselves contain `=`. The format
is line-based, so a value cannot contain a newline; a trailing newline is
fine.

The per-flow arguments are appended **after** the `maestro-env` arguments. A
key present in both is therefore passed to `maestro test` twice, and Maestro's
own argument handling — not this action — decides which of the two wins; the
action neither deduplicates nor claims a precedence.

### Example: seeding a per-flow database fixture

```yaml
jobs:
    e2e:
        # @main until the release that ships pre-flow-command, then pin to that tag
        uses: rnw-community/mobile-ci/.github/workflows/android-maestro.yml@main
        with:
            targets: >-
                [{"name":"bare","appDir":"apps/mobile","appId":"com.example.app","prebuildCommand":""}]
            flows-dir: apps/mobile/e2e/flows
            pre-flow-command: |
                fixture=$(sed -n "s/.*FIXTURE_ROW_ID_MATCH: '\(.*\)\.db'.*/\1/p" "$FLOW_PATH" | tail -n 1)
                [ -n "$fixture" ] || exit 0
                adb -s "$ANDROID_SERIAL" shell am force-stop "$APP_ID"
                adb -s "$ANDROID_SERIAL" shell "run-as $APP_ID cp /sdcard/E2EFixtures/$fixture.db databases/app.db"
                echo "DATABASE_FIXTURE_SEEDED=true" >> "$MAESTRO_FLOW_ENV_FILE"
```

Each flow carrying a `FIXTURE_ROW_ID_MATCH: 'NN.db'` marker gets `NN.db`
copied over the app's live database and runs with
`DATABASE_FIXTURE_SEEDED=true`, so its import subflow short-circuits instead
of walking the file-picker UI. Flows without the marker exit the command early
and run exactly as they did before, with no extra `-e` argument.

## Maestro workspace config

Maestro only auto-discovers a workspace `config.yaml` when the CLI is pointed
at a **directory**. Every shard here discovers its flows itself and hands the
CLI one flow file per invocation, so a workspace `config.yaml` is never read
and nothing warns about it. `maestro-config` is the input that passes it
explicitly (`--config`) to every `maestro test` a shard runs — shard flows,
`pre-run-flow`, and `flow-recovery-flow` alike.

The case that motivated it: an `@expo/ui` SwiftUI `.sheet()` modal renders its
React Native content outside the app's main window, so the XCUITest hierarchy
Maestro snapshots never contains it and every selector inside the sheet times
out at its assertion budget. The fix is one workspace-config key —
`platform.ios.snapshotKeyHonorModalViews: false` — which is inert unless
`--config` actually reaches the CLI.

## Debug artifacts

When a shard fails, only the **failing** flows' `--debug-output` (UI hierarchy
dumps, per-flow screenshots — every attempt of the flow plus the
recovery-flow runs that followed it) reaches the uploaded artifact, one
gzipped tarball per flow at `maestro-debug/<flow>.tar.gz`. Bundles are staged
in flow-execution order for as long as they fit a 200MB *compressed* total;
one that would exceed the cap is dropped with a `::warning::` naming the flow
and its compressed size, and the smaller remaining bundles are still tried —
if none of them fit, a single `::warning::` reports the total and the artifact
holds only the final-state capture. Output the shard could not attribute to a
flow (Maestro keys its output by `maestro test` invocation timestamp, not by
flow name) is bundled last as `maestro-debug/unattributed.tar.gz` instead of
being discarded, so nothing diagnostic is lost silently. Maestro's hidden
`.maestro/tests/<timestamp>/` path is preserved *inside* each archive, so no
hidden entry is staged; the upload step still sets `include-hidden-files:
true` — `actions/upload-artifact` skips hidden files by default, which
previously shipped `final-screen.png` alone and dropped the hierarchy dumps
the failure message points you at.

## Permissions

`contents: read` is sufficient in the caller workflow; this workflow does not
write to the repository.

## Example

```yaml
# .github/workflows/android-maestro.yml
name: Android Maestro E2E
on:
    workflow_dispatch:
    pull_request:
    push:
        branches: [main]
concurrency:
    group: android-maestro-${{ github.ref }}
    cancel-in-progress: true
jobs:
    e2e:
        uses: rnw-community/mobile-ci/.github/workflows/android-maestro.yml@v1.7.0 # v1.7.0
        with:
            targets: >-
                [{"name":"bare","appDir":"apps/mobile","appId":"com.example.app","prebuildCommand":""}]
            flows-dir: apps/mobile/e2e/flows
            target-packages: |
                @myorg/mobile-app
```
