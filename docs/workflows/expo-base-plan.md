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
   published for it — unless `build-strategy` is `native`, which skips the
   lookup;
4. when a base is found and `repack` is true,
   [`expo-repack`](../../actions/expo-repack) repacks it and uploads it as
   `<app-artifact-prefix>-<target name>` — the artifact the caller's test or
   capture job already downloads;
5. records the target's decision as `<plan-artifact-prefix>-<target name>`.

A collecting job then folds every target's decision into the `native-targets`
output. One plan per target is required: a plan that never arrived is not an
empty set of native builds, it is a target whose strategy nobody decided, and
the job fails.

Under `build-strategy: repack` a target with no base fails the job, naming the
key and the address that is empty.

## Inputs

| Name | Type | Required | Default | Description |
| ---- | ---- | -------- | ------- | ----------- |
| `platform` | string | yes | — | `ios` or `android`. |
| `targets` | string | yes | — | JSON array of build targets. Each element is passed through to the caller's native build job unchanged, with `nativeKey` added. |
| `build-strategy` | string | no | `auto` | `auto`, `repack` or `native`. Resolved by the caller, never here. |
| `repack` | boolean | no | `true` | Repack the base when one is found. The warm-up sets it false: it is looking for a key with no base, not producing this commit's binary. |
| `runner-labels` | string | no | `'["self-hosted","trf-linux-amd64-4x8"]'` | JSON array of runner labels for the plan jobs. |
| `timeout-minutes` | number | no | `30` | Per-target timeout. |
| `app-artifact-prefix` | string | yes | — | Artifact-name prefix the caller's test/capture job downloads the app under. |
| `plan-artifact-prefix` | string | yes | — | Artifact-name prefix for the per-target plan files. |
| `toolchain` | string | no | `''` | Pinned toolchain identity folded into the key — `xcode-<version>-<build>` on ios, `cmdline-<version>` on android. |
| `base-backend` | string | no | `ghcr` | `ghcr` or `artifact`. |
| `base-flavor` | string | no | `e2e` | Flavor segment of the base's address. |
| `fingerprint-config` | string | no | `fingerprint.config.js` | Path, relative to a target's `appDir`, of the fingerprint config whose hash enters the key. |
| `fingerprint-env` | string | no | `''` | Newline-separated `KEY=VALUE` exported while the key is computed. |
| `expo-fingerprint-version` | string | no | `0.20.6` | Pinned `@expo/fingerprint` npm version. |
| `repack-env` | string | no | `''` | Newline-separated `KEY=VALUE` exported for the re-bundle. |
| `expect-config` | string | no | `''` | Newline-separated `<dotted.path>=<value>` assertions on the repacked binary's embedded `app.config`. |
| `repack-app-version` | string | no | `0.7.2` | Pinned `@expo/repack-app` npm version. |
| `cmdline-tools-version` | string | no | `12266719` | Android cmdline-tools version. Ignored on ios. |
| `android-build-tools-dir` | string | no | `''` | Build-tools directory holding `zipalign`/`apksigner`. Empty falls back to `PATH`. |
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
| `native-targets` | JSON array of the targets whose native key has no published base, each carrying its `nativeKey`. `[]` means no expensive runner has to be claimed at all. |

## Secrets

None. The base store authenticates with the job's own `GITHUB_TOKEN`.

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

## Why it is a workflow and not an action

The decision spans runners: it has to happen on a Linux pool before the caller
claims a Mac, and its per-target results have to be folded into one list a
matrix can consume. A composite action runs inside a job that has already
claimed its runner, which is exactly the cost this removes.
