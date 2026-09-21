# `swift-ios.yml`

The whole-pipeline tier for a **native Swift / Xcode** app — no React Native,
no Expo, no Node, no CocoaPods, no EAS. It composes the à la carte native-Swift
actions into two jobs:

| Job        | Composes                                                                                                                                       |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `validate` | `setup-xcode-pinned` → `xcode-cache` (restore) → `swift-test` → `simulator-lease` (acquire) → `xcodebuild-test` → `simulator-lease` (release) → `xcode-cache` (save) |
| `publish`  | `setup-xcode-pinned` → `apple-signing` (install) → `xcode-archive-upload` → optional tag + GitHub Release → `apple-signing` (remove)             |

`validate` needs **no secrets at all**. `publish` is opt-in
(`enable-publish: true`), runs only after `validate` passes, and is the only
job that touches signing material.

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
   and then runs them with `test-without-building` against a freshly leased,
   already-booted simulator — so the cold boot is not inside the test timeout,
   and the same compiled products can be re-run or sharded.

## Inputs

### Shape

| Name                  | Required | Default | Description                                              |
| --------------------- | -------- | ------- | ---------------------------------------------------------- |
| `xcode-version`       | yes      | —       | Xcode version string, e.g. `26.4.1`.                       |
| `xcode-build`         | yes      | —       | Xcode build number, e.g. `17E202`.                         |
| `project`             | no       | `''`    | Path to the `.xcodeproj`. Exactly one of project/workspace. |
| `workspace`           | no       | `''`    | Path to the `.xcworkspace`.                                |
| `scheme`              | yes      | —       | Scheme built, tested and archived.                         |
| `configuration`       | no       | `Debug` | Configuration used by `validate`.                          |
| `working-directory`   | no       | `.`     | Directory every project-relative path resolves against.    |
| `checkout-fetch-depth`| no       | `1`     | `fetch-depth` passed to `actions/checkout`.                |

### Runners and timeouts

| Name                        | Default                                          |
| --------------------------- | -------------------------------------------------- |
| `runs-on-json`              | `["self-hosted","trf-macos-arm64-4x7"]`            |
| `publish-runs-on-json`      | `["self-hosted","trf-macos-arm64-6x12"]`           |
| `validate-timeout-minutes`  | `45`                                               |
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
| `fingerprint-paths` | `**/*.pbxproj`, `Package.swift`, `**/Package.resolved` | Globs hashed into the cache key.                       |

The same `cache-backend` / `cache-local-dir` pair also drives `swift-test`'s
`.build` cache.

### Tests

| Name                     | Default                      | Description                                             |
| ------------------------ | ---------------------------- | --------------------------------------------------------- |
| `enable-swift-test`      | `true`                       | Run `swift test --parallel`.                              |
| `swift-package-path`     | `.`                          | Directory holding `Package.swift`.                        |
| `swift-test-extra-args`  | `''`                         | Extra arguments for `swift test`.                         |
| `enable-xcodebuild-test` | `true`                       | Run the simulator-bound test lane.                        |
| `simulator-device-type`  | `''`                         | Exact device type name; required when the lane is enabled. |
| `simulator-runtime`      | `latest`                     | `latest` or an exact runtime identifier.                  |
| `test-plan`              | `''`                         | `-testPlan` name.                                         |
| `only-testing`           | `''`                         | Test identifiers to run (and to shard).                   |
| `shard-count`            | `1`                          | Number of shards; `1` disables sharding.                  |
| `result-bundle-path`     | `build/TestResults.xcresult` | `.xcresult` path; uploaded as an artifact.                |

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
