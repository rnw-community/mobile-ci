#!/usr/bin/env bash
# run-maestro-ios runs `maestro test` once per flow. Issue #165: every one of
# those invocations paid a fresh XCTest driver start on a random port, and the
# simulator animated every transition the flows waited out.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/run-maestro-ios/action.yml"
SHARD_STEP='Run Maestro shard'
REDUCE_MOTION_STEP='Set simulator Reduce Motion'

prepare_shard() {
    local dir
    dir="$(new_workspace "$ACTION" "$SHARD_STEP")"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" maestro 'printf "%s\n" "$*" >> "$MAESTRO_CALLS"; case "$*" in *fail.flow.yaml*) exit 1 ;; esac'
    mkdir -p "$dir/work/flows"
    printf 'appId: x\n' > "$dir/work/flows/a.flow.yaml"
    printf 'appId: x\n' > "$dir/work/flows/fail.flow.yaml"
    printf 'appId: x\n' > "$dir/work/flows/prime.yaml"
    printf 'appId: x\n' > "$dir/work/flows/recover.yaml"
    printf '%s\n' "$dir"
}

invoke_shard() {
    local dir="$1"
    shift
    run_step "$dir" MAESTRO_CALLS="$dir/calls" \
        GITHUB_ENV="$dir/github-env" GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 \
        APP_ID=com.example.app FLOWS_DIR=flows FLOWS_MAX_DEPTH=1 \
        FLOWS_NAME_PATTERN='*.flow.yaml' FLOWS_EXCLUDE_PATTERN='' SHARD_MANIFEST_DIR='' \
        SHARD_INDEX=0 SHARD_COUNT=1 PRE_RUN_FLOW=flows/prime.yaml \
        FLOW_RECOVERY_FLOW=flows/recover.yaml FLOW_RETRIES=1 PRE_FLOW_COMMAND='' \
        MAESTRO_ENV='' MAESTRO_CONFIG='' \
        "$@"
}

driver_ports() {
    sed -nE 's/.*--driver-host-port ([^ ]+).*/\1/p' "$1/calls" | sort -u
}

case_start 'maestro-version defaults to 2.10.0'
if assert_equals '2.10.0' "$(action_input_default "$ACTION" maestro-version)" 'maestro-version default'; then
    pass_case
fi

case_start 'maestro-reuse-driver defaults to true'
if assert_equals 'true' "$(action_input_default "$ACTION" maestro-reuse-driver)" 'maestro-reuse-driver default'; then
    pass_case
fi

case_start 'reuse passes one fixed driver port and --no-reinstall-driver to every invocation'
workspace="$(prepare_shard)"
invoke_shard "$workspace" MAESTRO_REUSE_DRIVER=true
calls="$(cat "$workspace/calls" 2>/dev/null || true)"
ports="$(driver_ports "$workspace")"
if assert_equals 1 "$STEP_STATUS" 'step status (fail.flow.yaml fails)' \
    && assert_equals 5 "$(grep -c . <<< "$calls")" 'priming, a, two fail.flow.yaml attempts and one recovery' \
    && assert_equals 5 "$(grep -c -- '--no-reinstall-driver' <<< "$calls")" 'invocations skipping the driver reinstall' \
    && assert_equals 5 "$(grep -c -- '--driver-host-port [0-9][0-9]*' <<< "$calls")" 'invocations pinning the driver port' \
    && assert_equals 1 "$(grep -c . <<< "$ports")" 'distinct driver ports' \
    && assert_contains "$(cat "$workspace/summary")" '| fail.flow.yaml |' 'per-flow timing row'; then
    pass_case
fi

case_start 'maestro-reuse-driver false leaves Maestro its per-invocation driver start'
workspace="$(prepare_shard)"
invoke_shard "$workspace" MAESTRO_REUSE_DRIVER=false
calls="$(cat "$workspace/calls" 2>/dev/null || true)"
if assert_equals 5 "$(grep -c . <<< "$calls")" 'invocations' \
    && assert_not_contains "$calls" '--driver-host-port' 'maestro argv' \
    && assert_not_contains "$calls" '--no-reinstall-driver' 'maestro argv'; then
    pass_case
fi

case_start 'a maestro-reuse-driver value that is neither true nor false fails closed'
workspace="$(prepare_shard)"
invoke_shard "$workspace" MAESTRO_REUSE_DRIVER=yes
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" "maestro-reuse-driver 'yes' must be 'true' or 'false'" 'error message' \
    && assert_equals 'false' "$([ -e "$workspace/calls" ] && echo true || echo false)" 'maestro was not invoked'; then
    pass_case
fi

prepare_reduce_motion() {
    local dir
    dir="$(new_workspace "$ACTION" "$REDUCE_MOTION_STEP")"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" xcrun 'printf "%s\n" "$*" >> "$XCRUN_CALLS"'
    printf '%s\n' "$dir"
}

case_start 'simulator-reduce-motion defaults to false'
if assert_equals 'false' "$(action_input_default "$ACTION" simulator-reduce-motion)" 'simulator-reduce-motion default'; then
    pass_case
fi

case_start 'simulator-reduce-motion true writes the Accessibility preference on the booted simulator'
workspace="$(prepare_reduce_motion)"
run_step "$workspace" XCRUN_CALLS="$workspace/calls" SIMULATOR_UDID=UDID-1 SIMULATOR_REDUCE_MOTION=true
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'simctl spawn UDID-1 defaults write com.apple.Accessibility ReduceMotionEnabled -bool true' \
        "$(cat "$workspace/calls" 2>/dev/null || true)" 'xcrun argv'; then
    pass_case
fi

case_start 'simulator-reduce-motion false leaves the simulator untouched'
workspace="$(prepare_reduce_motion)"
run_step "$workspace" XCRUN_CALLS="$workspace/calls" SIMULATOR_UDID=UDID-1 SIMULATOR_REDUCE_MOTION=false
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'false' "$([ -e "$workspace/calls" ] && echo true || echo false)" 'xcrun was not invoked'; then
    pass_case
fi

case_start 'a simulator-reduce-motion value that is neither true nor false fails closed'
workspace="$(prepare_reduce_motion)"
run_step "$workspace" XCRUN_CALLS="$workspace/calls" SIMULATOR_UDID=UDID-1 SIMULATOR_REDUCE_MOTION=1
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" "simulator-reduce-motion '1' must be 'true' or 'false'" 'error message'; then
    pass_case
fi

finish_suite
