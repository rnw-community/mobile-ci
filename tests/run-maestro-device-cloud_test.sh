#!/usr/bin/env bash
# The device-cloud driver hands the flows to a hosted device farm, so the only
# evidence a flow ran is what the Device Cloud CLI reports back. These cases
# run the real plan, submit and unpack steps against a stubbed `npx` that
# answers the way @devicecloud.dev/dcd does - JSON on stdout, exit 0 for a
# pass, 2 for a failed run, 1 for a rejected or broken submission - and pin
# that only an explicit pass of at least one flow is a pass.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/run-maestro-device-cloud/action.yml"
PLAN_STEP='Plan the Device Cloud submission'
SUBMIT_STEP='Submit the flows to Device Cloud'
UNPACK_STEP='Unpack the Device Cloud artifacts'
API_KEY='dc-key-should-never-be-on-argv'

# flows_tree <dir> — a flows dir with two runnable flows, a subflow, a non-flow
# yaml and a capture-only flow the exclude pattern drops.
flows_tree() {
    local root="$1/work/flows"
    mkdir -p "$root/subflows"
    printf 'appId: x\n---\n- launchApp\n' > "$root/01.login.flow.yaml"
    printf 'appId: x\n---\n- launchApp\n' > "$root/02.home.flow.yaml"
    printf 'appId: x\n---\n- launchApp\n' > "$root/99.capture.flow.yaml"
    printf 'appId: x\n---\n- tapOn: x\n' > "$root/subflows/login.flow.yaml"
    printf 'flows:\n  - "*"\n' > "$root/config.yaml"
    printf 'fake apk' > "$1/work/app.apk"
}

plan() {
    local dir="$1"
    shift
    run_step "$dir" \
        PLATFORM=android \
        APP_PATH=app.apk \
        API_KEY="$API_KEY" \
        CLI_VERSION=5.7.1 \
        FLOWS_DIR=flows \
        FLOWS_MAX_DEPTH=1 \
        FLOWS_NAME_PATTERN='*.flow.yaml' \
        FLOWS_EXCLUDE_PATTERN='99.*' \
        MAESTRO_CONFIG='' \
        RETRIES=0 \
        JUNIT_REPORT=true \
        GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 \
        "$@"
}

# submit_workspace <npx exit status> <stdout JSON> — a submit step whose npx
# records its argv and environment, then answers like dcd.
submit_workspace() {
    local status="$1" json="$2" dir
    dir="$(new_workspace "$ACTION" "$SUBMIT_STEP")"
    flows_tree "$dir"
    mkdir -p "$dir/runner-temp/work"
    printf '%s\n' "$json" > "$dir/answer.json"
    stub "$dir" npx "printf '%s\n' \"\$@\" > '$dir/argv'
env > '$dir/npx-env'
echo 'npm warn exec installing' >&2
printf 'Uploading...\n'
cat '$dir/answer.json'
exit $status"
    printf '%s\n' "$dir"
}

submit() {
    local dir="$1"
    shift
    run_step "$dir" \
        PLATFORM=android \
        APP_PATH=app.apk \
        DEVICE_CLOUD_API_KEY="$API_KEY" \
        CLI_VERSION=5.7.1 \
        FLOWS_DIR=flows \
        WORK="$dir/runner-temp/work" \
        CONFIG="$dir/runner-temp/work/config.yaml" \
        INCLUDE_TAGS='' EXCLUDE_TAGS='' \
        MAESTRO_ENV='' MAESTRO_VERSION='' RETRIES=0 \
        ANDROID_API_LEVEL='' ANDROID_DEVICE='' IOS_DEVICE='' IOS_VERSION='' \
        JUNIT_REPORT=true RUN_NAME='' DCD_TELEMETRY_DISABLED=1 \
        "$@"
}

PASSED_JSON='{
  "consoleUrl": "https://console.devicecloud.dev/results?upload=u-1",
  "status": "PASSED",
  "tests": [
    {"name": "01.login.flow.yaml", "status": "PASSED", "device": "pixel-7 (API 34)"},
    {"name": "02.home.flow.yaml", "status": "PASSED", "device": "pixel-7 (API 34)"}
  ],
  "uploadId": "u-1"
}'

case_start 'the plan selects exactly what the local drivers would run'
dir="$(new_workspace "$ACTION" "$PLAN_STEP")"
flows_tree "$dir"
plan "$dir"
config="$(step_output "$dir" config)"
assert_equals 0 "$STEP_STATUS" "exit status ($(cat "$dir/log"))" \
    && assert_equals '2' "$(step_output "$dir" count)" 'count' \
    && assert_equals $'flows:\n  - "01.login.flow.yaml"\n  - "02.home.flow.yaml"' "$(cat "$config")" 'generated config' \
    && pass_case

case_start 'maestro-config settings travel with the selection'
dir="$(new_workspace "$ACTION" "$PLAN_STEP")"
flows_tree "$dir"
printf 'executionOrder:\n  continueOnFailure: false' > "$dir/work/workspace.yaml"
plan "$dir" MAESTRO_CONFIG=workspace.yaml
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals $'executionOrder:\n  continueOnFailure: false\nflows:\n  - "01.login.flow.yaml"\n  - "02.home.flow.yaml"' "$(cat "$(step_output "$dir" config)")" 'generated config' \
    && pass_case

case_start 'a maestro-config with its own flows: fails closed'
dir="$(new_workspace "$ACTION" "$PLAN_STEP")"
flows_tree "$dir"
plan "$dir" MAESTRO_CONFIG=flows/config.yaml
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" 'sets its own top-level flows:' 'error' \
    && pass_case

case_start 'no API key fails before anything is submitted'
dir="$(new_workspace "$ACTION" "$PLAN_STEP")"
flows_tree "$dir"
plan "$dir" API_KEY=''
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" 'device-cloud-api-key' 'error' \
    && pass_case

case_start 'a CLI version range is refused'
dir="$(new_workspace "$ACTION" "$PLAN_STEP")"
flows_tree "$dir"
plan "$dir" CLI_VERSION='^5'
assert_equals 1 "$STEP_STATUS" 'exit status' && pass_case

case_start 'an iOS app that is not an .app, .zip or .tar.gz is refused'
dir="$(new_workspace "$ACTION" "$PLAN_STEP")"
flows_tree "$dir"
plan "$dir" PLATFORM=ios
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" 'not an app Device Cloud takes for ios' 'error' \
    && pass_case

case_start 'no flow found fails closed'
dir="$(new_workspace "$ACTION" "$PLAN_STEP")"
flows_tree "$dir"
plan "$dir" FLOWS_NAME_PATTERN='*.nothing'
assert_equals 1 "$STEP_STATUS" 'exit status' && pass_case

case_start 'a pass is a pass, and the key never reaches the command line'
dir="$(submit_workspace 0 "$PASSED_JSON")"
submit "$dir" MAESTRO_ENV=$'USER=demo\nPASSWORD=s3cret' INCLUDE_TAGS='smoke,login' EXCLUDE_TAGS=flaky \
    ANDROID_API_LEVEL=34 ANDROID_DEVICE=pixel-7 IOS_DEVICE=iphone-16 RETRIES=2 MAESTRO_VERSION=2.0.3
argv="$(cat "$dir/argv")"
assert_equals 0 "$STEP_STATUS" "exit status ($(cat "$dir/log"))" \
    && assert_equals PASSED "$(step_output "$dir" result)" 'result' \
    && assert_equals u-1 "$(step_output "$dir" upload-id)" 'upload-id' \
    && assert_contains "$argv" $'@devicecloud.dev/dcd@5.7.1\ncloud\n--app-file\napp.apk\n--flows\nflows\n--config' 'pinned CLI and app' \
    && assert_contains "$argv" $'--android-api-level\n34\n--android-device\npixel-7' 'android device' \
    && assert_not_contains "$argv" 'iphone-16' 'iOS device on an android run' \
    && assert_contains "$argv" $'--include-tags\nsmoke,login\n--exclude-tags\nflaky' 'tags' \
    && assert_contains "$argv" $'--retry\n2' 'retries' \
    && assert_contains "$argv" $'--maestro-version\n2.0.3' 'maestro version' \
    && assert_contains "$argv" $'-e\nUSER=demo\n-e\nPASSWORD=s3cret' 'maestro env' \
    && assert_contains "$argv" $'--download-artifacts\nALL' 'artifacts' \
    && assert_contains "$argv" $'--report\njunit' 'junit' \
    && assert_not_contains "$argv" "$API_KEY" 'argv' \
    && assert_contains "$(cat "$dir/npx-env")" "DEVICE_CLOUD_API_KEY=$API_KEY" 'key in the CLI environment' \
    && assert_contains "$(cat "$dir/summary")" "| \`02.home.flow.yaml\` | pixel-7 (API 34) | PASSED |" 'summary' \
    && pass_case

case_start 'an iOS run passes the iOS device and version only'
dir="$(submit_workspace 0 "$PASSED_JSON")"
submit "$dir" PLATFORM=ios APP_PATH=Base.app IOS_DEVICE=iphone-16 IOS_VERSION=18 ANDROID_API_LEVEL=34
argv="$(cat "$dir/argv")"
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_contains "$argv" $'--ios-device\niphone-16\n--ios-version\n18' 'iOS device' \
    && assert_not_contains "$argv" '--android-api-level' 'android flags on an iOS run' \
    && pass_case

case_start 'a failed run is red and names every failed flow with its reason'
dir="$(submit_workspace 2 '{"status":"FAILED","uploadId":"u-2","consoleUrl":"https://c/u-2","tests":[{"name":"01.login.flow.yaml","status":"PASSED","device":"pixel-7"},{"name":"02.home.flow.yaml","status":"FAILED","device":"pixel-7","failReason":"Element not found: Home"}]}')"
submit "$dir"
log="$(cat "$dir/log")"
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_equals FAILED "$(step_output "$dir" result)" 'result' \
    && assert_contains "$log" '::error title=Device Cloud flow 02.home.flow.yaml::FAILED on pixel-7: Element not found: Home' 'per-flow error' \
    && assert_contains "$log" '1 of 2 flow(s) did not pass' 'summary error' \
    && pass_case

case_start 'a rejected submission (quota) is red with the rejection reason, never a skip'
dir="$(submit_workspace 1 '{"status":"FAILED","error":"Request failed (402): monthly test quota exceeded"}')"
submit "$dir"
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_equals REJECTED "$(step_output "$dir" result)" 'result' \
    && assert_contains "$(cat "$dir/log")" '::error::Device Cloud rejected the submission: Request failed (402): monthly test quota exceeded' 'reason' \
    && pass_case

case_start 'a CLI that prints no JSON fails closed'
dir="$(submit_workspace 1 'Error: something broke')"
submit "$dir"
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_equals REJECTED "$(step_output "$dir" result)" 'result' \
    && assert_contains "$(cat "$dir/log")" 'without a JSON result' 'error' \
    && pass_case

case_start 'exit 0 with a superseded run is not a pass'
dir="$(submit_workspace 0 '{"status":"SUPERSEDED","uploadId":"u-3","tests":[{"name":"a.flow.yaml","status":"CANCELLED"}]}')"
submit "$dir"
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" "returned 'SUPERSEDED'" 'error' \
    && pass_case

case_start 'exit 0 with zero flows is not a pass'
dir="$(submit_workspace 0 '{"status":"PASSED","uploadId":"u-4","tests":[]}')"
submit "$dir"
assert_equals 1 "$STEP_STATUS" 'exit status' && pass_case

case_start 'a malformed maestro-env line fails before submitting'
dir="$(submit_workspace 0 "$PASSED_JSON")"
submit "$dir" MAESTRO_ENV='not-a-pair'
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_equals 'absent' "$([ -e "$dir/argv" ] && echo present || echo absent)" 'npx was not run' \
    && pass_case

case_start 'the downloaded artifacts and JUnit report land in the uploaded directory'
dir="$(new_workspace "$ACTION" "$UNPACK_STEP")"
work="$dir/runner-temp/work"
mkdir -p "$work/zipsrc/01.login"
printf 'maestro log\n' > "$work/zipsrc/01.login/maestro.log"
(cd "$work/zipsrc" && python3 -m zipfile -c "$work/artifacts.zip" 01.login)
printf '<testsuites/>\n' > "$work/report.xml"
printf '{"status":"PASSED"}\n' > "$work/result.json"
run_step "$dir" WORK="$work" ARTIFACTS_DIR="$dir/work/artifacts"
assert_equals 0 "$STEP_STATUS" "exit status ($(cat "$dir/log"))" \
    && assert_equals 'maestro log' "$(cat "$dir/work/artifacts/device-cloud/01.login/maestro.log")" 'artifact' \
    && assert_equals '<testsuites/>' "$(cat "$dir/work/artifacts/junit/report.xml")" 'junit' \
    && assert_equals '{"status":"PASSED"}' "$(cat "$dir/work/artifacts/device-cloud-result.json")" 'result' \
    && pass_case

finish_suite
