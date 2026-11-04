#!/usr/bin/env bash
# The reusable workflows take masked build and e2e secrets through their
# secrets: block. A secret declared but never threaded to the job that needs it
# is a build that silently runs without it; one threaded into a plain input, a
# job output or an artifact is a secret on the page. This suite reads the
# parsed workflows and pins every hop.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

check() {
    WORKFLOWS_DIR="$REPO_ROOT/.github/workflows" python3 - "$@" <<'PYTHON'
import os
import re
import sys

import yaml

root = os.environ['WORKFLOWS_DIR']
mode = sys.argv[1]
problems = []
APPLY = 'rnw-community/mobile-ci/actions/apply-secret-env@'


def load(name):
    return yaml.safe_load(open(os.path.join(root, name), encoding='utf-8'))


def call(workflow):
    on = workflow.get('on', workflow.get(True))
    return on['workflow_call']


EXPECTED = {
    'ios-e2e.yml': {'build-secrets-env', 'e2e-secrets-env'},
    'android-e2e.yml': {'build-secrets-env', 'e2e-secrets-env'},
    'store-screenshots.yml': {'build-secrets-env', 'e2e-secrets-env'},
    'seed-native-cache.yml': {'build-secrets-env'},
    'expo-base-plan.yml': {'build-secrets-env'},
}

if mode == 'declared':
    for name, wanted in EXPECTED.items():
        secrets = call(load(name)).get('secrets') or {}
        for secret in sorted(wanted):
            if secret not in secrets:
                problems.append(f'{name} declares no {secret} secret')
            elif secrets[secret].get('required') is not False:
                problems.append(f'{name}: {secret} must be optional, or every existing caller breaks')

elif mode == 'plan-calls':
    for name in EXPECTED:
        for job_id, job in load(name)['jobs'].items():
            if 'expo-base-plan.yml@' not in str(job.get('uses', '')):
                continue
            passed = (job.get('secrets') or {}).get('build-secrets-env')
            if passed != '${{ secrets.build-secrets-env }}':
                problems.append(f'{name}:{job_id} calls expo-base-plan without passing build-secrets-env (got {passed!r})')

elif mode == 'build-jobs':
    for name in EXPECTED:
        for job_id, job in load(name)['jobs'].items():
            steps = job.get('steps') or []
            names = [step.get('name') for step in steps]
            if 'Apply build-env' not in names:
                continue
            index = names.index('Apply build-env')
            following = steps[index + 1] if index + 1 < len(steps) else {}
            if following.get('name') != 'Apply build-secrets-env' \
                    or not str(following.get('uses', '')).startswith(APPLY) \
                    or (following.get('with') or {}).get('env') != '${{ secrets.build-secrets-env }}':
                problems.append(f'{name}:{job_id} applies build-env but not build-secrets-env right after it')

elif mode == 'native-key':
    steps = load('expo-base-plan.yml')['jobs']['plan']['steps']
    by_id = {step.get('id'): index for index, step in enumerate(steps) if step.get('id')}
    key = steps[by_id['native-key']]
    if (key.get('with') or {}).get('secrets-digest') != '${{ steps.build-secrets.outputs.digest }}':
        problems.append('expo-native-key is not given the build secrets digest, so rotating a compiled-in secret leaves the key where it was')
    if 'build-secrets' not in by_id or by_id['build-secrets'] > by_id['native-key']:
        problems.append('the build secrets are applied after the native key is computed')
    if 'build-secrets-env' in str(key.get('with', {}).get('extra-env', '')):
        problems.append('a build secret reaches extra-env, which exports its value into the fingerprint evaluation')

elif mode == 'capture-steps':
    jobs = load('store-screenshots.yml')['jobs']
    for job_id in ('capture-ios', 'capture-android'):
        applied = [s.get('with') or {} for s in jobs[job_id]['steps'] if str(s.get('uses', '')).startswith(APPLY) and 'e2e-secrets-env' in str(s.get('with'))]
        if len(applied) != 1 or applied[0].get('allow-multiline') is not False:
            problems.append(f'store-screenshots.yml:{job_id}: e2e-secrets-env is not applied once, single-line')

elif mode == 'containment':
    for name in sorted(os.listdir(root)):
        if not name.endswith('.yml'):
            continue
        workflow = load(name)
        for job_id, job in (workflow.get('jobs') or {}).items():
            for output, value in (job.get('outputs') or {}).items():
                if 'secrets.' in str(value):
                    problems.append(f'{name}:{job_id} output {output} carries a secret')
            for step in job.get('steps') or []:
                label = step.get('name') or step.get('uses')
                if 'secrets.' in str(step.get('run', '')):
                    problems.append(f'{name}:{job_id}:{label} interpolates a secret into run:')
                if 'upload-artifact' in str(step.get('uses', '')) and 'secrets.' in str(step.get('with', '')):
                    problems.append(f'{name}:{job_id}:{label} names a secret in an artifact upload')
                if 'secrets.build-secrets-env' in str(step.get('with', '')) or 'secrets.e2e-secrets-env' in str(step.get('with', '')):
                    if not str(step.get('uses', '')).startswith(APPLY):
                        problems.append(f'{name}:{job_id}:{label} hands a secret to something other than apply-secret-env')

elif mode == 'eas-install':
    for name in ('native-publish.yml', 'native-dev-release.yml'):
        for job_id, job in load(name)['jobs'].items():
            names = [step.get('name') for step in job.get('steps') or []]
            if 'Install dependencies' not in names:
                continue
            if 'Apply EAS_EXTRA_ENV' not in names or names.index('Apply EAS_EXTRA_ENV') > names.index('Install dependencies'):
                problems.append(f'{name}:{job_id} installs and builds without EAS_EXTRA_ENV applied first')
            elif "secrets.EAS_EXTRA_ENV != ''" not in str((job.get('env') or {}).get('HAS_EAS_EXTRA_ENV', '')):
                problems.append(f'{name}:{job_id} gates Apply EAS_EXTRA_ENV on a HAS_EAS_EXTRA_ENV it never sets')

elif mode == 'eas-extra-env':
    for name in ('native-publish.yml', 'native-dev-release.yml', 'store-screenshots.yml'):
        for job_id, job in load(name)['jobs'].items():
            for step in job.get('steps') or []:
                if step.get('name') != 'Apply EAS_EXTRA_ENV':
                    continue
                if not str(step.get('uses', '')).startswith(APPLY) \
                        or (step.get('with') or {}).get('env') != '${{ secrets.EAS_EXTRA_ENV }}':
                    problems.append(f'{name}:{job_id} parses EAS_EXTRA_ENV with its own copy of the secret parser')

if problems:
    sys.exit('\n      '.join(problems))
PYTHON
}

run_case() {
    local description="$1" mode="$2" failure
    case_start "$description"
    if failure="$(check "$mode" 2>&1)"; then
        pass_case
    else
        fail_case "$failure"
    fi
}

run_case 'every workflow that builds or tests declares its secrets, all optional' declared
run_case 'every expo-base-plan call is handed build-secrets-env' plan-calls
run_case 'every job that applies build-env applies build-secrets-env right after it' build-jobs
run_case 'only the build secrets digest, never a value, reaches the native key' native-key
run_case 'each capture job applies e2e-secrets-env once, single-line' capture-steps
run_case 'no secret reaches a run: body, a job output, an artifact upload or a plain input' containment
run_case 'EAS_EXTRA_ENV is parsed by the shared action, not a copy of it' eas-extra-env
run_case 'every native-publish/dev-release job that installs (the plan job too) applies EAS_EXTRA_ENV first' eas-install

finish_suite
