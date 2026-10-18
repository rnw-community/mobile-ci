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

finish_suite
