#!/usr/bin/env bash
# The warm-up plans a target when its base is missing OR when the iOS compile
# caches a native build restores (ccache, CocoaPods) are gone, so an eviction
# is refilled by the warm-up on a Mac instead of by the next pull request that
# has to compile. The lookup runs on Linux against the Actions cache API, and
# expo-base-plan hands a target marked forceNative to the native build even
# when its base exists. Both scripts are extracted and run here.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

SEED_WORKFLOW="$REPO_ROOT/.github/workflows/seed-native-cache.yml"
PLAN_WORKFLOW="$REPO_ROOT/.github/workflows/expo-base-plan.yml"
CACHES_STEP='Mark the targets whose iOS compile caches are missing'
RECORD_STEP="Record this target's plan"
TARGETS='[{"name":"bare","appDir":"apps/mobile"},{"name":"ai","appDir":"apps/ai"}]'
MAIN='refs%2Fheads%2Fmain'

# caches_workspace <present...> — each argument is "<key prefix>&ref=<encoded ref>"
# the stubbed cache API reports one entry for; anything else reports none.
caches_workspace() {
    dir="$(new_workflow_workspace "$SEED_WORKFLOW" ios-compile-caches "$CACHES_STEP")"
    printf '%s\n' "$@" > "$dir/present"
    : > "$dir/calls"
    stub "$dir" curl "$(cat <<STUB
out=''
url=''
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o|-H|--retry|--max-time) [ "\$1" = -o ] && out="\$2"; shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
printf '%s\n' "\$url" >> "$dir/calls"
[ -f "$dir/api-down" ] && exit 22
count=0
while IFS= read -r present; do
  [ -n "\$present" ] || continue
  case "\$url" in *"key=\$present&"*) count=1 ;; esac
done < "$dir/present"
printf '{"total_count":%s,"actions_caches":[]}' "\$count" > "\$out"
STUB
)"
}

check() {
    run_step "$dir" TARGETS="$TARGETS" XCODE_VERSION=26.4.1 GITHUB_TOKEN=token \
        API_URL=https://api.github.test REPOSITORY=acme/app REF=refs/heads/main DEFAULT_BRANCH=main "$@"
}

all_present=(
    "ccache-ios-bare-macOS-xcode-26.4.1-&ref=$MAIN"
    "pods-bare-macOS-xcode-26.4.1-&ref=$MAIN"
    "ccache-ios-ai-macOS-xcode-26.4.1-&ref=$MAIN"
    "pods-ai-macOS-xcode-26.4.1-&ref=$MAIN"
)

case_start 'targets whose compile caches are all restorable pass through unmarked'
caches_workspace "${all_present[@]}"
check
targets="$(step_output "$dir" targets)"
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals "$(jq -c . <<< "$TARGETS")" "$targets" 'targets' \
    && assert_contains "$(cat "$dir/calls")" 'https://api.github.test/repos/acme/app/actions/caches?key=ccache-ios-bare-macOS-xcode-26.4.1-&ref=refs%2Fheads%2Fmain&per_page=1' 'API query' \
    && pass_case

case_start 'an evicted ccache marks only that target forceNative'
caches_workspace "${all_present[@]:1}"
check
targets="$(step_output "$dir" targets)"
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals 'true' "$(jq -r '.[0].forceNative' <<< "$targets")" 'bare forceNative' \
    && assert_equals 'null' "$(jq -r '.[1].forceNative' <<< "$targets")" 'ai forceNative' \
    && assert_equals 'apps/mobile' "$(jq -r '.[0].appDir' <<< "$targets")" 'target passed through' \
    && assert_contains "$(cat "$dir/summary")" 'ccache-ios-bare-macOS-xcode-26.4.1-*' 'summary' \
    && pass_case

case_start 'an evicted CocoaPods cache marks the target forceNative'
caches_workspace "ccache-ios-bare-macOS-xcode-26.4.1-&ref=$MAIN" "${all_present[@]:2}"
check
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals 'true' "$(jq -r '.[0].forceNative' <<< "$(step_output "$dir" targets)")" 'bare forceNative' \
    && pass_case

case_start 'a cache for another Xcode does not count as restorable'
caches_workspace "ccache-ios-bare-macOS-xcode-26.3-&ref=$MAIN" "${all_present[@]:1}"
check
assert_equals 'true' "$(jq -r '.[0].forceNative' <<< "$(step_output "$dir" targets)")" 'bare forceNative' \
    && pass_case

case_start 'off the default branch, a cache the default branch saved still counts'
caches_workspace "${all_present[@]}"
check REF=refs/heads/warm-up
calls="$(cat "$dir/calls")"
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals 'null' "$(jq -r '.[0].forceNative' <<< "$(step_output "$dir" targets)")" 'bare forceNative' \
    && assert_contains "$calls" 'ref=refs%2Fheads%2Fwarm-up' 'own ref queried' \
    && pass_case

case_start 'an unreachable cache API fails closed instead of planning nothing or everything'
caches_workspace "${all_present[@]}"
: > "$dir/api-down"
check
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case "an API failure planned '$(step_output "$dir" targets)'"
else
    assert_contains "$(cat "$dir/log")" 'An unreadable cache index is not an evicted cache' 'error message' && pass_case
fi

case_start 'the lookup feeds the iOS plan, and a refill target skips the native-app shortcut'
problem="$(SEED="$SEED_WORKFLOW" python3 - <<'PYTHON'
import os
import yaml

problems = []
seed = yaml.safe_load(open(os.environ['SEED'], encoding='utf-8'))
jobs = seed['jobs']
if jobs['plan-ios'].get('needs') != 'ios-compile-caches':
    problems.append('plan-ios does not wait for the cache lookup')
if jobs['plan-ios']['with']['targets'] != '${{ needs.ios-compile-caches.outputs.targets }}':
    problems.append('plan-ios plans the raw ios-targets, not the marked ones')
if jobs['ios-compile-caches'].get('permissions', {}).get('actions') != 'read':
    problems.append('the lookup job cannot read the Actions cache API')
if 'control-runner-labels' not in str(jobs['ios-compile-caches'].get('runs-on')):
    problems.append('the lookup does not run on the control lane')
restore = next(step for step in jobs['seed-ios']['steps'] if step.get('name') == 'native-app-cache (restore)')
if '!matrix.target.forceNative' not in str(restore.get('if')):
    problems.append('a refill target restores the cached .app and skips the build that refills the caches')
lookup = next(step for step in jobs['ios-compile-caches']['steps'] if step.get('name') == 'Mark the targets whose iOS compile caches are missing')['run']
for step in jobs['seed-ios']['steps']:
    if step.get('name') == 'setup-ccache-ios (restore)':
        ccache_key = step['with']['key']
    if step.get('name') == 'build-ios-app':
        pods_key = step['with']['pods-cache-key']
for key, looked_up in ((ccache_key, 'ccache-ios-${name}-macOS-xcode-${XCODE_VERSION}-'), (pods_key, 'pods-${name}-macOS-xcode-${XCODE_VERSION}-')):
    prefix = key.replace('${{ matrix.target.name }}', '${name}').replace('${{ runner.os }}', 'macOS').replace('${{ inputs.xcode-version }}', '${XCODE_VERSION}')
    if not prefix.startswith(looked_up) or looked_up not in lookup:
        problems.append(f'the lookup checks {looked_up!r}, which is not a prefix of the key seed-ios saves ({key!r})')
print('; '.join(problems))
PYTHON
)"
if [ -n "$problem" ]; then
    fail_case "$problem"
else
    pass_case
fi

record() {
    dir="$(new_workflow_workspace "$PLAN_WORKFLOW" plan "$RECORD_STEP")"
    run_step "$dir" PLATFORM=ios NATIVE_KEY=k1-aaaaaaaaaaaa FINGERPRINT=k1 CONFIG_HASH=none BASE_SOURCE=ghcr BASE_REFERENCE=ghcr.io/acme/app:k1 BUILD_STRATEGY=auto PLAN_ARTIFACT=seed-plan-bare "$@"
}

case_start 'a target with a base is not built natively'
record TARGET='{"name":"bare"}' BASE_FOUND=true REPACKED=false
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals 'false' "$(jq -r '.needsNative' "$dir/work/.ci-artifacts/plan/plan.json")" 'needsNative' \
    && pass_case

case_start 'forceNative hands a target with a base to the native build'
record TARGET='{"name":"bare","forceNative":true}' BASE_FOUND=true REPACKED=false
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals 'true' "$(jq -r '.needsNative' "$dir/work/.ci-artifacts/plan/plan.json")" 'needsNative' \
    && assert_contains "$(cat "$dir/summary")" 'native build requested' 'summary' \
    && pass_case

case_start 'forceNative on a repacking caller fails closed'
record TARGET='{"name":"bare","forceNative":true}' BASE_FOUND=true REPACKED=true
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'a repacked target was also handed to the native build'
else
    assert_contains "$(cat "$dir/log")" 'repack: false' 'error message' && pass_case
fi

finish_suite
