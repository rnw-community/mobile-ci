# assert-distinct-fingerprints.yml

Release-pipeline pre-flight: proves no two targets of one platform with
different `appId` share a native key, before any build starts. The same check
runs inside [`expo-base-plan.yml`](expo-base-plan.md); this workflow is for
pipelines that never call it (`native-publish.yml`, `native-dev-release.yml`
callers). Read [docs/repack.md](../repack.md#targets-that-differ-only-in-brand-assets-or-per-target-config)
for why a shared key is a defect and the `extraSources` fix.

## What it does

1. One `key` job per target: install, optional `build-command` and the target's
   `prebuildCommand`, then [`expo-native-key`](../../actions/expo-native-key) with
   the same inputs `expo-base-plan.yml` uses (the target's `workspace` and
   `scheme` are appended to `toolchain`). The key, fingerprint and config hash
   are uploaded.
2. An `assert` job gathers one record per target (a missing record fails) and
   runs [`assert-distinct-fingerprints`](../../actions/assert-distinct-fingerprints).

The comparison lives once, in `scripts/assert-distinct-native-keys.sh`. A
composite action cannot loop over a dynamic target list, hence the matrix
workflow around the action.

## Inputs

| Name | Type | Required | Default | Description |
| ---- | ---- | -------- | ------- | ----------- |
| `platform` | string | yes | - | `ios` or `android`. |
| `targets` | string | yes | - | JSON array of targets; each needs `name`, `appDir`, `appId`; may carry `prebuildCommand`, `workspace`, `scheme`. |
| `runner-labels` | string | no | `'["self-hosted","trf-linux-amd64-2x4"]'` | Runner labels for the key jobs (Linux; no Mac needed). |
| `control-runner-labels` | string | no | `'["ubuntu-latest"]'` | JSON array of runner labels for the `assert` job, which only compares downloaded plan records. Set it when the org has no hosted runners, e.g. an ephemeral RunsOn label set. |
| `runs-on-cache-bypass` | boolean | no | `false` | Opt-in. Runs the [`runs-on-cache-bypass`](../../actions/runs-on-cache-bypass/README.md) action as the first step of both jobs, so artifact upload/download works on a RunsOn runner started with `extras=s3-cache`. A logged no-op elsewhere. |
| `timeout-minutes` | number | no | `30` | Per-target timeout. |
| `toolchain` | string | no | `''` | Toolchain identity, as passed to the build. |
| `base-flavor` | string | no | `e2e` | Flavor segment of the key. |
| `fingerprint-config` | string | no | `fingerprint.config.js` | Fingerprint config, relative to `appDir`. |
| `fingerprint-env` | string | no | `''` | `KEY=VALUE` lines exported while the key is computed. |
| `expo-fingerprint-version` | string | no | `0.20.6` | Pinned `@expo/fingerprint`. |
| `node-version` | string | no | `22.x` | Node version. |
| `install-command` | string | no | `yarn install --immutable` | Dependency install. |
| `enable-corepack` | boolean | no | `true` | Run `corepack enable`. |
| `build-command` | string | no | `''` | Workspace build run before the key is computed. |

## Secrets and permissions

No secrets. The calling job needs `contents: read`.

## Examples

### Minimal

```yaml
jobs:
    distinct-keys:
        permissions:
            contents: read
        uses: rnw-community/mobile-ci/.github/workflows/assert-distinct-fingerprints.yml@v4.4.2 # v4.4.2
        with:
            platform: ios
            targets: >-
                [{"name":"brand-a","appDir":"apps/mobile","appId":"com.a"},{"name":"brand-b","appDir":"apps/mobile","appId":"com.b"}]
    publish:
        needs: distinct-keys
        permissions:
            contents: read
        uses: rnw-community/mobile-ci/.github/workflows/native-publish.yml@v4.4.2 # v4.4.2
        with:
            app-dir: apps/mobile
        secrets:
            EXPO_TOKEN: ${{ secrets.EXPO_TOKEN }}
            ASC_API_KEY: ${{ secrets.ASC_API_KEY }}
            ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
            ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
```

### Full

Both platforms, with the same key inputs the e2e workflows pass, before a
per-brand publish:

```yaml
jobs:
    distinct-keys:
        strategy:
            matrix:
                platform: [ios, android]
        permissions:
            contents: read
        uses: rnw-community/mobile-ci/.github/workflows/assert-distinct-fingerprints.yml@v4.4.2 # v4.4.2
        with:
            platform: ${{ matrix.platform }}
            targets: >-
                [{"name":"acme","appDir":"apps/mobile","appId":"com.acme.app","prebuildCommand":"APP_VARIANT=acme npx expo prebuild -p ${{ matrix.platform }}"},
                 {"name":"globex","appDir":"apps/mobile","appId":"com.globex.app","prebuildCommand":"APP_VARIANT=globex npx expo prebuild -p ${{ matrix.platform }}"}]
            fingerprint-config: fingerprint.config.js
            install-command: pnpm install --frozen-lockfile
            build-command: pnpm turbo build --filter=./apps/mobile...
            runner-labels: '["self-hosted","trf-linux-amd64-2x4"]'
    publish:
        needs: distinct-keys
        strategy:
            fail-fast: false
            matrix:
                brand: [acme, globex]
        permissions:
            contents: read
        uses: rnw-community/mobile-ci/.github/workflows/native-publish.yml@v4.4.2 # v4.4.2
        with:
            app-dir: apps/mobile
            enable-android: true
            build-profile: ${{ matrix.brand }}
            submit-profile: ${{ matrix.brand }}
            record-scope: ${{ matrix.brand }}
            credentials-source: eas
        secrets:
            EXPO_TOKEN: ${{ secrets.EXPO_TOKEN }}
```

Complete caller workflows for whole apps, linted and checked against this
workflow's inputs in CI, live in [docs/examples/](../examples/README.md).
