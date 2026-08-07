# seed-native-cache.yml

`workflow_call` reusable workflow: proactively populates the native-app cache
so a later `ios-maestro.yml` / `android-maestro.yml` run hits a warm cache
instead of paying for a cold native build.

Two independent jobs, each only runs when its target list is non-empty:
**seed-ios** (one job per `ios-targets` entry — Xcode select, native
fingerprint, native-app-cache restore, ccache, `xcodebuild` on a cache miss)
and **seed-android** (one job per `android-targets` entry — native
fingerprint, native-app-cache restore, `gradlew assembleRelease` on a cache
miss). This is the build half of the two Maestro pipelines with no
detect/test jobs; it does not repack and does not run Maestro. Meant to be
called from a workflow that is itself `workflow_dispatch`-triggered (plus
optionally `push`/`schedule`) in the consuming repository.

## Inputs

| Name                          | Required | Default                                       | Description |
| -------------------------------- | -------- | ------------------------------------------------ | -------------- |
| `ios-runner-labels`               | no       | `["self-hosted","macOS","ARM64"]`                  | JSON array of self-hosted runner labels for `seed-ios`. |
| `android-runner-labels`           | no       | `["self-hosted","linux-tiered","linux-xl"]`        | JSON array of self-hosted runner labels for `seed-android`. |
| `ios-targets`                     | no       | `[]`                                               | JSON array of iOS build targets: `{name, appDir, workspace, scheme, prebuildCommand}`. `seed-ios` is skipped entirely when this is `[]`. |
| `android-targets`                 | no       | `[]`                                               | JSON array of Android build targets: `{name, appDir, prebuildCommand}`. `seed-android` is skipped entirely when this is `[]`. |
| `xcode-version`                   | no       | `26.4.1`                                           | Xcode version string, e.g. `26.4.1`. |
| `xcode-build`                     | no       | `17E202`                                           | Xcode build number, e.g. `17E202`. |
| `cmdline-tools-version`           | no       | `12266719`                                         | `android-actions/setup-android` cmdline-tools-version — pin explicitly, do not trust upstream defaults. |
| `ios-cache-profile`               | no       | `ios-native-v1`                                    | Cache-key prefix for the iOS native-app cache. |
| `android-cache-profile`           | no       | `android-native-v1`                                | Cache-key prefix for the Android native-app cache. |
| `expo-fingerprint-version`        | no       | `0.20.6`                                           | Pinned `@expo/fingerprint` npm version. |
| `node-version`                    | no       | `22.x`                                             | Node version for `actions/setup-node`. |
| `install-command`                 | no       | `yarn install --immutable`                         | JS dependency install command. |
| `enable-corepack`                 | no       | `true`                                             | Run `corepack enable` before install. |
| `build-command`                   | no       | `''`                                               | Optional workspace JS build command run at repo root before the native build. |
| `build-env`                       | no       | `''`                                               | Newline-separated `KEY=VALUE` pairs appended to `$GITHUB_ENV` at the start of each seed job. Rejects (fails closed) any line without `=` or whose name does not match `^[A-Za-z_][A-Za-z0-9_]*$`. |
| `rct-use-prebuilt-rncore`         | no       | `false`                                            | Sets `RCT_USE_PREBUILT_RNCORE=1` for the iOS build step when `true`. |
| `rct-use-rn-dep`                  | no       | `false`                                            | Sets `RCT_USE_RN_DEP=1` for the iOS build step when `true`. |
| `expo-use-precompiled-modules`    | no       | `false`                                            | Sets `EXPO_USE_PRECOMPILED_MODULES=1` for the iOS build step when `true`. |
| `ccache-max-size`                 | no       | `2G`                                               | Bounded, compressed ccache maximum size (iOS only). |
| `ios-timeout-minutes`             | no       | `90`                                               | `seed-ios` job timeout. |
| `android-timeout-minutes`         | no       | `60`                                               | `seed-android` job timeout. |

No `secrets:` block.

## Permissions

`contents: read` is sufficient in the caller workflow.

## Example

```yaml
# .github/workflows/seed-native-cache.yml
name: Seed native cache
on:
    workflow_dispatch:
    schedule:
        - cron: '0 4 * * *'
jobs:
    seed:
        uses: rnw-community/mobile-ci/.github/workflows/seed-native-cache.yml@main
        with:
            ios-targets: >-
                [{"name":"bare","appDir":"apps/mobile","workspace":"MyApp.xcworkspace","scheme":"MyApp","prebuildCommand":""}]
            android-targets: >-
                [{"name":"bare","appDir":"apps/mobile","prebuildCommand":""}]
```
