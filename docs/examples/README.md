# Example caller workflows

Complete workflows for four app shapes, each a file you copy into the app
repository's `.github/workflows/` and edit (paths, app ids, schemes, brands).
Every file is pinned `@v4.4.1 # v4.4.1` and grants exactly the `permissions:`
its calls need. A repository whose policy (or `zizmor`'s `unpinned-uses`)
requires commit-SHA pins swaps each for `@<sha> # v4.4.1`, where `<sha>` is
what `git ls-remote https://github.com/rnw-community/mobile-ci 'refs/tags/v4.4.1^{}'`
prints.

CI keeps them honest: `self-test.yml` runs `actionlint` on every file here, and
[`tests/docs-examples_test.sh`](../../tests/docs-examples_test.sh) resolves
every `rnw-community/mobile-ci/...@<ref>` to the workflow or action at the
same commit and fails on an input or secret it does not declare, a missing
required input or secret, a missing `# vX.Y.Z` pin comment, or a calling job
that grants less than any job of the called workflow requests. The same test checks the yaml blocks in the
Markdown docs.

## (a) Public Expo app — [`public-expo-app/`](public-expo-app/)

| File | Trigger | What it does |
| --- | --- | --- |
| [`e2e.yml`](public-expo-app/e2e.yml) | pull request, push to `main` | `ios-maestro.yml` + `android-maestro.yml` on the repack path: no native compile on a pull request whose native key has a published base. |
| [`warm-up.yml`](public-expo-app/warm-up.yml) | push to `main` (app paths), dispatch | `seed-native-cache.yml`: builds and publishes the base binary for every native key that has none. |
| [`ota-preview.yml`](public-expo-app/ota-preview.yml) | pull request | `expo-ota-preview.yml` on the GitHub Release backend: tokenless, public repositories only, previews only. |
| [`pr-closed.yml`](public-expo-app/pr-closed.yml) | PR closed, nightly | `pr-closed-cleanup-reusable.yml` (cancel runs, delete the PR's previews) and `preview-sweep-reusable.yml` (dry-run backstop). |

## (b) Private multi-brand Expo app — [`private-multi-brand-expo-app/`](private-multi-brand-expo-app/)

| File | Trigger | What it does |
| --- | --- | --- |
| [`ota-preview.yml`](private-multi-brand-expo-app/ota-preview.yml) | pull request | `expo-ota-preview.yml` with `ota-backend: eas`: the preview is an EAS Update on channel `pr-<number>`, linked to the newest matching EAS development build. |
| [`dev-build.yml`](private-multi-brand-expo-app/dev-build.yml) | push to `main`, dispatch | `native-dev-release.yml` once per brand in a matrix (`call-scope`), with `distribution: eas`: testers install from the EAS build page, no repository access needed. |
| [`store-release.yml`](private-multi-brand-expo-app/store-release.yml) | release tag | `assert-distinct-fingerprints.yml`, then `native-publish.yml` once per brand (`record-scope`, `credentials-source: eas`, `mode: auto`, `ota-baseline: eas-channel`), then `eas-update` to each brand's production channel in the `production` GitHub Environment. |
| [`eas-channel-cleanup.yml`](private-multi-brand-expo-app/eas-channel-cleanup.yml) | PR closed, weekly | `eas-channel-cleanup-reusable.yml`: deletes the PR's channel, sweeps idle `rc-*` channels, never a protected or `eas.json` channel. |

## (c) Pure Swift / Xcode app — [`swift-xcode-app/`](swift-xcode-app/)

| File | Trigger | What it does |
| --- | --- | --- |
| [`ios.yml`](swift-xcode-app/ios.yml) | pull request, push to `main` | `swift-ios.yml`: one compile, sharded simulator tests, affected-test selection on pull requests; on `main`, signed TestFlight upload in the `testflight` Environment. |
| [`release.yml`](swift-xcode-app/release.yml) | release tag | The publish lane à la carte: `setup-xcode-pinned` → `apple-signing` → `xcode-archive-upload` → `apple-signing` `mode: remove`, in the `app-store` Environment. |

## (d) Monorepo of React Native packages — [`rn-packages-monorepo/`](rn-packages-monorepo/)

| File | Trigger | What it does |
| --- | --- | --- |
| [`e2e.yml`](rn-packages-monorepo/e2e.yml) | pull request, push, nightly | One `ios-maestro.yml` / `android-maestro.yml` call per platform for every package: per-target `flowsDir`, `buildStrategy: native` for the bare apps, one suite quarantined with `tolerateTestFailures`. |
| [`pr-closed.yml`](rn-packages-monorepo/pr-closed.yml) | PR closed | `pr-closed-cleanup-reusable.yml`: frees the shared fleet from a closed PR's runs. |

## Permissions at a glance

| Workflow | Calling job grants |
| --- | --- |
| `ios-maestro.yml`, `android-maestro.yml`, `seed-native-cache.yml`, `store-screenshots.yml` | `contents: read`, `packages: write`, `actions: read` |
| `expo-ota-preview.yml` | `contents: write`, `pull-requests: write` |
| `native-dev-release.yml` | `contents: write` (+ `pull-requests: write` with `pr-comment: true`) |
| `native-publish.yml` | `contents: read` (+ `contents: write` for a store build record, + `actions: read` for `build-number: auto` in a private repository) |
| `store-release.yml` | `contents: read` |
| `pr-closed-cleanup-reusable.yml` | `actions: write` (+ `contents: write` with `ota-preview-release-tag-prefix`) |
| `preview-sweep-reusable.yml` | `contents: write`, `pull-requests: read` |
| `eas-channel-cleanup-reusable.yml`, `assert-distinct-fingerprints.yml` | `contents: read` |
| `swift-ios.yml` | `contents: write`, even without publishing: its `publish` job requests it, and GitHub refuses to start a run whose called job asks for more than the caller granted |
| `expo-fingerprint-guard.yml` | `contents: read`, `pull-requests: read` |
