# android-maestro.yml

`workflow_call` reusable workflow: Android Maestro e2e on self-hosted
runners, defaulting to the `avd` driver on an x86_64 Linux KVM pool.

**detect** (turbo-affected gate, shard-index computation, and build-strategy
resolution, hosted `ubuntu-latest`) → **plan** (one leg per `targets` entry, on
the repack pool — compute the native key with
[`expo-native-key`](../../actions/expo-native-key), look up the base binary
published for it with [`expo-base-binary`](../../actions/expo-base-binary),
and, when one exists, produce this commit's APK from it with
[`expo-repack`](../../actions/expo-repack) — re-bundled, zipaligned and
re-signed — instead of running Gradle; the job's `native-targets` output is the
set of targets whose key had no base) → **build** (one job per *remaining*
target only — `gradlew --no-daemon <gradle-task>`
(default `assembleRelease`), artifact upload, and, on the default branch,
publishing the base it just built) → **test** (one job per `targets` ×
`shard-count` — download the `.apk` the plan or the build produced, boot
Redroid or an AVD emulator per `android-driver`, run a Maestro flow shard) →
**status** (aggregates every job into a single required check). `plan`, `build`
and `test` default to the self-hosted x86_64 Linux pool
(`["self-hosted","trf-linux-amd64-4x8"]` — 4 vCPU / 8 GiB, `/dev/kvm`), which
is the host shape the default `avd` driver needs; `detect` and `status` always
run on `ubuntu-latest`. Linux jobs
belong on a Linux node — see
[self-hosted-runners.md#which-pool-a-job-belongs-on](../self-hosted-runners.md#which-pool-a-job-belongs-on).

The normal outcome of a pull request is that **Gradle never runs**: the plan
job repacks a published base. See [Build strategy](#build-strategy) below and
[docs/repack.md](../repack.md).

The `status` job reports three distinct outcomes, in its log and in
`$GITHUB_STEP_SUMMARY`: **passed**, **failed** (naming the job and result
that broke the run, with a `::notice::` hint when a `cancelled` result
likely means a hit timeout), and **skipped** — every build/test leg skipped
because the target packages were untouched, reported explicitly as "zero
Maestro flows ran (not a pass)" rather than blending into a green check
silently. A `build` job that was *skipped* while the plan still listed targets
needing one is reported as a failure too — a skipped build is not a build.

## Android ABIs and the SDK cache

The native build compiles only the ABI the test device runs (`android-abis:
auto`) instead of every ABI the project declares, which on a stock React
Native project skips three of the four native compiles. The resolved ABIs are folded
into the native key, so **upgrading changes every Android native key**: re-run
the warm-up ([`seed-native-cache.yml`](seed-native-cache.md)) once on the
default branch right after bumping the pin, or every Android pull request
compiles natively until a default-branch run has published the new bases. The
warm-up's `android-abis` must resolve to the same ABIs as this workflow's —
`x86_64` by default on both; a `redroid` pipeline passes `arm64-v8a` to the
warm-up.

The `build` job restores the Android SDK (cmdline-tools, platform-tools and
the build-tools, platforms, NDK and CMake Gradle installs) from the Actions
cache before the build, and on a hit runs no `sdkmanager` and downloads nothing
from `dl.google.com`. It saves the SDK in a separate last step, only off
`pull_request`, with `continue-on-error` and a 10-minute `timeout-minutes`, so
a stalled upload never fails or holds the job. See
[`build-android-app`](../../actions/build-android-app#android-sdk-cache) for
the key.

## Migrating a Redroid caller (default change)

`runner-labels` and `android-driver` defaults changed together: they name one
host shape, and the pair is meaningless split apart. A caller that pins its own
`linux-aarch64` Redroid `runner-labels` (or `test-runner-labels`) but relied on
the old `redroid` driver default must now pass `android-driver: redroid`
explicitly. Nothing else changes for it, and nothing at all changes for a
caller that already passes `android-driver`. The mismatch is not silent: the
test job asserts the selected driver against the runner it landed on (x86_64 +
`/dev/kvm` for `avd`) and fails immediately with the override to add, instead
of letting an emulator that cannot boot there time out. This is a breaking
input-default change under
[CONTRIBUTING.md#versioning](../../CONTRIBUTING.md#versioning) and ships in a
major release.

## Inputs

| Name                        | Required | Default                                       | Description |
| ------------------------------ | -------- | ------------------------------------------------ | -------------- |
| `runner-labels`                 | no       | `["self-hosted","trf-linux-amd64-4x8"]`             | JSON array of self-hosted runner labels for the build/test jobs. The default is the x86_64 Linux KVM pool (4 vCPU / 8 GiB) the default `avd` driver needs; override it together with `android-driver: redroid` to run on a `linux-aarch64` binder/privileged-docker pool. |
| `control-runner-labels` | no | `'["ubuntu-latest"]'` | JSON array of runner labels for the lightweight control jobs (detect/status/collect/validate-manifest/cancel-queued-runs), which need no self-hosted hardware. Set it when the org has no hosted runners, e.g. an ephemeral RunsOn label set; it is passed on to `expo-base-plan.yml` by the workflows that call it. |
| `runs-on-cache-bypass` | no | `false` | Opt-in. When a job lands on a RunsOn runner started with `extras=s3-cache`, whose cache proxy takes over the Actions results URL and breaks `actions/upload-artifact`/`download-artifact`, run a SHA-pinned `runs-on/action` first (via the [`runs-on-cache-bypass`](../../actions/runs-on-cache-bypass/README.md) action). A logged no-op on every other runner. |
| `build-runner-labels`           | no       | `''`                                               | JSON array of self-hosted runner labels for the build job only. Falls back to `runner-labels` when empty; set this and `test-runner-labels` together to split build/test across separate runner pools. |
| `test-runner-labels`            | no       | `''`                                               | JSON array of self-hosted runner labels for the test job only. Falls back to `runner-labels` when empty. |
| `targets`                       | **yes**  | —                                                  | JSON array of build targets: `{name, appDir, appId, prebuildCommand}`. `prebuildCommand` may be an empty string. Optional per target: `flowsDir`, `tolerateTestFailures`, `buildStrategy` — see [Several packages](#several-packages-per-target-fields-and-call-scope). |
| `flows-dir`                     | no       | `''`                                               | Directory (relative to repo root) whose top-level files are the runnable Maestro flows by default. Subdirectories are not searched unless `flows-max-depth` is raised. The default of every target's `flowsDir`; may be empty only when every target names its own. |
| `flows-max-depth`               | no       | `1`                                                 | `find -maxdepth` under `flows-dir`. `0` means unbounded recursion. Default keeps subflows (invoked via `runFlow`, conventionally in subdirectories) out of the shard. |
| `flows-name-pattern`            | no       | `*.flow.yaml`                                      | Space-separated `find -name` globs (OR'd together) selecting runnable flows directly inside `flows-dir`. Keeps reusable subflows and capture-only flows in subdirectories out of the shard by default. |
| `flows-exclude-pattern`         | no       | `''`                                                | Optional `find ! -name` globs excluding matched flows by basename: one glob, or a comma- and/or newline-separated list (each entry trimmed, empty entries ignored; a glob containing a comma is not supported). |
| `shard-manifest-dir`            | no       | `''`                                                | Optional directory (relative to repo root) of hand-curated `shard-<index>.txt` files (one `flows-dir`-relative flow path per line) overriding the computed index-modulo split. Unset falls back to modulo entirely; once set, every shard-index this job can run must have its own file — a partial manifest fails closed. |
| `pre-run-flow`                  | no       | `''`                                               | Path to a single priming flow run once before each shard's flows, excluded from sharding. Its failure fails that shard immediately. |
| `flow-recovery-flow`            | no       | `''`                                               | Path to a single best-effort recovery flow run after a **failed** flow attempt — before the same flow's next retry attempt, and before the next flow starts — so one failure cannot strand the app in a state that cascades into the flows after it. Never run after a passing attempt, and not after a shard's last flow. Its own failure only logs a `::warning::` and never fails the shard. Like `pre-run-flow`, it is removed from the shard's discovered flow list, so it never also runs as a scenario of its own. Its duration is excluded from the per-flow timing table; a line below that table reports how many times it ran and how many of those runs failed. Passed to both `android-driver` options. |
| `pre-test-command`              | no       | `''`                                               | Optional consumer-owned shell command run once after the app is installed on the device/container and before any flow (including `pre-run-flow`) executes, e.g. seeding a fixture into the app's data container. Runs with `ANDROID_SERIAL`, `APP_ID`, and `APK_PATH` in its environment. Its failure fails that shard immediately. Passed to both `android-driver` options. |
| `pre-flow-command`              | no       | `''`                                               | Consumer-owned shell command run **before every flow attempt**, each retry included, after `pre-run-flow` and the warm-up. Never run before `pre-run-flow` or `flow-recovery-flow` themselves. Runs with `FLOW_PATH`, `FLOW_NAME`, `APP_ID`, `ANDROID_SERIAL` and `MAESTRO_FLOW_ENV_FILE` in its environment. Unlike the best-effort `flow-recovery-flow` it is a **precondition**: a non-zero exit fails that attempt without running the flow, consuming one of its `1 + flow-retries` attempts and triggering the recovery flow like any other failed attempt. Every `KEY=VALUE` line it appends to `$MAESTRO_FLOW_ENV_FILE` becomes an extra `-e KEY=VALUE` argument for that one flow's `maestro test` — see [Per-flow preconditions](#per-flow-preconditions). Passed to both `android-driver` options. |
| `maestro-env`                   | no       | `''`                                               | Newline-separated `KEY=VALUE` pairs, each passed as an additional `-e KEY=VALUE` argument to every `maestro test` invocation (`pre-run-flow` and shard flows alike). Rejects (fails closed) any line without `=` or whose name does not match `^[A-Za-z_][A-Za-z0-9_]*$`. Passed to both `android-driver` options. |
| `maestro-config`                | no       | `''`                                               | Path to the consumer's Maestro workspace config (`config.yaml`), passed as `--config` to every `maestro test` invocation. Maestro only auto-discovers a workspace `config.yaml` when it is pointed at a **directory**, and the actions below always pass individual flow files, so without this input a workspace config is silently ignored — e.g. `platform.ios.snapshotKeyHonorModalViews: false`, which an `@expo/ui` SwiftUI `.sheet()` modal needs before its React Native content appears in the XCUITest hierarchy at all. Relative paths resolve against the job's working directory. Fails closed when set to a path that is not a file. Its `includeTags`/`excludeTags` are honoured when the shard is planned — see [Tag selection](#tag-selection). Passed to both `android-driver` options. |
| `include-tags` | no | `''` | Comma-separated Maestro tags; only flows whose config section's `tags:` holds any of them run. Applied when the shard is planned (exclude wins), added to `maestro-config`'s `includeTags`, and passed to `maestro test`. Fails closed on an unparsable flow config section or an empty selection — see [Tag selection](#tag-selection). |
| `exclude-tags` | no | `''` | Comma-separated Maestro tags; flows holding any of them never run, even when `include-tags` selects them. Added to `maestro-config`'s `excludeTags` — see [Tag selection](#tag-selection). |
| `junit-report` | no | `true` | `true` writes each flow's final-attempt JUnit report (`maestro test --format junit`) to `junit/<flow>.xml` inside the shard's existing Maestro artifact; `false` writes none — see [JUnit reports](#junit-reports). |
| `artifact-retention-days` | no | `7` | Retention in days of each shard's Maestro artifact (debug output, final-state capture, JUnit reports), passed to the `run-maestro-*` action's `retention-days`. |
| `flow-retries`                  | no       | `0`                                                | Non-negative retry budget per flow; each flow gets up to `1 + flow-retries` attempts. |
| `infra-retries`                 | no       | `1`                                                | Per-flow retry budget, separate from `flow-retries`, spent only on a failed attempt that hit ActivityManager's `startProcessLocked ... with non-zero startSeq` race (no app process started after a `clearState` relaunch); retried with a `::warning::` even when `flow-retries` is `0`. `avd` driver only — see [run-maestro-android](../../actions/run-maestro-android/README.md#activitymanager-startseq-race). |
| `settle-before-flow`            | no       | `true`                                             | `true` force-stops the app and waits up to 5 s for its process to be gone before every flow attempt, which removes that race; app data is untouched. `avd` driver only. |
| `app-warm-seconds`              | no       | `20`                                               | Seconds the app is left running during a one-off warm-up (launch via `monkey`, settle, `am force-stop`) performed after install and before `pre-test-command` or any flow runs, so first-launch cold-start cost is not absorbed by the first flow's own timeout budget. `0` disables warming. Passed to both `android-driver` options. |
| `shard-count`                   | no       | `2`                                                | Number of test shards per target. |
| `cmdline-tools-version`         | no       | `12266719`                                         | `android-actions/setup-android` cmdline-tools-version — pin explicitly, do not trust upstream defaults (see `build-android-app` README). |
| `gradle-task`                   | no       | `assembleRelease`                                  | `gradlew` task to build, e.g. `:app:assembleRelease` to scope to one module (see `build-android-app` README). |
| `gradle-args`                   | no       | `''`                                                | Extra whitespace-split arguments appended after `gradle-task`, e.g. `-x lint -x lintVitalAnalyzeRelease` (see `build-android-app` README). |
| `turbo-version`                 | no       | `''`                                               | Exact turbo npm version used by the detect job. Empty resolves the repository's own turbo: `node_modules/turbo`, then the version locked in `pnpm-lock.yaml`, `package-lock.json`, `npm-shrinkwrap.json`, `yarn.lock` or `bun.lock`, then an exact root `package.json` version, else `2.10.8` with a notice. See the [`turbo-affected` README](../../actions/turbo-affected/README.md). |
| `target-packages`               | no       | `''`                                               | Newline-separated package names gating this pipeline on `pull_request` events: a pull request that affects none of them (per `turbo ls --affected`) skips the run. Empty derives them from the `name` in each `targets[].appDir`'s `package.json`. Fails closed: an unreadable or nameless `package.json`, a target package `turbo ls` does not list, or a `turbo` failure, fails the detect job, and a missing base SHA reports affected. Every non-`pull_request` event runs. |
| `exempt-paths`                  | no       | `''`                                               | Newline- or comma-separated pathspec globs relative to the repository root, e.g. `docs/**`, `**/*.md`, `apps/website/**`. A pull request whose every changed file (`base...HEAD`) matches one skips the run without turbo detection. One non-exempt file, an empty diff, or a diff that cannot be computed (logged as a `::warning::`) runs normal detection instead. See the [`turbo-affected` README](../../actions/turbo-affected/README.md). |
| `trigger-paths`                 | no       | `''`                                               | Newline- or comma-separated pathspec globs relative to the repository root, e.g. `.github/workflows/e2e.yml`, `e2e/**`. A pull request that changes a matching file (`base...HEAD`, renames counted at both paths) runs without turbo detection, which never attributes a file outside a workspace package to one. `**` runs every pull request, which is what an empty `target-packages` did before v3.3.0. Wins over `exempt-paths`; a diff that cannot be computed runs, with a `::warning::`. See the [`turbo-affected` README](../../actions/turbo-affected/README.md). |
| `force-label` | no | `''` | Pull request label that runs the pipeline whatever turbo reports: with it on the pull request, `detect` reports affected without turbo (even for an `exempt-paths`-only diff) and the status summary reads `passed (forced by the <label> label)`. Add `labeled` to the caller's `pull_request` `types` so adding the label starts a run (see [Forcing a run](#forcing-a-run)). Empty never forces. |
| `expo-fingerprint-version`      | no       | `0.20.6`                                           | Pinned `@expo/fingerprint` npm version. |
| `maestro-version`               | no       | `2.8.0`                                            | Pinned Maestro CLI version. |
| `android-driver`                | no       | `avd`                                              | `avd` (default), `redroid` or `device-cloud` (no device on the runner at all — see [Device Cloud driver](#device-cloud-driver)). `avd` boots Google's own emulator through this repo's `android-emulator` action and matches the default `runner-labels`: an x86_64 Linux pool with `/dev/kvm`, no privileged containers, no `binder_linux`. Pick `redroid` — together with `runner-labels` pointing at a `linux-aarch64` binder/privileged-docker pool — when the run needs Android on arm64 (e.g. an arm64-only APK); Google publishes no `linux-aarch64` emulator/NDK/cmake, so `avd` cannot boot there, and `redroid` conversely cannot run on the default pool. Both drivers are fully supported self-hosted host shapes — see [self-hosted-runners.md#linux-x86_64-kvm-hosts-android-avd-driver](../self-hosted-runners.md#linux-x86_64-kvm-hosts-android-avd-driver) for the `avd` host's requirements. Stock `redroid` images ship no Google Play Services — see [self-hosted-runners.md#google-play-services-gms](../self-hosted-runners.md#google-play-services-gms) for GMS-dependent apps. |
| `android-abis`                  | no       | `auto`                                             | Comma-separated ABIs the native build compiles, passed to Gradle as `-PreactNativeArchitectures`. `auto` follows the test device: `emulator-arch` (`x86_64`) for `android-driver: avd`, `arm64-v8a` for `redroid`; when `gradle-args` or `build-env` already pins `reactNativeArchitectures`, `auto` leaves it to that pin. An explicit value that contradicts such a pin fails the run. Empty compiles every ABI the project declares. Part of the native key — see [Android ABIs](#android-abis-and-the-sdk-cache). |
| `device-cloud-runner-labels`    | no       | `''`                                               | JSON array of runner labels for the test job when the driver is `device-cloud`. The job only uploads and waits, so any Linux runner with Node works. Empty falls back to `repack-runner-labels`. |
| `device-cloud-cli-version`      | no       | `5.7.1`                                            | Exact `@devicecloud.dev/dcd` npm version the `device-cloud` driver runs. |
| `device-cloud-android-api-level` | no      | `''`                                               | Device Cloud Android API level, e.g. `34` (`--android-api-level`). Empty uses Device Cloud's default. |
| `device-cloud-android-device`   | no       | `''`                                               | Device Cloud Android model, e.g. `pixel-7` (`--android-device`). Empty uses Device Cloud's default. |
| `emulator-api-level`            | no       | `34`                                               | Android emulator API level (`avd` driver only). |
| `emulator-target`               | no       | `google_apis`                                      | Android emulator system image target (`avd` driver only). |
| `emulator-arch`                 | no       | `x86_64`                                           | Android emulator system image architecture (`avd` driver only). |
| `emulator-profile`              | no       | `pixel_6`                                          | Android emulator hardware profile (`avd` driver only). |
| `emulator-ram-size`             | no       | `''`                                               | Emulator RAM in MB (`avd` driver only). Empty (the default) derives it from the test runner's cgroup memory limit — 256 MB per GiB of limit, rounded down to a 256 MB step and clamped to 1536–4096 — so the default `runner-labels` pool (a memory-bounded 8 GiB container) gets 2048, the value this input was hand-set to before; with no memory limit detected the hardware profile's default applies. The detected limit and the resolved value are in the shard's step summary. Set a value only with headroom measured on the pool the run lands on: a cgroup limit kills qemu instead of reporting an out-of-memory condition, and the job then fails as a lost adb connection partway through. The `avd` counterpart to `redroid-memory`. See [Emulator budget and host slots](#emulator-budget-and-host-slots). |
| `emulator-heap-size`            | no       | `''`                                               | Android VM heap size in MB for the emulated device (`avd` driver only). |
| `emulator-cores`                | no       | `''`                                               | Emulator CPU cores (`avd` driver only). Empty derives half the test runner's cgroup CPU quota, rounded down and clamped to 2–4 (2 on the default 4 vCPU pool); with no quota detected the profile default applies. |
| `emulator-slots-dir`            | no       | `''`                                               | Host directory of fleet-provisioned `slot-*` files capping concurrent emulators on the test runner's host across every job and repository (`avd` driver only). Each shard holds an exclusive `flock` on one slot from before boot until shutdown. Empty takes no slot. Set it only once the fleet bind-mounts the directory into every runner container: a missing directory, no `slot-*` files or an unwritable slot fails the shard. See [Emulator budget and host slots](#emulator-budget-and-host-slots). |
| `emulator-slot-timeout-minutes` | no       | `60`                                               | Minutes a shard waits for a free slot in `emulator-slots-dir` before failing; busy slots are logged every 60 s. The wait counts against `test-timeout-minutes`. |
| `redroid-image`                 | no       | `redroid/redroid:15.0.0_64only-latest`             | Redroid image tag, used on a `redroid-prewarm-manifest-path` miss. Verified against a `6.17` host kernel — older `13.x` tags are known to never finish boot on that kernel, and `14.x` images hard-lock the guest kernel version. |
| `redroid-memory`                | no       | `3g`                                               | Container memory limit (`docker --memory` / `--memory-swap`). |
| `redroid-cpus`                  | no       | `2`                                                 | Container CPU limit (`docker --cpus`). |
| `redroid-prewarm-manifest-path` | no       | `$HOME/.rnw-ci/android-emulator.json`              | Path to a host-side Redroid prewarm manifest (`{"image","dataDir"}`); see [self-hosted-runners.md](../self-hosted-runners.md). |
| `redroid-boot-timeout-seconds`  | no       | `600`                                              | Seconds to wait for `sys.boot_completed` before failing the shard. |
| `node-version`                  | no       | `22.x`                                             | Node version for `actions/setup-node`. |
| `install-command`               | no       | `yarn install --immutable`                         | JS dependency install command. |
| `enable-corepack`               | no       | `true`                                             | Run `corepack enable` before install. Skipped when the resolved package manager is `pnpm` (provisioned by `pnpm/action-setup`). |
| `package-manager`               | no       | `''` (auto-detect)                                 | Override the JS package manager (`yarn`, `pnpm`, `npm`). Empty auto-detects at the repo root: `devEngines.packageManager` / `packageManager` in `package.json` (needs `jq` on the runner), else exactly one root lockfile (`yarn.lock` / `pnpm-lock.yaml` / `package-lock.json` or `npm-shrinkwrap.json`); no match, an ambiguous match or an unsupported value fails the job. Drives pnpm provisioning and, in the jobs that configure one, the package-manager dependency cache (`node-pm-cache`: restored on every event, saved only off pull requests) — set `install-command` to match (e.g. `pnpm install --frozen-lockfile`). Resolving to `pnpm` also requires a pnpm version in `package.json`. See [Package manager](../../README.md#package-manager). |
| `build-command`                 | no       | `''`                                               | Optional workspace JS build command run at repo root before the native build. |
| `build-env`                     | no       | `''`                                               | Newline-separated `KEY=VALUE` pairs appended to `$GITHUB_ENV` at the start of the build job. Rejects (fails closed) any line without `=` or whose name does not match `^[A-Za-z_][A-Za-z0-9_]*$`. |
| `build-strategy`                | no       | `auto`                                             | How this pull request gets the APK its Maestro shards install. `auto` computes the native key, looks up the base binary published for it, and repacks that base with this commit's JavaScript; only a key with no published base runs Gradle — and when it does on the default branch, the base it builds is published for the next run. `repack` refuses to run Gradle at all: a missing base fails the build. `native` is the escape hatch and a regression — every pull request then rebuilds the APK, and that run publishes no base. See [Build strategy](#build-strategy) and [docs/repack.md](../repack.md). |
| `repack-runner-labels`          | no       | `["self-hosted","trf-linux-amd64-2x4"]`            | JSON array of self-hosted runner labels for the `plan`/repack job. The default is the 2 vCPU / 4 GiB x86_64 pool without `/dev/kvm`, so these jobs never queue on the KVM emulator lane ([#169](https://github.com/rnw-community/mobile-ci/issues/169)); keep it x86_64 (Google ships Android build-tools for x86_64 Linux only) and move to the 4x8 pool if bundling the JavaScript needs more than about 3 GiB. |
| `native-build-label`            | no       | `mobile: force native build`                       | Pull-request label forcing `build-strategy: native` for that one pull request. Set together with `build-strategy: repack` it fails closed rather than silently picking a winner. |
| `base-backend`                  | no       | `ghcr`                                             | Where base binaries live: `ghcr` (an immutable OCI artifact needing `packages: write` to publish and `packages: read` to fetch) or `artifact` (workflow artifacts, default-branch runs only, needing `actions: read`). See [`expo-base-binary`](../../actions/expo-base-binary). |
| `base-flavor`                   | no       | `e2e`                                              | Flavor segment of the base binary's address. |
| `fingerprint-config`            | no       | `fingerprint.config.js`                            | Path, relative to a target's `appDir`, of the `@expo/fingerprint` config whose ignore list is the correctness boundary of every repack. Its hash is part of the native key. See [docs/repack.md](../repack.md). |
| `fingerprint-env`               | no       | `''`                                               | Newline-separated `KEY=VALUE` pairs exported while the native key is computed, for an `app.config` that branches on env. Must be byte-identical to what the warm-up passes, or the two never agree on a key and every pull request rebuilds the APK. |
| `repack-env`                    | no       | `''`                                               | Newline-separated `KEY=VALUE` pairs exported for the re-bundle, so the consumer's `app.config` writes this build's API URL, version and build number into the repacked APK. |
| `expect-config`                 | no       | `''`                                               | Newline-separated `<dotted.path>=<value>` assertions the repacked APK's embedded `app.config` must satisfy exactly. Every value `repack-env` is expected to have rewritten belongs here: a config rewrite nobody checked is a repack nobody can trust. |
| `repack-app-version`            | no       | `0.7.2`                                            | Pinned `@expo/repack-app` npm version. |
| `repack-timeout-minutes`        | no       | `30`                                               | `plan`/repack job timeout. |
| `android-build-tools-dir`       | no       | `''`                                               | Path to the Android SDK build-tools directory holding `zipalign` and `apksigner`, used by the repack job. Leave empty to use the `android-build-tools-version` directory the repack job installs under the SDK (`$ANDROID_SDK_ROOT/build-tools/<version>`); a version the SDK does not hold fails the repack, naming the path. |
| `android-build-tools-version`   | no       | `35.0.0`                                           | Android build-tools version the repack job installs via `android-actions/setup-android`, for the `zipalign` and `apksigner` a repacked APK is aligned and signed with. The Gradle build installs whatever its `compileSdkVersion` resolves to; the repack job never runs Gradle, so it asks for build-tools explicitly. |
| `android-keystore-path`         | no       | `android/app/debug.keystore`                       | Keystore, relative to a target's `appDir`, the repacked APK is signed with. The default is the React Native debug keystore an `expo prebuild` app ships and Gradle signs its release build with — sign the repack with anything else and the emulator refuses to install it over the base. These are the published debug-keystore constants, not secrets; a release key belongs in [`native-publish.yml`](native-publish.md), never here. Empty leaves `@expo/repack-app`'s own default in place. |
| `android-keystore-password`     | no       | `android`                                          | Password of `android-keystore-path`. Ignored when that is empty. |
| `android-keystore-key-alias`    | no       | `androiddebugkey`                                  | Key alias inside `android-keystore-path`. Ignored when that is empty. |
| `android-keystore-key-password` | no       | `android`                                          | Key password inside `android-keystore-path`. Ignored when that is empty. |
| `build-timeout-minutes`         | no       | `60`                                               | Build job timeout. |
| `test-timeout-minutes`          | no       | `75`                                               | Test job timeout. |
| `tolerate-test-failures`        | no       | `false`                                            | `true` keeps the test job green when the Maestro run step fails, and reports the failure as a `::warning::` instead. For a time-boxed quarantine of a known-broken suite. The default of every target's `tolerateTestFailures`, which quarantines one target alone. |
| `call-scope`                    | no       | `''`                                               | Names this call's artifacts, plans, Redroid containers and concurrency groups, so several calls in one run (one per package, say) never share or cancel them. Calls that share a run must each set a distinct, non-empty value. `[A-Za-z0-9._]` with single `-` between them. Empty keeps today's names. See [Several packages](#several-packages-per-target-fields-and-call-scope). |

## Outputs

| Name | Description |
| ---- | ----------- |
| `result` | The `status` job's verdict: `passed`, `failed`, or `skipped` when no target package was affected. A skip is a green check, not a pass, so a notification job should not report it as one. |

Read it from a caller job that `needs:` this one. GitHub skips a dependent
job when its need fails, so a notification job must opt in with `if:
always()` (or `!cancelled()`) to see a `failed` result:

```yaml
    notify:
        needs: e2e
        if: always()
        runs-on: ubuntu-latest
        steps:
            - env:
                  RESULT: ${{ needs.e2e.outputs.result }}
              run: echo "android-maestro: $RESULT"
```

## Secrets

| Secret                | Required | Description |
| --------------------- | -------- | ----------- |
| `build-secrets-env`   | no       | Masked `KEY=VALUE` entries (`KEY<<DELIMITER` for a multi-line value) exported after `build-env` in the `plan`/repack leg (install, `build-command`, fingerprint, re-bundle) and the native `build` job. For what a real build needs but a log must never show: a remote turbo cache token, a Maps API key compiled into the base. Parsed by [`apply-secret-env`](../../actions/apply-secret-env/README.md). Only a SHA-256 digest of the entries enters the native key, never a value — so rotating a secret moves the key, and the warm-up ([`seed-native-cache.yml`](seed-native-cache.md)) must be passed the same secret or the two never agree on a key and every pull request takes a native build. |
| `device-cloud-api-key` | with the `device-cloud` driver | Device Cloud API key. Reaches only `run-maestro-device-cloud`, which hands it to the CLI as `DEVICE_CLOUD_API_KEY`, never on a command line. A `device-cloud` run without it fails before submitting. |
| `maestro-secrets-env` | no       | Masked `KEY=VALUE` entries, one line each, appended to `maestro-env` (so each becomes a Maestro `-e` argument) and exported to the test job's environment for `pre-test-command` and `pre-flow-command`. Every value is replaced with `***` in the uploaded Maestro artifacts (`maestro.log`, commands JSON, logcat) before upload; masking only covers the job log. For test-user passwords and the credentials a hook uses to prepare the backend under test. |

Every secret is optional; with none passed, every job behaves exactly as it did
without the `secrets:` block. Pass them explicitly — `secrets: inherit` would
hand every repository secret to a third-party workflow.

```yaml
jobs:
    e2e:
        uses: rnw-community/mobile-ci/.github/workflows/android-maestro.yml@v4.4.1 # v4.4.1
        with:
            targets: ...
            flows-dir: apps/mobile/e2e/flows
            maestro-env: |
                TEST_USER=e2e@example.com
        secrets:
            build-secrets-env: |
                TURBO_TOKEN=${{ secrets.TURBO_TOKEN }}
                MAPS_API_KEY=${{ secrets.MAPS_API_KEY }}
            maestro-secrets-env: |
                TEST_PASSWORD=${{ secrets.E2E_TEST_PASSWORD }}
```

This workflow never touches a release signing credential
or an Expo/EAS token. The `android-keystore-*` inputs default to the published
React Native **debug** keystore constants, which are not secrets; a release key
belongs in [`native-publish.yml`](native-publish.md). The workflow does need a
**token permission** the caller grants; see [Permissions](#permissions).

## Device Cloud driver

`android-driver: device-cloud` keeps the plan, build and repack half of this
workflow and replaces only the test leg. The test job runs on
`device-cloud-runner-labels` (default: the `repack-runner-labels` Linux pool).
It needs no simulator, KVM or binder there, and it skips the KVM/arch host check and every emulator or Redroid step. It then
runs [`run-maestro-device-cloud`](../../actions/run-maestro-device-cloud/README.md)
against the same `app-release.apk` the local driver would install. That action:

- selects flows exactly as the local driver does (`flows-dir`,
  `flows-max-depth`, `flows-name-pattern`, `flows-exclude-pattern`), then
  submits them once per target with the pinned `@devicecloud.dev/dcd`
  (`device-cloud-cli-version`);
- passes `include-tags` / `exclude-tags`, `maestro-config` (minus `flows:`,
  which it refuses), `maestro-env` merged with `maestro-secrets-env` as `-e`,
  `maestro-version`, and `flow-retries` as `--retry`;
- downloads the run's logs, screenshots and videos (and, with `junit-report`,
  its JUnit report) and uploads them under the same artifact name as a local
  shard (`maestro-<platform>-<target>-shard-0`), after redacting the Maestro
  secrets. So `status` and any reporting read the same artifact.

`android-abis: auto` cannot follow a device it never sees, so with
`device-cloud` it fails the `detect` job: set `android-abis` explicitly to the
ABIs Device Cloud's devices run, and pass `seed-native-cache.yml` the same
value so the warm-up publishes under the same native key.

Device Cloud runs the flows in parallel itself, so `shard-count` and
`shard-manifest-dir` do not fan the job out: there is one submission per
target, reported as shard 0.

It fails closed:

- A submission Device Cloud rejects (a bad key, an exhausted quota, an
  unsupported device or Maestro version) is a red check carrying the
  CLI's reason, never a skip.
- Anything but an explicit pass of at least one flow fails. This covers a
  failed flow, a run superseded by another, an empty result, or CLI output
  that is not JSON.
- The local-device hooks — `pre-run-flow`, `flow-recovery-flow`, `pre-test-command` and
  `pre-flow-command` — each act on a device this runner boots, so setting one
  with `device-cloud` fails the job rather than silently never running it.

```yaml
jobs:
    e2e:
        uses: rnw-community/mobile-ci/.github/workflows/android-maestro.yml@v4.4.1 # v4.4.1
        with:
            targets: ...
            flows-dir: apps/mobile/e2e/flows
            android-driver: device-cloud
        secrets:
            device-cloud-api-key: ${{ secrets.DEVICE_CLOUD_API_KEY }}
```

## Emulator budget and host slots

On the `avd` driver each test shard sizes its emulator from **its own
container**, not the host: `run-maestro-android` boots it through the
[`android-emulator`](../../actions/android-emulator/README.md) action, which
reads the cgroup memory limit
and CPU quota (cgroup v2, then v1) and, for an empty `emulator-ram-size` /
`emulator-cores`, derives 256 MB of guest RAM per GiB of limit (clamped
1536–4096) and half the CPU quota (clamped 2–4). On the default 4 vCPU / 8 GiB
pool that is 2048 MB and 2 cores — the same 2048 this workflow used to
hard-code — so a caller that set `emulator-ram-size: '2048'` only to fit that
pool can drop the override. An explicit value always wins. Each shard's step
summary shows the detected limits and the resolved values.

A host can still run more emulators than it has memory for when several
runner containers on it each boot one. `emulator-slots-dir` caps that host-wide:
the fleet provisions one `slot-*` file per emulator the host may run (see
[self-hosted-runners.md](../self-hosted-runners.md#linux-x86_64-kvm-hosts-android-avd-driver)),
and each shard holds a `flock` on one from before boot until shutdown, waiting
up to `emulator-slot-timeout-minutes` for a free one. Unlike a workflow
`concurrency` group, a waiting shard is never cancelled and the cap spans every
repository on the host. Leave it empty until the fleet provisions the
directory: set against a host without it, every shard fails closed.

Before it boots anything, `android-emulator` runs `emulator -accel-check` and
fails the shard when hardware acceleration is unavailable, rather than letting
the emulator fall back to software emulation and time out much later.

The shutdown step kills only the emulator processes this job started
(identified by its `RUNNER_TRACKING_ID`), so a failed or cancelled shard cannot
leave a qemu holding the host's memory, and a neighbouring job's emulator is
never touched.

The `plan`/repack job needs neither KVM nor an emulator — only Node, a JDK and
the Android build-tools. It runs on `repack-runner-labels`, which defaults to
the smaller non-KVM `["self-hosted","trf-linux-amd64-2x4"]` pool, so it stays
off the emulator lane. A fleet without that pool points it at any x86_64 Linux
pool with that toolchain:

```yaml
with:
    repack-runner-labels: '["self-hosted","my-linux-pool"]'
```

## Build strategy

A pull request should not rebuild the APK. Its native surface is almost always
identical to the default branch's, so the only thing that actually changed is
JavaScript — and swapping JavaScript into an already-built APK is minutes, not
a full Gradle build. Three actions state that:
[`expo-native-key`](../../actions/expo-native-key) computes the one key a base
is addressed by, [`expo-base-binary`](../../actions/expo-base-binary) fetches
or publishes the base under that key, and
[`expo-repack`](../../actions/expo-repack) turns the base into this commit's
APK — re-bundled, config-rewritten, asserted, zipaligned, re-signed with
`android-keystore-path` and verified with `apksigner`. The whole contract,
including what `fingerprint.config.js` must ignore and what it must not, is in
[docs/repack.md](../repack.md).

**`auto` (the default).** The `plan` job computes the target's native key and
asks for the base published under it.

- *First run on a new native surface (no base yet).* The lookup reports
  `found=false`, the target lands in the plan's `native-targets` output, and
  the `build` job runs Gradle exactly as v2 did. When that run is on the default branch, it then
  **publishes** the APK it built as the base for that key. The **next** run —
  every pull request on that same native surface — finds the base and repacks,
  running no Gradle at all. A `found=false` is the signal to build; a lookup
  that *cannot tell* (registry error, artifacts API failure) fails the job
  instead, because an unreadable store is not an absent base.
- *Every subsequent run.* The base is found, `expo-repack` re-bundles this
  commit's JavaScript into it, the assertions in `expect-config` are checked,
  the APK is re-signed, and it is uploaded for the test shards. The `build`
  job's matrix is empty.

A pull request never publishes a base: publishing only happens when
`github.ref_name` is the repository's default branch. So after a change that
moves the native surface — an Expo or React Native upgrade, a new native
module — warm the new key by letting this workflow run once on the default
branch (the merge itself, or a `workflow_dispatch`/scheduled run of your
caller on it); the first pull request afterwards already repacks. Only that
first run pays for a Gradle build.

A dedicated warm-up is cheaper than letting the full e2e pipeline do it:
[`seed-native-cache.yml`](seed-native-cache.md) plans on Linux, builds only the
keys with no base, publishes them, and runs no Maestro shards at all. Wire it on
a default-branch push with a `paths:` filter — see
[docs/repack.md](../repack.md#the-warm-up).

**`repack`.** The same lookup, but running Gradle is forbidden: a missing base
fails the `plan` job with the key it looked for, rather than quietly queueing a
native build.

**`native`.** Every target runs Gradle and the run publishes no base. This is
the escape hatch, and using it is a **regression**: it is the v2 behaviour, it
costs a full native build per pull request, and the run emits a `::warning::`
saying so. Reach for it only to prove a repack-specific suspicion, and take it
back out. The same escape hatch is available per pull request, without editing
the caller, by applying the `native-build-label` label (default `mobile: force
native build`); combining that label with `build-strategy: repack` fails closed
instead of picking a winner.

A repacked APK must be signed with the **same** key as the base, or the
device/emulator refuses to install it over one already there — that is why
`android-keystore-path` defaults to the debug keystore Gradle's release build
signs with. A consumer whose base is signed with something else must point
these four inputs at it.


### Why the native build no longer reads a host cache

A `native-app-cache` entry is keyed on the native key, and the native key
deliberately excludes JavaScript. Restoring one and handing it to a Maestro or
capture job would test whatever bundle the cached shell happened to carry —
exactly the hole `repack-on-hit` existed to paper over in v2. The base binary
store is the cross-run cache now, and what it holds is always repacked with
this commit's JavaScript before anything installs it, so this job simply builds
when it runs — and it only runs for a key nothing has published a base for.
`seed-native-cache.yml` still keeps a host cache, because what it produces
becomes a base to be repacked, never a test artifact. `cache-profile` is gone
with it.

## Migrating from v2

- **`repack-on-hit: true`** — delete the input. Repacking is now the default
  path, and a better one: v2 could only repack onto a shell this *same host*
  had cached, while v3 repacks a base published for the native key from any
  host, before Gradle is involved at all.
- **`repack-on-hit: false`** — remove the input (it no longer exists and a
  caller that still passes it fails workflow validation). The default
  `build-strategy: auto` is what you want. It is *not* the same as v2: v2
  compiled unless the same host held a cache entry, while `auto` repacks a
  base published by any run. `build-strategy: native` compiles every target
  every time — strictly worse than both, and a regression to undo rather than
  a setting to keep.
- **The calling job now needs `permissions:`** — see below. This is the one
  step that silently breaks a `repack-on-hit` caller that changed nothing else.
- `repack-app-version`, `android-build-tools-dir` and
  `android-build-tools-version` survive with the same defaults, now scoped to
  the `plan`/repack job instead of to a native-app-cache hit.

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
        uses: rnw-community/mobile-ci/.github/workflows/android-maestro.yml@v4.4.1 # v4.4.1
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

## Tag selection

`include-tags` / `exclude-tags` select flows by the `tags:` list in each flow's
config section (the YAML document before the first `---`; block `- smoke` and
inline `[smoke, checkout]` lists both work), with Maestro's own semantics:

- a flow runs when `include-tags` is empty **or** it carries **any** listed tag;
- a flow carrying **any** `exclude-tags` tag never runs — exclude wins;
- both are comma-separated, entries trimmed, empty entries ignored.

Maestro applies tags only when it plans a **directory**; handed a single flow
file it ignores them, and the `run-maestro-*` actions every shard runs always hand it single files. So the selection
happens when the shard is planned, before the index-modulo split or
`shard-manifest-dir` assignment, and every shard computes the same list. The
inputs are also passed to each flow's `maestro test` as `--include-tags` /
`--exclude-tags`, which is a no-op for a single file today.

`maestro-config`'s `includeTags` / `excludeTags` are honoured too, with no
input set: they are added to `include-tags` / `exclude-tags` exactly as `maestro
test <dir> --include-tags …` adds them, so a workspace config that already
excludes `android-only` keeps doing so here. Before this, those keys were
silently ignored.

The tags are read by Maestro's own YAML parser: `scripts/maestro/MaestroTagSelection.java`
runs on the Java source launcher with the `lib/` jars of the `maestro` CLI the
job installed, so the runner needs nothing beyond the **JDK** Maestro already
runs on (a bare JRE cannot launch a source file). Selection fails the step,
rather than running an unfiltered shard, when the config section of any
discovered flow does not parse or its `tags:` is not a list, when the YAML
reader cannot run, or when no flow is left. A `shard-manifest-dir` entry naming
a flow the tags deselected is skipped with a log line, not rejected. None of
this runs — no JVM is started — when neither input is set and `maestro-config`
does not mention `includeTags`/`excludeTags`.

## JUnit reports

With `junit-report: true` (the default) every flow's `maestro test` also gets
`--format junit --output <artifacts-dir>/junit/<flow>.xml`, so the shard's
existing artifact (same name as before) carries one JUnit file per flow, for
test-summary tooling such as `mikepenz/action-junit-report` with
`report_paths: '**/junit/*.xml'`. A retried flow keeps only its final attempt's
report. A flow whose final attempt produced no report (its `pre-flow-command`
failed, or Maestro died before reporting) gets a one-case JUnit failure in its
place, so no failed flow is missing. `pre-run-flow` and `flow-recovery-flow`
write none. `--format junit` makes Maestro run the single flow through its
suite runner; set `junit-report: false` to keep the previous single-flow path.

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

## Several packages: per-target fields and `call-scope`

A monorepo of packages, each with its own example apps and Maestro suite, fits
in **one call per platform**. Each `targets` entry may set, on top of its
required fields:

| Field | Default | Meaning |
| --- | --- | --- |
| `flowsDir` | the `flows-dir` input | Directory of this target's runnable flows. With every target naming its own, `flows-dir` may be left empty; a target with neither fails the `detect` job. |
| `tolerateTestFailures` | the `tolerate-test-failures` input | `true` quarantines only this target: its Maestro failure becomes a `::warning::` and every other target still gates the run. Anything but a JSON boolean fails `detect`. |
| `buildStrategy` | the `build-strategy` input | `auto`, `repack` or `native` for this target alone. A bare (non-Expo) React Native app sets `native`: it has no Expo runtime to repack, so it is always built with Gradle and never publishes a base. The `native-build-label` still makes every target `native`, and fails closed on a target that asks for `repack`. |

`buildStrategy` is explicit rather than detected: whether an app is an Expo app
is not reliably readable from its `package.json` in a monorepo whose
dependencies are hoisted, and a wrong guess would either repack an app that
cannot be repacked or compile one that could. An unknown value fails `detect`.

One call runs every target when turbo reports any of them affected. To skip
unaffected packages instead, call the workflow once per package — and then give
each call a distinct `call-scope`. It is folded into every name a call owns:
the app and plan artifacts (`android-e2e-app-<call-scope>--<target>`,
`android-e2e-plan-<call-scope>--<target>`), the Maestro artifacts, the
native build's concurrency group and the workflow's own concurrency group, and the Redroid container name.
Without it two calls in one run share those names: a duplicate artifact name
fails the upload, and on a pull request the second call cancels the first. The
plan job only ever reads the plans named after its own targets, so another
call's plans in the same run are never counted. `call-scope` takes letters,
digits, `.` and `_`, with single `-` between them; anything else fails
`detect`.

Every Android target's shards boot their own emulator, whichever call they come
from. To cap how many run on one host at once — across targets, calls and
repositories — set `emulator-slots-dir` once the fleet provisions slot files
(see [Emulator budget and host slots](#emulator-budget-and-host-slots)); a
workflow `concurrency` group could only serialise whole calls.

[docs/examples/rn-packages-monorepo/e2e.yml](../examples/rn-packages-monorepo/e2e.yml)
is a complete single-call caller with a bare and an Expo app and one
quarantined suite.

## Concurrency

The workflow sets its own `concurrency` group of the caller's workflow name,
the `flows-dir` and `call-scope` inputs and, for a `pull_request` run, the pull
request's ref, so two calls in one run with different `call-scope`s never cancel
each other. Only a
`pull_request` run is cancelled when a newer push to the same pull request
supersedes it. Every other run — a push to the default branch, a schedule, a
manual dispatch — gets a group unique to its run id, so a newer push never
cancels or displaces an older default-branch run. A caller that sets its own
workflow-level `concurrency` should follow the same rule: a group of
`${{ github.event_name == 'pull_request' && github.ref || github.run_id }}`,
so a pull request's runs share one group while every other run gets its
own, together with
`cancel-in-progress: ${{ github.event_name == 'pull_request' }}`. Making
only `cancel-in-progress` conditional is not enough: a group shared by
default-branch pushes still lets a third pending run replace the second. The example below does both.

## Permissions

**The calling job must declare its own `permissions:` block.** A reusable
workflow's job-level `permissions:` can only *narrow* the token its caller
granted — it can never add a scope. The `plan` job asks for `packages: read` +
`actions: read` and the `build` job for `packages: write`, but in a repository
whose default workflow token permission is **read** (the GitHub default for new
organisations) those requests resolve to nothing and publishing the base fails.
The repository then runs Gradle on every run and never warms a key, which looks
like "repacking does not work" rather than like a permissions problem.

Grant them on the job that calls this workflow:

```yaml
jobs:
    e2e:
        permissions:
            contents: read
            packages: write
            actions: read
        uses: rnw-community/mobile-ci/.github/workflows/android-maestro.yml@v4.4.1 # v4.4.1
```

- `contents: read` — checkout.
- `packages: write` — publishing the base binary to GHCR from a default-branch
  run (`base-backend: ghcr`, the default). `packages: read` alone is enough for
  a repository whose keys are published by something else, but then a key this
  repository does not already have a base for can never be warmed by this
  workflow.
- `actions: read` — the `artifact` backend's cross-run artifact lookup; harmless
  and recommended on the `ghcr` backend too.

With `base-backend: artifact` no package scope is needed at all —
`contents: read` + `actions: read` suffices — at the cost of workflow artifacts
expiring, so a key can go cold and cost a native build again.

This workflow still never writes to the repository and never needs a release
signing credential or an Expo/EAS token.

## Examples

### Minimal

One target on the default `avd` driver and x86_64 KVM pool; the permissions
are required (see [Permissions](#permissions)).

```yaml
jobs:
    e2e:
        permissions:
            contents: read
            packages: write
            actions: read
        uses: rnw-community/mobile-ci/.github/workflows/android-maestro.yml@v4.4.1 # v4.4.1
        with:
            targets: >-
                [{"name":"app","appDir":"apps/mobile","appId":"com.example.app","prebuildCommand":"npx expo prebuild -p android"}]
            flows-dir: apps/mobile/e2e/flows
```

### Full

```yaml
# .github/workflows/android-maestro.yml
name: Android Maestro E2E
on:
    workflow_dispatch:
    pull_request:
    push:
        branches: [main]
concurrency:
    group: android-maestro-${{ github.event_name == 'pull_request' && github.ref || github.run_id }}
    cancel-in-progress: ${{ github.event_name == 'pull_request' }}
jobs:
    e2e:
        # Required: a reusable workflow can only narrow what the caller grants.
        permissions:
            contents: read
            packages: write
            actions: read
        uses: rnw-community/mobile-ci/.github/workflows/android-maestro.yml@v4.4.1 # v4.4.1
        with:
            targets: >-
                [{"name":"bare","appDir":"apps/mobile","appId":"com.example.app","prebuildCommand":""}]
            flows-dir: apps/mobile/e2e/flows
            target-packages: |
                @myorg/mobile-app
            # build-strategy: auto is the default — repack a published base,
            # run Gradle only for a native key that has none.
            repack-env: |
                API_URL=https://staging.example.com
                APP_VERSION=1.2.3
            expect-config: |
                extra.apiUrl=https://staging.example.com
                version=1.2.3
```

`fingerprint-env` must pass exactly what the default-branch warm-up passes; a
single differing byte gives the pull request a different native key, and every
pull request runs Gradle again.

A single call covering a monorepo's packages, with a bare app and a one-target
quarantine, is in
[docs/examples/rn-packages-monorepo/e2e.yml](../examples/rn-packages-monorepo/e2e.yml).

Complete caller workflows for whole apps, linted and checked against this
workflow's inputs in CI, live in [docs/examples/](../examples/README.md).

## Forcing a run

Set `force-label` (for example `e2e:force`) to let a reviewer run the suite on a
pull request turbo reports as unaffected. Add `labeled` to the caller's
`pull_request` types, or adding the label does nothing until the next push.
Since every labelling then starts a run, and this workflow's concurrency
cancels the pull request's run in progress, gate the calling job so other
labels are ignored:

```yaml
on:
    pull_request:
        types: [opened, synchronize, reopened, labeled]
jobs:
    e2e:
        if: github.event.action != 'labeled' || github.event.label.name == 'e2e:force'
        uses: rnw-community/mobile-ci/.github/workflows/android-maestro.yml@v4.4.1 # v4.4.1
        with:
            force-label: e2e:force
```

The label is read from the triggering event's payload, so it applies to every
later push to the pull request until it is removed.
