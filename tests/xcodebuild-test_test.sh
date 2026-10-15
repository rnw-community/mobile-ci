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

# --- Slimming the parallel-testing worker clones (#161) ----------------------
# Xcode clones the leased simulator once per worker into its own device set, and
# a clone never carries simslim's UDID-keyed disable overrides. `simslim watch`
# slims each clone no-reboot as it boots; these cases pin when it runs, how its
# profile resolves, how it is stopped, and when its failure fails the job.

DECIDE_STEP='Decide whether to slim the parallel-testing workers'
START_STEP='Start simslim watch for the parallel-testing workers'
STOP_STEP='Stop simslim watch and report the slimmed workers'
LEASE_UDID='11111111-1111-1111-1111-111111111111'
CLONE_A='AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA'
CLONE_B='BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB'

# Sets `workspace`; run_step's STEP_STATUS would be lost in a subshell, so these
# helpers are deliberately not command substitutions.
decide() {
    workspace="$(new_workspace "$ACTION" "$DECIDE_STEP")"
    run_step "$workspace" GITHUB_ACTION_PATH="$REPO_ROOT/actions/xcodebuild-test" "$@"
}

# A python stand-in for `simslim watch`: it records its argv, prints the banner
# the real CLI prints once its profile parsed, and runs until SIGINT, the only
# signal simslim treats as a clean stop. SIMSLIM_WATCH_BEHAVIOUR=exit makes it
# fail at start the way a rejected profile does.
stub_watch() {
    local dir="$1"
    cat > "$dir/stub-bin/simslim" <<'PYTHON'
#!/usr/bin/env python3
import os
import signal
import sys
import time

with open(os.environ['SIMSLIM_ARGV'], 'w', encoding='utf-8') as handle:
    handle.write('\n'.join(sys.argv[1:]) + '\n')
if os.environ.get('SIMSLIM_WATCH_BEHAVIOUR') == 'exit':
    print('simslim: unknown category "nope"', file=sys.stderr, flush=True)
    sys.exit(1)


def stop(*_):
    with open(os.environ['SIMSLIM_STOPPED'], 'w', encoding='utf-8') as handle:
        handle.write('SIGINT\n')
    sys.exit(0)


signal.signal(signal.SIGINT, stop)
print('Watching device sets [default, testing]; slimming each simulator no-reboot as it boots. Ctrl-C to stop.', file=sys.stderr, flush=True)
deadline = time.time() + 60
while time.time() < deadline:
    time.sleep(0.1)
PYTHON
    chmod +x "$dir/stub-bin/simslim"
}

start_watch() {
    workspace="$(new_workspace "$ACTION" "$START_STEP")"
    stub_watch "$workspace"
    run_step "$workspace" SIMSLIM_ARGV="$workspace/simslim-argv" SIMSLIM_STOPPED="$workspace/stopped" \
        SLIM_PROFILE="$REPO_ROOT/profiles/ci.json" "$@"
}

recorded_pid() {
    local state
    state="$(step_output "$1" state-dir)"
    if [ -n "$state" ]; then
        cat "$state/watch.pid" 2>/dev/null || true
    fi
}

alive() {
    if kill -0 "$1" 2>/dev/null; then echo true; else echo false; fi
}

reap() {
    local pid
    pid="$(recorded_pid "$1")"
    [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
}

# A stop-step workspace whose state dir holds the watch log the start step
# would have left behind.
prepare_stop() {
    local log_lines="$1" state
    workspace="$(new_workspace "$ACTION" "$STOP_STEP")"
    stub_watch "$workspace"
    state="$workspace/runner-temp/watch-state"
    mkdir -p "$state"
    printf '%s\n' "$log_lines" > "$state/watch.log"
}

# Launches the stand-in exactly the way the start step launches simslim, so the
# stop step meets a real, live `simslim watch` process.
launch_stand_in() {
    SIMSLIM_ARGV="$workspace/simslim-argv" SIMSLIM_STOPPED="$workspace/stopped" \
        "$workspace/stub-bin/simslim" watch --profile "$REPO_ROOT/profiles/ci.json" > /dev/null 2>&1 < /dev/null &
    stand_in=$!
    echo "$stand_in" > "$workspace/runner-temp/watch-state/watch.pid"
    local tries=0
    while [ ! -s "$workspace/simslim-argv" ] && [ "$tries" -lt 50 ]; do
        sleep 0.1
        tries=$((tries + 1))
    done
}

record_dead_pid() {
    (exit 0) &
    local dead=$!
    wait "$dead" || true
    echo "$dead" > "$workspace/runner-temp/watch-state/watch.pid"
}

stop_watch() {
    run_step "$workspace" STATE_DIR="$workspace/runner-temp/watch-state" \
        DESTINATION_ID="$LEASE_UDID" "$@"
}

BANNER='Watching device sets [default, testing]; slimming each simulator no-reboot as it boots. Ctrl-C to stop.'
TWO_CLONES_LOG="$BANNER
watch: slimming $LEASE_UDID (set default)
watch: slimmed $LEASE_UDID
watch: slimming $CLONE_A (set testing)
watch: $CLONE_A: stopping 146 daemons
watch: slimmed $CLONE_A
watch: slimming $CLONE_B (set testing)
watch: slimmed $CLONE_B"

case_start 'slim-workers defaults to auto and slim-profile to empty'
if assert_equals 'auto' "$(action_input_default "$ACTION" slim-workers)" 'slim-workers default' \
    && assert_equals '' "$(action_input_default "$ACTION" slim-profile)" 'slim-profile default'; then
    pass_case
fi

case_start 'simslim is pinned to the same version and digest simulator-lease installs'
lease_action="$REPO_ROOT/actions/simulator-lease/action.yml"
if assert_equals "$(action_input_default "$lease_action" simslim-version)" "$(action_input_default "$ACTION" simslim-version)" 'simslim-version' \
    && assert_equals "$(action_input_default "$lease_action" simslim-sha256)" "$(action_input_default "$ACTION" simslim-sha256)" 'simslim-sha256'; then
    pass_case
fi

case_start "auto with parallel-testing YES and 'bundled' watches with this release's profiles/ci.json"
decide SLIM_WORKERS='auto' PARALLEL_TESTING='YES' SLIM_PROFILE='bundled'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'true' "$(step_output "$workspace" enabled)" 'enabled' \
    && assert_equals "$REPO_ROOT/profiles/ci.json" "$(step_output "$workspace" profile)" 'resolved profile'; then
    pass_case
fi

case_start 'a repository-relative profile resolves against the workspace to an absolute path'
workspace="$(new_workspace "$ACTION" "$DECIDE_STEP")"
mkdir -p "$workspace/work/ci"
printf '{}\n' > "$workspace/work/ci/slim.json"
run_step "$workspace" GITHUB_ACTION_PATH="$REPO_ROOT/actions/xcodebuild-test" \
    SLIM_WORKERS='auto' PARALLEL_TESTING='YES' SLIM_PROFILE='ci/slim.json'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals "$workspace/work/ci/slim.json" "$(step_output "$workspace" profile)" 'resolved profile'; then
    pass_case
fi

case_start 'auto with parallel-testing NO starts no watch'
decide SLIM_WORKERS='auto' PARALLEL_TESTING='NO' SLIM_PROFILE='bundled'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'false' "$(step_output "$workspace" enabled)" 'enabled'; then
    pass_case
fi

case_start 'auto without a slim profile starts no watch'
decide SLIM_WORKERS='auto' PARALLEL_TESTING='YES' SLIM_PROFILE=''
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'false' "$(step_output "$workspace" enabled)" 'enabled'; then
    pass_case
fi

case_start "slim-workers 'false' starts no watch even with parallel testing and a profile"
decide SLIM_WORKERS='false' PARALLEL_TESTING='YES' SLIM_PROFILE='bundled'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'false' "$(step_output "$workspace" enabled)" 'enabled'; then
    pass_case
fi

case_start "slim-workers 'true' with parallel-testing NO fails closed"
decide SLIM_WORKERS='true' PARALLEL_TESTING='NO' SLIM_PROFILE='bundled'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" '::error::' 'error annotation' \
    && assert_contains "$(cat "$workspace/log")" 'no worker clones' 'error message'; then
    pass_case
fi

case_start "slim-workers 'true' without a slim profile fails closed"
decide SLIM_WORKERS='true' PARALLEL_TESTING='YES' SLIM_PROFILE=''
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'slim-profile' 'error message'; then
    pass_case
fi

case_start 'a slim-workers value outside auto/true/false fails closed'
decide SLIM_WORKERS='yes' PARALLEL_TESTING='YES' SLIM_PROFILE='bundled'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" "must be 'auto', 'true' or 'false'" 'error message'; then
    pass_case
fi

case_start 'a slim profile that does not exist fails closed, even under auto'
decide SLIM_WORKERS='auto' PARALLEL_TESTING='YES' SLIM_PROFILE='missing/profile.json'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'does not exist' 'error message'; then
    pass_case
fi

case_start 'the start step launches simslim watch with the profile, detached, and records its pid'
start_watch SLIM_WORKERS='auto'
pid="$(recorded_pid "$workspace")"
argv="$(cat "$workspace/simslim-argv" 2>/dev/null || true)"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'true' "$(step_output "$workspace" started)" 'started' \
    && assert_contains "$(step_output "$workspace" state-dir)" "$workspace/runner-temp/" 'state dir is under RUNNER_TEMP' \
    && assert_equals 'true' "$(alive "${pid:-0}")" 'the watch outlives the step' \
    && assert_equals "watch
--profile
$REPO_ROOT/profiles/ci.json" "$argv" 'simslim argv'; then
    pass_case
fi
reap "$workspace"

case_start "a watch that exits at start fails the step under slim-workers 'true'"
start_watch SLIM_WORKERS='true' SIMSLIM_WATCH_BEHAVIOUR='exit'
log="$(cat "$workspace/log")"
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$log" '::error::' 'error annotation' \
    && assert_contains "$log" 'unknown category' "simslim's own error is surfaced"; then
    pass_case
fi

case_start 'a watch that exits at start only warns under auto, and the tests still run'
start_watch SLIM_WORKERS='auto' SIMSLIM_WATCH_BEHAVIOUR='exit'
log="$(cat "$workspace/log")"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$log" '::warning::' 'warning annotation' \
    && assert_contains "$log" 'stock' 'the warning says the workers run stock' \
    && assert_equals 'false' "$(step_output "$workspace" started)" 'started'; then
    pass_case
fi

case_start 'the stop step interrupts the recorded watch and counts the clones it slimmed, not the lease'
prepare_stop "$TWO_CLONES_LOG"
launch_stand_in
stop_watch SLIM_WORKERS='auto' STARTED='true' TEST_OUTCOME='success'
summary="$(cat "$workspace/summary")"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'SIGINT' "$(cat "$workspace/stopped" 2>/dev/null || true)" 'the watch was stopped with SIGINT' \
    && assert_equals 'false' "$(alive "$stand_in")" 'the watch is gone' \
    && assert_contains "$summary" 'Worker clones slimmed: 2' 'summary count' \
    && assert_contains "$summary" "$CLONE_A" 'summary names a clone' \
    && assert_not_contains "$(grep -F 'Worker clones slimmed' "$workspace/summary" || true)" "$LEASE_UDID" 'the lease is not counted as a clone'; then
    pass_case
fi
kill -KILL "$stand_in" 2>/dev/null || true

case_start "a watch that died before the stop fails the job under slim-workers 'true'"
prepare_stop "$TWO_CLONES_LOG"
record_dead_pid
stop_watch SLIM_WORKERS='true' STARTED='true' TEST_OUTCOME='success'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'exited before the test run ended' 'error message'; then
    pass_case
fi

case_start 'a watch that died before the stop only warns under auto'
prepare_stop "$TWO_CLONES_LOG"
record_dead_pid
stop_watch SLIM_WORKERS='auto' STARTED='true' TEST_OUTCOME='success'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" '::warning::' 'warning annotation' \
    && assert_contains "$(cat "$workspace/summary")" 'Worker clones slimmed: 2' 'the log is still summarised'; then
    pass_case
fi

case_start 'a recorded pid now owned by another process is never signalled'
prepare_stop "$TWO_CLONES_LOG"
sleep 30 &
stranger=$!
echo "$stranger" > "$workspace/runner-temp/watch-state/watch.pid"
stop_watch SLIM_WORKERS='auto' STARTED='true' TEST_OUTCOME='success'
if assert_equals 'true' "$(alive "$stranger")" 'the unrelated process survives' \
    && assert_contains "$(cat "$workspace/log")" 'exited before the test run ended' 'treated as an early exit'; then
    pass_case
fi
kill -KILL "$stranger" 2>/dev/null || true

case_start "a green run with no clone slimmed fails under slim-workers 'true'"
prepare_stop "$BANNER
watch: slimming $LEASE_UDID (set default)
watch: slimmed $LEASE_UDID"
launch_stand_in
stop_watch SLIM_WORKERS='true' STARTED='true' TEST_OUTCOME='success'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'slimmed no worker clone' 'error message'; then
    pass_case
fi
kill -KILL "$stand_in" 2>/dev/null || true

case_start 'a green run with no clone slimmed only warns under auto'
prepare_stop "$BANNER"
launch_stand_in
stop_watch SLIM_WORKERS='auto' STARTED='true' TEST_OUTCOME='success'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" '::warning::' 'warning annotation' \
    && assert_contains "$(cat "$workspace/summary")" 'Worker clones slimmed: 0' 'summary count'; then
    pass_case
fi
kill -KILL "$stand_in" 2>/dev/null || true

case_start 'a watch that never started is not reported again by the stop step'
prepare_stop "simslim: unknown category \"nope\""
stop_watch SLIM_WORKERS='auto' STARTED='false' TEST_OUTCOME='success'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'never started' 'the stop step says why it has nothing to stop' \
    && assert_not_contains "$(cat "$workspace/log")" '::warning::' 'no duplicate warning'; then
    pass_case
fi

finish_suite
