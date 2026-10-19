# ios-maestro.yml

`workflow_call` reusable workflow: iOS Maestro e2e on self-hosted runners.

**detect** (turbo-affected gate, shard-index computation, and build-strategy
resolution, hosted `ubuntu-latest`) → **plan** (one leg per `targets` entry, on
the Linux repack pool — compute the native key with
[`expo-native-key`](../../actions/expo-native-key), look up the base binary
published for it with [`expo-base-binary`](../../actions/expo-base-binary),
and, when one exists, produce this commit's app from it with
[`expo-repack`](../../actions/expo-repack) instead of compiling anything; the
job's `native-targets` output is the set of targets whose key had no base) →
**build** (one job per *remaining* target only — Xcode select,
restore, ccache, `xcodebuild`, artifact upload, and, on the default branch,
publishing the base it just built) → **test** (one job per `targets` ×
`shard-count` — download the `.app` the plan or the build produced, boot a
Simulator, run a Maestro flow shard) → **status** (aggregates every job into a
single required check). `build` and `test` run on self-hosted macOS by default
and `plan` on the self-hosted Linux pool; `detect` and `status` always run on
`ubuntu-latest`.

The normal outcome of a pull request is that **no Mac slot is taken at all**:
the plan job repacks a published base on Linux. See
[Build strategy](#build-strategy) below and [docs/repack.md](../repack.md).

The `status` job reports three distinct outcomes, in its log and in
`$GITHUB_STEP_SUMMARY`: **passed**, **failed** (naming the job and result
that broke the run, with a `::notice::` hint when a `cancelled` result
likely means a hit timeout), and **skipped** — every build/test leg skipped
because the target packages were untouched, reported explicitly as "zero
Maestro flows ran (not a pass)" rather than blending into a green check
silently. A `build` job that was *skipped* while the plan still listed targets
needing one is reported as a failure too — a skipped build is not a build.

## Inputs

| Name                       | Required | Default                                | Description |
| ---------------------------- | -------- | ----------------------------------------- | -------------- |
| `runner-labels`               | no       | `["self-hosted","macOS","ARM64"]`          | JSON array of self-hosted runner labels for the build/test jobs. |
| `control-runner-labels` | no | `'["ubuntu-latest"]'` | JSON array of runner labels for the lightweight control jobs (detect/status/collect/validate-manifest/cancel-queued-runs), which need no self-hosted hardware. Set it when the org has no hosted runners, e.g. an ephemeral RunsOn label set; it is passed on to `expo-base-plan.yml` by the workflows that call it. |
| `runs-on-cache-bypass` | no | `false` | Opt-in. When a job lands on a RunsOn runner started with `extras=s3-cache`, whose cache proxy takes over the Actions results URL and breaks `actions/upload-artifact`/`download-artifact`, run a SHA-pinned `runs-on/action` first (via the [`runs-on-cache-bypass`](../../actions/runs-on-cache-bypass/README.md) action). A logged no-op on every other runner. |
| `build-runner-labels`         | no       | `''`                                       | JSON array of self-hosted runner labels for the build job only. Falls back to `runner-labels` when empty; set this and `test-runner-labels` together to split build/test across separate runner pools. |
| `test-runner-labels`          | no       | `''`                                       | JSON array of self-hosted runner labels for the test job only. Falls back to `runner-labels` when empty. Must be a macOS pool that can run the `ios-simulator-archs` slice; the test job checks this before it boots a simulator. |
| `ios-simulator-archs`         | no       | `arm64`                                    | Simulator slice the build produces: `arm64` or `x86_64`, anything else fails closed. `x86_64` is for apps whose native SDKs ship no arm64-simulator slice (ML Kit, for one): it builds with `ARCHS=x86_64 EXCLUDED_ARCHS=arm64`, gets its own native key, and the test job accepts an x86_64 macOS host or an arm64 one where `arch -x86_64 /usr/bin/true` succeeds (Rosetta 2 installed). Must match `seed-native-cache.yml`'s value, or the warm-up publishes under a key no pull request looks up. See [x86_64 simulator builds](#x86_64-simulator-builds). |
| `targets`                     | **yes**  | —                                          | JSON array of build targets: `{name, appDir, workspace, scheme, appId, prebuildCommand}`. `prebuildCommand` may be an empty string. |
| `flows-dir`                   | **yes**  | —                                          | Directory (relative to repo root) whose top-level files are the runnable Maestro flows by default. Subdirectories are not searched unless `flows-max-depth` is raised. |
| `flows-max-depth`             | no       | `1`                                        | `find -maxdepth` under `flows-dir`. `0` means unbounded recursion. Default keeps subflows (invoked via `runFlow`, conventionally in subdirectories) out of the shard. |
| `flows-name-pattern`          | no       | `*.flow.yaml`                              | Space-separated `find -name` globs (OR'd together) selecting runnable flows directly inside `flows-dir`. Keeps reusable subflows and capture-only flows in subdirectories out of the shard by default. |
| `flows-exclude-pattern`       | no       | `''`                                       | Optional `find ! -name` globs excluding matched flows by basename: one glob, or a comma- and/or newline-separated list (each entry trimmed, empty entries ignored; a glob containing a comma is not supported). |
| `shard-manifest-dir`          | no       | `''`                                       | Optional directory (relative to repo root) of hand-curated `shard-<index>.txt` files (one `flows-dir`-relative flow path per line) overriding the computed index-modulo split. Unset falls back to modulo entirely; once set, every shard-index this job can run must have its own file — a partial manifest fails closed. |
| `pre-run-flow`                | no       | `''`                                       | Path to a single priming flow run once before each shard's flows, excluded from sharding. Its failure fails that shard immediately. |
| `flow-recovery-flow`          | no       | `''`                                       | Path to a single best-effort recovery flow run after a **failed** flow attempt — before the same flow's next retry attempt, and before the next flow starts — so one failure cannot strand the app in a state that cascades into the flows after it. Never run after a passing attempt, and not after a shard's last flow. Its own failure only logs a `::warning::` and never fails the shard. Like `pre-run-flow`, it is removed from the shard's discovered flow list, so it never also runs as a scenario of its own. Its duration is excluded from the per-flow timing table; a line below that table reports how many times it ran and how many of those runs failed. |
| `pre-test-command`            | no       | `''`                                       | Optional consumer-owned shell command run once after the app is installed on the simulator and before any flow (including `pre-run-flow`) executes, e.g. seeding a fixture into the app's data container. Runs with `SIMULATOR_UDID`, `APP_ID`, and `APP_PATH` in its environment. Its failure fails that shard immediately. |
| `pre-flow-command`            | no       | `''`                                       | Consumer-owned shell command run **before every flow attempt**, each retry included, after `pre-run-flow` and the warm-up. Never run before `pre-run-flow` or `flow-recovery-flow` themselves. Runs with `FLOW_PATH`, `FLOW_NAME`, `APP_ID`, `SIMULATOR_UDID` and `MAESTRO_FLOW_ENV_FILE` in its environment. Unlike the best-effort `flow-recovery-flow` it is a **precondition**: a non-zero exit fails that attempt without running the flow, consuming one of its `1 + flow-retries` attempts and triggering the recovery flow like any other failed attempt. Every `KEY=VALUE` line it appends to `$MAESTRO_FLOW_ENV_FILE` becomes an extra `-e KEY=VALUE` argument for that one flow's `maestro test` — see [Per-flow preconditions](#per-flow-preconditions). |
| `maestro-env`                 | no       | `''`                                       | Newline-separated `KEY=VALUE` pairs, each passed as an additional `-e KEY=VALUE` argument to every `maestro test` invocation (`pre-run-flow` and shard flows alike). Rejects (fails closed) any line without `=` or whose name does not match `^[A-Za-z_][A-Za-z0-9_]*$`. |
| `maestro-config`              | no       | `''`                                       | Path to the consumer's Maestro workspace config (`config.yaml`), passed as `--config` to every `maestro test` invocation. Maestro only auto-discovers a workspace `config.yaml` when it is pointed at a **directory**, and the actions below always pass individual flow files, so without this input a workspace config is silently ignored — e.g. `platform.ios.snapshotKeyHonorModalViews: false`, which an `@expo/ui` SwiftUI `.sheet()` modal needs before its React Native content appears in the XCUITest hierarchy at all. Relative paths resolve against the job's working directory. Fails closed when set to a path that is not a file. Its `includeTags`/`excludeTags` are honoured when the shard is planned — see [Tag selection](#tag-selection). |
| `include-tags` | no | `''` | Comma-separated Maestro tags; only flows whose config section's `tags:` holds any of them run. Applied when the shard is planned (exclude wins), added to `maestro-config`'s `includeTags`, and passed to `maestro test`. Fails closed on an unparsable flow config section or an empty selection — see [Tag selection](#tag-selection). |
| `exclude-tags` | no | `''` | Comma-separated Maestro tags; flows holding any of them never run, even when `include-tags` selects them. Added to `maestro-config`'s `excludeTags` — see [Tag selection](#tag-selection). |
| `junit-report` | no | `true` | `true` writes each flow's final-attempt JUnit report (`maestro test --format junit`) to `junit/<flow>.xml` inside the shard's existing Maestro artifact; `false` writes none — see [JUnit reports](#junit-reports). |
| `artifact-retention-days` | no | `7` | Retention in days of each shard's Maestro artifact (debug output, final-state capture, JUnit reports), passed to the `run-maestro-*` action's `retention-days`. |
| `flow-retries`                | no       | `0`                                        | Non-negative retry budget per flow; each flow gets up to `1 + flow-retries` attempts. |
| `app-warm-seconds`            | no       | `20`                                       | Seconds the app is left running during a one-off warm-up (`simctl launch`, settle, `simctl terminate`) performed after install and before `pre-test-command` or any flow runs, so first-launch cold-start cost is not absorbed by the first flow's own timeout budget. `0` disables warming. |
| `shard-count`                 | no       | `2`                                        | Number of test shards per target. |
| `xcode-version`               | no       | `26.4.1`                                   | Xcode version string, e.g. `26.4.1`. |
| `xcode-build`                 | no       | `17E202`                                   | Xcode build number, e.g. `17E202`. |
| `turbo-version`               | no       | `''`                                       | Exact turbo npm version used by the detect job. Empty resolves the repository's own turbo: `node_modules/turbo`, then the version locked in `pnpm-lock.yaml`, `package-lock.json`, `npm-shrinkwrap.json`, `yarn.lock` or `bun.lock`, then an exact root `package.json` version, else `2.10.8` with a notice. See the [`turbo-affected` README](../../actions/turbo-affected/README.md). |
| `target-packages`             | no       | `''`                                       | Newline-separated package names gating this pipeline on `pull_request` events: a pull request that affects none of them (per `turbo ls --affected`) skips the run. Empty derives them from the `name` in each `targets[].appDir`'s `package.json`. Fails closed: an unreadable or nameless `package.json`, a target package `turbo ls` does not list, or a `turbo` failure, fails the detect job, and a missing base SHA reports affected. Every non-`pull_request` event runs. |
| `exempt-paths`                | no       | `''`                                       | Newline- or comma-separated pathspec globs relative to the repository root, e.g. `docs/**`, `**/*.md`, `apps/website/**`. A pull request whose every changed file (`base...HEAD`) matches one skips the run without turbo detection. One non-exempt file, an empty diff, or a diff that cannot be computed (logged as a `::warning::`) runs normal detection instead. See the [`turbo-affected` README](../../actions/turbo-affected/README.md). |
| `trigger-paths`               | no       | `''`                                       | Newline- or comma-separated pathspec globs relative to the repository root, e.g. `.github/workflows/e2e.yml`, `e2e/**`. A pull request that changes a matching file (`base...HEAD`, renames counted at both paths) runs without turbo detection, which never attributes a file outside a workspace package to one. `**` runs every pull request, which is what an empty `target-packages` did before v3.3.0. Wins over `exempt-paths`; a diff that cannot be computed runs, with a `::warning::`. See the [`turbo-affected` README](../../actions/turbo-affected/README.md). |
| `force-label` | no | `''` | Pull request label that runs the pipeline whatever turbo reports: with it on the pull request, `detect` reports affected without turbo (even for an `exempt-paths`-only diff) and the status summary reads `passed (forced by the <label> label)`. Add `labeled` to the caller's `pull_request` `types` so adding the label starts a run (see [Forcing a run](#forcing-a-run)). Empty never forces. |
| `expo-fingerprint-version`    | no       | `0.20.6`                                   | Pinned `@expo/fingerprint` npm version. |
| `maestro-version`             | no       | `2.10.0`                                   | Pinned Maestro CLI version; also the version the `device-cloud` driver asks Device Cloud for. |
| `ios-driver`                    | no       | `local`                                            | `local` runs the flows on a simulator the test runner boots (`run-maestro-ios`). `device-cloud` submits the `.app` and `flows-dir` to devicecloud.dev from a plain Linux runner — see [Device Cloud driver](#device-cloud-driver). |
| `device-cloud-runner-labels`    | no       | `''`                                               | JSON array of runner labels for the test job when the driver is `device-cloud`. The job only uploads and waits, so any Linux runner with Node works. Empty falls back to `repack-runner-labels`. |
| `device-cloud-cli-version`      | no       | `5.7.1`                                            | Exact `@devicecloud.dev/dcd` npm version the `device-cloud` driver runs. |
| `device-cloud-ios-device`       | no       | `''`                                               | Device Cloud iOS model, e.g. `iphone-16` (`--ios-device`). Empty uses Device Cloud's default. |
| `device-cloud-ios-version`      | no       | `''`                                               | Device Cloud iOS major version, e.g. `18` (`--ios-version`). Empty uses Device Cloud's default. |
| `maestro-reuse-driver`        | no       | `true`                                     | `true` passes `--no-reinstall-driver` and one `--driver-host-port` derived from the simulator UDID (the first free `127.0.0.1` port from a UDID-hashed start in 20000–30098, so shards on one host get distinct ports), to every `maestro test` invocation of the shard (pre-run flow, flows, retries, recovery flow): the XCTest driver the first invocation starts keeps running and every later invocation reuses it instead of starting its own. Each flow is still its own invocation, so `pre-flow-command`, per-flow env, retries, the recovery flow and the timing rows are unchanged. `false` starts a fresh driver per invocation. |
| `simulator-device`            | no       | `''`                                       | Exact simulator device name to boot (e.g. `iPhone 17 Pro`), matched against `xcrun simctl list devices available` with no fuzzy matching — fails closed, listing available devices, on no exact match. Empty keeps the previous last-available heuristic (emits a `::notice::` naming its choice and recommending pinning). |
| `simulator-reduce-motion`     | no       | `false`                                    | `true` turns on the booted simulator's Reduce Motion accessibility setting (`com.apple.Accessibility ReduceMotionEnabled`) before the app is installed and first launched, so UIKit, React Native `AccessibilityInfo` and Reanimated skip their animations. Fails closed on any value other than `true`/`false`. |
| `simslim-version` | no | `0.12.2` | Pinned simslim CLI version, consulted only when `simulator-slim-profile` or `simulator-requires` is set. A `simslim` already on PATH is reused on an exact `simslim version` match; otherwise the `simslim-v<version>-macos-arm64.tar.gz` asset is downloaded from [MobAI-App/simslim releases](https://github.com/MobAI-App/simslim/releases) into `$HOME/.simslim-pinned`, verified against `simslim-sha256`, and extracted per job; preinstall on the host to avoid it. |
| `simslim-sha256` | no | `b47302da6fb8...` | SHA-256 of the `simslim-v<simslim-version>-macos-arm64.tar.gz` release asset (default: the v0.12.2 digest, maintained here because upstream publishes no checksum file). The tarball cached under `$HOME/.simslim-pinned` is re-hashed against it on every job before the binary is extracted into a job-private directory, so no previously extracted executable is reused. Empty refuses to download, so only a preinstalled `simslim` of the exact version satisfies the job. Bump together with `simslim-version`. |
| `simulator-slim-profile` | no | `bundled` | `bundled` uses mobile-ci's own [`profiles/ci.json`](../../profiles/ci.json) (App Store/push/StoreKit and Safari/universal-link services on, every other category off), so a consumer commits no profile of its own; a repository-relative path uses that profile instead. The booted simulator is checked with `simslim verify --profile` before the app is installed; any drift fails closed unless `simulator-slim-repair` is `true`. Empty opts out of slimming. See [Every simulator runs slim](../../docs/self-hosted-runners.md#every-simulator-runs-slim). |
| `simulator-slim-repair` | no | `true` | `true` (the default) re-applies the profile in-job with `simslim on` (reboots the simulator) when `simulator-slim-profile` reports drift, then verifies again; a second mismatch still fails. Set it to `false` once the host image ships slimmed devices. |
| `simulator-requires` | no | `''` | Comma-separated simslim feature IDs the flows depend on (e.g. `push,universal-links`; `simslim doctor --list`). When set, `simslim doctor --requires` runs against the booted simulator and fails closed if slimming disabled a daemon behind any of them. Works without a profile. |
| `node-version`                | no       | `22.x`                                     | Node version for `actions/setup-node`. |
| `install-command`             | no       | `yarn install --immutable`                 | JS dependency install command. |
| `enable-corepack`             | no       | `true`                                     | Run `corepack enable` before install. Skipped when the resolved package manager is `pnpm` (provisioned by `pnpm/action-setup`). |
| `package-manager`             | no       | `''` (auto-detect)                         | Override the JS package manager (`yarn`, `pnpm`, `npm`). Empty auto-detects at the repo root: `devEngines.packageManager` / `packageManager` in `package.json` (needs `jq` on the runner), else exactly one root lockfile (`yarn.lock` / `pnpm-lock.yaml` / `package-lock.json` or `npm-shrinkwrap.json`); no match, an ambiguous match or an unsupported value fails the job. Drives pnpm provisioning and, in the jobs that configure one, the package-manager dependency cache (`node-pm-cache`: restored on every event, saved only off pull requests) — set `install-command` to match (e.g. `pnpm install --frozen-lockfile`). Resolving to `pnpm` also requires a pnpm version in `package.json`. See [Package manager](../../README.md#package-manager). |
| `build-command`               | no       | `''`                                       | Optional workspace JS build command run at repo root before the native build. |
| `rct-use-prebuilt-rncore`     | no       | `false`                                    | Exports `RCT_USE_PREBUILT_RNCORE=1` for the `expo prebuild` step, `pod install`, and the build step when `true`; exports nothing at all otherwise (an empty export reads as *enabled* on the Ruby side). |
| `rct-use-rn-dep`              | no       | `false`                                    | Exports `RCT_USE_RN_DEP=1` for the `expo prebuild` step, `pod install`, and the build step when `true`; exports nothing at all otherwise (an empty export reads as *enabled* on the Ruby side). |
| `expo-use-precompiled-modules` | no     | `false`                                    | Exports `EXPO_USE_PRECOMPILED_MODULES=1` for the `expo prebuild` step, `pod install`, and the build step when `true`; exports nothing at all otherwise (an empty export reads as *enabled* on the Ruby side). |
| `ccache-max-size`             | no       | `2G`                                       | Bounded, compressed ccache maximum size. |
| `build-env`                   | no       | `''`                                       | Newline-separated `KEY=VALUE` pairs appended to `$GITHUB_ENV` at the start of the build job. Rejects (fails closed) any line without `=` or whose name does not match `^[A-Za-z_][A-Za-z0-9_]*$`. |
| `build-strategy`              | no       | `auto`                                     | How this pull request gets the binary its Maestro shards install. `auto` computes the native key, looks up the base binary published for it, and repacks that base with this commit's JavaScript on the Linux pool; only a key with no published base reaches the Mac — and when it does on the default branch, the base it builds is published for the next run. `repack` refuses to compile native code at all: a missing base fails the build instead of quietly taking a Mac slot. `native` is the escape hatch and a regression — every pull request then compiles native code again, and that run publishes no base. See [Build strategy](#build-strategy) and [docs/repack.md](../repack.md). |
| `repack-runner-labels`        | no       | `["self-hosted","trf-linux-amd64-2x4"]`    | JSON array of self-hosted runner labels for the `plan`/repack job. The default is the 2 vCPU / 4 GiB x86_64 pool without `/dev/kvm`, so these jobs never queue on the KVM emulator lane ([#169](https://github.com/rnw-community/mobile-ci/issues/169)); keep it x86_64 (Google ships Android build-tools for x86_64 Linux only) and move to the 4x8 pool if bundling the JavaScript needs more than about 3 GiB. |
| `native-build-label`          | no       | `mobile: force native build`               | Pull-request label forcing `build-strategy: native` for that one pull request. Set together with `build-strategy: repack` it fails closed rather than silently picking a winner. |
| `base-backend`                | no       | `ghcr`                                     | Where base binaries live: `ghcr` (an immutable OCI artifact needing `packages: write` to publish and `packages: read` to fetch) or `artifact` (workflow artifacts, default-branch runs only, needing `actions: read`). See [`expo-base-binary`](../../actions/expo-base-binary). |
| `base-flavor`                 | no       | `e2e`                                      | Flavor segment of the base binary's address. |
| `fingerprint-config`          | no       | `fingerprint.config.js`                    | Path, relative to a target's `appDir`, of the `@expo/fingerprint` config whose ignore list is the correctness boundary of every repack. Its hash is part of the native key. See [docs/repack.md](../repack.md). |
| `fingerprint-env`             | no       | `''`                                       | Newline-separated `KEY=VALUE` pairs exported while the native key is computed, for an `app.config` that branches on env. Must be byte-identical to what the warm-up passes, or the two never agree on a key and every pull request takes a Mac slot. |
| `repack-env`                  | no       | `''`                                       | Newline-separated `KEY=VALUE` pairs exported for the re-bundle, so the consumer's `app.config` writes this build's API URL, version and build number into the repacked binary. |
| `expect-config`               | no       | `''`                                       | Newline-separated `<dotted.path>=<value>` assertions the repacked binary's embedded `app.config` must satisfy exactly. Every value `repack-env` is expected to have rewritten belongs here: a config rewrite nobody checked is a repack nobody can trust. |
| `repack-app-version`          | no       | `0.7.2`                                    | Pinned `@expo/repack-app` npm version. |
| `repack-timeout-minutes`      | no       | `30`                                       | `plan`/repack job timeout. |
| `build-timeout-minutes`       | no       | `60`                                       | Build job timeout. |
| `test-timeout-minutes`        | no       | `75`                                       | Test job timeout. |
| `tolerate-test-failures`      | no       | `false`                                    | `true` keeps the test job green when the Maestro run step fails, and reports the failure as a `::warning::` instead. For a time-boxed quarantine of a known-broken suite, usually passed per target from the caller (e.g. `${{ matrix.package == 'flaky' }}`). |

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
              run: echo "ios-maestro: $RESULT"
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
        uses: rnw-community/mobile-ci/.github/workflows/ios-maestro.yml@v4.2.0 # v4.2.0
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

This workflow never touches a signing credential or an
Expo/EAS token. It does need a **token permission** the caller grants; see
[Permissions](#permissions).

## Device Cloud driver

`ios-driver: device-cloud` keeps the plan, build and repack half of this
workflow and replaces only the test leg. The test job runs on
`device-cloud-runner-labels` (default: the `repack-runner-labels` Linux pool).
It needs no simulator, KVM or binder there, and it skips the architecture check and `setup-xcode-pinned`. It then
runs [`run-maestro-device-cloud`](../../actions/run-maestro-device-cloud/README.md)
against the same unpacked `Base.app` the local driver would install. That action:

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
        uses: rnw-community/mobile-ci/.github/workflows/ios-maestro.yml@v4.2.0 # v4.2.0
        with:
            targets: ...
            flows-dir: apps/mobile/e2e/flows
            ios-driver: device-cloud
        secrets:
            device-cloud-api-key: ${{ secrets.DEVICE_CLOUD_API_KEY }}
```

## Build strategy

A pull request should not compile native code. Its native surface is almost
always identical to the default branch's, so the only thing that actually
changed is JavaScript — and swapping JavaScript into an already-built binary is
a Linux job measured in minutes, not a Mac build measured in tens of them.
Three actions state that: [`expo-native-key`](../../actions/expo-native-key)
computes the one key a base is addressed by,
[`expo-base-binary`](../../actions/expo-base-binary) fetches or publishes the
base under that key, and [`expo-repack`](../../actions/expo-repack) turns the
base into this commit's binary and asserts the result. The whole contract,
including what `fingerprint.config.js` must ignore and what it must not, is in
[docs/repack.md](../repack.md).

**`auto` (the default).** The `plan` job computes the target's native key and
asks for the base published under it.

- *First run on a new native surface (no base yet).* The lookup reports
  `found=false`, the target lands in the plan's `native-targets` output, and
  the `build` job compiles it on the Mac exactly as v2 did. When that run is on the default
  branch, it then **publishes** the base binary it built under that key. The
  **next** run — every pull request on that same native surface — finds the
  base and repacks, taking no Mac slot at all. A `found=false` is the signal to
  build; a lookup that *cannot tell* (registry error, artifacts API failure)
  fails the job instead, because an unreadable store is not an absent base.
- *Every subsequent run.* The base is found, `expo-repack` re-bundles this
  commit's JavaScript into it on the Linux pool, the assertions in
  `expect-config` are checked, and the repacked app is uploaded for the test
  shards. The `build` job's matrix is empty and no Mac is touched.

A pull request never publishes a base: publishing only happens when
`github.ref_name` is the repository's default branch. So after a change that
moves the native surface — an Expo or React Native upgrade, a new native
module — warm the new key by letting this workflow run once on the default
branch (the merge itself, or a `workflow_dispatch`/scheduled run of your
caller on it); the first pull request afterwards already repacks. Only that
first run pays for a Mac.

A dedicated warm-up is cheaper than letting the full e2e pipeline do it:
[`seed-native-cache.yml`](seed-native-cache.md) plans on Linux, builds only the
keys with no base, publishes them, and runs no Maestro shards at all. Wire it on
a default-branch push with a `paths:` filter — see
[docs/repack.md](../repack.md#the-warm-up).

**`repack`.** The same lookup, but compiling native code is forbidden: a
missing base fails the `plan` job with the key it looked for, rather than
quietly queueing a Mac build. Use it where a Mac slot is a scarce resource you
would rather see a red check than silently consume.

**`native`.** Every target compiles native code and the run publishes no base.
This is the escape hatch, and using it is a **regression**: it is the v2
behaviour, it costs a full native build per pull request, and the run emits a
`::warning::` saying so. Reach for it only to prove a repack-specific
suspicion, and take it back out. The same escape hatch is available per pull
request, without editing the caller, by applying the `native-build-label`
label (default `mobile: force native build`); combining that label with
`build-strategy: repack` fails closed instead of picking a winner.


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
  host, on Linux, before a Mac is involved at all.
- **`repack-on-hit: false`** — remove the input (it no longer exists and a
  caller that still passes it fails workflow validation). The default
  `build-strategy: auto` is what you want. It is *not* the same as v2: v2
  compiled unless the same host held a cache entry, while `auto` repacks a
  base published by any run. `build-strategy: native` compiles every target
  every time — strictly worse than both, and a regression to undo rather than
  a setting to keep.
- **The calling job now needs `permissions:`** — see below. This is the one
  step that silently breaks a `repack-on-hit` caller that changed nothing else.
- `repack-app-version` survives with the same default and now applies to every
  repack, not just a cache hit.

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
| `SIMULATOR_UDID`        | UDID of the booted simulator this shard drives.                         |
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
        uses: rnw-community/mobile-ci/.github/workflows/ios-maestro.yml@v3.3.1 # v3.3.1
        with:
            targets: >-
                [{"name":"bare","appDir":"apps/mobile","workspace":"MyApp.xcworkspace","scheme":"MyApp","appId":"com.example.app","prebuildCommand":""}]
            flows-dir: apps/mobile/e2e/flows
            pre-flow-command: |
                fixture=$(sed -n "s/.*FIXTURE_ROW_ID_MATCH: '\(.*\)\.db'.*/\1/p" "$FLOW_PATH" | tail -n 1)
                [ -n "$fixture" ] || exit 0
                container=$(xcrun simctl get_app_container "$SIMULATOR_UDID" "$APP_ID" data)
                xcrun simctl terminate "$SIMULATOR_UDID" "$APP_ID" || true
                cp "$container/Documents/E2EFixtures/$fixture.db" "$container/Documents/SQLite/app.db"
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

## Concurrency

The workflow sets its own `concurrency` group of the caller's workflow name,
the `flows-dir` input and, for a `pull_request` run, the pull request's ref. Only a
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

## x86_64 simulator builds

Some native SDKs (ML Kit, for one) ship no arm64-simulator slice, so the app
only builds for an x86_64 Simulator. Set `ios-simulator-archs: x86_64` on
this workflow **and** on `seed-native-cache.yml` (and `store-screenshots.yml`
if you capture screenshots):

- The build passes `archs: x86_64` and `excluded-archs: arm64` to
  `build-ios-app`.
- The native key gets an extra `ios-simulator-archs=x86_64` component, so the
  x86_64 base is published and looked up under its own key. The default
  `arm64` adds nothing to the key, so switching an app *back* to arm64 lands
  on exactly the bases it published before.
- The test job's host check accepts an x86_64 macOS runner, or an arm64 one
  with Rosetta 2 installed (`softwareupdate --install-rosetta
  --agree-to-license`); it fails closed otherwise, before a simulator boots.
  The x86_64 app then runs on the arm64 host's simulator under Rosetta.

## Permissions

**The calling job must declare its own `permissions:` block.** A reusable
workflow's job-level `permissions:` can only *narrow* the token its caller
granted — it can never add a scope. The `plan` job asks for `packages: read` +
`actions: read` and the `build` job for `packages: write`, but in a repository
whose default workflow token permission is **read** (the GitHub default for new
organisations) those requests resolve to nothing.

What that costs depends on the scope. Without `packages: write`, a base that is
already published is still fetched and repacked — only the publish on a
default-branch run fails, so a *newly moved* native key never gets warmed and
every run on it compiles until the permission is granted. Without read access
at all, `expo-base-binary` fails the lookup closed rather than calling the
store empty: an unreadable store is not an absent base. Neither reads as a
permissions problem from the outside, which is why it is called out here.

Grant them on the job that calls this workflow:

```yaml
jobs:
    e2e:
        permissions:
            contents: read
            packages: write
            actions: read
        uses: rnw-community/mobile-ci/.github/workflows/ios-maestro.yml@v3.3.1 # v3.3.1
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

This workflow still never writes to the repository and never needs a signing
credential or an Expo/EAS token.

## Example

```yaml
# .github/workflows/ios-maestro.yml
name: iOS Maestro E2E
on:
    workflow_dispatch:
    pull_request:
    push:
        branches: [main]
    schedule:
        - cron: '17 3 * * *'
concurrency:
    group: ios-maestro-${{ github.event_name == 'pull_request' && github.ref || github.run_id }}
    cancel-in-progress: ${{ github.event_name == 'pull_request' }}
jobs:
    e2e:
        # Required: a reusable workflow can only narrow what the caller grants.
        permissions:
            contents: read
            packages: write
            actions: read
        uses: rnw-community/mobile-ci/.github/workflows/ios-maestro.yml@v3.3.1 # v3.3.1
        with:
            targets: >-
                [{"name":"bare","appDir":"apps/mobile","workspace":"MyApp.xcworkspace","scheme":"MyApp","appId":"com.example.app","prebuildCommand":""}]
            flows-dir: apps/mobile/e2e/flows
            target-packages: |
                @myorg/mobile-app
            build-command: yarn build --filter=@myorg/mobile-app
            # build-strategy: auto is the default — repack on Linux, compile
            # on a Mac only for a native key with no published base.
            repack-env: |
                API_URL=https://staging.example.com
                APP_VERSION=1.2.3
            expect-config: |
                extra.apiUrl=https://staging.example.com
                version=1.2.3
```

`fingerprint-env` must pass exactly what the default-branch warm-up passes; a
single differing byte gives the pull request a different native key, and every
pull request takes a Mac slot again.

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
        uses: rnw-community/mobile-ci/.github/workflows/ios-maestro.yml@<full-commit-sha> # <next release>
        with:
            force-label: e2e:force
```

The label is read from the triggering event's payload, so it applies to every
later push to the pull request until it is removed.
