# run-maestro-ios

Boots an available iOS Simulator — the last-available iPhone-family device by
default, or the exact device named by `simulator-device` — waits for `simctl
bootstatus -b` before installing (installing before the simulator finishes
booting is a reliable source of flaky first-run failures), installs the
packaged `.app`, runs a Maestro flow shard, and — regardless of pass/fail —
captures a final screenshot and uploads it plus `MAESTRO_DEBUG_OUTPUT_DIRECTORY`
contents as an artifact. Every `maestro test` invocation in the shard is
pointed (`--debug-output`) at a scratch directory private to this shard run
— rather than Maestro's shared, unscoped `~/.maestro/tests/<timestamp>`
default, which a concurrent shard on the same persistent self-hosted runner
could otherwise also be writing into. When any flow in the shard failed,
that scratch directory (UI hierarchy dumps and per-flow screenshots) is
copied into the artifact under a `maestro-debug/` subdirectory, capped at
200MB combined — a `::warning::` is emitted and the copy skipped if the
shard's debug output exceeds that. The simulator is always shut down at the
end (`if: always()`), so a failed shard never leaves a booted simulator
behind on a persistent self-hosted runner.

**Pinning `simulator-device`.** Leaving it empty keeps booting the last
available iPhone-family device by `xcrun simctl list devices available`
order — convenient, but that order (and therefore which physical device
shape/OS a flow runs against) silently changes whenever the runner pool's
provisioned device set changes, which can make a flow that only fails on one
specific device look like a flaky, unrelated regression. Pin an exact device
name (e.g. `iPhone 17 Pro`) once your flows are sensitive to device-specific
rendering, and provision that same device identically across every host in
the pool — see
[docs/self-hosted-runners.md](../../docs/self-hosted-runners.md#macos-pools-ios).

## Inputs

| Name                    | Required | Default       | Description                                                |
| ----------------------- | -------- | ------------- | ---------------------------------------------------------------- |
| `app-path`              | yes      | —             | Path to a packaged `.app` directory to install.                   |
| `app-id`                | yes      | —             | Bundle identifier passed to Maestro as `APP_ID`.                  |
| `flows-dir`             | yes      | —             | Directory whose top-level files are the runnable Maestro flows by default. Subdirectories are not searched unless `flows-max-depth` is raised. |
| `flows-max-depth`       | no       | `1`           | `find -maxdepth` under `flows-dir`. `0` means unbounded recursion. Default keeps subflows (invoked via `runFlow`, conventionally in subdirectories) out of the shard. |
| `flows-name-pattern`    | no       | `*.flow.yaml` | Space-separated `find -name` globs (OR'd together) selecting runnable flows directly inside `flows-dir`. Keeps reusable subflows and capture-only flows in subdirectories out of the shard by default. |
| `flows-exclude-pattern` | no       | `''`          | Optional `find ! -name` glob excluding matched flows by basename.  |
| `shard-manifest-dir`    | no       | `''`          | Directory of hand-curated `shard-<index>.txt` files (one `flows-dir`-relative path per line) overriding the index-modulo split. Unset falls back to modulo entirely; once set, every shard-index this job can run must have its own file — a partial manifest fails closed. |
| `shard-index`           | yes      | —             | Zero-based shard index this job runs.                             |
| `shard-count`           | yes      | —             | Total number of shards flows are distributed across.              |
| `pre-run-flow`          | no       | `''`          | Path to a single priming flow run once before this shard's flows, excluded from sharding. Its failure fails the step immediately. |
| `pre-test-command`      | no       | `''`          | Consumer-owned shell command run once after the app is installed on the simulator and before any flow (including `pre-run-flow`) executes. Runs with `SIMULATOR_UDID`, `APP_ID`, and `APP_PATH` in its environment. Its failure fails the step immediately. |
| `maestro-env`           | no       | `''`          | Newline-separated `KEY=VALUE` pairs, each passed as an additional `-e KEY=VALUE` argument to every `maestro test` invocation (`pre-run-flow` and shard flows alike). Rejects (fails closed) any line without `=` or whose name does not match `^[A-Za-z_][A-Za-z0-9_]*$`. |
| `flow-retries`          | no       | `0`           | Non-negative retry budget per flow; each flow gets up to `1 + flow-retries` attempts. |
| `maestro-version`       | no       | `2.8.0`       | Pinned Maestro CLI version.                                        |
| `simulator-device`      | no       | `''`          | Exact simulator device name to boot (e.g. `iPhone 17 Pro`), matched with no fuzzy matching. Fails closed, listing available devices, on no exact match. Empty keeps the last-available-iPhone heuristic (emits a `::notice::` naming its choice). |
| `artifacts-dir`         | yes      | —             | Directory Maestro debug output and final-state capture is written to. |
| `artifact-name`         | yes      | —             | Uploaded artifact name.                                            |
| `retention-days`        | no       | `7`           | Uploaded artifact retention in days.                               |

A per-flow timing table (flow, duration, status, attempts) is appended to
`$GITHUB_STEP_SUMMARY` after every shard run, including a priming-flow row
when `pre-run-flow` is set. The resolved flow list (before sharding) is
logged to the step output before selection, so a consumer can confirm
`flows-max-depth`/`flows-name-pattern`/`flows-exclude-pattern` resolved to
the intended set.

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/run-maestro-ios@v1
  with:
      app-path: .ci-artifacts/ios-e2e-app-bare/Base.app
      app-id: com.example.app
      flows-dir: apps/mobile/e2e/flows
      shard-index: ${{ matrix.shard-index }}
      shard-count: 2
      artifacts-dir: ${{ github.workspace }}/artifacts/maestro-ios-bare-${{ matrix.shard-index }}
      artifact-name: maestro-ios-bare-shard-${{ matrix.shard-index }}
```
