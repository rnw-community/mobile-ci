#!/usr/bin/env bash
# shellcheck disable=SC2016 # the expected values are literal ${{ }} expressions.
# ios-simulator-archs (#218): the Simulator slice an iOS base is built for.
# The wiring cases check the parsed workflows - build-ios-app gets the slice,
# the plan folds it into the native key, the warm-up caches under it. The host
# check is shell, extracted from each workflow and run against stubbed
# `uname`/`arch`.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

WORKFLOWS="$REPO_ROOT/.github/workflows"
HOST_STEP='Assert this host can run the packaged simulator architecture'

# query <workflow file> <python expression over `workflow`, `inputs`, `steps(job)`>
query() {
    WORKFLOW_YML="$WORKFLOWS/$1" EXPRESSION="$2" python3 -c '
import json, os, yaml
workflow = yaml.safe_load(open(os.environ["WORKFLOW_YML"], encoding="utf-8"))
inputs = workflow[True]["workflow_call"]["inputs"]
def steps(job):
    return workflow["jobs"][job]["steps"]
def by_uses(job, fragment):
    return [s for s in steps(job) if fragment in s.get("uses", "")]
result = eval(os.environ["EXPRESSION"])
print(result if isinstance(result, str) else json.dumps(result, sort_keys=True), end="")
' 2>&1 || true
}

case_start 'every iOS-building workflow exposes ios-simulator-archs defaulting to arm64'
wrong=''
for workflow in ios-maestro.yml seed-native-cache.yml store-screenshots.yml expo-base-plan.yml; do
    if [ "$(query "$workflow" 'inputs["ios-simulator-archs"]["default"] + "/" + inputs["ios-simulator-archs"]["type"]')" != 'arm64/string' ]; then
        wrong="$wrong $workflow"
    fi
done
if assert_equals '' "$wrong" 'workflows without an arm64 string default'; then
    pass_case
fi

case_start 'build-ios-app builds exactly the requested slice and excludes the other'
expected='["${{ inputs.ios-simulator-archs }}", "${{ inputs.ios-simulator-archs == '"'"'x86_64'"'"' && '"'"'arm64'"'"' || '"'"'x86_64'"'"' }}"]'
unwired=''
for pair in ios-maestro.yml:build seed-native-cache.yml:seed-ios store-screenshots.yml:build-ios; do
    got="$(query "${pair%%:*}" '[[s["with"].get("archs"), s["with"].get("excluded-archs")] for s in by_uses("'"${pair#*:}"'", "rnw-community/mobile-ci/actions/build-ios-app@")][0]')"
    if [ "$got" != "$expected" ]; then
        unwired="$unwired ${pair} ($got)"
    fi
done
if assert_equals '' "$unwired" 'build-ios-app steps not wired to ios-simulator-archs'; then
    pass_case
fi

case_start 'the iOS plan folds ios-simulator-archs into the native key'
unwired=''
for pair in ios-maestro.yml:plan seed-native-cache.yml:plan-ios store-screenshots.yml:plan-ios; do
    got="$(query "${pair%%:*}" 'workflow["jobs"]["'"${pair#*:}"'"]["with"].get("ios-simulator-archs", "")')"
    if [ "$got" != '${{ inputs.ios-simulator-archs }}' ]; then
        unwired="$unwired $pair"
    fi
done
native_key="$(query expo-base-plan.yml 'by_uses("plan", "rnw-community/mobile-ci/actions/expo-native-key@")[0]["with"].get("ios-simulator-archs", "")')"
if assert_equals '' "$unwired" 'plan calls not passing ios-simulator-archs' \
    && assert_equals '${{ inputs.ios-simulator-archs }}' "$native_key" 'expo-base-plan -> expo-native-key'; then
    pass_case
fi

case_start 'the warm-up caches the native app under the slice it built'
arches="$(query seed-native-cache.yml '[s["with"]["arch"] for s in by_uses("seed-ios", "rnw-community/mobile-ci/actions/native-app-cache@")]')"
if assert_equals '["${{ inputs.ios-simulator-archs }}", "${{ inputs.ios-simulator-archs }}"]' "$arches" 'native-app-cache arch'; then
    pass_case
fi

case_start 'the test and capture jobs run the same host check'
maestro_script="$(extract_workflow_step_script "$WORKFLOWS/ios-maestro.yml" test "$HOST_STEP" 2>&1 || true)"
capture_script="$(extract_workflow_step_script "$WORKFLOWS/store-screenshots.yml" capture-ios "$HOST_STEP" 2>&1 || true)"
maestro_env="$(query ios-maestro.yml '[s["env"] for s in steps("test") if s.get("name") == "'"$HOST_STEP"'"]')"
capture_env="$(query store-screenshots.yml '[s["env"] for s in steps("capture-ios") if s.get("name") == "'"$HOST_STEP"'"]')"
if [ "$maestro_script" != "$capture_script" ]; then
    fail_case "the two host checks differ: ios-maestro: $maestro_script / store-screenshots: $capture_script"
elif assert_equals '[{"IOS_SIMULATOR_ARCHS": "${{ inputs.ios-simulator-archs }}", "RUNNER_LABELS_INPUT": "test-runner-labels"}]' "$maestro_env" 'ios-maestro host check env' \
    && assert_equals '[{"IOS_SIMULATOR_ARCHS": "${{ inputs.ios-simulator-archs }}", "RUNNER_LABELS_INPUT": "capture-runner-labels"}]' "$capture_env" 'store-screenshots host check env'; then
    pass_case
fi

# host_check <host uname -m> <rosetta: works|missing> [VAR=value ...]
host_check() {
    local host="$1" rosetta="$2"
    shift 2
    workspace="$(new_workflow_workspace "$WORKFLOWS/ios-maestro.yml" test "$HOST_STEP")"
    stub "$workspace" uname "case \"\$1\" in -m) echo '$host' ;; *) echo Darwin ;; esac"
    if [ "$rosetta" = works ]; then
        stub "$workspace" arch 'if [ "$1" = -x86_64 ]; then shift; exec "$@"; fi; exit 1'
    else
        stub "$workspace" arch 'echo "arch: posix_spawnp: $2: Bad CPU type in executable" >&2; exit 1'
    fi
    run_step "$workspace" RUNNER_LABELS_INPUT=test-runner-labels "$@"
}

case_start 'an arm64 slice runs on an arm64 host'
host_check arm64 missing IOS_SIMULATOR_ARCHS=arm64
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))"; then
    pass_case
fi

case_start 'an arm64 slice on an x86_64 host fails closed'
host_check x86_64 missing IOS_SIMULATOR_ARCHS=arm64
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'arm64-only' 'error message' \
    && assert_contains "$(cat "$workspace/log")" 'test-runner-labels' 'names the input to change'; then
    pass_case
fi

case_start 'an x86_64 slice runs natively on an x86_64 host'
host_check x86_64 missing IOS_SIMULATOR_ARCHS=x86_64
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_contains "$(cat "$workspace/log")" 'natively' 'log line'; then
    pass_case
fi

case_start 'an x86_64 slice runs on an arm64 host whose Rosetta 2 executes x86_64 code'
host_check arm64 works IOS_SIMULATOR_ARCHS=x86_64
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_contains "$(cat "$workspace/log")" 'Rosetta 2' 'log line'; then
    pass_case
fi

case_start 'an x86_64 slice on an arm64 host without Rosetta 2 fails closed'
host_check arm64 missing IOS_SIMULATOR_ARCHS=x86_64
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'softwareupdate --install-rosetta' 'error message'; then
    pass_case
fi

case_start 'an unknown slice fails closed on any host'
rejected=''
for archs in '' i386 'arm64 x86_64'; do
    host_check arm64 works IOS_SIMULATOR_ARCHS="$archs"
    if [ "$STEP_STATUS" -eq 0 ] || ! grep -q "ios-simulator-archs must be" "$workspace/log"; then
        rejected="$rejected '$archs'"
    fi
done
if assert_equals '' "$rejected" 'values accepted'; then
    pass_case
fi

finish_suite
