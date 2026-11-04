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
for workflow in ios-e2e.yml seed-native-cache.yml store-screenshots.yml expo-base-plan.yml; do
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
for pair in ios-e2e.yml:build seed-native-cache.yml:seed-ios store-screenshots.yml:build-ios; do
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
for pair in ios-e2e.yml:plan seed-native-cache.yml:plan-ios store-screenshots.yml:plan-ios; do
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

finish_suite
