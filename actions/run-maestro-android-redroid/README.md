# run-maestro-android-redroid

Boots **Redroid** (Android-in-a-privileged-container over the `binder_linux`
kernel module) instead of an AVD emulator, waits for `sys.boot_completed`
before installing, installs the packaged `.apk`, runs a Maestro flow shard,
and — regardless of pass/fail — captures a final screenshot plus full, crash,
and app-filtered logcat and a foreground-activity dump, uploaded as an
artifact. The container is always removed at the end (`if: always()`).

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

There is no `adb-port` input. The container publishes 5555 on loopback with
an OS-assigned ephemeral host port (`docker run -p 127.0.0.1::5555`) rather
than a port this action or its caller picks — asking the kernel for "any free
port" is atomic, unlike a "probe with `ss`, then bind" check, which is a
TOCTOU race a concurrent shard can still lose. The action reads back whichever
port Docker assigned (`docker port <container> 5555/tcp`) and uses that for
every later `adb` call. This also means Redroid's adb port is never reachable
from outside the runner itself.

## Inputs

| Name                     | Required | Default                              | Description                                                                             |
| ------------------------- | -------- | ------------------------------------- | ------------------------------------------------------------------------------------------ |
| `image`                   | no       | `redroid/redroid:15.0.0_64only-latest` | Redroid image tag, used only on a prewarm-manifest miss. Verified against a 6.17 host kernel — older `13.x` tags are known to never finish boot on that kernel, and `14.x` images hard-lock the guest kernel version. |
| `container-name`          | yes      | —                                      | Docker container name base, distinguishing this cell from siblings in the same run; the action appends the run id/attempt automatically. |
| `apk-path`                | yes      | —                                      | Path to the packaged `.apk` to install.                                                     |
| `app-id`                  | yes      | —                                      | Application ID passed to Maestro as `APP_ID`.                                               |
| `flows-dir`               | yes      | —                                      | Directory containing Maestro flow `.yaml`/`.yml` files.                                     |
| `flows-max-depth`         | no       | `1`                                    | `find -maxdepth` under `flows-dir`. `0` means unbounded recursion.                          |
| `flows-name-pattern`      | no       | `*.flow.yaml`                          | Space-separated `find -name` globs (OR'd together) selecting runnable flows directly inside `flows-dir`. |
| `flows-exclude-pattern`   | no       | —                                       | Optional `find ! -name` glob excluding matched flows by basename.                           |
| `shard-manifest-dir`      | no       | —                                       | Directory of hand-curated `shard-<index>.txt` files (one `flows-dir`-relative path per line) overriding the index-modulo split. Unset falls back to modulo entirely; once set, every shard-index this job can run must have its own file — a partial manifest fails closed. |
| `shard-index`             | yes      | —                                      | Zero-based shard index this job runs.                                                       |
| `shard-count`             | yes      | —                                      | Total number of shards flows are distributed across.                                        |
| `maestro-version`         | no       | `2.8.0`                                | Pinned Maestro CLI version.                                                                  |
| `memory`                  | no       | `3g`                                   | Container memory limit (`docker --memory` / `--memory-swap`).                               |
| `cpus`                    | no       | `2`                                    | Container CPU limit (`docker --cpus`).                                                      |
| `prewarm-manifest-path`   | no       | `$HOME/.rnw-ci/android-emulator.json`  | Host-side prewarm manifest (`{"image", "dataDir"}`); absent means a cold in-workflow pull.  |
| `boot-timeout-seconds`    | no       | `600`                                  | Seconds to wait for `sys.boot_completed` before failing the shard.                          |
| `artifacts-dir`           | yes      | —                                      | Directory final-state capture (screenshot, logcat) is written to.                           |
| `artifact-name`           | yes      | —                                      | Uploaded artifact name.                                                                      |
| `retention-days`          | no       | `7`                                    | Uploaded artifact retention in days.                                                         |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/run-maestro-android-redroid@v1
  with:
      container-name: redroid-e2e-${{ strategy.job-index }}
      apk-path: .ci-artifacts/android-e2e-app-bare/app-release.apk
      app-id: com.reactnativepaymentsexample
      flows-dir: packages/react-native-payments-example/e2e/flows
      shard-index: ${{ matrix.shard-index }}
      shard-count: 2
      artifacts-dir: ${{ github.workspace }}/artifacts/maestro-android-bare-${{ matrix.shard-index }}
      artifact-name: maestro-android-bare-shard-${{ matrix.shard-index }}
```
