#!/usr/bin/env bash
# build-android-app's Gradle cache must warm even when the build does not
# finish. A build that times out on a cold cache and saves nothing restores
# the same cold cache next time and times out again, forever. So a build that
# failed or was cancelled saves what it downloaded under a run-unique partial
# key the next restore falls back to, and a successful build saves the exact
# key unless it was already an exact hit.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/build-android-app/action.yml"
STEP='Choose the Gradle cache save key'
KEY='gradle-bare-Linux-abc123'

choose() {
    workspace="$(new_workspace "$ACTION" "$STEP")"
    run_step "$workspace" CACHE_KEY="$KEY" RUN_ID='777' RUN_ATTEMPT='2' EVENT_NAME='push' "$@"
}

case_start 'a successful build on a cache miss saves the exact key'
choose BUILD_OUTCOME='success' CACHE_HIT='false'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals "$KEY" "$(step_output "$workspace" key)" 'save key'; then
    pass_case
fi

case_start 'a successful build on an exact hit saves nothing'
choose BUILD_OUTCOME='success' CACHE_HIT='true'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals '' "$(step_output "$workspace" key)" 'save key'; then
    pass_case
fi

case_start 'a failed build saves a run-unique partial key'
choose BUILD_OUTCOME='failure' CACHE_HIT='false'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals "$KEY-partial-777-2" "$(step_output "$workspace" key)" 'save key'; then
    pass_case
fi

case_start 'a build cancelled by its timeout saves a run-unique partial key'
choose BUILD_OUTCOME='cancelled' CACHE_HIT='false'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals "$KEY-partial-777-2" "$(step_output "$workspace" key)" 'save key'; then
    pass_case
fi

case_start 'a failed build that restored the exact key saves nothing new'
choose BUILD_OUTCOME='failure' CACHE_HIT='true'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals '' "$(step_output "$workspace" key)" 'save key'; then
    pass_case
fi

case_start 'a pull request saves no Gradle cache, even on a miss or a failure'
for outcome in success failure cancelled; do
    choose BUILD_OUTCOME="$outcome" CACHE_HIT='false' EVENT_NAME='pull_request'
    assert_equals 0 "$STEP_STATUS" "step status ($outcome)" \
        && assert_equals '' "$(step_output "$workspace" key)" "save key ($outcome)" || break
done && pass_case

case_start 'a build that never ran saves nothing'
choose BUILD_OUTCOME='skipped' CACHE_HIT=''
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals '' "$(step_output "$workspace" key)" 'save key'; then
    pass_case
fi

case_start 'the save runs after a failed or cancelled build, and the restore falls back to partials first'
if wiring="$(ACTION_YML="$ACTION" python3 - <<'PYTHON' 2>&1
import os
import sys

import yaml

steps = yaml.safe_load(open(os.environ['ACTION_YML'], encoding='utf-8'))['runs']['steps']
by_name = {step.get('name'): step for step in steps}
problems = []
for name in ('Choose the Gradle cache save key', 'Save Gradle cache'):
    if 'always()' not in str(by_name.get(name, {}).get('if', '')):
        problems.append(f"step {name!r} does not run if: always()")
restore = by_name.get('Restore Gradle cache', {})
first = str(restore.get('with', {}).get('restore-keys', '')).strip().split('\n')[0]
if first != '${{ inputs.gradle-cache-key }}-partial-':
    problems.append(f"restore-keys does not try this key's partials first: {first!r}")
if problems:
    sys.exit('; '.join(problems))
PYTHON
)"; then
    pass_case
else
    fail_case "$wiring"
fi

# The Android SDK cache: its key moves with every package the build installs,
# a hit skips setup-android (and so every download), and a save never runs on
# a pull request, never after a failed build and never stalls a workflow job.
SDK_KEY_STEP='Resolve the Android SDK cache'
SDK_USE_STEP='Use the restored Android SDK'
TILDE='~'
PLAN_WORKFLOW="$REPO_ROOT/.github/workflows/expo-base-plan.yml"

sdk_key() {
    workspace="$(new_workspace "$ACTION" "$SDK_KEY_STEP")"
    mkdir -p "$workspace/home" "$workspace/work/apps/mobile/android/app" "$workspace/work/node_modules/react-native/gradle"
    printf 'ndkVersion = "27.1.12297006"\n' > "$workspace/work/node_modules/react-native/gradle/libs.versions.toml"
    printf 'android.compileSdkVersion=35\n' > "$workspace/work/apps/mobile/android/gradle.properties"
    printf 'android {}\n' > "$workspace/work/apps/mobile/android/app/build.gradle"
}

run_sdk_key() {
    run_step "$workspace" HOME="$workspace/home" ANDROID_SDK_ROOT='' RUNNER_OS=Linux RUNNER_ARCH=X64 \
        APP_DIR=apps/mobile CMDLINE_TOOLS_VERSION=12266719 SDK_PACKAGES=platform-tools "$@"
}

case_start 'the SDK cache key names the OS, the arch and the cmdline-tools version'
sdk_key
run_sdk_key
key="$(step_output "$workspace" key)"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$key" 'android-sdk-v1-Linux-X64-cmdline-12266719-' 'key'; then
    pass_case
fi
base_key="$key"

case_start 'the SDK cache key is stable for the same project'
sdk_key
run_sdk_key
if assert_equals "$base_key" "$(step_output "$workspace" key)" 'key'; then
    pass_case
fi

case_start 'a version React Native pins moves the SDK cache key'
sdk_key
printf 'ndkVersion = "28.0.13004108"\n' > "$workspace/work/node_modules/react-native/gradle/libs.versions.toml"
run_sdk_key
if [ "$(step_output "$workspace" key)" = "$base_key" ]; then
    fail_case 'a new NDK pin kept the old key, so the cache would never hold the new NDK'
else
    pass_case
fi

case_start "a change to the app's gradle.properties moves the SDK cache key"
sdk_key
printf 'android.compileSdkVersion=36\n' > "$workspace/work/apps/mobile/android/gradle.properties"
run_sdk_key
if [ "$(step_output "$workspace" key)" = "$base_key" ]; then
    fail_case 'a new compileSdkVersion kept the old key'
else
    pass_case
fi

case_start 'another sdkmanager package list moves the SDK cache key'
sdk_key
run_sdk_key SDK_PACKAGES='platform-tools build-tools;35.0.0'
if [ "$(step_output "$workspace" key)" = "$base_key" ]; then
    fail_case 'an extra package kept the old key'
else
    pass_case
fi

case_start 'without ANDROID_SDK_ROOT the cache holds the setup-android default root, written host-independently'
sdk_key
run_sdk_key
paths="$(step_output "$workspace" paths)"
if assert_equals "$workspace/home/.android/sdk" "$(step_output "$workspace" root)" 'root' \
    && assert_contains "$paths" "$TILDE/.android/sdk/ndk" 'paths' \
    && assert_contains "$paths" "$TILDE/.android/sdk/cmdline-tools" 'paths' \
    && assert_not_contains "$paths" 'system-images' 'paths'; then
    pass_case
fi

case_start 'a preinstalled ANDROID_SDK_ROOT is the root the cache fills'
sdk_key
run_sdk_key ANDROID_SDK_ROOT=/opt/android-sdk
if assert_equals '/opt/android-sdk' "$(step_output "$workspace" root)" 'root' \
    && assert_contains "$(step_output "$workspace" paths)" '/opt/android-sdk/platform-tools' 'paths'; then
    pass_case
fi

use_sdk() {
    workspace="$(new_workspace "$ACTION" "$SDK_USE_STEP")"
    sdk="$workspace/sdk"
    mkdir -p "$sdk/cmdline-tools/16.0/bin" "$sdk/platform-tools"
}

case_start 'a restored SDK is put on the environment without running setup-android'
use_sdk
printf '#!/bin/sh\n' > "$sdk/cmdline-tools/16.0/bin/sdkmanager"
printf '#!/bin/sh\n' > "$sdk/platform-tools/adb"
chmod +x "$sdk/cmdline-tools/16.0/bin/sdkmanager" "$sdk/platform-tools/adb"
run_step "$workspace" SDK_ROOT="$sdk"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'true' "$(step_output "$workspace" ready)" 'ready' \
    && assert_contains "$(cat "$workspace/env")" "ANDROID_HOME=$sdk" 'env' \
    && assert_contains "$(cat "$workspace/env")" "ANDROID_SDK_ROOT=$sdk" 'env' \
    && assert_contains "$(cat "$workspace/path")" "$sdk/cmdline-tools/16.0/bin" 'path' \
    && assert_contains "$(cat "$workspace/path")" "$sdk/platform-tools" 'path'; then
    pass_case
fi

case_start 'a restored SDK without sdkmanager falls back to setup-android'
use_sdk
printf '#!/bin/sh\n' > "$sdk/platform-tools/adb"
chmod +x "$sdk/platform-tools/adb"
run_step "$workspace" SDK_ROOT="$sdk"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'false' "$(step_output "$workspace" ready)" 'ready' \
    && assert_equals '' "$(cat "$workspace/env")" 'env'; then
    pass_case
fi

case_start 'the SDK cache is wired restore-always, save-off-pull-request, and bounded in every workflow'
if wiring="$(REPO_ROOT="$REPO_ROOT" ACTION_YML="$ACTION" python3 - <<'PYTHON' 2>&1
import os
import sys

import yaml

root = os.environ['REPO_ROOT']
problems = []
steps = yaml.safe_load(open(os.environ['ACTION_YML'], encoding='utf-8'))['runs']['steps']
by_name = {step.get('name'): step for step in steps}
setup = by_name['Set up Android SDK']
if 'sdk-cached.outputs.ready' not in str(setup.get('if', '')):
    problems.append('build-android-app runs setup-android even on a cache hit')
if by_name['Resolve the Android SDK cache']['env']['SDK_PACKAGES'] != setup['with']['packages']:
    problems.append('build-android-app keys the SDK cache on other packages than it installs')
save = by_name['Save the Android SDK']
for needle in ("github.event_name != 'pull_request'", "steps.build.outcome == 'success'", "inputs.android-sdk-cache-save == 'true'"):
    if needle not in str(save.get('if', '')):
        problems.append(f'build-android-app SDK save is missing {needle!r}')
if save.get('continue-on-error') is not True:
    problems.append('build-android-app SDK save can fail the build')

for name, job_id in (('android-maestro', 'build'), ('seed-native-cache', 'seed-android'), ('expo-base-plan', 'plan')):
    job = yaml.safe_load(open(os.path.join(root, '.github', 'workflows', f'{name}.yml'), encoding='utf-8'))['jobs'][job_id]
    names = [step.get('name') for step in job['steps']]
    saves = [step for step in job['steps'] if step.get('name') == 'Save the Android SDK']
    if len(saves) != 1:
        problems.append(f'{name}.yml job {job_id}: expected one SDK save step, found {len(saves)}')
        continue
    save = saves[0]
    if "github.event_name != 'pull_request'" not in str(save.get('if', '')):
        problems.append(f'{name}.yml job {job_id}: saves the SDK cache on pull requests')
    if save.get('continue-on-error') is not True or not save.get('timeout-minutes'):
        problems.append(f'{name}.yml job {job_id}: an SDK save stall can fail or hang the job')
    if names.index('Save the Android SDK') != len(names) - 1:
        problems.append(f'{name}.yml job {job_id}: the SDK save is not the last step, so a slow upload delays the job\'s real work')
    build = [step for step in job['steps'] if step.get('name') == 'build-android-app']
    if build and build[0]['with'].get('android-sdk-cache-save') != 'false':
        problems.append(f'{name}.yml job {job_id}: saves the SDK twice, once unbounded inside build-android-app')
if problems:
    sys.exit('; '.join(problems))
PYTHON
)"; then
    pass_case
else
    fail_case "$wiring"
fi

case_start 'the repack plan and the build key and adopt a restored SDK with the same scripts'
differing=''
for step in "$SDK_KEY_STEP" "$SDK_USE_STEP"; do
    if [ "$(extract_step_script "$ACTION" "$step")" != "$(extract_workflow_step_script "$PLAN_WORKFLOW" plan "$step")" ]; then
        differing="$step"
    fi
done
if [ -n "$differing" ]; then
    fail_case "expo-base-plan's '$differing' differs from build-android-app's"
else
    pass_case
fi

# Native compile parallelism. The Android Gradle plugin runs the SDK's ninja
# directly, and ninja sizes itself from the CPUs the process may be scheduled
# on, not from the container's cgroup quota: a 4-CPU / 8 GiB runner on a
# 24-thread host started 26 clang processes per CMake project, four projects
# at once, and the kernel killed the build. The bound comes from the cgroup
# and is enforced by a compiler launcher that holds one of N slot locks.
JOBS_STEP='Fit the native build into the container limits'
BUILD_STEP='Build APK (Release)'
GIB=1073741824

jobs_cgroup_v2() {
    mkdir -p "$1"
    printf 'cpu memory pids\n' > "$1/cgroup.controllers"
    printf '%s\n' "$2" > "$1/memory.max"
    printf '%s\n' "$3" > "$1/cpu.max"
}

run_jobs() {
    run_step "$workspace" NATIVE_COMPILE_JOBS='' CGROUP_ROOT="$workspace/cgroup" "$@"
}

case_start 'a 4-CPU / 8 GiB cgroup v2 runner compiles 1 native job at a time: one heavy translation unit beside the JVMs is all that fits'
workspace="$(new_workspace "$ACTION" "$JOBS_STEP")"
jobs_cgroup_v2 "$workspace/cgroup" $((8 * GIB)) '400000 100000'
run_jobs
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 1 "$(step_output "$workspace" jobs)" 'jobs'; then
    pass_case
fi

case_start 'memory, not CPUs, bounds the jobs on a runner with more CPUs than memory per job'
workspace="$(new_workspace "$ACTION" "$JOBS_STEP")"
jobs_cgroup_v2 "$workspace/cgroup" $((16 * GIB)) '800000 100000'
run_jobs
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 3 "$(step_output "$workspace" jobs)" 'jobs'; then
    pass_case
fi

case_start 'CPUs, not memory, bound the jobs on a runner with memory to spare'
workspace="$(new_workspace "$ACTION" "$JOBS_STEP")"
jobs_cgroup_v2 "$workspace/cgroup" $((64 * GIB)) '400000 100000'
run_jobs
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 4 "$(step_output "$workspace" jobs)" 'jobs'; then
    pass_case
fi

case_start 'a fractional CPU quota rounds up and a tiny memory limit still compiles one job'
workspace="$(new_workspace "$ACTION" "$JOBS_STEP")"
jobs_cgroup_v2 "$workspace/cgroup" $((3 * GIB)) '150000 100000'
run_jobs
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 1 "$(step_output "$workspace" jobs)" 'jobs'; then
    pass_case
fi

case_start 'a cgroup v1 runner is bounded the same way'
workspace="$(new_workspace "$ACTION" "$JOBS_STEP")"
mkdir -p "$workspace/cgroup/memory" "$workspace/cgroup/cpu"
printf '%s\n' $((12 * GIB)) > "$workspace/cgroup/memory/memory.limit_in_bytes"
printf '400000\n' > "$workspace/cgroup/cpu/cpu.cfs_quota_us"
printf '100000\n' > "$workspace/cgroup/cpu/cpu.cfs_period_us"
run_jobs
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 2 "$(step_output "$workspace" jobs)" 'jobs'; then
    pass_case
fi

case_start 'native-compile-memory-per-job resizes the memory bound above a 5 GiB reserve for the Gradle daemon and the capped Kotlin daemon'
workspace="$(new_workspace "$ACTION" "$JOBS_STEP")"
jobs_cgroup_v2 "$workspace/cgroup" $((8 * GIB)) '400000 100000'
run_jobs NATIVE_COMPILE_MEMORY_PER_JOB=1024
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 3 "$(step_output "$workspace" jobs)" 'jobs' \
    && assert_contains "$(cat "$workspace/log")" 'less a 5120 MiB JVM reserve' 'log'; then
    pass_case
fi

case_start 'a native-compile-memory-per-job that is not a positive MiB count fails closed'
all_failed_closed=true
for per_job in 0 3.5G -1; do
    workspace="$(new_workspace "$ACTION" "$JOBS_STEP")"
    jobs_cgroup_v2 "$workspace/cgroup" $((8 * GIB)) '400000 100000'
    run_jobs NATIVE_COMPILE_MEMORY_PER_JOB="$per_job"
    if ! { assert_equals 1 "$STEP_STATUS" "step status ($per_job)" \
        && assert_contains "$(cat "$workspace/log")" 'native-compile-memory-per-job' "log ($per_job)"; }; then
        all_failed_closed=false
        break
    fi
done
if [ "$all_failed_closed" = true ]; then
    pass_case
fi

case_start 'a runner without cgroup limits leaves native parallelism to ninja'
workspace="$(new_workspace "$ACTION" "$JOBS_STEP")"
jobs_cgroup_v2 "$workspace/cgroup" max 'max 100000'
run_jobs
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals '' "$(step_output "$workspace" jobs)" 'jobs'; then
    pass_case
fi

case_start 'native-compile-jobs overrides the derived bound'
workspace="$(new_workspace "$ACTION" "$JOBS_STEP")"
jobs_cgroup_v2 "$workspace/cgroup" $((8 * GIB)) '400000 100000'
run_jobs NATIVE_COMPILE_JOBS=3
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 3 "$(step_output "$workspace" jobs)" 'jobs'; then
    pass_case
fi

case_start 'a native-compile-jobs that is not a positive integer fails closed'
workspace="$(new_workspace "$ACTION" "$JOBS_STEP")"
jobs_cgroup_v2 "$workspace/cgroup" $((8 * GIB)) '400000 100000'
run_jobs NATIVE_COMPILE_JOBS=0
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'native-compile-jobs' 'log'; then
    pass_case
fi

case_start 'an unreadable memory limit fails closed instead of compiling unbounded'
workspace="$(new_workspace "$ACTION" "$JOBS_STEP")"
jobs_cgroup_v2 "$workspace/cgroup" 'lots' '400000 100000'
run_jobs
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'memory.max' 'log'; then
    pass_case
fi

launcher_from_step() {
    workspace="$(new_workspace "$ACTION" "$JOBS_STEP")"
    jobs_cgroup_v2 "$workspace/cgroup" $((8 * GIB)) '400000 100000'
    run_jobs NATIVE_COMPILE_JOBS="$1"
    slot_launcher="$workspace/runner-temp/mobile-ci-compile-slots/compile-slot.sh"
    slots_dir="$workspace/runner-temp/mobile-ci-compile-slots"
}

case_start 'the compile slot launcher never runs more compilers than it has slots'
launcher_from_step 3
probe="$(mktemp -d)"
mkdir -p "$probe/running"
cat > "$probe/compiler" <<'COMPILER'
#!/bin/sh
touch "$PROBE/running/$$"
ls "$PROBE/running" | wc -l >> "$PROBE/concurrency"
sleep 0.3
rm "$PROBE/running/$$"
echo ran >> "$PROBE/ran"
COMPILER
chmod +x "$probe/compiler"
pids=''
for _ in 1 2 3 4 5 6 7 8 9 10; do
    PROBE="$probe" MOBILE_CI_COMPILE_SLOTS=3 MOBILE_CI_COMPILE_SLOTS_DIR="$slots_dir" \
        "$slot_launcher" "$probe/compiler" &
    pids="$pids $!"
done
launcher_failed=0
for pid in $pids; do
    wait "$pid" || launcher_failed=1
done
peak="$(sort -n "$probe/concurrency" 2>/dev/null | tail -1)"
if assert_equals 0 "$launcher_failed" 'launcher status' \
    && assert_equals 10 "$(wc -l < "$probe/ran" | tr -d ' ')" 'compilers run' \
    && [ "${peak:-99}" -le 3 ]; then
    pass_case
else
    [ "$launcher_failed" = 0 ] && fail_case "peak concurrency ${peak:-unknown} exceeds 3 slots"
fi

case_start "the compile slot launcher passes the compiler's exit status through"
launcher_from_step 2
status=0
MOBILE_CI_COMPILE_SLOTS=2 MOBILE_CI_COMPILE_SLOTS_DIR="$slots_dir" "$slot_launcher" sh -c 'exit 7' || status=$?
if assert_equals 7 "$status" 'exit status'; then
    pass_case
fi

case_start 'a long-lived process a chained launcher leaves behind does not keep the slot'
launcher_from_step 1
probe="$(mktemp -d)"
cat > "$probe/daemonizing" <<'DAEMON'
#!/bin/sh
sleep 30 &
echo ran >> "$PROBE/ran"
DAEMON
chmod +x "$probe/daemonizing"
PROBE="$probe" MOBILE_CI_COMPILE_SLOTS=1 MOBILE_CI_COMPILE_SLOTS_DIR="$slots_dir" "$slot_launcher" "$probe/daemonizing" > /dev/null
status=0
PROBE="$probe" MOBILE_CI_COMPILE_SLOTS=1 MOBILE_CI_COMPILE_SLOTS_DIR="$slots_dir" timeout 5 "$slot_launcher" "$probe/daemonizing" > /dev/null || status=$?
if assert_equals 0 "$status" 'second compile status (124 means it waited on a slot the first one leaked)' \
    && assert_equals 2 "$(wc -l < "$probe/ran" | tr -d ' ')" 'compilers run'; then
    pass_case
fi

case_start 'a bounded runner hands every later CMake configure in the job the compile slot launcher'
launcher_from_step ''
job_env="$(cat "$workspace/env")"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$job_env" "CMAKE_C_COMPILER_LAUNCHER=$slot_launcher" 'job env' \
    && assert_contains "$job_env" "CMAKE_CXX_COMPILER_LAUNCHER=$slot_launcher" 'job env' \
    && assert_contains "$job_env" 'MOBILE_CI_COMPILE_SLOTS=1' 'job env' \
    && assert_contains "$job_env" "MOBILE_CI_COMPILE_SLOTS_DIR=$slots_dir" 'job env'; then
    pass_case
fi

case_start "the caller's own compiler launcher runs behind the slot, and a second run does not nest the slot"
workspace="$(new_workspace "$ACTION" "$JOBS_STEP")"
jobs_cgroup_v2 "$workspace/cgroup" $((8 * GIB)) '400000 100000'
slot_launcher="$workspace/runner-temp/mobile-ci-compile-slots/compile-slot.sh"
run_jobs CMAKE_CXX_COMPILER_LAUNCHER=ccache CMAKE_C_COMPILER_LAUNCHER="$slot_launcher;ccache"
job_env="$(cat "$workspace/env")"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$job_env" "CMAKE_CXX_COMPILER_LAUNCHER=$slot_launcher;ccache" 'job env' \
    && assert_contains "$job_env" "CMAKE_C_COMPILER_LAUNCHER=$slot_launcher;ccache" 'job env' \
    && assert_not_contains "$job_env" "$slot_launcher;$slot_launcher" 'job env'; then
    pass_case
fi

G1_RETURN='-XX:G1PeriodicGCInterval=10000 -XX:MinHeapFreeRatio=10 -XX:MaxHeapFreeRatio=30'

case_start 'a bounded runner makes idle JVMs hand their unused heap back, keeping the fleet JAVA_TOOL_OPTIONS'
workspace="$(new_workspace "$ACTION" "$JOBS_STEP")"
jobs_cgroup_v2 "$workspace/cgroup" $((8 * GIB)) '400000 100000'
run_jobs JAVA_TOOL_OPTIONS='-XX:MaxRAM=8192m -XX:ActiveProcessorCount=4'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/env")" "JAVA_TOOL_OPTIONS=-XX:MaxRAM=8192m -XX:ActiveProcessorCount=4 $G1_RETURN" 'job env'; then
    pass_case
fi

case_start 'a second run does not repeat the JVM heap-return options'
workspace="$(new_workspace "$ACTION" "$JOBS_STEP")"
jobs_cgroup_v2 "$workspace/cgroup" $((8 * GIB)) '400000 100000'
run_jobs JAVA_TOOL_OPTIONS="-XX:MaxRAM=8192m $G1_RETURN"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_not_contains "$(cat "$workspace/env")" 'JAVA_TOOL_OPTIONS' 'job env'; then
    pass_case
fi

case_start 'an unbounded runner leaves JAVA_TOOL_OPTIONS alone'
workspace="$(new_workspace "$ACTION" "$JOBS_STEP")"
jobs_cgroup_v2 "$workspace/cgroup" max 'max 100000'
run_jobs JAVA_TOOL_OPTIONS='-XX:MaxRAM=8192m'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_not_contains "$(cat "$workspace/env")" 'JAVA_TOOL_OPTIONS' 'job env'; then
    pass_case
fi

KOTLIN_DAEMON_CAP='-Dkotlin.daemon.jvm.options=-Xmx1536m'

case_start 'a bounded runner caps the Kotlin daemon heap through GRADLE_OPTS, keeping the caller GRADLE_OPTS and the Kotlin execution strategy'
workspace="$(new_workspace "$ACTION" "$JOBS_STEP")"
jobs_cgroup_v2 "$workspace/cgroup" $((8 * GIB)) '400000 100000'
run_jobs GRADLE_OPTS='-Dorg.gradle.caching=true'
job_env="$(cat "$workspace/env")"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$job_env" "GRADLE_OPTS=-Dorg.gradle.caching=true $KOTLIN_DAEMON_CAP" 'job env' \
    && assert_not_contains "$job_env" 'kotlin.compiler.execution.strategy' 'job env'; then
    pass_case
fi

case_start "a caller's own Kotlin execution strategy still gets the Kotlin daemon cap"
workspace="$(new_workspace "$ACTION" "$JOBS_STEP")"
jobs_cgroup_v2 "$workspace/cgroup" $((8 * GIB)) '400000 100000'
run_jobs GRADLE_OPTS='-Dorg.gradle.project.kotlin.compiler.execution.strategy=daemon'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/env")" "GRADLE_OPTS=-Dorg.gradle.project.kotlin.compiler.execution.strategy=daemon $KOTLIN_DAEMON_CAP" 'job env'; then
    pass_case
fi

case_start "a caller's own Kotlin daemon JVM options in GRADLE_OPTS are kept, and a second run adds nothing"
all_kept=true
for opts in '-Dkotlin.daemon.jvm.options=-Xmx3g' '-Dorg.gradle.project.kotlin.daemon.jvmargs=-Xmx3g' "$KOTLIN_DAEMON_CAP"; do
    workspace="$(new_workspace "$ACTION" "$JOBS_STEP")"
    jobs_cgroup_v2 "$workspace/cgroup" $((8 * GIB)) '400000 100000'
    run_jobs GRADLE_OPTS="$opts"
    if ! { assert_equals 0 "$STEP_STATUS" "step status ($opts)" \
        && assert_not_contains "$(cat "$workspace/env")" 'GRADLE_OPTS' "job env ($opts)"; }; then
        all_kept=false
        break
    fi
done
if [ "$all_kept" = true ]; then
    pass_case
fi

case_start 'an unbounded runner leaves GRADLE_OPTS alone'
workspace="$(new_workspace "$ACTION" "$JOBS_STEP")"
jobs_cgroup_v2 "$workspace/cgroup" max 'max 100000'
run_jobs
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_not_contains "$(cat "$workspace/env")" 'GRADLE_OPTS' 'job env'; then
    pass_case
fi

case_start 'an unbounded runner sets no compiler launcher'
workspace="$(new_workspace "$ACTION" "$JOBS_STEP")"
jobs_cgroup_v2 "$workspace/cgroup" max 'max 100000'
run_jobs
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_not_contains "$(cat "$workspace/env")" 'COMPILER_LAUNCHER' 'job env'; then
    pass_case
fi

case_start 'the build summary names the native compile bound'
workspace="$(new_workspace "$ACTION" "$BUILD_STEP")"
printf '#!/bin/sh\n' > "$workspace/work/gradlew"
chmod +x "$workspace/work/gradlew"
run_step "$workspace" GRADLE_TASK=assembleRelease GRADLE_ARGS='' ANDROID_ABIS='' MOBILE_CI_COMPILE_SLOTS=4
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/summary")" 'Native compile jobs: 4' 'summary'; then
    pass_case
fi

case_start 'the eas build --local Android lanes bound native compiles with the same step'
differing=''
for lane in native-publish.yml:android-publish native-dev-release.yml:android-dev-release; do
    if [ "$(extract_step_script "$ACTION" "$JOBS_STEP")" != "$(extract_workflow_step_script "$REPO_ROOT/.github/workflows/${lane%%:*}" "${lane#*:}" "$JOBS_STEP" 2>&1)" ]; then
        differing="$differing ${lane%%:*}"
    fi
done
if [ -n "$differing" ]; then
    fail_case "'$JOBS_STEP' is missing from, or differs from build-android-app's in:$differing"
else
    pass_case
fi

finish_suite
