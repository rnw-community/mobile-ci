#!/usr/bin/env bash
# Issue #252: a monorepo of packages, each with its own flows, quarantine and
# build strategy, as one ios-maestro.yml / android-maestro.yml call per
# platform, or as several calls in one run. The detect job resolves every
# target's flowsDir, tolerateTestFailures and buildStrategy once, from the
# target or else the call's input, and the later jobs read only the resolved
# target. call-scope keeps several calls in one run from sharing an artifact,
# a plan, a container or a concurrency group.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

IOS_WORKFLOW="$REPO_ROOT/.github/workflows/ios-maestro.yml"
ANDROID_WORKFLOW="$REPO_ROOT/.github/workflows/android-maestro.yml"
STEP="Resolve each target's flows, quarantine and build strategy"
LABEL='mobile: force native build'

# resolve [VAR=value ...] - runs the step in a fresh workspace left in $dir.
resolve() {
    dir="$(new_workflow_workspace "$IOS_WORKFLOW" detect "$STEP")"
    run_step "$dir" FLOWS_DIR=e2e/flows TOLERATE_TEST_FAILURES=false REQUESTED_STRATEGY=auto \
        NATIVE_BUILD_LABEL="$LABEL" PULL_REQUEST_LABELS='[]' CALL_SCOPE='' "$@"
}

field() {
    jq -r --arg name "$2" --arg key "$3" '.[] | select(.name == $name) | .[$key] | tostring' <<< "$(step_output "$1" targets)"
}

expect_failure() {
    local dir="$1" needle="$2"
    if [ "$STEP_STATUS" -eq 0 ]; then
        fail_case "resolved to $(step_output "$dir" targets)"
    else
        assert_contains "$(cat "$dir/log")" "$needle" 'error' && pass_case
    fi
}

case_start 'ios-maestro and android-maestro resolve targets with the same script'
if [ "$(extract_workflow_step_script "$IOS_WORKFLOW" detect "$STEP")" != "$(extract_workflow_step_script "$ANDROID_WORKFLOW" detect "$STEP")" ]; then
    fail_case 'the two platforms resolve a target differently'
else
    pass_case
fi

case_start 'a target without overrides takes every value from the call'
resolve TARGETS='[{"name":"a","appDir":"apps/a"}]'
assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))" \
    && assert_equals 'e2e/flows' "$(field "$dir" a flowsDir)" 'flowsDir' \
    && assert_equals 'false' "$(field "$dir" a tolerateTestFailures)" 'tolerateTestFailures' \
    && assert_equals 'auto' "$(field "$dir" a buildStrategy)" 'buildStrategy' \
    && assert_equals 'apps/a' "$(field "$dir" a appDir)" 'other fields pass through' \
    && assert_equals '' "$(step_output "$dir" artifact-scope)" 'no call-scope, no artifact scope' \
    && pass_case

case_start 'each target overrides flows, quarantine and build strategy on its own'
resolve TOLERATE_TEST_FAILURES=true TARGETS='[
  {"name":"bare","appDir":"p/bare","flowsDir":"p/e2e","tolerateTestFailures":false,"buildStrategy":"native"},
  {"name":"expo","appDir":"p/expo"}]'
assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))" \
    && assert_equals 'p/e2e' "$(field "$dir" bare flowsDir)" 'bare flowsDir' \
    && assert_equals 'false' "$(field "$dir" bare tolerateTestFailures)" 'an explicit false is not replaced by the input' \
    && assert_equals 'native' "$(field "$dir" bare buildStrategy)" 'bare buildStrategy' \
    && assert_equals 'e2e/flows' "$(field "$dir" expo flowsDir)" 'expo flowsDir' \
    && assert_equals 'true' "$(field "$dir" expo tolerateTestFailures)" 'expo tolerateTestFailures' \
    && assert_equals 'auto' "$(field "$dir" expo buildStrategy)" 'expo buildStrategy' \
    && pass_case

case_start 'flows-dir may be empty when every target names its own flowsDir'
resolve FLOWS_DIR='' TARGETS='[{"name":"a","flowsDir":"a/e2e"}]'
assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))" \
    && assert_equals 'a/e2e' "$(field "$dir" a flowsDir)" 'flowsDir' && pass_case

case_start 'a target with no flowsDir and no flows-dir fails closed'
resolve FLOWS_DIR='' TARGETS='[{"name":"a","flowsDir":"a/e2e"},{"name":"b"}]'
expect_failure "$dir" 'flowsDir'

case_start 'the force-native label makes every target native, whatever it asked for'
resolve PULL_REQUEST_LABELS="[\"$LABEL\"]" TARGETS='[{"name":"a","buildStrategy":"auto"},{"name":"b"}]'
assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))" \
    && assert_equals 'native' "$(field "$dir" a buildStrategy)" 'a' \
    && assert_equals 'native' "$(field "$dir" b buildStrategy)" 'b' && pass_case

case_start 'a target asking for repack under the force-native label fails closed'
resolve PULL_REQUEST_LABELS="[\"$LABEL\"]" TARGETS='[{"name":"a","buildStrategy":"repack"}]'
expect_failure "$dir" 'Remove one of the two'

case_start 'an unknown per-target buildStrategy fails closed'
resolve TARGETS='[{"name":"a","buildStrategy":"bare"}]'
expect_failure "$dir" 'buildStrategy must be "auto", "repack" or "native"'

case_start 'a non-boolean tolerateTestFailures fails closed, never a quiet quarantine'
resolve TARGETS='[{"name":"a","tolerateTestFailures":"yes"}]'
expect_failure "$dir" 'tolerateTestFailures'

case_start 'targets that is not an array of objects fails closed'
resolve TARGETS='{"name":"a"}'
expect_failure "$dir" 'targets'

case_start 'call-scope becomes the artifact scope every per-call name carries'
resolve CALL_SCOPE=pkg-a TARGETS='[{"name":"a"}]'
assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))" \
    && assert_equals '-pkg-a-' "$(step_output "$dir" artifact-scope)" 'artifact scope' && pass_case

for scope in 'a--b' '-a' 'a-' 'a b' 'a/b' $'ok\nbad scope'; do
    case_start "call-scope '$scope' fails closed"
    resolve CALL_SCOPE="$scope" TARGETS='[{"name":"a"}]'
    expect_failure "$dir" 'call-scope'
done

check_wiring() {
    WORKFLOW="$1" PLATFORM="$2" python3 - <<'PYTHON'
import os
import re
import sys

import yaml

workflow = yaml.safe_load(open(os.environ['WORKFLOW'], encoding='utf-8'))
platform = os.environ['PLATFORM']
inputs = workflow[True]['workflow_call']['inputs']
jobs = workflow['jobs']
SCOPE = '${{ needs.detect.outputs.artifact-scope }}'
problems = []

spec = inputs.get('call-scope') or {}
if spec.get('type') != 'string' or spec.get('default') != '':
    problems.append(f'call-scope must be a string input defaulting to empty, got {spec!r}')
flows = inputs.get('flows-dir') or {}
if flows.get('required') is not False or flows.get('default') != '':
    problems.append('flows-dir must be optional, defaulting to empty, once a target can name its own flowsDir')
if 'inputs.call-scope' not in str(workflow['concurrency']['group']):
    problems.append('the workflow concurrency group ignores call-scope, so two calls in one run cancel each other')

detect = jobs['detect']['outputs']
if detect.get('targets') != '${{ steps.targets.outputs.targets }}' or detect.get('artifact-scope') != '${{ steps.targets.outputs.artifact-scope }}':
    problems.append('detect does not output the resolved targets and the artifact scope')

plan = jobs['plan']['with']
if plan.get('targets') != '${{ needs.detect.outputs.targets }}':
    problems.append(f"plan reads targets {plan.get('targets')!r}, not the resolved ones")
for key in ('app-artifact-prefix', 'plan-artifact-prefix'):
    if plan.get(key) != f'{platform}-e2e-{key.split("-")[0]}{SCOPE}':
        problems.append(f'plan {key} is {plan.get(key)!r}, not scoped')

test = jobs['test']
if test['strategy']['matrix']['target'] != '${{ fromJSON(needs.detect.outputs.targets) }}':
    problems.append('the test matrix does not read the resolved targets')

build = jobs['build']
group = str(build['concurrency']['group'])
if 'needs.detect.outputs.build-strategy' in group or "matrix.target.buildStrategy != 'native'" not in group:
    problems.append('the build concurrency group does not follow the target build strategy')
if f"'expo-base-build-{{0}}-{{1}}-{platform}{{2}}-{{3}}', github.run_id, github.run_attempt, needs.detect.outputs.artifact-scope, matrix.target.name" not in group:
    problems.append('two calls in one run building a target of the same name share a build concurrency group')

for job_id, job in jobs.items():
    for step in job.get('steps', []):
        name = step.get('name') or step.get('uses')
        text = yaml.safe_dump(step)
        if "needs.detect.outputs.build-strategy" in text:
            problems.append(f'{job_id} {name!r} reads the call strategy, not the target one')
        uses = str(step.get('uses', ''))
        given = step.get('with') or {}
        if 'actions/upload-artifact' in uses or 'actions/download-artifact' in uses:
            if SCOPE not in str(given.get('name', '')):
                problems.append(f'{job_id} {name!r} artifact {given.get("name")!r} is not scoped')
        if '/actions/run-maestro-' in uses:
            if given.get('flows-dir') != '${{ matrix.target.flowsDir }}':
                problems.append(f'{name!r} flows-dir is {given.get("flows-dir")!r}')
            if SCOPE not in str(given.get('artifact-name', '')):
                problems.append(f'{name!r} artifact-name is not scoped')
            if step.get('continue-on-error') != '${{ matrix.target.tolerateTestFailures }}':
                problems.append(f'{name!r} continue-on-error is {step.get("continue-on-error")!r}')
            if 'container-name' in given and SCOPE not in str(given['container-name']):
                problems.append(f'{name!r} container-name is shared by every call on the host')
        for value in (step.get('env') or {}).values():
            if re.search(rf'{platform}-e2e-app-\$', str(value)):
                problems.append(f'{job_id} {name!r} names the app artifact without the scope: {value!r}')
if problems:
    sys.exit('; '.join(problems))
PYTHON
}

for platform in ios android; do
    case_start "$platform-maestro.yml: every per-call name is scoped and every job reads the resolved target"
    workflow="$IOS_WORKFLOW"
    [ "$platform" = android ] && workflow="$ANDROID_WORKFLOW"
    if failure="$(check_wiring "$workflow" "$platform" 2>&1)"; then
        pass_case
    else
        fail_case "$failure"
    fi
done

finish_suite
