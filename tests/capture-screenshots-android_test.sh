#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"
ACTION="$REPO_ROOT/actions/capture-screenshots-android/action.yml"

prepare_capture() {
    local dir
    dir=$(new_workspace "$ACTION" 'Run screenshot capture matrix')
    # shellcheck disable=SC2016
    stub "$dir" adb 'printf "%s\n" "$*" >> "$ADB_CALLS"
case "$*" in
  *"cmd uimode night"*) rm -f "$DEMO_READY" "$CLOCK_READY" ;;
  *"settings put global sysui_tuner_demo_on 1"*) [ "${BROKEN_SETTING:-false}" != true ] || exit 1; touch "$DEMO_READY" ;;
  *"dumpsys activity service"*)
    if [ -f "$DEMO_READY" ] && [ "${DEMO_UNAVAILABLE:-false}" != true ]; then
      printf "isDemoModeAllowed=true\nisInDemoMode=true\n"
    else
      printf "isDemoModeAllowed=false\nisInDemoMode=false\n"
    fi ;;
  *"command clock"*) [ -f "$DEMO_READY" ] || exit 1; touch "$CLOCK_READY" ;;
  *"exec-out screencap"*)
    if [ "$STATUS_BAR_OVERRIDE" = true ] && [ ! -f "$CLOCK_READY" ]; then exit 1; fi
    printf png ;;
esac'
    stub "$dir" sleep 'exit 0'
    printf '%s\n' "$dir"
}

invoke_capture() {
    local dir="$1"
    shift
    run_step "$dir" ANDROID_SERIAL=emulator-5554 APK_PATH=app.apk APP_ID=com.example \
        SCENES_JSON='[{"name":"home","deepLink":"app://home"}]' SCREENSHOTS_DIR='' \
        CAPTURE_LOCALES=en CAPTURE_APPEARANCES='light,dark' SEED_COMMAND='' \
        SETTLE_SECONDS=0 MAESTRO_ENV='' LOCALE_ENV_JSON='' MAESTRO_CONFIG='' \
        DEVICE_SLUG=phone OUTPUT_DIR="$dir/output" STATUS_BAR_OVERRIDE=true \
        ADB_CALLS="$dir/adb-calls" DEMO_READY="$dir/demo-ready" CLOCK_READY="$dir/clock-ready" "$@"
}

case_start 'demo status is reapplied after each appearance change and seed hook before capture'
workspace=$(prepare_capture)
# shellcheck disable=SC2016
invoke_capture "$workspace" SEED_COMMAND='rm -f "$DEMO_READY" "$CLOCK_READY"'
if assert_equals 0 "$STEP_STATUS" 'capture status' \
    && assert_equals 2 "$(find "$workspace/output" -name '*.png' | wc -l | tr -d ' ')" 'captured cells' \
    && assert_equals 2 "$(grep -c 'command clock' "$workspace/adb-calls" || true)" 'clock applied per cell'; then
    pass_case
fi

case_start 'unavailable SystemUI demo mode fails instead of producing misleading screenshots'
workspace=$(prepare_capture)
invoke_capture "$workspace" DEMO_UNAVAILABLE=true
if assert_equals 1 "$STEP_STATUS" 'capture status' \
    && assert_not_contains "$(cat "$workspace/adb-calls")" 'exec-out screencap' 'no unchecked capture'; then
    pass_case
fi

case_start 'a failed settings command cannot be hidden by subsequent successful broadcasts'
workspace=$(prepare_capture)
invoke_capture "$workspace" BROKEN_SETTING=true
if assert_equals 1 "$STEP_STATUS" 'capture status' \
    && assert_not_contains "$(cat "$workspace/adb-calls")" 'exec-out screencap' 'no unchecked capture'; then
    pass_case
fi

case_start 'status-bar-override false captures without requiring SystemUI demo support'
workspace=$(prepare_capture)
invoke_capture "$workspace" STATUS_BAR_OVERRIDE=false DEMO_UNAVAILABLE=true
if assert_equals 0 "$STEP_STATUS" 'capture status' \
    && assert_not_contains "$(cat "$workspace/adb-calls")" 'sysui_tuner_demo_on' 'demo mode is not changed'; then
    pass_case
fi

finish_suite
