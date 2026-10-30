#!/usr/bin/env bash
# ios-maestro.yml's simulator-provider: simlock runs each test shard on a
# simulator the host's simlock worker leases to that one job, so several
# host-mode jobs share one Mac without a VM per shard. The lease must come
# before run-maestro-ios, its UDID must reach run-maestro-ios, and the release
# must run even when the shard failed or was cancelled, or the device stays
# held until its TTL.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

WORKFLOW="$REPO_ROOT/.github/workflows/ios-maestro.yml"
VALIDATE_STEP='Validate the simulator provider'

case_start 'the lease, the UDID hand-off and the always-run release are wired in order'
problems="$(WORKFLOW="$WORKFLOW" python3 - <<'PYTHON'
import os

import yaml

workflow = yaml.safe_load(open(os.environ['WORKFLOW'], encoding='utf-8'))
inputs = workflow[True]['workflow_call']['inputs']
problems = []
expected_inputs = {
    'simulator-provider': ('string', 'image'),
    'simlock-device': ('string', ''),
    'simlock-os': ('string', ''),
    'simlock-device-mode': ('string', 'slim'),
    'simlock-queue-timeout': ('string', '30m'),
    'simlock-version': ('string', '0.3.0'),
}
for name, (kind, default) in expected_inputs.items():
    spec = inputs.get(name)
    if spec is None:
        problems.append(f'input {name!r} is missing')
    elif spec.get('type') != kind or spec.get('default') != default:
        problems.append(f'input {name!r} is {spec.get("type")!r}/{spec.get("default")!r}, expected {kind!r}/{default!r}')

steps = workflow['jobs']['test']['steps']
def index_of(predicate, what):
    for i, step in enumerate(steps):
        if predicate(step):
            return i, step
    problems.append(f'no {what} step in the test job')
    return None, None

simlock = "inputs.simulator-provider == 'simlock'"
local = "inputs.ios-driver == 'local'"
acquire_i, acquire = index_of(lambda s: '/actions/simlock-lease@' in str(s.get('uses', '')) and s.get('with', {}).get('mode') == 'acquire', 'simlock-lease acquire')
run_i, run = index_of(lambda s: s.get('id') == 'run-maestro-ios', 'run-maestro-ios')
release_i, release = index_of(lambda s: '/actions/simlock-lease@' in str(s.get('uses', '')) and s.get('with', {}).get('mode') == 'release', 'simlock-lease release')
if acquire is not None:
    if acquire.get('id') != 'simlock':
        problems.append(f'acquire step id is {acquire.get("id")!r}, expected simlock')
    for needle in (simlock, local):
        if needle not in str(acquire.get('if', '')):
            problems.append(f'acquire step if: lacks {needle!r}')
    want = {
        'device': '${{ inputs.simlock-device }}',
        'os': '${{ inputs.simlock-os }}',
        'device-mode': '${{ inputs.simlock-device-mode }}',
        'ttl': "${{ format('{0}m', inputs.test-timeout-minutes) }}",
        'queue-timeout': '${{ inputs.simlock-queue-timeout }}',
        'simlock-version': '${{ inputs.simlock-version }}',
    }
    for key, value in want.items():
        if acquire['with'].get(key) != value:
            problems.append(f'acquire with.{key} is {acquire["with"].get(key)!r}, expected {value!r}')
if run is not None and run.get('with', {}).get('simulator-udid') != '${{ steps.simlock.outputs.udid }}':
    problems.append(f'run-maestro-ios simulator-udid is {run.get("with", {}).get("simulator-udid")!r}')
if release is not None:
    cond = str(release.get('if', ''))
    for needle in ('always()', simlock, local):
        if needle not in cond:
            problems.append(f'release step if: lacks {needle!r}')
if None not in (acquire_i, run_i, release_i) and not acquire_i < run_i < release_i:
    problems.append(f'steps out of order: acquire {acquire_i}, run {run_i}, release {release_i}')
print('\n'.join(problems))
PYTHON
)"
if assert_equals '' "$problems" 'wiring problems'; then
    pass_case
fi

validate() {
    dir="$(new_workflow_workspace "$WORKFLOW" test "$VALIDATE_STEP")"
    run_step "$dir" SIMULATOR_PROVIDER=image DRIVER=local SIMULATOR_DEVICE='' "$@"
}

case_start 'the image provider and simlock on the local driver are accepted'
ok=1
for provider in image simlock; do
    validate SIMULATOR_PROVIDER="$provider"
    assert_equals 0 "$STEP_STATUS" "$provider status ($(cat "$dir/log"))" || ok=0
done
[ "$ok" -eq 0 ] || pass_case

case_start 'an unknown simulator-provider fails closed'
validate SIMULATOR_PROVIDER=vm
if assert_equals 1 "$STEP_STATUS" status \
    && assert_contains "$(cat "$dir/log")" "::error::simulator-provider 'vm' is neither 'image' nor 'simlock'" error; then
    pass_case
fi

case_start 'simlock needs the local driver'
validate SIMULATOR_PROVIDER=simlock DRIVER=device-cloud
if assert_equals 1 "$STEP_STATUS" status \
    && assert_contains "$(cat "$dir/log")" "::error::simulator-provider 'simlock' needs ios-driver 'local'" error; then
    pass_case
fi

case_start 'simlock and simulator-device together fail closed'
validate SIMULATOR_PROVIDER=simlock SIMULATOR_DEVICE='iPhone 17'
if assert_equals 1 "$STEP_STATUS" status \
    && assert_contains "$(cat "$dir/log")" "::error::simulator-device names an image's simulator; with simulator-provider 'simlock' name the model in simlock-device" error; then
    pass_case
fi

finish_suite
