# run-maestro-android-redroid

Boots **Redroid** (Android-in-a-privileged-container over the `binder_linux`
kernel module) instead of an AVD emulator, waits for `sys.boot_completed`
before installing, installs the packaged `.apk`, runs a Maestro flow shard,
and — regardless of pass/fail — captures a final screenshot plus full, crash,
and app-filtered logcat and a foreground-activity dump, uploaded as an
artifact. Every `maestro test` invocation in the shard is pointed
(`--debug-output`) at a scratch directory private to this shard run —
rather than Maestro's shared, unscoped `~/.maestro/tests/<timestamp>`
default, which a concurrent shard on the same persistent self-hosted runner
could otherwise also be writing into. When any flow in the shard failed,
only the **failing** flows' debug output (UI hierarchy dumps and per-flow
screenshots, covering every attempt of the flow plus the recovery-flow runs
that followed it) is staged, one gzipped tarball per flow at
`maestro-debug/<flow>.tar.gz`. Bundles are staged in flow-execution order
for as long as they fit a 200MB *compressed* total; one that would exceed
the cap is dropped with a `::warning::` naming the flow and its compressed
size while the smaller remaining bundles are still tried. Debug output no
flow claims — Maestro keys its output by `maestro test` invocation
timestamp, not by flow name — is bundled last as
`maestro-debug/unattributed.tar.gz` rather than discarded. Because the
explicit `--debug-output`
flag takes precedence, a caller-exported `MAESTRO_DEBUG_OUTPUT_DIRECTORY`
environment variable is deliberately **not** honored by the shard's
`maestro test` invocations — debug output always lands in the uploaded
artifact as described above, so no fallback "copy `~/.maestro/tests`" step
is needed on the caller's side. The container is always removed at the
end (`if: always()`), and its Docker log and inspect dump
(`redroid-container.log` / `redroid-container-inspect.json`) are captured
into the artifact first — including when the container never became
adb-reachable at all.

Use this instead of `run-maestro-android` on hosts where the AVD emulator
cannot run at all — Google publishes no `linux-aarch64` build of the Android
emulator, NDK, or `cmake` packages, so `reactivecircus/android-emulator-runner`
is structurally unusable on `linux-aarch64` self-hosted runners regardless of
tuning. Redroid needs no `sdkmanager`, no NDK, no emulator binary — just a
container image and the host's `binder_linux` module — and runs at native
`arm64` speed with no virtualization inside the guest at all.

A host-side prewarm step (pulled image + a `/data` volume booted once with
animations disabled, manifest written to `prewarm-manifest-path`) makes shard
starts fast. Concurrent matrix cells all read the same manifest, so its
`dataDir` is copied into a per-shard directory under `RUNNER_TEMP` rather than
bind-mounted directly — two Redroid containers writing to the same live
`/data` on the host would corrupt it. A missing manifest does not fail the
shard either: the action falls back to an in-workflow `docker pull` of
`image` and a fresh (uncopied) data volume under `RUNNER_TEMP`, paying for a
cold `docker pull` and Android first boot instead. The one thing that
fallback cannot self-heal is the `binder_linux` kernel module itself —
host-kernel provisioning, not something a job can safely install unattended —
so a missing module fails the shard with an explicit, actionable error
instead of a confusing `docker run` failure. All three Android animation
scales (window/transition/animator) are forced to `0` after boot
unconditionally, since a prewarmed volume already having them off does not
help the cold-start fallback path.

`container-name` has no default: pass a value that distinguishes this matrix
cell from its siblings (e.g. incorporating `matrix.target.name` and
`matrix.shard-index`, or GitHub's own `strategy.job-index`). It only needs to
be unique *within* the calling run — the action itself appends
`GITHUB_RUN_ID`/`GITHUB_RUN_ATTEMPT` before using it, so two concurrent
workflow runs (the same repo or a different one sharing the same runner pool)
never collide even if they compute the same base. The container and its data
directory (`RUNNER_TEMP/redroid-data/<the run-scoped name>`) are removed in
the `if: always()` teardown step, so this run-scoping doesn't leak one
directory per run forever on a persistent self-hosted runner.

**Maestro's hidden debug path lives inside the bundles.** Maestro writes its
debug output into a hidden `.maestro/tests/<timestamp>/` path, and
`actions/upload-artifact` skips hidden files by default — which used to ship
`final-screen.png` alone and drop the very UI hierarchy dumps the failure
message tells you to inspect. Each staged `maestro-debug/<flow>.tar.gz` is a
visible file that keeps that path *inside* the archive, so no hidden entry is
staged at all; the upload step still sets `include-hidden-files: true` for the
rest of the artifact. Expand a bundle with
`tar -xzf maestro-debug/<flow>.tar.gz`.

There is no `adb-port` input. The container publishes 5555 on loopback with
an OS-assigned ephemeral host port (`docker run -p 127.0.0.1::5555`) rather
than a port this action or its caller picks — asking the kernel for "any free
port" is atomic, unlike a "probe with `ss`, then bind" check, which is a
TOCTOU race a concurrent shard can still lose. The action reads back whichever
port Docker assigned (`docker port <container> 5555/tcp`) and uses that for
every later `adb` call. This also means Redroid's adb port is never reachable
from outside the runner itself.

## Maestro workspace config

Maestro only auto-discovers a workspace `config.yaml` when the CLI is pointed
at a **directory**. This action always resolves flows itself and passes the
CLI an individual flow file per invocation, so a workspace config sitting next
to those flows is never read and nothing warns about it. Point
`maestro-config` at that file and it is passed as `--config` to **every**
`maestro test` this action runs — shard flows, `pre-run-flow` and
`flow-recovery-flow` alike.

The case that motivated the input is iOS-specific, but the mechanism is not —
any workspace-level `platform:` / `flows:` / tag setting is dropped the same
way. An `@expo/ui` SwiftUI `.sheet()` modal renders its React Native content
outside the app's main window, so the XCUITest hierarchy Maestro snapshots
never contains it and every selector inside the sheet times out at its
assertion budget. The fix lives entirely in the workspace config —

```yaml
platform:
    ios:
        snapshotKeyHonorModalViews: false
```

— and is inert unless `--config` actually reaches the CLI.

## Inputs

| Name                     | Required | Default                              | Description                                                                             |
| ------------------------- | -------- | ------------------------------------- | ------------------------------------------------------------------------------------------ |
| `image`                   | no       | `redroid/redroid:15.0.0_64only-latest` | Redroid image tag, used only on a prewarm-manifest miss. Verified against a 6.17 host kernel — older `13.x` tags are known to never finish boot on that kernel, and `14.x` images hard-lock the guest kernel version. |
| `container-name`          | yes      | —                                      | Docker container name base, distinguishing this cell from siblings in the same run; the action appends the run id/attempt automatically. |
| `apk-path`                | yes      | —                                      | Path to the packaged `.apk` to install.                                                     |
| `app-id`                  | yes      | —                                      | Application ID passed to Maestro as `APP_ID`.                                               |
| `flows-dir`               | yes      | —                                      | Directory whose top-level files are the runnable Maestro flows by default. Subdirectories are not searched unless `flows-max-depth` is raised. |
| `flows-max-depth`         | no       | `1`                                    | `find -maxdepth` under `flows-dir`. `0` means unbounded recursion.                          |
| `flows-name-pattern`      | no       | `*.flow.yaml`                          | Space-separated `find -name` globs (OR'd together) selecting runnable flows, at every depth `flows-max-depth` permits. |
| `flows-exclude-pattern`   | no       | `''`                                    | Optional `find ! -name` glob excluding matched flows by basename.                           |
| `shard-manifest-dir`      | no       | `''`                                    | Directory of hand-curated `shard-<index>.txt` files (one `flows-dir`-relative path per line) overriding the index-modulo split. Unset falls back to modulo entirely; once set, every shard-index this job can run must have its own file — a partial manifest fails closed. |
| `shard-index`             | yes      | —                                      | Zero-based shard index this job runs.                                                       |
| `shard-count`             | yes      | —                                      | Total number of shards flows are distributed across.                                        |
| `pre-run-flow`            | no       | `''`                                   | Path to a single priming flow run once before this shard's flows, excluded from sharding. Its failure fails the step immediately. |
| `flow-recovery-flow`      | no       | `''`                                   | Path to a single best-effort recovery flow run after a **failed** flow attempt — before the same flow's next retry attempt, and before the next flow starts — so one failure cannot strand the app in a state that cascades into the flows after it. Never run after a passing attempt, and not after this shard's last flow. Its own failure only logs a `::warning::` and never fails the step. Like `pre-run-flow`, it is removed from the shard's discovered flow list, so it never also runs as a scenario of its own. Its duration is excluded from the per-flow timing table; a line below that table reports how many times it ran and how many of those runs failed. |
| `pre-test-command`        | no       | `''`                                   | Consumer-owned shell command run once after the app is installed on the container and before any flow (including `pre-run-flow`) executes. Runs with `ANDROID_SERIAL`, `APP_ID`, and `APK_PATH` in its environment. Its failure fails the step immediately. |
| `pre-flow-command`        | no       | `''`                                   | Consumer-owned shell command run **before every flow attempt**, each retry included, after `pre-run-flow` and the warm-up. Never run before `pre-run-flow` or `flow-recovery-flow` themselves. Runs with `FLOW_PATH`, `FLOW_NAME`, `APP_ID`, `ANDROID_SERIAL` and `MAESTRO_FLOW_ENV_FILE` in its environment. Unlike the best-effort `flow-recovery-flow` it is a **precondition**: a non-zero exit fails that attempt without running the flow, consuming one of its `1 + flow-retries` attempts and triggering the recovery flow like any other failed attempt. Every `KEY=VALUE` line it appends to `$MAESTRO_FLOW_ENV_FILE` becomes an extra `-e KEY=VALUE` argument for that one flow's `maestro test` — see [Per-flow preconditions](#per-flow-preconditions). |
| `app-warm-seconds`        | no       | `20`                                   | Seconds the app is left running during a one-off warm-up (launch via `monkey`, settle, `am force-stop`) performed after install and before `pre-test-command` or any flow runs, so first-launch cold-start cost is not absorbed by the first flow's own timeout budget. `0` disables warming. The launch is best-effort: on some images (Redroid) `monkey` exits non-zero even after starting the app, so a non-zero status only warns. The trailing `am force-stop` is likewise ignored if it returns non-zero. |
| `maestro-env`             | no       | `''`                                   | Newline-separated `KEY=VALUE` pairs, each passed as an additional `-e KEY=VALUE` argument to every `maestro test` invocation (`pre-run-flow` and shard flows alike). Rejects (fails closed) any line without `=` or whose name does not match `^[A-Za-z_][A-Za-z0-9_]*$`. |
| `maestro-config`           | no       | `''`                                    | Path to the consumer's Maestro workspace config (`config.yaml`), passed as `--config` to every `maestro test` invocation. Maestro only auto-discovers a workspace `config.yaml` when it is pointed at a **directory**, and this action always passes individual flow files, so without this input a workspace config is silently ignored — see [Maestro workspace config](#maestro-workspace-config). Relative paths resolve against the job's working directory. Fails closed when set to a path that is not a file. |
| `flow-retries`            | no       | `0`                                    | Non-negative retry budget per flow; each flow gets up to `1 + flow-retries` attempts.        |
| `maestro-version`         | no       | `2.8.0`                                | Pinned Maestro CLI version. Installed by downloading the matching `cli-<version>` release directly from [mobile-dev-inc/Maestro releases](https://github.com/mobile-dev-inc/Maestro/releases) to `$HOME/.maestro-pinned/<version>` — immune to a pre-existing Homebrew-managed `maestro` on the host. An existing `maestro` already on `PATH` is reused only when its version exactly matches. |
| `memory`                  | no       | `3g`                                   | Container memory limit (`docker --memory` / `--memory-swap`).                               |
| `cpus`                    | no       | `2`                                    | Container CPU limit (`docker --cpus`).                                                      |
| `prewarm-manifest-path`   | no       | `$HOME/.rnw-ci/android-emulator.json`  | Host-side prewarm manifest (`{"image", "dataDir"}`); absent means a cold in-workflow pull.  |
| `boot-timeout-seconds`    | no       | `600`                                  | Seconds to wait for `sys.boot_completed` before failing the shard.                          |
| `artifacts-dir`           | yes      | —                                      | Directory final-state capture (screenshot, logcat) is written to.                           |
| `artifact-name`           | yes      | —                                      | Uploaded artifact name.                                                                      |
| `retention-days`          | no       | `7`                                    | Uploaded artifact retention in days.                                                         |

A per-flow timing table (flow, duration, status, attempts) is appended to
`$GITHUB_STEP_SUMMARY` after every shard run, including a priming-flow row
when `pre-run-flow` is set. Time spent in `flow-recovery-flow` is excluded
from those rows; when a recovery flow is configured, a line below the table
reports how many times it ran and how many of those runs failed.

The resolved flow list (before sharding) is logged to the step output before
selection, so a consumer can confirm
`flows-max-depth`/`flows-name-pattern`/`flows-exclude-pattern` resolved to
the intended set.

`flow-recovery-flow` runs after **every failed attempt** — before the same
flow's next retry attempt, and before the shard moves on to the next flow —
so a failure cannot strand the app in a state that fails the flows after it.
It never runs after a passing attempt, and it is skipped after the shard's
last flow. It is invoked exactly like `pre-run-flow` (same `-e APP_ID=…`,
`--debug-output`, and `maestro-env` passthrough), and it is **best-effort**:
a failing recovery only emits a `::warning::` and the shard continues. One
file can chain everything the app needs with `runFlow`, e.g. suuudokuuu's
state reset plus deep-link prime:

```yaml
# e2e/flows/setup/recover-after-failure.flow.yaml
appId: ${APP_ID}
---
- runFlow: reset-app-state.flow.yaml
- runFlow: prime-deep-links.flow.yaml
```

Like `pre-run-flow`, it is filtered out of the shard's discovered flow list by
file identity, so it never also runs as an ordinary scenario — even when it
sits at the top level of `flows-dir` or `flows-max-depth` is raised past the
subdirectory it lives in.

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
# @main until the release that ships pre-flow-command, then pin to that tag
- uses: rnw-community/mobile-ci/actions/run-maestro-android-redroid@main
  with:
      container-name: redroid-e2e-${{ strategy.job-index }}
      apk-path: ./build/app-release.apk
      app-id: com.example.app
      flows-dir: e2e/flows
      shard-index: ${{ matrix.shard-index }}
      shard-count: 2
      artifacts-dir: ${{ github.workspace }}/artifacts/maestro-android-bare-${{ matrix.shard-index }}
      artifact-name: maestro-android-bare-shard-${{ matrix.shard-index }}
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

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/run-maestro-android-redroid@v1
  with:
      container-name: redroid-e2e-${{ strategy.job-index }}
      apk-path: .ci-artifacts/android-e2e-app-bare/app-release.apk
      app-id: com.example.app
      flows-dir: apps/mobile/e2e/flows
      shard-index: ${{ matrix.shard-index }}
      shard-count: 2
      artifacts-dir: ${{ github.workspace }}/artifacts/maestro-android-bare-${{ matrix.shard-index }}
      artifact-name: maestro-android-bare-shard-${{ matrix.shard-index }}
```
