#!/usr/bin/env bash
# GitHub keeps one pending run per concurrency group and cancels the previous
# pending one when another arrives, so a group shared by every pull request of
# a consumer lets one PR's push cancel another PR's queued OTA preview
# (rnw-community/mobile-ci#151). The group has to be scoped to the caller's ref
# while still serialising pushes to the same ref.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

WORKFLOW="$REPO_ROOT/.github/workflows/expo-ota-preview.yml"

read_concurrency() {
    WORKFLOW="$WORKFLOW" python3 - <<'PYTHON'
import os

import yaml

concurrency = yaml.safe_load(open(os.environ['WORKFLOW'], encoding='utf-8'))['concurrency']
print(concurrency['group'])
print(str(concurrency['cancel-in-progress']).lower())
PYTHON
}

case_start 'previews of different refs never share a concurrency group'
concurrency="$(read_concurrency)"
group="$(printf '%s\n' "$concurrency" | sed -n 1p)"
cancel="$(printf '%s\n' "$concurrency" | sed -n 2p)"
assert_contains "$group" "\${{ github.ref }}" 'concurrency group' &&
    assert_contains "$group" "\${{ inputs.app-dir }}" 'concurrency group' &&
    assert_equals false "$cancel" 'cancel-in-progress' &&
    pass_case

# Issue #224: the preview no longer posts a new comment per push. It renders
# one section per platform into the sticky comment pr-preview-comment keeps,
# naming the runtime fingerprint and whether a published native-dev-release
# build carries it ("native build needed" otherwise).
RENDER_STEP='Render preview comment sections'
FP_IOS='1111111111111111111111111111111111111111'
FP_ANDROID='2222222222222222222222222222222222222222'

render_setup() {
    workspace="$(new_workflow_workspace "$WORKFLOW" preview "$RENDER_STEP")"
    mkdir -p "$workspace/fake" "$workspace/runner-temp/ota-qr"
    printf 'QR-IOS\n' > "$workspace/runner-temp/ota-qr/ios.txt"
    cat > "$workspace/fake/releases.json" <<JSON
[
  {"tag_name": "dev-ios-11", "draft": false, "created_at": "2026-10-01T00:00:00Z", "html_url": "https://github.com/acme/app/releases/tag/dev-ios-11", "body": "<!-- mobile-ci:fingerprint:${FP_IOS} -->"},
  {"tag_name": "dev-ios-12", "draft": false, "created_at": "2026-10-02T00:00:00Z", "html_url": "https://github.com/acme/app/releases/tag/dev-ios-12", "body": "Runtime fingerprint\n<!-- mobile-ci:fingerprint:${FP_IOS} -->"},
  {"tag_name": "dev-ios-13", "draft": true, "created_at": "2026-10-03T00:00:00Z", "html_url": "https://github.com/acme/app/releases/tag/dev-ios-13", "body": "<!-- mobile-ci:fingerprint:${FP_IOS} -->"},
  {"tag_name": "dev-android-12", "draft": false, "created_at": "2026-10-02T00:00:00Z", "html_url": "https://github.com/acme/app/releases/tag/dev-android-12", "body": "<!-- mobile-ci:fingerprint:3333333333333333333333333333333333333333 -->"}
]
JSON
    # shellcheck disable=SC2016
    stub "$workspace" gh '[ -z "${FAKE_GH_FAIL:-}" ] || exit 1; printf "%s\n" "$*" >> "$FAKE/gh-calls"; cat "$FAKE/releases.json"'
}

render() {
    run_step "$workspace" FAKE="$workspace/fake" GH_TOKEN='token' REPOSITORY='acme/app' \
        LINK_IOS='myapp://expo-development-client/?url=ios' LINK_ANDROID='myapp://expo-development-client/?url=android' \
        RUNTIME_IOS="$FP_IOS" RUNTIME_ANDROID="$FP_ANDROID" HEAD_SHA='abcdef0123456789' \
        DEV_RELEASE_TAG_PREFIX='dev' QR_DIR="$workspace/runner-temp/ota-qr" \
        SECTIONS_DIR="$workspace/runner-temp/sections" "$@"
}

case_start 'each platform section names its fingerprint, deep link and QR code'
render_setup
render
ios="$(cat "$workspace/runner-temp/sections/ios-ota.md" 2>/dev/null || true)"
android="$(cat "$workspace/runner-temp/sections/android-ota.md" 2>/dev/null || true)"
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_contains "$ios" "$FP_IOS" 'iOS fingerprint' \
    && assert_contains "$ios" 'myapp://expo-development-client/?url=ios' 'iOS link' \
    && assert_contains "$ios" 'QR-IOS' 'iOS QR' \
    && assert_contains "$ios" 'abcdef0' 'commit' \
    && assert_contains "$android" "$FP_ANDROID" 'Android fingerprint' \
    && assert_contains "$android" 'QR generation unavailable' 'missing QR'; then
    pass_case
fi

case_start 'the newest published dev build with the same fingerprint is linked, else native build needed'
render_setup
render
ios="$(cat "$workspace/runner-temp/sections/ios-ota.md" 2>/dev/null || true)"
android="$(cat "$workspace/runner-temp/sections/android-ota.md" 2>/dev/null || true)"
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_contains "$ios" '[dev-ios-12](https://github.com/acme/app/releases/tag/dev-ios-12)' 'matching iOS build' \
    && assert_contains "$android" 'Native build needed' 'Android needs a native build'; then
    pass_case
fi

case_start 'without dev-release-tag-prefix no dev build lookup happens'
render_setup
render DEV_RELEASE_TAG_PREFIX=''
ios="$(cat "$workspace/runner-temp/sections/ios-ota.md" 2>/dev/null || true)"
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals no "$([ -e "$workspace/fake/gh-calls" ] && echo yes || echo no)" 'gh called' \
    && assert_not_contains "$ios" 'Native build needed' 'no native verdict'; then
    pass_case
fi

case_start 'a platform without a deep link clears its section'
render_setup
render LINK_ANDROID=''
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals '' "$(cat "$workspace/runner-temp/sections/android-ota.md")" 'empty android section'; then
    pass_case
fi

case_start 'an unreadable release list fails closed'
render_setup
render FAKE_GH_FAIL=1
if assert_equals 1 "$STEP_STATUS" 'step status'; then
    pass_case
fi

case_start 'the preview comment goes through pr-preview-comment, never gh pr comment'
if failure="$(WORKFLOW="$WORKFLOW" python3 - <<'PYTHON' 2>&1
import os
import sys

import yaml

workflow = yaml.safe_load(open(os.environ['WORKFLOW'], encoding='utf-8'))
steps = workflow['jobs']['preview']['steps']
problems = []
if any('gh pr comment' in (step.get('run') or '') for step in steps):
    problems.append('a step still runs gh pr comment')
uses = [step for step in steps if 'actions/pr-preview-comment@' in (step.get('uses') or '')]
if len(uses) != 1:
    problems.append('expected exactly one pr-preview-comment step')
elif uses[0]['with'].get('sections-dir') != '${{ runner.temp }}/preview-comment-sections':
    problems.append('pr-preview-comment does not read the rendered sections')
if problems:
    sys.exit('; '.join(problems))
PYTHON
)"; then
    pass_case
else
    fail_case "$failure"
fi

finish_suite
