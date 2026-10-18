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
    run_step "$workspace" CACHE_KEY="$KEY" RUN_ID='777' RUN_ATTEMPT='2' "$@"
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

finish_suite
