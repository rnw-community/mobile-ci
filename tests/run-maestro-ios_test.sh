#!/usr/bin/env bash
# run-maestro-ios runs `maestro test` once per flow. Issue #165: every one of
# those invocations paid a fresh XCTest driver start on a random port, and the
# simulator animated every transition the flows waited out.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"
# shellcheck source=tests/lib/exclude-pattern-cases.sh
. "$REPO_ROOT/tests/lib/exclude-pattern-cases.sh"
# shellcheck source=tests/lib/maestro-tag-junit-cases.sh
. "$REPO_ROOT/tests/lib/maestro-tag-junit-cases.sh"
# shellcheck source=tests/lib/shard-timings-cases.sh
. "$REPO_ROOT/tests/lib/shard-timings-cases.sh"

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
        SIMULATOR_UDID=AAAAAAAA-0000-0000-0000-000000000001 \
        APP_ID=com.example.app FLOWS_DIR=flows FLOWS_MAX_DEPTH=1 \
        FLOWS_NAME_PATTERN='*.flow.yaml' FLOWS_EXCLUDE_PATTERN='' SHARD_MANIFEST_DIR='' SHARD_TIMINGS_FILE='' \
        SHARD_INDEX=0 SHARD_COUNT=1 PRE_RUN_FLOW=flows/prime.yaml \
        FLOW_RECOVERY_FLOW=flows/recover.yaml FLOW_RETRIES=1 PRE_FLOW_COMMAND='' \
        MAESTRO_ENV='' MAESTRO_CONFIG='' INCLUDE_TAGS='' EXCLUDE_TAGS='' JUNIT_REPORT=false MAESTRO_SCRIPTS_DIR="$REPO_ROOT/scripts/maestro" \
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

case_start 'the driver port is derived from the simulator UDID, so shards on one host differ'
workspace="$(prepare_shard)"
invoke_shard "$workspace" MAESTRO_REUSE_DRIVER=true
first_port="$(driver_ports "$workspace")"
workspace="$(prepare_shard)"
invoke_shard "$workspace" MAESTRO_REUSE_DRIVER=true
repeat_port="$(driver_ports "$workspace")"
workspace="$(prepare_shard)"
invoke_shard "$workspace" MAESTRO_REUSE_DRIVER=true SIMULATOR_UDID=BBBBBBBB-0000-0000-0000-000000000002
other_port="$(driver_ports "$workspace")"
if assert_equals "$first_port" "$repeat_port" 'port for the same UDID' \
    && assert_not_contains "$other_port" "$first_port" 'port for another UDID' \
    && assert_equals 1 "$([ "$first_port" -ge 20000 ] && [ "$first_port" -le 30098 ] && echo 1 || echo 0)" "port $first_port within [20000, 30098]"; then
    pass_case
fi

case_start 'a port already held on 127.0.0.1 is skipped for the next free one'
perl -MIO::Socket::INET -e '$s = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => shift, Listen => 1) or die; sleep 30' "$first_port" &
holder_pid=$!
sleep 1
workspace="$(prepare_shard)"
invoke_shard "$workspace" MAESTRO_REUSE_DRIVER=true
held_port="$(driver_ports "$workspace")"
kill "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
if assert_equals 0 "$([ "$held_port" -gt "$first_port" ] && [ "$held_port" -le $((first_port + 99)) ] && echo 0 || echo 1)" "port $held_port after the held $first_port"; then
    pass_case
fi

case_start 'reuse without a booted simulator UDID fails closed'
workspace="$(prepare_shard)"
invoke_shard "$workspace" MAESTRO_REUSE_DRIVER=true SIMULATOR_UDID=''
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'SIMULATOR_UDID is not set' 'error message' \
    && assert_equals 'false' "$([ -e "$workspace/calls" ] && echo true || echo false)" 'maestro was not invoked'; then
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

BOOT_STEP='Boot iOS Simulator'
LEASED_UDID='6F1D2A8C-3B4E-4F7A-9C2D-8E5B1A7F3C90'

# The stubbed xcrun lists two available iPhones and records every other call,
# so a case can tell which device was booted and whether name matching ran.
prepare_boot() {
    local dir
    dir="$(new_workspace "$ACTION" "$BOOT_STEP")"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" xcrun '
case "$*" in
    "simctl list devices available")
        printf -- "-- iOS 26.2 --\n"
        printf "    iPhone 17 (11111111-2222-3333-4444-555555555555) (Shutdown)\n"
        printf "    iPhone 17 Pro (%s) (Booted)\n" "$LEASED_UDID"
        ;;
    *) printf "%s\n" "$*" >> "$XCRUN_CALLS" ;;
esac'
    printf '%s\n' "$dir"
}

boot() {
    local dir="$1"
    shift
    run_step "$dir" XCRUN_CALLS="$dir/calls" LEASED_UDID="$LEASED_UDID" SIMULATOR_DEVICE='' SIMULATOR_UDID_INPUT='' "$@"
}

case_start 'simulator-udid defaults to empty'
if assert_contains "$(python3 -c 'import sys, yaml; print(" ".join(yaml.safe_load(open(sys.argv[1]))["inputs"]))' "$ACTION")" simulator-udid 'simulator-udid declared' \
    && assert_equals '' "$(action_input_default "$ACTION" simulator-udid)" 'simulator-udid default'; then
    pass_case
fi

case_start 'simulator-udid boots exactly the leased device, never a name match'
workspace="$(prepare_boot)"
boot "$workspace" SIMULATOR_UDID_INPUT="$LEASED_UDID"
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_contains "$(cat "$workspace/calls")" "simctl bootstatus $LEASED_UDID -b" 'waited on the leased device' \
    && assert_not_contains "$(cat "$workspace/calls")" '11111111-2222-3333-4444-555555555555' 'other device untouched' \
    && assert_equals "SIMULATOR_UDID=$LEASED_UDID" "$(cat "$workspace/env")" 'exported udid' \
    && assert_not_contains "$(cat "$workspace/log")" 'last-available heuristic' 'no name heuristic'; then
    pass_case
fi

case_start 'a simulator-udid that is not an available simulator fails closed'
workspace="$(prepare_boot)"
boot "$workspace" SIMULATOR_UDID_INPUT='AAAAAAAA-0000-0000-0000-000000000009'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" "::error::simulator-udid 'AAAAAAAA-0000-0000-0000-000000000009' is not among this host's available simulators" 'error' \
    && assert_equals '' "$(cat "$workspace/env")" 'nothing exported'; then
    pass_case
fi

case_start 'simulator-udid and simulator-device together fail closed'
workspace="$(prepare_boot)"
boot "$workspace" SIMULATOR_UDID_INPUT="$LEASED_UDID" SIMULATOR_DEVICE='iPhone 17'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" '::error::Set simulator-udid or simulator-device, not both' 'error'; then
    pass_case
fi

case_start 'a malformed simulator-udid fails closed'
workspace="$(prepare_boot)"
boot "$workspace" SIMULATOR_UDID_INPUT='booted'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" "::error::simulator-udid 'booted' is not a simulator UDID" 'error'; then
    pass_case
fi

case_start 'without simulator-udid the named device is still matched by name'
workspace="$(prepare_boot)"
boot "$workspace" SIMULATOR_DEVICE='iPhone 17'
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals 'SIMULATOR_UDID=11111111-2222-3333-4444-555555555555' "$(cat "$workspace/env")" 'exported udid'; then
    pass_case
fi

prepare_exclude() {
    local dir
    dir="$(new_workspace "$ACTION" "$SHARD_STEP")"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" maestro 'printf "%s\n" "$*" >> "$MAESTRO_CALLS"'
    write_exclude_fixture_flows "$dir/work/flows"
    printf '%s\n' "$dir"
}

invoke_exclude() {
    invoke_shard "$1" MAESTRO_REUSE_DRIVER=false PRE_RUN_FLOW='' FLOW_RECOVERY_FLOW='' \
        FLOWS_EXCLUDE_PATTERN="$2"
}

run_exclude_pattern_cases flow

prepare_tagged() {
    local dir
    dir="$(new_workspace "$ACTION" "$SHARD_STEP")"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" maestro 'printf "%s\n" "$*" >> "$MAESTRO_CALLS"; case "$*" in *fail.flow.yaml*) exit 1 ;; esac'
    printf '%s\n' "$dir"
}

invoke_tagged() {
    local dir="$1"
    shift
    invoke_shard "$dir" MAESTRO_REUSE_DRIVER=false PRE_RUN_FLOW='' FLOW_RECOVERY_FLOW='' FLOW_RETRIES=0 \
        JUNIT_REPORT=true MAESTRO_DEBUG_OUTPUT_DIRECTORY="$dir/artifacts" "$@"
}

run_maestro_tag_junit_cases
run_shard_timings_cases

finish_suite
