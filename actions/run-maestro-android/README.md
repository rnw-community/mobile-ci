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
When any flow in the shard failed, only the **failing** flows' debug output
(UI hierarchy dumps and per-flow screenshots, covering every attempt of the
flow plus the recovery-flow runs that followed it) is staged, one gzipped
tarball per flow at `maestro-debug/<flow>.tar.gz`. Bundles are staged in
flow-execution order for as long as they fit a 200MB *compressed* total; one
that would exceed the cap is dropped with a `::warning::` naming the flow and
its compressed size while the smaller remaining bundles are still tried.
Debug output no flow claims — Maestro keys its output by `maestro test`
invocation timestamp, not by flow name — is bundled last as
`maestro-debug/unattributed.tar.gz` rather than discarded.
Because the explicit `--debug-output` flag takes precedence, a
caller-exported `MAESTRO_DEBUG_OUTPUT_DIRECTORY` environment variable is
deliberately **not** honored by the shard's `maestro test` invocations —
debug output always lands in the uploaded artifact as described above, so
no fallback "copy `~/.maestro/tests`" step is needed on the caller's side.
The emulator is always killed at the end (`if: always()`).

**Maestro's hidden debug path lives inside the bundles.** Maestro writes its
debug output into a hidden `.maestro/tests/<timestamp>/` path, and
`actions/upload-artifact` skips hidden files by default — which used to ship
`final-screen.png` alone and drop the very UI hierarchy dumps the failure
message tells you to inspect. Each staged `maestro-debug/<flow>.tar.gz` is a
visible file that keeps that path *inside* the archive, so no hidden entry is
staged at all; the upload step still sets `include-hidden-files: true` for the
rest of the artifact. Expand a bundle with
`tar -xzf maestro-debug/<flow>.tar.gz`.

The emulator lifecycle belongs to
[`android-emulator`](../android-emulator/README.md), the AVD action
store-screenshots' `avd` capture leg uses too: this action calls it with
`mode: start` before the shard and with `mode: stop` under `if: always()`
after the final-state capture. `android-emulator` fails closed when
`emulator -accel-check` reports no hardware acceleration, sizes the guest from
the container's cgroup limits, optionally holds a host emulator slot, and on
stop kills only this job's emulator processes. The shard itself runs as a
plain step, `scripts/run-shard.sh`, with `ANDROID_SERIAL` set to the booted
emulator's serial; the script re-derives it from `adb devices` and exports it
for `pre-test-command`'s use.

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

## Tag selection

`include-tags` / `exclude-tags` select flows by the `tags:` list in each flow's
config section (the YAML document before the first `---`; block `- smoke` and
inline `[smoke, checkout]` lists both work), with Maestro's own semantics:

- a flow runs when `include-tags` is empty **or** it carries **any** listed tag;
- a flow carrying **any** `exclude-tags` tag never runs — exclude wins;
- both are comma-separated, entries trimmed, empty entries ignored.

Maestro applies tags only when it plans a **directory**; handed a single flow
file it ignores them, and this action and the other `run-maestro-*` actions always hand it single files. So the selection
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

## Inputs

| Name                | Required | Default       | Description                                                  |
| -------------------- | -------- | ------------- | ------------------------------------------------------------------ |
| `apk-path`           | yes      | —             | Path to the packaged `.apk` to install.                             |
| `app-id`             | yes      | —             | Application ID passed to Maestro as `APP_ID`.                       |
| `flows-dir`             | yes      | —             | Directory whose top-level files are the runnable Maestro flows by default. Subdirectories are not searched unless `flows-max-depth` is raised. |
| `flows-max-depth`       | no       | `1`           | `find -maxdepth` under `flows-dir`. `0` means unbounded recursion. Default keeps subflows (invoked via `runFlow`, conventionally in subdirectories) out of the shard. |
| `flows-name-pattern`    | no       | `*.flow.yaml` | Space-separated `find -name` globs (OR'd together) selecting runnable flows directly inside `flows-dir`. Keeps reusable subflows and capture-only flows in subdirectories out of the shard by default. |
| `flows-exclude-pattern` | no       | `''`          | Optional `find ! -name` globs excluding matched flows by basename: one glob, or a comma- and/or newline-separated list (each entry trimmed, empty entries ignored; a glob containing a comma is not supported).    |
| `shard-manifest-dir`    | no       | `''`          | Directory of hand-curated `shard-<index>.txt` files (one `flows-dir`-relative path per line) overriding the index-modulo split. Unset falls back to modulo entirely; once set, every shard-index this job can run must have its own file — a partial manifest fails closed. |
| `shard-index`        | yes      | —             | Zero-based shard index this job runs.                                |
| `shard-count`        | yes      | —             | Total number of shards flows are distributed across.                 |
| `pre-run-flow`       | no       | `''`          | Path to a single priming flow run once before this shard's flows, excluded from sharding. Its failure fails the step immediately. |
| `flow-recovery-flow` | no       | `''`          | Path to a single best-effort recovery flow run after a **failed** flow attempt — before the same flow's next retry attempt, and before the next flow starts — so one failure cannot strand the app in a state that cascades into the flows after it. Never run after a passing attempt, and not after this shard's last flow. Its own failure only logs a `::warning::` and never fails the step. Like `pre-run-flow`, it is removed from the shard's discovered flow list, so it never also runs as a scenario of its own. Its duration is excluded from the per-flow timing table; a line below that table reports how many times it ran and how many of those runs failed. |
| `pre-test-command`   | no       | `''`          | Consumer-owned shell command run once after the app is installed on the emulator and before any flow (including `pre-run-flow`) executes. Runs with `ANDROID_SERIAL`, `APP_ID`, and `APK_PATH` in its environment. Its failure fails the step immediately. |
| `pre-flow-command`   | no       | `''`          | Consumer-owned shell command run **before every flow attempt**, each retry included, after `pre-run-flow` and the warm-up. Never run before `pre-run-flow` or `flow-recovery-flow` themselves. Runs with `FLOW_PATH`, `FLOW_NAME`, `APP_ID`, `ANDROID_SERIAL` and `MAESTRO_FLOW_ENV_FILE` in its environment. Unlike the best-effort `flow-recovery-flow` it is a **precondition**: a non-zero exit fails that attempt without running the flow, consuming one of its `1 + flow-retries` attempts and triggering the recovery flow like any other failed attempt. Every `KEY=VALUE` line it appends to `$MAESTRO_FLOW_ENV_FILE` becomes an extra `-e KEY=VALUE` argument for that one flow's `maestro test` — see [Per-flow preconditions](#per-flow-preconditions). |
| `app-warm-seconds`   | no       | `20`          | Seconds the app is left running during a one-off warm-up (launch via `monkey`, settle, `am force-stop`) performed after install and before `pre-test-command` or any flow runs, so first-launch cold-start cost is not absorbed by the first flow's own timeout budget. `0` disables warming. The launch is best-effort: on some images (Redroid) `monkey` exits non-zero even after starting the app, so a non-zero status only warns. The trailing `am force-stop` is likewise ignored if it returns non-zero. |
| `maestro-env`        | no       | `''`          | Newline-separated `KEY=VALUE` pairs, each passed as an additional `-e KEY=VALUE` argument to every `maestro test` invocation (`pre-run-flow` and shard flows alike). Rejects (fails closed) any line without `=` or whose name does not match `^[A-Za-z_][A-Za-z0-9_]*$`. |
| `maestro-config`      | no       | `''`           | Path to the consumer's Maestro workspace config (`config.yaml`), passed as `--config` to every `maestro test` invocation. Maestro only auto-discovers a workspace `config.yaml` when it is pointed at a **directory**, and this action always passes individual flow files, so without this input a workspace config is silently ignored — see [Maestro workspace config](#maestro-workspace-config). Relative paths resolve against the job's working directory. Fails closed when set to a path that is not a file. Its `includeTags`/`excludeTags` are honoured when the shard is planned — see [Tag selection](#tag-selection). |
| `include-tags` | no | `''` | Comma-separated Maestro tags; only flows whose config section's `tags:` holds any of them run. Applied when the shard is planned (exclude wins), added to `maestro-config`'s `includeTags`, and passed to `maestro test`. Fails closed on an unparsable flow config section or an empty selection — see [Tag selection](#tag-selection). |
| `exclude-tags` | no | `''` | Comma-separated Maestro tags; flows holding any of them never run, even when `include-tags` selects them. Added to `maestro-config`'s `excludeTags` — see [Tag selection](#tag-selection). |
| `junit-report` | no | `'true'` | `'true'` writes each flow's final-attempt JUnit report (`maestro test --format junit`) to `junit/<flow>.xml` in `artifacts-dir`; `'false'` writes none — see [JUnit reports](#junit-reports). |
| `flow-retries`       | no       | `0`           | Non-negative retry budget per flow; each flow gets up to `1 + flow-retries` attempts. |
| `infra-retries`      | no       | `1`           | Per-flow retry budget, separate from `flow-retries`, spent only on a failed attempt that hit ActivityManager's `startProcessLocked ... with non-zero startSeq` race — see [ActivityManager startSeq race](#activitymanager-startseq-race). Such an attempt is reported as a `::warning::` and retried even when `flow-retries` is `0`; once this budget is spent it falls back to `flow-retries`. |
| `settle-before-flow` | no       | `true`        | `true` runs `am force-stop` on `app-id` before every flow attempt (`pre-run-flow` and retries included, before `pre-flow-command`) and waits up to 5 s for its process to be gone. App data is untouched. `false` leaves the app as the previous flow left it. Anything else fails the step. |
| `maestro-version`    | no       | `2.8.0`       | Pinned Maestro CLI version. Installed by downloading the matching `cli-<version>` release directly from [mobile-dev-inc/Maestro releases](https://github.com/mobile-dev-inc/Maestro/releases) to `$HOME/.maestro-pinned/<version>` — immune to a pre-existing Homebrew-managed `maestro` on the host. An existing `maestro` already on `PATH` is reused only when its version exactly matches. |
| `api-level`          | no       | `34`          | Android emulator API level.                                          |
| `target`             | no       | `google_apis` | Android emulator system image target.                                |
| `arch`               | no       | `x86_64`      | Android emulator system image architecture.                          |
| `profile`            | no       | `pixel_6`     | Android emulator hardware profile.                                    |
| `ram-size`           | no       | `''`          | Emulator RAM in MB, passed to `android-emulator`. Empty derives it from the runner's cgroup memory limit — see [Emulator budget](../android-emulator/README.md#emulator-budget); with no limit detected the hardware profile's default applies. An explicit value always wins. |
| `heap-size`          | no       | `''`          | Android VM heap size in MB for the emulated device. Empty keeps the profile default. |
| `cores`              | no       | `''`          | Emulator CPU cores. Empty derives half the runner's cgroup CPU quota — see [Emulator budget](../android-emulator/README.md#emulator-budget); with no quota detected the profile default applies. An explicit value always wins. |
| `emulator-slots-dir` | no       | `''`          | Host directory of fleet-provisioned `slot-*` files capping concurrent emulators on the host — see [Host emulator slots](../android-emulator/README.md#host-emulator-slots). Empty takes no slot. A missing directory, no `slot-*` files, an unwritable slot, or no `flock`/`setsid` on `PATH` fails the job. |
| `emulator-slot-timeout-minutes` | no | `60`      | Minutes to wait for a free slot before failing the job; busy slots are logged every 60 s. `0` tries each slot once. Ignored when `emulator-slots-dir` is empty. |
| `artifacts-dir`      | yes      | —             | Directory final-state capture (screenshot, `logcat-full.txt`, `logcat-crash.txt`, `logcat-events.txt`) and the per-failed-attempt `logcat-events/<flow>-attempt-<n>.txt` are written to. |
| `artifact-name`      | yes      | —             | Uploaded artifact name.                                               |
| `retention-days`     | no       | `7`           | Uploaded artifact retention in days.                                   |
| `redact-env-names` | no | `''` | Newline- or space-separated names of job environment variables (`apply-secret-env`'s `names`) whose values are replaced with `***` in every text file under `artifacts-dir` before upload — so a secret a flow typed never survives in `maestro.log`, a commands JSON or a logcat. A multi-line value is redacted line by line. Runs on failure too; a bad name, a host without `perl` or a failed rewrite deletes the artifacts and fails rather than upload them unredacted. |

## ActivityManager startSeq race

Maestro's `launchApp: clearState: true` runs `pm clear`, which kills the
running app process, then starts the launcher activity about a second later.
When that start reaches ActivityManager while it is still processing the
killed process's death, it takes the `startProcessLocked ... with non-zero
startSeq` path and never forks the app: the activity is created, no process
binds to it, and the flow's first selector times out on a blank screen. No
app code runs, so this is not an app failure.

- **Avoided** by `settle-before-flow` (default `true`): before every attempt
  the action runs `am force-stop` and waits for `pidof` to come back empty,
  so Maestro's `pm clear` finds no process to kill and there is no death in
  flight when it launches. It deliberately does not run `pm clear` itself:
  clearing data stays the flow's choice, so a flow without `clearState`
  still sees the storage the previous flow left. Only a flow that expects the
  previous flow's *running process* (no `launchApp` of its own) is affected,
  and sharding already gives such a flow no guaranteed predecessor.
- **Detected** after every failed attempt by scanning `adb logcat -b events`
  from the attempt's start (device clock, `logcat -T`) for the `am_wtf`
  naming `app-id`, or for an `app-id` activity created with neither an
  `am_proc_start` for `app-id` nor that activity's `wm_on_create_called`
  after it. A match emits a `::warning::` and retries on `infra-retries`.
- **Evidenced** by `logcat-events/<flow>-attempt-<n>.txt` for every failed
  attempt and `logcat-events.txt` in the final-state capture: the main
  buffer usually rotates past the failure on a long shard, the events buffer
  holds it.

## Outputs

| Name            | Description |
| --------------- | ----------- |
| `ram-size`      | Emulator RAM in MB the emulator was booted with: the input, else the derived value, else empty (profile default). |
| `cores`         | Emulator CPU cores the emulator was booted with: the input, else the derived value, else empty (profile default). |
| `emulator-slot` | Basename of the slot file held, e.g. `slot-1`. Empty when `emulator-slots-dir` is empty. |

## Emulator budget, host slots and shutdown

`ram-size`, `heap-size`, `cores`, `emulator-slots-dir` and
`emulator-slot-timeout-minutes` are passed to `android-emulator` unchanged,
and the `ram-size`/`cores`/`emulator-slot` outputs are its outputs. See its
README for how an empty `ram-size`/`cores` is derived from the container's
cgroup limits ([Emulator budget](../android-emulator/README.md#emulator-budget)),
how the fleet's slot files cap emulators per host
([Host emulator slots](../android-emulator/README.md#host-emulator-slots)),
and which processes the always-run stop kills
([Stop](../android-emulator/README.md#stop)).

A per-flow timing table (flow, duration, status, attempts, infra retries) is
appended to `$GITHUB_STEP_SUMMARY` after every shard run, including a
priming-flow row when `pre-run-flow` is set. Attempts include infra retries. Time spent in `flow-recovery-flow` is excluded
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
- uses: rnw-community/mobile-ci/actions/run-maestro-android@v4.4.2 # v4.4.2
  with:
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
- uses: rnw-community/mobile-ci/actions/run-maestro-android@v4.4.2 # v4.4.2
  with:
      apk-path: .ci-artifacts/android-e2e-app-bare/app-release.apk
      app-id: com.example.app
      flows-dir: apps/mobile/e2e/flows
      shard-index: ${{ matrix.shard-index }}
      shard-count: 2
      artifacts-dir: ${{ github.workspace }}/artifacts/maestro-android-bare-${{ matrix.shard-index }}
      artifact-name: maestro-android-bare-shard-${{ matrix.shard-index }}
```
