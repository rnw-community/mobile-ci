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
| `build-runner-labels`         | no       | `''`                                       | JSON array of self-hosted runner labels for the build job only. Falls back to `runner-labels` when empty; set this and `test-runner-labels` together to split build/test across separate runner pools. |
| `test-runner-labels`          | no       | `''`                                       | JSON array of self-hosted runner labels for the test job only. Falls back to `runner-labels` when empty. |
| `targets`                     | **yes**  | —                                          | JSON array of build targets: `{name, appDir, workspace, scheme, appId, prebuildCommand}`. `prebuildCommand` may be an empty string. |
| `flows-dir`                   | **yes**  | —                                          | Directory (relative to repo root) whose top-level files are the runnable Maestro flows by default. Subdirectories are not searched unless `flows-max-depth` is raised. |
| `flows-max-depth`             | no       | `1`                                        | `find -maxdepth` under `flows-dir`. `0` means unbounded recursion. Default keeps subflows (invoked via `runFlow`, conventionally in subdirectories) out of the shard. |
| `flows-name-pattern`          | no       | `*.flow.yaml`                              | Space-separated `find -name` globs (OR'd together) selecting runnable flows directly inside `flows-dir`. Keeps reusable subflows and capture-only flows in subdirectories out of the shard by default. |
| `flows-exclude-pattern`       | no       | `''`                                       | Optional `find ! -name` glob excluding matched flows by basename. |
| `shard-manifest-dir`          | no       | `''`                                       | Optional directory (relative to repo root) of hand-curated `shard-<index>.txt` files (one `flows-dir`-relative flow path per line) overriding the computed index-modulo split. Unset falls back to modulo entirely; once set, every shard-index this job can run must have its own file — a partial manifest fails closed. |
| `pre-run-flow`                | no       | `''`                                       | Path to a single priming flow run once before each shard's flows, excluded from sharding. Its failure fails that shard immediately. |
| `flow-recovery-flow`          | no       | `''`                                       | Path to a single best-effort recovery flow run after a **failed** flow attempt — before the same flow's next retry attempt, and before the next flow starts — so one failure cannot strand the app in a state that cascades into the flows after it. Never run after a passing attempt, and not after a shard's last flow. Its own failure only logs a `::warning::` and never fails the shard. Like `pre-run-flow`, it is removed from the shard's discovered flow list, so it never also runs as a scenario of its own. Its duration is excluded from the per-flow timing table; a line below that table reports how many times it ran and how many of those runs failed. |
| `pre-test-command`            | no       | `''`                                       | Optional consumer-owned shell command run once after the app is installed on the simulator and before any flow (including `pre-run-flow`) executes, e.g. seeding a fixture into the app's data container. Runs with `SIMULATOR_UDID`, `APP_ID`, and `APP_PATH` in its environment. Its failure fails that shard immediately. |
| `pre-flow-command`            | no       | `''`                                       | Consumer-owned shell command run **before every flow attempt**, each retry included, after `pre-run-flow` and the warm-up. Never run before `pre-run-flow` or `flow-recovery-flow` themselves. Runs with `FLOW_PATH`, `FLOW_NAME`, `APP_ID`, `SIMULATOR_UDID` and `MAESTRO_FLOW_ENV_FILE` in its environment. Unlike the best-effort `flow-recovery-flow` it is a **precondition**: a non-zero exit fails that attempt without running the flow, consuming one of its `1 + flow-retries` attempts and triggering the recovery flow like any other failed attempt. Every `KEY=VALUE` line it appends to `$MAESTRO_FLOW_ENV_FILE` becomes an extra `-e KEY=VALUE` argument for that one flow's `maestro test` — see [Per-flow preconditions](#per-flow-preconditions). |
| `maestro-env`                 | no       | `''`                                       | Newline-separated `KEY=VALUE` pairs, each passed as an additional `-e KEY=VALUE` argument to every `maestro test` invocation (`pre-run-flow` and shard flows alike). Rejects (fails closed) any line without `=` or whose name does not match `^[A-Za-z_][A-Za-z0-9_]*$`. |
| `maestro-config`              | no       | `''`                                       | Path to the consumer's Maestro workspace config (`config.yaml`), passed as `--config` to every `maestro test` invocation. Maestro only auto-discovers a workspace `config.yaml` when it is pointed at a **directory**, and the actions below always pass individual flow files, so without this input a workspace config is silently ignored — e.g. `platform.ios.snapshotKeyHonorModalViews: false`, which an `@expo/ui` SwiftUI `.sheet()` modal needs before its React Native content appears in the XCUITest hierarchy at all. Relative paths resolve against the job's working directory. Fails closed when set to a path that is not a file. |
| `flow-retries`                | no       | `0`                                        | Non-negative retry budget per flow; each flow gets up to `1 + flow-retries` attempts. |
| `app-warm-seconds`            | no       | `20`                                       | Seconds the app is left running during a one-off warm-up (`simctl launch`, settle, `simctl terminate`) performed after install and before `pre-test-command` or any flow runs, so first-launch cold-start cost is not absorbed by the first flow's own timeout budget. `0` disables warming. |
| `shard-count`                 | no       | `2`                                        | Number of test shards per target. |
| `xcode-version`               | no       | `26.4.1`                                   | Xcode version string, e.g. `26.4.1`. |
| `xcode-build`                 | no       | `17E202`                                   | Xcode build number, e.g. `17E202`. |
| `turbo-version`               | no       | `2.10.8`                                   | Pinned turbo npm version used by the detect job. |
| `target-packages`             | no       | `''`                                       | Newline-separated package names gating this pipeline on `pull_request` events. |
| `expo-fingerprint-version`    | no       | `0.20.6`                                   | Pinned `@expo/fingerprint` npm version. |
| `maestro-version`             | no       | `2.10.0`                                   | Pinned Maestro CLI version. |
| `maestro-reuse-driver`        | no       | `true`                                     | `true` passes `--no-reinstall-driver` and one `--driver-host-port`, picked free on `127.0.0.1` when the shard starts, to every `maestro test` invocation of the shard (pre-run flow, flows, retries, recovery flow): the XCTest driver the first invocation starts keeps running and every later invocation reuses it instead of starting its own. Each flow is still its own invocation, so `pre-flow-command`, per-flow env, retries, the recovery flow and the timing rows are unchanged. `false` starts a fresh driver per invocation. |
| `simulator-device`            | no       | `''`                                       | Exact simulator device name to boot (e.g. `iPhone 17 Pro`), matched against `xcrun simctl list devices available` with no fuzzy matching — fails closed, listing available devices, on no exact match. Empty keeps the previous last-available heuristic (emits a `::notice::` naming its choice and recommending pinning). |
| `simulator-reduce-motion`     | no       | `false`                                    | `true` turns on the booted simulator's Reduce Motion accessibility setting (`com.apple.Accessibility ReduceMotionEnabled`) before the app is installed and first launched, so UIKit, React Native `AccessibilityInfo` and Reanimated skip their animations. Fails closed on any value other than `true`/`false`. |
| `simslim-version` | no | `0.10.0` | Pinned simslim CLI version, consulted only when `simulator-slim-profile` or `simulator-requires` is set. A `simslim` already on PATH is reused on an exact `simslim version` match; otherwise the `simslim-v<version>-macos-arm64.tar.gz` asset is downloaded from [MobAI-App/simslim releases](https://github.com/MobAI-App/simslim/releases) into `$HOME/.simslim-pinned`, verified against `simslim-sha256`, and extracted per job; preinstall on the host to avoid it. |
| `simslim-sha256` | no | `eec00b27f069...` | SHA-256 of the `simslim-v<simslim-version>-macos-arm64.tar.gz` release asset (default: the v0.10.0 digest, maintained here because upstream publishes no checksum file). The tarball cached under `$HOME/.simslim-pinned` is re-hashed against it on every job before the binary is extracted into a job-private directory, so no previously extracted executable is reused. Empty refuses to download, so only a preinstalled `simslim` of the exact version satisfies the job. Bump together with `simslim-version`. |
| `simulator-slim-profile` | no | `bundled` | `bundled` uses mobile-ci's own [`profiles/ci.json`](../../profiles/ci.json) (App Store/push/StoreKit and Safari/universal-link services on, every other category off), so a consumer commits no profile of its own; a repository-relative path uses that profile instead. The booted simulator is checked with `simslim verify --profile` before the app is installed; any drift fails closed unless `simulator-slim-repair` is `true`. Empty opts out of slimming. See [Every simulator runs slim](../../docs/self-hosted-runners.md#every-simulator-runs-slim). |
| `simulator-slim-repair` | no | `true` | `true` (the default) re-applies the profile in-job with `simslim on` (reboots the simulator) when `simulator-slim-profile` reports drift, then verifies again; a second mismatch still fails. Set it to `false` once the host image ships slimmed devices. |
| `simulator-requires` | no | `''` | Comma-separated simslim feature IDs the flows depend on (e.g. `push,universal-links`; `simslim doctor --list`). When set, `simslim doctor --requires` runs against the booted simulator and fails closed if slimming disabled a daemon behind any of them. Works without a profile. |
| `node-version`                | no       | `22.x`                                     | Node version for `actions/setup-node`. |
| `install-command`             | no       | `yarn install --immutable`                 | JS dependency install command. |
| `enable-corepack`             | no       | `true`                                     | Run `corepack enable` before install. Skipped when the resolved package manager is `pnpm` (provisioned by `pnpm/action-setup`). |
| `package-manager`             | no       | `''` (auto-detect)                         | Override the JS package manager (`yarn`, `pnpm`, `npm`). Empty auto-detects at the repo root: `devEngines.packageManager` / `packageManager` in `package.json` (needs `jq` on the runner), else exactly one root lockfile (`yarn.lock` / `pnpm-lock.yaml` / `package-lock.json` or `npm-shrinkwrap.json`); no match, an ambiguous match or an unsupported value fails the job. Drives pnpm provisioning and, in the jobs that configure one, `actions/setup-node`'s `cache:` — set `install-command` to match (e.g. `pnpm install --frozen-lockfile`). Resolving to `pnpm` also requires a pnpm version in `package.json`. See [Package manager](../../README.md#package-manager). |
| `build-command`               | no       | `''`                                       | Optional workspace JS build command run at repo root before the native build. |
| `rct-use-prebuilt-rncore`     | no       | `false`                                    | Exports `RCT_USE_PREBUILT_RNCORE=1` for the `expo prebuild` step, `pod install`, and the build step when `true`; exports nothing at all otherwise (an empty export reads as *enabled* on the Ruby side). |
| `rct-use-rn-dep`              | no       | `false`                                    | Exports `RCT_USE_RN_DEP=1` for the `expo prebuild` step, `pod install`, and the build step when `true`; exports nothing at all otherwise (an empty export reads as *enabled* on the Ruby side). |
| `expo-use-precompiled-modules` | no     | `false`                                    | Exports `EXPO_USE_PRECOMPILED_MODULES=1` for the `expo prebuild` step, `pod install`, and the build step when `true`; exports nothing at all otherwise (an empty export reads as *enabled* on the Ruby side). |
| `ccache-max-size`             | no       | `2G`                                       | Bounded, compressed ccache maximum size. |
| `build-env`                   | no       | `''`                                       | Newline-separated `KEY=VALUE` pairs appended to `$GITHUB_ENV` at the start of the build job. Rejects (fails closed) any line without `=` or whose name does not match `^[A-Za-z_][A-Za-z0-9_]*$`. |
| `build-strategy`              | no       | `auto`                                     | How this pull request gets the binary its Maestro shards install. `auto` computes the native key, looks up the base binary published for it, and repacks that base with this commit's JavaScript on the Linux pool; only a key with no published base reaches the Mac — and when it does on the default branch, the base it builds is published for the next run. `repack` refuses to compile native code at all: a missing base fails the build instead of quietly taking a Mac slot. `native` is the escape hatch and a regression — every pull request then compiles native code again, and that run publishes no base. See [Build strategy](#build-strategy) and [docs/repack.md](../repack.md). |
| `repack-runner-labels`        | no       | `["self-hosted","trf-linux-amd64-4x8"]`    | JSON array of self-hosted runner labels for the `plan`/repack job. The default is the x86_64 Linux pool: a repack re-bundles JavaScript and rewrites an archive, so it needs no Xcode, no simulator and no Mac slot. |
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

No `secrets:` block — this workflow never touches a signing credential or an
Expo/EAS token. It does need a **token permission** the caller grants; see
[Permissions](#permissions).

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
        uses: rnw-community/mobile-ci/.github/workflows/ios-maestro.yml@v3.0.2 # v3.0.2
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
        uses: rnw-community/mobile-ci/.github/workflows/ios-maestro.yml@v3.0.2 # v3.0.2
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
    group: ios-maestro-${{ github.ref }}
    cancel-in-progress: true
jobs:
    e2e:
        # Required: a reusable workflow can only narrow what the caller grants.
        permissions:
            contents: read
            packages: write
            actions: read
        uses: rnw-community/mobile-ci/.github/workflows/ios-maestro.yml@v3.0.2 # v3.0.2
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
