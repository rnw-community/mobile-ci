#!/usr/bin/env bash
# Issue #251: native-dev-release.yml called once per brand in one run. Every
# name two calls would share - the build artifact, the release tag and the
# prune prefix it implies, the pull request comment section and the
# concurrency group - carries call-scope, so the calls neither overwrite,
# prune nor cancel each other. Two calls that still share a scope fail closed
# instead of silently publishing over each other's release.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

WORKFLOW="$REPO_ROOT/.github/workflows/native-dev-release.yml"

for job in ios-dev-release android-dev-release; do
    platform="${job%%-*}"

    case_start "$job: an empty call-scope keeps today's tag, prune prefix and artifact name"
    dir="$(new_workflow_workspace "$WORKFLOW" "$job" 'Compute release tag')"
    run_step "$dir" TAG_PREFIX=dev RUN_NUMBER=42 CALL_SCOPE=''
    assert_equals 0 "$STEP_STATUS" "step status ($(cat "$dir/log"))" \
        && assert_equals "dev-${platform}-42" "$(step_output "$dir" tag)" 'tag' \
        && assert_equals "dev-${platform}-" "$(step_output "$dir" prefix)" 'prune prefix' \
        && assert_equals "${platform}-dev-build" "$(step_output "$dir" artifact)" 'artifact' \
        && pass_case

    case_start "$job: call-scope names the tag, the prune prefix and the artifact"
    dir="$(new_workflow_workspace "$WORKFLOW" "$job" 'Compute release tag')"
    run_step "$dir" TAG_PREFIX=dev RUN_NUMBER=42 CALL_SCOPE=acme
    assert_equals 0 "$STEP_STATUS" "step status ($(cat "$dir/log"))" \
        && assert_equals "dev-acme-${platform}-42" "$(step_output "$dir" tag)" 'tag' \
        && assert_equals "dev-acme-${platform}-" "$(step_output "$dir" prefix)" 'prune prefix' \
        && assert_equals "${platform}-dev-build-acme" "$(step_output "$dir" artifact)" 'artifact' \
        && pass_case

    for scope in 'a--b' '-a' 'a-' 'a b' 'a/b'; do
        case_start "$job: call-scope '$scope' fails closed before anything is built"
        dir="$(new_workflow_workspace "$WORKFLOW" "$job" 'Compute release tag')"
        run_step "$dir" TAG_PREFIX=dev RUN_NUMBER=42 CALL_SCOPE="$scope"
        if [ "$STEP_STATUS" -eq 0 ]; then
            fail_case "accepted, tag '$(step_output "$dir" tag)'"
        else
            assert_contains "$(cat "$dir/log")" 'call-scope' 'error' && pass_case
        fi
    done

    label="$([ "$platform" = ios ] && echo iOS || echo Android)"
    case_start "$job: a release another call of this run attempt already published fails closed"
    dir="$(new_workflow_workspace "$WORKFLOW" "$job" 'Create GitHub Release (draft)')"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" gh '[ "$2" = view ] && { echo "Automated development build. Build number: 42.1."; exit 0; }; printf "%s\n" "$*" >> "$FAKE_GH_ARGS"'
    run_step "$dir" FAKE_GH_ARGS="$dir/gh-args" TAG="dev-${platform}-42" ARTIFACT_PATH=a META_PATH=b SUMS_PATH=c BUILD_NUMBER=42.1 FINGERPRINT=''
    if [ "$STEP_STATUS" -eq 0 ]; then
        fail_case "the second call published over the first: $(cat "$dir/gh-args" 2>/dev/null)"
    else
        assert_contains "$(cat "$dir/log")" 'call-scope' 'error names the fix' \
            && assert_equals '' "$(cat "$dir/gh-args" 2>/dev/null || true)" 'no release written' \
            && pass_case
    fi

    case_start "$job: a re-run attempt still updates its own release in place"
    dir="$(new_workflow_workspace "$WORKFLOW" "$job" 'Create GitHub Release (draft)')"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" gh '[ "$2" = view ] && { echo "Automated development build. Build number: 42.1."; exit 0; }; printf "%s\n" "$*" >> "$FAKE_GH_ARGS"'
    run_step "$dir" FAKE_GH_ARGS="$dir/gh-args" TAG="dev-${platform}-42" ARTIFACT_PATH=a META_PATH=b SUMS_PATH=c BUILD_NUMBER=42.2 FINGERPRINT=''
    assert_equals 0 "$STEP_STATUS" "step status ($(cat "$dir/log"))" \
        && assert_contains "$(cat "$dir/gh-args")" "release edit dev-${platform}-42 --draft --title $label dev build dev-${platform}-42" 'edited in place' \
        && pass_case
done

prune() {
    local dir
    dir="$(new_workflow_workspace "$WORKFLOW" ios-dev-release 'Prune old iOS dev releases')"
    : > "$dir/gh-calls"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" gh '
printf "%s\n" "$*" >> "$GH_CALLS"
case "$1 $2" in
    "api repos/o/r/releases")
        printf "2026-10-01T00:00:00Z\tdev-ios-1\n2026-10-02T00:00:00Z\tdev-ios-x-ios-2\n2026-10-03T00:00:00Z\tdev-ios-x-ios-3\n"
        printf "2026-10-04T00:00:00Z\tdev-a-ios-4\n2026-10-05T00:00:00Z\tdev-a-ios-b-ios-5\n2026-10-06T00:00:00Z\tdev-ios-6\n"
        ;;
    "release delete") exit 0 ;;
    *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac'
    run_step "$dir" GH_CALLS="$dir/gh-calls" GH_TOKEN=t REPOSITORY=o/r KEEP_RELEASES=0 "$@"
    printf '%s\n' "$dir"
}

case_start 'an unscoped prune deletes only its own run-numbered tags, never a scope that starts like it'
dir="$(prune TAG_PREFIX=dev-ios- CURRENT_TAG=dev-ios-6)"
calls="$(cat "$dir/gh-calls")"
assert_equals 0 "$STEP_STATUS" "step status ($(cat "$dir/log"))" \
    && assert_contains "$calls" 'release delete dev-ios-1 --yes --cleanup-tag' 'own old release deleted' \
    && assert_not_contains "$calls" 'release delete dev-ios-x-ios-' "scope 'ios-x' untouched" \
    && assert_not_contains "$calls" 'release delete dev-a-' "scope 'a' untouched" \
    && pass_case

case_start 'a scoped prune never deletes another scope whose name extends it'
dir="$(prune TAG_PREFIX=dev-a-ios- CURRENT_TAG=dev-a-ios-7)"
calls="$(cat "$dir/gh-calls")"
assert_equals 0 "$STEP_STATUS" "step status ($(cat "$dir/log"))" \
    && assert_contains "$calls" 'release delete dev-a-ios-4 --yes --cleanup-tag' 'own old release deleted' \
    && assert_not_contains "$calls" 'release delete dev-a-ios-b-ios-5' "scope 'a-ios-b' untouched" \
    && assert_not_contains "$calls" 'release delete dev-ios-' 'unscoped releases untouched' \
    && pass_case

case_start 'pr-comment: a scoped call writes its own section, labelled with its scope'
dir="$(new_workflow_workspace "$WORKFLOW" pr-comment 'Render development build comment sections')"
run_step "$dir" SECTIONS_DIR="$dir/runner-temp/sections" CALL_SCOPE=acme \
    SERVER_URL='https://github.com' REPOSITORY='o/r' HEAD_SHA='abcdef0123456789' RUN_URL='https://github.com/o/r/actions/runs/7' \
    ENABLE_IOS=false IOS_RESULT=skipped IOS_TAG='' IOS_ASSET='' IOS_FINGERPRINT='' IOS_INSTALL_URL='' \
    ENABLE_ANDROID=true ANDROID_RESULT=success ANDROID_TAG=dev-acme-android-12 ANDROID_ASSET=app.apk ANDROID_FINGERPRINT=fp ANDROID_INSTALL_URL=''
section="$(cat "$dir/runner-temp/sections/android-dev-build-acme.md" 2>/dev/null || true)"
assert_equals 0 "$STEP_STATUS" "step status ($(cat "$dir/log"))" \
    && assert_contains "$section" '### Android (acme): development build' 'scoped heading' \
    && assert_equals no "$([ -e "$dir/runner-temp/sections/android-dev-build.md" ] && echo yes || echo no)" 'unscoped section left alone' \
    && pass_case

case_start 'wiring: call-scope reaches the concurrency group, the artifact, the prune and the comment'
if failure="$(WORKFLOW_YML="$WORKFLOW" python3 - <<'PYTHON' 2>&1
import os
import sys

import yaml

workflow = yaml.safe_load(open(os.environ['WORKFLOW_YML'], encoding='utf-8'))
inputs = workflow[True]['workflow_call']['inputs']
problems = []
spec = inputs.get('call-scope') or {}
if spec.get('type') != 'string' or spec.get('default') != '':
    problems.append(f'call-scope must be a string input defaulting to empty, got {spec!r}')
if 'inputs.call-scope' not in str(workflow['concurrency']['group']):
    problems.append('the concurrency group must include call-scope, or one call per brand queues behind the others')
for job_id, label in (('ios-dev-release', 'iOS'), ('android-dev-release', 'Android')):
    steps = {step.get('name'): step for step in workflow['jobs'][job_id]['steps']}
    if steps['Compute release tag'].get('env', {}).get('CALL_SCOPE') != '${{ inputs.call-scope }}':
        problems.append(f'{job_id}: the tag step does not read call-scope')
    upload = steps[f'Upload {label} dev build artifact']['with']['name']
    if upload != '${{ steps.tag.outputs.artifact }}':
        problems.append(f'{job_id}: the build artifact is named {upload!r}, not the scoped name')
    prefix = steps[f'Prune old {label} dev releases']['env']['TAG_PREFIX']
    if prefix != '${{ steps.tag.outputs.prefix }}':
        problems.append(f'{job_id}: the prune prefix is {prefix!r}, not the scoped prefix')
render = workflow['jobs']['pr-comment']['steps'][0]
if render.get('env', {}).get('CALL_SCOPE') != '${{ inputs.call-scope }}':
    problems.append('the comment sections are not scoped')
if problems:
    sys.exit('; '.join(problems))
PYTHON
)"; then
    pass_case
else
    fail_case "$failure"
fi

finish_suite
