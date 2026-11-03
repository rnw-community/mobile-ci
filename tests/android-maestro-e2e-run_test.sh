#!/usr/bin/env bash
# android-maestro.yml's e2e job leases Android devices from a simlock farm, as
# ios-maestro.yml's does simulators, and decides a run passed on the suite's
# report, not on its exit code alone: a command that exits 0 without running a test (a wrong
# selection, a swallowed exit code, a wrapper that never started the suite)
# must fail closed, and so must a stale report from an earlier run.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

WORKFLOW="$REPO_ROOT/.github/workflows/android-maestro.yml"

report() {
    local status="$1" executed="$2" failed="$3"
    printf '{"schemaVersion":"report-1","run":{"status":"%s","exitCode":0,"summary":{"discovered":%s,"selected":%s,"executed":%s,"passed":%s,"failed":%s,"flaky":0,"skipped":0}}}' \
        "$status" "$executed" "$executed" "$executed" "$((executed - failed))" "$failed"
}

# run_suite <command> [VAR=value ...] - runs the e2e run step with an unreachable farm.
run_suite() {
    local command="$1"
    shift
    dir="$(new_workflow_workspace "$WORKFLOW" e2e 'Run the e2e suite')"
    mkdir -p "$dir/work" && : > "$dir/work/app-release.apk"
    stub "$dir" curl 'exit 7'
    run_step "$dir" E2E_COMMAND="$command" E2E_APP_PATH="$dir/work/app-release.apk" E2E_APP_ID=com.example.app \
        E2E_TARGET=app E2E_WORKERS=2 E2E_RETRIES=0 E2E_SESSION=s E2E_SHADOW=false \
        SIMLOCK_URL=http://farm.invalid SIMLOCK_TOKEN=t "$@"
}

writes() {
    printf "mkdir -p .e2e && printf '%%s' '%s' > .e2e/report.json" "$1"
}

case_start 'a passing report with executed tests passes'
run_suite "$(writes "$(report passed 3 0)")"
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))" \
    && assert_contains "$(cat "$dir/summary")" '3 executed' 'summary'; then
    pass_case
fi

case_start 'exit 0 with no report fails closed'
run_suite 'true'
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$dir/log")" 'no report' 'error'; then
    pass_case
fi

case_start 'exit 0 with a report that executed nothing fails closed'
run_suite "$(writes "$(report passed 0 0)")"
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$dir/log")" 'executed no test' 'error'; then
    pass_case
fi

case_start 'exit 0 with a failing report fails closed'
run_suite "$(writes "$(report failed 3 1)")"
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$dir/log")" 'did not pass' 'error'; then
    pass_case
fi

case_start 'a report whose counts are not whole numbers fails closed'
for summary in '"executed":3,"failed":0.5' '"executed":"x","failed":0' '"executed":3,"failed":"1"'; do
    run_suite "$(writes "{\"run\":{\"status\":\"passed\",\"summary\":{${summary}}}}")"
    assert_equals 1 "$STEP_STATUS" "status for ${summary} ($(cat "$dir/log"))" || break
done
if [ "$STEP_STATUS" = 1 ] && assert_contains "$(cat "$dir/log")" 'no run status and summary' 'error'; then
    pass_case
fi

case_start 'a stale report from an earlier run does not count'
dir="$(new_workflow_workspace "$WORKFLOW" e2e 'Run the e2e suite')"
mkdir -p "$dir/work/.e2e" && : > "$dir/work/app-release.apk"
report passed 5 0 > "$dir/work/.e2e/report.json"
stub "$dir" curl 'exit 7'
run_step "$dir" E2E_COMMAND='true' E2E_APP_PATH="$dir/work/app-release.apk" E2E_APP_ID=com.example.app \
    E2E_TARGET=app E2E_WORKERS=2 E2E_RETRIES=0 E2E_SESSION=s E2E_SHADOW=false \
    SIMLOCK_URL=http://farm.invalid SIMLOCK_TOKEN=t
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$dir/log")" 'no report' 'error'; then
    pass_case
fi

case_start 'a failing command keeps its own exit status'
run_suite 'exit 2'
if assert_equals 2 "$STEP_STATUS" "status ($(cat "$dir/log"))"; then
    pass_case
fi

case_start 'the farm'"'"'s free Android devices are split across the targets, and the token never reaches argv'
dir="$(new_workflow_workspace "$WORKFLOW" e2e 'Run the e2e suite')"
mkdir -p "$dir/work" && : > "$dir/work/app-release.apk"
# shellcheck disable=SC2016 # expanded when the stub runs.
stub "$dir" curl 'printf "%s\n" "$*" > "$(dirname "$0")/../curl-args"; cat > /dev/null; printf "%s" "{\"capacity\":{\"ios\":{\"limit\":40,\"used\":0},\"android\":{\"limit\":12,\"used\":3,\"warm\":1}}}"'
run_step "$dir" E2E_COMMAND="$(writes "$(report passed 1 0)")" E2E_APP_PATH="$dir/work/app-release.apk" E2E_APP_ID=com.example.app \
    E2E_TARGET=app E2E_WORKERS=08 E2E_RETRIES=0 E2E_SESSION=s E2E_SHADOW=false \
    TEST_TARGETS='[{"name":"a"},{"name":"b"}]' SIMLOCK_URL=http://farm.invalid SIMLOCK_TOKEN=secret-token
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))" \
    && assert_contains "$(cat "$dir/log")" 'running 5 workers instead of 8' 'split notice' \
    && assert_not_contains "$(cat "$dir/curl-args")" 'secret-token' 'curl argv'; then
    pass_case
fi

VALIDATE='Validate the test framework'
validate() {
    dir="$(new_workflow_workspace "$WORKFLOW" detect "$VALIDATE")"
    run_step "$dir" TEST_FRAMEWORK=e2e E2E_DIR=e2e SIMLOCK_URL=http://farm.invalid HAS_SIMLOCK_TOKEN=true \
        E2E_WORKERS=2 E2E_RETRIES=1 ANDROID_DRIVER=avd ABI_KEY_SEGMENT=-abi-arm64-v8a "$@"
}

case_start 'detect accepts a complete e2e call'
validate
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))"; then pass_case; fi

case_start 'detect rejects a build without arm64-v8a for the arm64 farm'
validate ABI_KEY_SEGMENT=-abi-x86_64
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(cat "$dir/log")" "compiles only 'x86_64'" 'error'; then pass_case; fi

case_start 'detect accepts arm64-v8a beside x86_64, and every ABI the project declares'
validate ABI_KEY_SEGMENT=-abi-x86_64,arm64-v8a
first="$STEP_STATUS"
validate ABI_KEY_SEGMENT=''
if assert_equals '0 0' "$first $STEP_STATUS" "status ($(cat "$dir/log"))"; then pass_case; fi

case_start 'detect rejects e2e without the farm'
validate SIMLOCK_URL='' HAS_SIMLOCK_TOKEN=false
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$dir/log")" 'needs simlock-url' 'url error' \
    && assert_contains "$(cat "$dir/log")" 'needs the simlock-token secret' 'token error'; then
    pass_case
fi

case_start 'detect rejects e2e with a Maestro-only android-driver, but not both'
validate ANDROID_DRIVER=redroid
e2e_status="$STEP_STATUS"
validate TEST_FRAMEWORK=both ANDROID_DRIVER=redroid
if assert_equals '1 0' "$e2e_status $STEP_STATUS" 'status (e2e, both)'; then pass_case; fi

case_start 'detect rejects an unknown test-framework'
validate TEST_FRAMEWORK=detox
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(cat "$dir/log")" "got 'detox'" 'error'; then pass_case; fi

case_start 'the Maestro shards stop with test-framework e2e'
test_if="$(WORKFLOW="$WORKFLOW" python3 -c '
import os, yaml
print(yaml.safe_load(open(os.environ["WORKFLOW"]))["jobs"]["test"]["if"])')"
if assert_contains "$test_if" "inputs.test-framework != 'e2e'" 'test if'; then pass_case; fi

case_start 'detect hands the targets step the test framework, so an e2e-only call takes e2e-dir as its tests'
targets_env="$(WORKFLOW="$WORKFLOW" python3 -c '
import os, yaml
steps = yaml.safe_load(open(os.environ["WORKFLOW"]))["jobs"]["detect"]["steps"]
env = next(s for s in steps if s.get("id") == "targets")["env"]
print(env.get("TEST_FRAMEWORK"), env.get("E2E_DIR"))')"
# shellcheck disable=SC2016 # the literal expression the step's env must carry.
if assert_equals '${{ inputs.test-framework }} ${{ inputs.e2e-dir }}' "$targets_env" 'targets env'; then pass_case; fi

case_start 'detect rejects 00 workers'
validate E2E_WORKERS=00
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(cat "$dir/log")" 'at least 1' 'error'; then pass_case; fi

case_start 'cache-pass never records a pass from a shadow e2e suite'
condition="$(WORKFLOW="$WORKFLOW" python3 -c '
import os, yaml
print(yaml.safe_load(open(os.environ["WORKFLOW"]))["jobs"]["cache-pass"]["if"])')"
if assert_contains "$condition" "(inputs.test-framework != 'both' || (inputs.e2e-required && needs.e2e.result == 'success'))" 'cache-pass if'; then
    pass_case
fi

RELEASE='Release the devices the suite left leased'
release() {
    dir="$(new_workflow_workspace "$WORKFLOW" e2e "$RELEASE")"
    mkdir -p "$dir/work/.e2e"
    # shellcheck disable=SC2016 # expanded when the stub runs.
    stub "$dir" curl 'printf "%s\n" "$*" >> "$(dirname "$0")/../curl-args"; cat > /dev/null; printf 204'
    : > "$dir/curl-args"
}

case_start 'with no lease list nothing is released'
release
run_step "$dir" SIMLOCK_URL=http://farm.invalid SIMLOCK_TOKEN=secret-token
if assert_equals 0 "$STEP_STATUS" 'status' && assert_equals '' "$(cat "$dir/curl-args")" 'curl calls'; then pass_case; fi

case_start 'every listed lease is released, with the token off argv, and a hostile id is skipped'
release
printf '%s' '["abc123",{"id":"def456"},"../x",42]' > "$dir/work/.e2e/simlock-leases.json"
run_step "$dir" SIMLOCK_URL=http://farm.invalid/ SIMLOCK_TOKEN=secret-token
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))" \
    && assert_contains "$(cat "$dir/curl-args")" 'http://farm.invalid/v1/leases/abc123' 'first lease' \
    && assert_contains "$(cat "$dir/curl-args")" 'http://farm.invalid/v1/leases/def456' 'second lease' \
    && assert_not_contains "$(cat "$dir/curl-args")" '../x' 'hostile id' \
    && assert_not_contains "$(cat "$dir/curl-args")" 'secret-token' 'curl argv' \
    && assert_contains "$(cat "$dir/log")" 'Released lease abc123' 'log'; then
    pass_case
fi

case_start 'a malformed lease list warns and does not fail the job'
release
printf '%s' 'not json' > "$dir/work/.e2e/simlock-leases.json"
run_step "$dir" SIMLOCK_URL=http://farm.invalid SIMLOCK_TOKEN=t
if assert_equals 0 "$STEP_STATUS" 'status' && assert_contains "$(cat "$dir/log")" 'not a JSON array' 'warning'; then pass_case; fi

finish_suite
