#!/usr/bin/env bash
# Which runner a pull request claims is decided twice: once when the strategy
# is resolved from the input and the pull request's labels, and once when the
# per-target plans are folded into the list of targets a native build still has
# to serve. Both decisions are extracted from the real workflows here.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

IOS_WORKFLOW="$REPO_ROOT/.github/workflows/ios-maestro.yml"
ANDROID_WORKFLOW="$REPO_ROOT/.github/workflows/android-maestro.yml"
PLAN_WORKFLOW="$REPO_ROOT/.github/workflows/expo-base-plan.yml"
STRATEGY_STEP='Resolve the build strategy'
COLLECT_STEP='Collect the targets whose native key has no base'
LABEL='mobile: force native build'

strategy_workspace() {
    new_workflow_workspace "$IOS_WORKFLOW" detect "$STRATEGY_STEP"
}

resolve() {
    local dir="$1" requested="$2" labels="$3"
    run_step "$dir" \
        REQUESTED_STRATEGY="$requested" \
        NATIVE_BUILD_LABEL="$LABEL" \
        PULL_REQUEST_LABELS="$labels"
}

case_start 'both e2e workflows resolve the strategy with the same script'
ios_script="$(extract_workflow_step_script "$IOS_WORKFLOW" detect "$STRATEGY_STEP")"
android_script="$(extract_workflow_step_script "$ANDROID_WORKFLOW" detect "$STRATEGY_STEP")"
if [ "$ios_script" != "$android_script" ]; then
    fail_case 'ios-maestro and android-maestro state the strategy rule differently, so a label can mean one thing on one platform and another on the other'
else
    pass_case
fi

case_start 'auto is the strategy when nothing asks for anything else'
dir="$(strategy_workspace)"
resolve "$dir" auto '[]'
assert_equals 0 "$STEP_STATUS" 'resolve exit status' \
    && assert_equals 'auto' "$(step_output "$dir" strategy)" 'strategy' \
    && pass_case

case_start 'the force-native label turns auto into native'
dir="$(strategy_workspace)"
resolve "$dir" auto "[\"$LABEL\"]"
assert_equals 0 "$STEP_STATUS" 'resolve exit status' \
    && assert_equals 'native' "$(step_output "$dir" strategy)" 'strategy' \
    && assert_contains "$(cat "$dir/log")" 'No base binary is published by this run' 'notice' \
    && pass_case

case_start 'an unrelated label leaves auto alone'
dir="$(strategy_workspace)"
resolve "$dir" auto '["dependencies","mobile: force native builds"]'
assert_equals 0 "$STEP_STATUS" 'resolve exit status' \
    && assert_equals 'auto' "$(step_output "$dir" strategy)" 'strategy' \
    && pass_case

case_start 'native warns that it is a regression'
dir="$(strategy_workspace)"
resolve "$dir" native '[]'
assert_equals 0 "$STEP_STATUS" 'resolve exit status' \
    && assert_equals 'native' "$(step_output "$dir" strategy)" 'strategy' \
    && assert_contains "$(cat "$dir/log")" '::warning::' 'regression warning' \
    && pass_case

case_start 'repack and the force-native label together fail closed'
dir="$(strategy_workspace)"
resolve "$dir" repack "[\"$LABEL\"]"
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case "the contradiction resolved to '$(step_output "$dir" strategy)' instead of failing"
else
    assert_contains "$(cat "$dir/log")" 'Remove one of the two' 'error message' && pass_case
fi

case_start 'an unknown strategy fails closed'
dir="$(strategy_workspace)"
resolve "$dir" always-native '[]'
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case "an unknown strategy resolved to '$(step_output "$dir" strategy)'"
else
    assert_contains "$(cat "$dir/log")" "must be 'auto', 'repack' or 'native'" 'error message' && pass_case
fi

# plan_workspace <plan json>... — one plan artifact directory per argument, laid
# out the way actions/download-artifact leaves a pattern download.
plan_workspace() {
    local dir index=0 plan
    dir="$(new_workflow_workspace "$PLAN_WORKFLOW" collect "$COLLECT_STEP")"
    for plan in "$@"; do
        mkdir -p "$dir/work/.ci-artifacts/plans/ios-e2e-plan-$index"
        printf '%s' "$plan" > "$dir/work/.ci-artifacts/plans/ios-e2e-plan-$index/plan.json"
        index=$((index + 1))
    done
    printf '%s\n' "$dir"
}

TARGETS='[{"name":"bare","appDir":"apps/mobile"},{"name":"ai","appDir":"apps/ai"}]'
BARE_REPACKED='{"name":"bare","appDir":"apps/mobile","nativeKey":"k1-aaaaaaaaaaaa","needsNative":false}'
BARE_NATIVE='{"name":"bare","appDir":"apps/mobile","nativeKey":"k1-aaaaaaaaaaaa","needsNative":true}'
AI_REPACKED='{"name":"ai","appDir":"apps/ai","nativeKey":"k2-bbbbbbbbbbbb","needsNative":false}'
AI_NATIVE='{"name":"ai","appDir":"apps/ai","nativeKey":"k2-bbbbbbbbbbbb","needsNative":true}'

case_start 'every target repacked means no native build job at all'
dir="$(plan_workspace "$BARE_REPACKED" "$AI_REPACKED")"
run_step "$dir" TARGETS="$TARGETS"
assert_equals 0 "$STEP_STATUS" 'collect exit status' \
    && assert_equals '[]' "$(step_output "$dir" targets)" 'targets' \
    && pass_case

case_start 'a target with no base is handed to the native build, carrying its key'
dir="$(plan_workspace "$BARE_NATIVE" "$AI_REPACKED")"
run_step "$dir" TARGETS="$TARGETS"
targets="$(step_output "$dir" targets)"
assert_equals 0 "$STEP_STATUS" 'collect exit status' \
    && assert_equals 'bare' "$(jq -r '.[0].name' <<< "$targets")" 'target name' \
    && assert_equals 'k1-aaaaaaaaaaaa' "$(jq -r '.[0].nativeKey' <<< "$targets")" 'native key' \
    && assert_equals '1' "$(jq 'length' <<< "$targets")" 'target count' \
    && assert_not_contains "$targets" 'needsNative' 'the decision itself is not forwarded' \
    && pass_case

case_start 'every target needing a native build is forwarded'
dir="$(plan_workspace "$BARE_NATIVE" "$AI_NATIVE")"
run_step "$dir" TARGETS="$TARGETS"
assert_equals 0 "$STEP_STATUS" 'collect exit status' \
    && assert_equals '2' "$(jq 'length' <<< "$(step_output "$dir" targets)")" 'target count' \
    && pass_case

case_start 'a target whose plan never arrived is not an empty set of native builds'
dir="$(plan_workspace "$BARE_REPACKED")"
run_step "$dir" TARGETS="$TARGETS"
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case "a missing plan collected to '$(step_output "$dir" targets)' instead of failing"
else
    assert_contains "$(cat "$dir/log")" 'Expected one plan per target' 'error message' && pass_case
fi

finish_suite
