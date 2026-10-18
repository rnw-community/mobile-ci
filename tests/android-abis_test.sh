#!/usr/bin/env bash
# An E2E or base Android build compiles only the ABI its test device runs, and
# that ABI is part of the native key. android-maestro.yml resolves it from the
# driver; seed-native-cache.yml has to resolve the same value for the same
# inputs, or the warm-up publishes under a key no pull request looks up. Both
# workflows' steps are extracted and run here, and build-android-app's own
# guard is run against a stubbed gradlew.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

E2E_WORKFLOW="$REPO_ROOT/.github/workflows/android-maestro.yml"
SEED_WORKFLOW="$REPO_ROOT/.github/workflows/seed-native-cache.yml"
ACTION="$REPO_ROOT/actions/build-android-app/action.yml"
STEP='Resolve the Android ABIs'
BUILD_STEP='Build APK (Release)'

resolve() {
    dir="$(new_workflow_workspace "$E2E_WORKFLOW" detect "$STEP")"
    run_step "$dir" ANDROID_ABIS=auto ANDROID_DRIVER=avd EMULATOR_ARCH=x86_64 GRADLE_ARGS='' BUILD_ENV='' "$@"
}

case_start 'the e2e and the warm-up resolve the ABIs with the same script'
e2e_script="$(extract_workflow_step_script "$E2E_WORKFLOW" detect "$STEP")"
seed_script="$(extract_workflow_step_script "$SEED_WORKFLOW" android-abis "$STEP")"
if [ "$e2e_script" != "$seed_script" ]; then
    fail_case 'android-maestro and seed-native-cache state the ABI rule differently, so the warm-up can publish under a key the e2e never computes'
else
    pass_case
fi

case_start 'auto on the avd driver builds the emulator ABI and keys on it'
resolve
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals 'x86_64' "$(step_output "$dir" abis)" 'abis' \
    && assert_equals '-abi-x86_64' "$(step_output "$dir" key-segment)" 'key segment' \
    && pass_case

case_start 'auto on the redroid driver builds arm64-v8a'
resolve ANDROID_DRIVER=redroid
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals 'arm64-v8a' "$(step_output "$dir" abis)" 'abis' \
    && assert_equals '-abi-arm64-v8a' "$(step_output "$dir" key-segment)" 'key segment' \
    && pass_case

case_start 'auto on an unknown driver fails closed'
resolve ANDROID_DRIVER=genymotion
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case "an unknown driver resolved to '$(step_output "$dir" abis)'"
else
    assert_contains "$(cat "$dir/log")" 'Set android-abis explicitly' 'error message' && pass_case
fi

case_start 'auto on the device-cloud driver fails closed, since no ABI follows from a device it never sees'
resolve ANDROID_DRIVER=device-cloud
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" 'android-driver is device-cloud' 'error message' \
    && pass_case

case_start 'an explicit android-abis on the device-cloud driver resolves and keys on it'
resolve ANDROID_DRIVER=device-cloud ANDROID_ABIS=x86_64,arm64-v8a
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals '-abi-x86_64,arm64-v8a' "$(step_output "$dir" key-segment)" 'key segment' \
    && pass_case

case_start 'auto leaves an ABI already pinned in gradle-args to gradle-args, and still keys on it'
resolve GRADLE_ARGS=$'-x lint\n-PreactNativeArchitectures=arm64-v8a'
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals '' "$(step_output "$dir" abis)" 'abis' \
    && assert_equals '-abi-arm64-v8a' "$(step_output "$dir" key-segment)" 'key segment' \
    && pass_case

case_start 'auto leaves an ABI pinned through build-env to build-env'
resolve BUILD_ENV=$'FOO=1\nORG_GRADLE_PROJECT_reactNativeArchitectures=x86'
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals '' "$(step_output "$dir" abis)" 'abis' \
    && assert_equals '-abi-x86' "$(step_output "$dir" key-segment)" 'key segment' \
    && pass_case

case_start 'gradle-args and build-env pinning different ABIs fail closed'
resolve GRADLE_ARGS='-PreactNativeArchitectures=x86_64' BUILD_ENV='ORG_GRADLE_PROJECT_reactNativeArchitectures=arm64-v8a'
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'two different pins resolved without failing'
else
    assert_contains "$(cat "$dir/log")" 'pin it once' 'error message' && pass_case
fi

case_start 'an explicit value that matches the gradle-args pin is accepted'
resolve ANDROID_ABIS=x86_64 GRADLE_ARGS='-PreactNativeArchitectures=x86_64'
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals 'x86_64' "$(step_output "$dir" abis)" 'abis' \
    && pass_case

case_start 'an explicit value that contradicts gradle-args fails closed'
resolve ANDROID_ABIS=x86_64 GRADLE_ARGS='-PreactNativeArchitectures=arm64-v8a'
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case "the contradiction resolved to '$(step_output "$dir" abis)'"
else
    assert_contains "$(cat "$dir/log")" 'drop one of the two' 'error message' && pass_case
fi

case_start 'an explicit list of several ABIs is kept as given'
resolve ANDROID_ABIS='x86_64,arm64-v8a' ANDROID_DRIVER=redroid
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals 'x86_64,arm64-v8a' "$(step_output "$dir" abis)" 'abis' \
    && pass_case

case_start 'empty passes nothing and adds nothing to the key'
resolve ANDROID_ABIS=''
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals '' "$(step_output "$dir" abis)" 'abis' \
    && assert_equals '' "$(step_output "$dir" key-segment)" 'key segment' \
    && pass_case

for bad in 'x86_64 ' 'x86_64,' 'mips' 'x86_64,,x86' 'arm64'; do
    case_start "an invalid ABI list '$bad' fails closed"
    resolve ANDROID_ABIS="$bad"
    if [ "$STEP_STATUS" -eq 0 ]; then
        fail_case "'$bad' resolved to '$(step_output "$dir" abis)'"
    else
        assert_contains "$(cat "$dir/log")" 'comma-separated list' 'error message' && pass_case
    fi
done

case_start 'the resolved ABIs reach the build and the native key in both workflows'
problem="$(E2E="$E2E_WORKFLOW" SEED="$SEED_WORKFLOW" python3 - <<'PYTHON'
import os
import yaml

problems = []
e2e = yaml.safe_load(open(os.environ['E2E'], encoding='utf-8'))
seed = yaml.safe_load(open(os.environ['SEED'], encoding='utf-8'))


def build_step(job):
    return next(step for step in job['steps'] if step.get('name') == 'build-android-app')


if e2e[True]['workflow_call']['inputs']['android-abis']['default'] != 'auto':
    problems.append('android-maestro android-abis does not default to auto')
if seed[True]['workflow_call']['inputs']['android-abis']['default'] != 'auto':
    problems.append('seed-native-cache android-abis does not default to auto')
if not e2e['jobs']['plan']['with']['toolchain'].endswith('${{ needs.detect.outputs.android-abi-key }}'):
    problems.append('android-maestro does not fold the ABIs into the native key')
if build_step(e2e['jobs']['build'])['with'].get('android-abis') != '${{ needs.detect.outputs.android-abis }}':
    problems.append('android-maestro does not pass the resolved ABIs to the build')
if not seed['jobs']['plan-android']['with']['toolchain'].endswith('${{ needs.android-abis.outputs.key-segment }}'):
    problems.append('seed-native-cache does not fold the ABIs into the native key')
if build_step(seed['jobs']['seed-android'])['with'].get('android-abis') != '${{ needs.android-abis.outputs.abis }}':
    problems.append('seed-native-cache does not pass the resolved ABIs to the build')
seed_env = next(step for step in seed['jobs']['android-abis']['steps'] if step.get('name') == 'Resolve the Android ABIs')['env']
if (seed_env.get('ANDROID_DRIVER'), seed_env.get('EMULATOR_ARCH')) != ('avd', 'x86_64'):
    problems.append('seed-native-cache auto does not resolve like the default avd driver')
print('; '.join(problems))
PYTHON
)"
if [ -n "$problem" ]; then
    fail_case "$problem"
else
    pass_case
fi

build() {
    dir="$(new_workspace "$ACTION" "$BUILD_STEP")"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/gradle-args"\n' "$dir" > "$dir/work/gradlew"
    chmod +x "$dir/work/gradlew"
    run_step "$dir" GRADLE_TASK=assembleRelease GRADLE_ARGS='-x lint' ANDROID_ABIS='' ORG_GRADLE_PROJECT_reactNativeArchitectures='' "$@"
}

case_start 'build-android-app passes android-abis to Gradle'
build ANDROID_ABIS=x86_64
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals $'--no-daemon\nassembleRelease\n-x\nlint\n-PreactNativeArchitectures=x86_64' "$(cat "$dir/gradle-args")" 'gradle argv' \
    && pass_case

case_start 'build-android-app passes nothing for an empty android-abis'
build
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals $'--no-daemon\nassembleRelease\n-x\nlint' "$(cat "$dir/gradle-args")" 'gradle argv' \
    && pass_case

case_start 'build-android-app does not repeat an ABI gradle-args already pins to the same value'
build ANDROID_ABIS=x86_64 GRADLE_ARGS='-PreactNativeArchitectures=x86_64'
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals $'--no-daemon\nassembleRelease\n-PreactNativeArchitectures=x86_64' "$(cat "$dir/gradle-args")" 'gradle argv' \
    && pass_case

case_start 'build-android-app fails closed when gradle-args pins a different ABI'
build ANDROID_ABIS=x86_64 GRADLE_ARGS='-PreactNativeArchitectures=arm64-v8a'
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'Gradle ran with two different ABI pins'
elif [ -f "$dir/gradle-args" ]; then
    fail_case 'Gradle ran before the contradiction was rejected'
else
    assert_contains "$(cat "$dir/log")" 'drop one of the two' 'error message' && pass_case
fi

case_start 'build-android-app fails closed when ORG_GRADLE_PROJECT_reactNativeArchitectures pins a different ABI'
build ANDROID_ABIS=x86_64 ORG_GRADLE_PROJECT_reactNativeArchitectures=arm64-v8a
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'Gradle ran with two different ABI pins'
else
    assert_contains "$(cat "$dir/log")" 'ORG_GRADLE_PROJECT_reactNativeArchitectures' 'error message' && pass_case
fi

case_start 'build-android-app rejects an invalid ABI before Gradle runs'
build ANDROID_ABIS='x86_64,'
if [ "$STEP_STATUS" -eq 0 ] || [ -f "$dir/gradle-args" ]; then
    fail_case 'an invalid ABI list reached Gradle'
else
    assert_contains "$(cat "$dir/log")" 'comma-separated list' 'error message' && pass_case
fi

finish_suite
