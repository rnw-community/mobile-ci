# build-android-app

Sets up the Android SDK via `android-actions/setup-android`, builds a Release
APK with `./gradlew --no-daemon <gradle-task>` (default task
`assembleRelease`), verifies the embedded `assets/index.android.bundle`, and
packages the single signed release APK as `<output-dir>/app-release.apk`.
Restores/saves a Gradle cache (`~/.gradle/caches`, `~/.gradle/wrapper`)
around the build.

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

## Outputs

| Name       | Description                                    |
| ---------- | -------------------------------------------------- |
| `app-path` | Path to the packaged APK (`<output-dir>/app-release.apk`). |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/build-android-app@v1
  id: build
  with:
      app-dir: apps/mobile
      output-dir: .ci-cache/android-native-app/bare
      gradle-cache-key: gradle-bare-${{ runner.os }}-${{ hashFiles('yarn.lock') }}
```
