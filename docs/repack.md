# Repack: how a pull request stops compiling native code

A React Native or Expo pull request that changes only JavaScript still produced
a whole native binary: `pod install` and `xcodebuild` on a Mac, or Gradle on
Linux, for a native shell byte-identical to the one the previous run produced.
On a self-hosted fleet that is the most expensive thing CI does, and it is the
thing that makes every other job on the Mac pool wait.

From **v3.0.0** it does not happen by default. A pull request:

1. computes the **native key** for each target, on Linux, once;
2. fetches the **base binary** published under that key;
3. **repacks** it — re-bundles this commit's JavaScript with the repository's
   own Metro and Hermes, swaps the bundle and assets into the simulator `.app`
   or the APK, rewrites the embedded Expo config — and hands the result to the
   Maestro or capture job exactly as a native build would have;
4. reaches a native build **only** when that key has no published base, when
   the base is unusable, or when the consumer set the escape hatch.

The measured effect on the reference implementation this was taken from:

|                                        | before                                        | after                                     |
| -------------------------------------- | --------------------------------------------- | ----------------------------------------- |
| iOS e2e build, native surface unchanged | 15–17 min on the Mac + 40–110 min of queue     | 3m39s–4m12s on Linux, no Mac slot claimed |
| Android e2e build, native unchanged     | 8–16 min                                       | 3m49s–4m34s                               |
| a pull request that *does* change native code | unchanged                               | unchanged, plus one warm-up after merge   |

## The three pieces

| Action | What it decides |
| ------ | ---------------- |
| [`expo-native-key`](../actions/expo-native-key) | The one address a base binary is stored under. |
| [`expo-base-binary`](../actions/expo-base-binary) | Whether that address holds a base, and puts one there. |
| [`expo-repack`](../actions/expo-repack) | Whether the repacked binary is this commit's app, and refuses it when it cannot tell. |

[`expo-base-plan.yml`](workflows/expo-base-plan.md) is those three in order. The
e2e and screenshot workflows all call it rather than restating the rule, so a
label or a strategy means the same thing in every pipeline.

## The native key is the correctness boundary

```
key = <@expo/fingerprint hash> - <12 hex of (platform, flavor, toolchain, build-action hash, fingerprint-config hash)>
```

`toolchain` carries the target's own `workspace` and `scheme` as well, so two
targets that share an app directory and a fingerprint but build different
schemes never share a base. None of it reaches the published address as text —
it is hashed into the twelve hex characters — so a Gradle task with colons or
an argument list with spaces is fine.

`@expo/fingerprint` hashes the native surface: the app config, the dependency
set, autolinking, config plugins, and — unless the config ignores them — the
generated `ios/` and `android/` directories. Three things it cannot see are
folded in beside it:

- **the mobile-ci build action** that produced the base (`build-ios-app` plus
  `setup-xcode-pinned` on ios, `build-android-app` on android), so changing how
  a base is built invalidates every base built the old way;
- **the pinned toolchain and everything that changes what it produces** — the
  Xcode version and build with `rct-use-prebuilt-rncore`, `rct-use-rn-dep` and
  `expo-use-precompiled-modules` on ios, the cmdline-tools version with
  `gradle-task` and `gradle-args` on android — so neither a toolchain bump nor
  a flipped switch nor a changed Gradle task can leave a base reachable that
  was built the other way;
- **the hash of `fingerprint.config.js`**, so relaxing an ignore rule
  invalidates every base published while it was in force.

An empty fingerprint is never a key. The step fails rather than publishing or
fetching under one.

### What the key does *not* cover, and what to do about it

This is the part to read twice. A repack is only as correct as the
fingerprint's idea of "native surface".

**Packages the ignore list hides.** Every path in `ignorePaths` is a package
that can change native code without moving the key. That is deliberate — some
packages rewrite generated files on every install and would make the key move
on every run — but it means a real native change inside one of them lands on a
stale base. When you add a package to `ignorePaths`, you are promising that its
native code does not change independently of something else in the fingerprint.
When that promise breaks, run the warm-up with `force-base: true`.

**Secrets and values compiled into the binary.** A key baked into the native
build at compile time (`GOOGLE_MAPS_KEY` in an `AndroidManifest` placeholder,
say) lives in the base, not in the JavaScript bundle. Rotating it does not move
the fingerprint, so every pull request keeps repacking onto a base carrying the
old value. Rotate it and run the warm-up with `force-base: true` in the same
change.

**Env the key sees but the build does not.** `expo-native-key` exports
`extra-env` while it fingerprints. Anything the app's `app.config` branches on
must therefore appear in **both** the workflow's `fingerprint-env` and its
`build-env`; a variable set for one and not the other gives a key describing a
native surface no build produces. The key deliberately does not export
`flavor` for exactly this reason — the native build does not export it either,
so it is a segment of the address and nothing more.

**Per-build values are excluded on purpose.** Versions, build numbers and the
per-build `extra` section are `sourceSkips`, because including them would give
every pull request its own key and no pull request would ever find a base. They
are instead rewritten *into* the repacked binary and then asserted — see
[The assertion](#the-assertion) below.

### The `fingerprint.config.js` contract

Ship this file next to the app's `package.json` — `expo-native-key`'s
`fingerprint-config` input points at it, and its hash enters the key.

```js
/** @type {import('@expo/fingerprint').Config} */
module.exports = {
    // Native directories `expo prebuild` regenerates every run: hashing them
    // makes the key move for reasons that do not change the built binary.
    // Omit these two entries if the app is bare and commits ios/ and android/.
    ignorePaths: [
        'ios',
        'ios/**',
        'android',
        'android/**',
        '**/.DS_Store',
    ],
    // Values that differ per build and are rewritten by the repack, not
    // compiled in. Each one here is a value that MUST appear in the workflow's
    // expect-config, or it is rewritten with nothing checking it.
    sourceSkips: [
        'ExpoConfigVersions',
        'ExpoConfigRuntimeVersionIfString',
        'ExpoConfigExtraSection',
        'ExpoConfigNames',
    ],
    // Anything the fingerprint should track that it cannot find by itself.
    extraSources: [],
};
```

Every entry is a claim. `ignorePaths` claims "this path cannot change the native
binary in a way that matters"; `sourceSkips` claims "this value is rewritten and
asserted at repack time". Keep the file small enough that each claim can be
defended, and remember that changing it changes the key — which is exactly what
you want, and why the file's hash is in there.

## The base binary

`expo-base-binary` addresses a base as
`<platform>-<flavor>-<key>` and stores it one of two ways.

**`ghcr` (the default)** pushes it as an immutable OCI artifact at
`ghcr.io/<owner>/<repo>/e2e-base:<platform>-<flavor>-<key>` with `oras`. There
is no retention clock, no artifacts-API pagination, and one tag per key. The
publishing job needs `packages: write`; the fetching job needs `packages: read`.

**`artifact`** stores it as a workflow artifact named
`e2e-base-<platform>-<flavor>-<key>` and accepts a base only from a run whose
head branch is the default branch and whose head repository is this repository,
so a pull request can never repack onto a base another pull request built. It
needs `actions: read`. Workflow artifacts expire, so a key goes cold and costs a
native build again; use this backend only where publishing packages is not an
option.

A published base is **immutable**. `publish` refuses an address that already
holds one unless `force: true` is set, because a key already in use has to keep
meaning the same binary. `force` warns, loudly, that every build which already
repacked onto the previous base used different native code.

A fetch that finds nothing reports `found=false`, and that is the signal to
build natively. A fetch that *cannot tell* — an unauthorized registry, a failing
artifacts API — fails the job. An unreadable store is not an empty one.

`oras` is not assumed to be installed. An `oras` of exactly the pinned version
already on `PATH` is reused; otherwise the release asset for the runner's OS and
architecture is downloaded and checked against the pinned `oras-checksums`
before it runs. A runner whose OS/arch has no checksum entry fails with that
named rather than trusting an unverified binary.

## The repack

`@expo/repack-app --embed-bundle-assets` under `NODE_ENV=production`, with the
`repack-env` the consumer passes exported so its `app.config` writes this
build's API URL, version and build number.

Three refusals make it trustworthy:

- **A base with no embedded bundle** (`main.jsbundle` on ios,
  `assets/index.android.bundle` on android) is a Debug build that loads
  JavaScript from a dev server. Repacking it would produce a binary whose
  JavaScript nobody controls. Both `build-ios-app` and `build-android-app` build
  Release and already assert the embedded bundle, so this fires only on a base
  produced some other way.
- **A repacked binary with no embedded `app.config`** is a rewrite nobody can
  check.
- **Any `expect-config` assertion that does not hold.**

There is no fallback to the base's own JavaScript. A broken repack fails the
build.

### The assertion

`expect-config` is a list of `<dotted.path>=<value>` claims about the repacked
binary's embedded `app.config`, plus the bundle identifier or package name from
`app-id`:

```yaml
repack-env: |
    API_URL=https://staging.example.com
    APP_VERSION=1.4.0
    APP_BUILD_NUMBER=42
expect-config: |
    version=1.4.0
    extra.apiUrl=https://staging.example.com
    ios.buildNumber=42
```

The rule to hold onto: **every value `repack-env` is expected to rewrite belongs
in `expect-config`.** A config rewrite nobody checked is a repack nobody can
trust, and it is the one failure mode that produces a green pipeline testing the
wrong app.

On android the repacked APK is re-signed with the consumer's keystore — by
default the React Native debug keystore at `android/app/debug.keystore` that
Gradle signs its release build with. Sign the repack with anything else and the
emulator refuses to install it over the base. `apksigner verify` runs afterwards,
and the embedded bundle is checked one more time.

## The strategy

Every workflow that builds an Expo app takes `build-strategy`:

| Value | What it does |
| ----- | ------------- |
| **`auto`** (default) | Compute the key, fetch the base, repack it. No base ⇒ build natively, and publish the base when the ref is the default branch. |
| `repack` | Refuse to compile native code at all. No base ⇒ the build fails, naming the key. |
| `native` | Compile natively for every target, publish nothing. |

The pull-request label `mobile: force native build` (the `native-build-label`
input) forces `native` for one pull request. Set together with
`build-strategy: repack` it fails closed: a contradiction is not something a
workflow should resolve by picking a winner.

`native` is an escape hatch and **a regression**. It claims a build slot a
repack would not have needed, and a run that opted out of the strategy publishes
no base — it has no standing to decide what every other run repacks onto. If a
consumer finds itself setting `native` permanently, the fix is in the
fingerprint config or the warm-up, not in the strategy.

### What `auto` does on the very first run

Nothing is published yet, so:

1. the plan job computes the key and reports `found=false`;
2. the native build job runs, exactly as it did in v2;
3. if the ref is the **default branch**, that build's binary is published as the
   base for the key;
4. the next run on the same native surface — including every pull request —
   repacks it.

On a **pull request**, step 3 does not happen: a pull request never publishes a
base. So the first pull request against a cold key pays for a native build, and
so does the next one, until the default branch runs once. That is what the
warm-up is for.

## The warm-up

[`seed-native-cache.yml`](workflows/seed-native-cache.md) is the warm-up. Wire it
on a default-branch push with a `paths:` filter:

```yaml
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
        permissions:
            contents: read
            packages: write
            actions: read
        uses: rnw-community/mobile-ci/.github/workflows/seed-native-cache.yml@v3.0.1 # v3.0.1
        with:
            ios-targets: '[{"name":"bare","appDir":"apps/mobile","workspace":"MyApp.xcworkspace","scheme":"MyApp","prebuildCommand":"npx expo prebuild -p ios"}]'
            android-targets: '[{"name":"bare","appDir":"apps/mobile","prebuildCommand":"npx expo prebuild -p android"}]'
            force-base: ${{ inputs.force-base || false }}
```

It plans on Linux first: one job per target computes the key and asks whether a
base already exists for it. Only the targets with no base reach a Mac or a
Gradle build at all, so a push that changes no native surface costs Linux
minutes and nothing else.

`force-base: true` rebuilds and re-publishes every target's base. That is the
answer to the two things the key cannot see — an ignored package that changed
native code, and a rotated compiled-in secret. It overwrites a base other builds
are already repacking onto, so run it deliberately and say why.

## Permissions

A reusable workflow's job `permissions:` block can only **narrow** the token the
caller grants it. Declaring `packages: write` inside `ios-maestro.yml` does not
grant it — the consumer's calling job has to. In a repository whose default
workflow token permission is **read** (the recommended setting, and the one both
reference consumers use), a caller without this block gets a run that plans
fine, builds fine, and fails at publish:

```yaml
jobs:
    e2e:
        permissions:
            contents: read
            packages: write   # publish the base binary (ghcr backend)
            actions: read     # read artifacts (artifact backend, and the plan's own)
        uses: rnw-community/mobile-ci/.github/workflows/ios-maestro.yml@v3.0.1 # v3.0.1
        with: ...
```

`packages: write` is only needed where a base can be published — the e2e and
screenshot workflows (whose native build publishes on the default branch) and
the warm-up. A caller that never builds on the default branch can grant
`packages: read`.

## Why the Mac's compile cache is kept on the host

The reference implementation's remaining risk was that a native-change pull
request ran near-cold, because the hosted 10 GB repository cache had evicted the
iOS compile objects under normal churn. On this fleet the Mac keeps `ccache`,
`DerivedData` and Pods in a persistent local backend on the host rather than in
the repository cache (see [`xcode-cache`](../actions/xcode-cache) and
[self-hosted-runners.md](self-hosted-runners.md)), so the rare native build that
does happen starts warm. That is the reason the local backend exists, and the
reason this risk does not transfer.

## Migrating from v2

| v2 | v3 |
| -- | -- |
| `repack-on-hit: true` | Delete it. Repacking a published base is the default and strictly better: the old input repacked the same host's cache entry and silently fell back to a full build. |
| `repack-on-hit: false` | Remove the input; it no longer exists. `auto` is what you want. It is not v2's behaviour — v2 compiled unless the same host held a cache entry — and `build-strategy: native`, which compiles every run, is worse than both. |
| a `native-app-cache` hit standing in for a build | Gone from the e2e and screenshot workflows. A shell keyed on the native key carries whatever JavaScript it was built with, so it may seed a base but never a test artifact. `cache-profile` is removed with it; the warm-up keeps its cache. |
| `actions/repack-app` used directly | [`actions/expo-repack`](../actions/expo-repack), which adds the config assertion, the no-embedded-bundle refusal, and the signature check. |
| no `permissions:` on the calling job | Add the block above, or the first default-branch run fails at publish. |
| nothing | Add `fingerprint.config.js` and read [the contract](#the-fingerprintconfigjs-contract). Without it the key still works, but the step warns, because the ignore list is the boundary and nobody stated it. |
