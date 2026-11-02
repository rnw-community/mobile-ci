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

finish_suite
