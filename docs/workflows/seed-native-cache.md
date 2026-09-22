# seed-native-cache.yml

`workflow_call` reusable workflow: **the warm-up.** It publishes the base
binary every pull request repacks, and warms the native-app cache on the host
that built it, so a later `ios-maestro.yml` / `android-maestro.yml` /
`store-screenshots.yml` run repacks a published base instead of compiling
native code. Read [docs/repack.md](../repack.md) first — this page is the input
reference.

Four jobs, in two stages.

**plan-ios / plan-android** run on the x86_64 Linux pool
(`plan-runner-labels`) and call [`expo-base-plan.yml`](expo-base-plan.md): one
leg per target installs dependencies, runs the target's `prebuildCommand`,
computes the native key with
[`expo-native-key`](../../actions/expo-native-key), and asks
[`expo-base-binary`](../../actions/expo-base-binary) whether a base is already
published for it. They never repack — a warm-up is looking for a key with *no*
base, not producing a binary. Their `native-targets` output names the targets
that still need building.

**seed-ios / seed-android** then run only for those targets — one job per
target, on the Mac pool and the Linux Gradle pool respectively — restore the
native-app cache, build on a miss, and publish what they produced as the base
binary for that target's key.

That ordering is the point: **a push that changes no native surface costs Linux
minutes and nothing else.** The plan jobs find every key already published and
no Mac or Gradle job starts at all.

Wire it on a **default-branch push** with a `paths:` filter, not only on a
schedule: a base is published only from the default branch, so the sooner after
a native change it runs, the fewer pull requests pay for a native build. A
`workflow_dispatch` trigger with `force-base` is the manual escape hatch for
the two things a fingerprint cannot see (see
[force-base](#when-to-use-force-base)).

## Inputs

| Name                          | Required | Default                                       | Description |
| -------------------------------- | -------- | ------------------------------------------------ | -------------- |
| `ios-runner-labels`               | no       | `["self-hosted","macOS","ARM64"]`                  | JSON array of self-hosted runner labels for `seed-ios`. |
| `plan-runner-labels`              | no       | `["self-hosted","trf-linux-amd64-4x8"]`             | JSON array of self-hosted runner labels for the two plan jobs, which compute each target's native key and ask whether a base binary is already published for it. The default is the x86_64 Linux pool, so a push that changes no native surface costs Linux minutes and claims no Mac. |
| `plan-timeout-minutes`            | no       | `30`                                               | Per-target timeout for the plan jobs. |
| `publish-base`                    | no       | `true`                                             | Publish the native app this run builds as the base binary pull requests repack. On by default: warming a host cache nobody else can reach is half the job. Publishing needs `packages: write` on the **calling** job for the `ghcr` backend, or `actions: read` for the `artifact` one. A run off the default branch builds but never publishes, and says so with a `::warning::`. |
| `force-base`                      | no       | `false`                                            | Rebuild and re-publish every target's base even when its native key already has one. It overwrites a base other builds are already repacking onto, so say why in the run. See [When to use force-base](#when-to-use-force-base). |
| `base-backend`                    | no       | `ghcr`                                             | `ghcr` (an immutable OCI artifact) or `artifact` (workflow artifacts). See [`expo-base-binary`](../../actions/expo-base-binary). |
| `base-flavor`                     | no       | `e2e`                                              | Flavor segment of the base binary's address. Must match what the e2e and screenshot workflows pass, or the warm-up publishes under an address no pull request looks up. |
| `fingerprint-config`              | no       | `fingerprint.config.js`                            | Path, relative to a target's `appDir`, of the `@expo/fingerprint` config whose ignore list is the correctness boundary of every repack. Its hash is part of the native key. See [docs/repack.md](../repack.md#the-fingerprintconfigjs-contract). |
| `fingerprint-env`                 | no       | `''`                                               | Newline-separated `KEY=VALUE` pairs exported while the native key is computed. **Must be byte-identical to what the e2e workflows pass**, or the warm-up publishes under a key no pull request ever looks up and every pull request keeps building natively. |
| `repack-app-version`              | no       | `0.7.2`                                            | Pinned `@expo/repack-app` npm version used by the plan jobs. |
| `android-build-tools-version`     | no       | `35.0.0`                                           | Android build-tools version the Android plan job installs. |
| `android-runner-labels`           | no       | `["self-hosted","trf-linux-amd64-4x8"]`             | JSON array of self-hosted runner labels for `seed-android`. The default is the x86_64 Linux pool (4 vCPU / 8 GiB): Gradle plus D8 need the 8 GiB profile, and Google ships an Android NDK/cmake for x86_64 Linux but none for `linux-aarch64`. |
| `ios-targets`                     | no       | `[]`                                               | JSON array of iOS build targets: `{name, appDir, workspace, scheme, prebuildCommand}`. `seed-ios` is skipped entirely when this is `[]`. |
| `android-targets`                 | no       | `[]`                                               | JSON array of Android build targets: `{name, appDir, prebuildCommand}`. `seed-android` is skipped entirely when this is `[]`. |
| `xcode-version`                   | no       | `26.4.1`                                           | Xcode version string, e.g. `26.4.1`. |
| `xcode-build`                     | no       | `17E202`                                           | Xcode build number, e.g. `17E202`. |
| `cmdline-tools-version`           | no       | `12266719`                                         | `android-actions/setup-android` cmdline-tools-version — pin explicitly, do not trust upstream defaults. |
| `gradle-task`                     | no       | `assembleRelease`                                  | `gradlew` task to build, e.g. `:app:assembleRelease` to scope to one module (see `build-android-app` README). |
| `gradle-args`                     | no       | `''`                                                | Extra whitespace-split arguments appended after `gradle-task`, e.g. `-x lint -x lintVitalAnalyzeRelease` (see `build-android-app` README). |
| `ios-cache-profile`               | no       | `ios-native-v1`                                    | Cache-key prefix for the iOS native-app cache. |
| `android-cache-profile`           | no       | `android-native-v1`                                | Cache-key prefix for the Android native-app cache. |
| `expo-fingerprint-version`        | no       | `0.20.6`                                           | Pinned `@expo/fingerprint` npm version. |
| `node-version`                    | no       | `22.x`                                             | Node version for `actions/setup-node`. |
| `install-command`                 | no       | `yarn install --immutable`                         | JS dependency install command. |
| `enable-corepack`                 | no       | `true`                                             | Run `corepack enable` before install. Skipped when the resolved package manager is `pnpm` (provisioned by `pnpm/action-setup`). |
| `package-manager`                 | no       | `''` (auto-detect)                                 | Override the JS package manager (`yarn`, `pnpm`, `npm`). Empty auto-detects at the repo root: `devEngines.packageManager` / `packageManager` in `package.json` (needs `jq` on the runner), else exactly one root lockfile (`yarn.lock` / `pnpm-lock.yaml` / `package-lock.json` or `npm-shrinkwrap.json`); no match, an ambiguous match or an unsupported value fails the job. Drives pnpm provisioning and, in the jobs that configure one, `actions/setup-node`'s `cache:` — set `install-command` to match (e.g. `pnpm install --frozen-lockfile`). Resolving to `pnpm` also requires a pnpm version in `package.json`. See [Package manager](../../README.md#package-manager). |
| `build-command`                   | no       | `''`                                               | Optional workspace JS build command run at repo root before the native build. |
| `build-env`                       | no       | `''`                                               | Newline-separated `KEY=VALUE` pairs appended to `$GITHUB_ENV` at the start of each seed job. Rejects (fails closed) any line without `=` or whose name does not match `^[A-Za-z_][A-Za-z0-9_]*$`. |
| `rct-use-prebuilt-rncore`         | no       | `false`                                            | Exports `RCT_USE_PREBUILT_RNCORE=1` for the iOS `expo prebuild` step, `pod install`, and the iOS build step when `true`; exports nothing at all otherwise (an empty export reads as *enabled* on the Ruby side). |
| `rct-use-rn-dep`                  | no       | `false`                                            | Exports `RCT_USE_RN_DEP=1` for the iOS `expo prebuild` step, `pod install`, and the iOS build step when `true`; exports nothing at all otherwise (an empty export reads as *enabled* on the Ruby side). |
| `expo-use-precompiled-modules`    | no       | `false`                                            | Exports `EXPO_USE_PRECOMPILED_MODULES=1` for the iOS `expo prebuild` step, `pod install`, and the iOS build step when `true`; exports nothing at all otherwise (an empty export reads as *enabled* on the Ruby side). |
| `ccache-max-size`                 | no       | `2G`                                               | Bounded, compressed ccache maximum size (iOS only). |
| `ios-timeout-minutes`             | no       | `90`                                               | `seed-ios` job timeout. |
| `android-timeout-minutes`         | no       | `60`                                               | `seed-android` job timeout. |

No `secrets:` block.

## Permissions

`contents: read` is no longer sufficient. A reusable workflow's job
`permissions:` block can only **narrow** the token its caller grants it, never
add a scope, so declaring `packages: write` inside this workflow does not grant
it — the **calling job** has to:

```yaml
permissions:
    contents: read
    packages: write   # publish the base binary (base-backend: ghcr, the default)
    actions: read     # read the artifacts API (base-backend: artifact)
```

In a repository whose default workflow token permission is **read** — the
recommended setting — a caller without this block gets a run that plans fine,
builds fine, and fails at publish. With `base-backend: artifact` no package
scope is needed, only `actions: read`.

## When to use `force-base`

The native key covers everything `@expo/fingerprint` can see plus the build
action, the pinned toolchain and the fingerprint config's hash. Two things it
cannot see, both of which need a forced re-warm:

- **A package the ignore list hides changed its native code.** Every path in
  `ignorePaths` is a promise that the package's native code does not change
  independently of something else in the fingerprint. When that promise breaks,
  pull requests repack onto a stale native shell until the base is rebuilt.
- **A value compiled into the native binary was rotated** — an API key in an
  `AndroidManifest` placeholder, say. It lives in the base, not in the
  JavaScript bundle, so the fingerprint never moves.

```yaml
on:
    workflow_dispatch:
        inputs:
            force-base:
                description: Rebuild and re-publish every base, even keys that already have one.
                type: boolean
                default: false
```

`force-base` skips the `native-app-cache` restore as well as the base lookup.
It has to: the native key is unchanged in both of the cases above, so a cache
hit would republish exactly the binary the force is meant to replace. The run
therefore always compiles, and warns before it overwrites — every build that
already repacked onto the previous base used different native code.

## Example

```yaml
# .github/workflows/warm-base.yml (in your app repo)
name: Warm the e2e base binaries
on:
    push:
        branches: [main]
        paths:
            - 'apps/mobile/**'
            - 'yarn.lock'
            - '.github/workflows/warm-base.yml'
    workflow_dispatch:
        inputs:
            force-base:
                type: boolean
                default: false

jobs:
    warm:
        # Required: a reusable workflow can only narrow what the caller grants.
        permissions:
            contents: read
            packages: write
            actions: read
        uses: rnw-community/mobile-ci/.github/workflows/seed-native-cache.yml@v3.0.0 # v3.0.0
        with:
            ios-targets: >-
                [{"name":"bare","appDir":"apps/mobile","workspace":"MyApp.xcworkspace","scheme":"MyApp","prebuildCommand":"npx expo prebuild -p ios"}]
            android-targets: >-
                [{"name":"bare","appDir":"apps/mobile","prebuildCommand":"npx expo prebuild -p android"}]
            force-base: ${{ inputs.force-base || false }}
```

The `paths:` filter is what keeps the warm-up honest: a push that touches
neither the app nor the lockfile cannot have moved a native key, so there is
nothing to warm.

## Migrating from v2

- **Add the `permissions:` block above** to the calling job. Without it the
  plan and build jobs still run, and the publish step fails — the one silent
  breakage of this release.
- **Set `fingerprint-env` and `base-flavor` to exactly what your e2e and
  screenshot callers pass.** They are two halves of one address; if they
  disagree the warm-up publishes bases nothing ever fetches, and the only
  symptom is that every pull request keeps taking a build slot.
- **Ship a `fingerprint.config.js`** next to the app's `package.json` and point
  `fingerprint-config` at it. Without one the key still works, but the step
  warns: the ignore list is the correctness boundary and nobody stated it. See
  [docs/repack.md](../repack.md#the-fingerprintconfigjs-contract).
- `publish-base` defaults to `true`. Set it to `false` only to keep the old
  cache-only behaviour, which leaves every pull request compiling natively.
