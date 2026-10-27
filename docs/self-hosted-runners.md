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
| Android build (`build-android-app`, `seed-native-cache`'s `seed-android`), Android Maestro and `store-screenshots.yml`'s Android capture on the `avd` driver (`android-emulator`) | x86_64 Linux KVM | Google ships an x86_64 Linux NDK/cmake/emulator; a 4 vCPU / 8 GiB profile fits Gradle+D8, or a bounded AVD plus Maestro |
| Android Maestro/screenshot capture on the `redroid` driver | `linux-aarch64` Redroid host | needs `binder_linux` + `docker run --privileged`; the Redroid shape for running Android on arm64 Linux (a macOS arm64 pool can run an arm64 AVD instead) |
| `expo-base-plan.yml`'s plan/repack job (`expo-native-key`, `expo-base-binary`, `expo-repack`) | x86_64 Linux | re-bundles JavaScript and rewrites an archive: no Xcode, no simulator, no emulator, no KVM — see [The Linux repack pool](#the-linux-repack-pool-expo-e2e-and-screenshot-runs) |
| Manifest/JSON/shell-only steps | the smallest Linux profile on the fleet (e.g. a 2 vCPU / 4 GiB profile) | no toolchain, no device |

This repo's own defaults follow that rule: `android-maestro.yml`'s
`runner-labels` and `seed-native-cache.yml`'s `android-runner-labels` default
to `["self-hosted","trf-linux-amd64-4x8"]` — the x86_64 Linux KVM shape
documented under [Linux x86_64 KVM hosts](#linux-x86_64-kvm-hosts-android-avd-driver)
— and `android-maestro.yml`'s `android-driver` defaults to `avd` to match,
since `redroid` cannot run on that shape. The one deliberate exception is
`store-screenshots.yml`'s `android-capture-runner-labels`, which stays on a
Redroid-capable Linux pool because its `android-driver` still defaults to
`redroid`. The capture leg has an `avd` driver too — the same
`android-emulator` action the Maestro shards boot with — so passing
`android-driver: avd` with `android-capture-runner-labels:
'["self-hosted","trf-linux-amd64-4x8"]'` moves it onto the KVM pool. Both
defaults flip only after an `avd` capture run has been validated on the
fleet.

Label names are a property of your fleet, not of this repo. The defaults name
the labels of the fleet this repo is developed against; on another fleet,
override them to whatever labels carry the same host shape.

## The Linux repack pool (Expo e2e and screenshot runs)

A pull request does not compile native code for an Expo e2e or screenshot run
any more. `expo-base-plan.yml`'s `plan` job — the shared decision
`ios-maestro.yml`, `android-maestro.yml`, `store-screenshots.yml` and
`seed-native-cache.yml` all call — computes the native key with
[`expo-native-key`](../actions/expo-native-key/README.md), fetches the base
binary published for it with
[`expo-base-binary`](../actions/expo-base-binary/README.md), and turns that base
into this commit's binary with
[`expo-repack`](../actions/expo-repack/README.md). Only a key with no published
base reaches a Mac (iOS) or a Gradle build (Android). The contract is in
[repack.md](repack.md).

Per [Which pool a job belongs on](#which-pool-a-job-belongs-on), that job
belongs on the **x86_64 Linux pool without KVM**: it re-bundles JavaScript and
rewrites an archive. `["self-hosted","trf-linux-amd64-2x4"]` (2 vCPU / 4 GiB, no
`/dev/kvm`) is the default `repack-runner-labels` / `plan-runner-labels` value in
every caller, so plan and repack jobs never queue behind Android emulator shards
on the KVM pool ([#169](https://github.com/rnw-community/mobile-ci/issues/169)).
Do not point them at a label also served by arm64 guests: Google publishes the
Android build-tools for x86_64 Linux only.

**What a repack host needs:**

- **Node and the repository's package manager.** The job installs JS
  dependencies and runs Metro exactly as a build job does — `actions/setup-node`
  provisions Node, `jq` resolves the manager (see
  [Common to every pool: `jq`](#common-to-every-pool-jq)), and a `pnpm`
  consumer still needs its version declared in the root `package.json`.
- **`jq`, `unzip`, `tar`, `curl`.** `unzip` reads and asserts the APK's
  embedded bundle and `app.config`, `tar` unpacks and repacks the iOS `.app`
  archive, `curl` fetches the pinned `oras` when one has to be downloaded, and
  `jq` carries the per-target plan between the `plan` and `native-targets`
  jobs.
- **iOS only: `python3`.** `@expo/repack-app` rewrites the `Info.plist` with
  macOS `plutil`; on a host without one, `expo-repack` provides a `python3`
  stand-in for the two conversions it makes (see
  [repack.md](repack.md#what-the-linux-repack-host-has-to-provide)).
- **Android only: a JDK 17 on the host.** Nothing in the repack job installs
  one, and both `sdkmanager` and `apksigner` are Java programs. The Android
  build-tools themselves (`zipalign`, `apksigner`) are *not* a host
  prerequisite: the job installs
  `platform-tools build-tools;<android-build-tools-version>` itself through
  `android-actions/setup-android`, and `expo-repack` resolves that directory
  under `ANDROID_SDK_ROOT` — nothing has to put it on `PATH`.

**What a repack host does not need:** no Xcode, no simulator, no emulator, no
`/dev/kvm`, no `binder_linux`, no privileged container. A repack never boots a
device and never compiles native code; that is the entire point of moving it
off the Mac.

**`hermesc` does not have to be on `PATH`.** Metro and `@expo/repack-app`
resolve the `hermesc` shipped inside the repository's own `react-native`
package, which is also the only copy whose bytecode version is guaranteed to
match the base binary's runtime. Installing a system-wide Hermes compiler on
the image buys nothing and risks a mismatch.

**`oras` is verified, not assumed.** `expo-base-binary` reuses an `oras`
already on `PATH` only when it is *exactly* the pinned version — `1.3.4` at the
time of writing; the authority is `oras-version`'s default in
[`actions/expo-base-binary/action.yml`](../actions/expo-base-binary/action.yml).
Otherwise it downloads that release's asset for the runner's OS and
architecture and checks it against the action's `oras-checksums` before running
it; an OS/arch with no checksum entry fails the step by name rather than
executing an unverified binary. Preinstalling the pinned `oras` on the image
saves one download per job — it is an optimisation, not a host requirement.

### What the macOS pool is still for

The macOS pool does not go away; its role shrinks to two things:

- **the rare native-change build.** When a native key has no published base —
  an Expo or React Native upgrade, a new native module, a changed
  `fingerprint.config.js` — the Mac compiles it, and a default-branch run then
  publishes that base so the next pull request repacks instead.
- **the Maestro and screenshot-capture shards.** They install and drive an iOS
  Simulator, and a Simulator only exists on macOS. Nothing about the repack
  default changes that.

That second role is why the sizing advice above still applies to the macOS
pool, and the first is why [`xcode-cache`](../actions/xcode-cache/README.md)
ships a persistent `local` backend. A native-change build on this fleet is not
the near-cold build it would be on a hosted runner, where a 10 GB repository
cache quota evicts DerivedData, the Swift Package clones and the Xcode 26
compilation cache between runs: the Mac keeps its compile cache on the host, in
a directory every VM mounts, so the one build that does reach a Mac starts warm
from the last one that did.

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

**Rosetta 2 on arm64 test hosts for `ios-simulator-archs: x86_64`.** An app
built as an x86_64 Simulator slice (because a native SDK ships no
arm64-simulator slice) runs on an arm64 host's simulator only under Rosetta 2.
Install it once per host with `softwareupdate --install-rosetta
--agree-to-license`. The test and capture jobs probe it with
`arch -x86_64 /usr/bin/true` and fail closed, before any simulator boots,
when it is missing; an x86_64 macOS host needs nothing extra.

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
curl -fsSL https://raw.githubusercontent.com/rnw-community/mobile-ci/v4.5.0/scripts/slim-simulator.sh \
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

**Leased simulators: slimmed before their first boot.** `run-maestro-ios` and
`capture-screenshots-ios` boot a device the host already owns, so the loop
above is the whole story for them. `simulator-lease` is different: it *creates*
the device it hands to `xcodebuild-test`, and a freshly created device is
always stock. With `slim-profile` set (the default, `bundled`) and
`slim-repair: 'true'` (the default), the lease is left shut down and
`simslim on --profile` writes its launchd disable overrides offline, then boots
it once, already slim; the job verifies and measures it. No image preparation
is needed, and nothing is left behind on the host.

**Templates do not carry slimming.** simslim keeps the overrides on the host in
a store keyed by the device's UDID
([`disabled_store.go`](https://github.com/MobAI-App/simslim/blob/main/disabled_store.go)),
not inside the device, so `xcrun simctl clone` of a slimmed template produces a
**stock** clone with a new UDID
([#161](https://github.com/rnw-community/mobile-ci/issues/161)). The same holds
for Xcode's `-parallel-testing-worker-count` clones: each worker boots stock,
so raising the worker count multiplies the stock footprint. simslim's own
answer for worker clones is `simslim watch`, which slims each clone no-reboot as
it boots; `xcodebuild-test` runs it for the length of the test run when given
`slim-profile` (`swift-ios.yml` passes the lease's). Baking `mobile-ci-template-*` devices
into the image buys nothing, and `template-strategy: auto` is deprecated
accordingly; `template-device` still clones a named device that carries
something other than slimming, and the clone is slimmed before first boot like
a created one.

**The fleet base image should still ship slim pool devices.** Measured inside
pony-labirinth's live UI-test VM (`maestro` profile, 7 GiB), a stock leased
simulator ran **272 RuntimeRoot processes** — Calendar, News and Maps widgets,
a Safari extension, Spotlight — with about **2 GB in the compressor and ~14 MB
of free pages**. The UI-test step there was memory-starved, not CPU-bound. The
devices `run-maestro-ios` and `capture-screenshots-ios` boot by name keep their
overrides across `simctl erase` (the store is keyed by UDID), so slimming them
once in the image, with the loop above, holds for every job.

**What resets a simulator to stock.** Anything that gives the device a new
UDID — delete-and-recreate, `simctl clone`, and every device created from a
newly installed runtime — comes up stock with no error anywhere (`simctl
erase` keeps the overrides, because simslim's store is keyed by UDID and lives
outside the device) - the simulator just
runs heavy again, and a pool that was sized for slim simulators starts
swapping. `simslim verify` in the job catches exactly this and fails the shard
naming the drift; re-run the loop above on that host. `simulator-slim-repair`
defaults to `'true'`, so the shard repairs itself in-job with `simslim on` (a
shutdown and one boot) and the repair is paid once per device; set it to
`'false'` on an image that ships slimmed devices to fail on drift instead.

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
slimmed and verified, and a clone that boots stock unless `xcodebuild-test`'s
`slim-workers` runs `simslim watch` for it.

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
    parallel-testing: 'YES'
    parallel-testing-worker-count: '2'
```

## Linux `linux-aarch64` Redroid hosts (Android)

Google does not publish `linux-aarch64` builds of the Android emulator, NDK,
or `cmake`, so `android-emulator` (`run-maestro-android` and the
screenshot capture's `avd` driver; `android-maestro.yml`'s default) is
structurally unusable on
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
The `avd` driver — `android-maestro.yml`'s default (`run-maestro-android`) and
`store-screenshots.yml`'s `android-driver: avd` capture leg, both booting the
emulator through the `android-emulator` action — is fully supported too, on
an x86_64 Linux host with
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
  Bake them into the runner image and point `ANDROID_SDK_ROOT`/`ANDROID_HOME`
  at that SDK: `android-emulator` then uses it as is, and adds only a missing
  system image to it with `sdkmanager` when the SDK root is writable. Without
  a usable preinstalled SDK it falls back to `android-actions/setup-android`,
  which downloads a fresh SDK (several minutes per job) into the same root or
  `~/.android/sdk`. Either install path runs `sdkmanager`, so the runner needs
  a JDK on `PATH`. No `binder_linux`, no privileged containers,
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
  through a shard. `run-maestro-android` therefore sizes the guest from the
  container's own cgroup limit when `emulator-ram-size` is empty (the
  default): 256 MB of guest RAM per GiB of `memory.max`, clamped to
  1536–4096, and half the `cpu.max` quota as cores, clamped to 2–4 — 2048 MB
  and 2 cores on a 4 vCPU / 8 GiB container. It reads cgroup v2 first, then
  cgroup v1, and keeps the profile default when neither reports a limit, so
  give the runner container a real memory limit rather than relying on the
  host's. Set `emulator-ram-size` (and `emulator-heap-size`) explicitly only
  with headroom measured on the pool. `redroid-memory` is the equivalent knob
  on the other driver.
- **Cap emulators per host with a slot directory (optional).** Per-container
  sizing cannot stop a host from admitting more emulator jobs than its RAM
  holds. Provision one file per emulator the host may run, on a **local**
  filesystem (`flock` over NFS is not reliable), and bind-mount the directory
  read-write at the same path into every runner container on the host:

  ```bash
  # once per host; N = emulators this host can hold (e.g. host RAM / 8 GiB)
  install -d -m 0777 /var/lib/mobile-ci/emulator-slots
  for i in $(seq 0 $((N - 1))); do
    install -m 0666 /dev/null "/var/lib/mobile-ci/emulator-slots/slot-$i"
  done
  # runner container: -v /var/lib/mobile-ci/emulator-slots:/var/lib/mobile-ci/emulator-slots:rw
  ```

  Then pass `emulator-slots-dir: /var/lib/mobile-ci/emulator-slots` to
  `android-maestro.yml` (and to `store-screenshots.yml` when its capture leg
  runs `android-driver: avd`, so screenshot emulators count against the same
  cap). Each test shard holds an exclusive `flock` on one
  slot from before the emulator boots until its shutdown step, so the number
  of `slot-*` files is the host's emulator cap across every job and
  repository. The lock lives in a detached `flock` holder process; if the job
  is killed, the kernel releases the lock when that process dies — through the
  shutdown step, the runner's orphan-process cleanup, or the container's
  teardown. To change the cap, add or remove `slot-*` files (remove only idle
  ones). Runner images need `flock` and `setsid` (util-linux) on `PATH`.
- **`emulator -accel-check` gates every boot.** A host missing `/dev/kvm`
  access does not necessarily refuse to boot an AVD — it can silently fall
  back to software emulation, which eventually boots but is far too slow for
  a CI budget and gives no clear signal that the host is misconfigured.
  `android-emulator` therefore runs `emulator -accel-check` before every
  boot and fails the job, quoting the emulator's reason, unless it confirms
  hardware acceleration. The same command makes a useful host health-check
  outside CI.

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

`store-screenshots.yml` has the same choice and default for its Android capture
leg: `android-driver: avd` on the x86_64 KVM pool
(`["self-hosted","trf-linux-amd64-4x8"]`). It uses the same `android-emulator`
action as the Maestro shards. Redroid consumers must explicitly set both
`android-driver: redroid` and `android-capture-runner-labels` naming the
Redroid pool — see
[docs/workflows/store-screenshots.md](workflows/store-screenshots.md#android-capture).

### EAS local builds (`native-publish`/`seed-native-cache`/`native-dev-release`)

`native-publish.yml`, `seed-native-cache.yml`, and `native-dev-release.yml`
all default their `android-runner-labels` input to the x86_64 Linux pool
(`["self-hosted","trf-linux-amd64-4x8"]`). An Android `eas build --local`
needs no Mac, only Google's NDK, which ships for x86_64 Linux and macOS but
never for linux-aarch64 - the same gap that rules out the `redroid`-only
`linux-aarch64` shape for an Android build. suuudokuuu's `native-publish`
Android job has built and published from that pool repeatedly (32-38 min a
run). The image does not need the NDK or build-tools preinstalled: the Gradle
build downloads the versions the app pins into the SDK, so the first run on a
fresh container pays that download.

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
