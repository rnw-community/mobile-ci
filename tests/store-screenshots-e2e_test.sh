#!/usr/bin/env bash
# shellcheck disable=SC2016 # the expected values are literal ${{ }} expressions.
# store-screenshots' test-framework e2e: a consumer's tester-army e2e project
# captures the iOS cells from a Linux runner against simlock instead of
# Maestro on a macOS host. The manifest validation must refuse what the e2e
# capture would silently drop (Maestro flows, a seed hook, Android, landscape),
# the plan must hold exactly the cells the macOS capture would take, at its
# raw/ios/<slug>/<locale>/<appearance>/<scene>.png paths, and neither an exit
# code nor a report may stand in for a PNG that was never written.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

WORKFLOW="$REPO_ROOT/.github/workflows/store-screenshots.yml"
VALIDATE_STEP='Validate structure, cross-checks, and matrix limits'

IOS_MANIFEST='[{"platform":"ios","device":"iPhone 17 Pro Max","locales":["en","de"],"appearances":["light","dark"]}]'
E2E_SCENES='[{"name":"01-home","deepLink":"app://","readySelector":{"id":"Home"}},{"name":"03-analytics","test":"03-analytics"}]'

# validate [VAR=value ...] - the manifest validation with a valid e2e call, overridable.
validate() {
    dir="$(new_workflow_workspace "$WORKFLOW" validate-manifest "$VALIDATE_STEP")"
    run_step "$dir" CAPTURE_MANIFEST="$IOS_MANIFEST" CAPTURE_MODE=direct CAPTURE_SCENES="$E2E_SCENES" \
        SEED_COMMAND= SETTLE_SECONDS=3 LAUNCH_SETTLE_SECONDS=0 SCREENSHOTS_DIR= \
        IOS_TARGET='{"name":"app","appDir":"apps/mobile","workspace":"App.xcworkspace","scheme":"App","appId":"com.example.app"}' \
        ANDROID_TARGET= TEST_FRAMEWORK=e2e E2E_DIR=e2e SIMLOCK_URL=http://farm.invalid HAS_SIMLOCK_TOKEN=true "$@"
}

case_start 'a valid e2e call passes validation'
validate
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))"; then
    pass_case
fi

case_start 'an unknown test-framework fails closed'
validate TEST_FRAMEWORK=both
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(cat "$dir/log")" "test-framework 'both'" 'error'; then
    pass_case
fi

case_start 'e2e without e2e-dir, simlock-url or the token fails closed'
ok=true
for pair in 'E2E_DIR=|needs e2e-dir' 'SIMLOCK_URL=|needs simlock-url' 'HAS_SIMLOCK_TOKEN=false|needs the simlock-token secret'; do
    validate "${pair%%|*}"
    if ! assert_equals 1 "$STEP_STATUS" "status with ${pair%%|*}" || ! assert_contains "$(cat "$dir/log")" "${pair#*|}" 'error'; then
        ok=false
    fi
done
if [ "$ok" = true ]; then
    pass_case
fi

case_start 'e2e refuses a seed-command it has no host to run on'
validate SEED_COMMAND='bash seed.sh'
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(cat "$dir/log")" 'seed-command is set but test-framework is' 'error'; then
    pass_case
fi

case_start 'e2e refuses a Maestro flow scene'
validate CAPTURE_SCENES='[{"name":"03-analytics","flow":"flows/03.flow.yaml"}]' SCREENSHOTS_DIR=e2e
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(cat "$dir/log")" "declare a Maestro 'flow'" 'error'; then
    pass_case
fi

case_start 'maestro refuses an e2e test scene it would never capture'
validate TEST_FRAMEWORK=maestro
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(cat "$dir/log")" "declare an e2e 'test'" 'error'; then
    pass_case
fi

case_start 'a scene with both a test and a deep link is invalid'
validate CAPTURE_SCENES='[{"name":"x","test":"x","deepLink":"app://"}]'
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(cat "$dir/log")" 'capture-scenes has invalid entries' 'error'; then
    pass_case
fi

case_start 'e2e refuses Android entries and landscape'
validate CAPTURE_MANIFEST='[{"platform":"android","device":"Pixel","locales":["en"],"appearances":["light"],"width":1080,"height":2400,"density":420}]' \
    ANDROID_TARGET='{"name":"app","appDir":"apps/mobile","appId":"com.example.app"}'
android_status="$STEP_STATUS"
android_log="$(cat "$dir/log")"
validate CAPTURE_MANIFEST='[{"platform":"ios","device":"iPad Pro 13-inch (M5)","locales":["en"],"appearances":["light"],"orientation":"landscape"}]'
if assert_equals 1 "$android_status" 'android status' \
    && assert_contains "$android_log" 'captures iOS only' 'android error' \
    && assert_equals 1 "$STEP_STATUS" 'landscape status' \
    && assert_contains "$(cat "$dir/log")" 'ask for landscape' 'landscape error'; then
    pass_case
fi

# plan [VAR=value ...] - the plan step for one iPhone entry.
plan() {
    dir="$(new_workflow_workspace "$WORKFLOW" capture-ios-e2e 'Plan the e2e capture cells')"
    mkdir -p "$dir/runner-temp"
    run_step "$dir" CAPTURE_SCENES="$E2E_SCENES" DEVICE='iPhone 17 Pro Max' LOCALES='["en","de"]' \
        APPEARANCES='["light","dark"]' SETTLE_SECONDS=4 OUTPUT_DIR="$dir/work/out" "$@"
}

case_start 'the plan holds every locale x appearance x scene cell at the raw layout path'
plan
plan_file="$(step_output "$dir" plan)"
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))" \
    && assert_equals 'iphone-17-pro-max' "$(step_output "$dir" device-slug)" 'slug' \
    && assert_equals 8 "$(jq 'length' "$plan_file")" 'cells' \
    && assert_equals "$dir/work/out/raw/ios/iphone-17-pro-max/de/dark/03-analytics.png" \
        "$(jq -r '.[] | select(.scene == "03-analytics" and .locale == "de" and .appearance == "dark") | .path' "$plan_file")" 'path' \
    && assert_equals '{"appearance":"light","deepLink":"app://","locale":"en","readySelector":{"id":"Home"},"settleSeconds":4}' \
        "$(jq -cS '.[0] | del(.path, .scene)' "$plan_file")" 'deep-link cell' \
    && assert_equals '03-analytics' "$(jq -r '.[1].test' "$plan_file")" 'test cell'; then
    pass_case
fi

case_start 'per-scene platforms, locales, appearances and settleSeconds apply'
plan CAPTURE_SCENES='[{"name":"a","test":"a","locales":["de"],"appearances":["dark"],"settleSeconds":9},{"name":"b","test":"b","platforms":["android"]}]'
plan_file="$(step_output "$dir" plan)"
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))" \
    && assert_equals '[{"appearance":"dark","locale":"de","scene":"a","settleSeconds":9,"test":"a"}]' \
        "$(jq -cS 'map(del(.path))' "$plan_file")" 'cells'; then
    pass_case
fi

case_start 'a plan the filters left empty fails closed'
plan CAPTURE_SCENES='[{"name":"a","test":"a","locales":["fr"]}]'
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(cat "$dir/log")" 'No capture cell' 'error'; then
    pass_case
fi

case_start 'stale captures from an earlier run are cleared'
dir="$(new_workflow_workspace "$WORKFLOW" capture-ios-e2e 'Plan the e2e capture cells')"
mkdir -p "$dir/runner-temp" "$dir/work/out/raw/ios/iphone-17-pro-max/en/light"
printf 'old' > "$dir/work/out/raw/ios/iphone-17-pro-max/en/light/old.png"
run_step "$dir" CAPTURE_SCENES="$E2E_SCENES" DEVICE='iPhone 17 Pro Max' LOCALES='["en"]' \
    APPEARANCES='["light"]' SETTLE_SECONDS=4 OUTPUT_DIR="$dir/work/out"
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals no "$([ -e "$dir/work/out/raw/ios/iphone-17-pro-max/en/light/old.png" ] && echo yes || echo no)" 'stale capture'; then
    pass_case
fi

report() {
    printf '{"run":{"status":"%s","summary":{"executed":%s,"failed":%s}}}' "$1" "$2" "$3"
}

# capture <command> - the run step with an unreachable farm.
capture() {
    dir="$(new_workflow_workspace "$WORKFLOW" capture-ios-e2e 'Run the e2e capture')"
    mkdir -p "$dir/work/Base.app"
    stub "$dir" curl 'exit 7'
    run_step "$dir" E2E_COMMAND="$1" E2E_APP_PATH="$dir/work/Base.app" E2E_APP_ID=com.example.app E2E_TARGET=app \
        E2E_WORKERS=2 E2E_RETRIES=0 E2E_SESSION=s SCREENSHOT_PLAN=plan.json SCREENSHOT_DEVICE=d \
        SCREENSHOT_DEVICE_SLUG=d SCREENSHOT_STATUS_BAR=override SIMLOCK_URL=http://farm.invalid SIMLOCK_TOKEN=t
}

case_start 'a passing report passes and the suite sees the plan'
capture "test \"\$SCREENSHOT_PLAN\" = plan.json && mkdir -p .e2e && printf '%s' '$(report passed 2 0)' > .e2e/report.json"
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))"; then
    pass_case
fi

case_start 'exit 0 without a report, or with one that ran nothing, fails closed'
capture 'true'
no_report="$STEP_STATUS"
capture "mkdir -p .e2e && printf '%s' '$(report passed 0 0)' > .e2e/report.json"
if assert_equals 1 "$no_report" 'no report' && assert_equals 1 "$STEP_STATUS" 'nothing executed' \
    && assert_contains "$(cat "$dir/log")" 'executed no test' 'error'; then
    pass_case
fi

case_start 'a report with a fractional failed count fails closed'
capture "mkdir -p .e2e && printf '%s' '{\"run\":{\"status\":\"passed\",\"summary\":{\"executed\":2,\"failed\":0.5}}}' > .e2e/report.json"
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(cat "$dir/log")" 'whole-number counts' 'error'; then
    pass_case
fi

case_start 'a failing command keeps its exit status'
capture 'exit 3'
if assert_equals 3 "$STEP_STATUS" 'status'; then
    pass_case
fi

# check <cells written...> - the post-capture check over a two-cell plan.
check() {
    dir="$(new_workflow_workspace "$WORKFLOW" capture-ios-e2e 'Check every planned capture was written')"
    printf '[{"path":"%s"},{"path":"%s"}]' "$dir/work/a.png" "$dir/work/b.png" > "$dir/work/plan.json"
    for name in "$@"; do
        printf '\211PNG\r\n\032\nrest' > "$dir/work/$name"
    done
    run_step "$dir" SCREENSHOT_PLAN="$dir/work/plan.json"
}

case_start 'every planned PNG written passes'
check a.png b.png
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))"; then
    pass_case
fi

case_start 'a missing or non-PNG capture fails closed'
check a.png
missing_status="$STEP_STATUS"
missing_log="$(cat "$dir/log")"
check a.png
printf 'not a png' > "$dir/work/b.png"
run_step "$dir" SCREENSHOT_PLAN="$dir/work/plan.json"
if assert_equals 1 "$missing_status" 'missing status' \
    && assert_contains "$missing_log" '1 of 2 planned captures are missing' 'missing error' \
    && assert_equals 1 "$STEP_STATUS" 'non-PNG status'; then
    pass_case
fi

# query <python expression over `jobs`>
query() {
    WORKFLOW_YML="$WORKFLOW" EXPRESSION="$1" python3 -c '
import json, os, yaml
jobs = yaml.safe_load(open(os.environ["WORKFLOW_YML"], encoding="utf-8"))["jobs"]
result = eval(os.environ["EXPRESSION"])
print(result if isinstance(result, str) else json.dumps(result, sort_keys=True), end="")
' 2>&1 || true
}

case_start 'exactly one iOS capture job runs per test-framework, and upload and status read that one'
if assert_contains "$(query 'jobs["capture-ios"]["if"]')" "inputs.test-framework != 'e2e'" 'maestro capture gate' \
    && assert_contains "$(query 'jobs["capture-ios-e2e"]["if"]')" "inputs.test-framework == 'e2e'" 'e2e capture gate' \
    && assert_contains "$(query 'jobs["upload"]["if"]')" "needs.capture-ios-e2e.result" 'upload gate' \
    && assert_contains "$(query '[s for s in jobs["status"]["steps"] if s.get("id") == "report"][0]["env"]["CAPTURE_IOS_RESULT"]')" \
        "needs.capture-ios-e2e.result" 'status' \
    && assert_contains "$(query 'jobs["status"]["needs"]')" 'capture-ios-e2e' 'status needs'; then
    pass_case
fi

finish_suite
