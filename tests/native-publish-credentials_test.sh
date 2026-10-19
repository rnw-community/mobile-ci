#!/usr/bin/env bash
# native-publish.yml's credentials-source: eas lets eas build / eas submit use
# the credentials stored on EAS instead of keys passed as GitHub secrets, and
# record-scope lets one caller run the workflow once per brand in a matrix
# without the calls overwriting each other's store build record, artifacts or
# concurrency slot. The submissions output reports what each target submitted.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

WORKFLOW_YML="$REPO_ROOT/.github/workflows/native-publish.yml"
SECRETS_STEP='Validate required secrets'
SUBMISSION_ID='7c1d2e3f-4a5b-4c6d-8e7f-9a0b1c2d3e4f'
SUBMISSION_URL="https://expo.dev/accounts/acme/projects/app/submissions/${SUBMISSION_ID}"

ios_secrets() {
    workspace="$(new_workflow_workspace "$WORKFLOW_YML" ios-publish "$SECRETS_STEP")"
    run_step "$workspace" CREDENTIALS_SOURCE=secrets EXPO_TOKEN=t ASC_API_KEY=k ASC_KEY_ID=i ASC_ISSUER_ID=s "$@"
}

android_secrets() {
    workspace="$(new_workflow_workspace "$WORKFLOW_YML" android-publish "$SECRETS_STEP")"
    run_step "$workspace" CREDENTIALS_SOURCE=secrets EXPO_TOKEN=t GOOGLE_SERVICE_ACCOUNT_JSON='{}' "$@"
}

case_start 'ios-publish: secrets mode with every App Store Connect secret passes'
ios_secrets
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))"; then
    pass_case
fi

case_start 'ios-publish: secrets mode still fails closed without ASC_API_KEY'
ios_secrets ASC_API_KEY=''
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$workspace/log")" 'ASC_API_KEY' 'missing secret named' \
    && assert_contains "$(cat "$workspace/log")" 'credentials-source: eas' 'alternative named'; then
    pass_case
fi

case_start 'ios-publish: eas mode needs only EXPO_TOKEN'
ios_secrets CREDENTIALS_SOURCE=eas ASC_API_KEY='' ASC_KEY_ID='' ASC_ISSUER_ID=''
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))"; then
    pass_case
fi

case_start 'ios-publish: eas mode still fails closed without EXPO_TOKEN'
ios_secrets CREDENTIALS_SOURCE=eas EXPO_TOKEN='' ASC_API_KEY='' ASC_KEY_ID='' ASC_ISSUER_ID=''
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$workspace/log")" 'EXPO_TOKEN' 'missing secret named'; then
    pass_case
fi

case_start 'ios-publish: eas mode with a partial App Store Connect key fails closed'
ios_secrets CREDENTIALS_SOURCE=eas ASC_KEY_ID='' ASC_ISSUER_ID=''
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$workspace/log")" 'ASC_KEY_ID' 'missing companion named'; then
    pass_case
fi

case_start 'ios-publish: an unknown credentials-source fails closed'
ios_secrets CREDENTIALS_SOURCE=vault
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$workspace/log")" "'vault'" 'value named'; then
    pass_case
fi

case_start 'android-publish: secrets mode still fails closed without GOOGLE_SERVICE_ACCOUNT_JSON'
android_secrets GOOGLE_SERVICE_ACCOUNT_JSON=''
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$workspace/log")" 'GOOGLE_SERVICE_ACCOUNT_JSON' 'missing secret named'; then
    pass_case
fi

case_start 'android-publish: eas mode needs only EXPO_TOKEN'
android_secrets CREDENTIALS_SOURCE=eas GOOGLE_SERVICE_ACCOUNT_JSON=''
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))"; then
    pass_case
fi

case_start 'android-publish: eas mode still fails closed without EXPO_TOKEN'
android_secrets CREDENTIALS_SOURCE=eas EXPO_TOKEN='' GOOGLE_SERVICE_ACCOUNT_JSON=''
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$workspace/log")" 'EXPO_TOKEN' 'missing secret named'; then
    pass_case
fi

case_start 'android-publish: an unknown credentials-source fails closed'
android_secrets CREDENTIALS_SOURCE=''
if assert_equals 1 "$STEP_STATUS" 'status'; then
    pass_case
fi

# --- record-scope ----------------------------------------------------------------------

TARGETS_STEP='Resolve publish targets'
run_targets() {
    workspace="$(new_workflow_workspace "$WORKFLOW_YML" plan "$TARGETS_STEP")"
    mkdir -p "$workspace/work/apps/mobile"
    echo '{"build":{"brand-a":{}},"submit":{"production":{}}}' > "$workspace/work/apps/mobile/eas.json"
    run_step "$workspace" APP_DIR=apps/mobile TARGETS='' ENABLE_IOS=true ENABLE_ANDROID=true \
        BUILD_PROFILE=brand-a SUBMIT_PROFILE=production MODE=native OTA_BASELINE=github-release WRITE_STORE_RECORD=false \
        RELEASE_TAG_INPUT='' REF_TYPE=branch REF_NAME=main RECORD_SCOPE='' "$@"
}

case_start 'record-scope: empty keeps the app-dir record name and the artifact names'
run_targets
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))" \
    && assert_equals store-record-apps-mobile.json "$(step_output "$workspace" record-asset)" 'record asset' \
    && assert_equals 'store-submitted---' "$(step_output "$workspace" marker-prefix)" 'reserved unscoped marker prefix' \
    && assert_equals ',' "$(jq -r 'map(.artifactSuffix) | join(",")' <<< "$(step_output "$workspace" requested)")" 'artifact suffixes'; then
    pass_case
fi

case_start 'record-scope: names the record and scopes every per-call artifact'
run_targets RECORD_SCOPE=brand-a
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))" \
    && assert_equals store-record-brand-a.json "$(step_output "$workspace" record-asset)" 'record asset' \
    && assert_equals 'store-submitted-brand-a--' "$(step_output "$workspace" marker-prefix)" 'marker prefix' \
    && assert_equals '-brand-a--ios,-brand-a--android' "$(jq -r 'map(.artifactSuffix) | join(",")' <<< "$(step_output "$workspace" requested)")" 'artifact suffixes'; then
    pass_case
fi

case_start 'record-scope: the unscoped marker prefix matches no scoped marker, and no scope matches another'
if python3 -c '
import fnmatch, sys
names = ["store-submitted-brand-a--ios", "store-submitted-brand-a-x--ios", "store-submitted---ios"]
cases = {"store-submitted---*": ["store-submitted---ios"], "store-submitted-brand-a--*": ["store-submitted-brand-a--ios"]}
sys.exit(any(fnmatch.filter(names, p) != want for p, want in cases.items()))'; then
    pass_case
else
    fail_case 'a marker prefix matched another call'\''s marker'
fi

for scope in 'brand--a' '-brand' 'brand-' 'a/b' 'a b'; do
    case_start "record-scope: '$scope' fails closed, it could collide with another call's artifacts"
    run_targets RECORD_SCOPE="$scope"
    if assert_equals 1 "$STEP_STATUS" 'status' \
        && assert_contains "$(cat "$workspace/log")" 'record-scope' 'error' \
        && assert_equals '' "$(cat "$workspace/outputs")" 'no output'; then
        pass_case
    fi
done

# --- submissions -----------------------------------------------------------------------

for lane in 'ios-publish iOS ios' 'android-publish Android android'; do
    read -r job label platform <<< "$lane"

    case_start "$job: the EAS submission page becomes the step's submission-url"
    workspace="$(new_workflow_workspace "$WORKFLOW_YML" "$job" "EAS submit ($label)")"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$workspace" npx 'printf "%s\n" "$@" > "$FAKE_NPX_ARGS"; echo "Submission details: $SUBMISSION_URL"; echo "Submitted your app"'
    run_step "$workspace" EAS_CLI_VERSION=20.5.1 SUBMIT_PROFILE=production ARTIFACT_PATH=/tmp/app.bin \
        FAKE_NPX_ARGS="$workspace/npx-args" SUBMISSION_URL="$SUBMISSION_URL" GOOGLE_APPLICATION_CREDENTIALS=''
    if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))" \
        && assert_contains "$(tr '\n' ' ' < "$workspace/npx-args")" "submit --platform $platform --profile production --non-interactive --path /tmp/app.bin" 'invocation' \
        && assert_equals "$SUBMISSION_URL" "$(step_output "$workspace" submission-url)" 'submission-url'; then
        pass_case
    fi

    case_start "$job: a submit whose page cannot be read warns and still succeeds"
    workspace="$(new_workflow_workspace "$WORKFLOW_YML" "$job" "EAS submit ($label)")"
    stub "$workspace" npx 'echo "Submitted your app"'
    run_step "$workspace" EAS_CLI_VERSION=20.5.1 SUBMIT_PROFILE=production ARTIFACT_PATH=/tmp/app.bin GOOGLE_APPLICATION_CREDENTIALS=''
    if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))" \
        && assert_contains "$(cat "$workspace/log")" '::warning::' 'warning' \
        && assert_equals '' "$(step_output "$workspace" submission-url)" 'submission-url'; then
        pass_case
    fi

    case_start "$job: a failed submit fails the step"
    workspace="$(new_workflow_workspace "$WORKFLOW_YML" "$job" "EAS submit ($label)")"
    stub "$workspace" npx 'echo "Submission details: '"$SUBMISSION_URL"'"; exit 1'
    run_step "$workspace" EAS_CLI_VERSION=20.5.1 SUBMIT_PROFILE=production ARTIFACT_PATH=/tmp/app.bin GOOGLE_APPLICATION_CREDENTIALS=''
    if assert_equals 1 "$STEP_STATUS" 'status'; then
        pass_case
    fi

    case_start "$job: without a store build record the marker still reports the submission"
    workspace="$(new_workflow_workspace "$WORKFLOW_YML" "$job" 'Record the submitted target')"
    run_step "$workspace" TARGET_NAME="$platform" TARGET_PLATFORM="$platform" BUILD_PROFILE=production \
        SUBMIT_PROFILE=production FINGERPRINTS='' RECORD=false SUBMISSION_URL="$SUBMISSION_URL"
    marker="$workspace/runner-temp/store-submitted/$platform.json"
    if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))" \
        && assert_equals "$SUBMISSION_URL $SUBMISSION_ID" "$(jq -r '"\(.submissionUrl) \(.submissionId)"' "$marker" 2>/dev/null || true)" 'marker submission'; then
        pass_case
    fi

    case_start "$job: with a store build record a missing fingerprint still fails closed"
    workspace="$(new_workflow_workspace "$WORKFLOW_YML" "$job" 'Record the submitted target')"
    run_step "$workspace" TARGET_NAME="$platform" TARGET_PLATFORM="$platform" BUILD_PROFILE=production \
        SUBMIT_PROFILE=production FINGERPRINTS='{}' RECORD=true SUBMISSION_URL="$SUBMISSION_URL"
    if assert_equals 1 "$STEP_STATUS" 'status'; then
        pass_case
    fi
done

case_start 'status: the markers become the submissions output'
workspace="$(new_workflow_workspace "$WORKFLOW_YML" status 'Collect the submissions')"
mkdir -p "$workspace/markers"
echo "{\"name\":\"brand-a-ios\",\"platform\":\"ios\",\"fingerprint\":\"\",\"submissionUrl\":\"$SUBMISSION_URL\",\"submissionId\":\"$SUBMISSION_ID\"}" > "$workspace/markers/brand-a-ios.json"
echo '{"name":"brand-a-android","platform":"android","fingerprint":"","submissionUrl":"","submissionId":""}' > "$workspace/markers/brand-a-android.json"
run_step "$workspace" MARKER_DIR="$workspace/markers"
submissions="$(step_output "$workspace" submissions)"
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))" \
    && assert_equals "ios $SUBMISSION_ID" "$(jq -r '.["brand-a-ios"] | "\(.platform) \(.submissionId)"' <<< "$submissions")" 'ios entry' \
    && assert_equals 'android ' "$(jq -r '.["brand-a-android"] | "\(.platform) \(.submissionId)"' <<< "$submissions")" 'android entry'; then
    pass_case
fi

case_start 'status: no marker is an empty submissions object'
workspace="$(new_workflow_workspace "$WORKFLOW_YML" status 'Collect the submissions')"
run_step "$workspace" MARKER_DIR="$workspace/missing"
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))" \
    && assert_equals '{}' "$(step_output "$workspace" submissions)" 'submissions'; then
    pass_case
fi

# --- wiring ----------------------------------------------------------------------------

case_start 'wiring: credentials-source, record-scope and the submissions output'
if failure="$(WORKFLOW_YML="$WORKFLOW_YML" python3 - <<'PYTHON' 2>&1
import os
import sys

import yaml

workflow = yaml.safe_load(open(os.environ['WORKFLOW_YML'], encoding='utf-8'))
call = workflow[True]['workflow_call']
inputs = call['inputs']
jobs = workflow['jobs']
problems = []
for name, default in (('credentials-source', 'secrets'), ('record-scope', '')):
    if inputs.get(name, {}).get('default', 'MISSING') != default:
        problems.append(f'input {name} must default to {default!r}')
if 'inputs.record-scope' not in str(workflow.get('concurrency', {}).get('group', '')):
    problems.append('the concurrency group must include record-scope, or one call per brand queues behind, and cancels, the others')
if 'jobs.status.outputs.submissions' not in str(call.get('outputs', {}).get('submissions', {}).get('value', '')):
    problems.append('workflow output submissions must read jobs.status.outputs.submissions')
if 'submissions' not in jobs['status'].get('outputs', {}):
    problems.append('status job must output submissions')
if 'marker-prefix' not in jobs['plan'].get('outputs', {}):
    problems.append('plan job must output marker-prefix')


def step(job, name):
    for candidate in jobs[job]['steps']:
        if candidate.get('name') == name:
            return candidate
    problems.append(f'{job}: no step {name!r}')
    return {}


for job, key_step, flag, secret in (
        ('ios-publish', 'Write App Store Connect API key', 'HAS_ASC_KEY', 'ASC_API_KEY'),
        ('android-publish', 'Write Google service account key', 'HAS_GOOGLE_KEY', 'GOOGLE_SERVICE_ACCOUNT_JSON')):
    if f"secrets.{secret} != ''" not in str(jobs[job].get('env', {}).get(flag, '')):
        problems.append(f'{job}: job env {flag} must test secrets.{secret}')
    if f"env.{flag} == 'true'" not in str(step(job, key_step).get('if', '')):
        problems.append(f'{job}: {key_step!r} must run only when the secret is set')
    if 'inputs.credentials-source' not in str(step(job, 'Validate required secrets').get('env', {}).get('CREDENTIALS_SOURCE', '')):
        problems.append(f'{job}: secret validation must read credentials-source')
    record = step(job, 'Record the submitted target')
    if 'if' in record:
        problems.append(f'{job}: the submitted-target marker must be written on every submit, not only with a record')
    upload = step(job, 'Upload the submitted-target marker')
    if 'if' in upload:
        problems.append(f'{job}: the marker upload must run on every submit')
    if str(upload.get('with', {}).get('name', '')) != '${{ needs.plan.outputs.marker-prefix }}${{ matrix.target.name }}':
        problems.append(f'{job}: the marker artifact must be named <marker-prefix><target name>')
for job in ('record', 'status'):
    download = step(job, 'Download the submitted-target markers')
    if str(download.get('with', {}).get('pattern', '')) != '${{ needs.plan.outputs.marker-prefix }}*':
        problems.append(f'{job}: the marker download pattern must be <marker-prefix>*')
if problems:
    sys.exit('\n'.join(problems))
PYTHON
)"; then
    pass_case
else
    fail_case "$failure"
fi

finish_suite
