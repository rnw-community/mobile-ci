#!/usr/bin/env bash
# ios-maestro.yml's e2e job decides a run passed on the suite's report, not on
# its exit code alone: a command that exits 0 without running a test (a wrong
# selection, a swallowed exit code, a wrapper that never started the suite)
# must fail closed, and so must a stale report from an earlier run.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

WORKFLOW="$REPO_ROOT/.github/workflows/ios-maestro.yml"

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
    mkdir -p "$dir/work/Base.app"
    stub "$dir" curl 'exit 7'
    run_step "$dir" E2E_COMMAND="$command" E2E_APP_PATH="$dir/work/Base.app" E2E_APP_ID=com.example.app \
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

case_start 'a stale report from an earlier run does not count'
dir="$(new_workflow_workspace "$WORKFLOW" e2e 'Run the e2e suite')"
mkdir -p "$dir/work/Base.app" "$dir/work/.e2e"
report passed 5 0 > "$dir/work/.e2e/report.json"
stub "$dir" curl 'exit 7'
run_step "$dir" E2E_COMMAND='true' E2E_APP_PATH="$dir/work/Base.app" E2E_APP_ID=com.example.app \
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

case_start 'the farm'"'"'s free simulators are split across the targets, and the token never reaches argv'
dir="$(new_workflow_workspace "$WORKFLOW" e2e 'Run the e2e suite')"
mkdir -p "$dir/work/Base.app"
stub "$dir" curl 'printf "%s\n" "$*" > "$(dirname "$0")/../curl-args"; cat > /dev/null; printf "%s" "{\"capacity\":{\"ios\":{\"limit\":12,\"used\":3,\"warm\":1}}}"'
run_step "$dir" E2E_COMMAND="$(writes "$(report passed 1 0)")" E2E_APP_PATH="$dir/work/Base.app" E2E_APP_ID=com.example.app \
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
        E2E_WORKERS=2 E2E_RETRIES=1 IOS_DRIVER=local IOS_SIMULATOR_ARCHS=arm64 "$@"
}

case_start 'detect accepts a complete e2e call'
validate
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))"; then pass_case; fi

case_start 'detect rejects an x86_64 slice for the arm64 farm'
validate IOS_SIMULATOR_ARCHS=x86_64
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(cat "$dir/log")" 'arm64' 'error'; then pass_case; fi

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

RELEASE='Release the simulators the suite left leased'
release() {
    dir="$(new_workflow_workspace "$WORKFLOW" e2e "$RELEASE")"
    mkdir -p "$dir/work/.e2e"
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
