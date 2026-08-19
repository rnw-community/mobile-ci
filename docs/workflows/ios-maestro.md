# ios-maestro.yml

`workflow_call` reusable workflow: iOS Maestro e2e on self-hosted runners.

Four jobs: **detect** (turbo-affected gate + shard-index computation, hosted
`ubuntu-latest`) →
**build** (one job per `targets` entry — Xcode select, native fingerprint,
native-app-cache restore, optional repack-on-hit, ccache, `xcodebuild`,
artifact upload) → **test** (one job per `targets` × `shard-count` — download
the built `.app`, boot a Simulator, run a Maestro flow shard) → **status**
(aggregates detect/build/test into a single required check). `build` and
`test` run on self-hosted macOS by default; `detect` and `status` always run
on `ubuntu-latest`.

The `status` job reports three distinct outcomes, in its log and in
`$GITHUB_STEP_SUMMARY`: **passed**, **failed** (naming the job and result
that broke the run, with a `::notice::` hint when a `cancelled` result
likely means a hit timeout), and **skipped** — every build/test leg skipped
because the target packages were untouched, reported explicitly as "zero
Maestro flows ran (not a pass)" rather than blending into a green check
silently.

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
| `maestro-env`                 | no       | `''`                                       | Newline-separated `KEY=VALUE` pairs, each passed as an additional `-e KEY=VALUE` argument to every `maestro test` invocation (`pre-run-flow` and shard flows alike). Rejects (fails closed) any line without `=` or whose name does not match `^[A-Za-z_][A-Za-z0-9_]*$`. |
| `maestro-config`              | no       | `''`                                       | Path to the consumer's Maestro workspace config (`config.yaml`), passed as `--config` to every `maestro test` invocation. Maestro only auto-discovers a workspace `config.yaml` when it is pointed at a **directory**, and the actions below always pass individual flow files, so without this input a workspace config is silently ignored — e.g. `platform.ios.snapshotKeyHonorModalViews: false`, which an `@expo/ui` SwiftUI `.sheet()` modal needs before its React Native content appears in the XCUITest hierarchy at all. Relative paths resolve against the job's working directory. Fails closed when set to a path that is not a file. |
| `flow-retries`                | no       | `0`                                        | Non-negative retry budget per flow; each flow gets up to `1 + flow-retries` attempts. |
| `app-warm-seconds`            | no       | `20`                                       | Seconds the app is left running during a one-off warm-up (`simctl launch`, settle, `simctl terminate`) performed after install and before `pre-test-command` or any flow runs, so first-launch cold-start cost is not absorbed by the first flow's own timeout budget. `0` disables warming. |
| `shard-count`                 | no       | `2`                                        | Number of test shards per target. |
| `xcode-version`               | no       | `26.4.1`                                   | Xcode version string, e.g. `26.4.1`. |
| `xcode-build`                 | no       | `17E202`                                   | Xcode build number, e.g. `17E202`. |
| `cache-profile`                | no       | `ios-native-v1`                            | Cache-key prefix distinguishing this consumer/app. |
| `turbo-version`               | no       | `2.10.8`                                   | Pinned turbo npm version used by the detect job. |
| `target-packages`             | no       | `''`                                       | Newline-separated package names gating this pipeline on `pull_request` events. |
| `expo-fingerprint-version`    | no       | `0.20.6`                                   | Pinned `@expo/fingerprint` npm version. |
| `maestro-version`             | no       | `2.8.0`                                    | Pinned Maestro CLI version. |
| `simulator-device`            | no       | `''`                                       | Exact simulator device name to boot (e.g. `iPhone 17 Pro`), matched against `xcrun simctl list devices available` with no fuzzy matching — fails closed, listing available devices, on no exact match. Empty keeps the previous last-available heuristic (emits a `::notice::` naming its choice and recommending pinning). |
| `node-version`                | no       | `22.x`                                     | Node version for `actions/setup-node`. |
| `install-command`             | no       | `yarn install --immutable`                 | JS dependency install command. |
| `enable-corepack`             | no       | `true`                                     | Run `corepack enable` before install. |
| `build-command`               | no       | `''`                                       | Optional workspace JS build command run at repo root before the native build. |
| `rct-use-prebuilt-rncore`     | no       | `false`                                    | Exports `RCT_USE_PREBUILT_RNCORE=1` for the `expo prebuild` step, `pod install`, and the build step when `true`; exports nothing at all otherwise (an empty export reads as *enabled* on the Ruby side). |
| `rct-use-rn-dep`              | no       | `false`                                    | Exports `RCT_USE_RN_DEP=1` for the `expo prebuild` step, `pod install`, and the build step when `true`; exports nothing at all otherwise (an empty export reads as *enabled* on the Ruby side). |
| `expo-use-precompiled-modules` | no     | `false`                                    | Exports `EXPO_USE_PRECOMPILED_MODULES=1` for the `expo prebuild` step, `pod install`, and the build step when `true`; exports nothing at all otherwise (an empty export reads as *enabled* on the Ruby side). |
| `ccache-max-size`             | no       | `2G`                                       | Bounded, compressed ccache maximum size. |
| `build-env`                   | no       | `''`                                       | Newline-separated `KEY=VALUE` pairs appended to `$GITHUB_ENV` at the start of the build job. Rejects (fails closed) any line without `=` or whose name does not match `^[A-Za-z_][A-Za-z0-9_]*$`. |
| `repack-on-hit`               | no       | `false`                                    | On a native-app-cache hit, run `repack-app` to inject a freshly exported JS bundle into the cached shell instead of reusing it unchanged. Falls back to a full native build if the repack fails. |
| `repack-app-version`          | no       | `0.7.2`                                    | Pinned `@expo/repack-app` npm version, used only when `repack-on-hit` is true. |
| `build-timeout-minutes`       | no       | `60`                                       | Build job timeout. |
| `test-timeout-minutes`        | no       | `45`                                       | Test job timeout. |

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

When a shard fails, the shard-private `--debug-output` directory (UI hierarchy
dumps, per-flow screenshots) is copied into the uploaded artifact under
`maestro-debug/`, unless the bundle exceeds the 200MB cap — an oversized
bundle is skipped entirely with a `::warning::` and the artifact then holds
only the final-state capture. Maestro writes that bundle behind a hidden
`.maestro/tests/<timestamp>/` path, so staging renames any hidden top-level
entry to a visible `dot-`-prefixed name (suffixed `-1`, `-2`, … if that name
is already taken, so neither tree is lost) and the upload step sets
`include-hidden-files: true` — `actions/upload-artifact` skips hidden files by
default, which previously shipped `final-screen.png` alone and dropped the
hierarchy dumps the failure message points you at.

## Permissions

`contents: read` is sufficient in the caller workflow; this workflow does not
write to the repository.

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
        uses: rnw-community/mobile-ci/.github/workflows/ios-maestro.yml@v1.6.2 # v1.6.2
        with:
            targets: >-
                [{"name":"bare","appDir":"apps/mobile","workspace":"MyApp.xcworkspace","scheme":"MyApp","appId":"com.example.app","prebuildCommand":""}]
            flows-dir: apps/mobile/e2e/flows
            target-packages: |
                @myorg/mobile-app
            build-command: yarn build --filter=@myorg/mobile-app
```
