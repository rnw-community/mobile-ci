[![self-test](https://github.com/rnw-community/mobile-ci/actions/workflows/self-test.yml/badge.svg)](https://github.com/rnw-community/mobile-ci/actions/workflows/self-test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

# mobile-ci

Reusable composite actions and `workflow_call` workflows for fleet-native
React Native / Expo mobile CI: fingerprinted native-app caches, Maestro e2e,
and simulator/emulator lifecycle management on self-hosted runners.

**Zero EAS-cloud dependency for CI builds.** Every test pipeline here builds
fleet-native — `expo prebuild` then raw `xcodebuild` / `gradlew` on
self-hosted runners, no EAS cloud builds, no `eas-cli`. Native fingerprinting
uses the standalone [`@expo/fingerprint`](https://www.npmjs.com/package/@expo/fingerprint)
package tokenlessly.

**Zero secret custody in the test pipelines.** `ios-maestro.yml`,
`android-maestro.yml`, and `seed-native-cache.yml` need no secrets at all —
no `EXPO_TOKEN`, no signing credentials, nothing. Secrets only enter the
picture in the two opt-in publish workflows (`native-publish.yml`,
`native-dev-release.yml`), scoped to exactly the jobs that submit to a store
or cut a dev release, and only for the platforms you enable.

**Pre-release: the `v1` tag is pending pipeline proof.** Pin to `@main` until
then — see [CONTRIBUTING.md](CONTRIBUTING.md) for the versioning plan and
[RELEASE.md](RELEASE.md) for how `v1` gets cut.

## Quick start

Minimal iOS Maestro e2e pipeline for a single app:

```yaml
# .github/workflows/ios-maestro.yml
name: iOS Maestro E2E
on:
    workflow_dispatch:
    pull_request:
    push:
        branches: [main]
jobs:
    e2e:
        uses: rnw-community/mobile-ci/.github/workflows/ios-maestro.yml@main
        with:
            targets: >-
                [{"name":"bare","appDir":"apps/mobile","workspace":"MyApp.xcworkspace","scheme":"MyApp","appId":"com.example.app","prebuildCommand":""}]
            flows-dir: apps/mobile/e2e/flows
```

See [docs/workflows/ios-maestro.md](docs/workflows/ios-maestro.md) for the
full input reference, and the same doc's siblings under
[docs/workflows/](docs/workflows/) for `android-maestro.yml` and the rest.

## Pick your tier

- **À la carte** — consume individual composite actions and keep your own
  job/workflow structure. Use this if you already have a working pipeline and
  want to adopt one piece at a time (e.g. just the simulator lifecycle, or
  just the native-app cache).
- **Whole pipeline** — consume `ios-maestro.yml` / `android-maestro.yml` /
  `seed-native-cache.yml` / `native-publish.yml` / `native-dev-release.yml`
  via `workflow_call` and collapse your own workflow to a thin `uses:`
  wrapper with inputs. Use this for a new pipeline or when migrating a
  pipeline that already matches this shape closely.

## Action catalog

| Action                         | Purpose                                                                                     |
| ------------------------------- | --------------------------------------------------------------------------------------------- |
| [`setup-xcode-pinned`](actions/setup-xcode-pinned/README.md)     | Select a pre-installed Xcode by exact version+build; hard-assert the match. |
| [`native-fingerprint`](actions/native-fingerprint/README.md)     | Tokenless `@expo/fingerprint` hash of an app's native surface. |
| [`native-app-cache`](actions/native-app-cache/README.md)         | Restore/save the canonical native `.app`/`.apk` keyed on profile/os/arch/toolchain/fingerprint. |
| [`setup-ccache-ios`](actions/setup-ccache-ios/README.md)         | Bounded, compressed ccache install + restore/save for `xcodebuild`. |
| [`build-ios-app`](actions/build-ios-app/README.md)               | Release, ad-hoc-signed (entitlements preserved) iOS Simulator `.app` via `xcodebuild`, embedded jsbundle verified. |
| [`build-android-app`](actions/build-android-app/README.md)       | Release `.apk` via `gradlew`, embedded JS bundle verified, pinned `cmdline-tools-version`. |
| [`repack-app`](actions/repack-app/README.md)                     | Inject a freshly exported JS bundle into a cached native shell without a full native rebuild. |
| [`run-maestro-ios`](actions/run-maestro-ios/README.md)           | Simulator boot/bootstatus/install/test/capture/shutdown for a Maestro flow shard. |
| [`run-maestro-android`](actions/run-maestro-android/README.md)   | Headless AVD emulator boot/install/test/capture/shutdown for a Maestro flow shard. |
| [`run-maestro-android-redroid`](actions/run-maestro-android-redroid/README.md) | Redroid (Android-in-container) boot/install/test/capture/teardown for a Maestro flow shard — the only Android driver that boots at all on `linux-aarch64` self-hosted runners; `android-maestro.yml`'s default. |
| [`capture-screenshots-ios`](actions/capture-screenshots-ios/README.md) | Boots a pinned Simulator and captures one screenshot per locale x appearance x scene into a fixed `raw/ios/<device-slug>/...` layout for store screenshot pipelines. |
| [`turbo-affected`](actions/turbo-affected/README.md)             | Fail-closed `turbo ls --affected` detection gating a pipeline to touched packages. |

Each action has its own `README.md` under `actions/<name>/` with the full
input/output table and a usage example.

## Reusable workflow catalog

| Workflow                          | Composes                                                                          |
| ----------------------------------- | ------------------------------------------------------------------------------------ |
| [`ios-maestro.yml`](docs/workflows/ios-maestro.md)           | `turbo-affected` → `setup-xcode-pinned` → `native-fingerprint` → `native-app-cache` → cache hit: (`repack-app`, if enabled) → `run-maestro-ios` \| cache miss: `setup-ccache-ios` → `build-ios-app` → `run-maestro-ios` |
| [`android-maestro.yml`](docs/workflows/android-maestro.md)   | `turbo-affected` → `native-fingerprint` → `native-app-cache` → cache hit: (`repack-app`, if enabled) → `run-maestro-android-redroid` (default) or `run-maestro-android` (`android-driver: avd`) \| cache miss: `build-android-app` → `run-maestro-android-redroid` (default) or `run-maestro-android` (`android-driver: avd`) |
| [`seed-native-cache.yml`](docs/workflows/seed-native-cache.md) | The build half of both pipelines above, without the detect/test jobs — populates the native-app cache on a schedule or dispatch. |
| [`native-publish.yml`](docs/workflows/native-publish.md)     | Per-platform `eas build --local` → `eas submit`, with an Android Play-policy lint gate and 64-bit ABI verification. |
| [`native-dev-release.yml`](docs/workflows/native-dev-release.md) | Per-platform `eas build --local` (development profile) → publish to a pruned GitHub Release. |
| [`store-screenshots.yml`](docs/workflows/store-screenshots.md) | `build-ios-app` → `capture-screenshots-ios` matrix (one job per `capture-manifest` device, looping locales x appearances x scenes on one booted simulator) → optional gated `upload` (consumer's fastlane `deliver` lane). iOS only in this release. |
| [`pr-closed-cleanup-reusable.yml`](docs/workflows/pr-closed-cleanup-reusable.md) | Cancels queued/in-progress workflow runs left behind on a closed PR's branch, so a serialized self-hosted fleet does not starve on zombie runs. Zero required inputs — everything is derived from the calling workflow's `pull_request: closed` event context. |

Both `ios-maestro.yml` and `android-maestro.yml` split their runner pool into
`build-runner-labels` + `test-runner-labels` (the second defaults to the
first) so a consumer with a dedicated builder host separate from its Maestro
test pool can preserve that split; a single-pool consumer sets only
`build-runner-labels` and ignores `test-runner-labels` entirely. Flow
discovery under both is bounded by default (`flows-max-depth: 1`, a
`flows-name-pattern` glob, and an optional `flows-exclude-pattern`) so subflow
and fixture directories under `flows-dir` are never swept into a shard; an
optional `shard-manifest-dir` of hand-curated `shard-<index>.txt` files
overrides the computed index-modulo split for consumers whose shard balance
is hand-tuned, falling back to modulo when unset.

### Android driver: Redroid vs AVD

`android-maestro.yml`'s `android-driver` input picks the Maestro-execution
step's Android backend, `redroid` by default:

- **`redroid`** (default) — Android as a privileged container over the
  `binder_linux` kernel module (`run-maestro-android-redroid`). Needs no
  `sdkmanager`, NDK, or emulator binary on the runner, so it is the only
  driver that works at all on `linux-aarch64` self-hosted runners — this
  workflow's own default `runner-labels`. See
  [docs/self-hosted-runners.md](docs/self-hosted-runners.md) for how to
  provision a Redroid host.
- **`avd`** — a real Android emulator via
  `reactivecircus/android-emulator-runner` (`run-maestro-android`). Only
  viable when `runner-labels` is overridden to a host with a working
  emulator + acceleration, e.g. GitHub-hosted `ubuntu-latest` (KVM-accelerated
  out of the box). Google does not publish `linux-aarch64` builds of the
  Android emulator, NDK, or `cmake`, so `avd` cannot boot on this workflow's
  default self-hosted fleet regardless of tuning — that gap is exactly why
  `redroid` is the default rather than an opt-in.

`ios-maestro.yml` / `android-maestro.yml` also support splitting build and
test onto separate runner pools via `build-runner-labels` /
`test-runner-labels` (each falls back to `runner-labels` when left empty) —
useful when your build hosts and Maestro-execution hosts are provisioned
differently (see [docs/self-hosted-runners.md](docs/self-hosted-runners.md)).

`seed-native-cache.yml` is meant to be called from a workflow that is itself
`workflow_dispatch`-triggered (plus optionally `push`/`schedule`) in the
*consuming* repository. GitHub only allows dispatching a `workflow_dispatch`
workflow once it exists on the default branch — merge your caller workflow to
your default branch before expecting to dispatch it.

`pr-closed-cleanup-reusable.yml` must be called from a workflow triggered by
`pull_request: types: [closed]` in the consuming repository — it reads
`github.event.pull_request.head.ref` from that event, so it cannot be
dispatched standalone. This repo's own `pr-closed-cleanup.yml` is a one-line
consumer of it:

```yaml
# .github/workflows/pr-closed-cleanup.yml
name: pr-closed-cleanup
on:
    pull_request:
        types: [closed]
permissions:
    actions: write
jobs:
    cleanup:
        permissions:
            actions: write
        uses: rnw-community/mobile-ci/.github/workflows/pr-closed-cleanup-reusable.yml@main
```

## Scope

In scope: the e2e pipelines (`ios-maestro.yml` / `android-maestro.yml` /
`seed-native-cache.yml`) — ad-hoc-signed (entitlements preserved) iOS
simulator / unsigned Android emulator builds, tokenless
fingerprinting, Maestro; and store publishing (`native-publish.yml`:
`eas build --local` for fleet-compute signed builds + `eas submit` for store
upload) and development-build distribution (`native-dev-release.yml`:
`eas build --local` + pruned GitHub Releases). `EXPO_TOKEN` and store
credentials are scoped to exactly those two publish workflows — every other
pipeline in this catalog runs with no secrets at all. EAS there only manages
signing-credential custody, not build compute; the actual `.ipa`/`.aab` still
builds on your own runner.

## Self-hosted runners

Every action and reusable workflow here assumes a self-hosted fleet with
Xcode already installed (iOS) and `binder_linux` loaded (Redroid Android).
See [docs/self-hosted-runners.md](docs/self-hosted-runners.md) for host
provisioning: macOS Xcode pools, Linux `linux-aarch64` Redroid hosts, the
Redroid prewarm manifest format, and the repo variables this repo's own
maintainer-only fleet self-test job reads.

## Repo practices

- Semver + sliding `v1` tag once cut (see [CONTRIBUTING.md](CONTRIBUTING.md)
  and [RELEASE.md](RELEASE.md)).
- Every third-party action pinned by full commit SHA with a `# vX.Y.Z` comment.
- `actionlint`, `shellcheck`, and `zizmor` run in CI (`self-test.yml`) on
  every push and PR; a fleet self-test job exists but is
  `workflow_dispatch`-only since the self-hosted runners are shared with the
  consuming repos.
- MIT licensed.

**Versioning note:** this repo is pre-`v1`. Examples throughout this README
and the per-action/per-workflow docs use `@v1` for readability, but that tag
does not exist yet — pin to a specific commit SHA (or `@main` at your own
risk) until [RELEASE.md](RELEASE.md)'s checklist cuts it.

## Used in the wild

Real-world adopters — worth reading as usage examples, not as this repo's
own documentation:

- [vitalyiegorov/suuudokuuu](https://github.com/vitalyiegorov/suuudokuuu) — iOS + Android Redroid Maestro pipelines.
- [budgie-at/budgie](https://github.com/budgie-at/budgie) — iOS Maestro + native cache, à la carte tier.
- [rnw-community/rnw-community](https://github.com/rnw-community/rnw-community) — monorepo canary pipeline this catalog was extracted from.
