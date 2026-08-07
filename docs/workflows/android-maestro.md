# android-maestro.yml

`workflow_call` reusable workflow: Android Maestro e2e on self-hosted
runners, defaulting to the Redroid driver.

Four jobs: **detect** (turbo-affected gate + shard-index computation, hosted
`ubuntu-latest`) → **build** (one job per `targets` entry — native
fingerprint, native-app-cache restore, optional repack-on-hit, `gradlew
assembleRelease`, artifact upload) → **test** (one job per `targets` ×
`shard-count` — download the built `.apk`, boot Redroid or an AVD emulator
per `android-driver`, run a Maestro flow shard) → **status** (aggregates
detect/build/test into a single required check). `build` and `test` default
to a self-hosted `linux-tiered`/`linux-xl` pool; `detect` and `status` always
run on `ubuntu-latest`.

## Inputs

| Name                        | Required | Default                                       | Description |
| ------------------------------ | -------- | ------------------------------------------------ | -------------- |
| `runner-labels`                 | no       | `["self-hosted","linux-tiered","linux-xl"]`        | JSON array of self-hosted runner labels for the build/test jobs. |
| `build-runner-labels`           | no       | `''`                                               | JSON array of self-hosted runner labels for the build job only. Falls back to `runner-labels` when empty; set this and `test-runner-labels` together to split build/test across separate runner pools. |
| `test-runner-labels`            | no       | `''`                                               | JSON array of self-hosted runner labels for the test job only. Falls back to `runner-labels` when empty. |
| `targets`                       | **yes**  | —                                                  | JSON array of build targets: `{name, appDir, appId, prebuildCommand}`. `prebuildCommand` may be an empty string. |
| `flows-dir`                     | **yes**  | —                                                  | Directory (relative to repo root) whose top-level files are the runnable Maestro flows by default. Subdirectories are not searched unless `flows-max-depth` is raised. |
| `flows-max-depth`               | no       | `1`                                                 | `find -maxdepth` under `flows-dir`. `0` means unbounded recursion. Default keeps subflows (invoked via `runFlow`, conventionally in subdirectories) out of the shard. |
| `flows-name-pattern`            | no       | `*.flow.yaml`                                      | Space-separated `find -name` globs (OR'd together) selecting runnable flows directly inside `flows-dir`. Keeps reusable subflows and capture-only flows in subdirectories out of the shard by default. |
| `flows-exclude-pattern`         | no       | `''`                                                | Optional `find ! -name` glob excluding matched flows by basename. |
| `shard-manifest-dir`            | no       | `''`                                                | Optional directory (relative to repo root) of hand-curated `shard-<index>.txt` files (one `flows-dir`-relative flow path per line) overriding the computed index-modulo split. Unset falls back to modulo entirely; once set, every shard-index this job can run must have its own file — a partial manifest fails closed. |
| `pre-run-flow`                  | no       | `''`                                               | Path to a single priming flow run once before each shard's flows, excluded from sharding. Its failure fails that shard immediately. |
| `flow-retries`                  | no       | `0`                                                | Non-negative retry budget per flow; each flow gets up to `1 + flow-retries` attempts. |
| `shard-count`                   | no       | `2`                                                | Number of test shards per target. |
| `cmdline-tools-version`         | no       | `12266719`                                         | `android-actions/setup-android` cmdline-tools-version — pin explicitly, do not trust upstream defaults (see `build-android-app` README). |
| `cache-profile`                  | no       | `android-native-v1`                                | Cache-key prefix distinguishing this consumer/app. |
| `turbo-version`                 | no       | `2.10.8`                                           | Pinned turbo npm version used by the detect job. |
| `target-packages`               | no       | `''`                                               | Newline-separated package names gating this pipeline on `pull_request` events. |
| `expo-fingerprint-version`      | no       | `0.20.6`                                           | Pinned `@expo/fingerprint` npm version. |
| `maestro-version`               | no       | `2.8.0`                                            | Pinned Maestro CLI version. |
| `android-driver`                | no       | `redroid`                                          | `redroid` (default) or `avd`. Google publishes no `linux-aarch64` build of the Android emulator/NDK/cmake, so `avd` cannot boot on this workflow's default self-hosted `runner-labels`; `redroid` runs Android as a privileged container over `binder_linux` instead and needs none of those packages. Pick `avd` only when overriding `runner-labels` to a host with a working emulator (e.g. GitHub-hosted x86_64 runners, which carry KVM out of the box). |
| `emulator-api-level`            | no       | `34`                                               | Android emulator API level (`avd` driver only). |
| `emulator-target`               | no       | `google_apis`                                      | Android emulator system image target (`avd` driver only). |
| `emulator-arch`                 | no       | `x86_64`                                           | Android emulator system image architecture (`avd` driver only) — also used as the native-app-cache `arch` key segment for both drivers. |
| `emulator-profile`              | no       | `pixel_6`                                          | Android emulator hardware profile (`avd` driver only). |
| `redroid-image`                 | no       | `redroid/redroid:15.0.0_64only-latest`             | Redroid image tag, used on a `redroid-prewarm-manifest-path` miss. Verified against a `6.17` host kernel — older `13.x` tags are known to never finish boot on that kernel, and `14.x` images hard-lock the guest kernel version. |
| `redroid-memory`                | no       | `3g`                                               | Container memory limit (`docker --memory` / `--memory-swap`). |
| `redroid-cpus`                  | no       | `2`                                                 | Container CPU limit (`docker --cpus`). |
| `redroid-prewarm-manifest-path` | no       | `$HOME/.rnw-ci/android-emulator.json`              | Path to a host-side Redroid prewarm manifest (`{"image","dataDir"}`); see [self-hosted-runners.md](../self-hosted-runners.md). |
| `redroid-boot-timeout-seconds`  | no       | `600`                                              | Seconds to wait for `sys.boot_completed` before failing the shard. |
| `node-version`                  | no       | `22.x`                                             | Node version for `actions/setup-node`. |
| `install-command`               | no       | `yarn install --immutable`                         | JS dependency install command. |
| `enable-corepack`               | no       | `true`                                             | Run `corepack enable` before install. |
| `build-command`                 | no       | `''`                                               | Optional workspace JS build command run at repo root before the native build. |
| `build-env`                     | no       | `''`                                               | Newline-separated `KEY=VALUE` pairs appended to `$GITHUB_ENV` at the start of the build job. Rejects (fails closed) any line without `=` or whose name does not match `^[A-Za-z_][A-Za-z0-9_]*$`. |
| `repack-on-hit`                 | no       | `false`                                            | On a native-app-cache hit, run `repack-app` to inject a freshly exported JS bundle into the cached shell instead of reusing it unchanged. Falls back to a full native build if the repack fails. |
| `repack-app-version`            | no       | `0.7.2`                                            | Pinned `@expo/repack-app` npm version, used only when `repack-on-hit` is true. |
| `android-build-tools-dir`       | no       | `''`                                               | Path to the Android SDK build-tools directory, used by `repack-app` (its `--android-build-tools-dir` and `aapt2` validation) when `repack-on-hit` is true. Leave empty to rely on an `aapt2` already on `PATH` (see `android-build-tools-version`, which populates `PATH` via `setup-android` on a cache hit when `repack-on-hit` is true). |
| `android-build-tools-version`   | no       | `35.0.0`                                           | Android build-tools version installed via `android-actions/setup-android` on a native-app-cache hit, used only when `repack-on-hit` is true. `build-android-app`'s own Gradle build (cache-miss path) installs whatever build-tools its `compileSdkVersion` resolves to, but that path never runs on a cache hit, so `repack-app`'s `aapt2` validation needs build-tools requested explicitly instead. |
| `build-timeout-minutes`         | no       | `60`                                               | Build job timeout. |
| `test-timeout-minutes`          | no       | `60`                                               | Test job timeout. |

No `secrets:` block — this workflow never touches a signing credential or an
Expo/EAS token.

## Permissions

`contents: read` is sufficient in the caller workflow; this workflow does not
write to the repository.

## Example

```yaml
# .github/workflows/android-maestro.yml
name: Android Maestro E2E
on:
    workflow_dispatch:
    pull_request:
    push:
        branches: [main]
concurrency:
    group: android-maestro-${{ github.ref }}
    cancel-in-progress: true
jobs:
    e2e:
        uses: rnw-community/mobile-ci/.github/workflows/android-maestro.yml@main
        with:
            targets: >-
                [{"name":"bare","appDir":"apps/mobile","appId":"com.example.app","prebuildCommand":""}]
            flows-dir: apps/mobile/e2e/flows
            target-packages: |
                @myorg/mobile-app
```
