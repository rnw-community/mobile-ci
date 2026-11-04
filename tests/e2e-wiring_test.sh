#!/usr/bin/env bash
# ios-e2e.yml and android-e2e.yml run their e2e suites through the one
# e2e-suite action, wired the same way: validate in detect, run and release in
# the e2e job.
# store-screenshots' e2e capture installs the same package and releases leases
# through the same action.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

# check <python expression over w (the parsed workflow), job(id), step(job, name)>
check() {
    WORKFLOW="$1" EXPR="$2" python3 - <<'PYTHON'
import os, sys, yaml
w = yaml.safe_load(open(os.environ['WORKFLOW']))
inputs = w[True]['workflow_call']['inputs']
secrets = w[True]['workflow_call'].get('secrets', {})
def job(name):
    return w['jobs'][name]
def step(job_name, name):
    for s in job(name=job_name)['steps']:
        if s.get('name') == name or s.get('id') == name:
            return s
    sys.exit(f'no step {name!r} in job {job_name!r}')
import re
def pinned(uses, action):
    """A self-reference to `action` pinned to a release tag (the tag itself moves with every release)."""
    return re.fullmatch(rf'rnw-community/mobile-ci/actions/{re.escape(action)}@v\d+\.\d+\.\d+', uses or '') is not None
problems = eval(os.environ['EXPR'])
if problems:
    print(problems)
    sys.exit(1)
PYTHON
}


for platform in ios android; do
    workflow="$REPO_ROOT/.github/workflows/$platform-e2e.yml"
    # shellcheck disable=SC2016 # the literal expressions the workflow must carry.
    case "$platform" in
        ios) abis='${{ inputs.ios-simulator-archs }}' app=Base.app ;;
        android) abis='${{ steps.android-abis.outputs.built }}' app=app-release.apk ;;
    esac

    case_start "$platform-e2e: detect validates the e2e call through e2e-suite"
    # shellcheck disable=SC2016 # the literal expressions the workflow must carry.
    if out="$(check "$workflow" "[p for p in [
        not pinned(step('detect', 'Validate the e2e call').get('uses'), 'e2e-suite') and 'uses',
        step('detect', 'Validate the e2e call')['with'] != {'mode': 'validate', 'platform': '$platform',
            'abis': '$abis',
            'e2e-dir': '\${{ inputs.e2e-dir }}', 'workers': '\${{ inputs.e2e-workers }}', 'retries': '\${{ inputs.e2e-retries }}',
            'simlock-url': '\${{ inputs.simlock-url }}', 'simlock-token': '\${{ secrets.simlock-token }}'} and step('detect', 'Validate the e2e call')['with'],
    ] if p]")"; then pass_case; else fail_case "$out"; fi

    case_start "$platform-e2e: the e2e job runs the suite and releases its leases on every exit path"
    # shellcheck disable=SC2016
    if out="$(check "$workflow" "[p for p in [
        not pinned(step('e2e', 'run').get('uses'), 'e2e-suite') and 'run uses',
        {k: v for k, v in step('e2e', 'run')['with'].items() if k in ('mode', 'platform')} != {'mode': 'run', 'platform': '$platform'} and 'run mode',
        not step('e2e', 'run')['with']['app-path'].endswith('-\${{ matrix.target.name }}/$app') and step('e2e', 'run')['with']['app-path'],
        step('e2e', 'run')['with']['simlock-token'] != '\${{ secrets.simlock-token }}' and 'run token',
        step('e2e', 'Release the devices the suite left leased')['if'] != \"\${{ always() && steps.run.outcome != 'skipped' }}\" and 'release if',
        step('e2e', 'Release the devices the suite left leased')['with'].get('mode') != 'release' and 'release mode',
        step('e2e', 'Upload the e2e report')['with']['name'] != 'e2e-$platform\${{ needs.detect.outputs.artifact-scope }}-\${{ matrix.target.name }}' and 'artifact name',
    ] if p]")"; then pass_case; else fail_case "$out"; fi

    # suuudokuuu run 41797995373: both workflows named their sessions alike, and the farm refused the second job's leases.
    case_start "$platform-e2e: the e2e session name carries the platform, so overlapping jobs of one run never share one"
    # shellcheck disable=SC2016
    if out="$(check "$workflow" "[p for p in [
        step('e2e', 'run')['with']['session'] != 'e2e-$platform-\${{ github.run_id }}-\${{ github.run_attempt }}\${{ needs.detect.outputs.artifact-scope }}-\${{ matrix.target.name }}' and step('e2e', 'run')['with']['session'],
    ] if p]")"; then pass_case; else fail_case "$out"; fi

    case_start "$platform-e2e: the e2e job gates the cached pass and the status"
    # shellcheck disable=SC2016
    if out="$(check "$workflow" "[p for p in [
        \"needs.e2e.result == 'success'\" not in job('cache-pass')['if'] and 'cache-pass if',
        'e2e' not in job('status')['needs'] and 'status needs',
    ] if p]")"; then pass_case; else fail_case "$out"; fi
done

case_start 'both workflows take the same e2e inputs and secret, with the same defaults but the e2e-command target'
# shellcheck disable=SC2016
if out="$(IOS="$REPO_ROOT/.github/workflows/ios-e2e.yml" check "$REPO_ROOT/.github/workflows/android-e2e.yml" "[p for p in [
    (lambda ios: [
        sorted(k for k in ios if k.startswith('e2e-') and not k.startswith('e2e-cache') or k in ('simlock-url',))
            != sorted(k for k in inputs if k.startswith('e2e-') and not k.startswith('e2e-cache') or k in ('simlock-url',)) and 'names',
        [k for k in ('e2e-dir', 'e2e-node-version', 'e2e-install-command', 'e2e-workers', 'e2e-retries', 'e2e-timeout-minutes', 'simlock-url')
            if ios[k].get('default') != inputs[k].get('default')],
        (ios['e2e-command']['default'], inputs['e2e-command']['default']) != ('npx e2e run --target ios', 'npx e2e run --target android') and 'e2e-command',
        'simlock-token' not in secrets and 'secret',
    ])(yaml.safe_load(open(os.environ['IOS']))[True]['workflow_call']['inputs'])
] for p in p if p]")"; then pass_case; else fail_case "$out"; fi

case_start 'store-screenshots installs the package after the e2e project, and releases through e2e-suite'
# shellcheck disable=SC2016
if out="$(check "$REPO_ROOT/.github/workflows/store-screenshots.yml" "[p for p in [
    (lambda names: names.index('Install the e2e project') + 1 != names.index('Install @mobile-ci/e2e-simlock') and names)([s.get('name') for s in job('capture-ios')['steps']]),
    not pinned(step('capture-ios', 'Install @mobile-ci/e2e-simlock').get('uses'), 'e2e-simlock-install') and 'install uses',
    step('capture-ios', 'Install @mobile-ci/e2e-simlock').get('with') != {'e2e-dir': '\${{ inputs.e2e-dir }}'} and 'install with',
    not pinned(step('capture-ios', 'Release the simulators the capture left leased').get('uses'), 'e2e-suite') and 'release uses',
    step('capture-ios', 'Release the simulators the capture left leased')['with'].get('mode') != 'release' and 'release mode',
] if p]")"; then pass_case; else fail_case "$out"; fi

finish_suite
