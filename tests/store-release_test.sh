#!/usr/bin/env bash
# store-release.yml decides which stores a call releases to and fails closed,
# before any store is touched, when a selected platform lacks its secrets or
# its app id. Its validation and version steps run here extracted from the
# parsed workflow, and the parsed wiring is checked for the guarantees the
# workflow promises: dry run by default and the caller's GitHub Environment.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

WORKFLOW="$REPO_ROOT/.github/workflows/store-release.yml"

validate() {
    dir="$(new_workflow_workspace "$WORKFLOW" release 'Validate platforms and credentials')"
    run_step "$dir" \
        PLATFORMS='ios,android' \
        IOS_APP_ID='6449440933' \
        IOS_BUNDLE_ID='' \
        IOS_VERSION='2.35.0' \
        VERSION_FILE='' \
        ANDROID_PACKAGE='com.example.app' \
        ASC_API_KEY='key' \
        ASC_API_KEY_BASE64='' \
        ASC_KEY_ID='ABC123DEFG' \
        ASC_ISSUER_ID='69a6de70-03db-47e3-e053-5b8c7c11a4d1' \
        GOOGLE_SERVICE_ACCOUNT_JSON='{}' \
        "$@"
}

case_start 'both platforms with every credential select both stores'
validate PLATFORMS=' ios , android '
assert_equals 0 "$STEP_STATUS" "exit status ($(cat "$dir/log"))" \
    && assert_equals true "$(step_output "$dir" ios)" 'ios' \
    && assert_equals true "$(step_output "$dir" android)" 'android' \
    && pass_case

case_start 'android alone needs no App Store Connect secret'
validate PLATFORMS=android ASC_API_KEY='' ASC_KEY_ID='' ASC_ISSUER_ID='' IOS_APP_ID=''
assert_equals 0 "$STEP_STATUS" "exit status ($(cat "$dir/log"))" \
    && assert_equals false "$(step_output "$dir" ios)" 'ios' \
    && assert_equals true "$(step_output "$dir" android)" 'android' \
    && pass_case

case_start 'ios without its secrets fails closed naming every missing one'
validate PLATFORMS=ios ASC_API_KEY='' ASC_ISSUER_ID=''
log="$(cat "$dir/log")"
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$log" "::error::platforms 'ios' requires secret ASC_API_KEY or ASC_API_KEY_BASE64, which is empty." 'ASC_API_KEY' \
    && assert_contains "$log" "::error::platforms 'ios' requires secret ASC_ISSUER_ID, which is empty." 'ASC_ISSUER_ID' \
    && assert_not_contains "$log" 'ASC_KEY_ID' 'present secret' \
    && assert_equals '' "$(cat "$dir/outputs")" 'outputs' \
    && pass_case

case_start 'ios accepts a base64 key and a bundle id in place of the raw key and the app id'
validate PLATFORMS=ios ASC_API_KEY='' ASC_API_KEY_BASE64='a2V5' IOS_APP_ID='' IOS_BUNDLE_ID=com.example.app
assert_equals 0 "$STEP_STATUS" "exit status ($(cat "$dir/log"))" && assert_equals true "$(step_output "$dir" ios)" 'ios' && pass_case

case_start 'ios with both key forms, or with neither app id nor bundle id, fails closed'
validate PLATFORMS=ios ASC_API_KEY_BASE64='a2V5'
both="$STEP_STATUS $(cat "$dir/log")"
validate PLATFORMS=ios IOS_APP_ID=''
if assert_contains "$both" "1 " 'both keys status' \
    && assert_contains "$both" '::error::set only one of ASC_API_KEY and ASC_API_KEY_BASE64' 'both keys' \
    && assert_equals 1 "$STEP_STATUS" 'no app status' \
    && assert_contains "$(cat "$dir/log")" "requires input ios-app-id or ios-bundle-id, which is empty." 'no app'; then
    pass_case
fi

case_start 'a base64 key is decoded into the key file, and invalid base64 fails closed'
key_step() {
    dir="$(new_workflow_workspace "$WORKFLOW" release 'Write store credentials')"
    run_step "$dir" IOS=true ANDROID=false ASC_API_KEY='' GOOGLE_SERVICE_ACCOUNT_JSON='' "$@"
}
key_step ASC_API_KEY_BASE64="$(printf -- '-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n' | base64 | tr -d '\n')"
decoded="$(cat "$(step_output "$dir" asc-key-path)" 2>/dev/null || true)"
key_step ASC_API_KEY_BASE64='not base64!'
if assert_contains "$decoded" '-----BEGIN PRIVATE KEY-----' 'decoded key' \
    && assert_equals 1 "$STEP_STATUS" 'invalid base64 status' \
    && assert_contains "$(cat "$dir/log")" '::error::ASC_API_KEY_BASE64 is not valid base64' 'invalid base64'; then
    pass_case
fi

case_start 'android without the service account fails closed'
validate PLATFORMS=android GOOGLE_SERVICE_ACCOUNT_JSON=''
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" "requires secret GOOGLE_SERVICE_ACCOUNT_JSON, which is empty." 'error' \
    && pass_case

case_start 'ios without a version or a version file fails closed'
validate PLATFORMS=ios IOS_VERSION=''
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" 'requires input ios-version or version-file' 'error' \
    && pass_case

for platforms in iso 'ios,web' ''; do
    case_start "platforms '$platforms' fails closed"
    validate PLATFORMS="$platforms"
    assert_equals 1 "$STEP_STATUS" 'exit status' \
        && assert_contains "$(cat "$dir/log")" '::error::platforms' 'error' \
        && pass_case
done

version() {
    dir="$(new_workflow_workspace "$WORKFLOW" release 'Resolve the iOS version')"
    printf '{"name":"app","version":"2.35.0"}' > "$dir/work/package.json"
    printf '{"name":"app"}' > "$dir/work/no-version.json"
    run_step "$dir" IOS_VERSION='' VERSION_FILE='package.json' "$@"
}

case_start 'an explicit ios-version wins over the version file'
version IOS_VERSION=3.0.0
assert_equals 0 "$STEP_STATUS" 'exit status' && assert_equals 3.0.0 "$(step_output "$dir" version)" 'version' && pass_case

case_start 'an empty ios-version reads the top-level version of version-file'
version
assert_equals 0 "$STEP_STATUS" "exit status ($(cat "$dir/log"))" && assert_equals 2.35.0 "$(step_output "$dir" version)" 'version' && pass_case

case_start 'a version file without a version fails closed'
version VERSION_FILE=no-version.json
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" "::error::version-file 'no-version.json' has no top-level string \"version\"." 'error' \
    && pass_case

case_start 'a missing version file fails closed'
version VERSION_FILE=absent.json
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" "::error::version-file 'absent.json' does not exist" 'error' \
    && pass_case

case_start 'the workflow is a dry run by default, runs in the caller environment and threads dry-run to both stores'
if failure="$(WORKFLOW="$WORKFLOW" python3 - <<'PYTHON' 2>&1
import os
import sys

import yaml

workflow = yaml.safe_load(open(os.environ['WORKFLOW'], encoding='utf-8'))
call = workflow.get('on', workflow.get(True))['workflow_call']
job = workflow['jobs']['release']
problems = []
if call['inputs']['dry-run'].get('default') is not True:
    problems.append('dry-run does not default to true')
if job.get('environment') != '${{ inputs.github-environment }}':
    problems.append(f"environment is {job.get('environment')!r}")
for secret in ('ASC_API_KEY', 'ASC_KEY_ID', 'ASC_ISSUER_ID', 'GOOGLE_SERVICE_ACCOUNT_JSON'):
    if call['secrets'][secret].get('required') is not False:
        problems.append(f'{secret} is not optional')
steps = {step.get('name'): step for step in job['steps']}
for name in ('Release on the App Store', 'Release on Google Play'):
    if steps[name]['with'].get('dry-run') != '${{ inputs.dry-run }}':
        problems.append(f'{name} is not given inputs.dry-run')
if steps['Remove store credentials'].get('if') != 'always()':
    problems.append('the credentials are not removed in always()')
if problems:
    sys.exit('; '.join(problems))
PYTHON
)"; then
    pass_case
else
    fail_case "$failure"
fi

finish_suite
