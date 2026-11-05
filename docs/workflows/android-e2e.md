# android-e2e.yml

`workflow_call` reusable workflow: Android e2e on self-hosted runners. A
tester-army suite runs from a Linux runner against Android devices leased from a
simlock farm.

**detect** (turbo-affected gate, e2e call validation, and build-strategy
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
publishing the base it just built) → **e2e** (one job per `targets` entry — download the `.apk` the plan or the build produced, lease devices from simlock and run the suite) → **status** (aggregates every job into a single required check). `build` defaults to the
self-hosted x86_64 Linux pool (`["self-hosted","trf-linux-amd64-4x8"]`); `detect` and `status` always
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
because the target packages were untouched, reported explicitly as "no
e2e tests ran (not a pass)" rather than blending into a green check
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
`arm64-v8a`, the ABI of the farm's emulators, by default on both.

The `build` job restores the Android SDK (cmdline-tools, platform-tools and
the build-tools, platforms, NDK and CMake Gradle installs) from the Actions
cache before the build, and on a hit runs no `sdkmanager` and downloads nothing
from `dl.google.com`. It saves the SDK in a separate last step, only off
`pull_request`, with `continue-on-error` and a 10-minute `timeout-minutes`, so
a stalled upload never fails or holds the job. See
[`build-android-app`](../../actions/build-android-app#android-sdk-cache) for
the key.

## Inputs

| Name                        | Required | Default                                       | Description |
| ------------------------------ | -------- | ------------------------------------------------ | -------------- |
| `e2e-result-cache` | no | `false` | Reuse a validated exact pass for the native key, production bundle/config, tests, inputs and device. See [cache contract and rollout](../e2e-result-cache.md). Bypasses Turbo/path detection when on; forced, manual and quarantined runs do not cache. |
| `e2e-cache-test-paths` | no | `''` | Newline-separated literal paths/globs replacing the default `e2e-dir` tree. Every pattern must match. |
| `e2e-cache-extra-paths` | no | `''` | Additional fixture/script dependency paths/globs relative to repository root. Include shared hook/test dependencies. |
| `e2e-cache-state-command` | no | `''` | Optional app-directory command whose nonempty stdout versions mutable test state, e.g. `date -u +%F`. Errors disable reuse. |
| `e2e-cache-export-command` | no | `''` | Optional custom exporter writing nonempty `bundle`, valid `config.json` and all assets under `$E2E_CACHE_EXPORT_DIR`; empty uses the installed production Expo export. |
| `control-runner-labels` | no | `'["ubuntu-latest"]'` | JSON array of runner labels for the lightweight control jobs (detect/status/collect/validate-manifest/cancel-queued-runs), which need no self-hosted hardware. Set it when the org has no hosted runners, e.g. an ephemeral RunsOn label set; it is passed on to `expo-base-plan.yml` by the workflows that call it. |
| `runs-on-cache-bypass` | no | `false` | Opt-in. When a job lands on a RunsOn runner started with `extras=s3-cache`, whose cache proxy takes over the Actions results URL and breaks `actions/upload-artifact`/`download-artifact`, run a SHA-pinned `runs-on/action` first (via the [`runs-on-cache-bypass`](../../actions/runs-on-cache-bypass/README.md) action). A logged no-op on every other runner. |
| `build-runner-labels` | no | `'["self-hosted","trf-linux-amd64-4x8"]'` | JSON array of self-hosted runner labels for the native build job. |
| `targets`                       | **yes**  | —                                                  | JSON array of build targets: `{name, appDir, appId, prebuildCommand}`. `prebuildCommand` may be an empty string. Optional per target: `tolerateTestFailures`, `buildStrategy` — see [Several packages](#several-packages-per-target-fields-and-call-scope). |
| `artifact-retention-days` | no | `7` | Retention in days of the e2e report artifact. |
| `cmdline-tools-version`         | no       | `12266719`                                         | `android-actions/setup-android` cmdline-tools-version — pin explicitly, do not trust upstream defaults (see `build-android-app` README). |
| `gradle-task`                   | no       | `assembleRelease`                                  | `gradlew` task to build, e.g. `:app:assembleRelease` to scope to one module (see `build-android-app` README). |
| `gradle-args`                   | no       | `''`                                                | Extra whitespace-split arguments appended after `gradle-task`, e.g. `-x lint -x lintVitalAnalyzeRelease` (see `build-android-app` README). |
| `turbo-version`                 | no       | `''`                                               | Exact turbo npm version used by the detect job. Empty resolves the repository's own turbo: `node_modules/turbo`, then the version locked in `pnpm-lock.yaml`, `package-lock.json`, `npm-shrinkwrap.json`, `yarn.lock` or `bun.lock`, then an exact root `package.json` version, else `2.10.8` with a notice. See the [`turbo-affected` README](../../actions/turbo-affected/README.md). |
| `target-packages`               | no       | `''`                                               | Newline-separated package names gating this pipeline on `pull_request` events: a pull request that affects none of them (per `turbo ls --affected`) skips the run. Empty derives them from the `name` in each `targets[].appDir`'s `package.json`. Fails closed: an unreadable or nameless `package.json`, a target package `turbo ls` does not list, or a `turbo` failure, fails the detect job, and a missing base SHA reports affected. Every non-`pull_request` event runs. |
| `exempt-paths`                  | no       | `''`                                               | Newline- or comma-separated pathspec globs relative to the repository root, e.g. `docs/**`, `**/*.md`, `apps/website/**`. A pull request whose every changed file (`base...HEAD`) matches one skips the run without turbo detection. One non-exempt file, an empty diff, or a diff that cannot be computed (logged as a `::warning::`) runs normal detection instead. See the [`turbo-affected` README](../../actions/turbo-affected/README.md). |
| `trigger-paths`                 | no       | `''`                                               | Newline- or comma-separated pathspec globs relative to the repository root, e.g. `.github/workflows/e2e.yml`, `e2e/**`. A pull request that changes a matching file (`base...HEAD`, renames counted at both paths) runs without turbo detection, which never attributes a file outside a workspace package to one. `**` runs every pull request, which is what an empty `target-packages` did before v3.3.0. Wins over `exempt-paths`; a diff that cannot be computed runs, with a `::warning::`. See the [`turbo-affected` README](../../actions/turbo-affected/README.md). |
| `force-label` | no | `''` | Pull request label that runs the pipeline whatever turbo reports: with it on the pull request, `detect` reports affected without turbo (even for an `exempt-paths`-only diff) and the status summary reads `passed (forced by the <label> label)`. Add `labeled` to the caller's `pull_request` `types` so adding the label starts a run (see [Forcing a run](#forcing-a-run)). Empty never forces. |
| `expo-fingerprint-version`      | no       | `0.20.6`                                           | Pinned `@expo/fingerprint` npm version. |
| `android-abis`                  | no       | `auto`                                             | Comma-separated ABIs the native build compiles, passed to Gradle as `-PreactNativeArchitectures`. `auto` is `arm64-v8a`, the ABI of the farm's emulators; when `gradle-args` or `build-env` already pins `reactNativeArchitectures`, `auto` leaves it to that pin. An explicit value that contradicts such a pin fails the run. Empty compiles every ABI the project declares. Part of the native key — see [Android ABIs](#android-abis-and-the-sdk-cache). |
| `e2e-dir`                       | **yes** | `''`                                      | Directory of the e2e project (its `package.json`, lockfile and e2e config), relative to the repository root. |
| `e2e-runner-labels`             | no       | `''` (falls back to `repack-runner-labels`)        | JSON array of Linux runner labels for the e2e job. Any Linux runner with Node that reaches `simlock-url`, no KVM; it hosts one test worker per leased device. |
| `e2e-node-version`              | no       | `^24.8.0`                                          | Node.js version the e2e job runs the e2e project with, independent of `node-version` (which builds the app). tester-army e2e needs 22.22.3+ on Node 22, or 24.8+. |
| `e2e-install-command`           | no       | `npm ci --no-audit --no-fund`                      | Installs the e2e project's dependencies, in `e2e-dir`. |
| `e2e-command`                   | no       | `npx e2e run --target android`                     | Runs the suite, in `e2e-dir`. Gets the [environment contract](#e2e-suite-on-simlock); must write its report under `e2e-dir/.e2e`. |
| `e2e-workers`                   | no       | `1`                                                | Devices leased and tests run at once per target (`E2E_WORKERS`). Lowered to the farm's free Android capacity when the farm reports it. |
| `e2e-retries`                   | no       | `1`                                                | Retries per failed test inside the run (`E2E_RETRIES`). |
| `e2e-timeout-minutes`           | no       | `60`                                               | Timeout of the e2e job. |
| `simlock-url`                   | **yes** | `''`                                      | Base URL of the simlock gateway or worker (`SIMLOCK_URL`), reachable from `e2e-runner-labels`. |
| `node-version`                  | no       | `22.x`                                             | Node version for `actions/setup-node`. |
| `install-command`               | no       | `yarn install --immutable`                         | JS dependency install command. |
| `enable-corepack`               | no       | `true`                                             | Run `corepack enable` before install. Skipped when the resolved package manager is `pnpm` (provisioned by `pnpm/action-setup`). |
| `package-manager`               | no       | `''` (auto-detect)                                 | Override the JS package manager (`yarn`, `pnpm`, `npm`). Empty auto-detects at the repo root: `devEngines.packageManager` / `packageManager` in `package.json` (needs `jq` on the runner), else exactly one root lockfile (`yarn.lock` / `pnpm-lock.yaml` / `package-lock.json` or `npm-shrinkwrap.json`); no match, an ambiguous match or an unsupported value fails the job. Drives pnpm provisioning and, in the jobs that configure one, the package-manager dependency cache (`node-pm-cache`: restored on every event, saved only off pull requests) — set `install-command` to match (e.g. `pnpm install --frozen-lockfile`). Resolving to `pnpm` also requires a pnpm version in `package.json`. See [Package manager](../../README.md#package-manager). |
| `build-command`                 | no       | `''`                                               | Optional workspace JS build command run at repo root before the native build. |
| `build-env`                     | no       | `''`                                               | Newline-separated `KEY=VALUE` pairs appended to `$GITHUB_ENV` at the start of the build job. Rejects (fails closed) any line without `=` or whose name does not match `^[A-Za-z_][A-Za-z0-9_]*$`. |
| `build-strategy`                | no       | `auto`                                             | How this pull request gets the APK its e2e suite installs. `auto` computes the native key, looks up the base binary published for it, and repacks that base with this commit's JavaScript; only a key with no published base runs Gradle — and when it does on the default branch, the base it builds is published for the next run. `repack` refuses to run Gradle at all: a missing base fails the build. `native` is the escape hatch and a regression — every pull request then rebuilds the APK, and that run publishes no base. See [Build strategy](#build-strategy) and [docs/repack.md](../repack.md). |
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
| `tolerate-test-failures`        | no       | `false`                                            | `true` keeps the e2e job green when the suite fails, and reports the failure as a `::warning::` instead. For a time-boxed quarantine of a known-broken suite. The default of every target's `tolerateTestFailures`, which quarantines one target alone. |
| `call-scope`                    | no       | `''`                                               | Names this call's artifacts, plans and concurrency groups, so several calls in one run (one per package, say) never share or cancel them. Calls that share a run must each set a distinct, non-empty value. `[A-Za-z0-9._]` with single `-` between them. Empty keeps today's names. See [Several packages](#several-packages-per-target-fields-and-call-scope). |

With `e2e-result-cache: true`, the planner checks exact pass records before base
fetch/repack and returns only cache misses to the build/test matrices. Complete
hits report `result=passed` with successful producer links. Default-branch E2E
pushes seed evidence for other PRs; the native-base warm-up does not. Additional
planner work is one production export; cache failures require the normal suite.
See [identity, test dependency and trust contracts](../e2e-result-cache.md).

## Outputs

| Name | Description |
| ---- | ----------- |
| `result` | The `status` job's verdict: `passed`, `failed`, or `skipped` when no target package was affected. A skip is a green check, not a pass, so a notification job should not report it as one. |
| `e2e-artifact-prefix` | The [e2e report artifact](#e2e-suite-on-simlock)'s name up to its target. Append the target's name instead of rebuilding it: `download-artifact` with a pattern that matches nothing does not fail. `e2e-android-<call-scope>--`, or `e2e-android-` without a `call-scope`. |

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
              run: echo "android-e2e: $RESULT"
```

## Secrets

| Secret                | Required | Description |
| --------------------- | -------- | ----------- |
| `build-secrets-env`   | no       | Masked `KEY=VALUE` entries (`KEY<<DELIMITER` for a multi-line value) exported after `build-env` in the `plan`/repack leg (install, `build-command`, fingerprint, re-bundle) and the native `build` job. For what a real build needs but a log must never show: a remote turbo cache token, a Maps API key compiled into the base. Parsed by [`apply-secret-env`](../../actions/apply-secret-env/README.md). Only a SHA-256 digest of the entries enters the native key, never a value — so rotating a secret moves the key, and the warm-up ([`seed-native-cache.yml`](seed-native-cache.md)) must be passed the same secret or the two never agree on a key and every pull request takes a native build. |
| `e2e-secrets-env` | no | Masked `KEY=VALUE` entries, one line each, exported to the e2e job's environment. For test-user passwords and the credentials a suite uses to prepare the backend under test. |
| `simlock-token` | **yes** | simlock agent token (`SIMLOCK_TOKEN`) the e2e suite leases Android devices with. Reaches only the e2e job's run and lease-release steps. Give each consuming repository its own token. A run that needs it and lacks it fails in `detect`, before anything builds. |

Pass them explicitly — `secrets: inherit` would
hand every repository secret to a third-party workflow.

```yaml
jobs:
    e2e:
        uses: rnw-community/mobile-ci/.github/workflows/android-e2e.yml@v5.0.0 # v5.0.0
        with:
            targets: ...
            e2e-dir: e2e
            simlock-url: https://simlock.example.com
        secrets:
            simlock-token: ${{ secrets.SIMLOCK_TOKEN }}
            build-secrets-env: |
                TURBO_TOKEN=${{ secrets.TURBO_TOKEN }}
                MAPS_API_KEY=${{ secrets.MAPS_API_KEY }}
            e2e-secrets-env: |
                TEST_PASSWORD=${{ secrets.E2E_TEST_PASSWORD }}
```

This workflow never touches a release signing credential
or an Expo/EAS token. The `android-keystore-*` inputs default to the published
React Native **debug** keystore constants, which are not secrets; a release key
belongs in [`native-publish.yml`](native-publish.md). The workflow does need a
**token permission** the caller grants; see [Permissions](#permissions).

## E2E suite on simlock

One Linux job per target runs your
[tester-army e2e](https://github.com/tester-army/e2e) suite against Android devices
leased from a [simlock](https://github.com/callstackincubator/simlock) gateway or
worker. The job downloads the `android-e2e-app…` artifact the plan or the build
produced, and one job with `e2e-workers: N` balances the tests over N devices as
each finishes. `ios-e2e.yml` and `android-e2e.yml` run it through the same
[`e2e-suite`](../../actions/e2e-suite/README.md) action, so both platforms behave
alike. `e2e-dir` is also what the e2e result cache hashes.

The job runs `e2e-install-command`, installs
[`@mobile-ci/e2e-simlock`](../../packages/e2e-simlock/README.md) from this
workflow's own tag into `e2e-dir/node_modules`, then runs `e2e-command` in
`e2e-dir` with:

| Variable | Value |
| --- | --- |
| `E2E_PLATFORM` | `android` |
| `E2E_APP_PATH` | absolute path of the repacked or built `.apk` |
| `E2E_APP_ID` | the target's `appId` |
| `E2E_TARGET` | the target's `name` |
| `E2E_WORKERS` | `e2e-workers`, lowered to the farm's free Android devices split across this call's targets, when the farm reports them (best effort: other runs may lease in between) |
| `E2E_RETRIES` | `e2e-retries` |
| `E2E_SESSION` | unique per platform, run, attempt and target; give it to agent-device as the session name |
| `SIMLOCK_URL`, `SIMLOCK_TOKEN` | `simlock-url` and the `simlock-token` secret |

`e2e-secrets-env` entries are exported to the suite too (masked), for test
credentials. A target with `tolerateTestFailures` turns failing tests into a
warning, but not a run that tested nothing or hit an infrastructure error: no report, none executed or a run error fails the job with an `Infrastructure failure:` annotation, which [`rerun-infra-failures`](../../actions/rerun-infra-failures/README.md) retries once. The farm runs **arm64-v8a** emulators, so the APK must contain that ABI. `android-abis: auto` builds exactly that, and [`seed-native-cache.yml`](seed-native-cache.md) must resolve the same value (the ABIs are part of the native key). `detect` rejects a build that leaves arm64-v8a out; an empty `android-abis` builds every ABI the project declares and passes.

Your e2e config leases its devices with the package:

```ts
import { simlockDevices } from '@mobile-ci/e2e-simlock';

// in the target's mobile({ platform: 'android', session: process.env.E2E_SESSION, device: … })
device: simlockDevices({
    url: process.env.SIMLOCK_URL!,
    token: process.env.SIMLOCK_TOKEN!,
    platform: 'android',
    device: 'Pixel 6', osVersion: '34', imageTag: 'aosp_atd',
    tenant: 'my-app'
}),
```

It leases one device per worker and waits in a client-side queue while the
farm is full. It installs the app, swaps a device whose install failed (once),
renews each lease, lists the lease ids in `.e2e/simlock-leases.json` and
releases every lease at the end. A target whose tests need an unslimmed device (Apple Pay and other
PassKit/Wallet tests on iOS) adds `deviceMode: 'full'`; the others keep the
farm's slim default. The package [README](../../packages/e2e-simlock/README.md)
has every option, the `@mobile-ci/e2e-simlock/exec` fixture helpers (`simctl` on
iOS, `adb` on Android), and the local install. Nothing in it assumes a particular app: no bundle id, no fixture layout,
no helper app unless you pass one in `extraApps`.

A cancelled run (a newer push, with `cancel-in-progress`) is killed before the
suite can release its devices. The job then releases every lease listed in
`.e2e/simlock-leases.json` in an `if: always()` step, so a cancel frees the
farm at once instead of at the lease TTL.

Keep `e2e-dir` a standalone project (its own `package.json` and lockfile, not a
member of the repository's workspace): its tree is hashed into the result cache
key, and a workspace's `node_modules` links make that walk slow or circular. The
default `e2e-install-command` is npm; set it for pnpm or yarn (corepack is not
enabled for you).

The report under `e2e-dir/.e2e` is uploaded as `e2e-android-<target>`, or with a
`call-scope` as `e2e-android-<call-scope>--<target>`, with two dashes: `call-scope:
edge-fade` and target `foo` give `e2e-android-edge-fade--foo`. Read the name from the
`e2e-artifact-prefix` output rather than rebuilding it:

```yaml
    metrics:
        needs: e2e
        runs-on: [self-hosted, trf-linux-amd64-2x4]
        steps:
            - uses: actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131 # v7.0.0
              with:
                  name: ${{ needs.e2e.outputs.e2e-artifact-prefix }}foo
```

Its `summary.md` is added to the job summary. An exit code of 0 is not enough to pass: the job clears `.e2e` before
the run, then requires the run's `.e2e/report.json` (tester-army's report) with
`status: passed`, at least one executed test and none failed, every count a
whole number. A command that exits 0 without that evidence (no report, nothing
selected, a swallowed exit code) fails the job.

```yaml
jobs:
    e2e:
        permissions:
            contents: read
            packages: write
            actions: read
        uses: rnw-community/mobile-ci/.github/workflows/android-e2e.yml@v5.0.0 # v5.0.0
        with:
            targets: >-
                [{"name":"app","appDir":"apps/mobile","appId":"com.example.app","prebuildCommand":"npx expo prebuild -p android"}]
            trigger-paths: e2e/**
            e2e-dir: e2e
            e2e-workers: '2'
            simlock-url: https://simlock.vitaliiyehorov.dev
            android-abis: arm64-v8a
        secrets:
            simlock-token: ${{ secrets.SIMLOCK_TOKEN }}
```

A standalone `e2e/` sits outside the app workspace, so turbo never reports a
change there as affecting the app: list it in `trigger-paths`. GitHub withholds
secrets from pull requests opened from forks, so give the calling job
`if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository`
and run the suite on fork contributions with `workflow_dispatch` once reviewed;
never hand the token to untrusted code.

Use the farm's public HTTPS address in CI. A LAN address reaches only the hosts
on that LAN, and the shared pools also schedule jobs on machines outside it.

### Migrating from a copied provider

A repository that copied a simlock provider into its e2e project (budgie's
`e2e/support/simlock/`) switches the same way:

1. Delete the copied `provider.ts`, `relay.ts`, `exec.ts` and `e2e-drop/`, and the
   generic step helpers your suite copied (`byId`, `tapUntil`, `done`, centring
   scrolls).
2. Import `simlockDevices` from `@mobile-ci/e2e-simlock`, the steps from
   `@mobile-ci/e2e-simlock/steps` and the fixture helpers from
   `@mobile-ci/e2e-simlock/exec`, and pass `platform` and your own `tenant`.
3. Pin every mobile-ci workflow call to the same tag: the
   workflow installs the package from that tag.
4. A job of your own that typechecks or runs the e2e project outside these
   workflows (a `tsc` check on pull requests) installs the package first, after
   its `npm ci`: `curl -fsSLO https://raw.githubusercontent.com/rnw-community/mobile-ci/v5.0.0/scripts/fetch-e2e-simlock.sh && bash fetch-e2e-simlock.sh v5.0.0 e2e`, or the
   [`e2e-simlock-install`](../../actions/e2e-simlock-install/README.md) action.

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
  the APK is re-signed, and it is uploaded for the e2e job. The `build`
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
keys with no base, publishes them, and runs no e2e suite at all. Wire it on
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
deliberately excludes JavaScript. Restoring one and handing it to a test or
capture job would test whatever bundle the cached shell happened to carry —
exactly the hole `repack-on-hit` existed to paper over in v2. The base binary
store is the cross-run cache now, and what it holds is always repacked with
this commit's JavaScript before anything installs it, so this job simply builds
when it runs — and it only runs for a key nothing has published a base for.
`seed-native-cache.yml` still keeps a host cache, because what it produces
becomes a base to be repacked, never a test artifact. `cache-profile` is gone
with it.

## Several packages: per-target fields and `call-scope`

A monorepo of packages, each with its own example apps and e2e suite, fits
in **one call per platform**. Each `targets` entry may set, on top of its
required fields:

| Field | Default | Meaning |
| --- | --- | --- |
| `tolerateTestFailures` | the `tolerate-test-failures` input | `true` quarantines only this target: its suite failure becomes a `::warning::` and every other target still gates the run. Anything but a JSON boolean fails `detect`. |
| `buildStrategy` | the `build-strategy` input | `auto`, `repack` or `native` for this target alone. A bare (non-Expo) React Native app sets `native`: it has no Expo runtime to repack, so it is always built with Gradle and never publishes a base. The `native-build-label` still makes every target `native`, and fails closed on a target that asks for `repack`. |

`buildStrategy` is explicit rather than detected: whether an app is an Expo app
is not reliably readable from its `package.json` in a monorepo whose
dependencies are hoisted, and a wrong guess would either repack an app that
cannot be repacked or compile one that could. An unknown value fails `detect`.

One call runs every target when turbo reports any of them affected. To skip
unaffected packages instead, call the workflow once per package — and then give
each call a distinct `call-scope`. It is folded into every name a call owns:
the app and plan artifacts (`android-e2e-app-<call-scope>--<target>`,
`android-e2e-plan-<call-scope>--<target>`), the e2e report, the
native build's concurrency group and the workflow's own concurrency group.
Without it two calls in one run share those names: a duplicate artifact name
fails the upload, and on a pull request the second call cancels the first. The
plan job only ever reads the plans named after its own targets, so another
call's plans in the same run are never counted. `call-scope` takes letters,
digits, `.` and `_`, with single `-` between them; anything else fails
`detect`.

[docs/examples/rn-packages-monorepo/e2e.yml](../examples/rn-packages-monorepo/e2e.yml)
is a complete single-call caller with a bare and an Expo app and one
quarantined suite.

## Concurrency

The workflow sets its own `concurrency` group of the caller's workflow name,
the `e2e-dir` and `call-scope` inputs and, for a `pull_request` run, the pull
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
        uses: rnw-community/mobile-ci/.github/workflows/android-e2e.yml@v5.0.0 # v5.0.0
```

- `contents: read` — checkout.
- `packages: write` — publishing the base binary to GHCR from a default-branch
  run (`base-backend: ghcr`, the default). `packages: read` alone is enough for
  a repository whose keys are published by something else, but then a key this
  repository does not already have a base for can never be warmed by this
  workflow.
- `actions: read` — the `artifact` backend's cross-run artifact lookup, and
  reading the e2e run's own artifacts; harmless and recommended
  on the `ghcr` backend too.

With `base-backend: artifact` no package scope is needed at all —
`contents: read` + `actions: read` suffices — at the cost of workflow artifacts
expiring, so a key can go cold and cost a native build again.

This workflow still never writes to the repository and never needs a release
signing credential or an Expo/EAS token.

## Examples

### Minimal

One target; the permissions
are required (see [Permissions](#permissions)).

```yaml
jobs:
    e2e:
        permissions:
            contents: read
            packages: write
            actions: read
        uses: rnw-community/mobile-ci/.github/workflows/android-e2e.yml@v5.0.0 # v5.0.0
        with:
            targets: >-
                [{"name":"app","appDir":"apps/mobile","appId":"com.example.app","prebuildCommand":"npx expo prebuild -p android"}]
            e2e-dir: e2e
            simlock-url: https://simlock.example.com
        secrets:
            simlock-token: ${{ secrets.SIMLOCK_TOKEN }}
```

### Full

```yaml
# .github/workflows/android-e2e.yml
name: Android E2E
on:
    workflow_dispatch:
    pull_request:
    push:
        branches: [main]
concurrency:
    group: android-e2e-${{ github.event_name == 'pull_request' && github.ref || github.run_id }}
    cancel-in-progress: ${{ github.event_name == 'pull_request' }}
jobs:
    e2e:
        # Required: a reusable workflow can only narrow what the caller grants.
        permissions:
            contents: read
            packages: write
            actions: read
        uses: rnw-community/mobile-ci/.github/workflows/android-e2e.yml@v5.0.0 # v5.0.0
        with:
            targets: >-
                [{"name":"bare","appDir":"apps/mobile","appId":"com.example.app","prebuildCommand":""}]
            e2e-dir: e2e
            simlock-url: https://simlock.example.com
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
        secrets:
            simlock-token: ${{ secrets.SIMLOCK_TOKEN }}
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
        uses: rnw-community/mobile-ci/.github/workflows/android-e2e.yml@v5.0.0 # v5.0.0
        with:
            e2e-dir: e2e
            simlock-url: https://simlock.example.com
            force-label: e2e:force
        secrets:
            simlock-token: ${{ secrets.SIMLOCK_TOKEN }}
```

The label is read from the triggering event's payload, so it applies to every
later push to the pull request until it is removed.
