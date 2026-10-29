#!/usr/bin/env bash
# Issue #192: a `launchApp: clearState: true` relaunch can land while
# ActivityManager is still processing the previous process's death, so it
# hits the `startProcessLocked ... with non-zero startSeq` path and never forks
# the app: the activity is created, no process binds to it, and the flow times
# out on a blank screen. run-shard.sh settles the app's process death before
# every attempt, classifies a failed attempt whose events buffer shows the race
# as infrastructure, retries it on its own infra-retries budget, and keeps the
# events buffer as evidence.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

RUN_SHARD="$REPO_ROOT/actions/run-maestro-android/scripts/run-shard.sh"
ACTION="$REPO_ROOT/actions/run-maestro-android/action.yml"
APP=com.reactnativepaymentsexample
MARKER=1760592000

write_events() {
    local file="$1" shape="$2"
    printf '%s\n' '10-16 05:17:00.000   524   550 I am_wtf  : [0,524,system_server,-1,ActivityManager,startProcessLocked processName:com.reactnativepaymentsexample with non-zero startSeq:12]' > "$file.before"
    {
        case "$shape" in
            startseq)
                printf '%s\n' \
                    '10-16 05:19:05.123   524   550 I am_kill : [0,5796,com.reactnativepaymentsexample,0,stop com.reactnativepaymentsexample due to clear data]' \
                    '10-16 05:19:05.125   524   550 I wm_finish_activity: [0,217980109,8,com.reactnativepaymentsexample/.MainActivity,proc died without state saved]' \
                    '10-16 05:19:05.706   524   550 I wm_task_removed: [8,8,0,removeChild]' \
                    '10-16 05:19:06.145   524   550 I wm_create_activity: [0,22338868,9,com.reactnativepaymentsexample/.MainActivity,android.intent.action.MAIN,NULL,NULL,268435456]' \
                    '10-16 05:19:06.202   524   550 I am_wtf  : [0,524,system_server,-1,ActivityManager,startProcessLocked processName:com.reactnativepaymentsexample with non-zero startSeq:78]'
                ;;
            orphan)
                printf '%s\n' \
                    '10-16 04:53:33.008   524   550 I am_kill : [0,6003,com.reactnativepaymentsexample,0,stop com.reactnativepaymentsexample due to clear data]' \
                    '10-16 04:53:34.017   524   550 I wm_create_activity: [0,253523169,9,com.reactnativepaymentsexample/.MainActivity,android.intent.action.MAIN,NULL,NULL,268435456]' \
                    '10-16 04:53:34.100   524   550 I am_proc_start: [0,6100,10193,com.reactnativepaymentsexample.other,next-top-activity,{com.reactnativepaymentsexample.other/.MainActivity}]'
                ;;
            normal)
                printf '%s\n' \
                    '10-16 05:20:15.389   524   550 I wm_create_activity: [0,2670093,10,com.reactnativepaymentsexample/.MainActivity,android.intent.action.MAIN,NULL,NULL,268435456]' \
                    '10-16 05:20:15.407   524   550 I am_proc_start: [0,6327,10192,com.reactnativepaymentsexample,next-top-activity,{com.reactnativepaymentsexample/.MainActivity}]' \
                    '10-16 05:20:15.585  6327  6327 I wm_on_create_called: [2670093,com.reactnativepaymentsexample.MainActivity,performCreate,29]' \
                    '10-16 05:20:16.000   524   550 I wm_create_activity: [0,2670200,10,com.reactnativepaymentsexample/.SettingsActivity,NULL,NULL,NULL,0]' \
                    '10-16 05:20:16.100  6327  6327 I wm_on_create_called: [2670200,com.reactnativepaymentsexample.SettingsActivity,performCreate,12]'
                ;;
        esac
    } > "$file"
}

# prepare <events shape>: a workspace whose adb stub reports one live pid for
# the app on its first pidof, then none, and whose events buffer holds the
# shape's lines after a race left over from before the attempt, which only a
# dump without -T returns; maestro fails its first $MAESTRO_FAILS invocations.
prepare() {
    local dir
    dir="$(new_empty_workspace)"
    cp "$RUN_SHARD" "$dir/step.sh"
    write_events "$dir/events.txt" "$1"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" adb '
printf "%s\n" "$*" >> "$ADB_CALLS"
case "$*" in
  "shell getprop sys.boot_completed") echo 1 ;;
  get-state) echo device ;;
  devices) printf "List of devices attached\nemulator-5554\tdevice\n" ;;
  "shell date +%s") printf "%s\r\n" "$MARKER" ;;
  "shell pidof "*)
    n=$(cat "$PIDOF_COUNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$PIDOF_COUNT"
    if [ "$n" -eq 1 ]; then printf "5796\r\n"; else exit 1; fi ;;
  *"logcat -b events -d -T "*) cat "$EVENTS" ;;
  *"logcat -b events -d"*) cat "$EVENTS.before" "$EVENTS" ;;
esac'
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" maestro '
printf "%s\n" "$*" >> "$MAESTRO_CALLS"
printf "maestro\n" >> "$ADB_CALLS"
n=$(cat "$MAESTRO_COUNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$MAESTRO_COUNT"
[ "$n" -gt "$MAESTRO_FAILS" ]'
    mkdir -p "$dir/work/flows"
    printf 'appId: x\n' > "$dir/work/flows/01.payments.flow.yaml"
    printf '%s\n' "$dir"
}

invoke() {
    local dir="$1"
    shift
    run_step "$dir" MAESTRO_CALLS="$dir/maestro-calls" MAESTRO_COUNT="$dir/maestro-count" \
        ADB_CALLS="$dir/adb-calls" PIDOF_COUNT="$dir/pidof-count" EVENTS="$dir/events.txt" MARKER="$MARKER" \
        GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 \
        APK_PATH=app.apk APP_ID="$APP" APP_WARM_SECONDS=0 PRE_TEST_COMMAND='' \
        FLOWS_DIR=flows FLOWS_MAX_DEPTH=1 FLOWS_NAME_PATTERN='*.flow.yaml' FLOWS_EXCLUDE_PATTERN='' \
        SHARD_MANIFEST_DIR='' SHARD_TIMINGS_FILE='' SHARD_INDEX=0 SHARD_COUNT=1 PRE_RUN_FLOW='' FLOW_RECOVERY_FLOW='' \
        PRE_FLOW_COMMAND='' MAESTRO_ENV='' MAESTRO_CONFIG='' INCLUDE_TAGS='' EXCLUDE_TAGS='' JUNIT_REPORT=false MAESTRO_SCRIPTS_DIR="$REPO_ROOT/scripts/maestro" ARTIFACTS_DIR="$dir/artifacts" \
        FLOW_RETRIES=0 SETTLE_BEFORE_FLOW=true INFRA_RETRIES=1 MAESTRO_FAILS=1 "$@"
}

maestro_runs() {
    if [ -f "$1/maestro-calls" ]; then wc -l < "$1/maestro-calls" | tr -d ' '; else echo 0; fi
}

case_start 'the inputs default to settling and one infra retry'
if assert_equals true "$(action_input_default "$ACTION" settle-before-flow)" 'settle-before-flow default' \
    && assert_equals 1 "$(action_input_default "$ACTION" infra-retries)" 'infra-retries default'; then
    pass_case
fi

case_start 'the startSeq am_wtf after the attempt start is retried on the infra budget with flow-retries 0'
ws="$(prepare startseq)"
invoke "$ws"
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$ws/log"))" \
    && assert_equals 2 "$(maestro_runs "$ws")" 'maestro invocations' \
    && assert_contains "$(cat "$ws/log")" "::warning::" 'warning emitted' \
    && assert_contains "$(cat "$ws/log")" 'non-zero startSeq' 'warning names the race' \
    && assert_contains "$(cat "$ws/summary")" '| 01.payments.flow.yaml |' 'summary row' \
    && assert_contains "$(cat "$ws/summary")" '| passed | 2 | 1 |' 'summary counts the infra retry' \
    && assert_contains "$(cat "$ws/adb-calls")" "logcat -b events -d -T $MARKER.000" 'events scan scoped to the attempt start' \
    && assert_contains "$(cat "$ws/artifacts/logcat-events/01.payments.flow.yaml-attempt-1.txt" 2>/dev/null)" 'startSeq:78' 'events evidence per failed attempt'; then
    pass_case
fi

case_start 'an activity created with no process start for the app is the same race'
ws="$(prepare orphan)"
invoke "$ws"
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$ws/log"))" \
    && assert_equals 2 "$(maestro_runs "$ws")" 'maestro invocations' \
    && assert_contains "$(cat "$ws/log")" "::warning::" 'warning emitted' \
    && assert_contains "$(cat "$ws/summary")" '| passed | 2 | 1 |' 'summary counts the infra retry'; then
    pass_case
fi

case_start 'an ordinary failure with a normal launch shape is not retried and still fails'
ws="$(prepare normal)"
invoke "$ws"
if assert_equals 1 "$STEP_STATUS" "step status ($(cat "$ws/log"))" \
    && assert_equals 1 "$(maestro_runs "$ws")" 'maestro invocations' \
    && assert_not_contains "$(cat "$ws/log")" 'startSeq' 'no race warning' \
    && assert_contains "$(cat "$ws/summary")" '| failed | 1 | 0 |' 'summary row' \
    && assert_contains "$(cat "$ws/artifacts/logcat-events/01.payments.flow.yaml-attempt-1.txt" 2>/dev/null)" 'wm_on_create_called' 'events evidence kept for an ordinary failure too'; then
    pass_case
fi

case_start 'infra-retries 0 still names the race but fails the flow'
ws="$(prepare startseq)"
invoke "$ws" INFRA_RETRIES=0
if assert_equals 1 "$STEP_STATUS" "step status ($(cat "$ws/log"))" \
    && assert_equals 1 "$(maestro_runs "$ws")" 'maestro invocations' \
    && assert_contains "$(cat "$ws/log")" 'non-zero startSeq' 'race still named'; then
    pass_case
fi

case_start 'an exhausted infra budget falls back to flow-retries'
ws="$(prepare startseq)"
invoke "$ws" MAESTRO_FAILS=2 FLOW_RETRIES=1
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$ws/log"))" \
    && assert_equals 3 "$(maestro_runs "$ws")" 'maestro invocations' \
    && assert_contains "$(cat "$ws/summary")" '| passed | 3 | 1 |' 'summary row'; then
    pass_case
fi

case_start 'without a device-time marker the failure is not classified and fails'
ws="$(prepare startseq)"
# shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
sed -i 's|"shell date +%s") printf "%s\\r\\n" "$MARKER" ;;|"shell date +%s") exit 1 ;;|' "$ws/stub-bin/adb"
invoke "$ws"
if assert_equals 1 "$STEP_STATUS" "step status ($(cat "$ws/log"))" \
    && assert_equals 1 "$(maestro_runs "$ws")" 'maestro invocations'; then
    pass_case
fi

case_start 'settling force-stops the app and waits for its process to die before every attempt'
ws="$(prepare startseq)"
invoke "$ws"
calls="$(grep -E "^(shell am force-stop|shell pidof|shell pm clear|maestro)" "$ws/adb-calls" | tr '\n' ';')"
if assert_equals "shell am force-stop $APP;shell pidof $APP;shell pidof $APP;maestro;shell am force-stop $APP;shell pidof $APP;maestro;" "$calls" 'settle sequence'; then
    pass_case
fi

case_start 'settle-before-flow false leaves the app untouched'
ws="$(prepare normal)"
invoke "$ws" SETTLE_BEFORE_FLOW=false MAESTRO_FAILS=0
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$ws/log"))" \
    && assert_not_contains "$(cat "$ws/adb-calls")" 'force-stop' 'no force-stop' \
    && assert_not_contains "$(cat "$ws/adb-calls")" 'pidof' 'no pidof'; then
    pass_case
fi

case_start 'invalid settle-before-flow and infra-retries fail closed'
ws="$(prepare normal)"
invoke "$ws" SETTLE_BEFORE_FLOW=yes MAESTRO_FAILS=0
settle_status="$STEP_STATUS"
settle_log="$(cat "$ws/log")"
ws="$(prepare normal)"
invoke "$ws" INFRA_RETRIES=-1 MAESTRO_FAILS=0
if assert_equals 1 "$settle_status" 'settle status' \
    && assert_contains "$settle_log" "settle-before-flow" 'settle error' \
    && assert_equals 1 "$STEP_STATUS" 'infra status' \
    && assert_contains "$(cat "$ws/log")" 'infra-retries' 'infra error' \
    && assert_equals 0 "$(maestro_runs "$ws")" 'no flow ran'; then
    pass_case
fi

case_start 'the final-state capture keeps the events buffer'
ws="$(new_workspace "$ACTION" 'Capture final device state')"
# shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
stub "$ws" adb 'case "$*" in *"-b events"*) echo "I am_wtf  : [startSeq]" ;; esac'
run_step "$ws" OUT_DIR="$ws/out" SHARD_OUTCOME=failure ANDROID_SERIAL=emulator-5554
if assert_contains "$(cat "$ws/out/logcat-events.txt" 2>/dev/null)" 'startSeq' 'logcat-events.txt'; then
    pass_case
fi

finish_suite
