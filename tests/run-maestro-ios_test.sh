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
        SIMULATOR_UDID=AAAAAAAA-0000-0000-0000-000000000001 \
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

lane_calls() {
    grep -F -- "--udid $2 " "$1/calls" || true
}

case_start 'simulator-count defaults to 1'
if assert_equals '1' "$(action_input_default "$ACTION" simulator-count)" 'simulator-count default'; then
    pass_case
fi

case_start 'a single simulator never passes --udid'
workspace="$(prepare_shard)"
invoke_shard "$workspace" MAESTRO_REUSE_DRIVER=true SIMULATOR_UDIDS=AAAAAAAA-0000-0000-0000-000000000001
if assert_not_contains "$(cat "$workspace/calls" 2>/dev/null || true)" '--udid' 'maestro argv' \
    && assert_contains "$(cat "$workspace/summary")" '### Maestro flow timing (shard 0)' 'summary heading'; then
    pass_case
fi

prepare_lanes() {
    local dir
    dir="$(prepare_shard)"
    rm -f "$dir/work/flows/fail.flow.yaml"
    printf 'appId: x\n' > "$dir/work/flows/b.flow.yaml"
    printf 'appId: x\n' > "$dir/work/flows/c.flow.yaml"
    printf 'appId: x\n' > "$dir/work/flows/d.flow.yaml"
    stub "$dir" memory_pressure 'echo "System-wide memory free percentage: 42%"'
    stub "$dir" vm_stat 'printf "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages occupied by compressor:                   128.\n"'
    printf '%s\n' "$dir"
}

LANE_A=AAAAAAAA-0000-0000-0000-000000000001
LANE_B=BBBBBBBB-0000-0000-0000-000000000002

case_start 'two simulators split the flows into interleaved lanes, each on its own UDID, port and debug output'
workspace="$(prepare_lanes)"
# shellcheck disable=SC2016 # the command is expanded when the step runs it.
invoke_shard "$workspace" MAESTRO_REUSE_DRIVER=true SIMULATOR_UDIDS="$LANE_A $LANE_B" \
    PRE_FLOW_COMMAND='printf "%s %s %s\n" "$FLOW_NAME" "$SIMULATOR_UDID" "$SIMULATOR_LANE" >> "$PRE_FLOW_CALLS"; echo "LANE_SEEN=$SIMULATOR_LANE" >> "$MAESTRO_FLOW_ENV_FILE"' \
    PRE_FLOW_CALLS="$workspace/pre-flow-calls"
lane_a="$(lane_calls "$workspace" "$LANE_A")"
lane_b="$(lane_calls "$workspace" "$LANE_B")"
port_a="$(sed -nE 's/.*--driver-host-port ([^ ]+).*/\1/p' <<< "$lane_a" | sort -u)"
port_b="$(sed -nE 's/.*--driver-host-port ([^ ]+).*/\1/p' <<< "$lane_b" | sort -u)"
debug_a="$(sed -nE 's/.*--debug-output ([^ ]+).*/\1/p' <<< "$lane_a" | sort -u)"
debug_b="$(sed -nE 's/.*--debug-output ([^ ]+).*/\1/p' <<< "$lane_b" | sort -u)"
summary="$(cat "$workspace/summary")"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 6 "$(grep -c . "$workspace/calls")" 'priming twice and four flows' \
    && assert_equals 'prime.yaml a.flow.yaml c.flow.yaml' "$(grep -oE '[a-z]+(\.flow)?\.yaml$' <<< "$lane_a" | tr '\n' ' ' | sed 's/ $//')" 'lane 0 flows' \
    && assert_equals 'prime.yaml b.flow.yaml d.flow.yaml' "$(grep -oE '[a-z]+(\.flow)?\.yaml$' <<< "$lane_b" | tr '\n' ' ' | sed 's/ $//')" 'lane 1 flows' \
    && assert_equals 1 "$(grep -c . <<< "$port_a")" 'one port in lane 0' \
    && assert_equals 1 "$(grep -c . <<< "$port_b")" 'one port in lane 1' \
    && assert_not_contains "$port_b" "$port_a" 'lane ports' \
    && assert_equals 1 "$(grep -c . <<< "$debug_a")" 'one debug dir in lane 0' \
    && assert_not_contains "$debug_b" "$debug_a" 'lane debug dirs' \
    && assert_equals "a.flow.yaml $LANE_A 0|b.flow.yaml $LANE_B 1|c.flow.yaml $LANE_A 0|d.flow.yaml $LANE_B 1" \
        "$(sort "$workspace/pre-flow-calls" | tr '\n' '|' | sed 's/|$//')" 'pre-flow-command UDID and lane' \
    && assert_contains "$lane_b" '-e LANE_SEEN=1' 'lane 1 per-flow env' \
    && assert_not_contains "$lane_a" 'LANE_SEEN=1' 'lane 0 per-flow env' \
    && assert_contains "$summary" "### Maestro flow timing (shard 0, lane 0 on $LANE_A)" 'lane 0 timing table' \
    && assert_contains "$summary" "### Maestro flow timing (shard 0, lane 1 on $LANE_B)" 'lane 1 timing table' \
    && assert_contains "$summary" '| d.flow.yaml |' 'lane 1 timing row' \
    && assert_contains "$summary" 'Minimum memory_pressure free: 42%. Peak compressor: 2 MB' 'memory guardrail' \
    && assert_contains "$(cat "$workspace/log")" '[lane 1] ' 'lane log prefix'; then
    pass_case
fi

case_start 'a failing lane fails the step while the other lane still runs every flow'
workspace="$(prepare_lanes)"
printf 'appId: x\n' > "$workspace/work/flows/b.flow.yaml"
mv "$workspace/work/flows/b.flow.yaml" "$workspace/work/flows/fail.flow.yaml"
invoke_shard "$workspace" MAESTRO_REUSE_DRIVER=true SIMULATOR_UDIDS="$LANE_A $LANE_B"
lane_a="$(lane_calls "$workspace" "$LANE_A")"
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$lane_a" 'd.flow.yaml' 'lane 0 ran its last flow' \
    && assert_contains "$(cat "$workspace/log")" "Lane 1 on simulator $LANE_B failed." 'lane failure' \
    && assert_contains "$(lane_calls "$workspace" "$LANE_B")" 'recover.yaml' 'lane 1 recovery'; then
    pass_case
fi

case_start 'lanes on UDIDs hashing to one port base still get distinct driver ports'
workspace="$(prepare_lanes)"
invoke_shard "$workspace" MAESTRO_REUSE_DRIVER=true SIMULATOR_UDIDS="$LANE_A $LANE_A"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 2 "$(driver_ports "$workspace" | grep -c .)" 'distinct driver ports'; then
    pass_case
fi

case_start 'more simulators than flows leave the extra lanes idle'
workspace="$(prepare_lanes)"
invoke_shard "$workspace" MAESTRO_REUSE_DRIVER=false PRE_RUN_FLOW='' FLOW_RECOVERY_FLOW='' \
    FLOWS_EXCLUDE_PATTERN='[bcd].flow.yaml' SIMULATOR_UDIDS="$LANE_A $LANE_B"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 1 "$(grep -c . "$workspace/calls")" 'one invocation' \
    && assert_contains "$(cat "$workspace/log")" 'Lane 1 has no flows' 'idle lane'; then
    pass_case
fi

case_start 'a failing lane flow is staged as its own debug bundle in the shard artifact'
workspace="$(prepare_lanes)"
mv "$workspace/work/flows/b.flow.yaml" "$workspace/work/flows/fail.flow.yaml"
# shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
stub "$workspace" maestro 'printf "%s\n" "$*" >> "$MAESTRO_CALLS"
debug_dir="$(sed -nE "s/.*--debug-output ([^ ]+).*/\1/p" <<< "$*")"
mkdir -p "$debug_dir/.maestro/tests/$(date +%s%N)"
case "$*" in *fail.flow.yaml*) exit 1 ;; esac'
invoke_shard "$workspace" MAESTRO_REUSE_DRIVER=false SIMULATOR_UDIDS="$LANE_A $LANE_B" PRE_RUN_FLOW='' FLOW_RETRIES=0
shard_status="$STEP_STATUS"
extract_step_script "$ACTION" 'Capture final simulator state' > "$workspace/step.sh"
stub "$workspace" xcrun 'exit 0'
run_step "$workspace" SHARD_OUTCOME=failure \
    MAESTRO_DEBUG_SCRATCH_DIR="$(sed -n 's/^MAESTRO_DEBUG_SCRATCH_DIR=//p' "$workspace/github-env")" \
    MAESTRO_DEBUG_MANIFEST_FILE="$(sed -n 's/^MAESTRO_DEBUG_MANIFEST_FILE=//p' "$workspace/github-env")" \
    SIMULATOR_UDIDS="$LANE_A $LANE_B" \
    MAESTRO_DEBUG_OUTPUT_DIRECTORY="$workspace/artifacts"
if assert_equals 1 "$shard_status" 'shard status' \
    && assert_equals 0 "$STEP_STATUS" 'capture status' \
    && assert_equals 'fail.flow.yaml.tar.gz' "$(find "$workspace/artifacts/maestro-debug" -type f -exec basename {} \; 2>/dev/null | tr '\n' ' ' | sed 's/ $//')" 'staged bundles' \
    && assert_contains "$(tar -tzf "$workspace/artifacts/maestro-debug/fail.flow.yaml.tar.gz")" '.maestro/lanes/1/.maestro/tests/' 'bundle holds lane 1 output'; then
    pass_case
fi

BOOT_STEP='Boot iOS Simulator'

prepare_boot() {
    local dir
    dir="$(new_workspace "$ACTION" "$BOOT_STEP")"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" xcrun 'printf "%s\n" "$*" >> "$XCRUN_CALLS"
case "$*" in
  "simctl list devices available") printf "== Devices ==\n-- iOS 26.4 --\n    iPhone 17 Pro (AAAAAAAA-0000-0000-0000-000000000001) (Shutdown) \n%s" "$EXTRA_DEVICES" ;;
  "simctl clone "*) echo CCCCCCCC-0000-0000-0000-000000000003 ;;
esac'
    printf '%s\n' "$dir"
}

case_start 'simulator-count 2 clones a distinctly named second device and boots both'
workspace="$(prepare_boot)"
run_step "$workspace" XCRUN_CALLS="$workspace/calls" GITHUB_ENV="$workspace/github-env" \
    SIMULATOR_DEVICE='iPhone 17 Pro' SIMULATOR_COUNT=2 EXTRA_DEVICES=''
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/calls")" 'simctl clone AAAAAAAA-0000-0000-0000-000000000001 iPhone 17 Pro #2' 'clone' \
    && assert_contains "$(cat "$workspace/calls")" 'simctl bootstatus CCCCCCCC-0000-0000-0000-000000000003 -b' 'second boot' \
    && assert_contains "$(cat "$workspace/github-env")" 'SIMULATOR_UDID=AAAAAAAA-0000-0000-0000-000000000001' 'SIMULATOR_UDID' \
    && assert_contains "$(cat "$workspace/github-env")" 'SIMULATOR_UDIDS=AAAAAAAA-0000-0000-0000-000000000001 CCCCCCCC-0000-0000-0000-000000000003' 'SIMULATOR_UDIDS'; then
    pass_case
fi

case_start 'an existing "<name> #2" device is reused instead of cloned'
workspace="$(prepare_boot)"
run_step "$workspace" XCRUN_CALLS="$workspace/calls" GITHUB_ENV="$workspace/github-env" \
    SIMULATOR_DEVICE='iPhone 17 Pro' SIMULATOR_COUNT=2 \
    EXTRA_DEVICES='    iPhone 17 Pro #2 (BBBBBBBB-0000-0000-0000-000000000002) (Shutdown) '
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_not_contains "$(cat "$workspace/calls")" 'simctl clone' 'xcrun argv' \
    && assert_contains "$(cat "$workspace/github-env")" 'SIMULATOR_UDIDS=AAAAAAAA-0000-0000-0000-000000000001 BBBBBBBB-0000-0000-0000-000000000002' 'SIMULATOR_UDIDS'; then
    pass_case
fi

case_start 'simulator-count 1 boots only the selected device'
workspace="$(prepare_boot)"
run_step "$workspace" XCRUN_CALLS="$workspace/calls" GITHUB_ENV="$workspace/github-env" \
    SIMULATOR_DEVICE='iPhone 17 Pro' SIMULATOR_COUNT=1 EXTRA_DEVICES=''
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 1 "$(grep -c 'simctl boot ' "$workspace/calls")" 'boots' \
    && assert_contains "$(cat "$workspace/github-env")" 'SIMULATOR_UDIDS=AAAAAAAA-0000-0000-0000-000000000001' 'SIMULATOR_UDIDS'; then
    pass_case
fi

case_start 'a simulator-count that is not a positive integer fails closed'
workspace="$(prepare_boot)"
run_step "$workspace" XCRUN_CALLS="$workspace/calls" GITHUB_ENV="$workspace/github-env" \
    SIMULATOR_DEVICE='iPhone 17 Pro' SIMULATOR_COUNT=0 EXTRA_DEVICES=''
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" "simulator-count '0' must be a positive integer" 'error message'; then
    pass_case
fi

case_start 'pre-test-command runs once per simulator with that lane UDID'
workspace="$(new_workspace "$ACTION" 'Run pre-test command')"
# shellcheck disable=SC2016 # the command is expanded when the step runs it.
run_step "$workspace" SIMULATOR_UDID="$LANE_A" SIMULATOR_UDIDS="$LANE_A $LANE_B" \
    PRE_TEST_COMMAND='echo "$SIMULATOR_UDID $SIMULATOR_LANE" >> "$PRE_TEST_CALLS"' PRE_TEST_CALLS="$workspace/pre-test-calls"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals "$LANE_A 0|$LANE_B 1" "$(tr '\n' '|' < "$workspace/pre-test-calls" | sed 's/|$//')" 'pre-test-command calls'; then
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
