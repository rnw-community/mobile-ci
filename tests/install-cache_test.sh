#!/usr/bin/env bash
# install-cache restores what a dependency's install script downloads outside
# the package manager's store, before every install-command a workflow runs, and
# leaves the bounded, non-fatal save to the workflow. The key script is extracted
# from the real action.yml; the wiring of every install-command is asserted from
# the parsed workflows.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/install-cache/action.yml"
STEP='Resolve install cache key'

resolve() {
    local dir
    dir="$(new_workspace "$ACTION" "$STEP")"
    run_step "$dir" RUNNER_OS_NAME=Linux "$@"
    printf '%s\n' "$STEP_STATUS" > "$dir/status"
    printf '%s\n' "$dir"
}

case_start 'paths and key resolve a key prefixed with the runner OS'
dir="$(resolve CACHE_PATHS='node_modules/.pnpm/llama.rn@*/node_modules/llama.rn/ios/rnllama.xcframework' CACHE_KEY=llama.rn-0.13.0-rc.7)"
assert_equals 0 "$(cat "$dir/status")" 'exit status' \
    && assert_equals 'install-cache-v1-Linux-llama.rn-0.13.0-rc.7' "$(step_output "$dir" key)" 'key' \
    && pass_case

case_start 'neither paths nor key leaves the cache off without failing'
dir="$(resolve CACHE_PATHS='' CACHE_KEY='')"
assert_equals 0 "$(cat "$dir/status")" 'exit status' \
    && assert_equals '' "$(step_output "$dir" key)" 'key' \
    && pass_case

case_start 'whitespace-only paths count as no paths'
dir="$(resolve CACHE_PATHS=$'  \n' CACHE_KEY='')"
assert_equals 0 "$(cat "$dir/status")" 'exit status' \
    && assert_equals '' "$(step_output "$dir" key)" 'key' \
    && pass_case

for half in 'CACHE_PATHS=a CACHE_KEY=' 'CACHE_PATHS= CACHE_KEY=k'; do
    case_start "one of paths and key without the other fails closed: ${half//$'\n'/\\n}"
    # shellcheck disable=SC2086
    dir="$(resolve $half)"
    if [ "$(cat "$dir/status")" -eq 0 ]; then
        fail_case 'resolved a half-configured cache'
    else
        assert_contains "$(cat "$dir/log")" 'set together' 'error' && pass_case
    fi
done

case_start 'a key with a comma fails closed'
dir="$(resolve CACHE_PATHS=a CACHE_KEY=a,b)"
if [ "$(cat "$dir/status")" -eq 0 ]; then
    fail_case 'accepted a comma'
else
    assert_contains "$(cat "$dir/log")" 'comma' 'error' && pass_case
fi

case_start 'a key longer than actions/cache accepts fails closed'
dir="$(resolve CACHE_PATHS=a CACHE_KEY="$(printf 'k%.0s' $(seq 1 500))")"
if [ "$(cat "$dir/status")" -eq 0 ]; then
    fail_case 'accepted a key over 512 characters'
else
    assert_contains "$(cat "$dir/log")" '512' 'error' && pass_case
fi

case_start 'the action only restores, never fatally, only when enabled, and exposes what a workflow-level save needs'
if ACTION_YML="$ACTION" python3 - <<'PYTHON'
import os
import re
import sys

import yaml

doc = yaml.safe_load(open(os.environ['ACTION_YML'], encoding='utf-8'))
steps = doc['runs']['steps']
problems = []
if any(str(s.get('uses', '')).startswith('actions/cache/save@') for s in steps):
    problems.append('the save belongs in the calling workflow, where a step can carry timeout-minutes')
restore = next((s for s in steps if str(s.get('uses', '')).startswith('actions/cache/restore@')), None)
if restore is None:
    problems.append('no actions/cache/restore step')
else:
    if restore.get('if') != "steps.resolve.outputs.key != ''":
        problems.append(f"restore guard is {restore.get('if')!r}")
    if restore.get('continue-on-error') is not True:
        problems.append('a failed restore must not fail the job')
    if not re.fullmatch(r'actions/cache/restore@[0-9a-f]{40}', restore['uses']):
        problems.append(f"{restore['uses']} is not pinned to a full SHA")
    if 'restore-keys' in (restore.get('with') or {}):
        problems.append('a prefix restore would hand an install files from another key')
    if (restore.get('with') or {}).get('path') != '${{ inputs.paths }}':
        problems.append('restore path is not the paths input')
outputs = doc.get('outputs', {})
for name in ('cache-hit', 'cache-key', 'paths'):
    if name not in outputs:
        problems.append(f'missing output {name}')
if outputs.get('paths', {}).get('value') != '${{ inputs.paths }}':
    problems.append('paths output must be the exact input, or save and restore compute different cache versions')
sys.exit('; '.join(problems) if problems else 0)
PYTHON
then
    pass_case
else
    fail_case 'install-cache action is misconfigured (see above)'
fi

case_start 'every install-command a workflow runs is wrapped by an install-cache restore and a bounded, non-fatal save under the same guard'
miswired="$(WORKFLOW_ROOT="$REPO_ROOT" python3 - <<'PYTHON'
import glob
import os

import yaml

root = os.environ['WORKFLOW_ROOT']
bad = []
for path in sorted(glob.glob(f'{root}/.github/workflows/*.yml')):
    doc = yaml.safe_load(open(path, encoding='utf-8'))
    name = os.path.basename(path)
    for job_id, job in doc.get('jobs', {}).items():
        steps = job.get('steps', []) or []
        where = f'{name}:{job_id}'
        for index, step in enumerate(steps):
            command = str((step.get('env') or {}).get('INSTALL_COMMAND', ''))
            if not command or 'e2e-install-command' in command or step.get('working-directory'):
                continue
            restores = [i for i, s in enumerate(steps) if 'actions/install-cache@' in str(s.get('uses', ''))]
            saves = [i for i, s in enumerate(steps) if s.get('name') == 'Save install cache']
            if len(restores) != 1 or len(saves) != 1:
                bad.append(f'{where}: {len(restores)} restore(s), {len(saves)} save(s)')
                continue
            restore, save = steps[restores[0]], steps[saves[0]]
            problems = []
            if not restores[0] < index < saves[0]:
                problems.append('restore and save do not wrap the install')
            if restore.get('id') != 'install-cache':
                problems.append('restore id is not install-cache')
            if (restore.get('with') or {}) != {'paths': '${{ inputs.install-cache-paths }}', 'key': '${{ inputs.install-cache-key }}'}:
                problems.append('restore is not fed by install-cache-paths and install-cache-key')
            cond = str(save.get('if', ''))
            install_guard = str(step.get('if', ''))
            if install_guard and str(restore.get('if', '')) != install_guard:
                problems.append('restore lacks the install guard')
            if install_guard and install_guard not in cond:
                problems.append('save lacks the install guard')
            for guard in ("github.event_name != 'pull_request'", "steps.install-cache.outputs.cache-key != ''", "steps.install-cache.outputs.cache-hit != 'true'"):
                if guard not in cond:
                    problems.append(f'save lacks {guard}')
            if not str(save.get('uses', '')).startswith('actions/cache/save@'):
                problems.append('save is not actions/cache/save')
            if not save.get('timeout-minutes'):
                problems.append('save has no timeout-minutes')
            if save.get('continue-on-error') is not True:
                problems.append('save is not continue-on-error')
            if (save.get('with') or {}) != {'path': '${{ steps.install-cache.outputs.paths }}', 'key': '${{ steps.install-cache.outputs.cache-key }}'}:
                problems.append('save path/key are not the restore outputs')
            if problems:
                bad.append(f"{where}: {', '.join(problems)}")
print('\n'.join(sorted(set(bad))))
PYTHON
)"
assert_equals '' "$miswired" 'jobs whose install is not wrapped by the install cache' && pass_case

case_start 'every workflow taking install-command takes install-cache-paths and install-cache-key, and hands them to expo-base-plan'
undeclared="$(WORKFLOW_ROOT="$REPO_ROOT" python3 - <<'PYTHON'
import glob
import os

import yaml

root = os.environ['WORKFLOW_ROOT']
bad = []
for path in sorted(glob.glob(f'{root}/.github/workflows/*.yml')):
    doc = yaml.safe_load(open(path, encoding='utf-8'))
    name = os.path.basename(path)
    on = doc.get('on', doc.get(True, {})) or {}
    inputs = ((on.get('workflow_call') or {}).get('inputs') or {}) if isinstance(on, dict) else {}
    if 'install-command' not in inputs:
        continue
    for wanted in ('install-cache-paths', 'install-cache-key'):
        spec = inputs.get(wanted)
        if not spec:
            bad.append(f'{name}: no {wanted} input')
        elif spec.get('default') != '' or spec.get('type') != 'string':
            bad.append(f"{name}: {wanted} must be an optional string defaulting to ''")
    for job_id, job in doc.get('jobs', {}).items():
        if 'expo-base-plan.yml@' not in str(job.get('uses', '')):
            continue
        given = job.get('with') or {}
        for wanted in ('install-cache-paths', 'install-cache-key'):
            if given.get(wanted) != f'${{{{ inputs.{wanted} }}}}':
                bad.append(f'{name}:{job_id}: does not pass {wanted} to expo-base-plan')
print('\n'.join(bad))
PYTHON
)"
assert_equals '' "$undeclared" 'workflows missing the install-cache inputs' && pass_case

finish_suite
