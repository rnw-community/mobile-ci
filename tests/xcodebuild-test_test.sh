#!/usr/bin/env bash
# xcodebuild-test's test step decides what -parallel-testing-enabled the run
# gets. Issue #155: the default 'YES' made Xcode boot 'Clone 1 of <lease>' and
# run the whole suite there, on a VM that has memory for one simulator.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/xcodebuild-test/action.yml"
STEP='Run the tests without rebuilding'

prepare() {
    local dir
    dir="$(new_workspace "$ACTION" "$STEP")"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" xcodebuild 'printf "%s\n" "$@" > "$XCODEBUILD_ARGV"'
    printf '%s\n' "$dir"
}

invoke() {
    local dir="$1"
    shift
    run_step "$dir" XCODEBUILD_ARGV="$dir/argv" \
        COMMON_ARGS="$(printf -- '-scheme\nPony\n')" \
        SELECTED_TESTS='' \
        RESULT_BUNDLE_PATH='build/TestResults.xcresult' \
        WORKING_DIRECTORY='.' \
        "$@"
}

case_start 'parallel-testing defaults to NO'
if assert_equals 'NO' "$(action_input_default "$ACTION" parallel-testing)" 'parallel-testing default'; then
    pass_case
fi

case_start "the default run passes -parallel-testing-enabled NO and no worker count"
workspace="$(prepare)"
invoke "$workspace" \
    PARALLEL_TESTING="$(action_input_default "$ACTION" parallel-testing)" \
    PARALLEL_TESTING_WORKER_COUNT=''
argv="$(cat "$workspace/argv" 2>/dev/null || true)"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$argv" '-parallel-testing-enabled
NO' 'xcodebuild argv' \
    && assert_not_contains "$argv" '-parallel-testing-worker-count' 'xcodebuild argv'; then
    pass_case
fi

case_start "parallel-testing YES without a worker count fails closed"
workspace="$(prepare)"
invoke "$workspace" PARALLEL_TESTING='YES' PARALLEL_TESTING_WORKER_COUNT=''
log="$(cat "$workspace/log")"
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$log" '::error::' 'error annotation' \
    && assert_contains "$log" 'Clone 1 of' 'the clone is named' \
    && assert_contains "$log" '7 GiB' 'the memory budget is named' \
    && assert_contains "$log" '6x12' 'the profile YES belongs on is named' \
    && assert_equals 'false' "$([ -e "$workspace/argv" ] && echo true || echo false)" 'xcodebuild was not invoked'; then
    pass_case
fi

case_start "parallel-testing YES with an explicit worker count is allowed"
workspace="$(prepare)"
invoke "$workspace" PARALLEL_TESTING='YES' PARALLEL_TESTING_WORKER_COUNT='2'
argv="$(cat "$workspace/argv" 2>/dev/null || true)"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$argv" '-parallel-testing-enabled
YES' 'xcodebuild argv' \
    && assert_contains "$argv" '-parallel-testing-worker-count
2' 'xcodebuild argv'; then
    pass_case
fi

case_start "a parallel-testing value that is neither YES nor NO fails closed"
workspace="$(prepare)"
invoke "$workspace" PARALLEL_TESTING='yes' PARALLEL_TESTING_WORKER_COUNT=''
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" "must be 'YES' or 'NO'" 'error message'; then
    pass_case
fi

case_start "a worker count with parallel-testing NO fails closed instead of being ignored"
workspace="$(prepare)"
invoke "$workspace" PARALLEL_TESTING='NO' PARALLEL_TESTING_WORKER_COUNT='2'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'is ignored by xcodebuild' 'error message'; then
    pass_case
fi

case_start "a non-numeric worker count fails closed before xcodebuild runs"
workspace="$(prepare)"
invoke "$workspace" PARALLEL_TESTING='NO' PARALLEL_TESTING_WORKER_COUNT='two'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'must be a positive integer' 'error message' \
    && assert_equals 'false' "$([ -e "$workspace/argv" ] && echo true || echo false)" 'xcodebuild was not invoked'; then
    pass_case
fi

finish_suite
