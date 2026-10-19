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

# ota-backend eas publishes through eas-update instead of exporting, manifesting
# and releasing on GitHub; the backend step validates the choice and resolves
# the channel and platform the action gets.
BACKEND_STEP='Resolve the OTA backend'

backend() {
    workspace="$(new_workflow_workspace "$WORKFLOW" preview "$BACKEND_STEP")"
    run_step "$workspace" OTA_BACKEND=eas EAS_CHANNEL_TEMPLATE='pr-{number}' PLATFORMS='ios,android' PR_NUMBER=42 \
        DEV_BUILD_SOURCE=github-release GITHUB_RELEASE_ONLY='' EAS_ONLY='' "$@"
}

case_start 'ota-backend eas resolves the pull request channel and both platforms to all'
backend
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals pr-42 "$(step_output "$workspace" channel)" 'channel' \
    && assert_equals all "$(step_output "$workspace" platform)" 'platform'; then
    pass_case
fi

case_start 'ota-backend eas outside a pull request takes a fixed channel and one platform'
backend PR_NUMBER='' EAS_CHANNEL_TEMPLATE=development PLATFORMS=' android '
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals development "$(step_output "$workspace" channel)" 'channel' \
    && assert_equals android "$(step_output "$workspace" platform)" 'platform'; then
    pass_case
fi

case_start 'ota-backend github-release resolves only the platform'
backend OTA_BACKEND=github-release PR_NUMBER='' PLATFORMS=ios
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals ios "$(step_output "$workspace" platform)" 'platform' \
    && assert_equals '' "$(step_output "$workspace" channel)" 'no channel'; then
    pass_case
fi

for bad in 'OTA_BACKEND=s3|ota-backend must be' 'PR_NUMBER=|has no pull request' 'PLATFORMS=web|platforms must name' \
    'DEV_BUILD_SOURCE=s3|dev-build-source must be' \
    'GITHUB_RELEASE_ONLY=runtime-version-ios public-base-url |ota-backend eas ignores runtime-version-ios public-base-url' \
    'EAS_ONLY=eas-rollout-percentage |cannot honour eas-rollout-percentage'; do
    case_start "the OTA backend step fails closed on ${bad%%|*}"
    if [ "${bad%%=*}" = EAS_ONLY ]; then
        backend OTA_BACKEND=github-release "${bad%%|*}"
    else
        backend "${bad%%|*}"
    fi
    if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(cat "$workspace/log")" "${bad#*|}" 'message'; then
        pass_case
    fi
done

case_start 'an EAS preview section names its channel'
render_setup
render EAS_CHANNEL=pr-42
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$workspace/runner-temp/sections/ios-ota.md")" "EAS Update channel \`pr-42\`" 'channel named'; then
    pass_case
fi

case_start 'ota-backend eas skips the GitHub Release path and feeds eas-update into the links and the comment'
if failure="$(WORKFLOW="$WORKFLOW" python3 - <<'PYTHON' 2>&1
import os
import sys

import yaml

steps = yaml.safe_load(open(os.environ['WORKFLOW'], encoding='utf-8'))['jobs']['preview']['steps']
by_name = {step.get('name'): step for step in steps}
problems = []
for name in ['Export JS bundle', 'Compute preview tag and base URL', 'Generate Expo Updates manifests',
             'Publish to GitHub Release', 'Check the pull request head is current']:
    if "inputs.ota-backend != 'eas'" not in str(by_name[name].get('if', '')):
        problems.append(f'{name} still runs under ota-backend eas')
eas = by_name['Publish the EAS update']
if not eas.get('uses', '').startswith('rnw-community/mobile-ci/actions/eas-update@'):
    problems.append('the EAS update is not published through eas-update')
if eas.get('with', {}).get('expo-token') != '${{ secrets.EXPO_TOKEN }}':
    problems.append('eas-update does not get the EXPO_TOKEN secret')
if eas.get('with', {}).get('ios-runtime-version') != '${{ steps.runtime.outputs.ios-runtime-version }}':
    problems.append('eas-update does not check the runtime ota-runtime-version resolved')
runtime = by_name['Resolve the runtime versions']
if not runtime.get('uses', '').startswith('rnw-community/mobile-ci/actions/ota-runtime-version@'):
    problems.append('the runtime version does not come from ota-runtime-version')
if any('actions/native-fingerprint@' in (step.get('uses') or '') for step in steps):
    problems.append('a step still uses native-fingerprint for the runtime version')
manifest = by_name['Generate Expo Updates manifests']['with']
if 'steps.runtime.outputs.ios-runtime-version' not in manifest['runtime-version-ios']:
    problems.append('the GitHub Release manifest does not target the resolved runtime')
result = by_name['Collect the published update']['env']
if 'steps.eas.outputs.ios-manifest-url' not in result['EAS_URL_IOS']:
    problems.append('the EAS manifest URL is not collected')
render = by_name['Render preview comment sections']
if render['env']['LINK_IOS'] != '${{ steps.result.outputs.ios-deep-link }}':
    problems.append('the comment does not use the collected deep link')
for name in ['Generate QR codes', 'Render preview comment sections', 'Update the sticky preview comment']:
    if "steps.result.outputs.skipped-reason != 'stale-head'" not in str(by_name[name].get('if', '')):
        problems.append(f'{name} still runs for a stale head')
if problems:
    sys.exit('; '.join(problems))
PYTHON
)"; then
    pass_case
else
    fail_case "$failure"
fi

# Both backends hand the comment and the workflow outputs the same shape, and
# a stale pull-request run publishes nothing and leaves the comment alone.
RESULT_STEP='Collect the published update'

collect() {
    workspace="$(new_workflow_workspace "$WORKFLOW" preview "$RESULT_STEP")"
    printf '{"id":"manifest-ios-id"}\n' > "$workspace/manifest-ios.json"
    run_step "$workspace" OTA_BACKEND=github-release SCHEME=myapp PUBLISH=true STALE=false \
        MANIFEST_IOS="$workspace/manifest-ios.json" MANIFEST_ANDROID='' \
        RELEASE_URL_IOS='https://github.com/acme/app/releases/download/t/ios-manifest.json' RELEASE_URL_ANDROID='' \
        RELEASE_RUNTIME_IOS=rv-i RELEASE_RUNTIME_ANDROID='' \
        EAS_PUBLISHED='' EAS_SKIPPED_REASON='' EAS_ID_IOS='' EAS_ID_ANDROID='' EAS_URL_IOS='' EAS_URL_ANDROID='' \
        EAS_RUNTIME_IOS='' EAS_RUNTIME_ANDROID='' "$@"
}

case_start 'the GitHub Release backend reports the manifest id, runtime, URL and deep link'
collect
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals true "$(step_output "$workspace" published)" 'published' \
    && assert_equals manifest-ios-id "$(step_output "$workspace" ios-update-id)" 'update id' \
    && assert_equals rv-i "$(step_output "$workspace" ios-runtime-version)" 'runtime' \
    && assert_equals 'myapp://expo-development-client/?url=https%3A%2F%2Fgithub.com%2Facme%2Fapp%2Freleases%2Fdownload%2Ft%2Fios-manifest.json' "$(step_output "$workspace" ios-deep-link)" 'deep link' \
    && assert_equals '' "$(step_output "$workspace" android-deep-link)" 'no android'; then
    pass_case
fi

case_start 'the EAS backend reports the same outputs from eas-update'
collect OTA_BACKEND=eas EAS_PUBLISHED=false EAS_SKIPPED_REASON=already-published EAS_ID_ANDROID=u-a \
    EAS_URL_ANDROID=https://u.expo.dev/p/group/g EAS_RUNTIME_ANDROID=rv-a
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals false "$(step_output "$workspace" published)" 'published' \
    && assert_equals already-published "$(step_output "$workspace" skipped-reason)" 'reason' \
    && assert_equals u-a "$(step_output "$workspace" android-update-id)" 'update id' \
    && assert_equals 'myapp://expo-development-client/?url=https%3A%2F%2Fu.expo.dev%2Fp%2Fgroup%2Fg' "$(step_output "$workspace" android-deep-link)" 'deep link' \
    && assert_equals '' "$(step_output "$workspace" ios-deep-link)" 'no ios'; then
    pass_case
fi

case_start 'a stale head reports nothing to link'
collect STALE=true
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals stale-head "$(step_output "$workspace" skipped-reason)" 'reason' \
    && assert_equals '' "$(step_output "$workspace" ios-deep-link)" 'no link'; then
    pass_case
fi

case_start 'publish false is reported as skipped'
collect PUBLISH=false
if assert_equals publish-disabled "$(step_output "$workspace" skipped-reason)" 'reason'; then
    pass_case
fi

HEAD_STEP='Check the pull request head is current'
head_check() {
    workspace="$(new_workflow_workspace "$WORKFLOW" preview "$HEAD_STEP")"
    stub "$workspace" gh "$1"
    run_step "$workspace" GH_TOKEN=t REPOSITORY=acme/app PR_NUMBER=42 EVENT_HEAD=aaa
}

case_start 'the GitHub Release backend notices a head that moved on'
head_check 'echo bbb'
if assert_equals 0 "$STEP_STATUS" 'status' && assert_equals true "$(step_output "$workspace" stale)" 'stale'; then
    pass_case
fi
head_check 'echo aaa'
if assert_equals false "$(step_output "$workspace" stale)" 'current'; then
    pass_case
fi

case_start 'an unreadable pull request head fails closed'
head_check 'exit 1'
if assert_equals 1 "$STEP_STATUS" 'status'; then
    pass_case
fi

case_start 'dev-build-source eas links the matching EAS build, else says a native build is needed'
render_setup
mkdir -p "$workspace/runner-temp/eas-dev-builds"
printf '[01a153b5](https://expo.dev/accounts/acme/projects/app/builds/01a153b5-x)\n' > "$workspace/runner-temp/eas-dev-builds/ios.md"
: > "$workspace/runner-temp/eas-dev-builds/android.md"
render DEV_BUILD_SOURCE=eas DEV_BUILDS_DIR="$workspace/runner-temp/eas-dev-builds" DEV_RELEASE_TAG_PREFIX=''
ios="$(cat "$workspace/runner-temp/sections/ios-ota.md")"
android="$(cat "$workspace/runner-temp/sections/android-ota.md")"
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_contains "$ios" 'EAS development build [01a153b5](https://expo.dev/accounts/acme/projects/app/builds/01a153b5-x)' 'ios build' \
    && assert_contains "$android" 'no finished EAS Android build' 'android native build needed'; then
    pass_case
fi

DEV_BUILDS_STEP='Find matching EAS development builds'
case_start 'the EAS development build lookup queries by runtime version and fails closed'
workspace="$(new_workflow_workspace "$WORKFLOW" preview "$DEV_BUILDS_STEP")"
# shellcheck disable=SC2016
stub "$workspace" npx 'printf "%s\n" "$*" >> "$(dirname "$0")/../npx-calls"; [ -z "${LIST_FAIL:-}" ] || exit 1; echo "[{\"id\":\"01a153b5-x\",\"app\":{\"slug\":\"app\",\"ownerAccount\":{\"name\":\"acme\"}}}]"'
run_step "$workspace" EXPO_TOKEN=t EAS_CLI_VERSION=20.5.1 DEV_BUILD_PROFILE=development RUNTIME_IOS=rv-i RUNTIME_ANDROID='' \
    DEV_BUILDS_DIR="$workspace/out"
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$workspace/npx-calls")" 'build:list --platform ios --runtime-version rv-i --status finished --limit 1 --build-profile development --json' 'query' \
    && assert_equals '[01a153b5](https://expo.dev/accounts/acme/projects/app/builds/01a153b5-x)' "$(cat "$workspace/out/ios.md")" 'link' \
    && assert_equals '' "$(cat "$workspace/out/android.md")" 'no android'; then
    run_step "$workspace" EXPO_TOKEN=t EAS_CLI_VERSION=20.5.1 DEV_BUILD_PROFILE='' RUNTIME_IOS=rv-i RUNTIME_ANDROID='' \
        DEV_BUILDS_DIR="$workspace/out" LIST_FAIL=1
    if assert_equals 1 "$STEP_STATUS" 'unreadable builds fail closed'; then
        pass_case
    fi
fi

case_start 'an EAS build without app identity is named by id, never linked to a null URL'
workspace="$(new_workflow_workspace "$WORKFLOW" preview "$DEV_BUILDS_STEP")"
stub "$workspace" npx 'echo "[{\"id\":\"01a153b5-x\"}]"'
run_step "$workspace" EXPO_TOKEN=t EAS_CLI_VERSION=20.5.1 DEV_BUILD_PROFILE='' RUNTIME_IOS=rv-i RUNTIME_ANDROID='' \
    DEV_BUILDS_DIR="$workspace/out"
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals "\`01a153b5-x\`" "$(cat "$workspace/out/ios.md")" 'plain id'; then
    pass_case
fi

finish_suite
