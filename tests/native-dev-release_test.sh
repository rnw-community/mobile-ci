#!/usr/bin/env bash
# native-dev-release.yml publishes build-meta.json describing a binary. Its
# buildNumber is what the workflow exported to the build, not what the binary
# carries; these cases pin that the binary is read back after the EAS build,
# that the opt-in iOS assertion compares the two, and that a consumer's
# post-build hook runs before anything is published.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

WORKFLOW="$REPO_ROOT/.github/workflows/native-dev-release.yml"
READ_BACK='Read embedded build number'
META='Compute build metadata'

stub_ios_tools() {
    local dir="$1"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" unzip '
if [ "$1" = -Z1 ]; then
    printf "%s\n" ${STUB_IPA_ENTRIES:-}
    exit 0
fi
if [ "$1" = -p ]; then
    cat "$STUB_PLIST"
    exit 0
fi
exit 2'
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" plutil '
key="$2"
file="${!#}"
value="$(sed -n "s/^$key=//p" "$file")"
[ -n "$value" ] || exit 1
printf "%s\n" "$value"'
}

# Sets `workspace`; run_step's STEP_STATUS would be lost in a subshell, so this
# is deliberately not a command substitution.
read_ios() {
    local plist="$1"
    shift
    workspace="$(new_workflow_workspace "$WORKFLOW" ios-dev-release "$READ_BACK")"
    stub_ios_tools "$workspace"
    : > "$workspace/runner-temp/app.ipa"
    printf '%s' "$plist" > "$workspace/plist"
    run_step "$workspace" \
        ARTIFACT_PATH="$workspace/runner-temp/app.ipa" \
        STUB_PLIST="$workspace/plist" \
        STUB_IPA_ENTRIES='Payload/App.app/ Payload/App.app/Info.plist Payload/App.app/Watch/W.app/Info.plist' \
        DEVELOPMENT_BUILD_NUMBER='482.1' \
        "$@"
}

PLIST_MATCH='CFBundleVersion=482.1
CFBundleShortVersionString=1.4.2
'
PLIST_MISMATCH='CFBundleVersion=7
CFBundleShortVersionString=1.4.2
'

case_start 'iOS read-back reports what the ipa Info.plist embeds'
read_ios "$PLIST_MISMATCH" VERIFY_EMBEDDED_BUILD_NUMBER='false'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals '7' "$(step_output "$workspace" embedded-build-number)" 'embedded-build-number' \
    && assert_equals '1.4.2' "$(step_output "$workspace" embedded-version)" 'embedded-version'; then
    pass_case
fi

case_start 'an ipa whose Info.plist cannot be read fails closed'
read_ios 'not a plist' VERIFY_EMBEDDED_BUILD_NUMBER='false'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'CFBundleVersion' 'error message'; then
    pass_case
fi

case_start 'an ipa with no top-level app Info.plist fails closed'
read_ios "$PLIST_MATCH" VERIFY_EMBEDDED_BUILD_NUMBER='false' STUB_IPA_ENTRIES='Payload/App.app/Assets.car'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'Payload/<name>.app/Info.plist' 'error message'; then
    pass_case
fi

case_start 'verification on: a CFBundleVersion that differs fails naming both numbers'
read_ios "$PLIST_MISMATCH" VERIFY_EMBEDDED_BUILD_NUMBER='true'
log="$(cat "$workspace/log")"
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$log" "'7'" 'embedded number in error' \
    && assert_contains "$log" "'482.1'" 'expected number in error' \
    && assert_contains "$log" 'ios.buildNumber' 'wiring hint'; then
    pass_case
fi

case_start 'verification on: a matching CFBundleVersion passes'
read_ios "$PLIST_MATCH" VERIFY_EMBEDDED_BUILD_NUMBER='true'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals '482.1' "$(step_output "$workspace" embedded-build-number)" 'embedded-build-number'; then
    pass_case
fi

case_start 'verification off: a differing CFBundleVersion is reported, not failed'
read_ios "$PLIST_MISMATCH" VERIFY_EMBEDDED_BUILD_NUMBER='false'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals '7' "$(step_output "$workspace" embedded-build-number)" 'embedded-build-number'; then
    pass_case
fi

read_android() {
    local artifact="$1"
    shift
    workspace="$(new_workflow_workspace "$WORKFLOW" android-dev-release "$READ_BACK")"
    : > "$workspace/runner-temp/$artifact"
    run_step "$workspace" \
        ARTIFACT_PATH="$workspace/runner-temp/$artifact" \
        ANDROID_HOME='' ANDROID_SDK_ROOT='' \
        "$@"
}

BADGING="package: name='com.example.app' versionCode='4821' versionName='1.4.2' platformBuildVersionName='14'"

case_start 'apk read-back uses aapt2 from the SDK build-tools'
workspace="$(new_workflow_workspace "$WORKFLOW" android-dev-release "$READ_BACK")"
mkdir -p "$workspace/sdk/build-tools/34.0.0"
# shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
printf '#!/usr/bin/env bash\n[ "$1 $2" = "dump badging" ] || exit 2\nprintf "%%s\\n" "%s"\n' "$BADGING" > "$workspace/sdk/build-tools/34.0.0/aapt2"
chmod +x "$workspace/sdk/build-tools/34.0.0/aapt2"
: > "$workspace/runner-temp/app.apk"
run_step "$workspace" ARTIFACT_PATH="$workspace/runner-temp/app.apk" ANDROID_HOME="$workspace/sdk" ANDROID_SDK_ROOT=''
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals '4821' "$(step_output "$workspace" embedded-build-number)" 'embedded-build-number' \
    && assert_equals '1.4.2' "$(step_output "$workspace" embedded-version)" 'embedded-version'; then
    pass_case
fi

case_start 'apk read-back picks the numerically newest build-tools, not the alphabetically last'
workspace="$(new_workflow_workspace "$WORKFLOW" android-dev-release "$READ_BACK")"
mkdir -p "$workspace/sdk/build-tools/9.0.0" "$workspace/sdk/build-tools/34.0.0"
printf '#!/usr/bin/env bash\necho "too old" >&2\nexit 1\n' > "$workspace/sdk/build-tools/9.0.0/aapt2"
# shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
printf '#!/usr/bin/env bash\n[ "$1 $2" = "dump badging" ] || exit 2\nprintf "%%s\\n" "%s"\n' "$BADGING" > "$workspace/sdk/build-tools/34.0.0/aapt2"
chmod +x "$workspace/sdk/build-tools/9.0.0/aapt2" "$workspace/sdk/build-tools/34.0.0/aapt2"
: > "$workspace/runner-temp/app.apk"
run_step "$workspace" ARTIFACT_PATH="$workspace/runner-temp/app.apk" ANDROID_HOME="$workspace/sdk" ANDROID_SDK_ROOT=''
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals '4821' "$(step_output "$workspace" embedded-build-number)" 'embedded-build-number'; then
    pass_case
fi

case_start 'an apk aapt2 cannot read fails closed'
workspace="$(new_workflow_workspace "$WORKFLOW" android-dev-release "$READ_BACK")"
stub "$workspace" aapt2 'echo "ERROR: not a valid apk" >&2; exit 1'
: > "$workspace/runner-temp/app.apk"
run_step "$workspace" ARTIFACT_PATH="$workspace/runner-temp/app.apk" ANDROID_HOME='' ANDROID_SDK_ROOT=''
if assert_equals 1 "$STEP_STATUS" 'step status'; then
    pass_case
fi

case_start 'aapt2 output with no versionCode fails closed rather than reporting nothing'
workspace="$(new_workflow_workspace "$WORKFLOW" android-dev-release "$READ_BACK")"
stub "$workspace" aapt2 'echo "application-label:'"'"'App'"'"'"'
: > "$workspace/runner-temp/app.apk"
run_step "$workspace" ARTIFACT_PATH="$workspace/runner-temp/app.apk" ANDROID_HOME='' ANDROID_SDK_ROOT=''
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'versionCode' 'error message'; then
    pass_case
fi

case_start 'aab read-back uses bundletool when it is on PATH'
workspace="$(new_workflow_workspace "$WORKFLOW" android-dev-release "$READ_BACK")"
stub "$workspace" bundletool '
case "$*" in
    *"--bundle "*"@android:versionCode"*) echo 4821 ;;
    *"--bundle "*"@android:versionName"*) echo 1.4.2 ;;
    *) exit 2 ;;
esac'
: > "$workspace/runner-temp/app.aab"
run_step "$workspace" ARTIFACT_PATH="$workspace/runner-temp/app.aab" ANDROID_HOME='' ANDROID_SDK_ROOT=''
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals '4821' "$(step_output "$workspace" embedded-build-number)" 'embedded-build-number' \
    && assert_equals '1.4.2' "$(step_output "$workspace" embedded-version)" 'embedded-version'; then
    pass_case
fi

case_start 'an aab with no bundletool on the host warns and leaves the values empty'
read_android app.aab
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" '::warning::' 'warning' \
    && assert_equals '' "$(step_output "$workspace" embedded-build-number)" 'embedded-build-number'; then
    pass_case
fi

compute_meta() {
    workspace="$(new_workflow_workspace "$WORKFLOW" "$1" "$META")"
    shift
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$workspace" shasum 'printf "%s  %s\n" 1d8cbc804fa48c3e $3'
    : > "$workspace/runner-temp/app.ipa"
    run_step "$workspace" \
        ARTIFACT_PATH="$workspace/runner-temp/app.ipa" \
        PLATFORM=ios BUILD_NUMBER='482.1' COMMIT_SHA=b0389d2 BRANCH_NAME=main \
        WORKFLOW_URL=https://example.invalid/run TAG_NAME=dev-ios-482 \
        "$@"
}

for job in ios-dev-release android-dev-release; do
    case_start "$job build-meta.json carries the embedded build number and version"
    compute_meta "$job" EMBEDDED_BUILD_NUMBER='482.1' EMBEDDED_VERSION='1.4.2'
    meta="$(cat "$workspace/runner-temp/build-meta.json" 2>/dev/null || true)"
    if assert_equals 0 "$STEP_STATUS" 'step status' \
        && assert_equals '482.1' "$(printf '%s' "$meta" | jq -r '.embeddedBuildNumber')" 'embeddedBuildNumber' \
        && assert_equals '1.4.2' "$(printf '%s' "$meta" | jq -r '.embeddedVersion')" 'embeddedVersion' \
        && assert_equals '482.1' "$(printf '%s' "$meta" | jq -r '.buildNumber')" 'buildNumber'; then
        pass_case
    fi

    case_start "$job build-meta.json omits embedded fields nothing could read"
    compute_meta "$job" EMBEDDED_BUILD_NUMBER='' EMBEDDED_VERSION=''
    meta="$(cat "$workspace/runner-temp/build-meta.json" 2>/dev/null || true)"
    if assert_equals 0 "$STEP_STATUS" 'step status' \
        && assert_equals 'false' "$(printf '%s' "$meta" | jq 'has("embeddedBuildNumber") or has("embeddedVersion")')" 'embedded keys present'; then
        pass_case
    fi
done

case_start 'the read-back and post-build hook run before anything is published, in both jobs'
if order="$(WORKFLOW_YML="$WORKFLOW" python3 - <<'PYTHON' 2>&1
import os
import sys

import yaml

workflow = yaml.safe_load(open(os.environ['WORKFLOW_YML'], encoding='utf-8'))
inputs = workflow[True]['workflow_call']['inputs']
problems = []
verify = inputs.get('ios-verify-embedded-build-number')
if not verify or verify.get('type') != 'boolean' or verify.get('default') is not False:
    problems.append('ios-verify-embedded-build-number must be a boolean input defaulting to false')
for job_id, platform in (('ios-dev-release', 'iOS'), ('android-dev-release', 'Android')):
    hook_input = f'{platform.lower()}-post-build-command'
    if inputs.get(hook_input, {}).get('default') != '':
        problems.append(f'{hook_input} must be an input defaulting to empty')
    names = [step.get('name') for step in workflow['jobs'][job_id]['steps']]
    wanted = ['EAS build (%s, development)' % platform, 'Read embedded build number',
              'Run %s post-build command' % platform, 'Create GitHub Release (draft)']
    missing = [name for name in wanted if name not in names]
    if missing:
        problems.append(f'{job_id}: missing step(s) {missing}')
        continue
    positions = [names.index(name) for name in wanted]
    if positions != sorted(positions):
        problems.append(f'{job_id}: expected order {wanted}, got positions {positions}')
    hook = workflow['jobs'][job_id]['steps'][names.index(wanted[2])]
    for var in ('ARTIFACT_PATH', 'EMBEDDED_BUILD_NUMBER', 'EMBEDDED_VERSION'):
        if var not in hook.get('env', {}):
            problems.append(f'{job_id}: post-build hook does not receive {var}')
if problems:
    sys.exit('\n'.join(problems))
PYTHON
)"; then
    pass_case
else
    fail_case "$order"
fi

# Issue #224: every dev build records the runtime fingerprint the OTA preview
# matches against (build-meta.json and a release-notes marker), and an opt-in
# pr-comment job writes each platform's build into the pull request's sticky
# preview comment.
FP='4444444444444444444444444444444444444444'

for job in ios-dev-release android-dev-release; do
    case_start "$job build-meta.json carries the runtime fingerprint"
    compute_meta "$job" EMBEDDED_BUILD_NUMBER='' EMBEDDED_VERSION='' FINGERPRINT="$FP"
    meta="$(cat "$workspace/runner-temp/build-meta.json" 2>/dev/null || true)"
    if assert_equals 0 "$STEP_STATUS" 'step status' \
        && assert_equals "$FP" "$(printf '%s' "$meta" | jq -r '.fingerprint')" 'fingerprint'; then
        pass_case
    fi

    case_start "$job release notes carry the fingerprint marker the OTA preview matches"
    workspace="$(new_workflow_workspace "$WORKFLOW" "$job" 'Create GitHub Release (draft)')"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$workspace" gh '[ "$2" = view ] && exit 1; printf "%s\n" "$@" >> "$FAKE_GH_ARGS"'
    run_step "$workspace" FAKE_GH_ARGS="$workspace/gh-args" TAG=dev-ios-482 ARTIFACT_PATH=a META_PATH=b SUMS_PATH=c \
        BUILD_NUMBER='482.1' FINGERPRINT="$FP"
    if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
        && assert_contains "$(cat "$workspace/gh-args")" "<!-- mobile-ci:fingerprint:${FP} -->" 'notes marker'; then
        pass_case
    fi
done

RENDER='Render development build comment sections'
render_dev() {
    workspace="$(new_workflow_workspace "$WORKFLOW" pr-comment "$RENDER")"
    run_step "$workspace" SECTIONS_DIR="$workspace/runner-temp/sections" \
        SERVER_URL='https://github.com' REPOSITORY='acme/app' HEAD_SHA='abcdef0123456789' \
        RUN_URL='https://github.com/acme/app/actions/runs/7' \
        ENABLE_IOS=true IOS_RESULT=success IOS_TAG=dev-ios-12 IOS_ASSET=app.ipa IOS_FINGERPRINT="$FP" IOS_INSTALL_URL='' \
        ENABLE_ANDROID=true ANDROID_RESULT=success ANDROID_TAG=dev-android-12 ANDROID_ASSET=app.apk ANDROID_FINGERPRINT="$FP" ANDROID_INSTALL_URL='' \
        "$@"
}

case_start 'each built platform gets a section with its install link and fingerprint'
render_dev
ios="$(cat "$workspace/runner-temp/sections/ios-dev-build.md" 2>/dev/null || true)"
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_contains "$ios" 'https://github.com/acme/app/releases/download/dev-ios-12/app.ipa' 'install link' \
    && assert_contains "$ios" '[dev-ios-12](https://github.com/acme/app/releases/tag/dev-ios-12)' 'release link' \
    && assert_contains "$ios" "$FP" 'fingerprint' \
    && assert_contains "$(cat "$workspace/runner-temp/sections/android-dev-build.md" 2>/dev/null || true)" 'app.apk' 'android'; then
    pass_case
fi

case_start 'a failed platform says so, and a disabled one leaves its section alone'
render_dev ANDROID_RESULT=failure ENABLE_IOS=false IOS_RESULT=skipped
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals no "$([ -e "$workspace/runner-temp/sections/ios-dev-build.md" ] && echo yes || echo no)" 'iOS section file' \
    && assert_contains "$(cat "$workspace/runner-temp/sections/android-dev-build.md" 2>/dev/null || true)" 'failure' 'android failure'; then
    pass_case
fi

case_start 'the pr-comment job is opt-in, pull-request-only, and needs no new permission from existing callers'
if failure="$(WORKFLOW_YML="$WORKFLOW" python3 - <<'PYTHON' 2>&1
import os
import sys

import yaml

workflow = yaml.safe_load(open(os.environ['WORKFLOW_YML'], encoding='utf-8'))
inputs = workflow[True]['workflow_call']['inputs']
problems = []
if inputs.get('pr-comment', {}).get('default', 'MISSING') is not False:
    problems.append('pr-comment must be a boolean input defaulting to false')
job = workflow['jobs'].get('pr-comment', {})
condition = str(job.get('if', ''))
for needle in ('inputs.pr-comment', "github.event_name == 'pull_request'"):
    if needle not in condition:
        problems.append(f'pr-comment job if: lacks {needle}')
if 'permissions' in job:
    problems.append('pr-comment must not request permissions: GitHub refuses to start a run whose caller does not grant them, even when the job is skipped')
for job_id in ('ios-dev-release', 'android-dev-release'):
    names = [step.get('name') for step in workflow['jobs'][job_id]['steps']]
    if 'Compute the runtime version' not in names or names.index('Compute the runtime version') > names.index('Compute build metadata'):
        problems.append(f'{job_id}: no runtime fingerprint before the build metadata')
    outputs = workflow['jobs'][job_id].get('outputs', {})
    for key in ('tag', 'fingerprint', 'asset-name'):
        if key not in outputs:
            problems.append(f'{job_id}: missing output {key}')
if problems:
    sys.exit('; '.join(problems))
PYTHON
)"; then
    pass_case
else
    fail_case "$failure"
fi

finish_suite
