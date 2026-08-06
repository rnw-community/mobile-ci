# Self-hosted runners

Every action and reusable workflow in this repo assumes a self-hosted fleet.
Nothing here works out of the box on GitHub-hosted runners for the Android
`redroid` driver (needs `binder_linux`, a host kernel module) or for iOS
(needs a real Xcode install, not the one GitHub's hosted macOS images ship
with several versions of but no `.xcconfig`-level pinning guarantee across
runs). This doc covers provisioning both pool types plus the two variables
this repo's own maintainer-only fleet self-test job reads.

## macOS pools (iOS)

Each macOS runner needs one or more Xcode versions installed side by side at
their default install location:

```
/Applications/Xcode_<version>.app
```

e.g. `/Applications/Xcode_26.4.1.app`. `setup-xcode-pinned` selects one of
these by exact version *and* build number — it never runs `xcode-select -s`
globally, and it never installs or switches Xcode itself. It only exports
`DEVELOPER_DIR` for the current job and hard-asserts that
`xcodebuild -version` reports exactly the requested `Xcode <version>` /
`Build version <build>` pair before any build step runs.

**Why assert the build number, not just the version string.** Apple
sometimes ships two different builds under what looks like the same
public-facing version during a beta cycle, and a runner image can drift
(reimaged with a patch release that keeps the same `/Applications/Xcode_X.Y.app`
path but a different build) without anyone noticing until a build behaves
subtly differently. Asserting both means a drifted or missing toolchain fails
the job immediately with a clear message instead of silently building with
the wrong compiler — the same reasoning `setup-xcode-pinned`'s own README
documents.

**Splitting build and test pools.** `ios-maestro.yml` (and
`android-maestro.yml`) accept `build-runner-labels` and `test-runner-labels`
in addition to the simpler `runner-labels`. Both fall back to `runner-labels`
when left empty, so the common case (`runner-labels` only) needs no change.
Split them when your build hosts and your Maestro-execution hosts are
provisioned differently in practice — e.g. build machines sized for
`xcodebuild`/Gradle parallelism and disk (DerivedData, ccache, Gradle cache)
while test machines are sized for however many Simulators/emulators/Redroid
containers you run concurrently, or when the two pools live in different
labeled groups for capacity-management reasons on your fleet:

```yaml
with:
    build-runner-labels: '["self-hosted","macos-builder"]'
    test-runner-labels: '["self-hosted","macos-maestro"]'
```

## Linux `linux-aarch64` Redroid hosts (Android)

Google does not publish `linux-aarch64` builds of the Android emulator, NDK,
or `cmake`, so `reactivecircus/android-emulator-runner` (`run-maestro-android`,
the `avd` driver) is structurally unusable on `linux-aarch64` self-hosted
runners regardless of tuning. `run-maestro-android-redroid` (the `redroid`
driver, `android-maestro.yml`'s default) runs Android as a privileged Docker
container over the host's `binder_linux` kernel module instead, and needs
none of the emulator's `linux-aarch64`-unavailable dependencies.

Host requirements:

- **Docker**, with the runner's user able to run `sudo docker ...`
  (the action's every `docker`/`modprobe` invocation is prefixed `sudo`).
- **`binder_linux` loadable.** The action itself runs
  `sudo modprobe binder_linux devices=binder,hwbinder,vndbinder` at the start
  of every shard and treats a still-absent `/sys/module/binder_linux` after
  that as a hard failure — this is host-kernel provisioning a workflow run
  cannot safely self-heal, so provision it once per host instead:

  ```bash
  # /etc/modules-load.d/binder_linux.conf
  binder_linux

  # /etc/modprobe.d/binder_linux.conf
  options binder_linux devices=binder,hwbinder,vndbinder
  ```

  Verified against a `6.17` host kernel with the default `redroid-image`
  (`redroid/redroid:15.0.0_64only-latest`); older `13.x` Redroid tags are
  known to never finish boot on that kernel, and `14.x` images hard-lock the
  guest kernel version on some hosts — a host running a different kernel
  should re-verify its own Redroid image tag before relying on this default.
- **Privileged containers allowed.** Redroid requires `docker run
  --privileged`; this is a host-level Docker daemon policy decision, not
  something either `android-maestro.yml` or `run-maestro-android-redroid`
  can work around.

### The Redroid prewarm manifest

A cold shard pays for two slow things every time: a `docker pull` of the
Redroid image, and Android's own first-boot (which is much slower than a
subsequent boot from an already-initialized `/data`). The prewarm manifest
lets a host-side process pay for both once and hand every later shard a
warm starting point instead.

`run-maestro-android-redroid`'s `prewarm-manifest-path` input (default
`$HOME/.rnw-ci/android-emulator.json`, expanded against the runner's actual
home directory) points at a JSON file with exactly two keys:

```json
{
    "image": "redroid/redroid:15.0.0_64only-latest",
    "dataDir": "/var/lib/redroid-prewarm/data"
}
```

- `image` — the Redroid image tag already pulled on this host.
- `dataDir` — a `/data` volume that has already been booted once (with
  animations disabled) and shut down cleanly, so a shard using it skips
  first-boot entirely.

When the manifest is present, the action copies `dataDir` into a per-shard
directory under `RUNNER_TEMP` before mounting it (concurrent matrix shards
must never share one live, writable `/data` — bind-mounting the same
directory into more than one container at once corrupts it). When the
manifest is absent or unreadable, the action falls back to an in-workflow
`docker pull` of `image` and a fresh, uninitialized data volume — slower,
but self-healing rather than hard-failing.

### Producing the manifest on the host

A minimal prewarm script, run once (and re-run whenever you bump the pinned
Redroid image tag):

```bash
#!/usr/bin/env bash
set -euo pipefail

image="redroid/redroid:15.0.0_64only-latest"
data_dir="/var/lib/redroid-prewarm/data"
manifest_path="$HOME/.rnw-ci/android-emulator.json"

sudo docker pull "$image"
sudo modprobe binder_linux devices=binder,hwbinder,vndbinder

sudo rm -rf "$data_dir"
sudo mkdir -p "$data_dir"

sudo docker rm -f redroid-prewarm >/dev/null 2>&1 || true
sudo docker run -d --name redroid-prewarm --privileged \
    --memory 3g --memory-swap 3g --cpus 2 \
    -v "$data_dir":/data -p 127.0.0.1::5555 \
    "$image" androidboot.redroid_gpu_mode=guest

port=$(sudo docker port redroid-prewarm 5555/tcp | head -n1 | sed -E 's/.*:([0-9]+)$/\1/')
adb connect "localhost:$port"
until [ "$(adb -s "localhost:$port" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do
    sleep 5
done
for setting in window_animation_scale transition_animation_scale animator_duration_scale; do
    adb -s "localhost:$port" shell settings put global "$setting" 0
done

sudo docker stop redroid-prewarm
sudo docker rm redroid-prewarm

mkdir -p "$(dirname "$manifest_path")"
cat > "$manifest_path" <<EOF
{
    "image": "$image",
    "dataDir": "$data_dir"
}
EOF
```

Run it from a systemd timer so the prewarmed image/data volume gets
refreshed periodically (e.g. weekly, or whenever the pinned `redroid-image`
in your caller workflow changes):

```ini
# /etc/systemd/system/redroid-prewarm.service
[Unit]
Description=Prewarm Redroid image and data volume for mobile-ci

[Service]
Type=oneshot
ExecStart=/usr/local/bin/redroid-prewarm.sh

# /etc/systemd/system/redroid-prewarm.timer
[Unit]
Description=Weekly Redroid prewarm refresh

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now redroid-prewarm.timer
```

## Maintainer note: fleet self-test repo variables

`self-test.yml`'s `fleet-self-test` job (`workflow_dispatch`-only, since the
self-hosted runners it exercises are shared with consuming repos) resolves
the Xcode version/build it asserts against from two repository variables,
falling back to this repo's own current defaults when unset:

- `MOBILE_CI_SELFTEST_XCODE_VERSION` (falls back to `26.4.1`)
- `MOBILE_CI_SELFTEST_XCODE_BUILD` (falls back to `17E202`)

Set these under this repository's **Settings → Secrets and variables →
Actions → Variables** to whatever Xcode version/build is actually installed
on the fleet's macOS runners at the time, so the fleet self-test asserts
against reality rather than this repo's documentation defaults drifting out
from under the fleet (or vice versa).
