# run-maestro-android

Boots a **headless** Android emulator (`-no-window -no-audio -gpu
swiftshader_indirect`, no boot animation, no snapshot save), waits for
`sys.boot_completed` before installing, installs the packaged `.apk`, runs a
Maestro flow shard, and — regardless of pass/fail — captures a final
screenshot plus full and crash logcat, uploaded as an artifact. Every
`maestro test` invocation in the shard is pointed (`--debug-output`) at a
scratch directory private to this shard run — rather than Maestro's shared,
unscoped `~/.maestro/tests/<timestamp>` default, which a concurrent shard on
the same persistent self-hosted runner could otherwise also be writing into.
When any flow in the shard failed, that scratch directory (UI hierarchy
dumps and per-flow screenshots) is copied into the artifact under a
`maestro-debug/` subdirectory, capped at 200MB combined — a `::warning::` is
emitted and the copy skipped if the shard's debug output exceeds that.
Because the explicit `--debug-output` flag takes precedence, a
caller-exported `MAESTRO_DEBUG_OUTPUT_DIRECTORY` environment variable is
deliberately **not** honored by the shard's `maestro test` invocations —
debug output always lands in the uploaded artifact as described above, so
no fallback "copy `~/.maestro/tests`" step is needed on the caller's side.
The emulator is always killed at the end (`if: always()`).

Uses `reactivecircus/android-emulator-runner`, which owns the emulator
boot/kill lifecycle; this action supplies the headless flags and a bundled
`scripts/run-shard.sh` that installs the app and runs the shard inside it.
That script lives in its own file rather than inline in `script:` because
`reactivecircus/android-emulator-runner` runs each newline of its `script`
input as an *independent* shell invocation — a multi-line for/while/if
written directly in `script:` would not see state from the line before it.
`run-shard.sh` derives `ANDROID_SERIAL` from `adb devices` right after boot
and exports it for `pre-test-command`'s use.

## Inputs

| Name                | Required | Default       | Description                                                  |
| -------------------- | -------- | ------------- | ------------------------------------------------------------------ |
| `apk-path`           | yes      | —             | Path to the packaged `.apk` to install.                             |
| `app-id`             | yes      | —             | Application ID passed to Maestro as `APP_ID`.                       |
| `flows-dir`             | yes      | —             | Directory whose top-level files are the runnable Maestro flows by default. Subdirectories are not searched unless `flows-max-depth` is raised. |
| `flows-max-depth`       | no       | `1`           | `find -maxdepth` under `flows-dir`. `0` means unbounded recursion. Default keeps subflows (invoked via `runFlow`, conventionally in subdirectories) out of the shard. |
| `flows-name-pattern`    | no       | `*.flow.yaml` | Space-separated `find -name` globs (OR'd together) selecting runnable flows directly inside `flows-dir`. Keeps reusable subflows and capture-only flows in subdirectories out of the shard by default. |
| `flows-exclude-pattern` | no       | `''`          | Optional `find ! -name` glob excluding matched flows by basename.    |
| `shard-manifest-dir`    | no       | `''`          | Directory of hand-curated `shard-<index>.txt` files (one `flows-dir`-relative path per line) overriding the index-modulo split. Unset falls back to modulo entirely; once set, every shard-index this job can run must have its own file — a partial manifest fails closed. |
| `shard-index`        | yes      | —             | Zero-based shard index this job runs.                                |
| `shard-count`        | yes      | —             | Total number of shards flows are distributed across.                 |
| `pre-run-flow`       | no       | `''`          | Path to a single priming flow run once before this shard's flows, excluded from sharding. Its failure fails the step immediately. |
| `flow-recovery-flow` | no       | `''`          | Path to a single best-effort recovery flow run after a **failed** flow attempt — before the same flow's next retry attempt, and before the next flow starts — so one failure cannot strand the app in a state that cascades into the flows after it. Never run after a passing attempt, and not after this shard's last flow. Its own failure only logs a `::warning::` and never fails the step. Unlike `pre-run-flow` it is not removed from the discovered flow list, so keep it in a subdirectory of `flows-dir`. Its duration is excluded from the per-flow timing table; a line below that table reports how many times it ran and how many of those runs failed. |
| `pre-test-command`   | no       | `''`          | Consumer-owned shell command run once after the app is installed on the emulator and before any flow (including `pre-run-flow`) executes. Runs with `ANDROID_SERIAL`, `APP_ID`, and `APK_PATH` in its environment. Its failure fails the step immediately. |
| `app-warm-seconds`   | no       | `20`          | Seconds the app is left running during a one-off warm-up (launch via `monkey`, settle, `am force-stop`) performed after install and before `pre-test-command` or any flow runs, so first-launch cold-start cost is not absorbed by the first flow's own timeout budget. `0` disables warming. |
| `maestro-env`        | no       | `''`          | Newline-separated `KEY=VALUE` pairs, each passed as an additional `-e KEY=VALUE` argument to every `maestro test` invocation (`pre-run-flow` and shard flows alike). Rejects (fails closed) any line without `=` or whose name does not match `^[A-Za-z_][A-Za-z0-9_]*$`. |
| `flow-retries`       | no       | `0`           | Non-negative retry budget per flow; each flow gets up to `1 + flow-retries` attempts. |
| `maestro-version`    | no       | `2.8.0`       | Pinned Maestro CLI version. Installed by downloading the matching `cli-<version>` release directly from [mobile-dev-inc/Maestro releases](https://github.com/mobile-dev-inc/Maestro/releases) to `$HOME/.maestro-pinned/<version>` — immune to a pre-existing Homebrew-managed `maestro` on the host. An existing `maestro` already on `PATH` is reused only when its version exactly matches. |
| `api-level`          | no       | `34`          | Android emulator API level.                                          |
| `target`             | no       | `google_apis` | Android emulator system image target.                                |
| `arch`               | no       | `x86_64`      | Android emulator system image architecture.                          |
| `profile`            | no       | `pixel_6`     | Android emulator hardware profile.                                    |
| `artifacts-dir`      | yes      | —             | Directory final-state capture (screenshot, logcat) is written to.    |
| `artifact-name`      | yes      | —             | Uploaded artifact name.                                               |
| `retention-days`     | no       | `7`           | Uploaded artifact retention in days.                                   |

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

Keep it in a subdirectory of `flows-dir`: unlike `pre-run-flow`, it is not
filtered out of the discovered flow list, so a top-level recovery flow would
also be sharded and run as a scenario.

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/run-maestro-android@v1
  with:
      apk-path: .ci-artifacts/android-e2e-app-bare/app-release.apk
      app-id: com.example.app
      flows-dir: apps/mobile/e2e/flows
      shard-index: ${{ matrix.shard-index }}
      shard-count: 2
      artifacts-dir: ${{ github.workspace }}/artifacts/maestro-android-bare-${{ matrix.shard-index }}
      artifact-name: maestro-android-bare-shard-${{ matrix.shard-index }}
```
