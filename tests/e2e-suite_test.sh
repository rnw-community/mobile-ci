#!/usr/bin/env bash
# actions/e2e-suite is the e2e job of ios-e2e.yml and android-e2e.yml. It
# validates the call, decides a run passed on the suite's report and not on its
# exit code alone (a command that exits 0 without running a test, or a stale
# report, fails closed), splits the farm's free devices of the run's platform
# across its targets, and releases the leases a killed run left behind. Every
# case runs for both platforms against the one action.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/e2e-suite/action.yml"
FARM='{"capacity":{"ios":{"limit":12,"used":3,"warm":1},"android":{"limit":2,"used":1,"warm":0}}}'

report() {
    local status="$1" executed="$2" failed="$3"
    printf '{"schemaVersion":"report-1","run":{"status":"%s","exitCode":0,"summary":{"discovered":%s,"selected":%s,"executed":%s,"passed":%s,"failed":%s,"flaky":0,"skipped":0}}}' \
        "$status" "$executed" "$executed" "$executed" "$((executed - failed))" "$failed"
}

writes() {
    printf "mkdir -p .e2e && printf '%%s' '%s' > .e2e/report.json" "$1"
}

# app <platform> <dir>: the platform's app under test, a .app directory or an .apk file.
app() {
    if [ "$1" = ios ]; then
        mkdir -p "$2/work/Base.app" && printf '%s' "$2/work/Base.app"
    else
        : > "$2/work/app-release.apk" && printf '%s' "$2/work/app-release.apk"
    fi
}

# run_suite <platform> <command> [VAR=value ...]: the run step, with a farm that does not answer.
run_suite() {
    local platform="$1" command="$2"
    shift 2
    dir="$(new_workspace "$ACTION" 'Run the e2e suite')"
    stub "$dir" curl 'exit 7'
    run_step "$dir" E2E_PLATFORM="$platform" E2E_COMMAND="$command" E2E_APP_PATH="$(app "$platform" "$dir")" \
        E2E_APP_ID=com.example.app E2E_TARGET=app E2E_WORKERS=2 E2E_RETRIES=0 E2E_SESSION=s \
        SIMLOCK_URL=https://farm.invalid SIMLOCK_TOKEN=t "$@"
}

# log_count <pattern>: matching lines of the last run's log; none is a count, not a failure.
log_count() {
    grep -c "$1" "$dir/log" || true
}

for platform in ios android; do
    case_start "$platform: a passing report with executed tests passes, and the suite gets E2E_PLATFORM"
    run_suite "$platform" "printf '%s' \"\$E2E_PLATFORM\" > platform; $(writes "$(report passed 3 0)")"
    if assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))" \
        && assert_equals "$platform" "$(cat "$dir/work/platform")" 'E2E_PLATFORM' \
        && assert_contains "$(cat "$dir/summary")" 'E2E report: passed, 3 executed, 0 failed, 0 flaky.' 'summary'; then
        pass_case
    fi

    case_start "$platform: exit 0 with no report fails closed"
    run_suite "$platform" 'true'
    if assert_equals 1 "$STEP_STATUS" 'status' \
        && assert_contains "$(cat "$dir/log")" '::error::Infrastructure failure: the e2e command exited 0 but wrote no report (.e2e/report.json), so there is no evidence any test ran.' 'error'; then
        pass_case
    fi

    case_start "$platform: exit 0 with a report that executed nothing fails closed"
    run_suite "$platform" "$(writes "$(report passed 0 0)")"
    if assert_equals 1 "$STEP_STATUS" 'status' \
        && assert_contains "$(cat "$dir/log")" '::error::Infrastructure failure: the e2e suite exited 0 but executed no test.' 'error'; then
        pass_case
    fi

    case_start "$platform: exit 0 with a failing report fails closed"
    run_suite "$platform" "$(writes "$(report failed 3 1)")"
    if assert_equals 1 "$STEP_STATUS" 'status' \
        && assert_contains "$(cat "$dir/log")" '::error::The e2e report did not pass (failed, 1 failed) although the command exited 0.' 'error'; then
        pass_case
    fi

    case_start "$platform: a report whose counts are not whole numbers fails closed"
    for summary in '"executed":3,"failed":0.5' '"executed":"x","failed":0' '"executed":3,"failed":"1"' '"executed":-1,"failed":0'; do
        run_suite "$platform" "$(writes "{\"run\":{\"status\":\"passed\",\"summary\":{${summary}}}}")"
        assert_equals 1 "$STEP_STATUS" "status for ${summary} ($(cat "$dir/log"))" || break
    done
    if [ "$STEP_STATUS" = 1 ] && assert_contains "$(cat "$dir/log")" '::error::Infrastructure failure: the e2e report (.e2e/report.json) has no run status and summary with whole-number counts.' 'error'; then
        pass_case
    fi

    case_start "$platform: a stale report from an earlier run does not count"
    dir="$(new_workspace "$ACTION" 'Run the e2e suite')"
    stub "$dir" curl 'exit 7'
    mkdir -p "$dir/work/.e2e"
    report passed 5 0 > "$dir/work/.e2e/report.json"
    run_step "$dir" E2E_PLATFORM="$platform" E2E_COMMAND='true' E2E_APP_PATH="$(app "$platform" "$dir")" E2E_APP_ID=a \
        E2E_TARGET=app E2E_WORKERS=1 E2E_RETRIES=0 E2E_SESSION=s SIMLOCK_URL=https://farm.invalid SIMLOCK_TOKEN=t
    if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(cat "$dir/log")" 'wrote no report' 'error'; then
        pass_case
    fi

    FAILED_TESTS="$(writes "$(report failed 3 1)"); exit 1"

    case_start "$platform: failing tests keep the command's exit status and are no infrastructure failure"
    run_suite "$platform" "$FAILED_TESTS"
    if assert_equals 1 "$STEP_STATUS" 'status' && assert_not_contains "$(cat "$dir/log")" '::error::Infrastructure failure' 'annotation'; then
        pass_case
    fi

    case_start "$platform: a tolerated target with failing tests warns and passes"
    run_suite "$platform" "$FAILED_TESTS" E2E_TOLERATED=true
    if assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))" \
        && assert_contains "$(cat "$dir/log")" '::warning::E2E suite failed (exit 1) for a target with tolerateTestFailures; it does not gate this run.' 'warning'; then
        pass_case
    fi

    # rnw-community/rnw-community#743: a lease that failed, no report, and a green check.
    case_start "$platform: a tolerated target that tested nothing fails as infrastructure"
    tested_nothing_held=true
    for tested_nothing in 'exit 3' 'true' "$(writes '{}'); exit 1" "$(writes 'not json'); exit 1" "$(writes "$(report failed 0 0)"); exit 3"; do
        run_suite "$platform" "$tested_nothing" E2E_TOLERATED=true
        log="$(cat "$dir/log")"
        if [ "$STEP_STATUS" = 0 ]; then
            fail_case "${tested_nothing} passed: $log"
            tested_nothing_held=false
            break
        fi
        assert_contains "$log" '::error::Infrastructure failure: ' "annotation for ${tested_nothing}" || { tested_nothing_held=false; break; }
        assert_not_contains "$log" 'tolerateTestFailures' "warning for ${tested_nothing}" || { tested_nothing_held=false; break; }
    done
    if [ "$tested_nothing_held" = true ]; then pass_case; fi

    case_start "$platform: a report with a run error or an error status fails as infrastructure, tolerated or not"
    ENGINE_FAILURE='{"run":{"status":"error","errors":[{"category":"infrastructure","code":"ENGINE_FAILURE","message":"lost"}],"summary":{"executed":3,"failed":1}}}'
    run_suite "$platform" "$(writes "$ENGINE_FAILURE"); exit 3"
    plain="$STEP_STATUS $(log_count '::error::Infrastructure failure: the e2e run ended with status error, 1 run error(s) and 1 of 3 tests failed; read its report.')"
    run_suite "$platform" "$(writes "$ENGINE_FAILURE"); exit 3" E2E_TOLERATED=true
    tolerated="$STEP_STATUS $(log_count '::error::Infrastructure failure: ')"
    run_suite "$platform" "$(writes '{"run":{"status":"error","summary":{"executed":3,"failed":1}}}'); exit 3" E2E_TOLERATED=true
    status_only="$STEP_STATUS $(log_count '::error::Infrastructure failure: ')"
    run_suite "$platform" "$(writes '{"run":{"status":"interrupted","summary":{"executed":3,"failed":1}}}'); exit 130" E2E_TOLERATED=true
    if assert_equals '3 1|3 1|3 1|130' "$plain|$tolerated|$status_only|$STEP_STATUS" 'status and annotation'; then
        pass_case
    fi

    case_start "$platform: a report whose run errors are not a list fails closed"
    run_suite "$platform" "$(writes '{"run":{"status":"failed","errors":"lost","summary":{"executed":3,"failed":1}}}'); exit 1" E2E_TOLERATED=true
    if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(cat "$dir/log")" '::error::Infrastructure failure: the e2e report' 'annotation'; then
        pass_case
    fi
done

# suuudokuuu job 126511875088, as the suite printed it: the error sat only in the step log.
RUN_ERROR="printf '\\033[1m\\033[41m ERROR \\033[49m\\033[22m infrastructure error \\033[2mENGINE_FAILURE\\033[22m\\033[2m (launch)\\033[22m\\n\\033[31mdevice provider \"simlock\" could not lease a device: No Android device with serial emulator-5588\\033[39m\\n\\n      Tests  no tests executed\\n'; exit 3"

case_start 'an infrastructure failure names the error the run printed, and the step log keeps its output'
run_suite android "$RUN_ERROR"
if assert_equals 3 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$dir/log")" '::error::Infrastructure failure: the e2e command exited 3 but wrote no report (.e2e/report.json), so there is no evidence any test ran. The run said: infrastructure error ENGINE_FAILURE (launch): device provider "simlock" could not lease a device: No Android device with serial emulator-5588' 'annotation' \
    && assert_contains "$(cat "$dir/log")" 'no tests executed' 'output'; then
    pass_case
fi

case_start 'the annotation quotes at most 500 characters of that error'
run_suite android "printf ' ERROR x\\n%0600d\\n' 0; exit 3"
annotation="$(grep '^::error::' "$dir/log")"
if assert_contains "$annotation" 'The run said: x: 000' 'quote' && assert_equals 'short' "$([ "${#annotation}" -lt 700 ] && echo short || echo "${#annotation}")" 'length'; then
    pass_case
fi

case_start 'a process the command left running does not hold the step open'
started="$SECONDS"
run_suite android 'sleep 15 & exit 3'
if assert_equals 3 "$STEP_STATUS" 'status' && assert_equals 'prompt' "$([ $((SECONDS - started)) -lt 12 ] && echo prompt || echo "$((SECONDS - started))s")" 'wait'; then
    pass_case
fi

case_start 'ios: a missing .app fails closed, and so does an .apk where a .app belongs'
run_suite ios 'touch ran' E2E_APP_PATH=/nonexistent/Base.app
missing="$STEP_STATUS $(cat "$dir/log")"
dir="$(new_workspace "$ACTION" 'Run the e2e suite')"
: > "$dir/work/file.app"
run_step "$dir" E2E_PLATFORM=ios E2E_COMMAND='touch ran' E2E_APP_PATH="$dir/work/file.app" E2E_WORKERS=1 E2E_RETRIES=0 SIMLOCK_URL=https://farm.invalid SIMLOCK_TOKEN=t
if assert_contains "$missing" '1 ::error::The iOS app is not at /nonexistent/Base.app (expected a .app directory).' 'missing' \
    && assert_equals 1 "$STEP_STATUS" 'file status' \
    && assert_equals no "$([ -e "$dir/work/ran" ] && echo yes || echo no)" 'suite ran'; then
    pass_case
fi

case_start 'android: a missing .apk fails closed before the suite runs'
run_suite android 'touch ran' E2E_APP_PATH=/nonexistent/app-release.apk
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$dir/log")" '::error::The Android app is not at /nonexistent/app-release.apk (expected an .apk file).' 'error' \
    && assert_equals no "$([ -e "$dir/work/ran" ] && echo yes || echo no)" 'suite ran'; then
    pass_case
fi

case_start 'an unknown platform fails closed'
run_suite tvos 'touch ran' E2E_APP_PATH=/tmp
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(cat "$dir/log")" "::error::e2e-suite platform must be 'ios' or 'android'; got 'tvos'." 'error'; then
    pass_case
fi

# capacity <platform> <workers> <targets>: runs the suite against a farm that reports $FARM.
capacity() {
    dir="$(new_workspace "$ACTION" 'Run the e2e suite')"
    # shellcheck disable=SC2016 # expanded when the stub runs.
    stub "$dir" curl 'printf "%s\n" "$*" > "$(dirname "$0")/../curl-args"; cat > "$(dirname "$0")/../curl-stdin"; printf "%s" "$FARM"'
    run_step "$dir" FARM="$FARM" E2E_PLATFORM="$1" E2E_COMMAND="printf '%s' \"\$E2E_WORKERS\" > workers; $(writes "$(report passed 1 0)")" \
        E2E_APP_PATH="$(app "$1" "$dir")" E2E_APP_ID=a E2E_TARGET=app E2E_WORKERS="$2" E2E_RETRIES=0 E2E_SESSION=s \
        TEST_TARGETS="$3" SIMLOCK_URL=https://farm.invalid/ SIMLOCK_TOKEN=secret-token
}

case_start "ios: the farm's free simulators are split across the targets, and the token never reaches argv"
capacity ios 08 '[{"name":"a"},{"name":"b"}]'
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))" \
    && assert_contains "$(cat "$dir/log")" '::notice::The farm has 5 free ios devices; running 5 workers instead of 8.' 'notice' \
    && assert_equals 5 "$(cat "$dir/work/workers")" 'E2E_WORKERS' \
    && assert_contains "$(cat "$dir/curl-args")" 'https://farm.invalid/v1/status' 'url' \
    && assert_not_contains "$(cat "$dir/curl-args")" 'secret-token' 'curl argv' \
    && assert_equals 'Authorization: Bearer secret-token' "$(cat "$dir/curl-stdin")" 'header on stdin'; then
    pass_case
fi

case_start "android: the farm's Android capacity, not iOS's, bounds the workers"
capacity android 2 '[{"name":"a"}]'
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))" \
    && assert_contains "$(cat "$dir/log")" '::notice::The farm has 1 free android devices; running 1 workers instead of 2.' 'notice' \
    && assert_equals 1 "$(cat "$dir/work/workers")" 'E2E_WORKERS'; then
    pass_case
fi

case_start 'a full farm still runs one worker, and workers within capacity are kept'
FARM='{"capacity":{"android":{"limit":2,"used":2}}}' capacity android 3 '[]'
full="$(cat "$dir/work/workers")"
capacity ios 2 '[]'
if assert_equals '1 2' "$full $(cat "$dir/work/workers")" 'workers'; then pass_case; fi

case_start 'a farm that does not report capacity leaves the workers as asked'
run_suite android "printf '%s' \"\$E2E_WORKERS\" > workers; $(writes "$(report passed 1 0)")" E2E_WORKERS=03
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals 3 "$(cat "$dir/work/workers")" 'workers' \
    && assert_contains "$(cat "$dir/log")" '::notice::The farm did not report its free android capacity; running 3 workers as asked.' 'notice'; then
    pass_case
fi

VALIDATE='Validate the e2e call'
validate() {
    dir="$(new_workspace "$ACTION" "$VALIDATE")"
    run_step "$dir" PLATFORM=ios ABIS=arm64 E2E_DIR=e2e E2E_WORKERS=2 E2E_RETRIES=1 \
        SIMLOCK_URL=https://farm.invalid HAS_SIMLOCK_TOKEN=true "$@"
}

case_start 'validate accepts a complete e2e call on either platform'
validate
ios_status="$STEP_STATUS"
validate PLATFORM=android ABIS=x86_64,arm64-v8a
android_status="$STEP_STATUS"
if assert_equals '0 0' "$ios_status $android_status" "status ($(cat "$dir/log"))"; then pass_case; fi

case_start 'validate names every missing or malformed e2e input at once'
validate E2E_DIR='' SIMLOCK_URL=farm.invalid HAS_SIMLOCK_TOKEN=false E2E_WORKERS=00 E2E_RETRIES=x
log="$(cat "$dir/log")"
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$log" "::error::An e2e call needs e2e-dir: the directory of the e2e project." 'e2e-dir' \
    && assert_contains "$log" "::error::An e2e call needs simlock-url, an http(s) URL of the simlock gateway or worker; got 'farm.invalid'." 'url' \
    && assert_contains "$log" "::error::An e2e call needs the simlock-token secret: pass it by name from the calling workflow." 'token' \
    && assert_contains "$log" "::error::e2e-workers must be at least 1; got '00'." 'workers' \
    && assert_contains "$log" "::error::e2e-retries must be a whole number; got 'x'." 'retries'; then
    pass_case
fi

case_start "validate rejects an app the farm's arm64 devices cannot run, per platform"
validate ABIS=x86_64
ios_log="$STEP_STATUS $(cat "$dir/log")"
validate PLATFORM=android ABIS=x86_64
if assert_contains "$ios_log" "1 ::error::An e2e call runs the app on the farm's arm64 simulators; ios-simulator-archs 'x86_64' builds no arm64." 'ios' \
    && assert_equals 1 "$STEP_STATUS" 'android status' \
    && assert_contains "$(cat "$dir/log")" "::error::An e2e call runs the app on the farm's arm64-v8a emulators; android-abis 'x86_64' builds no arm64-v8a." 'android'; then
    pass_case
fi

case_start 'validate accepts an empty ABI list (every ABI the project declares)'
validate PLATFORM=android ABIS=''
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))"; then pass_case; fi

case_start 'validate rejects an unknown platform'
validate PLATFORM=tvos
if assert_equals 1 "$STEP_STATUS" 'platform status' \
    && assert_contains "$(cat "$dir/log")" "::error::e2e-suite platform must be 'ios' or 'android'; got 'tvos'." 'platform'; then
    pass_case
fi

case_start 'an unknown mode fails closed'
dir="$(new_workspace "$ACTION" 'Reject an unknown mode')"
run_step "$dir" MODE=start
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(cat "$dir/log")" "::error::e2e-suite mode must be 'validate', 'run' or 'release'; got 'start'." 'error'; then
    pass_case
fi

case_start "the run step hands the suite its whole environment contract, each from the action's input"
contract="$(ACTION="$ACTION" python3 -c '
import os, yaml
steps = yaml.safe_load(open(os.environ["ACTION"]))["runs"]["steps"]
env = next(s for s in steps if s["name"] == "Run the e2e suite")["env"]
print(" ".join(f"{k}={v}" for k, v in sorted(env.items())))')"
# shellcheck disable=SC2016 # the literal expressions the action must carry.
if assert_equals 'E2E_APP_ID=${{ inputs.app-id }} E2E_APP_PATH=${{ inputs.app-path }} E2E_COMMAND=${{ inputs.command }} E2E_PLATFORM=${{ inputs.platform }} E2E_RETRIES=${{ inputs.retries }} E2E_SESSION=${{ inputs.session }} E2E_TARGET=${{ inputs.target }} E2E_TELEMETRY_DISABLED=1 E2E_TOLERATED=${{ inputs.tolerated }} E2E_WORKERS=${{ inputs.workers }} SIMLOCK_TOKEN=${{ inputs.simlock-token }} SIMLOCK_URL=${{ inputs.simlock-url }} TEST_TARGETS=${{ inputs.targets }}' "$contract" 'env'; then
    pass_case
fi

case_start 'each mode runs only its own steps'
modes="$(ACTION="$ACTION" python3 -c '
import os, yaml
for step in yaml.safe_load(open(os.environ["ACTION"]))["runs"]["steps"]:
    print(step["name"], "|", step["if"])')"
if assert_equals "Validate the e2e call | inputs.mode == 'validate'
Install the e2e project | inputs.mode == 'run'
Install @mobile-ci/e2e-simlock | inputs.mode == 'run'
Run the e2e suite | inputs.mode == 'run'
Release the devices the suite left leased | inputs.mode == 'release'
Reject an unknown mode | inputs.mode != 'validate' && inputs.mode != 'run' && inputs.mode != 'release'" "$modes" 'step conditions'; then
    pass_case
fi

RELEASE='Release the devices the suite left leased'
release() {
    dir="$(new_workspace "$ACTION" "$RELEASE")"
    mkdir -p "$dir/work/.e2e"
    # shellcheck disable=SC2016 # expanded when the stub runs.
    stub "$dir" curl 'printf "%s\n" "$*" >> "$(dirname "$0")/../curl-args"; cat > /dev/null; printf "${CODE:-204}"'
    : > "$dir/curl-args"
}

case_start 'release with no lease list releases nothing'
release
run_step "$dir" SIMLOCK_URL=https://farm.invalid SIMLOCK_TOKEN=secret-token
if assert_equals 0 "$STEP_STATUS" 'status' && assert_equals '' "$(cat "$dir/curl-args")" 'curl calls'; then pass_case; fi

case_start 'release deletes every listed lease, with the token off argv, and skips a hostile id'
release
printf '%s' '["abc123",{"id":"def456"},"../x",42]' > "$dir/work/.e2e/simlock-leases.json"
run_step "$dir" SIMLOCK_URL=https://farm.invalid/ SIMLOCK_TOKEN=secret-token
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))" \
    && assert_contains "$(cat "$dir/curl-args")" '-X DELETE -H @- https://farm.invalid/v1/leases/abc123' 'first lease' \
    && assert_contains "$(cat "$dir/curl-args")" 'https://farm.invalid/v1/leases/def456' 'second lease' \
    && assert_equals 2 "$(wc -l < "$dir/curl-args" | tr -d ' ')" 'only the two valid ids' \
    && assert_not_contains "$(cat "$dir/curl-args")" 'secret-token' 'curl argv' \
    && assert_contains "$(cat "$dir/log")" 'Released lease abc123.' 'log'; then
    pass_case
fi

case_start 'release reports an already released lease and warns on any other failure, without failing'
release
printf '%s' '["gone","stuck"]' > "$dir/work/.e2e/simlock-leases.json"
# shellcheck disable=SC2016 # expanded when the stub runs.
stub "$dir" curl 'cat > /dev/null; case "$*" in *gone*) printf 404 ;; *) printf 500 ;; esac'
run_step "$dir" SIMLOCK_URL=https://farm.invalid SIMLOCK_TOKEN=t
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$dir/log")" 'Lease gone was already released.' '404' \
    && assert_contains "$(cat "$dir/log")" '::warning::Could not release lease stuck (HTTP 500); it expires at its TTL.' '500'; then
    pass_case
fi

case_start 'release warns on a malformed lease list and does not fail the job'
release
printf '%s' 'not json' > "$dir/work/.e2e/simlock-leases.json"
run_step "$dir" SIMLOCK_URL=https://farm.invalid SIMLOCK_TOKEN=t
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$dir/log")" '::warning::.e2e/simlock-leases.json is not a JSON array of lease ids; nothing released.' 'warning'; then
    pass_case
fi

finish_suite
