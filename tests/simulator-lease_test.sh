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
    verify) exit "${SIMSLIM_VERIFY_STATUS:-0}" ;;
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

case_start "auto clones the host's verified mobile-ci-template device"
workspace="$(acquire_workspace)"
acquire "$workspace" devices-template.json TEMPLATE_STRATEGY='auto'
log="$(cat "$workspace/simctl-log")"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$log" "simslim verify 22222222-2222-2222-2222-222222222222 --profile" 'the template is verified before it is cloned' \
    && assert_contains "$log" "simctl clone 22222222-2222-2222-2222-222222222222" 'simctl log' \
    && assert_not_contains "$log" 'simctl create' 'simctl log' \
    && assert_equals "$TEMPLATE" "$(step_output "$workspace" template)" 'template output' \
    && assert_equals '' "$(step_output "$workspace" template-bake-name)" 'nothing left to bake'; then
    pass_case
fi

case_start 'auto names the template it will leave behind when the host has none'
workspace="$(acquire_workspace)"
acquire "$workspace" devices-no-template.json TEMPLATE_STRATEGY='auto'
log="$(cat "$workspace/simctl-log")"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$log" 'simctl create' 'simctl log' \
    && assert_not_contains "$log" 'simctl clone' 'simctl log' \
    && assert_equals "$TEMPLATE" "$(step_output "$workspace" template-bake-name)" 'template name to bake'; then
    pass_case
fi

case_start 'auto never clones a template of another runtime'
workspace="$(acquire_workspace)"
acquire "$workspace" devices-template-other-runtime.json TEMPLATE_STRATEGY='auto'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_not_contains "$(cat "$workspace/simctl-log")" 'simctl clone' 'simctl log' \
    && assert_equals "$TEMPLATE" "$(step_output "$workspace" template-bake-name)" 'template name to bake'; then
    pass_case
fi

case_start 'auto never clones a booted template'
workspace="$(acquire_workspace)"
acquire "$workspace" devices-template-booted.json TEMPLATE_STRATEGY='auto'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_not_contains "$(cat "$workspace/simctl-log")" 'simctl clone' 'simctl log'; then
    pass_case
fi

case_start 'a template that is not slim is neither cloned nor replaced'
workspace="$(acquire_workspace)"
acquire "$workspace" devices-template.json TEMPLATE_STRATEGY='auto' SIMSLIM_VERIFY_STATUS='1'
log="$(cat "$workspace/simctl-log")"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$log" 'simctl create' 'simctl log' \
    && assert_not_contains "$log" 'simctl clone' 'simctl log' \
    && assert_equals '' "$(step_output "$workspace" template-bake-name)" 'no second template for this type and runtime' \
    && assert_contains "$(cat "$workspace/log")" '::warning::' 'the stale template is reported'; then
    pass_case
fi

case_start 'auto together with an explicit template-device fails closed'
workspace="$(acquire_workspace)"
acquire "$workspace" devices-template.json TEMPLATE_STRATEGY='auto' TEMPLATE_DEVICE='some-template'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'set exactly one of them' 'error message'; then
    pass_case
fi

case_start 'auto without a slim profile fails closed'
workspace="$(acquire_workspace)"
acquire "$workspace" devices-template.json TEMPLATE_STRATEGY='auto' SLIM_PROFILE=''
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'requires slim-profile' 'error message'; then
    pass_case
fi

case_start 'an unknown template-strategy fails closed'
workspace="$(acquire_workspace)"
acquire "$workspace" devices-template.json TEMPLATE_STRATEGY='maybe'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" "must be 'none' or 'auto'" 'error message'; then
    pass_case
fi

case_start 'an explicitly named template is still cloned by name'
workspace="$(acquire_workspace)"
acquire "$workspace" devices-template.json TEMPLATE_DEVICE="$TEMPLATE"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/simctl-log")" 'simctl clone 22222222-2222-2222-2222-222222222222' 'simctl log' \
    && assert_equals "$TEMPLATE" "$(step_output "$workspace" template)" 'template output'; then
    pass_case
fi

# --- the slim step bakes the template it was told to leave behind ------------

slim_workspace() {
    local dir
    dir="$(new_workspace "$ACTION" "Verify, repair and measure the lease's slim profile")"
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
        BOOT_TIMEOUT_SECONDS='5' \
        "$@"
}

case_start 'a lease with nothing to bake leaves no device behind'
workspace="$(slim_workspace)"
slim "$workspace" devices-no-template.json TEMPLATE_BAKE_NAME=''
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_not_contains "$(cat "$workspace/simctl-log")" 'simctl clone' 'simctl log'; then
    pass_case
fi

case_start 'baking shuts the lease down, clones it, and boots the lease again'
workspace="$(slim_workspace)"
slim "$workspace" devices-no-template.json TEMPLATE_BAKE_NAME="$TEMPLATE"
log="$(cat "$workspace/simctl-log")"
expected="simctl shutdown $CREATED_UDID
simctl clone $CREATED_UDID $TEMPLATE
simctl shutdown $CLONED_UDID
simctl boot $CREATED_UDID"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$log" "$expected" 'simctl call order' \
    && assert_contains "$log" "simctl bootstatus $CREATED_UDID -b" 'the lease is waited for again'; then
    pass_case
fi

case_start 'baking never creates a second template for the same type and runtime'
workspace="$(slim_workspace)"
slim "$workspace" devices-template.json TEMPLATE_BAKE_NAME="$TEMPLATE"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_not_contains "$(cat "$workspace/simctl-log")" 'simctl clone' 'simctl log' \
    && assert_contains "$(cat "$workspace/log")" 'never baking a second one' 'reason'; then
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
