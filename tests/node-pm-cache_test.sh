#!/usr/bin/env bash
# node-pm-cache replaces actions/setup-node's `cache:`: restore everywhere, save
# only off pull requests as a bounded, non-fatal step. The path/key script is
# extracted from the real action.yml; the save step's guards and the absence of
# any setup-node `cache:` anywhere in the repo are asserted from the parsed YAML.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/node-pm-cache/action.yml"
STEP='Resolve package manager cache path and key'

cache_workspace() {
    local dir
    dir="$(new_workspace "$ACTION" "$STEP")"
    stub "$dir" pnpm 'echo /stores/pnpm'
    stub "$dir" npm 'echo /stores/npm'
    # shellcheck disable=SC2016
    stub "$dir" yarn 'case "$1" in --version) echo "${FAKE_YARN_VERSION:-1.22.22}" ;; cache) echo /stores/yarn-classic ;; config) echo /stores/yarn-berry ;; esac'
    printf '%s\n' "$dir"
}

resolve() {
    local dir="$1" pm="$2"
    shift 2
    run_step "$dir" PACKAGE_MANAGER="$pm" WORKING_DIRECTORY=. RUNNER_ARCH_NAME=ARM64 RUNNER_OS_NAME=macOS "$@"
}

lock_hash() { sha256sum "$1" | cut -d' ' -f1; }

case_start 'pnpm resolves its store path and keys on os, arch, pm and lockfile hash'
dir="$(cache_workspace)"
echo 'lockfileVersion: 9' > "$dir/work/pnpm-lock.yaml"
resolve "$dir" pnpm
expected="node-pm-v1-macOS-ARM64-pnpm-$(lock_hash "$dir/work/pnpm-lock.yaml")"
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals /stores/pnpm "$(step_output "$dir" path)" 'path' \
    && assert_equals "$expected" "$(step_output "$dir" key)" 'key' \
    && assert_equals 'node-pm-v1-macOS-ARM64-pnpm-' "$(step_output "$dir" restore-prefix)" 'restore prefix' \
    && pass_case

case_start 'a changed lockfile changes the key but not the restore prefix'
dir="$(cache_workspace)"
echo a > "$dir/work/pnpm-lock.yaml"
resolve "$dir" pnpm
first="$(step_output "$dir" key)"
dir="$(cache_workspace)"
echo b > "$dir/work/pnpm-lock.yaml"
resolve "$dir" pnpm
if [ "$first" = "$(step_output "$dir" key)" ]; then
    fail_case 'two different lockfiles produced the same key'
else
    assert_equals 'node-pm-v1-macOS-ARM64-pnpm-' "$(step_output "$dir" restore-prefix)" 'restore prefix' && pass_case
fi

case_start 'yarn classic uses yarn cache dir'
dir="$(cache_workspace)"
echo x > "$dir/work/yarn.lock"
resolve "$dir" yarn FAKE_YARN_VERSION=1.22.22
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals /stores/yarn-classic "$(step_output "$dir" path)" 'path' && pass_case

case_start 'yarn berry uses the cacheFolder setting'
dir="$(cache_workspace)"
echo x > "$dir/work/yarn.lock"
resolve "$dir" yarn FAKE_YARN_VERSION=4.5.0
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals /stores/yarn-berry "$(step_output "$dir" path)" 'path' && pass_case

case_start 'npm falls back to npm-shrinkwrap.json when package-lock.json is absent'
dir="$(cache_workspace)"
echo x > "$dir/work/npm-shrinkwrap.json"
resolve "$dir" npm
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals /stores/npm "$(step_output "$dir" path)" 'path' \
    && assert_contains "$(step_output "$dir" key)" "$(lock_hash "$dir/work/npm-shrinkwrap.json")" 'key' && pass_case

case_start 'a missing lockfile fails closed'
dir="$(cache_workspace)"
resolve "$dir" pnpm
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'resolved a key without a lockfile'
else
    assert_contains "$(cat "$dir/log")" 'No pnpm-lock.yaml' 'error' && pass_case
fi

case_start 'an unsupported package manager fails closed'
dir="$(cache_workspace)"
resolve "$dir" bun
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'accepted bun'
else
    assert_contains "$(cat "$dir/log")" "Unsupported package-manager 'bun'" 'error' && pass_case
fi

case_start 'an empty store path fails closed'
dir="$(cache_workspace)"
echo x > "$dir/work/pnpm-lock.yaml"
stub "$dir" pnpm 'true'
resolve "$dir" pnpm
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'accepted an empty cache path'
else
    pass_case
fi

linux_pnpm_workspace() {
    local dir
    dir="$(cache_workspace)"
    # shellcheck disable=SC2016
    stub "$dir" pnpm 'echo "$HOME/setup-pnpm/store/v11"'
    echo 'lockfileVersion: 9' > "$dir/work/pnpm-lock.yaml"
    printf '%s\n' "$dir"
}

case_start 'Linux pnpm shares one key, prefix and cache path literal across architectures and home directories'
x64="$(linux_pnpm_workspace)"
arm64="$(linux_pnpm_workspace)"
run_step "$x64" PACKAGE_MANAGER=pnpm WORKING_DIRECTORY=. RUNNER_ARCH_NAME=X64 RUNNER_OS_NAME=Linux HOME=/home/runner
run_step "$arm64" PACKAGE_MANAGER=pnpm WORKING_DIRECTORY=. RUNNER_ARCH_NAME=ARM64 RUNNER_OS_NAME=Linux HOME=/home/admin
expected="node-pm-v2-Linux-pnpm-$(lock_hash "$x64/work/pnpm-lock.yaml")"
# shellcheck disable=SC2088
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals "$expected" "$(step_output "$x64" key)" 'x64 key' \
    && assert_equals "$expected" "$(step_output "$arm64" key)" 'arm64 key' \
    && assert_equals 'node-pm-v2-Linux-pnpm-' "$(step_output "$arm64" restore-prefix)" 'restore prefix' \
    && assert_equals '~/setup-pnpm/store/v11' "$(step_output "$x64" path)" 'x64 path' \
    && assert_equals '~/setup-pnpm/store/v11' "$(step_output "$arm64" path)" 'arm64 path' \
    && pass_case

case_start 'a Linux pnpm store outside the home directory keeps its absolute path'
dir="$(linux_pnpm_workspace)"
stub "$dir" pnpm 'echo /stores/pnpm'
run_step "$dir" PACKAGE_MANAGER=pnpm WORKING_DIRECTORY=. RUNNER_ARCH_NAME=X64 RUNNER_OS_NAME=Linux HOME=/home/runner
assert_equals /stores/pnpm "$(step_output "$dir" path)" 'path' && pass_case

case_start 'Linux npm stays keyed by architecture, with its absolute path'
dir="$(cache_workspace)"
echo x > "$dir/work/package-lock.json"
run_step "$dir" PACKAGE_MANAGER=npm WORKING_DIRECTORY=. RUNNER_ARCH_NAME=ARM64 RUNNER_OS_NAME=Linux
assert_equals 'node-pm-v1-Linux-ARM64-npm-' "$(step_output "$dir" restore-prefix)" 'restore prefix' \
    && assert_equals /stores/npm "$(step_output "$dir" path)" 'path' && pass_case

SEED_STEP='Add every Linux architecture to the pnpm store being seeded'

seed() {
    local version="$1" fetch_status="${2:-0}" dir
    dir="$(new_workspace "$ACTION" "$SEED_STEP")"
    # shellcheck disable=SC2016
    stub "$dir" pnpm 'case "$1" in
--version) echo "$FAKE_PNPM_VERSION" ;;
fetch)
    printf "%s\n" "$*" >> "$FAKE_LOG"
    printf "%s\n" "${pnpm_config_supported_architectures:-no-env}" >> "$FAKE_LOG"
    printf "%s\n" "${pnpm_config_virtual_store_dir:-no-env}" >> "$FAKE_LOG"
    mkdir -p node_modules
    : > node_modules/.modules.yaml
    : > node_modules/.pnpm-workspace-state-v1.json
    exit "$FAKE_FETCH_STATUS"
    ;;
esac'
    : > "$dir/fetch.log"
    run_step "$dir" WORKING_DIRECTORY=. FAKE_PNPM_VERSION="$version" FAKE_FETCH_STATUS="$fetch_status" FAKE_LOG="$dir/fetch.log"
    printf '%s\n' "$STEP_STATUS" > "$dir/status"
    printf '%s\n' "$dir"
}

case_start 'pnpm 11 seeds both architectures through flags, outside the project'
dir="$(seed 11.28.3)"
log="$(cat "$dir/fetch.log")"
assert_equals 0 "$(cat "$dir/status")" 'exit status' \
    && assert_contains "$log" '--os=linux --cpu=x64 --cpu=arm64 --libc=glibc' 'architecture flags' \
    && assert_contains "$log" "--modules-dir=$dir/runner-temp/" 'modules dir' \
    && assert_contains "$log" "$dir/runner-temp/" 'virtual store dir' \
    && pass_case

case_start 'pnpm 12 rejects those flags on fetch, so it seeds both architectures through the environment'
dir="$(seed 12.14.0)"
log="$(cat "$dir/fetch.log")"
case "$log" in
    *--cpu*) fail_case "pnpm 12 fetch was given --cpu: $log" ;;
    *)
        assert_equals 0 "$(cat "$dir/status")" 'exit status' \
            && assert_contains "$log" '"cpu":["x64","arm64"]' 'supported architectures' \
            && assert_contains "$log" "$dir/runner-temp/" 'virtual store dir' \
            && pass_case
        ;;
esac

case_start 'the seed leaves no node_modules state and no scratch directory behind'
dir="$(seed 12.14.0)"
if [ -e "$dir/work/node_modules" ]; then
    fail_case "left $(find "$dir/work/node_modules" | tr '\n' ' ')"
elif [ -n "$(find "$dir/runner-temp" -mindepth 1 -print)" ]; then
    fail_case 'left a scratch directory in RUNNER_TEMP'
else
    pass_case
fi

case_start 'pnpm older than 10.14 cannot fetch for another architecture: it warns and fetches nothing'
dir="$(seed 9.15.9)"
assert_equals 0 "$(cat "$dir/status")" 'exit status' \
    && assert_equals '' "$(cat "$dir/fetch.log")" 'fetch calls' \
    && assert_contains "$(cat "$dir/log")" '::warning::pnpm 9.15.9' 'warning' \
    && pass_case

case_start 'a failed seed fails the step instead of saving a store that lacks an architecture'
dir="$(seed 11.28.3 1)"
if [ "$(cat "$dir/status")" -eq 0 ]; then
    fail_case 'a failed pnpm fetch reported success'
else
    pass_case
fi

case_start 'the seed runs only for Linux pnpm, off pull requests, after a non-exact restore'
guard="$(ACTION_YML="$ACTION" SEED_STEP="$SEED_STEP" python3 - <<'PYTHON'
import os

import yaml

steps = yaml.safe_load(open(os.environ['ACTION_YML'], encoding='utf-8'))['runs']['steps']
names = [s.get('id') or s.get('name') for s in steps]
seed = next(s for s in steps if s.get('name') == os.environ['SEED_STEP'])
if names.index('restore') > names.index(os.environ['SEED_STEP']):
    print('seed runs before restore')
print(seed['if'])
PYTHON
)"
assert_equals "inputs.package-manager == 'pnpm' && runner.os == 'Linux' && github.event_name != 'pull_request' && steps.restore.outputs.cache-hit != 'true'" "$guard" 'if' && pass_case

case_start 'the action only restores, on every event, with restore-keys, and exposes the path and key a workflow-level save needs'
if ACTION_YML="$ACTION" python3 - <<'PYTHON'
import os
import re
import sys

import yaml

doc = yaml.safe_load(open(os.environ['ACTION_YML'], encoding='utf-8'))
steps = doc['runs']['steps']
problems = []
saves = [s for s in steps if str(s.get('uses', '')).startswith('actions/cache/save@')]
if saves:
    problems.append('the save belongs in the calling workflow, where a step can carry timeout-minutes')
restore = next((s for s in steps if str(s.get('uses', '')).startswith('actions/cache/restore@')), None)
if restore is None:
    problems.append('no actions/cache/restore step')
else:
    if 'if' in restore:
        problems.append('restore must run on every event')
    if not re.fullmatch(r'actions/cache/restore@[0-9a-f]{40}', restore['uses']):
        problems.append(f"{restore['uses']} is not pinned to a full SHA")
    if not restore.get('with', {}).get('restore-keys'):
        problems.append('restore has no restore-keys')
for name in ('cache-hit', 'cache-key', 'path'):
    if name not in doc.get('outputs', {}):
        problems.append(f'missing output {name}')
sys.exit('; '.join(problems) if problems else 0)
PYTHON
then
    pass_case
else
    fail_case 'node-pm-cache action is misconfigured (see above)'
fi

case_start 'no composite action step carries timeout-minutes (the runner rejects the whole job at set-up)'
offenders="$(ACTIONS_ROOT="$REPO_ROOT/actions" python3 - <<'PYTHON'
import glob
import os

import yaml

bad = []
for path in sorted(glob.glob(os.path.join(os.environ['ACTIONS_ROOT'], '*', 'action.yml'))):
    runs = yaml.safe_load(open(path, encoding='utf-8')).get('runs', {})
    for step in runs.get('steps', []) or []:
        if 'timeout-minutes' in step:
            bad.append(f"{os.path.basename(os.path.dirname(path))}: {step.get('name', step.get('uses', '?'))}")
print('\n'.join(bad))
PYTHON
)"
assert_equals '' "$offenders" 'composite steps with timeout-minutes' && pass_case

case_start 'node-pm-cache pins actions/cache to the same SHA as every other use in the repo'
shas="$(grep -rhoE 'actions/cache/(restore|save)@[0-9a-f]{40}' "$REPO_ROOT/actions" "$REPO_ROOT/.github/workflows" | sed 's/.*@//' | sort -u)"
assert_equals 1 "$(printf '%s\n' "$shas" | wc -l | tr -d ' ')" 'distinct actions/cache SHAs' && pass_case

case_start 'no workflow or action lets actions/setup-node cache (its post-step save is unboundable and runs on pull requests)'
offenders="$(WORKFLOW_ROOT="$REPO_ROOT" python3 - <<'PYTHON'
import glob
import os

import yaml

root = os.environ['WORKFLOW_ROOT']
bad = []
for path in glob.glob(f'{root}/.github/workflows/*.yml') + glob.glob(f'{root}/actions/*/action.yml'):
    doc = yaml.safe_load(open(path, encoding='utf-8'))
    jobs = doc.get('jobs', {}).values() if 'jobs' in doc else [doc.get('runs', {})]
    for job in jobs:
        for step in job.get('steps', []):
            if str(step.get('uses', '')).startswith('actions/setup-node@') and 'cache' in (step.get('with') or {}):
                bad.append(os.path.relpath(path, root))
print('\n'.join(bad))
PYTHON
)"
assert_equals '' "$offenders" 'files using setup-node cache:' && pass_case

case_start 'every node-pm-cache restore is followed by a bounded, non-fatal save that skips pull requests and exact hits'
missing="$(WORKFLOW_ROOT="$REPO_ROOT" python3 - <<'PYTHON'
import glob
import os

import yaml

root = os.environ['WORKFLOW_ROOT']
bad = []
for path in sorted(glob.glob(f'{root}/.github/workflows/*.yml')):
    doc = yaml.safe_load(open(path, encoding='utf-8'))
    for job_id, job in doc.get('jobs', {}).items():
        steps = job.get('steps', [])
        where = f'{os.path.basename(path)}:{job_id}'
        restores = [s for s in steps if 'actions/node-pm-cache@' in str(s.get('uses', ''))]
        saves = [s for s in steps if s.get('name') == 'Save package manager cache']
        if not restores and not saves:
            continue
        if len(restores) != 1 or len(saves) != 1:
            bad.append(f'{where}: {len(restores)} restore(s), {len(saves)} save(s)')
            continue
        restore_id = restores[0].get('id')
        save = saves[0]
        cond = str(save.get('if', ''))
        problems = []
        if not str(save.get('uses', '')).startswith('actions/cache/save@'):
            problems.append('save is not actions/cache/save')
        if "github.event_name != 'pull_request'" not in cond:
            problems.append('save runs on pull requests')
        if f"steps.{restore_id}.outputs.cache-hit != 'true'" not in cond:
            problems.append('save re-saves an exact hit')
        if not save.get('timeout-minutes'):
            problems.append('save has no timeout-minutes')
        if save.get('continue-on-error') is not True:
            problems.append('save is not continue-on-error')
        w = save.get('with') or {}
        if w.get('path') != f'${{{{ steps.{restore_id}.outputs.path }}}}' or w.get('key') != f'${{{{ steps.{restore_id}.outputs.cache-key }}}}':
            problems.append('save path/key are not the restore outputs')
        if steps.index(save) < steps.index(restores[0]):
            problems.append('save runs before restore')
        if problems:
            bad.append(f"{where}: {', '.join(problems)}")
print('\n'.join(bad))
PYTHON
)"
assert_equals '' "$missing" 'jobs with a missing or misconfigured save' && pass_case

case_start 'every job that resolves a package manager and installs restores node-pm-cache before the install'
uncached="$(WORKFLOW_ROOT="$REPO_ROOT" python3 - <<'PYTHON'
import glob
import os

import yaml

root = os.environ['WORKFLOW_ROOT']
bad = []
for path in sorted(glob.glob(f'{root}/.github/workflows/*.yml')):
    doc = yaml.safe_load(open(path, encoding='utf-8'))
    for job_id, job in doc.get('jobs', {}).items():
        steps = job.get('steps', [])
        installs = [s for s in steps if 'inputs.install-command' in str((s.get('env') or {}).get('INSTALL_COMMAND', ''))]
        if not installs or not any(s.get('id') == 'package-manager' for s in steps):
            continue
        restores = [i for i, s in enumerate(steps) if 'actions/node-pm-cache@' in str(s.get('uses', ''))]
        if not restores or restores[0] > steps.index(installs[0]):
            bad.append(f'{os.path.basename(path)}:{job_id}')
print('\n'.join(bad))
PYTHON
)"
assert_equals '' "$uncached" 'jobs installing without the package manager cache' && pass_case

finish_suite
