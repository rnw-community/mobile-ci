#!/usr/bin/env bash
# Issue #220: ios-maestro.yml and android-maestro.yml expose include-tags,
# exclude-tags, junit-report and artifact-retention-days, and each must reach
# every run-maestro-* call the workflow makes. A forgotten `with:` line is
# silently dropped (the action falls back to its default), so only this
# suite notices it.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

check_wiring() {
    WORKFLOW="$1" python3 - <<'PYTHON'
import os
import sys

import yaml

path = os.environ['WORKFLOW']
workflow = yaml.safe_load(open(path, encoding='utf-8'))
inputs = workflow[True]['workflow_call']['inputs']
expected = {
    'include-tags': ('include-tags', 'string', ''),
    'exclude-tags': ('exclude-tags', 'string', ''),
    'junit-report': ('junit-report', 'boolean', True),
    'retention-days': ('artifact-retention-days', 'number', 7),
}
problems = []
for _, (name, kind, default) in expected.items():
    spec = inputs.get(name)
    if spec is None:
        problems.append(f'input {name!r} is missing')
    elif spec.get('type') != kind or spec.get('default') != default:
        problems.append(f'input {name!r} is {spec.get("type")!r} defaulting to {spec.get("default")!r}, expected {kind!r} defaulting to {default!r}')
calls = 0
for job_id, job in workflow['jobs'].items():
    for step in job.get('steps', []):
        if '/actions/run-maestro-' not in str(step.get('uses', '')):
            continue
        calls += 1
        given = step.get('with', {})
        for action_input, (name, _, _) in expected.items():
            want = '${{ inputs.' + name + ' }}'
            if given.get(action_input) != want:
                problems.append(f"job {job_id!r} step {step.get('name')!r} passes {action_input}: {given.get(action_input)!r}, expected {want!r}")
if calls == 0:
    problems.append('no run-maestro-* call found')
if problems:
    print('\n'.join(problems))
    sys.exit(1)
PYTHON
}

for workflow in ios-maestro android-maestro; do
    case_start "$workflow.yml threads tag selection, JUnit and artifact retention to every shard"
    if output="$(check_wiring "$REPO_ROOT/.github/workflows/$workflow.yml" 2>&1)"; then
        pass_case
    else
        fail_case "$output"
    fi
done

case_start 'ios-maestro.yml tolerate-test-failures defaults off and only softens the Maestro run steps'
if output="$(WORKFLOW_YML="$REPO_ROOT/.github/workflows/ios-maestro.yml" python3 - <<'PYTHON' 2>&1
import os, sys, yaml
workflow = yaml.safe_load(open(os.environ['WORKFLOW_YML'], encoding='utf-8'))
spec = workflow.get('on', workflow.get(True))['workflow_call']['inputs'].get('tolerate-test-failures')
problems = []
if not spec or spec.get('type') != 'boolean' or spec.get('default') is not False:
    problems.append(f'tolerate-test-failures must be a boolean defaulting to false, got {spec!r}')
want = '${{ inputs.tolerate-test-failures }}'
runs, report = 0, False
for job in workflow['jobs'].values():
    for step in job.get('steps', []):
        uses = str(step.get('uses', ''))
        if '/actions/run-maestro-ios@' in uses or '/actions/run-maestro-device-cloud@' in uses:
            runs += 1
            if step.get('continue-on-error') != want:
                problems.append(f"{step.get('name')!r} continue-on-error is {step.get('continue-on-error')!r}, expected {want!r}")
        elif step.get('continue-on-error') == want:
            problems.append(f"{step.get('name')!r} is softened but is not a Maestro run step")
        if "outcome == 'failure'" in str(step.get('if', '')) and '::warning::' in str(step.get('run', '')):
            report = True
if runs != 2:
    problems.append(f'expected 2 Maestro run steps, found {runs}')
if not report:
    problems.append('no step reports a tolerated failure as a ::warning::')
print('\n'.join(problems))
sys.exit(1 if problems else 0)
PYTHON
)"; then
    pass_case
else
    fail_case "$output"
fi

finish_suite
