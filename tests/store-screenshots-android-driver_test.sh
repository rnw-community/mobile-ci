#!/usr/bin/env bash
# shellcheck disable=SC2016 # the expected values are literal ${{ }} expressions and shell text.
# store-screenshots' capture-android job drives one of two device backends
# (issues #96, #149): a Redroid container (android-driver: redroid, the
# default, unchanged) or an AVD booted through android-emulator, the same
# action run-maestro-android uses (android-driver: avd). The device steps are
# `uses:` steps, so most cases check the wiring in the parsed workflow; the
# driver validation step is shell and runs for real.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

WORKFLOW="$REPO_ROOT/.github/workflows/store-screenshots.yml"
ANDROID_MAESTRO="$REPO_ROOT/.github/workflows/android-maestro.yml"
VALIDATE_STEP='Validate android-driver against this runner'

# query <python expression over `steps`, `inputs`, `maestro_inputs`>
query() {
    WORKFLOW_YML="$WORKFLOW" MAESTRO_YML="$ANDROID_MAESTRO" EXPRESSION="$1" python3 -c '
import json, os, yaml
workflow = yaml.safe_load(open(os.environ["WORKFLOW_YML"], encoding="utf-8"))
maestro = yaml.safe_load(open(os.environ["MAESTRO_YML"], encoding="utf-8"))
inputs = workflow[True]["workflow_call"]["inputs"]
maestro_inputs = maestro[True]["workflow_call"]["inputs"]
steps = workflow["jobs"]["capture-android"]["steps"]
def by_uses(fragment):
    return [s for s in steps if fragment in s.get("uses", "")]
result = eval(os.environ["EXPRESSION"])
print(result if isinstance(result, str) else json.dumps(result, sort_keys=True), end="")
' 2>&1 || true
}

case_start 'android-driver defaults to redroid and the capture pool default is unchanged'
if assert_equals redroid "$(query 'inputs["android-driver"]["default"]')" 'android-driver default' \
    && assert_equals '["self-hosted","linux-tiered","linux-xl"]' "$(query 'inputs["android-capture-runner-labels"]["default"]')" 'android-capture-runner-labels default'; then
    pass_case
fi

case_start 'the emulator inputs mirror android-maestro.yml names and defaults'
mismatched="$(query '[n for n in ["emulator-api-level","emulator-target","emulator-arch","emulator-profile","emulator-ram-size","emulator-heap-size","emulator-cores","emulator-slots-dir","emulator-slot-timeout-minutes"] if n not in inputs or inputs[n].get("default") != maestro_inputs[n].get("default") or inputs[n].get("type") != maestro_inputs[n].get("type")]')"
if assert_equals '[]' "$mismatched" 'inputs differing from android-maestro.yml'; then
    pass_case
fi

case_start 'redroid-container runs only for the redroid driver, start and teardown alike'
redroid_ifs="$(query '[s.get("if", "") for s in by_uses("rnw-community/mobile-ci/actions/redroid-container@")]')"
if assert_equals '["inputs.android-driver == '"'"'redroid'"'"'", "always() && inputs.android-driver == '"'"'redroid'"'"'"]' "$redroid_ifs" 'redroid-container conditions'; then
    pass_case
fi

case_start 'the avd driver starts android-emulator before the capture and always stops it afterwards'
emulator_steps="$(query '[[s.get("with", {}).get("mode"), s.get("if", ""), s.get("id", "")] for s in by_uses("rnw-community/mobile-ci/actions/android-emulator@")]')"
order="$(query '[s.get("name", s.get("uses", "")) for s in steps]')"
if assert_equals '[["start", "inputs.android-driver == '"'"'avd'"'"'", "emulator"], ["stop", "always() && inputs.android-driver == '"'"'avd'"'"'", ""]]' "$emulator_steps" 'android-emulator steps' \
    && assert_contains "$order" '"android-emulator (start)", "capture-screenshots-android"' 'start precedes capture' \
    && assert_contains "$order" '"android-emulator (stop)"' 'stop present'; then
    pass_case
fi

case_start 'the avd emulator gets its own wiped AVD and every emulator input'
start_with="$(query '[s for s in by_uses("rnw-community/mobile-ci/actions/android-emulator@") if s["with"]["mode"] == "start"][0]["with"]')"
unwired=''
for pair in api-level:emulator-api-level target:emulator-target arch:emulator-arch profile:emulator-profile \
    ram-size:emulator-ram-size heap-size:emulator-heap-size cores:emulator-cores \
    emulator-slots-dir:emulator-slots-dir emulator-slot-timeout-minutes:emulator-slot-timeout-minutes; do
    case "$start_with" in
        *"\"${pair%%:*}\": \"\${{ inputs.${pair#*:} }}\""*) ;;
        *) unwired="$unwired ${pair%%:*}" ;;
    esac
done
if assert_equals '' "$unwired" "inputs not passed through ($start_with)" \
    && assert_contains "$start_with" '"wipe-data": "true"' 'wiped userdata' \
    && assert_contains "$start_with" '"avd-name": "mobile-ci-screenshots"' 'AVD separate from the Maestro AVD'; then
    pass_case
fi

case_start 'the capture drives whichever device the selected driver booted'
serial="$(query '[s for s in steps if s.get("id") == "capture"][0]["with"]["android-serial"]')"
if assert_equals "\${{ inputs.android-driver == 'avd' && steps.emulator.outputs.android-serial || steps.redroid.outputs.android-serial }}" "$serial" 'android-serial'; then
    pass_case
fi

validate_driver() {
    workspace="$(new_workflow_workspace "$WORKFLOW" capture-android "$VALIDATE_STEP")"
    # shellcheck disable=SC2016 # expanded when the stub runs.
    stub "$workspace" uname 'case "$1" in -s) echo "${FAKE_OS:-Linux}" ;; -m) echo "${FAKE_ARCH:-x86_64}" ;; *) echo Linux ;; esac'
    run_step "$workspace" "$@"
}

case_start 'an unknown android-driver fails closed instead of skipping both device backends'
validate_driver ANDROID_DRIVER=emulator
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" "android-driver 'emulator'" 'error message'; then
    pass_case
fi

case_start 'redroid passes validation on any runner'
validate_driver ANDROID_DRIVER=redroid FAKE_ARCH=aarch64
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))"; then
    pass_case
fi

case_start 'avd passes on x86_64 Linux'
validate_driver ANDROID_DRIVER=avd
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))"; then
    pass_case
fi

case_start 'avd on a linux-aarch64 runner fails closed, since no Android emulator exists for it'
validate_driver ANDROID_DRIVER=avd FAKE_ARCH=aarch64
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'x86_64' 'error message'; then
    pass_case
fi

finish_suite
