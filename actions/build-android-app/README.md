# build-android-app

Sets up the Android SDK via `android-actions/setup-android`, builds a Release
APK with `./gradlew --no-daemon <gradle-task>` (default task
`assembleRelease`), verifies the embedded `assets/index.android.bundle`, and
packages the single signed release APK as `<output-dir>/app-release.apk`.
Restores/saves a Gradle cache (`~/.gradle/caches`, `~/.gradle/wrapper`)
around the build, and an [Android SDK cache](#android-sdk-cache) in front of
`setup-android`. `android-abis` limits the build to the ABIs a test device
runs.

## Android SDK cache

Before this, `setup-android` ran uncached: the cmdline-tools, platform-tools,
and every SDK package Gradle installs on demand (build-tools, platforms, NDK,
CMake — the NDK alone is over a gigabyte) were downloaded on every run, and a
`dl.google.com` outage failed the build.

The action resolves the SDK root `setup-android` would use
(`$ANDROID_SDK_ROOT`, else `~/.android/sdk`) and restores its
`cmdline-tools`, `platform-tools`, `build-tools`, `platforms`, `ndk`, `cmake`
and `licenses` directories under the key

```
android-sdk-v1-<runner.os>-<runner.arch>-cmdline-<cmdline-tools-version>-<16 hex>
```

where the hex digest covers the package list this action asks `sdkmanager`
for, plus a hash of every file that pins what Gradle installs on top:
`android/build.gradle`, `android/settings.gradle`,
`android/gradle.properties`, `android/gradle/libs.versions.toml` and
`android/app/build.gradle` (or their `.kts` forms) under `app-dir`, and
`react-native/gradle/libs.versions.toml` and
`expo-modules-autolinking/package.json` from the nearest `node_modules` (React
Native's and Expo's default `compileSdk`, `buildTools` and `ndkVersion`). A
version bump in any of them is a new key, so a cache never silently lacks the
NDK the build asks for. There are no restore-keys: a partial match would carry
every retired NDK forward forever.

- **Hit**: the restored SDK is exported as `ANDROID_HOME`/`ANDROID_SDK_ROOT`
  and put on `PATH`; `setup-android` and `sdkmanager` do not run, and nothing
  is downloaded. A restored tree with no `sdkmanager` or `adb` falls back to
  `setup-android` with a warning.
- **Miss**: `setup-android` installs into that same root, Gradle adds what it
  needs, and after a **successful** build the SDK is saved — never on a
  `pull_request` run (a pull request's cache is scoped to its own ref, so
  nobody else could restore it), and with `continue-on-error`, so a failed
  upload never fails the build.

A composite action step cannot carry `timeout-minutes`, so a stalled upload
inside this action would hold the job until its own timeout. The reusable
workflows therefore pass `android-sdk-cache-save: 'false'` and save the
`android-sdk-cache-paths` under `android-sdk-cache-key` themselves, as the
job's last step with `timeout-minutes: 10` and `continue-on-error: true`. Do
the same in a workflow of your own:

```yaml
- name: Save the Android SDK
  if: github.event_name != 'pull_request' && steps.build.outputs.android-sdk-cache-hit != 'true'
  continue-on-error: true
  timeout-minutes: 10
  uses: actions/cache/save@0057852bfaa89a56745cba8c7296529d2fc39830 # v4.3.0
  with:
      path: ${{ steps.build.outputs.android-sdk-cache-paths }}
      key: ${{ steps.build.outputs.android-sdk-cache-key }}
```

## Native compile parallelism

The Android Gradle plugin runs the SDK's `ninja` directly, so
`CMAKE_BUILD_PARALLEL_LEVEL` never reaches it, and `ninja` sizes itself from
the CPUs the process may be scheduled on, not from the container's cgroup
quota. On a 4-CPU / 8 GiB runner container on a 24-thread host that is 26
compilers per CMake project, with several projects building at once; the
build only finished while the container could page into host swap, and is
OOM-killed without it.

The action therefore bounds the compilers running at once across the whole
build. `native-compile-jobs` empty derives the bound from the cgroup: one job
per CPU of quota (`cpu.max`, or the cgroup v1 CFS quota, rounded up) and one
job per `native-compile-memory-per-job` (default 3.5 GiB) of memory limit
(`memory.max`, or `memory.limit_in_bytes`) above a 5 GiB reserve for the
Gradle daemon, the capped Kotlin daemon and eas-cli, whichever is lower, at
least 1. That is 1 job on a
4-CPU / 8 GiB runner, 3 on 16 GiB, and the CPU count once memory is plentiful.
The per-job budget is sized for the heaviest translation unit, not the
average: a single React Native Skia translation unit peaks near 3.5 GiB, and a
cold build compiles several of them back to back, so a second slot on 8 GiB
lets two of them meet and the kernel kill the build. Lower it for a build
without such units; `native-compile-jobs` sets the count outright. An
unparseable limit or input fails the step; a runner with no limit is left to
`ninja`.

The bound is enforced by a compiler launcher, written to
`$RUNNER_TEMP/mobile-ci-compile-slots/compile-slot.sh`, that runs each
compiler while holding one of N `flock` slots. The step exports
`CMAKE_C_COMPILER_LAUNCHER` / `CMAKE_CXX_COMPILER_LAUNCHER` (read by CMake 3.17
and later on a project's first configure), `MOBILE_CI_COMPILE_SLOTS` and
`MOBILE_CI_COMPILE_SLOTS_DIR` through `$GITHUB_ENV`, so the bound also covers
any later CMake build in the same job. A launcher the caller already exports,
such as `ccache`, is kept behind the slot. The bound only schedules compilers,
so it never changes what is built or the native key.

The same step keeps the JVMs small beside the compilers:

- It appends `-Dkotlin.daemon.jvm.options=-Xmx1536m` to `GRADLE_OPTS`, so
  each Kotlin compile daemon gets a 1536 MiB heap instead of inheriting the
  Gradle daemon's (the template's `-Xmx2048m`) and holding it through the
  native phase: the Kotlin daemon runs the parallel collector, which keeps the
  heap it grew to. Kotlin still compiles in its own daemon, so the compiler's
  classes never load into the Gradle daemon's metaspace and the template's
  `-XX:MaxMetaspaceSize=512m` is enough. The system property is the lowest
  precedence of the Kotlin Gradle plugin's daemon JVM options, below
  `kotlin.daemon.jvmargs` in `gradle.properties`, a `-Dkotlin.daemon.jvm.options`
  in `org.gradle.jvmargs`, the `kotlin { kotlinDaemonJvmArgs }` extension and a
  task's own arguments, so a project that sizes its Kotlin daemon keeps its
  size, and a project's `kotlin.compiler.execution.strategy` is left alone. A
  `GRADLE_OPTS` that already sets `kotlin.daemon.jvm.options` or
  `kotlin.daemon.jvmargs` is kept as is.
- It appends `-XX:G1PeriodicGCInterval=10000 -XX:MinHeapFreeRatio=10
  -XX:MaxHeapFreeRatio=30` to `JAVA_TOOL_OPTIONS`, keeping whatever the runner
  already sets there, so an idle JVM runs a periodic GC and returns its free
  heap to the kernel; on the runner image a JVM idling at 300 MB live drops
  from 1917 MiB to 572 MiB resident.

Together they make an app-level workaround (a serial CMake job pool, an
in-process Kotlin `gradle.properties` entry, a raised `MaxMetaspaceSize`)
unnecessary. v4.3.0 compiled Kotlin in-process instead; that exhausted the
template's 512 MiB Gradle metaspace on Expo apps, so v4.3.1 returned to the
capped daemon, and a `build-env` `GRADLE_OPTS` that set
`kotlin.compiler.execution.strategy=daemon` to opt out can be dropped.
`native-publish.yml` and `native-dev-release.yml` run the same step before
`eas build --local` for Android.

## ABIs

A stock React Native project compiles its C++ for `armeabi-v7a`, `arm64-v8a`,
`x86` and `x86_64`. A build for an emulator or a Redroid container needs one
of them. `android-abis` passes `-PreactNativeArchitectures=<value>` to Gradle;
it fails the step before Gradle runs when the value is not a comma-separated
list of those four names, or when `gradle-args` (`-PreactNativeArchitectures=`)
or the environment (`ORG_GRADLE_PROJECT_reactNativeArchitectures`) pins a
different value. A matching pin is not repeated. `android-maestro.yml` and
`seed-native-cache.yml` resolve the value from the driver and fold it into the
native key; see [docs/repack.md](../../docs/repack.md#the-native-key-is-the-correctness-boundary).

**Why the Gradle cache is saved after a failed or timed-out build.** A cold
build that hits the job's `timeout-minutes` used to save nothing, so the next
run restored the same stale fallback, did the same downloads, and timed out
again — the cache never warmed. Now the save step runs `if: always()`:

| Build outcome           | Restore was an exact hit | Saved as                                   |
| ----------------------- | ------------------------ | ------------------------------------------ |
| success                 | no                       | `<gradle-cache-key>`                       |
| success                 | yes                      | nothing (already warm)                     |
| failure / cancelled     | no                       | `<gradle-cache-key>-partial-<run id>-<attempt>` |
| failure / cancelled     | yes                      | nothing                                    |

On `pull_request` events nothing is saved, whatever the outcome: a pull-request
save is scoped to that ref, so no other run can restore it, and the multi-gigabyte
upload can take most of the job's timeout. Pull requests restore what
default-branch builds and the warm-up saved.
| never ran               | —                        | nothing                                    |

The restore tries `<gradle-cache-key>` exactly, then the newest
`<gradle-cache-key>-partial-` entry, then `gradle-cache-restore-keys`. Each
partial is run-unique because cache entries are immutable, so successive
timed-out attempts keep building on each other's progress until one finishes
and writes the exact key. Partials are ordinary cache entries and age out
under GitHub's per-repository cache eviction.

`gradle/actions/setup-gradle` is not used here: it would replace the
caller-supplied `gradle-cache-key` contract, and its default makes every
non-default-branch run read-only, while a pull request whose native key has no
published base is exactly the run that has to compile. Gradle's build cache
and configuration cache are left off: the configuration cache is not
supported by every React Native / Expo Gradle plugin, and the build cache
would grow the saved entry with task outputs. Pass `--build-cache` in
`gradle-args` to opt in.

**Why `--no-daemon` is unconditional.** A Gradle daemon that outlives the
step gains a CI job nothing — there is no second invocation in the same job
to amortize warm-up against — but a daemon that crashes mid-build can be
orphaned holding the log pipe open, hanging the step silently until
`build-timeout-minutes` cancels the whole job. `--no-daemon` runs Gradle
in-process so a crash surfaces immediately as a failed step instead.

**Why `gradle-task` defaults to unscoped `assembleRelease`, and when to
change it.** The unscoped task also builds and lint-checks every module
transitively. On some dependency trees that has been observed to blow
through the JVM's Metaspace (`OutOfMemoryError: Metaspace` from
`expo-updates`' ksp step and `expo-modules-core`'s
`lintVitalAnalyzeRelease`). Pass a module-scoped task, e.g.
`:app:assembleRelease`, to build only the app module — the APK still lands
under `app/build/outputs/apk/release`, same as the unscoped task — and use
`gradle-args` (e.g. `-x lint -x lintVitalAnalyzeRelease`) to skip lint tasks
that trip the same OOM independently of scoping.

**Why `cmdline-tools-version` defaults to `12266719`.** This is the version
the `android-actions/setup-android@v3` release this action used to pin
defaulted to — **not** whatever the upstream action currently defaults to
(`v4` defaults to `15859902`, cmdline-tools 22.0). This action always passes
the input explicitly, so moving to `setup-android@v4` (which only changed the
Node runtime, the default, and the macOS arm64 download for 22.0+) did not
change the cmdline-tools a build gets. The two have drifted before and collided with the cmdline-tools version
pre-licensed on some runner SDK images, producing license-acceptance failures
that only reproduce on cold runners. Pin the input explicitly per consumer if
your fleet's runner image bakes a different cmdline-tools version; do not rely
on the upstream action's own default.

**Why `packages: platform-tools` is passed explicitly.** Left unset,
`android-actions/setup-android` defaults to `tools platform-tools`, and the
legacy `tools` SDK package has been removed from Google's repository —
`sdkmanager` exits 1 trying to install it, failing every build. Gradle/AGP
fetch the `build-tools`/`platforms` packages they need themselves once
`ANDROID_HOME` and `sdkmanager` exist, so only `platform-tools` has to be
preinstalled here.

## Inputs

| Name                          | Required | Default      | Description                                             |
| ------------------------------ | -------- | ------------ | ------------------------------------------------------------- |
| `app-dir`                      | yes      | —            | App directory containing `android/`.                           |
| `cmdline-tools-version`        | no       | `12266719`   | See note above — pin explicitly, do not trust upstream defaults. |
| `output-dir`                   | yes      | —            | Directory the built APK is copied into as `app-release.apk`.   |
| `gradle-cache-key`             | yes      | —            | Exact cache key for the Gradle cache; a build that did not succeed saves `<key>-partial-<run id>-<attempt>` instead. |
| `gradle-cache-restore-keys`    | no       | `''`         | Newline-separated fallback prefixes, tried after `<gradle-cache-key>-partial-`. |
| `gradle-task`                  | no       | `assembleRelease` | `gradlew` task to build, e.g. `:app:assembleRelease` to scope to one module. |
| `gradle-args`                  | no       | `''`         | Extra whitespace-split arguments appended after `gradle-task`, e.g. `-x lint -x lintVitalAnalyzeRelease`. Not shell-quoted. |
| `android-abis`                 | no       | `''`         | Comma-separated ABIs passed as `-PreactNativeArchitectures=<value>`, e.g. `x86_64`. Empty passes nothing, so the project's own `reactNativeArchitectures` applies. Fails closed on an unknown ABI or a contradicting pin in `gradle-args` / `ORG_GRADLE_PROJECT_reactNativeArchitectures`. See [ABIs](#abis). |
| `native-compile-jobs`          | no       | `''`         | Most C/C++ compilers the CMake builds inside Gradle run at once, across every native module. Empty derives it from the cgroup limits. See [Native compile parallelism](#native-compile-parallelism). |
| `native-compile-memory-per-job` | no     | `3584`       | MiB of memory limit each derived native compile job is sized for, the peak of the heaviest translation unit. Ignored when `native-compile-jobs` is set. See [Native compile parallelism](#native-compile-parallelism). |
| `android-sdk-cache-save`       | no       | `'true'`     | `'true'` saves the [Android SDK cache](#android-sdk-cache) from inside the action after a successful build, off `pull_request`, with `continue-on-error`. `'false'` leaves the save to the caller, which can bound it with `timeout-minutes`. |

## Outputs

| Name       | Description                                    |
| ---------- | -------------------------------------------------- |
| `app-path` | Path to the packaged APK (`<output-dir>/app-release.apk`). |
| `android-sdk-cache-key` | Key of the Android SDK cache this build restored or would save. |
| `android-sdk-cache-paths` | Newline-separated SDK directories the Android SDK cache holds. |
| `android-sdk-cache-hit` | `true` when the Android SDK was restored from an exact cache hit. |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/build-android-app@v4.3.0 # v4.3.0
  id: build
  with:
      app-dir: apps/mobile
      output-dir: .ci-cache/android-native-app/bare
      gradle-cache-key: gradle-bare-${{ runner.os }}-${{ hashFiles('yarn.lock') }}
```
