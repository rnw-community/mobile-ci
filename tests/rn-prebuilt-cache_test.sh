#!/usr/bin/env bash
# rn-prebuilt-cache keys React Native's prebuilt tarball cache on the
# installed react-native version, and every job that builds iOS with
# build-ios-app restores it before the build and saves it after, bounded and
# never on a pull request. Ephemeral macOS guests otherwise download the
# ReactNativeCore and ReactNativeDependencies tarballs on every build.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/rn-prebuilt-cache/action.yml"
STEP='Resolve the react-native version and cache path'

resolve() {
    workspace="$(new_workspace "$ACTION" "$STEP")"
    mkdir -p "$workspace/work/apps/mobile"
    run_step "$workspace" APP_DIR=apps/mobile RUNNER_OS_NAME=macOS RUNNER_ARCH_NAME=ARM64 HOME=/Users/admin
}
install_rn() {
    mkdir -p "$workspace/work/node_modules/react-native"
    printf '{"name":"react-native","version":"%s"}' "$1" > "$workspace/work/node_modules/react-native/package.json"
}

case_start 'the key follows the installed react-native version, resolved from app-dir like Node would'
workspace="$(new_workspace "$ACTION" "$STEP")"
mkdir -p "$workspace/work/apps/mobile"
install_rn 0.88.0
run_step "$workspace" APP_DIR=apps/mobile RUNNER_OS_NAME=macOS RUNNER_ARCH_NAME=ARM64 HOME=/Users/admin
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))" \
    && assert_equals rn-prebuilts-v1-macOS-ARM64-0.88.0 "$(step_output "$workspace" key)" key \
    && assert_equals /Users/admin/Library/Caches/ReactNative "$(step_output "$workspace" path)" path; then
    pass_case
fi

case_start 'no installed react-native fails closed'
resolve
if assert_equals 1 "$STEP_STATUS" status \
    && assert_contains "$(cat "$workspace/log")" "::error::Cannot resolve react-native from 'apps/mobile'" error \
    && assert_equals '' "$(step_output "$workspace" key)" key; then
    pass_case
fi

case_start 'a version with characters a cache key cannot carry fails closed'
workspace="$(new_workspace "$ACTION" "$STEP")"
mkdir -p "$workspace/work/apps/mobile"
install_rn '0.88.0 bad'
run_step "$workspace" APP_DIR=apps/mobile RUNNER_OS_NAME=macOS RUNNER_ARCH_NAME=ARM64 HOME=/Users/admin
assert_equals 1 "$STEP_STATUS" status && pass_case

case_start 'the action restores the exact key only, and never saves'
if problems="$(ACTION="$ACTION" python3 - <<'PYTHON'
import os
import yaml

action = yaml.safe_load(open(os.environ['ACTION']))
steps = action['runs']['steps']
problems = []
restore = [s for s in steps if str(s.get('uses', '')).startswith('actions/cache/restore@')]
if len(restore) != 1 or 'restore-keys' in (restore[0].get('with') or {}):
    problems.append('expected one exact-key restore')
if any('actions/cache/save@' in str(s.get('uses', '')) or str(s.get('uses', '')) == 'actions/cache@' for s in steps):
    problems.append('the action saves')
print('; '.join(problems))
PYTHON
)" && assert_equals '' "$problems" problems; then pass_case; fi

case_start 'every build-ios-app job restores the cache before building and saves it after, off pull requests'
missing="$(WORKFLOW_ROOT="$REPO_ROOT" python3 - <<'PYTHON'
import glob
import os

import yaml

bad = []
for path in sorted(glob.glob(f"{os.environ['WORKFLOW_ROOT']}/.github/workflows/*.yml")):
    for job_id, job in (yaml.safe_load(open(path)).get('jobs') or {}).items():
        steps = job.get('steps', [])
        builds = [i for i, s in enumerate(steps) if 'actions/build-ios-app@' in str(s.get('uses', ''))]
        if not builds:
            continue
        where = f'{os.path.basename(path)}:{job_id}'
        restores = [i for i, s in enumerate(steps) if 'actions/rn-prebuilt-cache@' in str(s.get('uses', ''))]
        saves = [i for i, s in enumerate(steps) if s.get('name') == 'Save the React Native prebuilt cache']
        if len(restores) != 1 or len(saves) != 1:
            bad.append(f'{where}: {len(restores)} restore(s), {len(saves)} save(s)')
            continue
        save = steps[saves[0]]
        restore_id = steps[restores[0]].get('id')
        cond = str(save.get('if', ''))
        if not (restores[0] < builds[0] < saves[0]):
            bad.append(f'{where}: not restore, build, save in that order')
        if "github.event_name != 'pull_request'" not in cond or f"steps.{restore_id}.outputs.cache-hit != 'true'" not in cond:
            bad.append(f'{where}: save runs on pull requests or re-saves a hit')
        if not save.get('timeout-minutes') or save.get('continue-on-error') is not True:
            bad.append(f'{where}: save is unbounded or fatal')
print('\n'.join(bad))
PYTHON
)"
assert_equals '' "$missing" 'jobs with a missing or misordered React Native prebuilt cache' && pass_case

finish_suite
