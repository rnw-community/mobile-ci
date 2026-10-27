# android-emulator

Starts a headless Android emulator (AVD) for the rest of the job
(`mode: start`) and shuts it down again (`mode: stop`). It is the one AVD
implementation in this repo: [`run-maestro-android`](../run-maestro-android/README.md)
boots its Maestro shard's device through it, and `store-screenshots.yml`'s
`android-driver: avd` capture leg boots the device
[`capture-screenshots-android`](../capture-screenshots-android/README.md)
drives through it.

`mode: start`, in order:

1. validates its inputs (fails closed on anything malformed);
2. resolves the SDK — see [Android SDK](#android-sdk);
3. runs `emulator -accel-check` and **fails closed** unless it confirms
   hardware acceleration — see [Hardware acceleration](#hardware-acceleration);
4. sizes the guest from the container's cgroup limits — see
   [Emulator budget](#emulator-budget);
5. optionally takes a host-wide emulator slot — see
   [Host emulator slots](#host-emulator-slots);
6. creates the AVD (or reuses one built for the same system image), writes
   `hw.ramSize`/`hw.heapSize`/`hw.cpu.ncore`, boots it detached with
   `emulator-options`, waits for `sys.boot_completed`, and turns window,
   transition and animator animations and the spell checker off.

`mode: stop` sends `adb emu kill` to the serial `start` booted, kills whatever
of this job's emulator processes survive, and releases the slot — see
[Stop](#stop). Call it with `if: always()`.

## Inputs

| Name                            | Required | Default | Description |
| ------------------------------- | -------- | ------- | ----------- |
| `mode`                          | yes      | —       | `start` or `stop`. Anything else fails the step. |
| `api-level`                     | no       | `34`    | System image API level. |
| `target`                        | no       | `google_apis` | System image target, e.g. `google_apis` or `google_apis_playstore`. |
| `arch`                          | no       | `x86_64` | System image architecture. |
| `profile`                       | no       | `pixel_6` | `avdmanager` hardware profile (device id or name). Empty uses `avdmanager`'s default device. |
| `avd-name`                      | no       | `test`  | AVD name under `ANDROID_AVD_HOME`. Reused when built for the same system image, recreated otherwise. Give jobs that change device-wide settings (`wm size`, demo mode) their own name. |
| `port`                          | no       | `5554`  | Even console port 5554–5682; the adb serial is `emulator-<port>`. Fails closed when that serial is already attached to adb. |
| `ram-size`                      | no       | `''`    | Guest RAM in MB (`hw.ramSize`). Empty derives it from the cgroup memory limit — see [Emulator budget](#emulator-budget). An explicit value always wins. |
| `heap-size`                     | no       | `''`    | Android VM heap size in MB (`hw.heapSize`). Empty keeps the profile default. |
| `cores`                         | no       | `''`    | Guest CPU cores (`hw.cpu.ncore`). Empty derives half the cgroup CPU quota — see [Emulator budget](#emulator-budget). An explicit value always wins. |
| `emulator-options`              | no       | `-no-snapshot-save -no-window -gpu swiftshader_indirect -noaudio -no-boot-anim -camera-back none` | Whitespace-separated emulator options after `-port` and `-avd`. |
| `wipe-data`                     | no       | `false` | `true` boots with `-wipe-data`, discarding any earlier run's apps and settings. |
| `boot-timeout-seconds`          | no       | `600`   | Seconds to wait for `sys.boot_completed` before failing. |
| `cmdline-tools-version`         | no       | `12266719` | SDK cmdline-tools build `setup-android` installs when the SDK has no matching `sdkmanager`. |
| `emulator-slots-dir`            | no       | `''`    | Host directory of fleet-provisioned `slot-*` files capping concurrent emulators on the host — see [Host emulator slots](#host-emulator-slots). Empty takes no slot. A missing directory, no `slot-*` files, an unwritable slot, or no `flock`/`setsid` on `PATH` fails the step. |
| `emulator-slot-timeout-minutes` | no       | `60`    | Minutes to wait for a free slot; busy slots are logged every 60 s. `0` tries each slot once. Ignored when `emulator-slots-dir` is empty. |

## Outputs

| Name             | Description |
| ---------------- | ----------- |
| `android-serial` | adb serial of the booted emulator, `emulator-<port>`. Empty for `mode: stop`. |
| `ram-size`       | Guest RAM in MB the emulator was booted with: the input, else the derived value, else empty (profile default). |
| `cores`          | Guest CPU cores the emulator was booted with: the input, else the derived value, else empty (profile default). |
| `emulator-slot`  | Basename of the slot file held, e.g. `slot-1`. Empty when `emulator-slots-dir` is empty. |

## Android SDK

`start` first looks for an SDK already on the runner, in `ANDROID_SDK_ROOT`
and then `ANDROID_HOME` (read from the runner's real environment, so an SDK
baked into the runner image counts). It uses that SDK as is — skipping
`android-actions/setup-android` entirely — when it has an executable
`emulator/emulator`, `platform-tools/adb`, an `avdmanager` (under
`cmdline-tools/latest/bin`, any `cmdline-tools/*/bin`, or on `PATH`) and the
requested `system-images/android-<api-level>/<target>/<arch>` with its
`package.xml` and `system.img`. When only the system image is missing and the
SDK root is writable, it installs just that package into the same SDK with its
`sdkmanager --sdk_root`. Otherwise, including when that install fails, it runs
`android-actions/setup-android` against the same root (or setup-android's
default `~/.android/sdk` when no SDK directory exists). Either way it exports
`ANDROID_HOME`/`ANDROID_SDK_ROOT` to the resolved root for the rest of the job,
and the step summary says which path it took. On a fleet image with the SDK
preinstalled the step costs seconds; a fresh setup-android SDK costs minutes.

## Hardware acceleration

A runner without usable `/dev/kvm` does not necessarily refuse to boot an AVD:
the emulator can fall back to software emulation, which eventually boots but
far too slowly for a CI budget, and the job then fails as an unrelated flow or
boot timeout. `start` runs `emulator -accel-check` before anything else touches
the device and fails the step, quoting the emulator's own reason, unless it
exits 0 **and** reports status `0`. The confirmed accelerator (e.g.
`KVM (version 12) is installed and usable.`) goes to the step summary. Nothing
in this action ever passes `-accel off`.

## Emulator budget

Inside a container `/proc/meminfo` and `nproc` report the host, so an unset
`ram-size` would leave the guest at the hardware profile's default regardless
of the container it runs in. Before booting, the action reads the runner's own
cgroup limits — cgroup v2 `memory.max` and `cpu.max`, falling back to cgroup v1
`memory/memory.limit_in_bytes` and `cpu/cpu.cfs_quota_us` /
`cpu.cfs_period_us` — and, only for an input left empty, derives:

- **`ram-size`** = 256 MB per GiB of memory limit, rounded down to a 256 MB
  step, clamped to 1536–4096. An 8 GiB container gets 2048, which leaves
  roughly 4 GiB beside the ~4.2 GiB emulator RSS for the test driver's JVM,
  adb and the runner. Below 6 GiB the 1536 floor still applies and the step
  warns.
- **`cores`** = half the CPU quota, rounded down, clamped to 2–4, leaving the
  other half to the test driver, adb and the runner (the emulator's software
  GPU renders on host CPU too). A 4 vCPU container gets 2.

A limit of `max` (or the cgroup v1 unbounded sentinels) leaves the input
empty, i.e. the profile default. An unparseable limit file fails the step
rather than guessing. The detected limits and the resolved values are written
to the step summary and exposed as the `ram-size`/`cores` outputs.

## Host emulator slots

Several runner containers on one host can each boot an emulator, and nothing
inside a single job can see the others. `emulator-slots-dir` names a host
directory the fleet pre-creates with one `slot-*` file per emulator the host
may run at once (the number of files **is** the cap, and the fleet owns it).
Before booting, `start` takes an exclusive `flock` on a free slot through a
detached holder process (`setsid flock … sleep`), waits up to
`emulator-slot-timeout-minutes` while all are busy, and fails closed when none
frees up. `stop` releases it. If the job dies first, the lock still goes away:
the kernel drops a `flock` when its last descriptor closes, and the holder
carries the job's `RUNNER_TRACKING_ID`, so the runner's orphan cleanup or the
container's teardown kills it. The directory must be on a local filesystem
(never NFS) and bind-mounted read-write into every runner container on the
host; see
[self-hosted-runners.md](../../docs/self-hosted-runners.md#linux-x86_64-kvm-hosts-android-avd-driver).

## Stop

`stop` sends `adb -s <serial> emu kill` to the serial `start` recorded (and no
blind `adb emu kill` when `start` never got that far), waits up to 15 s for
this job's emulator processes (`emulator`, `qemu-system-*`, `netsimd`,
`crashpad_handler`) to exit, then `SIGKILL`s the survivors, logging each one.
A process counts as this job's only when its environment carries this job's
`RUNNER_TRACKING_ID` — or, where that is unset, the same `GITHUB_RUN_ID`,
`GITHUB_RUN_ATTEMPT`, `GITHUB_JOB` and `RUNNER_NAME` — so another job's
emulator on a shared host is never touched. It stops the adb server only when
this job started it, then releases the emulator slot. It never fails the job.

## Why not `reactivecircus/android-emulator-runner`

`android-emulator-runner` boots the emulator, runs its `script:` input, and
kills the emulator, all inside one step. That suits a single command, but not
a device later steps have to share (install, a seed hook, a capture loop, a
final-state capture after a failure) or a teardown that must run when an
earlier step failed. This action is the part of it those callers need — the
SDK packages, `avdmanager create avd`, the config keys, the boot wait and the
animation settings, with the same headless options — split into `start` and
`stop`, plus what it never did: the acceleration preflight (it silently adds
`-accel off` when `/dev/kvm` is missing), cgroup-derived sizing, the host
slot, and a job-scoped teardown.

## Example

```yaml
- name: Start emulator
  id: emulator
  uses: rnw-community/mobile-ci/actions/android-emulator@v4.5.0 # v4.5.0
  with:
      mode: start

- name: Install and exercise the app
  shell: bash
  env:
      ANDROID_SERIAL: ${{ steps.emulator.outputs.android-serial }}
  run: adb install -r app-release.apk

- name: Stop emulator
  if: always()
  uses: rnw-community/mobile-ci/actions/android-emulator@v4.5.0 # v4.5.0
  with:
      mode: stop
```
