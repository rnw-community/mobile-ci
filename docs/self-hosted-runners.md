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

```text
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

**Pre-existing Homebrew-managed `maestro`.** The `Install Maestro` step in
`run-maestro-ios`, `run-maestro-android-redroid`, and `run-maestro-android`
prefers a `maestro` already on `PATH` when it exactly matches the pinned
`maestro-version`, and otherwise installs the pinned version to
`~/.maestro/bin` and puts that ahead of `PATH` for the rest of the job. The
official `get.maestro.mobile.dev` installer itself refuses to run at all if
it detects an existing Homebrew-managed `maestro`
(`Your maestro installation is already managed by a homebrew`), which
otherwise hard-fails every run on that host. If a host was ever provisioned
with `brew install maestro`, either `brew uninstall maestro` on it once, or
rely on this action's `PATH` override picking up the pinned `~/.maestro/bin`
copy ahead of Homebrew's — do not `brew upgrade maestro` to "fix" a pinned
version mismatch, since the two installs will then compete for `PATH` on
every run.

## Linux `linux-aarch64` Redroid hosts (Android)

Google does not publish `linux-aarch64` builds of the Android emulator, NDK,
or `cmake`, so `reactivecircus/android-emulator-runner` (`run-maestro-android`,
the `avd` driver) is structurally unusable on `linux-aarch64` self-hosted
runners regardless of tuning. `run-maestro-android-redroid` (the `redroid`
driver, `android-maestro.yml`'s default) runs Android as a privileged Docker
container over the host's `binder_linux` kernel module instead, and needs
none of the emulator's `linux-aarch64`-unavailable dependencies.

**Trust boundary: these runners are for trusted workloads only.** `sudo
docker`, `docker run --privileged`, and `sudo modprobe` all grant
root-equivalent access to the host and its kernel — the `NOPASSWD` sudoers
entry below lets any workflow step run arbitrary commands as root, and a
`--privileged` container can affect the host (and therefore every later job
scheduled onto it) well beyond the Android emulation this action uses it
for. Do not point this pool at workflows that run untrusted code (e.g. a
`pull_request` trigger from forks); use dedicated or ephemeral runners for
that case instead, and scope the sudoers entry to the exact `docker` and
`modprobe` invocations this action needs rather than a blanket `NOPASSWD:
ALL` where your sudo policy allows it.

Host requirements:

- **Docker**, with the runner's user able to run `sudo docker ...`
  (the action's every `docker`/`modprobe` invocation is prefixed `sudo`). Grant
  this non-interactively (e.g. a `NOPASSWD` sudoers entry for the runner user)
  — a workflow step has no terminal to answer a password prompt, so an
  interactive-sudo host either hangs the step until it times out or fails it
  outright.
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
staging_dir="${data_dir}.staging"
old_dir="${data_dir}.old"
manifest_path="$HOME/.rnw-ci/android-emulator.json"

sudo docker pull "$image"
sudo modprobe binder_linux devices=binder,hwbinder,vndbinder

# Build the new data volume in a staging directory rather than data_dir
# itself: a shard's cp -a reads dataDir from the manifest at any time,
# including mid-refresh, so rm -rf'ing and re-booting data_dir in place would
# hand a concurrent shard a partially-written or deleted tree. staging_dir is
# swapped into place atomically (same filesystem rename) only after a clean
# boot and shutdown below.
sudo rm -rf "$staging_dir"
sudo mkdir -p "$staging_dir"

sudo docker rm -f redroid-prewarm >/dev/null 2>&1 || true

cleanup() {
    sudo docker rm -f redroid-prewarm >/dev/null 2>&1 || true
}
trap cleanup EXIT

sudo docker run -d --name redroid-prewarm --privileged \
    --memory 3g --memory-swap 3g --cpus 2 \
    -v "$staging_dir":/data -p 127.0.0.1::5555 \
    "$image" androidboot.redroid_gpu_mode=guest

port=$(sudo docker port redroid-prewarm 5555/tcp | head -n1 | sed -E 's/.*:([0-9]+)$/\1/')
# Tolerates failure: Redroid has not necessarily opened 5555 yet immediately
# after `docker run -d` returns, and under set -e a hard failure here would
# abort the script before the boot-wait loop below (which retries adb
# connect every 5s) ever runs — the same race run-maestro-android-redroid's
# own bring-up guards against.
adb connect "localhost:$port" || true
deadline=$((SECONDS + 600))
until [ "$(adb -s "localhost:$port" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do
    if [ "$SECONDS" -ge "$deadline" ]; then
        echo "Redroid did not boot within 600 seconds." >&2
        exit 1
    fi
    sleep 5
    adb connect "localhost:$port" >/dev/null 2>&1 || true
done
for setting in window_animation_scale transition_animation_scale animator_duration_scale; do
    adb -s "localhost:$port" shell settings put global "$setting" 0
done

sudo docker stop redroid-prewarm

# Atomically replace data_dir with the freshly booted-and-shut-down
# staging_dir. Both directories are on the same filesystem, so each mv below
# is a single rename syscall: a concurrent shard's cp -a either sees the
# complete old tree (via its already-open directory handle) or the complete
# new one, never a half-written one.
sudo rm -rf "$old_dir"
if [ -d "$data_dir" ]; then
    sudo mv -T "$data_dir" "$old_dir"
fi
sudo mv -T "$staging_dir" "$data_dir"
sudo rm -rf "$old_dir"

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
User=<runner-user>
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:<path-to-android-sdk>/platform-tools
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

Set `User=` to the same account the GitHub Actions runner service runs as
(replace `<runner-user>`). Without it, systemd runs the unit as root and
writes the manifest to `/root/.rnw-ci/android-emulator.json` — a path
`run-maestro-android-redroid`'s default `prewarm-manifest-path`
(`$HOME/.rnw-ci/android-emulator.json`, expanded against the runner user's own
home directory) never resolves to, so every shard would silently fall back to
a cold `docker pull` and first boot instead of using the prewarmed data.

Replace `<path-to-android-sdk>` in `Environment=PATH=` with the runner
user's actual Android SDK `platform-tools` directory (e.g.
`/Users/<runner-user>/Library/Android/sdk/platform-tools` or
`$ANDROID_HOME/platform-tools`). A system service started with `User=` gets
`HOME` set but does not inherit the runner user's login shell `PATH`, so
`redroid-prewarm.sh`'s unqualified `adb` calls resolve to nothing and the
timer unit fails outright — silently falling back to a cold `docker pull`
and first boot on every subsequent shard, exactly the outcome prewarming
exists to avoid.

```bash
sudo systemctl enable --now redroid-prewarm.timer
```

### Google Play Services (GMS)

Stock `redroid` images are plain AOSP — no Google Play Services, no Play
Store, no Play Integrity. Any app that calls a GMS API at runtime (Google
Wallet/Pay's `isReadyToPay()`, Maps, Firebase Cloud Messaging, Play
Integrity attestation, Google Sign-In, and similar) will hang or fail on
Redroid even though the container boots, `adb` connects, and the APK
installs cleanly — the container-level plumbing this doc covers is not the
problem. This was discovered against a real consumer app: every Maestro
flow timed out at launch, blocked on the app's own
`Wallet.getPaymentsClient().isReadyToPay()` probe, which never resolves
without GMS present in the image.

Options for a consumer app that depends on GMS at runtime:

1. **Provision a GMS-enabled Redroid image.** Layer `gapps`/`microG` into
   the image and reference the resulting tag via `android-maestro.yml`'s
   `redroid-image` input. If a
   [prewarm manifest](#the-redroid-prewarm-manifest) is configured, note
   that `redroid-image` is only consulted on a manifest *miss* — on a hit,
   the container boots from the manifest's own `image` field and its
   already-initialized `dataDir` (a `/data` volume, not the system image
   itself), so a manifest hit silently ignores a `redroid-image` change.
   Point the manifest's `image` at your GMS-enabled tag and rebuild
   `dataDir` from it (re-run [the prewarm script](#producing-the-manifest-on-the-host)
   against the new image), or disable prewarming
   (`redroid-prewarm-manifest-path: ''`, or remove the manifest file) if
   you would rather not rebuild it and are fine paying the cold-boot cost.
2. **Switch to `android-driver: avd` with a `google_apis` system image**
   (`emulator-target: google_apis` is already the default for the `avd`
   driver), on a runner architecture Google actually ships an emulator for
   — x86_64 Linux or macOS `arm64`. This is not an option on this repo's
   default `linux-aarch64` self-hosted pool: Google publishes no
   `linux-aarch64` build of the Android emulator (see above), so `avd`
   cannot boot there regardless of system image.
3. **Gate GMS calls in the app's e2e build variant** (e.g. a build flavor
   or runtime flag that stubs `isReadyToPay()`-style calls under
   Maestro/CI), so the flow under test never depends on GMS being present.
4. **Dismiss the "won't run without Google Play services" dialog at every
   entry point that invokes a GMS-dependent operation, not only the ones
   a flow's own steps tap into.** A hang is not the only symptom: one
   consumer's own logcat showed `GoogleApiAvailability: Google Play
   services is invalid. Cannot recover.` — `ConnectionResult.SERVICE_INVALID`,
   which per Google's docs means the installed Play Services package
   failed its own authenticity check, a generic availability signal, not
   a statement that any specific GMS API (Wallet/Payments included) is
   unsupported. On Redroid there is no Play Services package at all, so
   every GMS-dependent operation hits this same code once invoked.
   `Wallet.getPaymentsClient()` itself only builds a `PaymentsClient`
   object and is harmless on its own; it was the readiness call chained
   right after it (that consumer's own `isReadyToPay()` probe) whose
   connection failure Play Services' bundled fallback UI surfaced as a
   blocking system dialog, instead of the hang option 3 above is written
   around — a client built in one place can invoke the actual
   GMS-dependent operation later or elsewhere, so place the dismissal
   after that invocation, not around wherever the client happens to be
   constructed. Their flows guarded the one entry point a flow step
   drove directly (a button tap that shows the payment sheet, and
   invokes `loadPaymentData` right behind it) with a
   `tapOn: {text: "OK", optional: true}` right after the triggering step,
   but missed that `isReadyToPay()` also fires from the app's own
   effect-driven mount logic, with no flow step to hang a dismissal off.
   Every flow shared a `launchApp` subflow, so the dialog occluded the
   app's own elements from the very first assertion of every flow, not
   just the ones that reach the guarded button. The fix was the same
   optional dismissal placed right after `launchApp` in the shared
   subflow, since that is where the mount-time probe's invocation
   effectively lands — the lesson is to audit *every* code path that
   invokes a GMS-dependent operation (including ones triggered by app
   lifecycle, not user action) rather than stopping at the first one a
   flow happens to exercise.

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
