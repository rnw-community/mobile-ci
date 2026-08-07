# ios-maestro.yml

`workflow_call` reusable workflow: iOS Maestro e2e on self-hosted runners.

Four jobs: **detect** (turbo-affected gate + shard-index computation, hosted
`ubuntu-latest`) →
**build** (one job per `targets` entry — Xcode select, native fingerprint,
native-app-cache restore, optional repack-on-hit, ccache, `xcodebuild`,
artifact upload) → **test** (one job per `targets` × `shard-count` — download
the built `.app`, boot a Simulator, run a Maestro flow shard) → **status**
(aggregates detect/build/test into a single required check). `build` and
`test` run on self-hosted macOS by default; `detect` and `status` always run
on `ubuntu-latest`.

## Inputs

| Name                       | Required | Default                                | Description |
| ---------------------------- | -------- | ----------------------------------------- | -------------- |
| `runner-labels`               | no       | `["self-hosted","macOS","ARM64"]`          | JSON array of self-hosted runner labels for the build/test jobs. |
| `build-runner-labels`         | no       | `''`                                       | JSON array of self-hosted runner labels for the build job only. Falls back to `runner-labels` when empty; set this and `test-runner-labels` together to split build/test across separate runner pools. |
| `test-runner-labels`          | no       | `''`                                       | JSON array of self-hosted runner labels for the test job only. Falls back to `runner-labels` when empty. |
| `targets`                     | **yes**  | —                                          | JSON array of build targets: `{name, appDir, workspace, scheme, appId, prebuildCommand}`. `prebuildCommand` may be an empty string. |
| `flows-dir`                   | **yes**  | —                                          | Directory (relative to repo root) whose top-level files are the runnable Maestro flows by default. Subdirectories are not searched unless `flows-max-depth` is raised. |
| `flows-max-depth`             | no       | `1`                                        | `find -maxdepth` under `flows-dir`. `0` means unbounded recursion. Default keeps subflows (invoked via `runFlow`, conventionally in subdirectories) out of the shard. |
| `flows-name-pattern`          | no       | `*.flow.yaml`                              | Space-separated `find -name` globs (OR'd together) selecting runnable flows directly inside `flows-dir`. Keeps reusable subflows and capture-only flows in subdirectories out of the shard by default. |
| `flows-exclude-pattern`       | no       | `''`                                       | Optional `find ! -name` glob excluding matched flows by basename. |
| `shard-manifest-dir`          | no       | `''`                                       | Optional directory (relative to repo root) of hand-curated `shard-<index>.txt` files (one `flows-dir`-relative flow path per line) overriding the computed index-modulo split. Unset falls back to modulo entirely; once set, every shard-index this job can run must have its own file — a partial manifest fails closed. |
| `pre-run-flow`                | no       | `''`                                       | Path to a single priming flow run once before each shard's flows, excluded from sharding. Its failure fails that shard immediately. |
| `flow-retries`                | no       | `0`                                        | Non-negative retry budget per flow; each flow gets up to `1 + flow-retries` attempts. |
| `shard-count`                 | no       | `2`                                        | Number of test shards per target. |
| `xcode-version`               | no       | `26.4.1`                                   | Xcode version string, e.g. `26.4.1`. |
| `xcode-build`                 | no       | `17E202`                                   | Xcode build number, e.g. `17E202`. |
| `cache-profile`                | no       | `ios-native-v1`                            | Cache-key prefix distinguishing this consumer/app. |
| `turbo-version`               | no       | `2.10.8`                                   | Pinned turbo npm version used by the detect job. |
| `target-packages`             | no       | `''`                                       | Newline-separated package names gating this pipeline on `pull_request` events. |
| `expo-fingerprint-version`    | no       | `0.20.6`                                   | Pinned `@expo/fingerprint` npm version. |
| `maestro-version`             | no       | `2.8.0`                                    | Pinned Maestro CLI version. |
| `node-version`                | no       | `22.x`                                     | Node version for `actions/setup-node`. |
| `install-command`             | no       | `yarn install --immutable`                 | JS dependency install command. |
| `enable-corepack`             | no       | `true`                                     | Run `corepack enable` before install. |
| `build-command`               | no       | `''`                                       | Optional workspace JS build command run at repo root before the native build. |
| `rct-use-prebuilt-rncore`     | no       | `false`                                    | Sets `RCT_USE_PREBUILT_RNCORE=1` for the build step when `true`. |
| `rct-use-rn-dep`              | no       | `false`                                    | Sets `RCT_USE_RN_DEP=1` for the build step when `true`. |
| `expo-use-precompiled-modules` | no     | `false`                                    | Sets `EXPO_USE_PRECOMPILED_MODULES=1` for the build step when `true`. |
| `ccache-max-size`             | no       | `2G`                                       | Bounded, compressed ccache maximum size. |
| `build-env`                   | no       | `''`                                       | Newline-separated `KEY=VALUE` pairs appended to `$GITHUB_ENV` at the start of the build job. Rejects (fails closed) any line without `=` or whose name does not match `^[A-Za-z_][A-Za-z0-9_]*$`. |
| `repack-on-hit`               | no       | `false`                                    | On a native-app-cache hit, run `repack-app` to inject a freshly exported JS bundle into the cached shell instead of reusing it unchanged. Falls back to a full native build if the repack fails. |
| `repack-app-version`          | no       | `0.7.2`                                    | Pinned `@expo/repack-app` npm version, used only when `repack-on-hit` is true. |
| `build-timeout-minutes`       | no       | `60`                                       | Build job timeout. |
| `test-timeout-minutes`        | no       | `45`                                       | Test job timeout. |

No `secrets:` block — this workflow never touches a signing credential or an
Expo/EAS token.

## Permissions

`contents: read` is sufficient in the caller workflow; this workflow does not
write to the repository.

## Example

```yaml
# .github/workflows/ios-maestro.yml
name: iOS Maestro E2E
on:
    workflow_dispatch:
    pull_request:
    push:
        branches: [main]
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
                [{"name":"bare","appDir":"apps/mobile","workspace":"MyApp.xcworkspace","scheme":"MyApp","appId":"com.example.app","prebuildCommand":""}]
            flows-dir: apps/mobile/e2e/flows
            target-packages: |
                @myorg/mobile-app
            build-command: yarn build --filter=@myorg/mobile-app
```
