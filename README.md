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
picture in the opt-in distribution workflows — `native-publish.yml`,
`native-dev-release.yml`, the EAS Update backend of `expo-ota-preview.yml`,
`eas-channel-cleanup-reusable.yml`, and `store-screenshots.yml`'s upload —
scoped to exactly the jobs that need them, and only for the platforms you
enable.

**Released.** Exact `vX.Y.Z` tags are published, plus a floating major tag
per major (`v4` is current, at `v4.3.1`; `v3` stays frozen at `v3.3.2`,
`v2` at `v2.3.0` and `v1` at `v1.23.1`) that
moves with the latest release of that major — pin to an exact tag or a full
commit SHA for reproducibility, or `@v4` to float. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the versioning policy and
[RELEASE.md](RELEASE.md) for the release procedure.

## A pull request no longer compiles native code

**Since `v3.0.0`, and the default.** An Expo/React Native e2e or screenshot
run used to build the app on a Mac (iOS) or through Gradle (Android) on every
pull request. It no longer does. `ios-maestro.yml`, `android-maestro.yml` and
`store-screenshots.yml` now compute the **native fingerprint key** of the
target's native surface on Linux, fetch the **base binary** published for that
key, and **repack** it with this commit's JavaScript — on the x86_64 Linux
pool, in minutes. Only a key with *no* published base reaches a Mac or a Gradle
build, and a default-branch run then publishes the base it built, so the next
pull request repacks again.

Three actions state that, and nothing else changes for a caller:
[`expo-native-key`](actions/expo-native-key/README.md) computes the key,
[`expo-base-binary`](actions/expo-base-binary/README.md) fetches or publishes
the base under it, and [`expo-repack`](actions/expo-repack/README.md) produces
this commit's binary from that base and asserts the result — a repack that
cannot be verified fails the build rather than shipping the base's own
JavaScript.

**The one thing a consumer must add** is a `permissions:` block on the job that
calls the workflow. A reusable workflow can only narrow the token its caller
granted, never add a scope, so in a repository whose default workflow token is
read-only no default-branch run can publish a base, and a native key nothing
has warmed yet never gets warmed:

```yaml
jobs:
    e2e:
        permissions:
            contents: read
            packages: write
            actions: read
        uses: rnw-community/mobile-ci/.github/workflows/ios-maestro.yml@v4.3.1 # v4.3.1
```

A read-only token does **not** mean nothing works. A base that is already
published stays readable, so pull requests keep repacking; what fails is the
publish step on a default-branch run, and the effect is that a *newly moved*
native key never gets warmed — every run on that key compiles natively until
the permission is granted. A store that cannot be read at all is different
again: `expo-base-binary` fails the lookup closed rather than reporting an
absent base, because an unreadable store is not an empty one.

Read [docs/repack.md](docs/repack.md) for the whole contract — what
`fingerprint.config.js` must ignore and must not, how a key is warmed, and the
`build-strategy` escape hatches (`repack` refuses to compile at all; `native`
is the old v2 behaviour and a regression). The host side is in
[docs/self-hosted-runners.md](docs/self-hosted-runners.md#the-linux-repack-pool-expo-e2e-and-screenshot-runs).

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
        # Required: a reusable workflow can only narrow what the caller grants.
        permissions:
            contents: read
            packages: write
            actions: read
        uses: rnw-community/mobile-ci/.github/workflows/ios-maestro.yml@v4.3.1 # v4.3.1
        with:
            targets: >-
                [{"name":"bare","appDir":"apps/mobile","workspace":"MyApp.xcworkspace","scheme":"MyApp","appId":"com.example.app","prebuildCommand":""}]
            flows-dir: apps/mobile/e2e/flows
```

See [docs/workflows/ios-maestro.md](docs/workflows/ios-maestro.md) for the
full input reference, and the same doc's siblings under
[docs/workflows/](docs/workflows/) for `android-maestro.yml` and the rest —
each has a **Minimal** and a **Full** example. Complete caller workflows for
four app shapes are in [docs/examples/](docs/examples/README.md); CI lints them
and checks every input, secret and permission against this commit.

## Which workflow do I need?

**What kind of app?**

- **Expo / React Native** — the rest of this guide.
- **Pure Swift / Xcode** (no Node, Expo or CocoaPods) —
  [`swift-ios.yml`](docs/workflows/swift-ios.md) builds once, shards simulator
  tests and optionally signs and uploads to TestFlight; or compose
  `apple-signing` + `xcode-archive-upload` yourself. Example:
  [docs/examples/swift-xcode-app/](docs/examples/swift-xcode-app/).

**Expo / React Native, by job to be done:**

| You want | Use | Choose |
| --- | --- | --- |
| Maestro e2e on pull requests | [`ios-maestro.yml`](docs/workflows/ios-maestro.md), [`android-maestro.yml`](docs/workflows/android-maestro.md) | iOS `ios-driver`: `local` (default, a simulator on your Mac pool) or `device-cloud` (devicecloud.dev from a Linux runner). Android `android-driver`: `avd` (default, x86_64 Linux with `/dev/kvm`), `redroid` (a `linux-aarch64` pool, privileged Docker + `binder_linux`) or `device-cloud`. Quarantine a broken suite for a while with `tolerate-test-failures`. One call can cover a monorepo: each `targets` entry may set its own `flowsDir`, `tolerateTestFailures` and `buildStrategy`; `call-scope` keeps several calls in one run apart. |
| Pull requests that do not compile native code | [`seed-native-cache.yml`](docs/workflows/seed-native-cache.md), the warm-up | Run it on a default-branch push with a `paths:` filter; it publishes the base binary every pull request repacks. Pass it the same `fingerprint-config` / `fingerprint-env` / `build-secrets-env` as the e2e callers. See [docs/repack.md](docs/repack.md). |
| Development builds for testers | [`native-dev-release.yml`](docs/workflows/native-dev-release.md) | `distribution: github-release` (default; a public repository, or testers with repository access) or `eas` (an EAS install page; private repositories). `build-location: local` (default, your fleet) or `cloud` (EAS servers; needs `distribution: eas`). `call-scope`: one per brand when you call it once per brand. |
| Store releases | [`native-publish.yml`](docs/workflows/native-publish.md) | `credentials-source`: `secrets` (default; ASC / Play keys as GitHub secrets) or `eas` (keys stored on EAS; one `EXPO_TOKEN` for every team). `record-scope`: one per brand when you call it once per brand. `mode: auto` + `ota-baseline`: `github-release` (the store build record on the tag's release) or `eas-channel` (what the EAS channel already serves) to skip the build when only JavaScript changed. |
| Releasing an uploaded build (App Review, Play production) | [`store-release.yml`](docs/workflows/store-release.md) | Dry run by default; `dry-run: false` submits the iOS version for review and promotes the Android build `android-from-track` → `android-to-track` with `android-rollout`. `github-environment` puts the job behind required reviewers. |
| OTA previews on pull requests | [`expo-ota-preview.yml`](docs/workflows/expo-ota-preview.md) | `ota-backend: github-release` (default; tokenless, **public repositories and previews only**) or `eas` (EAS Update; private repositories, and the only backend for production). See [Choosing an OTA backend](#choosing-an-ota-backend). |
| Production OTA updates | the [`eas-update`](actions/eas-update/README.md) action, gated on `native-publish.yml`'s `decision` output | Run the job in a GitHub Environment with required reviewers. [`eas-channel-fingerprint`](actions/eas-channel-fingerprint/README.md) answers "can this commit ship as an OTA on channel X?" on its own. |
| A gate against orphaning published OTAs | [`expo-fingerprint-guard.yml`](docs/workflows/expo-fingerprint-guard.md) | Fails a pull request that moves the native runtime fingerprint, unless labelled. |
| Store screenshots | [`store-screenshots.yml`](docs/workflows/store-screenshots.md) | `capture-mode: flows` (a Maestro flow per scene, iOS) or `direct` (a deep-link scene manifest, required for Android); optional gated fastlane upload. |
| Cleanup | [`pr-closed-cleanup-reusable.yml`](docs/workflows/pr-closed-cleanup-reusable.md) + [`preview-sweep-reusable.yml`](docs/workflows/preview-sweep-reusable.md) (GitHub Release previews); [`eas-channel-cleanup-reusable.yml`](docs/workflows/eas-channel-cleanup-reusable.md) (EAS channels) | The first cancels a closed pull request's runs on a shared fleet, whatever else you use. |

Every calling job needs a `permissions:` block granting at least what the
called workflow's jobs request — see the table in
[docs/examples/README.md](docs/examples/README.md#permissions-at-a-glance).

## What changed in v4.x

- **v3 → v4.0.0** — the one breaking change: `store-screenshots.yml` captures
  Android on the `avd` driver and the x86_64 KVM pool by default. A Redroid
  caller now passes `android-driver: redroid` with its `linux-aarch64`
  runner labels ([migration](docs/workflows/store-screenshots.md#migrating-from-the-redroid-defaults)).
  `android-maestro.yml` already defaulted to `avd`.
- **v4.1.0** — repack guards: two targets with different `appId` sharing one
  native key fail closed (`assert-distinct-fingerprints.yml` runs the same
  check before a release); package-manager, Android SDK and Gradle caches are
  restored everywhere but saved only off pull requests; native compile
  parallelism is bounded to the runner's cgroup (no more OOM-killed Android
  builds); a self-reference pinned to a tag that lacks the action fails
  `self-test`. Also: the `device-cloud` test driver, masked
  `build-secrets-env` / `maestro-secrets-env`, the sticky preview comment,
  `force-label`, Maestro tag selection and JUnit reports, `native-publish.yml`
  `targets` / build number / OTA decision, and `preview-sweep-reusable.yml`.
- **v4.2.0** — EAS Update: the `eas-update`, `eas-channel-fingerprint`,
  `eas-profile-env` and `ota-runtime-version` actions, `expo-ota-preview.yml`
  `ota-backend: eas`, `native-publish.yml` `ota-baseline: eas-channel`, and
  `eas-channel-cleanup-reusable.yml`. EAS distribution and credentials:
  `native-dev-release.yml` `distribution: eas` / `build-location: cloud`,
  `native-publish.yml` `credentials-source: eas` and `record-scope`, and
  outputs on both. `ios-maestro.yml` `tolerate-test-failures`. The Gradle cache
  is restored on pull requests but no longer saved there. **Runtime versions
  now come from the project's own `expo-updates`**, not the pinned
  `@expo/fingerprint`: the first `mode: auto` run after upgrading may build
  natively once, and a preview comment may not match a dev build published
  before v4.2.0 (`native-publish.yml`'s `fingerprint-version` is now ignored).
- **v4.3.0** — `call-scope` on `native-dev-release.yml`, `ios-maestro.yml` and
  `android-maestro.yml`, so several calls in one run (a per-brand or
  per-package matrix) never collide on artifacts, tags or concurrency; per-target
  `flowsDir`, `tolerateTestFailures` and `buildStrategy` in `targets[]`, so one
  call can cover a monorepo with bare and Expo apps. Native compile slots are
  sized by memory per heavy translation unit (`native-compile-memory-per-job`,
  default 3584 MiB), so a cold react-native-skia build fits 8 GiB; such cold
  native builds run with fewer parallel compiles and take a few minutes longer.
  Its in-process Kotlin ran an Expo app's Gradle daemon out of metaspace on the
  template's 512 MiB, so on v4.3.0 an Expo app still needed a raised
  `MaxMetaspaceSize` or a `kotlin.compiler.execution.strategy=daemon` opt-out.
- **v4.3.1** — fixes v4.3.0's metaspace regression: Kotlin compiles in its own
  daemon again, with that daemon's heap capped at 1536 MiB
  (`-Dkotlin.daemon.jvm.options=-Xmx1536m`, below any Kotlin daemon setting
  the project makes itself) instead of inheriting the Gradle daemon's, and the
  native compile reserve returns to 5 GiB. An Expo app on the template's
  `org.gradle.jvmargs` builds natively on 8 GiB with no metaspace raise and no
  `kotlin.compiler.execution.strategy` opt-out; drop either workaround.

No input was removed or had its default changed after v4.0.0, so within v4
bumping the pin is the whole migration.

## Pick your tier

- **À la carte** — consume individual composite actions and keep your own
  job/workflow structure. Use this if you already have a working pipeline and
  want to adopt one piece at a time (e.g. just the simulator lifecycle, or
  just the native-app cache).
- **Whole pipeline** — consume the reusable workflows in the
  [catalog below](#reusable-workflow-catalog) via `workflow_call` and collapse
  your own workflow to a thin `uses:` wrapper with inputs. Use this for a new
  pipeline or when migrating a pipeline that already matches this shape
  closely; start from [docs/examples/](docs/examples/README.md).
- **Native Swift / Xcode** — an app with no React Native, no Expo, no Node and
  no CocoaPods is a first-class consumer too. Compose `xcode-cache`,
  `swift-test`, `simulator-lease`, `xcodebuild-test`,
  `xcodebuild-affected-tests`, `apple-signing` and
  `xcode-archive-upload` à la carte, or take the whole pipeline with
  [`swift-ios.yml`](docs/workflows/swift-ios.md). Nothing in that lane installs
  a JS toolchain or reads an Expo fingerprint.

## Action catalog

| Action                         | Purpose                                                                                     |
| ------------------------------- | --------------------------------------------------------------------------------------------- |
| [`setup-xcode-pinned`](actions/setup-xcode-pinned/README.md)     | Select a pre-installed Xcode by exact version+build; hard-assert the match. |
| [`native-fingerprint`](actions/native-fingerprint/README.md)     | Tokenless `@expo/fingerprint` hash of an app's native surface. |
| [`node-pm-cache`](actions/node-pm-cache/README.md)                | Restore the package-manager store on every event, save it only off pull requests (bounded, non-fatal). |
| [`native-app-cache`](actions/native-app-cache/README.md)         | Restore/save the canonical native `.app`/`.apk` keyed on profile/os/arch/toolchain/fingerprint. |
| [`setup-ccache-ios`](actions/setup-ccache-ios/README.md)         | Bounded, compressed ccache install + restore/save for `xcodebuild`. |
| [`xcode-cache`](actions/xcode-cache/README.md)                   | Restore/save DerivedData + resolved Swift Package clones + the Xcode 26 compilation cache (CAS), keyed on toolchain + project fingerprint; `github` or network-free `local` backend. Emits the `xcodebuild` arguments that point Xcode at all three. |
| [`swift-test`](actions/swift-test/README.md)                     | `swift test --parallel` for a Swift Package, `.build` cached on the same key scheme, pass/fail step summary. |
| [`simulator-lease`](actions/simulator-lease/README.md)           | Create an isolated, run-scoped simulator, slim it before its first boot (`simslim on`, one boot), wait for `bootstatus -b` and verify it; paired `mode: release` shuts the lease down and deletes it. |
| [`xcodebuild-affected-tests`](actions/xcodebuild-affected-tests/README.md) | Maps a pull request's changed files to the `only-testing` list that covers them; an unmapped file, a full-suite path, a push or an unreachable base ref all widen back to the whole suite. |
| [`xcodebuild-test`](actions/xcodebuild-test/README.md)           | `build-for-testing` once, then `test-without-building` against a booted simulator; `mode: build`/`test` splits the two so N shard jobs share one compile; `.xcresult` artifact, summary; zero executed tests fails the job. |
| [`apple-signing`](actions/apple-signing/README.md)               | Throwaway keychain from the caller's `.p12`/profile/ASC key, profile ↔ App ID assertion, paired `mode: remove` teardown. No secret is echoed. |
| [`xcode-archive-upload`](actions/xcode-archive-upload/README.md) | `xcodebuild archive` + `-exportArchive` straight to App Store Connect with an ASC API key, or local export only. |
| [`build-ios-app`](actions/build-ios-app/README.md)               | Release, ad-hoc-signed (entitlements preserved) iOS Simulator `.app` via `xcodebuild`, embedded jsbundle verified. |
| [`build-android-app`](actions/build-android-app/README.md)       | Release `.apk` via `gradlew`, embedded JS bundle verified, pinned `cmdline-tools-version`. |
| [`expo-native-key`](actions/expo-native-key/README.md)           | The one key a base binary is published and looked up under: `@expo/fingerprint` of the native surface, folded with the build action, the pinned toolchain and the fingerprint config's hash. |
| [`expo-base-binary`](actions/expo-base-binary/README.md)         | Fetch or publish the immutable base binary for a native key — GHCR OCI artifact (default) or default-branch workflow artifact. An unreadable store is never an absent base. |
| [`expo-repack`](actions/expo-repack/README.md)                   | Turn a published base into this commit's binary without compiling native code: re-bundle the JS, rewrite the embedded Expo config, assert it, re-sign on Android. |
| [`run-maestro-ios`](actions/run-maestro-ios/README.md)           | Simulator boot/bootstatus/install/test/capture/shutdown for a Maestro flow shard. |
| [`run-maestro-android`](actions/run-maestro-android/README.md)   | Headless AVD emulator boot/install/test/capture/shutdown for a Maestro flow shard. |
| [`android-emulator`](actions/android-emulator/README.md)         | Standalone headless AVD lifecycle (`mode: start` / `mode: stop`) — fail-closed `emulator -accel-check` preflight, guest RAM/cores sized from the container's cgroup limits, optional host-wide `flock` emulator slot, job-scoped teardown — shared by `run-maestro-android` and `store-screenshots.yml`'s `avd` capture leg. |
| [`run-maestro-device-cloud`](actions/run-maestro-device-cloud/README.md) | Runs a Maestro flow selection on hosted devicecloud.dev devices from a plain Linux runner with a pinned `@devicecloud.dev/dcd`; downloads the run's artifacts and JUnit report under the caller's artifact name; a rejected submission or anything but an explicit pass fails with the reason (`ios-maestro.yml`'s `ios-driver` / `android-maestro.yml`'s `android-driver: device-cloud`). |
| [`run-maestro-android-redroid`](actions/run-maestro-android-redroid/README.md) | Redroid (Android-in-container) boot/install/test/capture/teardown for a Maestro flow shard — the only Android driver that boots at all on `linux-aarch64` self-hosted runners (`android-maestro.yml`'s `android-driver: redroid`). |
| [`redroid-container`](actions/redroid-container/README.md)       | Standalone Redroid container lifecycle (`mode: start` / `mode: teardown`) — run-scoped naming, prewarm manifest, kernel-assigned loopback adb port — for jobs that drive the booted device themselves. |
| [`capture-screenshots-ios`](actions/capture-screenshots-ios/README.md) | Boots a pinned Simulator and captures one screenshot per locale x appearance x scene — discovered Maestro flows or a deep-link/flow scene manifest with a per-cell seed hook — into a fixed `raw/ios/<device-slug>/...` layout for store screenshot pipelines. |
| [`capture-screenshots-android`](actions/capture-screenshots-android/README.md) | Drives an already-booted Android device (Redroid/AVD/physical) through a scene manifest — `wm size`/`wm density` device shaping, per-app locales, demo-mode status bar, per-cell seed hook — into a fixed `raw/android/<device-slug>/...` layout. |
| [`compose-media`](actions/compose-media/README.md) | Frames raw captures in fastlane frameit's real device frames (iPhone 6.9", iPad 13"; transparent or plate background) and encodes web media: AVIF + WebP stills, and WebM (AV1, VP9 fallback) + faststart H.264 MP4 + WebP poster clips. Every file is held to a byte budget, and the action fails closed. Captions stay app-side. Also usable locally from `scripts/media/`. |
| [`asc-dedupe-screenshots`](actions/asc-dedupe-screenshots/README.md) | Post-upload App Store Connect duplicate-screenshot verify/repair gate — self-signed ES256 JWT, `curl`/`jq`/`openssl` only; deletes all but the oldest copy of every `deliver` retry duplicate and fails closed so the flaky upload lane gets fixed. |
| [`app-store-release`](actions/app-store-release/README.md) | Submits an uploaded iOS build for App Review through the App Store Connect API (Node, no fastlane): finds or creates the version, attaches the newest valid build, sets release type and phased release, submits; dry run by default, idempotent on a version already in review. |
| [`play-store-release`](actions/play-store-release/README.md) | Promotes an uploaded Android build between Google Play tracks through the edits API (Node, no fastlane): highest version code on the source track, release notes copied, completed or staged rollout; dry run by default, idempotent. |
| [`runs-on-cache-bypass`](actions/runs-on-cache-bypass/README.md) | Opt-in: runs a SHA-pinned `runs-on/action` on a RunsOn `extras=s3-cache` runner so artifact upload/download work behind its cache proxy; a no-op elsewhere. |
| [`apply-secret-env`](actions/apply-secret-env/README.md)         | Masks and exports a secret's `KEY=VALUE` entries (multi-line via `KEY<<DELIMITER`) with a collision-proof `$GITHUB_ENV` delimiter, fails closed without echoing a malformed line, and emits a SHA-256 digest of the values (plus, with `allow-multiline: false`, a job-local merged `lines` output that does carry them) — the one parser behind `build-secrets-env`, `maestro-secrets-env` and `EAS_EXTRA_ENV`. |
| [`turbo-affected`](actions/turbo-affected/README.md)             | Fail-closed `turbo ls --affected` detection gating a pipeline to touched packages. |
| [`load-consumer-config`](actions/load-consumer-config/README.md) | Reads a consumer-owned JSON config file out of the checkout and validates it against an allowlist of keys, so a reusable workflow can resolve its inputs from a checked-in file instead of JSON-in-YAML `with:` blobs. |
| [`expo-ota-manifest`](actions/expo-ota-manifest/README.md)       | Generate Expo Updates protocol v1 manifests per platform from an `expo export` output — EAS-free, tokenless OTA hosting. |
| [`eas-update`](actions/eas-update/README.md)                     | Publish an EAS Update (`eas update --json`) to a channel, auto-creating it or pointing it at a branch, under an `eas.json` profile's env and environment; outputs update/group ids, runtime versions, manifest URLs and `expo-dev-client` deep links per platform; fails closed on a missing token, unparsable output or a missing platform. |
| [`eas-channel-fingerprint`](actions/eas-channel-fingerprint/README.md) | "Can this commit ship as an OTA on channel X?": the project's `expo-updates` runtime version vs the latest update and build on the channel; `decision=ota\|native` with a reason, `native` whenever EAS cannot be read. |
| [`ota-runtime-version`](actions/ota-runtime-version/README.md)   | The one runtime-version source for every OTA path: the project's own `expo-updates runtimeversion:resolve` per platform or target, under an `eas.json` profile's env — used by both `expo-ota-preview.yml` backends, both `native-publish.yml` baselines, `native-dev-release.yml`'s build marker and `eas-channel-fingerprint`. |
| [`eas-profile-env`](actions/eas-profile-env/README.md)           | Resolve `eas.json` build profiles through `extends`: merged env, channel and EAS environment, failing closed on cycles, unknown profiles and malformed env — shared by `native-publish.yml`, `eas-update` and `eas-channel-fingerprint`. |
| [`github-release-publish`](actions/github-release-publish/README.md) | Publish a directory to a GitHub Release as flat-named assets under a stable tag, pruning older previews. |
| [`pr-preview-comment`](actions/pr-preview-comment/README.md)     | One sticky pull-request comment, found by a hidden marker and edited in place, whose sections each workflow owns (OTA update, native dev build); verified read-modify-write with retry against concurrent writers. |

Each action has its own `README.md` under `actions/<name>/` with the full
input/output table and a usage example.

## Reusable workflow catalog

| Workflow                          | Composes                                                                          |
| ----------------------------------- | ------------------------------------------------------------------------------------ |
| [`ios-maestro.yml`](docs/workflows/ios-maestro.md)           | `turbo-affected` → `expo-base-plan.yml` (`expo-native-key` → `expo-base-binary` fetch → `expo-repack`, on Linux) → `run-maestro-ios` \| no base for the key: `setup-xcode-pinned` → `native-app-cache` → `setup-ccache-ios` → `build-ios-app` → `expo-base-binary` publish (default branch) → `run-maestro-ios` |
| [`android-maestro.yml`](docs/workflows/android-maestro.md)   | `turbo-affected` → `expo-base-plan.yml` (`expo-native-key` → `expo-base-binary` fetch → `expo-repack`, on Linux) → `run-maestro-android` (default, `avd`) or `run-maestro-android-redroid` (`android-driver: redroid`) \| no base for the key: `native-app-cache` → `build-android-app` → `expo-base-binary` publish (default branch) → the same Maestro step |
| [`expo-base-plan.yml`](.github/workflows/expo-base-plan.yml)  | The shared decision the e2e and screenshot workflows call, not something a consumer normally calls directly: one leg per target on the Linux pool — `expo-native-key` → `expo-base-binary` fetch → `expo-repack` when a base exists, and a `native-targets` output naming the keys that still need a Mac or a Gradle build. |
| [`seed-native-cache.yml`](docs/workflows/seed-native-cache.md) | The warm-up: builds natively for every key that has no base yet and **publishes the base binary** pull requests repack, on a schedule or dispatch. Run it on the default branch after a native change so the next pull request takes no Mac slot. |
| [`swift-ios.yml`](docs/workflows/swift-ios.md)               | Native Swift / Xcode, no JS toolchain: `build` (`setup-xcode-pinned` → `xcode-cache` restore → `swift-test` → `xcodebuild-test` `mode: build` → `xcode-cache` save) → `test` (one matrix shard per `shards-json` entry: `xcode-cache` restore → `simulator-lease` → optional `xcodebuild-affected-tests` on a pull request → `xcodebuild-test` `mode: test`), both secretless, then an opt-in `publish` (`apple-signing` → `xcode-archive-upload` → optional tag + GitHub Release). N shards share one compile through the restored DerivedData cache. |
| [`native-publish.yml`](docs/workflows/native-publish.md)     | `plan` (targets, `eas.json` profile env with `extends`, build number, optional OTA decision against the store build record or, with `ota-baseline: eas-channel`, the EAS channel) → per-target `eas build --local` → `eas submit`, with an Android Play-policy lint gate and 64-bit ABI verification, then an optional store build record on the release. Signing and store keys from GitHub secrets or EAS-stored credentials. |
| [`store-release.yml`](docs/workflows/store-release.md) | The step after `native-publish.yml`: `app-store-release` (App Store version, build, review submission) and `play-store-release` (Play track promotion with a staged rollout) in one dry-run-by-default job on a Linux control runner, optionally behind a GitHub Environment's required reviewers. |
| [`native-dev-release.yml`](docs/workflows/native-dev-release.md) | Per-platform `eas build --local` (or an EAS cloud build) of the development profile → publish to a pruned GitHub Release, or to EAS internal distribution with an install link. |
| [`store-screenshots.yml`](docs/workflows/store-screenshots.md) | `build-ios-app` → `capture-screenshots-ios` matrix and/or `build-android-app` → `android-emulator` (default, `avd`) or `redroid-container` (`android-driver: redroid`) + `capture-screenshots-android` matrix (one job per `capture-manifest` device, looping locales x appearances x scenes on one booted simulator/container; scenes discovered as Maestro flows or declared in a deep-link scene manifest) → optional gated `upload` (consumer's fastlane `deliver` lane, with an optional fail-closed App Store slot-resolution check and an optional App Store Connect duplicate-screenshot verify/repair gate). |
| [`expo-ota-preview.yml`](docs/workflows/expo-ota-preview.md) | `ota-runtime-version` → `expo export` → `expo-ota-manifest` → `github-release-publish` → `pr-preview-comment` (deep link, QR, runtime version and the matching dev build in one sticky comment). EAS-free, tokenless OTA JS preview loaded by a development build through `expo-development-client`; `ota-backend: eas` publishes it with `eas-update` instead, for private repositories. |
| [`expo-fingerprint-guard.yml`](docs/workflows/expo-fingerprint-guard.md) | `native-fingerprint` on the pull-request head → `native-fingerprint` on a merge-base `git worktree` → hash comparison + `fingerprint:diff`. Fails a pull request that silently moves the native runtime fingerprint out from under published OTA updates, unless an override label acknowledges it. |
| [`assert-distinct-fingerprints.yml`](docs/workflows/assert-distinct-fingerprints.md) | Release-pipeline pre-flight: one `expo-native-key` per target, then `assert-distinct-fingerprints` fails when two targets with different `appId` share a native key. Runs before any build starts. |
| [`pr-closed-cleanup-reusable.yml`](docs/workflows/pr-closed-cleanup-reusable.md) | Cancels queued/in-progress workflow runs left behind on a closed PR's branch, so a serialized self-hosted fleet does not starve on zombie runs, and opt-in deletes the PR's `expo-ota-preview.yml` releases once every run of the PR has stopped. Zero required inputs — everything is derived from the calling workflow's `pull_request: closed` event context. |
| [`eas-channel-cleanup-reusable.yml`](docs/workflows/eas-channel-cleanup-reusable.md) | Deletes a closed pull request's EAS Update channel and branch (`channel-template`, e.g. `pr-{number}`) and sweeps channels matching a pattern idle for `max-age-days`; never a channel in the deny-list (`production`, `main` by default), one an `eas.json` profile sets, or one EAS marks protected. Dry-run input. |
| [`preview-sweep-reusable.yml`](docs/workflows/preview-sweep-reusable.md) | Scheduled backstop for the cleanup above: deletes `expo-ota-preview.yml` releases of closed PRs and branch previews older than `max-age-days`, never an open PR's or one inside the grace period, capped per run. Dry run by default. |

`store-screenshots.yml` additionally accepts a `config-path` pointing at a
checked-in JSON file holding its app-shaped configuration (targets, capture
manifest, scenes, build and upload knobs), so a caller shrinks to `uses:` +
`config-path` + runner labels + secrets. Precedence is explicit workflow
input > config file value > built-in default; runner labels and timeouts are
deliberately not loadable, because `runs-on` is resolved before any step can
read a file. See
[docs/workflows/store-screenshots.md#config-file](docs/workflows/store-screenshots.md#config-file)
and the schema at
[`schemas/store-screenshots.schema.json`](schemas/store-screenshots.schema.json).

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

### Choosing an OTA backend

Two ways to ship JavaScript over the air, both loaded by an `expo-updates`
build whose runtime version matches:

| | GitHub Release (EAS-free) | EAS Update |
| --- | --- | --- |
| Pieces | `expo-ota-preview.yml` (default `ota-backend: github-release`): `expo-ota-manifest` + `github-release-publish` | `eas-update`, `eas-channel-fingerprint`, `expo-ota-preview.yml` with `ota-backend: eas`, `native-publish.yml` with `ota-baseline: eas-channel`, `eas-channel-cleanup-reusable.yml` |
| Token | none — the job's `GITHUB_TOKEN` | `EXPO_TOKEN` |
| Repository | **public only**: a device downloads release assets anonymously | public or private |
| Use | pull-request previews for development builds only: a static host sends no protocol headers and supports no code signing, rollout or rollback | previews, and production channels (development, staging, release candidates, per-brand production) with channel/branch management, code signing, rollouts, rollback and the EAS dashboard |
| Cleanup | `pr-closed-cleanup-reusable.yml` + `preview-sweep-reusable.yml` | `eas-channel-cleanup-reusable.yml` |

Pick the GitHub Release backend for a public app that wants previews without
an Expo account; pick EAS Update for a private repository or whenever an
update has to reach store builds. Both resolve the runtime version the same
way (`ota-runtime-version`), produce the same outputs and post the same sticky
preview comment; switching is one input. A job holding an `EXPO_TOKEN` that
can publish to (or delete) a production channel belongs in a GitHub
Environment with required reviewers or a branch policy.

### Package manager

Every reusable workflow above resolves the JS package manager once per job that
installs JS dependencies, after checkout and before `actions/setup-node`. The
result drives pnpm provisioning everywhere, and the
[`node-pm-cache`](actions/node-pm-cache/README.md) dependency cache in the jobs
that configure one (the `ios-maestro` / `android-maestro` / `store-screenshots`
build jobs, `expo-base-plan`, `expo-ota-preview`, `expo-fingerprint-guard`).
That cache is restored on every event but saved only off pull requests, as a
bounded non-fatal step, so a stalled upload can never cancel a finished job. Resolution order:

1. the `package-manager` input, when set to `yarn`, `pnpm` or `npm`;
2. `package.json` at the repository root —
   `devEngines.packageManager.name` first, then `packageManager`, matching
   pnpm's own precedence. Reading it needs `jq` on the runner; without `jq`
   the step emits a `::warning::` and falls through to step 3;
3. exactly one root lockfile — `yarn.lock`, `pnpm-lock.yaml`, or
   `package-lock.json` / `npm-shrinkwrap.json` (both mean npm, so having both
   is not ambiguous).

Those same lockfile names are what the ccache / Pods / Gradle cache keys hash,
so a dependency change re-keys the native caches whichever manager you use.

Nothing to match on, several root lockfiles at once, or an unsupported value
fails the job with an actionable `::error::` instead of guessing. In the jobs
that do configure the dependency cache, the resolved manager's own root lockfile
must exist — the cache key is derived from it — and its absence is reported by
this step rather than by the cache action. Existing
Yarn consumers need no change: a repo with `yarn.lock` (and/or
`packageManager: yarn@…`) resolves to `yarn`, exactly what these workflows
hardcoded before.

`install-command` is a separate knob and still defaults to
`yarn install --immutable` — set it to match your manager:

```yaml
jobs:
    e2e:
        uses: rnw-community/mobile-ci/.github/workflows/ios-maestro.yml@v4.3.1 # v4.3.1
        with:
            targets: >-
                [{"name":"bare","appDir":"apps/mobile","workspace":"MyApp.xcworkspace","scheme":"MyApp","appId":"com.example.app","prebuildCommand":""}]
            flows-dir: apps/mobile/e2e/flows
            install-command: pnpm install --frozen-lockfile
```

When the resolved manager is `pnpm`, pnpm is installed by `pnpm/action-setup`
and the `enable-corepack` step is skipped so pnpm is never provisioned twice.
`pnpm/action-setup` takes its version from the repository-root `package.json`
(`devEngines.packageManager: { name: pnpm, version: … }`, else
`packageManager: "pnpm@…"`), so a pnpm consumer **must** declare one of those
and **must** have `jq` on the runner — the resolve step verifies both up front
and fails with an actionable message rather than letting
`pnpm/action-setup` abort later with `No pnpm version is specified`.

### Android driver: Redroid vs AVD

`android-maestro.yml`'s `android-driver` input picks the Maestro-execution
step's Android backend, `avd` by default:

- **`avd`** (default) — a real Android emulator via
  `run-maestro-android` (which boots it through `android-emulator`), on a host
  with `/dev/kvm`. This is what the default `runner-labels`
  (`["self-hosted","trf-linux-amd64-4x8"]`, an x86_64 Linux KVM pool) provide,
  and it needs no privileged container, no Docker daemon, and no
  `binder_linux`. A `google_apis` system image also carries real Google Play
  Services. The guest is bounded on a memory-limited runner: an empty
  `emulator-ram-size` (the default) is derived from the container's cgroup
  memory limit, 2048 MB on the default 8 GiB pool.
- **`redroid`** — Android as a privileged container over the `binder_linux`
  kernel module (`run-maestro-android-redroid`). Needs no `sdkmanager`, NDK,
  or emulator binary on the runner, so it is the only driver that works at
  all on `linux-aarch64` self-hosted runners — select it together with
  `runner-labels` pointing at such a pool, since it cannot run on the default
  x86_64 one. Stock images ship no Google Play Services. See
  [docs/self-hosted-runners.md](docs/self-hosted-runners.md) for how to
  provision a Redroid host, and
  [which pool a job belongs on](docs/self-hosted-runners.md#which-pool-a-job-belongs-on)
  for the fleet policy these defaults follow.

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
consumer of it (add `ota-preview-release-tag-prefix` and `contents: write` to
also delete the pull request's OTA previews):

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
        uses: rnw-community/mobile-ci/.github/workflows/pr-closed-cleanup-reusable.yml@v4.3.1 # v4.3.1
```

## Scope

In scope: the e2e pipelines (`ios-maestro.yml` / `android-maestro.yml` /
`seed-native-cache.yml`) — ad-hoc-signed (entitlements preserved) iOS
simulator / unsigned Android emulator builds, tokenless
fingerprinting, Maestro; store publishing (`native-publish.yml`:
`eas build --local` for fleet-compute signed builds + `eas submit` for store
upload); development-build distribution (`native-dev-release.yml`:
`eas build --local`, or an opt-in EAS cloud build, to a pruned GitHub Release
or EAS internal distribution); OTA updates (`expo-ota-preview.yml`, the
`eas-update` action, `eas-channel-cleanup-reusable.yml`); store screenshots;
and the native Swift / Xcode lane. `EXPO_TOKEN` and store credentials are
scoped to exactly the jobs that publish — every test pipeline in this catalog
runs with no secrets at all. Store builds run on your own runner; EAS manages
signing-credential custody (and, with `credentials-source: eas`, the store
keys), not build compute, unless you opt into `build-location: cloud` for a
development build.

## Self-hosted runners

Every action and reusable workflow here assumes a self-hosted fleet: macOS
with Xcode installed (iOS), and x86_64 Linux with `/dev/kvm` (the default
`avd` Android driver) or `linux-aarch64` with `binder_linux` and privileged
Docker (the `redroid` driver).
See [docs/self-hosted-runners.md](docs/self-hosted-runners.md) for host
provisioning: the x86_64 Linux pool the repack path runs on, macOS Xcode
pools, Linux `linux-aarch64` Redroid hosts, the Redroid prewarm manifest
format, and the repo variables this repo's own maintainer-only fleet self-test
job reads.

## Repo practices

- Semver + a sliding major tag per major (see [CONTRIBUTING.md](CONTRIBUTING.md)
  and [RELEASE.md](RELEASE.md)).
- Every third-party action pinned by full commit SHA with a `# vX.Y.Z` comment.
- `actionlint`, `shellcheck`, and `zizmor` run in CI (`self-test.yml`) on
  every push and PR; a fleet self-test job exists but is
  `workflow_dispatch`-only since the self-hosted runners are shared with the
  consuming repos.
- MIT licensed.

**Versioning note:** examples in this README, the per-action/per-workflow docs
and [docs/examples/](docs/examples/README.md) pin the exact release they were
checked against (`@v4.3.1 # v4.3.1`). A major tag such as `@v4` floats to the
latest release of that major and `@main` can change without a deprecation
window — pin to an exact `vX.Y.Z` tag or a full commit SHA when you need
reproducibility.

## Used in the wild

Real-world adopters — worth reading as usage examples, not as this repo's
own documentation:

- [vitalyiegorov/suuudokuuu](https://github.com/vitalyiegorov/suuudokuuu) — the fleet-validation consumer: iOS + Android (`avd`) Maestro e2e, warm-up, dev release, store publish and store screenshots.
- [budgie-at/budgie](https://github.com/budgie-at/budgie) — iOS Maestro + native cache, à la carte tier.
- [rnw-community/rnw-community](https://github.com/rnw-community/rnw-community) — monorepo canary pipeline this catalog was extracted from.
