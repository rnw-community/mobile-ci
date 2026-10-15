#!/usr/bin/env bash
# shellcheck disable=SC2016 # the expected values are literal ${{ }} expressions and shell text.
# run-maestro-android boots its AVD through android-emulator (issue #96), the
# same action store-screenshots' avd capture leg uses, instead of running the
# shard inside reactivecircus/android-emulator-runner's script. The steps
# involved are `uses:` steps, so these cases check the wiring in the parsed
# action.yml; android-emulator_test.sh exercises the shell itself.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/run-maestro-android/action.yml"

# query <python expression over `steps`, `action`>: prints its result.
query() {
    ACTION_YML="$ACTION" EXPRESSION="$1" python3 -c '
import json, os, yaml
action = yaml.safe_load(open(os.environ["ACTION_YML"], encoding="utf-8"))
steps = action["runs"]["steps"]
def by_uses(fragment):
    return [s for s in steps if fragment in s.get("uses", "")]
def index_of(step):
    return steps.index(step)
result = eval(os.environ["EXPRESSION"])
print(result if isinstance(result, str) else json.dumps(result, sort_keys=True), end="")
' 2>&1 || true
}

case_start 'no step runs the shard inside reactivecircus/android-emulator-runner any more'
if assert_equals '[]' "$(query '[s["name"] for s in by_uses("reactivecircus/android-emulator-runner")]')" 'android-emulator-runner steps'; then
    pass_case
fi

case_start 'android-emulator starts the emulator before the shard and stops it, always, after the final capture'
modes="$(query '[s.get("with", {}).get("mode") for s in by_uses("rnw-community/mobile-ci/actions/android-emulator@")]')"
order="$(query '[s["name"] for s in steps]')"
stop_if="$(query '[s.get("if", "") for s in by_uses("rnw-community/mobile-ci/actions/android-emulator@") if s.get("with", {}).get("mode") == "stop"]')"
if assert_equals '["start", "stop"]' "$modes" 'android-emulator modes' \
    && assert_contains "$order" '"Start emulator", "Run Maestro shard", "Capture final device state", "Stop emulator", "Upload Maestro artifacts"' 'step order' \
    && assert_equals '["always()"]' "$stop_if" 'stop condition'; then
    pass_case
fi

case_start 'every emulator input reaches android-emulator unchanged'
with_map="$(query '[s for s in by_uses("rnw-community/mobile-ci/actions/android-emulator@") if s["with"]["mode"] == "start"][0]["with"]')"
unwired=''
for input in api-level target arch profile ram-size heap-size cores emulator-slots-dir emulator-slot-timeout-minutes; do
    case "$with_map" in
        *"\"$input\": \"\${{ inputs.$input }}\""*) ;;
        *) unwired="$unwired $input" ;;
    esac
done
if assert_equals '' "$unwired" "inputs not passed through ($with_map)" \
    && assert_contains "$with_map" '"emulator-options": "-no-snapshot-save -no-window -gpu swiftshader_indirect -noaudio -no-boot-anim -camera-back none"' 'emulator options kept'; then
    pass_case
fi

case_start 'the budget and slot outputs come from android-emulator'
outputs="$(query '{k: v["value"] for k, v in action["outputs"].items()}')"
if assert_contains "$outputs" '"ram-size": "${{ steps.emulator.outputs.ram-size }}"' 'ram-size output' \
    && assert_contains "$outputs" '"cores": "${{ steps.emulator.outputs.cores }}"' 'cores output' \
    && assert_contains "$outputs" '"emulator-slot": "${{ steps.emulator.outputs.emulator-slot }}"' 'emulator-slot output' \
    && assert_equals emulator "$(query '[s for s in steps if s.get("name") == "Start emulator"][0].get("id", "")')" 'start step id'; then
    pass_case
fi

case_start 'the shard step keeps every variable run-shard.sh read under android-emulator-runner, plus the serial'
shard_env="$(query '[s for s in steps if s.get("name") == "Run Maestro shard"][0]["env"]')"
missing=''
for var in APK_PATH APP_ID FLOWS_DIR FLOWS_MAX_DEPTH FLOWS_NAME_PATTERN FLOWS_EXCLUDE_PATTERN SHARD_MANIFEST_DIR \
    SHARD_INDEX SHARD_COUNT PRE_RUN_FLOW FLOW_RECOVERY_FLOW PRE_TEST_COMMAND APP_WARM_SECONDS MAESTRO_ENV \
    MAESTRO_CONFIG FLOW_RETRIES PRE_FLOW_COMMAND ANDROID_SERIAL; do
    case "$shard_env" in
        *"\"$var\":"*) ;;
        *) missing="$missing $var" ;;
    esac
done
if assert_equals '' "$missing" 'variables missing from the shard step' \
    && assert_contains "$shard_env" '"ANDROID_SERIAL": "${{ steps.emulator.outputs.android-serial }}"' 'serial from android-emulator' \
    && assert_equals 'bash "$GITHUB_ACTION_PATH/scripts/run-shard.sh"' "$(query '[s for s in steps if s.get("name") == "Run Maestro shard"][0]["run"].strip()')" 'shard script'; then
    pass_case
fi

finish_suite
