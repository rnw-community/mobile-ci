# `swift-ios.yml`

The whole-pipeline tier for a **native Swift / Xcode** app — no React Native,
no Expo, no Node, no CocoaPods, no EAS. It composes the à la carte native-Swift
actions into three jobs:

| Job       | Composes                                                                                                                                  |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `build`   | `setup-xcode-pinned` → `xcode-cache` (restore) → `swift-test` → `xcodebuild-test` (`mode: build`) → `xcode-cache` (save)                    |
| `test`    | One matrix leg per `shards-json` entry: `setup-xcode-pinned` → `xcode-cache` (restore) → `simulator-lease` → `xcodebuild-test` (`mode: test`) → `simulator-lease` (release) |
| `publish` | `setup-xcode-pinned` → `apple-signing` (install) → `xcode-archive-upload` → optional tag + GitHub Release → `apple-signing` (remove)        |

`build` and `test` need **no secrets at all**. `publish` is opt-in
(`enable-publish: true`), runs only after both pass, and is the only job that
touches signing material.

The split is the point: `build` compiles the tests **once** and saves
DerivedData under a key of `toolchain + project fingerprint`; every `test`
shard restores that same key and runs `test-without-building`, so N shards
share one compile instead of each paying for their own. `shards-json: '[0]'`
(the default) is a single unsharded leg. Because the array's length *is* the
shard count, there is no second knob that can disagree with the matrix.

Restored `-derivedDataPath` is an absolute path, so `build` and `test` share
one `runs-on-json` label set — a homogeneous pool, where the workspace path is
the same on every VM.

```yaml
jobs:
    ios:
        uses: rnw-community/mobile-ci/.github/workflows/swift-ios.yml@v1
        with:
            xcode-version: '26.4.1'
            xcode-build: '17E202'
            project: MyApp.xcodeproj
            scheme: MyApp
            simulator-device-type: 'iPad Pro 11-inch (M4)'
            enable-swift-test: true
        secrets: {}
```

## Speed model

The three levers, in the order they pay off:

1. **`swift-test`** runs the pure-logic Swift Package targets with
   `swift test --parallel` — seconds, no simulator, no app build. Most logic
   regressions are caught here and never reach the slow lane.
2. **`xcode-cache`** restores DerivedData, the resolved Swift Package clones,
   and the Xcode 26 compilation cache (CAS) before anything compiles. With
   `cache-backend: local` the entries live on a directory the self-hosted VM
   already mounts, so a warm run pays no network at all.
3. **`xcodebuild-test`** compiles the tests **once** with `build-for-testing`
   in the `build` job, then runs them with `test-without-building` against a
   freshly leased, already-booted simulator in each `test` shard — so the cold
   boot is not inside the test timeout, the compile is not repeated per shard,
   and wall-clock falls roughly linearly in the number of shards.

The measured shape of the problem, from the consumer of record
(`vitalyiegorov/pony-labirinth`, run `35560967152`, 21m15s total): `swift test`
50s, `xcodebuild build` 22s, simulator create 1s, and `xcodebuild test`
**1177s — 92% of the job**, single shard, recompiling inside `test`. That last
number is what this workflow's shape exists to attack.

## Inputs

### Shape

| Name                  | Required | Default | Description                                              |
| --------------------- | -------- | ------- | ---------------------------------------------------------- |
| `xcode-version`       | yes      | —       | Xcode version string, e.g. `26.4.1`.                       |
| `xcode-build`         | yes      | —       | Xcode build number, e.g. `17E202`.                         |
| `project`             | no       | `''`    | Path to the `.xcodeproj`. Exactly one of project/workspace. |
| `workspace`           | no       | `''`    | Path to the `.xcworkspace`.                                |
| `scheme`              | yes      | —       | Scheme built, tested and archived.                         |
| `configuration`       | no       | `Debug` | Configuration used by `build` and `test`.                  |
| `working-directory`   | no       | `.`     | Directory every project-relative path resolves against.    |
| `checkout-fetch-depth`| no       | `1`     | `fetch-depth` passed to `actions/checkout`.                |

### Runners and timeouts

| Name                        | Default                                          |
| --------------------------- | -------------------------------------------------- |
| `runs-on-json`              | `["self-hosted","trf-macos-arm64-4x7"]` (build **and** test) |
| `publish-runs-on-json`      | `["self-hosted","trf-macos-arm64-6x12"]`           |
| `validate-timeout-minutes`  | `45` (applies to `build` and to each `test` shard)  |
| `publish-timeout-minutes`   | `90`                                               |

`runs-on` is resolved before any step runs, so both are JSON arrays of labels
rather than anything derived at runtime.

### Cache

| Name                | Default                                                | Description                                          |
| ------------------- | ------------------------------------------------------ | ------------------------------------------------------ |
| `cache-backend`     | `github`                                               | `github` (actions/cache) or `local` (a plain directory). |
| `cache-local-dir`   | `''`                                                   | Cache root for `local`. Required when `cache-backend` is `local`. |
| `derived-data-dir`  | `build/DerivedData`                                    | `-derivedDataPath`.                                    |
| `spm-clones-dir`    | `build/SourcePackages`                                 | `-clonedSourcePackagesDirPath`.                        |
| `cas-dir`           | `build/CompilationCache`                               | `COMPILATION_CACHE_CAS_PATH`.                          |
| `fingerprint-paths` | `**/*.pbxproj`, `Package.swift`, `**/Package.resolved`, `**/*.swift`, `**/*.xcconfig`, `**/*.plist`, `**/*.entitlements` | Globs hashed into the cache key. Build inputs are included because the `test` shards restore what `build` compiled. Not exhaustive: add asset catalogs or script-phase inputs your project has. |

The same `cache-backend` / `cache-local-dir` pair also drives `swift-test`'s
`.build` cache.

The cache key also carries the **scheme and configuration**
(`key-prefix: xcode-cache-v1-<scheme>-<configuration>`), so two callers sharing
one checkout and one `derived-data-dir` cannot restore each other's products.
The `build` job saves only on **success**, so a failed compile never publishes
a half-built DerivedData under an immutable key that a retry would restore.
There are no fallback/prefix keys: only an exact hit counts, because a
prefix-matched DerivedData would let a `test` shard run an older revision's
compiled products and pass.

### Tests

| Name                     | Default                      | Description                                             |
| ------------------------ | ---------------------------- | --------------------------------------------------------- |
| `enable-swift-test`      | `false`                      | Run `swift test --parallel`. Opt-in: an Xcode-only app has no `Package.swift`. |
| `swift-package-path`     | `.`                          | Directory holding `Package.swift`, resolved **relative to `working-directory`**. |
| `swift-test-extra-args`  | `''`                         | Extra arguments for `swift test`.                         |
| `enable-xcodebuild-test` | `true`                       | Compile and run the simulator-bound tests at all.         |
| `simulator-device-type`  | `''`                         | Exact device type name. **Required** whenever `enable-xcodebuild-test` is `true`; the `test` job fails closed on an empty value rather than guessing a device. |
| `simulator-runtime`      | `latest`                     | `latest` or an exact runtime identifier.                  |
| `simulator-template-device` | `''`                      | Name of a shut-down, prewarmed device to `simctl clone` instead of creating one. A slimmed template clones slim. |
| `simulator-slim-profile` | `bundled`                    | `bundled` uses mobile-ci's own [`profiles/ci.json`](../../profiles/ci.json); a repo-relative path uses that profile instead; empty leases a stock device. |
| `simulator-slim-repair`  | `true`                       | Apply the profile in-job (a reboot) on drift. Set `false` with a slimmed template so an unslimmed one errors. |
| `parallel-testing`       | `NO`                         | `-parallel-testing-enabled`. `YES` makes Xcode run the tests on `Clone 1 of <lease>`, a second simulator on the same guest, and is refused without `parallel-testing-worker-count` ([#155](https://github.com/rnw-community/mobile-ci/issues/155)). |
| `parallel-testing-worker-count` | `''`                  | `-parallel-testing-worker-count`. Each worker clones the leased simulator, so raise it only on a slimmed lease on the 6x12 profile. Required when `parallel-testing` is `YES`, refused when it is `NO`. |
| `test-plan`              | `''`                         | `-testPlan` name.                                         |
| `only-testing`           | `''`                         | Test identifiers to run (and to shard).                   |
| `shards-json`            | `[0]`                        | JSON array of shard indices; one `test` matrix leg each, and its length is the shard count. Must list every zero-based index exactly once — `[0, 0]` would run one shard twice, never run the other, and still report green, so it fails closed. |
| `result-bundle-path-prefix` | `build/TestResults-`      | `.xcresult` path per shard: `<prefix><index>.xcresult`; each is uploaded as an artifact. |

### Publish

| Name                    | Default              | Description                                                |
| ----------------------- | -------------------- | ------------------------------------------------------------ |
| `enable-publish`        | `false`              | Run the `publish` job at all.                                |
| `publish-configuration` | `Release`            | Configuration used for the archive.                          |
| `publish-environment`   | `''`                 | GitHub Environment gating the job and scoping its secrets.   |
| `team-id`               | `''`                 | Apple Developer team identifier.                             |
| `bundle-id`             | `''`                 | Bundle identifier being published.                           |
| `build-number`          | `''`                 | `CFBundleVersion`; defaults to `1000 + github.run_number`.   |
| `signing-certificate`   | `Apple Distribution` | `CODE_SIGN_IDENTITY` / exportOptions `signingCertificate`.   |
| `archive-path`          | `''`                 | Defaults to `build/<scheme>.xcarchive`.                      |
| `export-path`           | `build/AppStoreUpload` | `-exportArchive` output directory.                         |
| `upload`                | `true`               | `false` exports locally and never contacts Apple.            |
| `create-release`        | `false`              | Tag the commit and cut a GitHub Release.                     |
| `release-tag-prefix`    | `build/`             | Tag is `<prefix><build-number>`.                             |

`expected-application-identifier` is not a separate input: the workflow asserts
the provisioning profile declares `<team-id>.<bundle-id>`.

## Secrets

All optional, all only read by `publish`:

| Secret                       | Used for                                       |
| ---------------------------- | ------------------------------------------------ |
| `apple-certificate-base64`   | The distribution `.p12`.                         |
| `apple-certificate-password` | Its password.                                    |
| `apple-profile-base64`       | The App Store `.mobileprovision`.                |
| `asc-key-base64`             | The App Store Connect API `.p8`.                 |
| `asc-key-id`                 | ASC API key ID.                                  |
| `asc-issuer-id`              | ASC API issuer ID.                               |

Pass them explicitly (`secrets: apple-certificate-base64: ${{ secrets.… }}`);
this workflow is never called with `secrets: inherit` in the examples, so a
caller's unrelated secrets never enter the job.

## Outputs

| Name           | Description                                  |
| -------------- | ---------------------------------------------- |
| `build-number` | The build number the `publish` job used.        |

## Permissions

`contents: read` for the workflow; the `publish` job raises itself to
`contents: write` so `create-release` can cut the tag and release. A caller
whose `create-release` stays `false` still grants `contents: write` to the job,
which is the smallest granularity GitHub offers here.

## Full example

```yaml
name: iOS
on:
    pull_request:
    push:
        branches: [main]

permissions:
    contents: read

jobs:
    ios:
        uses: rnw-community/mobile-ci/.github/workflows/swift-ios.yml@v1
        permissions:
            contents: write
        with:
            xcode-version: '26.4.1'
            xcode-build: '17E202'
            project: MyApp.xcodeproj
            scheme: MyApp
            simulator-device-type: 'iPad Pro 11-inch (M4)'
            enable-swift-test: true
            shards-json: '[0, 1]'
            cache-backend: local
            cache-local-dir: /Volumes/My Shared Files/ci-shared/xcode-cache
            enable-publish: ${{ github.ref == 'refs/heads/main' }}
            publish-environment: testflight
            team-id: 3R8589YV24
            bundle-id: com.example.app
            create-release: true
        secrets:
            apple-certificate-base64: ${{ secrets.APPLE_DISTRIBUTION_CERTIFICATE_BASE64 }}
            apple-certificate-password: ${{ secrets.APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD }}
            apple-profile-base64: ${{ secrets.APP_STORE_PROVISIONING_PROFILE_BASE64 }}
            asc-key-base64: ${{ secrets.ASC_PRIVATE_KEY_BASE64 }}
            asc-key-id: ${{ secrets.ASC_KEY_ID }}
            asc-issuer-id: ${{ secrets.ASC_ISSUER_ID }}
```

A consumer that needs extra jobs between the two (a release-notes preview, a
store metadata step) composes the **actions** à la carte instead — see the
per-action READMEs under [`actions/`](../../actions/).
