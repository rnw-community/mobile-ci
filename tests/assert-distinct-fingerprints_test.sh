#!/usr/bin/env bash
# Two targets with different appIds must never share a native key: the target
# name is not in the key, so such a pair shares one base binary. The comparison
# is one script (scripts/assert-distinct-native-keys.sh) run by the action and,
# through the action, by expo-base-plan.yml's collect job.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/assert-distinct-fingerprints/action.yml"
PLAN_WORKFLOW="$REPO_ROOT/.github/workflows/expo-base-plan.yml"
SCRIPT="$REPO_ROOT/scripts/assert-distinct-native-keys.sh"
STEP='Assert no two appIds share a native key'
COLLECT_STEP='Collect the targets whose native key has no base'

A='{"name":"brand-a","appId":"com.a","appDir":"apps/mobile","nativeKey":"k1-aaaa","fingerprint":"fp1","configHash":"ch1"}'
B_SAME_KEY='{"name":"brand-b","appId":"com.b","appDir":"apps/mobile","nativeKey":"k1-aaaa","fingerprint":"fp1","configHash":"ch1"}'
B_OTHER_KEY='{"name":"brand-b","appId":"com.b","appDir":"apps/mobile","nativeKey":"k2-bbbb"}'
A_DUP='{"name":"brand-a-dup","appId":"com.a","nativeKey":"k1-aaaa"}'

case_start 'different appIds on one key fail, naming both targets, the key and the shared sources'
dir="$(new_workspace "$ACTION" "$STEP")"
run_step "$dir" PLATFORM=ios PLANS="[$A,$B_SAME_KEY]" ASSERT_SCRIPT="$SCRIPT"
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'a shared key between com.a and com.b passed'
else
    log="$(cat "$dir/log")"
    assert_contains "$log" 'brand-a' 'first target' \
        && assert_contains "$log" 'brand-b' 'second target' \
        && assert_contains "$log" 'k1-aaaa' 'key' \
        && assert_contains "$log" 'fingerprint fp1' 'fingerprint source' \
        && assert_contains "$log" 'extraSources' 'fix' \
        && pass_case
fi

case_start 'different appIds on different keys pass'
dir="$(new_workspace "$ACTION" "$STEP")"
run_step "$dir" PLATFORM=ios PLANS="[$A,$B_OTHER_KEY]" ASSERT_SCRIPT="$SCRIPT"
assert_equals 0 "$STEP_STATUS" 'exit status' && pass_case

case_start 'the same appId sharing a key is a legitimate dedupe'
dir="$(new_workspace "$ACTION" "$STEP")"
run_step "$dir" PLATFORM=android PLANS="[$A,$A_DUP]" ASSERT_SCRIPT="$SCRIPT"
assert_equals 0 "$STEP_STATUS" 'exit status' && pass_case

case_start 'a target with no key cannot be proven distinct'
dir="$(new_workspace "$ACTION" "$STEP")"
run_step "$dir" PLATFORM=ios PLANS='[{"name":"brand-a","appId":"com.a","nativeKey":""}]' ASSERT_SCRIPT="$SCRIPT"
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'an empty key passed'
else
    assert_contains "$(cat "$dir/log")" 'no name, appId or nativeKey' 'error message' && pass_case
fi

case_start 'two targets that both omit appId cannot be proven distinct'
dir="$(new_workspace "$ACTION" "$STEP")"
run_step "$dir" PLATFORM=ios PLANS='[{"name":"a","nativeKey":"k"},{"name":"b","nativeKey":"k"}]' ASSERT_SCRIPT="$SCRIPT"
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'targets without appId passed'
else
    pass_case
fi

case_start 'with require-app-id false, targets that all omit appId (the seed-native-cache target shape) skip the comparison with a notice'
dir="$(new_workspace "$ACTION" "$STEP")"
run_step "$dir" PLATFORM=android REQUIRE_APP_ID=false PLANS='[{"name":"a","nativeKey":"k"},{"name":"b","nativeKey":"k"}]' ASSERT_SCRIPT="$SCRIPT"
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" 'No android target declares an appId' 'notice' \
    && pass_case

case_start 'with require-app-id false, a mix of targets with and without appId still fails closed'
dir="$(new_workspace "$ACTION" "$STEP")"
run_step "$dir" PLATFORM=ios REQUIRE_APP_ID=false PLANS='[{"name":"a","appId":"com.a","nativeKey":"k"},{"name":"b","nativeKey":"k"}]' ASSERT_SCRIPT="$SCRIPT"
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'a target without appId next to one with an appId passed'
else
    pass_case
fi

case_start 'with require-app-id false, different appIds on one key still fail'
dir="$(new_workspace "$ACTION" "$STEP")"
run_step "$dir" PLATFORM=ios REQUIRE_APP_ID=false PLANS="[$A,$B_SAME_KEY]" ASSERT_SCRIPT="$SCRIPT"
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'a shared key between com.a and com.b passed'
else
    pass_case
fi

case_start 'a require-app-id other than true or false fails closed'
dir="$(new_workspace "$ACTION" "$STEP")"
run_step "$dir" PLATFORM=ios REQUIRE_APP_ID=maybe PLANS="[$A]" ASSERT_SCRIPT="$SCRIPT"
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case "require-app-id 'maybe' passed"
else
    pass_case
fi

case_start 'plans that are not a JSON array fail closed'
dir="$(new_workspace "$ACTION" "$STEP")"
run_step "$dir" PLATFORM=ios PLANS='not json' ASSERT_SCRIPT="$SCRIPT"
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'garbage plans passed'
else
    pass_case
fi

case_start 'an unknown platform fails closed'
dir="$(new_workspace "$ACTION" "$STEP")"
run_step "$dir" PLATFORM=windows PLANS="[$A]" ASSERT_SCRIPT="$SCRIPT"
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'platform windows passed'
else
    assert_contains "$(cat "$dir/log")" 'Unsupported platform' 'error message' && pass_case
fi

case_start 'the collect job hands every plan, with its key sources, to the check'
dir="$(new_workflow_workspace "$PLAN_WORKFLOW" collect "$COLLECT_STEP")"
mkdir -p "$dir/work/.ci-artifacts/plans/p0" "$dir/work/.ci-artifacts/plans/p1"
printf '%s' "$A" > "$dir/work/.ci-artifacts/plans/p0/plan.json"
printf '%s' "$B_SAME_KEY" > "$dir/work/.ci-artifacts/plans/p1/plan.json"
run_step "$dir" TARGETS='[{"name":"brand-a"},{"name":"brand-b"}]'
plans="$(step_output "$dir" plans)"
assert_equals 0 "$STEP_STATUS" 'collect exit status' \
    && assert_equals '2' "$(jq 'length' <<< "$plans")" 'plan count' \
    && assert_equals 'fp1' "$(jq -r '.[0].fingerprint' <<< "$plans")" 'fingerprint is carried' \
    && assert_not_contains "$(step_output "$dir" targets)" 'configHash' 'sources are not forwarded to the build' \
    && pass_case

case_start 'expo-base-plan runs the check after collecting'
problem="$(PLAN_WORKFLOW="$PLAN_WORKFLOW" python3 - <<'PYTHON'
import os
import yaml

steps = yaml.safe_load(open(os.environ['PLAN_WORKFLOW'], encoding='utf-8'))['jobs']['collect']['steps']
check = [step for step in steps if str(step.get('uses', '')).startswith('rnw-community/mobile-ci/actions/assert-distinct-fingerprints@')]
if not check:
    print('the collect job never calls assert-distinct-fingerprints')
elif check[0]['with']['plans'] != '${{ steps.collect.outputs.plans }}':
    print(f"the check is fed {check[0]['with']['plans']!r}, not the collected plans")
elif str(check[0]['with'].get('require-app-id')).lower() != 'false':
    print('expo-base-plan must pass require-app-id false: seed-native-cache targets carry no appId')
PYTHON
)"
if [ -n "$problem" ]; then
    fail_case "$problem"
else
    pass_case
fi

finish_suite
