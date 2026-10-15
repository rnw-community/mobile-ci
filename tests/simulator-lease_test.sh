#!/usr/bin/env bash
# simulator-lease's acquire step decides which device the tests run on, and its
# slim step decides what is left behind for the next job on the host. Both are
# exercised here against the fixtures/simctl listings with a stubbed xcrun and
# simslim, so the real jq filters and the real template naming rule are what
# gets tested.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/simulator-lease/action.yml"
FIXTURES="$REPO_ROOT/fixtures/simctl"
IPAD='iPad Pro 11-inch (M4)'
TEMPLATE='mobile-ci-template-ipad-pro-11-inch-m4-ios-26-0'
CREATED_UDID='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
CLONED_UDID='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'

stub_xcrun() {
    local dir="$1"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" xcrun '
printf "%s\n" "$*" >> "$SIMCTL_LOG"
case "$*" in
    "simctl list devicetypes -j") cat "$SIMCTL_FIXTURES/devicetypes.json" ;;
    "simctl list runtimes -j") cat "$SIMCTL_FIXTURES/runtimes.json" ;;
    "simctl list devices -j") cat "$SIMCTL_DEVICES" ;;
    "simctl create "*) printf "%s\n" "$SIMCTL_CREATED_UDID" ;;
    "simctl clone "*) printf "%s\n" "$SIMCTL_CLONED_UDID" ;;
esac
exit 0'
}

stub_simslim() {
    local dir="$1"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" simslim '
printf "simslim %s\n" "$*" >> "$SIMCTL_LOG"
case "$1" in
    verify)
        if [ -n "${SIMSLIM_VERIFY_FAIL_ONCE:-}" ] && [ ! -e "$SIMSLIM_VERIFY_FAIL_ONCE" ]; then
            : > "$SIMSLIM_VERIFY_FAIL_ONCE"
            exit 1
        fi
        exit 0
        ;;
    measure) echo "footprint 900 MB" ;;
esac
exit 0'
}

acquire_workspace() {
    local dir
    dir="$(new_workspace "$ACTION" 'Acquire an isolated simulator')"
    stub_xcrun "$dir"
    stub_simslim "$dir"
    : > "$dir/simctl-log"
    printf '%s\n' "$dir"
}

acquire() {
    local dir="$1" devices="$2"
    shift 2
    run_step "$dir" \
        SIMCTL_LOG="$dir/simctl-log" \
        SIMCTL_FIXTURES="$FIXTURES" \
        SIMCTL_DEVICES="$FIXTURES/$devices" \
        SIMCTL_CREATED_UDID="$CREATED_UDID" \
        SIMCTL_CLONED_UDID="$CLONED_UDID" \
        DEVICE_TYPE="$IPAD" \
        RUNTIME='latest' \
        NAME_PREFIX='mobile-ci-lease' \
        TEMPLATE_DEVICE='' \
        TEMPLATE_STRATEGY='none' \
        SLIM_PROFILE="$REPO_ROOT/profiles/ci.json" \
        SLIM_REPAIR='true' \
        LEASE_FILE_INPUT="$dir/lease.json" \
        BOOT_TIMEOUT_SECONDS='5' \
        "$@"
}

case_start 'template-strategy defaults to none, so nothing is cloned unless the caller asks'
workspace="$(acquire_workspace)"
acquire "$workspace" devices-template.json
if assert_equals 'none' "$(action_input_default "$ACTION" template-strategy)" 'template-strategy default' \
    && assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/simctl-log")" 'simctl create' 'simctl log' \
    && assert_not_contains "$(cat "$workspace/simctl-log")" 'simctl clone' 'simctl log' \
    && assert_equals '' "$(step_output "$workspace" template)" 'template output'; then
    pass_case
fi

case_start 'a lease with a slim profile is left shut down for the slim step to boot once, already slim'
workspace="$(acquire_workspace)"
acquire "$workspace" devices-no-template.json
log="$(cat "$workspace/simctl-log")"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$log" 'simctl create' 'simctl log' \
    && assert_not_contains "$log" 'simctl boot' 'no boot before the profile is applied' \
    && assert_equals 'false' "$(step_output "$workspace" booted)" 'booted output'; then
    pass_case
fi

case_start 'a lease without a slim profile is booted by acquire'
workspace="$(acquire_workspace)"
acquire "$workspace" devices-no-template.json SLIM_PROFILE=''
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/simctl-log")" "simctl bootstatus $CREATED_UDID -b" 'simctl log' \
    && assert_equals 'true' "$(step_output "$workspace" booted)" 'booted output'; then
    pass_case
fi

case_start 'with slim-repair false the lease is booted as it is, for the slim step to verify'
workspace="$(acquire_workspace)"
acquire "$workspace" devices-no-template.json SLIM_REPAIR='false'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/simctl-log")" "simctl boot $CREATED_UDID" 'simctl log' \
    && assert_equals 'true' "$(step_output "$workspace" booted)" 'booted output'; then
    pass_case
fi

case_start 'auto is deprecated: it neither clones a host template nor leaves one behind'
workspace="$(acquire_workspace)"
acquire "$workspace" devices-template.json TEMPLATE_STRATEGY='auto'
log="$(cat "$workspace/simctl-log")"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$log" 'simctl create' 'simctl log' \
    && assert_not_contains "$log" 'simctl clone' 'simctl log' \
    && assert_equals '' "$(step_output "$workspace" template)" 'template output' \
    && assert_contains "$(cat "$workspace/log")" "template-strategy 'auto' is deprecated" 'deprecation notice'; then
    pass_case
fi

case_start 'a lease may not be named from the reserved template namespace'
workspace="$(acquire_workspace)"
acquire "$workspace" devices-no-template.json NAME_PREFIX='mobile-ci-template-job'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'reserved' 'error message' \
    && assert_not_contains "$(cat "$workspace/simctl-log")" 'simctl create' 'no device was created'; then
    pass_case
fi

case_start 'an unknown template-strategy fails closed'
workspace="$(acquire_workspace)"
acquire "$workspace" devices-template.json TEMPLATE_STRATEGY='maybe'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" "must be 'none' or 'auto'" 'error message'; then
    pass_case
fi

case_start 'an explicitly named template is still cloned by name, and slimmed before its first boot'
workspace="$(acquire_workspace)"
acquire "$workspace" devices-template.json TEMPLATE_DEVICE="$TEMPLATE"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/simctl-log")" 'simctl clone 22222222-2222-2222-2222-222222222222' 'simctl log' \
    && assert_not_contains "$(cat "$workspace/simctl-log")" 'simctl boot' 'simctl log' \
    && assert_equals "$TEMPLATE" "$(step_output "$workspace" template)" 'template output'; then
    pass_case
fi

# --- the slim step slims a shut-down lease with a single boot -----------------

slim_workspace() {
    local dir
    dir="$(new_workspace "$ACTION" 'Slim, verify and measure the lease')"
    stub_xcrun "$dir"
    stub_simslim "$dir"
    : > "$dir/simctl-log"
    printf '%s\n' "$dir"
}

slim() {
    local dir="$1" devices="$2"
    shift 2
    run_step "$dir" \
        HOME="$dir/home" \
        SIMCTL_LOG="$dir/simctl-log" \
        SIMCTL_FIXTURES="$FIXTURES" \
        SIMCTL_DEVICES="$FIXTURES/$devices" \
        SIMCTL_CREATED_UDID="$CREATED_UDID" \
        SIMCTL_CLONED_UDID="$CLONED_UDID" \
        SLIM_PROFILE="$REPO_ROOT/profiles/ci.json" \
        SLIM_REPAIR='true' \
        SIMULATOR_UDID="$CREATED_UDID" \
        TEMPLATE_CLONED_FROM='' \
        LEASE_BOOTED='false' \
        BOOT_TIMEOUT_SECONDS='5' \
        "$@"
}

case_start 'a shut-down lease is slimmed by simslim on, then waited for and verified'
workspace="$(slim_workspace)"
slim "$workspace" devices-no-template.json
log="$(cat "$workspace/simctl-log")"
expected="simslim on $CREATED_UDID --profile $REPO_ROOT/profiles/ci.json
simctl bootstatus $CREATED_UDID -b
simslim verify $CREATED_UDID --profile $REPO_ROOT/profiles/ci.json"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$log" "$expected" 'call order' \
    && assert_not_contains "$log" 'simctl boot ' 'simslim on boots the lease itself' \
    && assert_equals 'true' "$(step_output "$workspace" slimmed)" 'slimmed output'; then
    pass_case
fi

case_start 'a shut-down lease that still does not verify after simslim on fails the job'
workspace="$(slim_workspace)"
slim "$workspace" devices-no-template.json SIMSLIM_VERIFY_FAIL_ONCE="$workspace/verify-failed-once"
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" "does not match" 'error message'; then
    pass_case
fi

case_start 'a booted lease that fails verify is repaired with simslim on and verified again'
workspace="$(slim_workspace)"
slim "$workspace" devices-template.json LEASE_BOOTED='true' TEMPLATE_CLONED_FROM="$TEMPLATE" \
    SIMSLIM_VERIFY_FAIL_ONCE="$workspace/verify-failed-once"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/simctl-log")" "simslim on $CREATED_UDID --profile" 'the lease is repaired in-job' \
    && assert_not_contains "$(cat "$workspace/log")" '::warning::' 'a stock clone is expected, not a stale template' \
    && assert_not_contains "$(cat "$workspace/simctl-log")" "simctl delete" 'the template is never replaced automatically'; then
    pass_case
fi

case_start 'with slim-repair false a stock clone fails the job and says clones never inherit overrides'
workspace="$(slim_workspace)"
slim "$workspace" devices-template.json LEASE_BOOTED='true' TEMPLATE_CLONED_FROM="$TEMPLATE" \
    SLIM_REPAIR='false' SIMSLIM_VERIFY_FAIL_ONCE="$workspace/verify-failed-once"
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_not_contains "$(cat "$workspace/simctl-log")" 'simslim on' 'no repair' \
    && assert_contains "$(cat "$workspace/log")" 'a clone never inherits the disable overrides of its template' 'the error names the cause'; then
    pass_case
fi

case_start 'a booted lease that is already slim is not touched'
workspace="$(slim_workspace)"
slim "$workspace" devices-no-template.json LEASE_BOOTED='true'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_not_contains "$(cat "$workspace/simctl-log")" "simslim on" 'no repair' \
    && assert_not_contains "$(cat "$workspace/simctl-log")" 'simctl clone' 'no template is baked'; then
    pass_case
fi

# --- release never deletes a template ---------------------------------------

release_workspace() {
    local dir
    dir="$(new_workspace "$ACTION" 'Release the leased simulator')"
    stub_xcrun "$dir"
    : > "$dir/simctl-log"
    printf '%s\n' "$dir"
}

release() {
    local dir="$1" devices="$2" lease="$3"
    run_step "$dir" \
        SIMCTL_LOG="$dir/simctl-log" \
        SIMCTL_FIXTURES="$FIXTURES" \
        SIMCTL_DEVICES="$FIXTURES/$devices" \
        LEASE_FILE_INPUT="$lease"
}

case_start 'release deletes the device its lease file names'
workspace="$(release_workspace)"
printf '{"udid":"11111111-1111-1111-1111-111111111111","name":"iPhone 17 Pro"}' > "$workspace/lease.json"
release "$workspace" devices-no-template.json "$workspace/lease.json"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/simctl-log")" 'simctl delete 11111111-1111-1111-1111-111111111111' 'simctl log'; then
    pass_case
fi

case_start 'release refuses to delete a host template'
workspace="$(release_workspace)"
printf '{"udid":"22222222-2222-2222-2222-222222222222","name":"a-lease"}' > "$workspace/lease.json"
release "$workspace" devices-template.json "$workspace/lease.json"
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_not_contains "$(cat "$workspace/simctl-log")" 'simctl delete' 'simctl log' \
    && assert_contains "$(cat "$workspace/log")" 'never deleted' 'error message'; then
    pass_case
fi

finish_suite
