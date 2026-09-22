# Self-hosted runners

Every action and reusable workflow in this repo assumes a self-hosted fleet.
Nothing here works out of the box on GitHub-hosted runners for the Android
`redroid` driver (needs `binder_linux`, a host kernel module) or for iOS
(needs a real Xcode install, not the one GitHub's hosted macOS images ship
with several versions of but no `.xcconfig`-level pinning guarantee across
runs). This doc covers provisioning both pool types plus the two variables
this repo's own maintainer-only fleet self-test job reads.

## Common to every macOS pool: `python3`

macOS pools need `python3` on `PATH`, which the **Xcode Command Line Tools**
install (`xcode-select --install`) — a host that can run `xcodebuild` normally
already has it. [`xcodebuild-test`](../actions/xcodebuild-test/README.md) uses
it to rewrite the generated `.xctestrun`'s screen-capture format (see [UI tests
capture screenshots, not video](#ui-tests-capture-screenshots-not-video)). On
Linux Redroid hosts, `redroid-container` needs it only when a prewarm manifest
is present — it reads the manifest's `image` and `dataDir` with it.

Missing `python3` does not fail a run there: the rewrite is skipped with a
warning and the run pays Xcode's UI-test video for that job. It is a
pool-provisioning defect, not a test failure, so it is reported as one.

[`xcodebuild-affected-tests`](../actions/xcodebuild-affected-tests/README.md)
also needs it, and fails the step without it: that action decides which tests
*not* to run, and a selector that cannot read its map must never be taken for
"nothing is affected".

## Common to every pool: `jq`

Install `jq` on every host in every pool. The reusable workflows' package
manager resolution reads `package.json`'s `devEngines.packageManager` /
`packageManager` field with it (see
[README.md#package-manager](../README.md#package-manager)), and several
composite actions (`capture-screenshots-ios`, `capture-screenshots-android`,
`asc-dedupe-screenshots`) already require it outright. Without `jq` the
resolve step warns and falls back to root-lockfile detection, which is enough
for Yarn and npm but **fails closed for pnpm** — pnpm's version can only come
from `package.json`.

## Which pool a job belongs on

One rule, stated once: **a job runs on the cheapest pool that can actually
run it, and a macOS pool only when the job needs macOS.** Concretely, on a
fleet whose macOS hosts also host Linux guests, every Linux guest on a Mac
consumes one of that host's two Apple-Virtualization slots — i.e. one of its
macOS job slots — so a Linux job parked on a Mac's Linux guest is paid for
twice: once in its own runtime and once in the iOS build it displaced.

| Job | Pool | Why |
| --- | --- | --- |
| `xcodebuild`, Simulators, iOS Maestro, `capture-screenshots-ios`, Apple signing/upload | macOS | needs Xcode and CoreSimulator; nothing else can run it |
| Android build (`build-android-app`, `seed-native-cache`'s `seed-android`), Android Maestro on the `avd` driver | x86_64 Linux KVM | Google ships an x86_64 Linux NDK/cmake/emulator; a 4 vCPU / 8 GiB profile fits Gradle+D8, or a bounded AVD plus Maestro |
| Android Maestro/screenshot capture on the `redroid` driver | `linux-aarch64` Redroid host | needs `binder_linux` + `docker run --privileged`; the Redroid shape for running Android on arm64 Linux (a macOS arm64 pool can run an arm64 AVD instead) |
| Manifest/JSON/shell-only steps | the smallest Linux profile on the fleet (e.g. a 2 vCPU / 4 GiB profile) | no toolchain, no device |

This repo's own defaults follow that rule: `android-maestro.yml`'s
`runner-labels` and `seed-native-cache.yml`'s `android-runner-labels` default
to `["self-hosted","trf-linux-amd64-4x8"]` — the x86_64 Linux KVM shape
documented under [Linux x86_64 KVM hosts](#linux-x86_64-kvm-hosts-android-avd-driver)
— and `android-maestro.yml`'s `android-driver` defaults to `avd` to match,
since `redroid` cannot run on that shape. The one deliberate exception is
`store-screenshots.yml`'s `android-capture-runner-labels`, which stays on a
Redroid-capable Linux pool: `capture-screenshots-android` drives a
`redroid-container` and has no `avd` code path at all.

Label names are a property of your fleet, not of this repo. The defaults name
the labels of the fleet this repo is developed against; on another fleet,
override them to whatever labels carry the same host shape.

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

**Pin `simulator-device` once the pool has more than one host.** Left empty,
`run-maestro-ios`/`ios-maestro.yml`'s `simulator-device` boots the last
available iPhone-family device by `xcrun simctl list devices available`
order — an order that depends on exactly which simulator runtimes and
devices are provisioned on that specific host, so it can silently boot a
different device than the last run, or a different device than a sibling
host in the same pool, with no diff anywhere. Pin an exact device name (e.g.
`iPhone 17 Pro`) once a flow's rendering is sensitive to device shape, and
make sure every host in the pool has that exact device provisioned — a
pinned name that only exists on some hosts turns an intermittent heuristic
mismatch into a hard, host-dependent failure instead.

**Pre-existing Homebrew-managed `maestro`: no host action needed.** The
`Install Maestro` step in `run-maestro-ios`, `run-maestro-android-redroid`,
and `run-maestro-android` prefers a `maestro` already on `PATH` when it
exactly matches the pinned `maestro-version`, and otherwise downloads that
exact `cli-<version>` release directly from
`https://github.com/mobile-dev-inc/Maestro/releases` (verifying its
published `checksums_sha256.txt` when present) and extracts it to
`$HOME/.maestro-pinned/<version>`, which it puts ahead of `PATH` for the
rest of the job. This sidesteps `~/.maestro` entirely, so it never invokes
(and is never refused by) the official `get.maestro.mobile.dev` bootstrap
script, which itself refuses to run at all if it detects an existing
Homebrew-managed `maestro` (`Your maestro installation is already managed by
a homebrew`). A Homebrew-installed `maestro` on a host is therefore
harmless: the action either reuses it (exact version match) or ignores it in
favor of its own pinned copy — no `brew uninstall`/`brew upgrade` is
required, and a host is free to keep whatever Homebrew-managed `maestro` it
already has.

### Every simulator runs slim

Every iOS simulator mobile-ci touches — a leased device, a host device a
Maestro shard boots, a capture job's device, or a developer's local simulator —
runs slim. A stock simulator sits at roughly 4 GB of `phys_footprint` once
booted, and that figure, not CPU, is what caps how many `run-maestro-ios`
shards or `capture-screenshots-ios` jobs a macOS host can run at once before it
starts swapping. [simslim](https://github.com/MobAI-App/simslim) (MIT, Go,
macOS only) disables ~170 launchd daemons a CI simulator never needs by writing
persistent `launchctl disable` overrides into that one simulator's launchd
database, cutting a booted simulator to roughly a quarter of the memory. The
host itself is never touched, and `simslim off` restores stock.

The order is always **boot → slim → install → drive**: slimming after the app
is installed and fixtures are seeded wastes a boot cycle, and slimming is only
possible on a device that exists.

**The profile lives here.** [`profiles/ci.json`](../profiles/ci.json) keeps the
`store` category (App Store, push notifications, StoreKit, media) and the `web`
category (Safari sync, web push, universal links) enabled and disables every
other category `simslim profiles` lists — the set a UI-test or screenshot run
actually depends on. It is the single source of truth for CI and local runs
alike, so a consumer repo commits no profile of its own.

**In CI, nothing calls simslim by hand.** `simulator-lease`,
`run-maestro-ios` and `capture-screenshots-ios` resolve the special value
`bundled` to that file, and the reusable workflows (`ios-maestro.yml`,
`store-screenshots.yml`, `swift-ios.yml`) default `simulator-slim-profile` to
`bundled` and `simulator-slim-repair` to `'true'`, with `simslim-version` and
`simslim-sha256` pinned here too. A caller passes none of them:

```yaml
with:
    simulator-device: iPhone 17 Pro
    simulator-requires: push,universal-links
```

`simulator-requires` stays per consumer — which features the flows depend on is
a property of the app, not of the fleet. Override `simulator-slim-profile` with
a repository-relative path to use a different profile, or set it to `''` to opt
out of slimming entirely.

**Locally, use the shared helper** rather than a copy of it. Fetch it once at a
pinned tag and source it:

```bash
brew install mobai-app/tap/simslim
curl -fsSL https://raw.githubusercontent.com/rnw-community/mobile-ci/v2/scripts/slim-simulator.sh \
    -o /usr/local/bin/slim-simulator.sh

xcrun simctl boot "$udid"
. /usr/local/bin/slim-simulator.sh && slim_simulator "$udid"
xcrun simctl install "$udid" MyApp.app
```

`slim_simulator <udid>` verifies against the profile and only applies the
missing delta (`simslim on --no-reboot --profile`) when the device has drifted,
so it is idempotent and never drops an installed app or a seeded fixture.
`slim_booted_simulators` does the same for every booted device, and running the
script instead of sourcing it does exactly that. It fails fast with the
Homebrew hint when `simslim` is missing. The profile is taken from
`$SIMSLIM_PROFILE` when set, then from `profiles/ci.json` next to the script's
parent directory, and otherwise downloaded from `$SIMSLIM_PROFILE_REF`
(default `v2`) — so a lone copy of the script still slims against the same
profile CI uses.

**Provisioning: pay for it once.** The overrides persist across reboots, so
slim a host's devices at provisioning time and let the job only verify:

```bash
for udid in $(xcrun simctl list -j devices available \
        | jq -r '.devices[][] | select(.name == "iPhone 17 Pro") | .udid'); do
    simslim on "$udid" --profile /path/to/profiles/ci.json --boot-timeout 15m
    simslim verify "$udid" --profile /path/to/profiles/ci.json
    simslim measure "$udid"
done
```

Then set `simulator-slim-repair: 'false'` in the caller so a device that comes
up stock fails the job as the provisioning defect it is, instead of paying for
an in-job `simslim on` reboot on every shard.

**Leased simulators: clone a slimmed template.** `run-maestro-ios` and
`capture-screenshots-ios` boot a device the host already owns, so the loop
above is the whole story for them. `simulator-lease` is different: it *creates*
the device it hands to `xcodebuild-test`, and a freshly created device is
always stock. That is why its `slim-repair` defaults to `'true'` (the opposite
of `run-maestro-ios`) — with only `slim-profile` set, every lease pays one
`simslim on` reboot.

The way to stop paying it is `template-device`. `xcrun simctl clone` copies the
device's launchd disable overrides along with the device, so a clone of a
slimmed, **shut-down** template is slim from its first boot:

```bash
# Host provisioning, once per image: one shut-down, slimmed template per device type.
udid=$(xcrun simctl create 'trf-template-iPad Pro 11-inch (M4)' \
    'com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4' \
    "$(xcrun simctl list runtimes -j | jq -r '[.runtimes[] | select(.isAvailable and (.identifier | contains("iOS")))] | sort_by(.version | split(".") | map(tonumber)) | last.identifier')")
simslim on "$udid" --profile /path/to/profiles/ci.json --boot-timeout 15m
simslim verify "$udid" --profile /path/to/profiles/ci.json
simslim measure "$udid"
xcrun simctl shutdown "$udid"
```

```yaml
with:
    template-device: 'trf-template-iPad Pro 11-inch (M4)'
    slim-repair: 'false'
```

`slim-repair: 'false'` is the point of the pairing: with a template in place, a
lease that comes up stock means the *image* lost its slimming, and that should
fail loudly rather than be repaired on every run. The action also refuses to
clone a template that is booted — a template is provisioning state, never a
job's device.

### Templates the image can bake

Naming a template in the consumer's workflow means the consumer has to know
what the host image ships. `simulator-lease`'s `template-strategy: auto` (and
`swift-ios.yml`'s `simulator-template-strategy: auto`) removes that coupling:
the job looks for a **shut-down, available device whose name starts with
`mobile-ci-template-` and whose device type and runtime both match the lease**,
verifies it with `simslim verify --profile` and clones it. Nothing matches?
The lease is created and slimmed exactly as before, and a shut-down copy is
left behind for the next job on that host.

**The naming rule is the contract between this repo and the image:**

```text
mobile-ci-template-<device-type-slug>-<runtime-slug>
```

where each slug is the name lowercased with every run of non-alphanumeric
characters collapsed to a single `-`, and the runtime slug is taken from the
last dot-separated component of the runtime identifier:

| Device type             | Runtime identifier                                | Template name                                     |
| ----------------------- | ------------------------------------------------- | ------------------------------------------------- |
| `iPad Pro 11-inch (M4)` | `com.apple.CoreSimulator.SimRuntime.iOS-26-0`     | `mobile-ci-template-ipad-pro-11-inch-m4-ios-26-0`  |
| `iPhone 17 Pro`         | `com.apple.CoreSimulator.SimRuntime.iOS-26-0`     | `mobile-ci-template-iphone-17-pro-ios-26-0`        |

Only the prefix, the device type and the runtime are matched, so a template
baked under the exact name above is found, and a template of another runtime
or another device type is never cloned in its place.

**On a fleet of one-job VM clones, bake it into the image.** The fleet
([`vitalyiegorov/tart-runner-fleet`](https://github.com/vitalyiegorov/tart-runner-fleet))
gives every job a fresh clone of a base image, so the copy a job leaves behind
dies with the VM: the persistent win requires the template to exist in the base
image. Add this to the image build right after its "Prewarm the simulators"
and "Slim the simulators" steps (`docs/BASE_IMAGE.md`), once per device type
the fleet's tenants lease:

```sh
export DEVELOPER_DIR=/Applications/Xcode_26.4.1.app/Contents/Developer
profile=~/.fleet/simslim.fleet.json     # or mobile-ci's profiles/ci.json

bake_template() {
    device_type="$1"
    device_type_id="$(xcrun simctl list devicetypes -j \
        | jq -r --arg name "$device_type" '[.devicetypes[] | select(.name == $name) | .identifier] | first')"
    runtime_id="$(xcrun simctl list runtimes -j \
        | jq -r '[.runtimes[] | select(.isAvailable and (.identifier | contains("iOS")))]
                 | sort_by(.version | split(".") | map(tonumber)) | last.identifier')"
    slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'; }
    name="mobile-ci-template-$(slug "$device_type")-$(slug "${runtime_id##*.}")"

    # One template per device type + runtime: never create a second.
    if xcrun simctl list devices -j | jq -e --arg name "$name" \
        '[.devices[][] | select(.name == $name)] | length > 0' > /dev/null; then
        echo "$name already exists"; return 0
    fi

    udid="$(xcrun simctl create "$name" "$device_type_id" "$runtime_id")"
    xcrun simctl boot "$udid"
    xcrun simctl bootstatus "$udid" -b
    simslim on "$udid" --profile "$profile" --boot-timeout 15m
    simslim verify "$udid" --profile "$profile"
    simslim measure "$udid"
    xcrun simctl shutdown "$udid"          # a template is always shut down
}

bake_template 'iPad Pro 11-inch (M4)'
bake_template 'iPhone 17 Pro'
```

`pony-labirinth` leases `iPad Pro 11-inch (M4)` on the newest installed iOS
runtime, so the device the image must carry for it is
**`mobile-ci-template-ipad-pro-11-inch-m4-ios-26-0`** (the runtime slug follows
whatever `simctl` reports as newest — re-derive it with the snippet above
rather than hard-coding `26-0` if the image's runtime changes).

Leaving the template **shut down** is not cosmetic: the action refuses to clone
a booted device, because a booted template is a device something else is using.
Do not `simctl erase` a template afterwards — that resets it to stock, and the
lease will fail `simslim verify` on the clone.

**The fleet base image should ship these templates.** Measured inside
pony-labirinth's live UI-test VM (`maestro` profile, 7 GiB), a stock leased
simulator ran **272 RuntimeRoot processes** — Calendar, News and Maps widgets,
a Safari extension, Spotlight — with about **2 GB in the compressor and ~14 MB
of free pages**. The UI-test step there was memory-starved, not CPU-bound. This
also gates `-parallel-testing-worker-count`: each worker is a *clone* of the
leased device, so raising it on a stock lease multiplies that footprint, while
clones of a slim lease inherit the overrides.

**What resets a simulator to stock.** `xcrun simctl erase`, delete-and-recreate,
"Erase All Content and Settings", and every device created from a newly
installed runtime come up stock with no error anywhere - the simulator just
runs heavy again, and a pool that was sized for slim simulators starts
swapping. `simslim verify` in the job catches exactly this and fails the shard
naming the drift; re-run the loop above on that host. Set
`simulator-slim-repair: 'true'` only if you would rather have the shard repair
itself with an in-job `simslim on` (one extra reboot) than fail.

**What slimming breaks, and `simulator-requires`.** Spotlight (`search`),
push notifications (`apsd` in `store`), StoreKit testing (`storekitd`),
universal links (`swcd` in `web`), and the Contacts/Photos/Calendar pickers
stop working when their category is disabled. Keep a whole category with the
profile's `except` array or one daemon with `keep`, and declare the features
the flows depend on in `simulator-requires` (`simslim doctor --list` prints the
IDs) so a profile edit that drops one fails the job before the first flow
instead of as a flaky assertion.

**Runtime floor and the pinned binary.** Only iOS 18.5 and newer runtimes keep
the overrides across a reboot; older runtimes accept them and silently come
back stock. The actions reuse a `simslim` already on `PATH` when its
`simslim version` matches the pinned `simslim-version` exactly, and otherwise
download the `macos-arm64` release tarball into `$HOME/.simslim-pinned`,
check its SHA-256 against the `simslim-sha256` input, and extract the binary
into a job-private directory; the cached tarball is re-hashed on every later
job, so a tampered file on disk is refused rather than reused. MobAI-App/simslim
publishes no checksum file, so that digest is maintained in this repo next to
the default `simslim-version` and must be bumped with it; an empty
`simslim-sha256` refuses to download at all. Preinstalling via Homebrew as
above keeps the job off the network and the supply chain in the host's hands. Intel hosts must preinstall (`go install
github.com/mobai-app/simslim/cmd/simslim@v<version>`); no x86_64 release
asset exists and the install step fails closed on `uname -m != arm64`.

**Optional disk hygiene.** `simslim disk-plan <udid>` reports reclaimable
per-device caches, logs, and temporary files read-only; `simslim disk-clean
--categories caches,logs,temporary --confirm <udid>` deletes them. Neither is
run by any action; schedule it alongside runtime cleanup if simulator disk
growth is a problem on a pool.

### UI tests capture screenshots, not video

Slimming the simulator is not the whole memory story on a 7 GiB guest. Xcode 26
records a **video of every UI test** — `PreferredScreenCaptureFormat =
screenRecording` in the generated `.xctestrun` — and the encoder that produces
it, `VTEncoderXPCService`, was measured on a 4 CPU / 7 GiB `maestro` guest at
**~1 GB of RSS and a full core**: the single largest consumer in a run whose
free memory never rose above ~50 MB, with 100+ attachments accumulated in the
`.xcresult` after half an hour
([#147](https://github.com/rnw-community/mobile-ci/issues/147)). On a host with
four cores and seven gigabytes, that is a quarter of the CPU and a seventh of
the memory spent on a recording that `deleteOnSuccess` throws away whenever the
run is green.

So [`xcodebuild-test`](../actions/xcodebuild-test/README.md) defaults
`screen-capture` to `screenshots` and rewrites the `.xctestrun` before the run.
Nothing is needed on the host, and failure evidence is unchanged — screenshots
are still attached to the uploaded `.xcresult`. A pool with memory and cores to
spare can ask for `screen-capture: screenRecording` per job.

This is also why the "two XCUITest workers in one VM" experiment (#147) was
*not* adopted: two workers measured 0.81× the wall time of one and produced a
timing flake, because the guest was memory-bound before the second worker
existed. Re-measure that only on a quiet host, on the 6x12 builder profile,
after the encoder is gone.

### One test job, one simulator

`-parallel-testing-enabled YES` does not merely allow more workers: Xcode
clones the destination simulator and runs the tests on
`Clone 1 of <destination>` even with a single worker. A `simulator-lease` job
then holds two simulators on a 7 GiB guest — the leased device it booted,
slimmed and verified, and a clone `simslim` never saw.

Measured on pony-labirinth
([#155](https://github.com/rnw-community/mobile-ci/issues/155), 2026-09-22):
with the clone, two shards ran ~30 minutes each and produced 4 timeout
failures; the same 71 XCUITests finished in 20m18s on one simulator on the same
host and VM class the same day.

[`xcodebuild-test`](../actions/xcodebuild-test/README.md) therefore defaults
`parallel-testing` to `'NO'`, and **fails the step** when a caller asks for
`'YES'` without an explicit `parallel-testing-worker-count`. Nothing is needed
on the host. Raise workers only on the 6x12 builder profile, on a slimmed
lease, and measure the wall time before keeping it:

```yaml
with:
    runs-on-json: '["self-hosted","trf-macos-arm64-6x12"]'
    parallel-testing-worker-count: '2'
```

## Linux `linux-aarch64` Redroid hosts (Android)

Google does not publish `linux-aarch64` builds of the Android emulator, NDK,
or `cmake`, so `reactivecircus/android-emulator-runner` (`run-maestro-android`,
the `avd` driver, `android-maestro.yml`'s default) is structurally unusable on
`linux-aarch64` self-hosted runners regardless of tuning.
`run-maestro-android-redroid` (the `redroid` driver, selected explicitly
together with `runner-labels` pointing at this shape) runs Android as a privileged Docker
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

**A hang is not the only failure signature to watch for.** A GMS-dependent
call can instead resolve immediately into Play Services' own fallback UI: a
full-screen, unrecoverable system dialog ("… won't run without Google Play
services, which are not supported by your device.") from a *different*
package (`com.google.android.gms`), not the app under test. Because that
dialog sits on top of and blocks the accessibility tree Maestro walks, every
subsequent assertion against the app's own elements times out — the
observed symptom is `assertVisible` timing out on an app element that
should obviously be rendered, which gives no hint that the real cause is a
system dialog from another package rather than a bug in the app or the
flow. If you see an inexplicable `assertVisible` timeout like this, capture
`logcat` before debugging the app itself and check for the marker
`GoogleApiAvailability: Google Play services is invalid. Cannot recover.`
first — see option 4 below for what that log line does and does not mean.

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
   — x86_64 Linux or macOS `arm64`. This is what `android-maestro.yml`
   defaults to; it is only unavailable if you have pointed the run at a
   `linux-aarch64` pool, where Google publishes no build of the Android
   emulator (see above) and `avd` cannot boot regardless of system image. See
   [Linux x86_64 KVM hosts](#linux-x86_64-kvm-hosts-android-avd-driver) below
   for that host shape's requirements.
3. **Gate GMS calls in the app's e2e build variant** (e.g. a build flavor
   or runtime flag that stubs `isReadyToPay()`-style calls under
   Maestro/CI), so the flow under test never depends on GMS being present.
4. **Dismiss the "won't run without Google Play services" dialog at every
   entry point that invokes a GMS-dependent operation, not only the ones
   a flow's own steps tap into.** A hang is not the only symptom: one
   consumer's own logcat showed, verbatim and reproducibly across every
   shard, `GoogleApiAvailability: Google Play services is invalid.
   Cannot recover.` — `ConnectionResult.SERVICE_INVALID`. Per Google's
   docs `SERVICE_INVALID` textbook-describes an *installed* package
   failing its own authenticity check, which is not literally what a
   stock Redroid image (no Play Services package at all) sounds like it
   should hit — `SERVICE_MISSING` looks like the closer fit on paper.
   Empirically, on this fleet's Redroid image it is `SERVICE_INVALID`
   every time (the log line is reproducible, not a one-off); the
   evidence takes precedence over that assumption, and either way the
   code is a generic Play Services availability signal, not a statement
   that any specific GMS API (Wallet/Payments included) is unsupported.
   On this Redroid image every GMS-dependent operation hits this same
   code once invoked.
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

## Linux x86_64 KVM hosts (Android, `avd` driver)

The Redroid shape above is not the only supported Android host shape.
`android-maestro.yml`'s `avd` driver (`reactivecircus/android-emulator-runner`,
`run-maestro-android`) is fully supported too, on an x86_64 Linux host with
KVM — no `binder_linux`, no privileged container, no Docker daemon at all.
This is the shape for a rootless-container runner pool (e.g. rootless
Podman-backed runners) where `--privileged` and `sudo modprobe` are off the
table entirely: KVM passthrough needs neither.

Host requirements:

- **`/dev/kvm` exposed to the runner.** The runner process (or its
  container, if the runner itself runs containerized) needs read/write
  access to `/dev/kvm` — a KVM-capable instance profile/hypervisor
  configuration is a prerequisite this doc cannot provision for you; verify
  it at the virtualization layer before touching the Android SDK.
- **Android SDK with `emulator` plus a `google_apis` x86_64 system image**
  matching `android-maestro.yml`'s `emulator-api-level`/`emulator-target`/
  `emulator-arch` inputs (e.g. `android-34`, `google_apis`, `x86_64`).
  `reactivecircus/android-emulator-runner` installs and caches these itself
  via the Android SDK manager. No `binder_linux`, no privileged containers,
  and no Docker daemon are needed on this shape at all.
- **Give the emulator room inside the runner's memory limit, and bound it
  explicitly.** On a container-backed pool the cgroup limit is the ceiling
  the emulator actually lives under, and exceeding it does not surface as an
  out-of-memory error: the kernel kills qemu — the largest RSS in the
  container — and the job continues against a device that has silently
  vanished. Maestro then reports a refused adb connection and
  `You have 0 devices connected, which is not enough to run 1 shards`, minutes
  into a run whose earlier flows passed. Measured on a 4 vCPU / 8 GiB
  container: the AVD alone sits near 4.2 GiB, and the emulator plus Maestro's
  JVM plus the runner's own Node processes reached the 8 GiB ceiling partway
  through a shard. Either give the profile headroom above the AVD's footprint
  or set `emulator-ram-size` (and `emulator-heap-size`) so the guest cannot
  grow into the limit. `redroid-memory` is the equivalent knob on the other
  driver.
- **Gate on `emulator -accel-check` before trusting the pool.** A host
  missing `/dev/kvm` access does not necessarily refuse to boot an AVD — it
  can silently fall back to software emulation, which eventually boots but
  is far too slow for a CI budget and gives no clear signal that the host is
  misconfigured. Run `emulator -accel-check` as a host health-check (or a
  preflight step ahead of the real job) and fail closed on anything other
  than confirmation that hardware acceleration is available, rather than
  discovering the problem later as an intermittent timeout in the test job.

Observed characteristics from a real fleet, useful for sizing this pool
(specific to a headless `google_apis`/x86_64 AVD; expect these to move with
API level, host CPU, and image build — treat them as a starting point, not a
guarantee):

- **~23 seconds** cold boot to `sys.boot_completed`.
- **~4.2GB RSS** at a 4 vCPU / 8GiB host shape.

### Choosing an Android driver

`android-maestro.yml`'s `android-driver` input picks which of these two host
shapes a run needs, and both are fully supported — the choice is per-fleet,
not a migration from one to the other:

- **`avd`** (default) needs the x86_64 KVM shape documented in this section,
  which is also what `runner-labels` defaults to. A `google_apis` system image
  carries real Google Play Services, at the cost of requiring the app under
  test to build (or include) an x86_64 ABI.
- **`redroid`** needs the `linux-aarch64` binder/privileged-docker shape
  documented above, and runs Android natively on arm64 — required if your app
  ships (or you must test) an arm64-only APK. Stock images carry no Google
  Play Services (see [GMS](#google-play-services-gms) above). Selecting it
  means overriding `runner-labels` too: it cannot run on the default pool.

Set `android-driver` together with `runner-labels` (or the split
`build-runner-labels`/`test-runner-labels`) from the consumer workflow to
route a run at the host shape it needs — see
[docs/workflows/android-maestro.md](workflows/android-maestro.md) for the
full input reference.

### EAS local builds (`native-publish`/`seed-native-cache`/`native-dev-release`)

`native-publish.yml`, `seed-native-cache.yml`, and `native-dev-release.yml`
all default their `android-runner-labels` input to the same macOS pool as
iOS (`["self-hosted","macOS","ARM64"]`), not because the Android build needs
a Mac, but because Google's Android NDK build tooling used by `eas build
--local` is x86_64-only on Linux — there is no `linux-aarch64` NDK to run it
with, the same gap that rules out the `redroid`-only `linux-aarch64` shape
for an Android build. An x86_64 Linux KVM host — the same shape
`android-maestro.yml` and `seed-native-cache.yml` now default to — is
x86_64-native and can serve these Android EAS build jobs too. Per
[Which pool a job belongs on](#which-pool-a-job-belongs-on) that is where
they belong; point `android-runner-labels` at it rather than accepting the
macOS default, which remains only because no run has yet proven `eas build
--local` on this fleet's x86_64 Linux containers.

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
