#!/usr/bin/env bash
# The plan and repack jobs need Node, a JDK and the Android build-tools, never
# /dev/kvm. Defaulting them to the KVM emulator pool made every pull request's
# light jobs queue behind Android emulator shards on the one host that has KVM
# (rnw-community/mobile-ci#169). Their defaults must name a pool without KVM.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

input_default() {
    WORKFLOW="$1" INPUT="$2" python3 - <<'PYTHON'
import os

import yaml

workflow = yaml.safe_load(open(os.environ['WORKFLOW'], encoding='utf-8'))
triggers = workflow.get('on', workflow.get(True))
print(triggers['workflow_call']['inputs'][os.environ['INPUT']]['default'])
PYTHON
}

for spec in ios-maestro:repack-runner-labels android-maestro:repack-runner-labels \
    store-screenshots:repack-runner-labels seed-native-cache:plan-runner-labels \
    expo-base-plan:runner-labels; do
    workflow="${spec%%:*}"
    input="${spec#*:}"
    case_start "$workflow: $input defaults to the non-KVM x86_64 pool"
    default="$(input_default "$REPO_ROOT/.github/workflows/$workflow.yml" "$input")"
    assert_equals '["self-hosted","trf-linux-amd64-2x4"]' "$default" "$input default" && pass_case
done

WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"
BYPASS_ACTION="$REPO_ROOT/actions/runs-on-cache-bypass/action.yml"
BYPASS_STEP='Decide whether the RunsOn cache proxy is in play'

workflow_lint() {
    MODE="$1" WORKFLOWS_DIR="$WORKFLOWS_DIR" ACTIONS_DIR="$REPO_ROOT/actions" python3 - <<'PYTHON'
import glob
import os
import sys

import yaml

# Not reusable workflows: this repo's own CI, release, metrics and consumers.
SKIP = {'self-test.yml', 'release.yml', 'pr-closed-cleanup.yml', 'ci-metrics.yml'}
mode = os.environ['MODE']
bypass_ref = 'rnw-community/mobile-ci/actions/runs-on-cache-bypass@'


def artifact_actions():
    names = set()
    for path in glob.glob(os.path.join(os.environ['ACTIONS_DIR'], '*', 'action.yml')):
        text = open(path, encoding='utf-8').read()
        if 'upload-artifact' in text or 'download-artifact' in text:
            names.add(os.path.basename(os.path.dirname(path)))
    return names


composites = artifact_actions()
problems = []
for path in sorted(glob.glob(os.path.join(os.environ['WORKFLOWS_DIR'], '*.yml'))):
    base = os.path.basename(path)
    if base in SKIP:
        continue
    workflow = yaml.safe_load(open(path, encoding='utf-8'))
    inputs = (workflow.get('on') or workflow.get(True))['workflow_call'].get('inputs', {})
    jobs = workflow['jobs']
    has_bypass = False
    for job_id, job in jobs.items():
        runs_on = job.get('runs-on')
        if mode == 'hardcoded' and isinstance(runs_on, str) and '${{' not in runs_on:
            problems.append(f'{base}:{job_id} runs-on is the literal {runs_on!r}')
        if mode == 'control' and isinstance(runs_on, str) and 'control-runner-labels' in runs_on:
            if inputs.get('control-runner-labels', {}).get('default') != '["ubuntu-latest"]':
                problems.append(f'{base} uses control-runner-labels without the ["ubuntu-latest"] default')
        steps = job.get('steps')
        if steps is None:
            if mode == 'nested' and 'expo-base-plan.yml' in job.get('uses', ''):
                for name in ('control-runner-labels', 'runs-on-cache-bypass'):
                    if f'inputs.{name}' not in str(job.get('with', {}).get(name, '')):
                        problems.append(f'{base}:{job_id} does not thread {name} into expo-base-plan')
            continue
        touches = any(
            'artifact' in str(step.get('uses', '')).split('@')[0].split('/')[-1]
            or any(f'/actions/{name}@' in str(step.get('uses', '')) for name in composites)
            for step in steps
        )
        first = steps[0] if steps else {}
        applied = str(first.get('uses', '')).startswith(bypass_ref)
        has_bypass = has_bypass or applied
        if mode == 'bypass':
            if touches and not applied:
                problems.append(f'{base}:{job_id} touches artifacts but its first step is not the RunsOn bypass')
            if applied and first.get('with', {}).get('enabled') != '${{ inputs.runs-on-cache-bypass }}':
                problems.append(f'{base}:{job_id} bypass is not driven by inputs.runs-on-cache-bypass')
            if any(str(step.get('uses', '')).startswith('runs-on/action') for step in steps):
                problems.append(f'{base}:{job_id} calls runs-on/action directly instead of through the composite')
    if mode == 'bypass' and has_bypass:
        declared = inputs.get('runs-on-cache-bypass', {})
        if declared.get('type') != 'boolean' or declared.get('default') is not False:
            problems.append(f'{base} wires the bypass without an opt-in boolean runs-on-cache-bypass defaulting to false')
if problems:
    sys.stdout.write('\n'.join(problems))
    sys.exit(1)
PYTHON
}

for mode in hardcoded control nested bypass; do
    case_start "workflows: lint mode '$mode' finds no violation"
    if output="$(workflow_lint "$mode" 2>&1)"; then
        pass_case
    else
        fail_case "$output"
    fi
done

case_start 'every reusable workflow with a control job declares control-runner-labels'
missing=''
for workflow in expo-base-plan ios-maestro android-maestro native-dev-release native-publish \
    store-screenshots store-release pr-closed-cleanup-reusable seed-native-cache; do
    default="$(input_default "$WORKFLOWS_DIR/$workflow.yml" control-runner-labels 2>/dev/null || true)"
    [ "$default" = '["ubuntu-latest"]' ] || missing="$missing $workflow"
done
assert_equals '' "$missing" 'workflows lacking the control-runner-labels default' && pass_case

case_start 'the bypass action pins runs-on/action to a full commit SHA'
assert_contains "$(cat "$BYPASS_ACTION")" 'uses: runs-on/action@17b59092eb37ebfdbb034460892887c09100eaa3 # v2.5.0' 'pin' \
    && pass_case

bypass_run() {
    dir="$(new_workspace "$BYPASS_ACTION" "$BYPASS_STEP")"
    run_step "$dir" "$@"
}

case_start 'bypass: disabled does nothing even on a RunsOn runner'
bypass_run ENABLED=false ZCTIONS_RESULTS_URL=https://results.example
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals false "$(step_output "$dir" applied)" 'applied' && pass_case

case_start 'bypass: enabled on a RunsOn runner applies runs-on/action'
bypass_run ENABLED=true ZCTIONS_RESULTS_URL=https://results.example
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals true "$(step_output "$dir" applied)" 'applied' && pass_case

case_start 'bypass: enabled on any other runner is a noted no-op'
bypass_run ENABLED=true ZCTIONS_RESULTS_URL= ZCTIONS_CACHE_URL=
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals false "$(step_output "$dir" applied)" 'applied' \
    && assert_contains "$(cat "$dir/log")" 'not a RunsOn s3-cache runner' 'notice' && pass_case

case_start 'bypass: a value that is neither true nor false fails closed'
bypass_run ENABLED=yes
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" "must be 'true' or 'false'" 'error' && pass_case

finish_suite
