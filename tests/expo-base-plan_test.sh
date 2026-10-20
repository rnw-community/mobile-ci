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
SCREENSHOTS_WORKFLOW="$REPO_ROOT/.github/workflows/store-screenshots.yml"
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

case_start 'every workflow that builds an Expo app resolves the strategy with the same script'
ios_script="$(extract_workflow_step_script "$IOS_WORKFLOW" detect "$STRATEGY_STEP")"
android_script="$(extract_workflow_step_script "$ANDROID_WORKFLOW" detect "$STRATEGY_STEP")"
screenshots_script="$(extract_workflow_step_script "$SCREENSHOTS_WORKFLOW" validate-manifest "$STRATEGY_STEP")"
if [ "$ios_script" != "$android_script" ]; then
    fail_case 'ios-maestro and android-maestro state the strategy rule differently, so a label can mean one thing on one platform and another on the other'
elif [ "$ios_script" != "$screenshots_script" ]; then
    fail_case 'store-screenshots states the strategy rule differently from the e2e workflows'
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
    local dir plan artifact
    dir="$(new_workflow_workspace "$PLAN_WORKFLOW" collect "$COLLECT_STEP")"
    for plan in "$@"; do
        artifact="${PLAN_ARTIFACT_PREFIX:-ios-e2e-plan}-$(jq -r '.name' <<< "$plan")"
        mkdir -p "$dir/work/.ci-artifacts/plans/$artifact"
        jq -c --arg artifact "$artifact" '. + {planArtifact: $artifact}' <<< "$plan" > "$dir/work/.ci-artifacts/plans/$artifact/plan.json"
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
run_step "$dir" TARGETS="$TARGETS" PLAN_PREFIX=ios-e2e-plan
assert_equals 0 "$STEP_STATUS" 'collect exit status' \
    && assert_equals '[]' "$(step_output "$dir" targets)" 'targets' \
    && pass_case

case_start 'a target with no base is handed to the native build, carrying its key'
dir="$(plan_workspace "$BARE_NATIVE" "$AI_REPACKED")"
run_step "$dir" TARGETS="$TARGETS" PLAN_PREFIX=ios-e2e-plan
targets="$(step_output "$dir" targets)"
assert_equals 0 "$STEP_STATUS" 'collect exit status' \
    && assert_equals 'bare' "$(jq -r '.[0].name' <<< "$targets")" 'target name' \
    && assert_equals 'k1-aaaaaaaaaaaa' "$(jq -r '.[0].nativeKey' <<< "$targets")" 'native key' \
    && assert_equals '1' "$(jq 'length' <<< "$targets")" 'target count' \
    && assert_not_contains "$targets" 'needsNative' 'the decision itself is not forwarded' \
    && pass_case

case_start 'every target needing a native build is forwarded'
dir="$(plan_workspace "$BARE_NATIVE" "$AI_NATIVE")"
run_step "$dir" TARGETS="$TARGETS" PLAN_PREFIX=ios-e2e-plan
assert_equals 0 "$STEP_STATUS" 'collect exit status' \
    && assert_equals '2' "$(jq 'length' <<< "$(step_output "$dir" targets)")" 'target count' \
    && pass_case

case_start 'a target whose plan never arrived is not an empty set of native builds'
dir="$(plan_workspace "$BARE_REPACKED")"
run_step "$dir" TARGETS="$TARGETS" PLAN_PREFIX=ios-e2e-plan
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case "a missing plan collected to '$(step_output "$dir" targets)' instead of failing"
else
    assert_contains "$(cat "$dir/log")" 'Expected one plan per target' 'error message' && pass_case
fi

case_start "another call's plans in the same run are neither counted nor collected (#252)"
dir="$(plan_workspace "$BARE_NATIVE" "$AI_REPACKED")"
mkdir -p "$dir/work/.ci-artifacts/plans/ios-e2e-plan-pkg-b--bare"
printf '%s' '{"name":"bare","appDir":"apps/b","nativeKey":"k9-cccccccccccc","needsNative":true,"planArtifact":"ios-e2e-plan-pkg-b--bare"}' > "$dir/work/.ci-artifacts/plans/ios-e2e-plan-pkg-b--bare/plan.json"
run_step "$dir" TARGETS="$TARGETS" PLAN_PREFIX=ios-e2e-plan
targets="$(step_output "$dir" targets)"
assert_equals 0 "$STEP_STATUS" "collect exit status ($(cat "$dir/log"))" \
    && assert_equals 'apps/mobile' "$(jq -r 'map(.appDir) | join(",")' <<< "$targets")" "only this call's native target" \
    && assert_not_contains "$(step_output "$dir" plans)" 'k9-cccccccccccc' "the sibling's plan is not this call's" \
    && pass_case

case_start 'a lone plan, which download-artifact extracts straight into the path, is still collected'
dir="$(new_workflow_workspace "$PLAN_WORKFLOW" collect "$COLLECT_STEP")"
mkdir -p "$dir/work/.ci-artifacts/plans"
jq -c '. + {planArtifact: "ios-e2e-plan-bare"}' <<< "$BARE_NATIVE" > "$dir/work/.ci-artifacts/plans/plan.json"
run_step "$dir" TARGETS='[{"name":"bare","appDir":"apps/mobile"}]' PLAN_PREFIX=ios-e2e-plan
targets="$(step_output "$dir" targets)"
assert_equals 0 "$STEP_STATUS" "collect exit status ($(cat "$dir/log"))" \
    && assert_equals 'bare' "$(jq -r '.[0].name' <<< "$targets")" 'target collected' \
    && assert_not_contains "$targets" 'planArtifact' 'the plan bookkeeping is not forwarded' \
    && pass_case

case_start 'a scoped call collects exactly its own plans, never the unscoped call of the same run'
dir="$(PLAN_ARTIFACT_PREFIX=ios-e2e-plan-pkg-b- plan_workspace "$BARE_REPACKED" "$AI_NATIVE")"
mkdir -p "$dir/work/.ci-artifacts/plans/ios-e2e-plan-bare"
jq -c '. + {planArtifact: "ios-e2e-plan-bare"}' <<< "$BARE_NATIVE" > "$dir/work/.ci-artifacts/plans/ios-e2e-plan-bare/plan.json"
run_step "$dir" TARGETS="$TARGETS" PLAN_PREFIX=ios-e2e-plan-pkg-b-
assert_equals 0 "$STEP_STATUS" "collect exit status ($(cat "$dir/log"))" \
    && assert_equals 'ai' "$(jq -r 'map(.name) | join(",")' <<< "$(step_output "$dir" targets)")" "only this call's native target" \
    && pass_case

case_start "a target's own buildStrategy decides its base lookup and its repack refusal"
problem="$(PLAN_WORKFLOW="$PLAN_WORKFLOW" python3 - <<'PYTHON'
import os
import yaml

workflow = yaml.safe_load(open(os.environ['PLAN_WORKFLOW'], encoding='utf-8'))
steps = {step.get('name'): step for step in workflow['jobs']['plan']['steps']}
effective = '(matrix.target.buildStrategy || inputs.build-strategy)'
problems = []
if steps['expo-base-binary (fetch)'].get('if') != f"{effective} != 'native'":
    problems.append(f"the base lookup runs when {steps['expo-base-binary (fetch)'].get('if')!r}")
if not str(steps['Refuse to compile native code under build-strategy repack'].get('if', '')).startswith(f"{effective} == 'repack'"):
    problems.append('the repack refusal ignores the target strategy')
if steps["Record this target's plan"]['env'].get('BUILD_STRATEGY') != '${{ ' + effective + ' }}':
    problems.append('the plan summary reports the call strategy')
collect = {step.get('name'): step for step in workflow['jobs']['collect']['steps']}
if collect['Collect the targets whose native key has no base']['env'].get('PLAN_PREFIX') != '${{ inputs.plan-artifact-prefix }}':
    problems.append('collect does not know which plan names are its own')
if steps["Record this target's plan"]['env'].get('PLAN_ARTIFACT') != '${{ inputs.plan-artifact-prefix }}-${{ matrix.target.name }}':
    problems.append('a plan does not record the artifact name it is uploaded under')
if steps["Upload this target's plan"]['with'].get('name') != '${{ inputs.plan-artifact-prefix }}-${{ matrix.target.name }}':
    problems.append('the plan is uploaded under another name than it records')
print('; '.join(problems))
PYTHON
)"
if [ -n "$problem" ]; then
    fail_case "$problem"
else
    pass_case
fi

case_start 'the repack resolves the same build-tools version the plan job installs (#163)'
problem="$(PLAN_WORKFLOW="$PLAN_WORKFLOW" python3 - <<'PYTHON'
import os
import yaml

steps = yaml.safe_load(open(os.environ['PLAN_WORKFLOW'], encoding='utf-8'))['jobs']['plan']['steps']
by_name = {step.get('name'): step for step in steps}
installed = by_name['Set up Android SDK for the repack']['with']['packages']
repack = by_name['expo-repack']['with']
if 'build-tools;${{ inputs.android-build-tools-version }}' not in installed:
    print(f'the SDK step installs {installed!r}, not android-build-tools-version')
elif repack.get('android-build-tools-version') != '${{ inputs.android-build-tools-version }}':
    print(f"expo-repack resolves build-tools version {repack.get('android-build-tools-version')!r}, not the one the SDK step installed")
PYTHON
)"
if [ -n "$problem" ]; then
    fail_case "$problem"
else
    pass_case
fi

case_start 'every job that publishes a base serializes on its native key, and only when it publishes (#162)'
problem="$(REPO_ROOT="$REPO_ROOT" python3 - <<'PYTHON'
import os
import re
import yaml

problems = []
checked = 0
for name in ('ios-maestro', 'android-maestro', 'store-screenshots', 'seed-native-cache'):
    path = os.path.join(os.environ['REPO_ROOT'], '.github', 'workflows', f'{name}.yml')
    for job_id, job in yaml.safe_load(open(path, encoding='utf-8'))['jobs'].items():
        publish = [step for step in job.get('steps', []) if step.get('name') == 'expo-base-binary (publish)']
        if not publish:
            continue
        checked += 1
        where = f'{name}.yml job {job_id}'
        platform = publish[0]['with']['platform']
        concurrency = job.get('concurrency') or {}
        group = str(concurrency.get('group', ''))
        if concurrency.get('cancel-in-progress') is not False:
            problems.append(f'{where}: cancel-in-progress must be false, or a second build cancels the first')
        match = re.fullmatch(
            r"\$\{\{ \((?P<cond>.+)\) && format\('expo-base-publish-\{0\}-(?P<platform>[a-z]+)-\{1\}-\{2\}', github\.repository, inputs\.base-flavor, matrix\.target\.nativeKey\)"
            r" \|\| format\('expo-base-build-\{0\}-\{1\}-(?P<job>[a-z]+)"
            r"(?:-\{2\}', github\.run_id, github\.run_attempt, matrix\.target\.name"
            r"|\{2\}-\{3\}', github\.run_id, github\.run_attempt, needs\.detect\.outputs\.artifact-scope, matrix\.target\.name)\) \}\}",
            group,
        )
        if not match:
            problems.append(f'{where}: concurrency group {group!r} is not keyed on the native key')
            continue
        if match['cond'] != publish[0]['if']:
            problems.append(f"{where}: joins the publish group when {match['cond']!r} but publishes when {publish[0]['if']!r}")
        if match['platform'] != platform:
            problems.append(f"{where}: publishes {platform} but serializes on the {match['platform']} group")
        if match['job'] != platform:
            problems.append(f"{where}: its non-publishing group is not distinct per platform")
if checked != 6:
    problems.append(f'expected 6 publishing jobs, found {checked}')
print('; '.join(problems))
PYTHON
)"
if [ -n "$problem" ]; then
    fail_case "$problem"
else
    pass_case
fi

finish_suite
