# expo-base-plan.yml

The decision "does this commit have to compile native code?", stated once.

`ios-maestro.yml`, `android-maestro.yml`, `store-screenshots.yml` and
`seed-native-cache.yml` all call it instead of restating the rule, so a
`build-strategy` value or a force-native label means the same thing in every
pipeline. **Consumers do not normally call it directly** — call the e2e,
screenshot or warm-up workflow, which passes its own inputs through. It is
documented here because it is where the behaviour actually lives.

Read [docs/repack.md](../repack.md) first; this page is the input reference.

## What it does

For every target, on the runner pool named by `runner-labels` (an x86_64 Linux
pool by default):

1. installs dependencies, runs `build-command`, and runs the target's
   `prebuildCommand`, so the fingerprint sees what a native build would see;
2. [`expo-native-key`](../../actions/expo-native-key) computes the native key;
3. [`expo-base-binary`](../../actions/expo-base-binary) fetches the base
   published for it — unless the target's `buildStrategy`, or else
   `build-strategy`, is `native`, which skips the lookup;
4. when a base is found and `repack` is true,
   [`expo-repack`](../../actions/expo-repack) repacks it and uploads it as
   `<app-artifact-prefix>-<target name>` — the artifact the caller's test or
   capture job already downloads;
5. records the target's decision as `<plan-artifact-prefix>-<target name>`:
   it needs a native build when no base was found, or when the target carries
   `"forceNative": true` (the warm-up sets it on an iOS target whose compile
   caches were evicted). Only a caller with `repack: false` may set
   `forceNative`; a repacking caller that does fails the job, because a
   repacked target already has the binary its jobs consume.

On android, the repack's Android SDK (`platform-tools` and
`build-tools;<android-build-tools-version>`) is restored from the Actions cache
first, keyed like [`build-android-app`'s](../../actions/build-android-app#android-sdk-cache);
a hit runs no `sdkmanager` and downloads nothing. The cache is saved by the
job's last step, never on `pull_request`, with `continue-on-error` and a
10-minute `timeout-minutes`.

The collecting job also fails closed when two targets with different `appId`
resolve to the same native key (same-`appId` targets sharing a key are a
legitimate dedupe): the error names both targets, the key and the fingerprint
sources they share. See [docs/repack.md](../repack.md#targets-that-differ-only-in-brand-assets-or-per-target-config)
for the `extraSources` fix and
[`assert-distinct-fingerprints.yml`](assert-distinct-fingerprints.md) for the same
check ahead of a build pipeline. When no target declares an `appId` (the `seed-native-cache.yml` target shape) there is nothing to prove distinct, so the comparison is skipped with a notice; the e2e and screenshot callers that consume those bases still run it with their `appId`s. A mix of targets with and without `appId` fails.

A collecting job then folds every target's decision into the `native-targets`
output. It reads only the plans named `<plan-artifact-prefix>-<target name>` for
this call's targets, never another call's plans in the same run. One plan per
target is required: a plan that never arrived is not an
empty set of native builds, it is a target whose strategy nobody decided, and
the job fails.

Under `build-strategy: repack` (or a target's `buildStrategy: repack`) a target with no base fails the job, naming the
key and the address that is empty.

## Inputs

| Name | Type | Required | Default | Description |
| ---- | ---- | -------- | ------- | ----------- |
| `platform` | string | yes | — | `ios` or `android`. |
| `targets` | string | yes | — | JSON array of build targets. Each element is passed through to the caller's native build job unchanged, with `nativeKey` added. A target with `"forceNative": true` is handed to the native build even when its base exists; only a caller with `repack: false` may set it. A target's own `buildStrategy` (`auto`, `repack` or `native`, resolved by the caller) wins over `build-strategy` for that target. |
| `build-strategy` | string | no | `auto` | `auto`, `repack` or `native`. Resolved by the caller, never here. The default of a target without its own `buildStrategy`. |
| `repack` | boolean | no | `true` | Repack the base when one is found. The warm-up sets it false: it is looking for a key with no base, not producing this commit's binary. |
| `runner-labels` | string | no | `'["self-hosted","trf-linux-amd64-2x4"]'` | JSON array of runner labels for the plan jobs. The default is the 2 vCPU / 4 GiB x86_64 pool without `/dev/kvm`, so these jobs never queue on the KVM emulator lane ([#169](https://github.com/rnw-community/mobile-ci/issues/169)); keep it x86_64 (Google ships Android build-tools for x86_64 Linux only) and move to the 4x8 pool if bundling the JavaScript needs more than about 3 GiB. |
| `control-runner-labels` | string | no | `'["ubuntu-latest"]'` | JSON array of runner labels for the lightweight control jobs (detect/status/collect/validate-manifest/cancel-queued-runs), which need no self-hosted hardware. Set it when the org has no hosted runners, e.g. an ephemeral RunsOn label set; it is passed on to `expo-base-plan.yml` by the workflows that call it. |
| `runs-on-cache-bypass` | boolean | no | `false` | Opt-in. When a job lands on a RunsOn runner started with `extras=s3-cache`, whose cache proxy takes over the Actions results URL and breaks `actions/upload-artifact`/`download-artifact`, run a SHA-pinned `runs-on/action` first (via the [`runs-on-cache-bypass`](../../actions/runs-on-cache-bypass/README.md) action). A logged no-op on every other runner. |
| `timeout-minutes` | number | no | `30` | Per-target timeout. |
| `app-artifact-prefix` | string | yes | — | Artifact-name prefix the caller's test/capture job downloads the app under. |
| `plan-artifact-prefix` | string | yes | — | Artifact-name prefix for the per-target plan files. The collecting job reads exactly `<plan-artifact-prefix>-<target name>` per target, so other plans in the same run are never counted. A caller that runs several times in one run puts its own scope in both prefixes (`ios-maestro.yml` and `android-maestro.yml` do it with `call-scope`); that is why this workflow needs no scope input of its own. |
| `toolchain` | string | no | `''` | Pinned toolchain identity folded into the key — `xcode-<version>-<build>` on ios, `cmdline-<version>` on android. |
| `ios-simulator-archs` | string | no | `arm64` | `arm64` or `x86_64`: the Simulator slice an ios base is built for. Folded into the native key by `expo-native-key` (only when `x86_64`, so arm64 keys are unchanged). Ignored on android. |
| `base-backend` | string | no | `ghcr` | `ghcr` or `artifact`. |
| `base-flavor` | string | no | `e2e` | Flavor segment of the base's address. |
| `fingerprint-config` | string | no | `fingerprint.config.js` | Path, relative to a target's `appDir`, of the fingerprint config whose hash enters the key. |
| `fingerprint-env` | string | no | `''` | Newline-separated `KEY=VALUE` exported while the key is computed. |
| `expo-fingerprint-version` | string | no | `0.20.6` | Pinned `@expo/fingerprint` npm version. |
| `repack-env` | string | no | `''` | Newline-separated `KEY=VALUE` exported for the re-bundle. |
| `expect-config` | string | no | `''` | Newline-separated `<dotted.path>=<value>` assertions on the repacked binary's embedded `app.config`. |
| `repack-app-version` | string | no | `0.7.2` | Pinned `@expo/repack-app` npm version. |
| `cmdline-tools-version` | string | no | `12266719` | Android cmdline-tools version. Ignored on ios. |
| `android-build-tools-dir` | string | no | `''` | Build-tools directory holding `zipalign`/`apksigner`. Empty uses `$ANDROID_SDK_ROOT/build-tools/<android-build-tools-version>`, which the plan job installs. |
| `android-build-tools-version` | string | no | `35.0.0` | Build-tools version the plan job installs. |
| `android-keystore-path` | string | no | `android/app/debug.keystore` | Keystore, relative to a target's `appDir`, the repacked APK is signed with. |
| `android-keystore-password` | string | no | `android` | Password of that keystore. |
| `android-keystore-key-alias` | string | no | `androiddebugkey` | Key alias inside it. |
| `android-keystore-key-password` | string | no | `android` | Key password inside it. |
| `node-version` | string | no | `22.x` | Node version. |
| `install-command` | string | no | `yarn install --immutable` | Dependency install command. |
| `enable-corepack` | boolean | no | `true` | Run `corepack enable` unless the resolved manager is pnpm. |
| `package-manager` | string | no | `''` | `yarn`, `pnpm`, `npm`, or empty to auto-detect. |
| `build-command` | string | no | `''` | Workspace JS build command run at the repository root before the key is computed. |
| `build-env` | string | no | `''` | Newline-separated `KEY=VALUE` appended to `$GITHUB_ENV`. |

## Outputs

| Name | Description |
| ---- | ----------- |
| `native-targets` | JSON array of the targets whose native key has no published base, or that set `forceNative`, each carrying its `nativeKey`. `[]` means no expensive runner has to be claimed at all. |

## Secrets

| Secret                | Required | Description |
| --------------------- | -------- | ----------- |
| `build-secrets-env`   | no       | Masked `KEY=VALUE` entries (`KEY<<DELIMITER` for a multi-line value) exported after `build-env` in the plan job, before install, `build-command`, the fingerprint and the re-bundle. For what a real build needs but a log must never show: a remote turbo cache token, a Maps API key compiled into the base. Parsed by [`apply-secret-env`](../../actions/apply-secret-env/README.md). Only a SHA-256 digest of the entries enters the native key, never a value — so rotating a secret moves the key, and every caller of one native surface must pass the same secret. |

The base store authenticates with the job's own `GITHUB_TOKEN`. The plan
record and the repacked-app artifact carry no secret: the plan is the target,
its native key and `needsNative`, and the key carries only the digest. A value
the consumer's `app.config` itself embeds in the app is in the app, as it would
be in any build.

## Permissions

The **calling job** must grant these; a reusable workflow can only narrow the
token it is given, never widen it:

```yaml
permissions:
    contents: read
    packages: read    # ghcr backend: pull the base
    actions: read     # artifact backend: query the artifacts API
```

The caller's *native build* job needs `packages: write` on top, because that is
where a base is published. See [docs/repack.md](../repack.md#permissions).

## Examples

These show the interface the e2e, screenshot and warm-up workflows use. A
consumer calls one of those instead.

### Minimal

```yaml
jobs:
    plan:
        permissions:
            contents: read
            packages: read
            actions: read
        uses: rnw-community/mobile-ci/.github/workflows/expo-base-plan.yml@v4.4.1 # v4.4.1
        with:
            platform: android
            targets: >-
                [{"name":"app","appDir":"apps/mobile","appId":"com.example.app","prebuildCommand":"npx expo prebuild -p android"}]
            app-artifact-prefix: android-e2e-app
            plan-artifact-prefix: android-e2e-plan
```

### Full

```yaml
jobs:
    plan:
        permissions:
            contents: read
            packages: read
            actions: read
        uses: rnw-community/mobile-ci/.github/workflows/expo-base-plan.yml@v4.4.1 # v4.4.1
        with:
            platform: ios
            targets: >-
                [{"name":"app","appDir":"apps/mobile","workspace":"MyApp.xcworkspace","scheme":"MyApp","appId":"com.example.app","prebuildCommand":"npx expo prebuild -p ios"}]
            build-strategy: auto
            app-artifact-prefix: ios-e2e-app
            plan-artifact-prefix: ios-e2e-plan
            toolchain: xcode-26.4.1-17E202
            fingerprint-config: fingerprint.config.js
            install-command: pnpm install --frozen-lockfile
            repack-env: |
                API_URL=https://staging.example.com
            expect-config: |
                extra.apiUrl=https://staging.example.com
        secrets:
            build-secrets-env: ${{ secrets.BUILD_SECRETS_ENV }}
    build:
        needs: plan
        if: needs.plan.outputs.native-targets != '[]'
        runs-on: [self-hosted, macOS, ARM64]
        strategy:
            matrix:
                target: ${{ fromJSON(needs.plan.outputs.native-targets) }}
        steps:
            - env:
                  TARGET: ${{ matrix.target.name }}
                  NATIVE_KEY: ${{ matrix.target.nativeKey }}
              run: echo "compile $TARGET for native key $NATIVE_KEY"
```

## Why it is a workflow and not an action

The decision spans runners: it has to happen on a Linux pool before the caller
claims a Mac, and its per-target results have to be folded into one list a
matrix can consume. A composite action runs inside a job that has already
claimed its runner, which is exactly the cost this removes.
