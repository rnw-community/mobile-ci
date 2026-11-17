#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

WORKFLOW="$REPO_ROOT/.github/workflows/store-screenshots.yml"
STEP='Validate call-scope'

for scope in '' brand-a brand-b a.b_c; do
    case_start "call-scope '$scope' resolves like Maestro"
    dir="$(new_workflow_workspace "$WORKFLOW" validate-manifest "$STEP")"
    run_step "$dir" CALL_SCOPE="$scope"
    assert_equals 0 "$STEP_STATUS" 'status' \
        && assert_equals "${scope:+-$scope-}" "$(step_output "$dir" artifact-scope)" 'artifact scope' && pass_case
done

for scope in 'a--b' '-a' 'a-' 'a b' 'a/b' 'a*' 'a?' 'a[b]' $'ok\nbad'; do
    case_start "invalid call-scope '$scope' fails closed"
    dir="$(new_workflow_workspace "$WORKFLOW" validate-manifest "$STEP")"
    run_step "$dir" CALL_SCOPE="$scope"
    assert_equals 1 "$STEP_STATUS" 'status' \
        && assert_contains "$(cat "$dir/log")" 'call-scope' 'error' && pass_case
done

case_start 'every artifact, plan, concurrency group and session is scoped; upload isolates calls'
if failure="$(WORKFLOW="$WORKFLOW" python3 - <<'PYTHON'
import fnmatch
import os
import yaml

w = yaml.safe_load(open(os.environ['WORKFLOW']))
scope = '${{ needs.validate-manifest.outputs.artifact-scope }}'
assert w[True]['workflow_call']['inputs']['call-scope'] == {
    'description': w[True]['workflow_call']['inputs']['call-scope']['description'],
    'type': 'string', 'required': False, 'default': ''}
assert w['jobs']['validate-manifest']['outputs']['artifact-scope'] == '${{ steps.scope.outputs.artifact-scope }}'
assert "inputs.call-scope != ''" in w['concurrency']['group']
names = []
for job_id, job in w['jobs'].items():
    if 'concurrency' in job:
        assert 'needs.validate-manifest.outputs.artifact-scope' in job['concurrency']['group'], job_id
    for key in ('app-artifact-prefix', 'plan-artifact-prefix'):
        if key in job.get('with', {}):
            assert scope in job['with'][key], (job_id, key)
            names.append(job['with'][key] + '-app')
    for step in job.get('steps', []):
        if any(action in step.get('uses', '') for action in ('upload-artifact', 'download-artifact')):
            name = step['with'].get('name', step['with'].get('pattern'))
            assert scope in name, (job_id, name)
            names.append(name)
        for key in ('E2E_SESSION', 'ARTIFACT_SCOPE'):
            if key in step.get('env', {}):
                assert scope in step['env'][key], (job_id, key)
        if 'container-name' in step.get('with', {}):
            assert scope in step['with']['container-name'], job_id
pattern = next(s['with']['pattern'] for s in w['jobs']['upload']['steps'] if s.get('name') == 'Download raw screenshots')
def resolve(value, call):
    return value.replace(scope, f'-{call}-' if call else '')
for call in ('brand', 'brand-a', 'brand-b'):
    own = [resolve(n, call) for n in names]
    other = [resolve(n, 'another') for n in names]
    assert set(own).isdisjoint(other)
    for job_id in ('capture-ios', 'capture-android', 'capture-ios-e2e', 'capture-android-e2e'):
        raw = next(s['with']['name'] for s in w['jobs'][job_id]['steps']
                   if 'upload-artifact' in s.get('uses', '') and s['with']['name'].startswith('raw-screenshots'))
        assert fnmatch.fnmatchcase(resolve(raw, call), resolve(pattern, call))
        for other_call in ('another', call + '-nested'):
            assert not fnmatch.fnmatchcase(resolve(raw, other_call), resolve(pattern, call))
assert {resolve(n, '') for n in names} == {
    'store-screenshots-app-app', 'store-screenshots-apk-app',
    'store-screenshots-ios-plan-app', 'store-screenshots-android-plan-app',
    'store-screenshots-app-${{ matrix.name }}',
    'store-screenshots-apk-${{ matrix.name }}',
    'store-screenshots-app-${{ fromJSON(needs.validate-manifest.outputs.ios-target).name }}',
    'store-screenshots-apk-${{ fromJSON(needs.validate-manifest.outputs.android-target).name }}',
    'raw-screenshots-ios-${{ steps.capture.outputs.device-slug }}',
    'raw-screenshots-android-${{ steps.capture.outputs.device-slug }}',
    'raw-screenshots-ios-${{ steps.plan.outputs.device-slug }}',
    'raw-screenshots-android-${{ steps.plan.outputs.device-slug }}',
    'e2e-screenshots-ios-${{ steps.plan.outputs.device-slug }}',
    'e2e-screenshots-android-${{ steps.plan.outputs.device-slug }}',
    'raw-screenshots-*',
}
PYTHON
)"; then pass_case; else fail_case "$failure"; fi

for call in '' brand-a brand-b; do
    case_start "iOS archive and both capture unpack steps agree for scope '$call'"
    artifact_scope="${call:+-$call-}"
    archive="$(new_workflow_workspace "$WORKFLOW" build-ios 'Archive app for the capture job')"
    mkdir -p "$archive/work/.ci-cache/ios-native-app/app/Base.app"
    printf 'app bundle' > "$archive/work/.ci-cache/ios-native-app/app/Base.app/binary"
    run_step "$archive" TARGET_NAME=app ARTIFACT_SCOPE="$artifact_scope"
    assert_equals 0 "$STEP_STATUS" "archive ($(cat "$archive/log"))" || continue
    for job in capture-ios capture-ios-e2e; do
        unpack="$(new_workflow_workspace "$WORKFLOW" "$job" 'Unpack app')"
        destination="$unpack/work/.ci-artifacts/store-screenshots-app${artifact_scope}-app"
        mkdir -p "$destination"
        cp "$archive/work/.ci-artifacts/store-screenshots-app${artifact_scope}-app.tar.gz" "$destination/"
        run_step "$unpack" TARGET_NAME=app ARTIFACT_SCOPE="$artifact_scope"
        assert_equals 0 "$STEP_STATUS" "$job unpack ($(cat "$unpack/log"))" || continue
        assert_equals 'app bundle' "$(cat "$destination/Base.app/binary")" "$job bundle" || continue
    done
    pass_case
done

finish_suite
