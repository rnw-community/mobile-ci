#!/usr/bin/env bash
# ios-maestro.yml and android-maestro.yml run their e2e suites through the one
# e2e-suite action, wired the same way: validate in detect, run and release in
# the e2e job, Maestro stopped and the result gated as test-framework says.
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
    workflow="$REPO_ROOT/.github/workflows/$platform-maestro.yml"
    # shellcheck disable=SC2016 # the literal expressions the workflow must carry.
    case "$platform" in
        ios) driver=ios-driver abis='${{ inputs.ios-simulator-archs }}' app=Base.app ;;
        android) driver=android-driver abis='${{ steps.android-abis.outputs.built }}' app=app-release.apk ;;
    esac

    case_start "$platform-maestro: detect validates the e2e call through e2e-suite"
    # shellcheck disable=SC2016 # the literal expressions the workflow must carry.
    if out="$(check "$workflow" "[p for p in [
        not pinned(step('detect', 'Validate the e2e call').get('uses'), 'e2e-suite') and 'uses',
        step('detect', 'Validate the e2e call')['with'] != {'mode': 'validate', 'platform': '$platform',
            'test-framework': '\${{ inputs.test-framework }}', 'driver': '\${{ inputs.$driver }}', 'abis': '$abis',
            'e2e-dir': '\${{ inputs.e2e-dir }}', 'workers': '\${{ inputs.e2e-workers }}', 'retries': '\${{ inputs.e2e-retries }}',
            'simlock-url': '\${{ inputs.simlock-url }}', 'simlock-token': '\${{ secrets.simlock-token }}'} and step('detect', 'Validate the e2e call')['with'],
        step('detect', 'targets')['env'].get('TEST_FRAMEWORK') != '\${{ inputs.test-framework }}' and 'targets TEST_FRAMEWORK',
        step('detect', 'targets')['env'].get('E2E_DIR') != '\${{ inputs.e2e-dir }}' and 'targets E2E_DIR',
    ] if p]")"; then pass_case; else fail_case "$out"; fi

    case_start "$platform-maestro: the e2e job runs the suite and releases its leases on every exit path"
    # shellcheck disable=SC2016
    if out="$(check "$workflow" "[p for p in [
        not pinned(step('e2e', 'run').get('uses'), 'e2e-suite') and 'run uses',
        {k: v for k, v in step('e2e', 'run')['with'].items() if k in ('mode', 'platform')} != {'mode': 'run', 'platform': '$platform'} and 'run mode',
        not step('e2e', 'run')['with']['app-path'].endswith('-\${{ matrix.target.name }}/$app') and step('e2e', 'run')['with']['app-path'],
        step('e2e', 'run')['with']['simlock-token'] != '\${{ secrets.simlock-token }}' and 'run token',
        step('e2e', 'run')['continue-on-error'] != \"\${{ inputs.test-framework == 'both' && !inputs.e2e-required }}\" and 'continue-on-error',
        step('e2e', 'Release the devices the suite left leased')['if'] != \"\${{ always() && steps.run.outcome != 'skipped' }}\" and 'release if',
        step('e2e', 'Release the devices the suite left leased')['with'].get('mode') != 'release' and 'release mode',
        step('e2e', 'Upload the e2e report')['with']['name'] != 'e2e-$platform\${{ needs.detect.outputs.artifact-scope }}-\${{ matrix.target.name }}' and 'artifact name',
    ] if p]")"; then pass_case; else fail_case "$out"; fi

    case_start "$platform-maestro: Maestro stops with e2e, and no shadow e2e suite records a cached pass"
    # shellcheck disable=SC2016
    if out="$(check "$workflow" "[p for p in [
        \"inputs.test-framework != 'e2e'\" not in job('test')['if'] and 'test if',
        \"inputs.test-framework != 'maestro'\" not in job('e2e')['if'] and 'e2e if',
        \"(inputs.test-framework != 'both' || (inputs.e2e-required && needs.e2e.result == 'success'))\" not in job('cache-pass')['if'] and 'cache-pass if',
        'e2e' not in job('status')['needs'] and 'status needs',
    ] if p]")"; then pass_case; else fail_case "$out"; fi
done

case_start 'both workflows take the same e2e inputs and secret, with the same defaults but the e2e-command target'
# shellcheck disable=SC2016
if out="$(IOS="$REPO_ROOT/.github/workflows/ios-maestro.yml" check "$REPO_ROOT/.github/workflows/android-maestro.yml" "[p for p in [
    (lambda ios: [
        sorted(k for k in ios if k.startswith('e2e-') and not k.startswith('e2e-cache') or k in ('test-framework', 'simlock-url'))
            != sorted(k for k in inputs if k.startswith('e2e-') and not k.startswith('e2e-cache') or k in ('test-framework', 'simlock-url')) and 'names',
        [k for k in ('test-framework', 'e2e-dir', 'e2e-node-version', 'e2e-install-command', 'e2e-workers', 'e2e-retries', 'e2e-required', 'e2e-timeout-minutes', 'simlock-url')
            if ios[k].get('default') != inputs[k].get('default')],
        (ios['e2e-command']['default'], inputs['e2e-command']['default']) != ('npx e2e run --target ios', 'npx e2e run --target android') and 'e2e-command',
        'simlock-token' not in secrets and 'secret',
    ])(yaml.safe_load(open(os.environ['IOS']))[True]['workflow_call']['inputs'])
] for p in p if p]")"; then pass_case; else fail_case "$out"; fi

case_start 'store-screenshots installs the package after the e2e project, and releases through e2e-suite'
# shellcheck disable=SC2016
if out="$(check "$REPO_ROOT/.github/workflows/store-screenshots.yml" "[p for p in [
    (lambda names: names.index('Install the e2e project') + 1 != names.index('Install @mobile-ci/e2e-simlock') and names)([s.get('name') for s in job('capture-ios-e2e')['steps']]),
    not pinned(step('capture-ios-e2e', 'Install @mobile-ci/e2e-simlock').get('uses'), 'e2e-simlock-install') and 'install uses',
    step('capture-ios-e2e', 'Install @mobile-ci/e2e-simlock').get('with') != {'e2e-dir': '\${{ inputs.e2e-dir }}'} and 'install with',
    not pinned(step('capture-ios-e2e', 'Release the simulators the capture left leased').get('uses'), 'e2e-suite') and 'release uses',
    step('capture-ios-e2e', 'Release the simulators the capture left leased')['with'].get('mode') != 'release' and 'release mode',
] if p]")"; then pass_case; else fail_case "$out"; fi

finish_suite
