# mobile-ci

Reusable composite actions and `workflow_call` workflows for fleet-native
React Native / Expo mobile CI: fingerprinted native-app caches, Maestro e2e,
and simulator/emulator lifecycle management on self-hosted runners.

**Zero EAS.** Every pipeline here builds fleet-native — `expo prebuild` then
raw `xcodebuild` / `gradlew` on self-hosted runners, no EAS cloud builds, no
`eas-cli`, no `EXPO_TOKEN` anywhere. Native fingerprinting uses the standalone
[`@expo/fingerprint`](https://www.npmjs.com/package/@expo/fingerprint) package
tokenlessly. (Store publishing is out of scope for this catalog; see
[Scope](#scope) below.)

**Pre-release: the `v1` tag is pending pipeline proof.** This catalog was
extracted from `rnw-community/rnw-community`'s canary-optimized e2e pipeline.
`v1` will be cut once that source pipeline's canaries are green on the fleet.
Until then, pin to `@main` — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Pick your tier

- **À la carte** — consume individual composite actions and keep your own
  job/workflow structure. Use this if you already have a working pipeline and
  want to adopt one piece at a time (e.g. just the simulator lifecycle, or
  just the native-app cache).
- **Whole pipeline** — consume `ios-maestro.yml` / `android-maestro.yml` /
  `seed-native-cache.yml` via `workflow_call` and collapse your own workflow
  to a thin `uses:` wrapper with inputs. Use this for a new pipeline or when
  migrating a pipeline that already matches this shape closely.

## Action catalog

| Action                  | Purpose                                                                                     |
| ------------------------ | --------------------------------------------------------------------------------------------- |
| `setup-xcode-pinned`     | Select a pre-installed Xcode by exact version+build; hard-assert the match.                    |
| `native-fingerprint`     | Tokenless `@expo/fingerprint` hash of an app's native surface.                                  |
| `native-app-cache`       | Restore/save the canonical native `.app`/`.apk` keyed on profile/os/arch/toolchain/fingerprint. |
| `setup-ccache-ios`       | Bounded, compressed ccache install + restore/save for `xcodebuild`.                             |
| `build-ios-app`          | Release, unsigned iOS Simulator `.app` via `xcodebuild`, embedded jsbundle verified.            |
| `build-android-app`      | Release `.apk` via `gradlew`, embedded JS bundle verified, pinned `cmdline-tools-version`.       |
| `run-maestro-ios`        | Simulator boot/bootstatus/install/test/capture/shutdown for a Maestro flow shard.               |
| `run-maestro-android`    | Headless AVD emulator boot/install/test/capture/shutdown for a Maestro flow shard.               |
| `run-maestro-android-redroid` | Redroid (Android-in-container) boot/install/test/capture/teardown for a Maestro flow shard — the only Android driver that boots at all on `linux-aarch64` self-hosted runners; `android-maestro.yml`'s default. |
| `turbo-affected`         | Fail-closed `turbo ls --affected` detection gating a pipeline to touched packages.               |

Each action has its own `README.md` under `actions/<name>/` with the full
input/output table and a usage example.

## Reusable workflows

| Workflow                  | Composes                                                                          |
| --------------------------- | ------------------------------------------------------------------------------------ |
| `ios-maestro.yml`           | `turbo-affected` → `setup-xcode-pinned` → `native-fingerprint` → `native-app-cache` → `setup-ccache-ios` → `build-ios-app` → `run-maestro-ios` |
| `android-maestro.yml`       | `turbo-affected` → `native-fingerprint` → `native-app-cache` → `build-android-app` → `run-maestro-android-redroid` (default) or `run-maestro-android` (`android-driver: avd`) |
| `seed-native-cache.yml`     | The build half of both pipelines above, without the detect/test jobs — populates the native-app cache on a schedule or dispatch. |
| `pr-closed-cleanup-reusable.yml` | Cancels queued/in-progress workflow runs left behind on a closed PR's branch, so a serialized self-hosted fleet does not starve on zombie runs. Zero required inputs — everything is derived from the calling workflow's `pull_request: closed` event context. |

### Android driver: Redroid vs AVD

`android-maestro.yml`'s `android-driver` input picks the Maestro-execution
step's Android backend, `redroid` by default:

- **`redroid`** (default) — Android as a privileged container over the
  `binder_linux` kernel module (`run-maestro-android-redroid`). Needs no
  `sdkmanager`, NDK, or emulator binary on the runner, so it is the only
  driver that works at all on `linux-aarch64` self-hosted runners — this
  workflow's own default `runner-labels`. Proven on `vitalyiegorov/suuudokuuu`'s
  fleet (redroid tag `15.0.0_64only` verified against a `6.17` host kernel;
  animation scales forced to `0` after boot) and ported into
  `rnw-community/rnw-community`'s canary pipeline.
- **`avd`** — a real Android emulator via
  `reactivecircus/android-emulator-runner` (`run-maestro-android`). Only
  viable when `runner-labels` is overridden to a host with a working
  emulator + acceleration, e.g. GitHub-hosted `ubuntu-latest` (KVM-accelerated
  out of the box). Google does not publish `linux-aarch64` builds of the
  Android emulator, NDK, or `cmake`, so `avd` cannot boot on this workflow's
  default self-hosted fleet regardless of tuning — that gap is exactly why
  `redroid` is the default rather than an opt-in.

`seed-native-cache.yml` is meant to be called from a workflow that is itself
`workflow_dispatch`-triggered (plus optionally `push`/`schedule`) in the
*consuming* repository. GitHub only allows dispatching a `workflow_dispatch`
workflow once it exists on the default branch — merge your caller workflow to
your default branch before expecting to dispatch it.

`pr-closed-cleanup-reusable.yml` must be called from a workflow triggered by
`pull_request: types: [closed]` in the consuming repository — it reads
`github.event.pull_request.head.ref` from that event, so it cannot be
dispatched standalone. This repo's own `pr-closed-cleanup.yml` is a one-line
consumer of it (see below).

## Scope

In scope for `v1`: the e2e pipelines above — unsigned simulator/emulator
builds, tokenless fingerprinting, Maestro. Out of scope for `v1`: store
publishing. A future `native-publish` reusable workflow (extracted from
budgie's `native-publish.yml`: `eas build --local` for fleet-compute signed
builds + `eas submit` for store upload, with `EXPO_TOKEN` scoped to that
workflow only) is planned for `v1.1` — it is the one sanctioned place EAS
remains in this stack, because EAS there only manages signing-credential
custody, not build compute.

## Consumer examples

### rnw-community/rnw-community (react-native-payments-example)

```yaml
# .github/workflows/ios-maestro.yml
name: iOS Maestro E2E
on:
    workflow_dispatch:
    pull_request:
    push:
        branches: [master]
    schedule:
        - cron: '17 3 * * *'
concurrency:
    group: ios-maestro-${{ github.ref }}
    cancel-in-progress: true
jobs:
    e2e:
        uses: rnw-community/mobile-ci/.github/workflows/ios-maestro.yml@main
        with:
            targets: >-
                [{"name":"bare","appDir":"packages/react-native-payments-example/apps/bare","workspace":"ReactNativePaymentsExample.xcworkspace","scheme":"ReactNativePaymentsExample","appId":"org.reactjs.native.example.ReactNativePaymentsExample","prebuildCommand":""},
                 {"name":"expo","appDir":"packages/react-native-payments-example/apps/expo","workspace":"reactnativepaymentsexpoexample.xcworkspace","scheme":"reactnativepaymentsexpoexample","appId":"com.reactnativepaymentsexpoexample","prebuildCommand":"yarn prebuild:expo"}]
            flows-dir: packages/react-native-payments-example/e2e/flows
            target-packages: |
                @rnw-community/react-native-payments
                @rnw-community/react-native-payments-example
            build-command: yarn build --filter=@rnw-community/react-native-payments
            rct-use-prebuilt-rncore: true
            rct-use-rn-dep: true
            expo-use-precompiled-modules: true
```

### budgie-at/budgie

À la carte tier: budgie keeps its existing EAS-based build steps and adopts
just the simulator/emulator lifecycle actions —

```yaml
- uses: rnw-community/mobile-ci/actions/run-maestro-ios@main
  with:
      app-path: build/output/Budgie.app
      app-id: at.budgie.app
      flows-dir: e2e/flows
      shard-index: '0'
      shard-count: '1'
      artifacts-dir: ${{ github.workspace }}/artifacts/maestro-ios
      artifact-name: maestro-ios-shard-0
```

### vitalyiegorov/suuudokuuu

Whole-pipeline tier, same shape as the rnw-community example above, with
`targets` reduced to suuudokuuu's single bare app and its own `appId`/paths.

### PR-closed cleanup (rnw-community, budgie, suuudokuuu)

Every consumer with a serialized self-hosted fleet adopts this the same way —
a thin wrapper triggered by the PR's own `closed` event:

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

## Repo practices

- Semver + sliding `v1` tag once cut (see [CONTRIBUTING.md](CONTRIBUTING.md)).
- Every third-party action pinned by full commit SHA with a `# vX.Y.Z` comment.
- `actionlint` + `shellcheck` run in CI (`self-test.yml`) on every push and PR;
  a fleet self-test job exists but is `workflow_dispatch`-only since the
  self-hosted runners are shared with the consuming repos.
- MIT licensed.
