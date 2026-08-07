# run-maestro-android

Boots a **headless** Android emulator (`-no-window -no-audio -gpu
swiftshader_indirect`, no boot animation, no snapshot save), waits for
`sys.boot_completed` before installing, installs the packaged `.apk`, runs a
Maestro flow shard, and — regardless of pass/fail — captures a final
screenshot plus full and crash logcat, uploaded as an artifact. The emulator
is always killed at the end (`if: always()`).

Uses `reactivecircus/android-emulator-runner`, which owns the emulator
boot/kill lifecycle; this action supplies the headless flags and a bundled
`scripts/run-shard.sh` that installs the app and runs the shard inside it.
That script lives in its own file rather than inline in `script:` because
`reactivecircus/android-emulator-runner` runs each newline of its `script`
input as an *independent* shell invocation — a multi-line for/while/if
written directly in `script:` would not see state from the line before it.

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
| `flow-retries`       | no       | `0`           | Non-negative retry budget per flow; each flow gets up to `1 + flow-retries` attempts. |
| `maestro-version`    | no       | `2.8.0`       | Pinned Maestro CLI version.                                          |
| `api-level`          | no       | `34`          | Android emulator API level.                                          |
| `target`             | no       | `google_apis` | Android emulator system image target.                                |
| `arch`               | no       | `x86_64`      | Android emulator system image architecture.                          |
| `profile`            | no       | `pixel_6`     | Android emulator hardware profile.                                    |
| `artifacts-dir`      | yes      | —             | Directory final-state capture (screenshot, logcat) is written to.    |
| `artifact-name`      | yes      | —             | Uploaded artifact name.                                               |
| `retention-days`     | no       | `7`           | Uploaded artifact retention in days.                                   |

A per-flow timing table (flow, duration, status, attempts) is appended to
`$GITHUB_STEP_SUMMARY` after every shard run, including a priming-flow row
when `pre-run-flow` is set. The resolved flow list (before sharding) is
logged to the step output before selection, so a consumer can confirm
`flows-max-depth`/`flows-name-pattern`/`flows-exclude-pattern` resolved to
the intended set.

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
