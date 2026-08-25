# redroid-container

Run-scoped **Redroid** (Android-in-a-privileged-container over the
`binder_linux` kernel module) lifecycle, split into two calls: `mode: start`
boots a container, waits for `sys.boot_completed`, zeroes all three Android
animation scales, and exports the container's adb serial; `mode: teardown`
removes the container and its per-job data directory. Unlike
[`run-maestro-android-redroid`](../run-maestro-android-redroid/README.md)
(which owns the whole boot → install → test → capture → teardown span for a
Maestro e2e shard), this action owns *only* the container — what happens on
the device between start and teardown belongs to the caller, e.g.
[`capture-screenshots-android`](../capture-screenshots-android/README.md),
which takes an already-booted serial as an input.

`run-maestro-android-redroid` calls this action for both halves of its own
container lifecycle, so everything documented there about container handling
is identical here by construction rather than by convention:

- **Prewarm manifest.** A host-side prewarm step (pulled image + a `/data`
  volume booted once, manifest written to `prewarm-manifest-path`) makes
  starts fast. Concurrent jobs all read the same manifest, so its `dataDir`
  is copied into a per-job directory under `RUNNER_TEMP` rather than
  bind-mounted directly — two Redroid containers writing to the same live
  `/data` would corrupt it. A missing manifest falls back to an in-workflow
  `docker pull` of `image` and a fresh data volume (slower, self-healing).
  See [docs/self-hosted-runners.md](../../docs/self-hosted-runners.md) for
  the manifest format and host provisioning.
- **`binder_linux` fails closed.** The one thing the fallback cannot
  self-heal is the kernel module itself — host provisioning, not something a
  job can install unattended — so a missing module fails with an explicit
  error instead of a confusing `docker run` failure.
- **Kernel-assigned loopback adb port.** The container publishes 5555 on
  loopback with an OS-assigned ephemeral host port (`-p 127.0.0.1::5555`)
  rather than a port this action or its caller picks — atomic, unlike a
  "probe with `ss`, then bind" TOCTOU race — and the port is never reachable
  from outside the runner.
- **Run-scoping.** `container-name` only needs to be unique *within* the
  calling run (e.g. incorporate `strategy.job-index`); the action appends
  `GITHUB_RUN_ID`/`GITHUB_RUN_ATTEMPT` before using it, so concurrent runs
  sharing a runner pool never collide. Teardown removes both the container
  and `RUNNER_TEMP/redroid-data/<run-scoped name>`.

Start writes `ANDROID_SERIAL`, `REDROID_EFFECTIVE_CONTAINER_NAME`, and
`REDROID_DATA_DIR` into the job environment (as well as emitting them as
step outputs), which is how a later `mode: teardown` step in the same job
finds what to remove — teardown is tolerant of a partially-failed start (it
falls back to the raw `container-name` input and skips whatever was never
created). Call teardown from an `if: always()` step so a failed capture step
in between still releases the container.

## Inputs

| Name                    | Required | Default                                | Description |
| ------------------------ | -------- | --------------------------------------- | -------------- |
| `mode`                   | yes      | —                                       | `start` or `teardown`; anything else fails closed. |
| `container-name`         | yes      | —                                       | Container name base, distinguishing this job from siblings in the same run; the action appends the run id/attempt automatically. Required in both modes (teardown's fallback when start never exported the run-scoped name). |
| `image`                  | no       | `redroid/redroid:15.0.0_64only-latest`  | Redroid image tag, used only in start mode on a prewarm-manifest miss. Verified against a 6.17 host kernel — older `13.x` tags are known to never finish boot on that kernel, and `14.x` images hard-lock the guest kernel version. |
| `memory`                 | no       | `3g`                                    | Container memory limit (`docker --memory` / `--memory-swap`). Start mode only. |
| `cpus`                   | no       | `2`                                     | Container CPU limit (`docker --cpus`). Start mode only. |
| `prewarm-manifest-path`  | no       | `$HOME/.rnw-ci/android-emulator.json`   | Host-side prewarm manifest (`{"image", "dataDir"}`); absent means a cold in-workflow pull. Start mode only. |
| `boot-timeout-seconds`   | no       | `600`                                   | Seconds to wait for `sys.boot_completed` before failing. Start mode only. |

## Outputs

All three are produced by `mode: start` only (empty in teardown mode), and
each is also exported to the job environment under the name in parentheses.

| Name             | Description |
| ----------------- | -------------- |
| `android-serial`  | adb serial of the booted container, `localhost:<kernel-assigned port>` (`ANDROID_SERIAL`). |
| `container-name`  | The run-scoped container name actually used (`REDROID_EFFECTIVE_CONTAINER_NAME`). |
| `data-dir`        | Per-job `/data` directory bind-mounted into the container (`REDROID_DATA_DIR`). |

## Example

```yaml
- name: Start Redroid
  id: redroid
  uses: rnw-community/mobile-ci/actions/redroid-container@v1
  with:
      mode: start
      container-name: redroid-screenshots-${{ strategy.job-index }}

- name: Do something with the booted device
  shell: bash
  env:
      DEVICE_SERIAL: ${{ steps.redroid.outputs.android-serial }}
  run: adb -s "$DEVICE_SERIAL" shell getprop ro.build.version.sdk

- name: Teardown Redroid
  if: always()
  uses: rnw-community/mobile-ci/actions/redroid-container@v1
  with:
      mode: teardown
      container-name: redroid-screenshots-${{ strategy.job-index }}
```
