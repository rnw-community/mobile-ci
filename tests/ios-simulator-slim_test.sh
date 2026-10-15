#!/usr/bin/env bash
# run-maestro-ios and capture-screenshots-ios boot a simulator the host owns,
# and slim it by default (rnw-community/mobile-ci#146): a stock simulator in a
# 7 GiB VM leaves the guest compressing instead of testing. Both actions share
# the same verify/repair/measure step, so every case runs against both.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

STEP='Verify simulator slim profile and required features'
UDID='cccccccc-cccc-cccc-cccc-cccccccccccc'
PROFILE="$REPO_ROOT/profiles/ci.json"

slim_workspace() {
    local dir
    dir="$(new_workspace "$1" "$STEP")"
    : > "$dir/calls"
    # shellcheck disable=SC2016 # the stub bodies are expanded when the stubs run.
    stub "$dir" simslim '
printf "simslim %s\n" "$*" >> "$CALLS"
case "$1" in
    verify)
        if [ -n "${VERIFY_FAIL_ONCE:-}" ] && [ ! -e "$VERIFY_FAIL_ONCE" ]; then
            : > "$VERIFY_FAIL_ONCE"
            exit 1
        fi
        ;;
    measure) [ -n "${MEASURE_FAIL:-}" ] && exit 1; echo "footprint 900 MB" ;;
esac
exit 0'
    # shellcheck disable=SC2016
    stub "$dir" xcrun 'printf "xcrun %s\n" "$*" >> "$CALLS"'
    printf '%s\n' "$dir"
}

run_slim() {
    local dir="$1"
    shift
    run_step "$dir" \
        CALLS="$dir/calls" \
        SIMULATOR_UDID="$UDID" \
        SIMULATOR_SLIM_PROFILE="$PROFILE" \
        SIMULATOR_SLIM_REPAIR='true' \
        SIMULATOR_REQUIRES='' \
        "$@"
}

for action in run-maestro-ios capture-screenshots-ios; do
    ACTION="$REPO_ROOT/actions/$action/action.yml"

    case_start "$action: slims by default with the bundled profile and in-job repair"
    if assert_equals 'bundled' "$(action_input_default "$ACTION" simulator-slim-profile)" 'simulator-slim-profile default' \
        && assert_equals 'true' "$(action_input_default "$ACTION" simulator-slim-repair)" 'simulator-slim-repair default'; then
        pass_case
    fi

    case_start "$action: a slim simulator is measured into the step summary and left alone"
    dir="$(slim_workspace "$ACTION")"
    run_slim "$dir"
    if assert_equals 0 "$STEP_STATUS" 'step status' \
        && assert_not_contains "$(cat "$dir/calls")" 'simslim on' 'no repair' \
        && assert_contains "$(cat "$dir/summary")" 'footprint 900 MB' 'step summary'; then
        pass_case
    fi

    case_start "$action: a drifted simulator is repaired, verified again and measured"
    dir="$(slim_workspace "$ACTION")"
    run_slim "$dir" VERIFY_FAIL_ONCE="$dir/verify-failed-once"
    if assert_equals 0 "$STEP_STATUS" 'step status' \
        && assert_contains "$(cat "$dir/calls")" "simslim on $UDID --profile $PROFILE" 'repair' \
        && assert_contains "$(cat "$dir/summary")" 'footprint 900 MB' 'step summary'; then
        pass_case
    fi

    case_start "$action: a failed measurement warns and does not fail the shard"
    dir="$(slim_workspace "$ACTION")"
    run_slim "$dir" MEASURE_FAIL=1
    if assert_equals 0 "$STEP_STATUS" 'step status' \
        && assert_contains "$(cat "$dir/log")" "::warning::'simslim measure' failed" 'warning'; then
        pass_case
    fi
done

finish_suite
