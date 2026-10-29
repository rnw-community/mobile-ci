#!/usr/bin/env bash
# ios-maestro's ios-driver and android-maestro's android-driver can hand the
# flows to Device Cloud instead of a device the runner boots. What must hold:
# an unknown driver never skips every test step into a green check; the
# device-cloud leg runs on a plain Linux pool with no simulator/KVM step;
# a hook that only makes sense on a local device fails rather than silently
# never running; and the artifact the status/reporting side reads keeps its
# name.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

IOS_WORKFLOW="$REPO_ROOT/.github/workflows/ios-maestro.yml"
ANDROID_WORKFLOW="$REPO_ROOT/.github/workflows/android-maestro.yml"
STEP='Validate the test driver'

validate() {
    local dir="$1"
    shift
    run_step "$dir" \
        DRIVER=device-cloud DRIVER_INPUT=ios-driver LOCAL_DRIVERS=local \
        HAS_DEVICE_CLOUD_API_KEY=true \
        PRE_RUN_FLOW='' FLOW_RECOVERY_FLOW='' PRE_TEST_COMMAND='' PRE_FLOW_COMMAND='' \
        SHARD_COUNT=1 SHARD_MANIFEST_DIR='' SHARD_TIMINGS_FILE='' \
        "$@"
}

case_start 'both workflows validate the driver with the same script'
if [ "$(extract_workflow_step_script "$IOS_WORKFLOW" test "$STEP")" != "$(extract_workflow_step_script "$ANDROID_WORKFLOW" test "$STEP")" ]; then
    fail_case 'ios-maestro and android-maestro validate the test driver differently'
else
    pass_case
fi

case_start 'an unknown driver fails instead of skipping every test step'
dir="$(new_workflow_workspace "$IOS_WORKFLOW" test "$STEP")"
validate "$dir" DRIVER=cloud
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" "Unsupported ios-driver 'cloud'" 'error' \
    && pass_case

case_start 'a local driver passes without a Device Cloud key'
dir="$(new_workflow_workspace "$ANDROID_WORKFLOW" test "$STEP")"
validate "$dir" DRIVER=redroid DRIVER_INPUT=android-driver LOCAL_DRIVERS='avd redroid' HAS_DEVICE_CLOUD_API_KEY=false PRE_TEST_COMMAND='seed.sh'
assert_equals 0 "$STEP_STATUS" 'exit status' && pass_case

case_start 'device-cloud without the API key fails closed'
dir="$(new_workflow_workspace "$IOS_WORKFLOW" test "$STEP")"
validate "$dir" HAS_DEVICE_CLOUD_API_KEY=false
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" 'device-cloud-api-key secret is empty' 'error' \
    && pass_case

case_start 'device-cloud refuses every hook that needs a local device'
dir="$(new_workflow_workspace "$IOS_WORKFLOW" test "$STEP")"
validate "$dir" PRE_RUN_FLOW=prime.yaml PRE_TEST_COMMAND=seed.sh
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" 'cannot honour: pre-run-flow pre-test-command' 'error' \
    && pass_case

case_start 'device-cloud explains that it submits once instead of sharding'
dir="$(new_workflow_workspace "$IOS_WORKFLOW" test "$STEP")"
validate "$dir" SHARD_COUNT=3
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" '::notice::Device Cloud runs the flows in parallel itself' 'notice' \
    && pass_case

wiring() {
    WORKFLOW="$1" DRIVER_INPUT="$2" LOCAL_STEPS="$3" HOST_STEPS="$4" PLATFORM="$5" python3 - <<'PYTHON'
import os
import sys

import yaml

workflow = yaml.safe_load(open(os.environ['WORKFLOW'], encoding='utf-8'))
driver = os.environ['DRIVER_INPUT']
on = workflow.get('on', workflow.get(True))['workflow_call']
job = workflow['jobs']['test']
steps = job['steps']
by_name = {step.get('name'): step for step in steps}
problems = []

if 'device-cloud-api-key' not in (on.get('secrets') or {}):
    problems.append('no device-cloud-api-key secret is declared')
for name in ('device-cloud-runner-labels', 'device-cloud-cli-version'):
    if name not in on['inputs']:
        problems.append(f'no {name} input')
if on['inputs']['device-cloud-cli-version'].get('default') != '5.7.1':
    problems.append('the Device Cloud CLI is not pinned to an exact version by default')
if f"inputs.{driver} == 'device-cloud' && (inputs.device-cloud-runner-labels != '' && inputs.device-cloud-runner-labels || inputs.repack-runner-labels)" not in job['runs-on']:
    problems.append(f"the device-cloud test job does not run on the plain Linux pool: {job['runs-on']}")
if f"inputs.{driver} == 'device-cloud' && fromJSON('[0]')" not in str(job['strategy']['matrix']['shard-index']):
    problems.append('device-cloud still fans out one job per shard')

for name in os.environ['LOCAL_STEPS'].split(','):
    step = by_name.get(name)
    if step is None or "== 'device-cloud'" in str(step.get('if', '')) or not str(step.get('if', '')):
        problems.append(f'{name} is not gated to its local driver')
for name in filter(None, os.environ['HOST_STEPS'].split(',')):
    if str(by_name.get(name, {}).get('if', '')) != f"inputs.{driver} != 'device-cloud'":
        problems.append(f'{name} still runs on the device-cloud leg')

dc = by_name.get('run-maestro-device-cloud') or {}
inputs = dc.get('with') or {}
if dc.get('if') != f"inputs.{driver} == 'device-cloud'":
    problems.append('run-maestro-device-cloud is not gated on the device-cloud driver')
if inputs.get('platform') != os.environ['PLATFORM']:
    problems.append(f"run-maestro-device-cloud platform is {inputs.get('platform')!r}")
local = by_name[os.environ['LOCAL_STEPS'].split(',')[0]]['with']
for key in ('artifact-name', 'artifacts-dir', 'retention-days', 'flows-dir', 'flows-name-pattern',
            'flows-exclude-pattern', 'flows-max-depth', 'include-tags', 'exclude-tags', 'maestro-config',
            'maestro-env', 'maestro-version', 'junit-report', 'redact-env-names'):
    if inputs.get(key) != local.get(key):
        problems.append(f'{key} differs from the local driver: {inputs.get(key)!r} vs {local.get(key)!r}')
if inputs.get('retries') != '${{ inputs.flow-retries }}':
    problems.append('flow-retries does not reach --retry')
if inputs.get('api-key') != '${{ secrets.device-cloud-api-key }}':
    problems.append('the API key does not come from the secrets: block')

if "needs.detect.outputs.affected == 'true'" not in str(job.get('if', '')):
    problems.append('the test job (and so the device-cloud leg) is not gated on detect, so force-label cannot start it')
status = workflow['jobs']['status']
if 'test' not in status.get('needs', []) or str(status.get('if')) != 'always()':
    problems.append('status does not read the test job the device-cloud leg runs in')
status_env = status['steps'][-1].get('env') or {}
if status_env.get('TEST_RESULT') != '${{ needs.test.result }}' or not status_env.get('FORCE_LABEL'):
    problems.append('status does not report the device-cloud test result with the force-label it ran under')

names = [step.get('name') for step in steps]
if names.index('Validate the test driver') > names.index('run-maestro-device-cloud'):
    problems.append('the driver is validated after it runs')

if problems:
    sys.exit('; '.join(problems))
PYTHON
}

case_start 'ios-maestro: device-cloud leg is wired like the local one, minus the Mac'
if failure="$(wiring "$IOS_WORKFLOW" ios-driver 'run-maestro-ios' 'Assert this host can run the packaged simulator architecture,setup-xcode-pinned' ios 2>&1)"; then
    pass_case
else
    fail_case "$failure"
fi

case_start 'android-maestro: device-cloud leg is wired like the local ones, minus KVM and binder'
if failure="$(wiring "$ANDROID_WORKFLOW" android-driver 'run-maestro-android,run-maestro-android-redroid' '' android 2>&1)"; then
    pass_case
else
    fail_case "$failure"
fi

case_start 'android-maestro accepts device-cloud in its host check and skips the KVM assertions'
dir="$(new_workflow_workspace "$ANDROID_WORKFLOW" test 'Validate android-driver against this runner')"
run_step "$dir" ANDROID_DRIVER=device-cloud
assert_equals 0 "$STEP_STATUS" "exit status ($(cat "$dir/log"))" && pass_case

finish_suite
