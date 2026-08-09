# build-android-app

Sets up the Android SDK via `android-actions/setup-android`, builds a Release
APK with `./gradlew --no-daemon <gradle-task>` (default task
`assembleRelease`), verifies the embedded `assets/index.android.bundle`, and
packages the single signed release APK as `<output-dir>/app-release.apk`.
Restores/saves a Gradle cache around the build.

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
baked into the `android-actions/setup-android@v3` tag release actually pinned
by this action — **not** whatever `main` on that action currently defaults to.
The two have drifted before and collided with the cmdline-tools version
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
| `gradle-cache-key`             | yes      | —            | Exact cache key for the Gradle cache.                           |
| `gradle-cache-restore-keys`    | no       | `''`         | Newline-separated fallback prefixes.                            |
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
