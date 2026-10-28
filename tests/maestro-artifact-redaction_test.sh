#!/usr/bin/env bash
# Masking only covers the job log. A Maestro artifact is a file: maestro.log and
# the commands JSON record every inputText a flow typed, and a logcat records
# whatever the app printed, so a maestro-secrets-env value a flow used would be
# uploaded in clear unless the run-maestro actions scrub it first. This suite
# runs the real redaction step from each of them.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

STEP='Redact secret values from the artifacts'
ACTIONS=(run-maestro-ios run-maestro-android run-maestro-android-redroid run-maestro-device-cloud)

case_start 'every Maestro action redacts with the same script'
reference="$(extract_step_script "$REPO_ROOT/actions/${ACTIONS[0]}/action.yml" "$STEP")"
mismatch=''
for action in "${ACTIONS[@]}"; do
    if [ "$(extract_step_script "$REPO_ROOT/actions/$action/action.yml" "$STEP")" != "$reference" ]; then
        mismatch="$action"
    fi
done
if [ -n "$mismatch" ]; then
    fail_case "$mismatch redacts differently from ${ACTIONS[0]}"
else
    pass_case
fi

for action in "${ACTIONS[@]}"; do
    case_start "$action: the upload runs after the redaction, and the redaction runs on failure too"
    if ACTION_YML="$REPO_ROOT/actions/$action/action.yml" STEP_NAME="$STEP" python3 - <<'PYTHON'
import os
import sys

import yaml

steps = yaml.safe_load(open(os.environ['ACTION_YML'], encoding='utf-8'))['runs']['steps']
names = [step.get('name') for step in steps]
redact = names.index(os.environ['STEP_NAME'])
upload = names.index('Upload Maestro artifacts')
if redact != upload - 1:
    sys.exit(f'redaction is step {redact}, upload is step {upload}')
if not str(steps[redact].get('if', '')).startswith('always()'):
    sys.exit('redaction is skipped when a flow fails, which is exactly when maestro.log is uploaded')
PYTHON
    then
        pass_case
    else
        fail_case 'see above'
    fi
done

ACTION="$REPO_ROOT/actions/${ACTIONS[0]}/action.yml"

case_start 'a typed password is scrubbed from every text artifact and binaries are left alone'
dir="$(new_workspace "$ACTION" "$STEP")"
artifacts="$dir/work/artifacts"
mkdir -p "$artifacts/flow"
printf 'Input text "s3cr.t+pw"\nother line\n' > "$artifacts/maestro.log"
printf '{"text":"s3cr.t+pw","user":"demo"}\n' > "$artifacts/flow/commands-login.json"
printf 'D/App: token=tok-9\n' > "$artifacts/logcat.txt"
printf '\x89PNG\x00s3cr.t+pw\x00' > "$artifacts/final.png"
run_step "$dir" ARTIFACTS_DIR="$artifacts" REDACT_ENV_NAMES=$'TEST_PASSWORD\nAPI_TOKEN\nUNSET_ONE' \
    TEST_PASSWORD='s3cr.t+pw' API_TOKEN='tok-9'
assert_equals 0 "$STEP_STATUS" "exit status ($(cat "$dir/log"))" \
    && assert_equals $'Input text "***"\nother line' "$(cat "$artifacts/maestro.log")" 'maestro.log' \
    && assert_equals '{"text":"***","user":"demo"}' "$(cat "$artifacts/flow/commands-login.json")" 'commands JSON' \
    && assert_equals 'D/App: token=***' "$(cat "$artifacts/logcat.txt")" 'logcat' \
    && assert_contains "$(cat "$dir/log")" '3 artifact file(s)' 'summary' \
    && pass_case

case_start 'a regex metacharacter in a value is matched literally'
dir="$(new_workspace "$ACTION" "$STEP")"
artifacts="$dir/work/artifacts"
mkdir -p "$artifacts"
printf 'a.b and axb\n' > "$artifacts/maestro.log"
run_step "$dir" ARTIFACTS_DIR="$artifacts" REDACT_ENV_NAMES='DOTTED' DOTTED='a.b'
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals '*** and axb' "$(cat "$artifacts/maestro.log")" 'maestro.log' \
    && pass_case

case_start 'a multi-line value is redacted line by line, wherever its lines land'
dir="$(new_workspace "$ACTION" "$STEP")"
artifacts="$dir/work/artifacts"
mkdir -p "$artifacts"
printf 'first: line-one-secret\nlater: line-two-secret\n' > "$artifacts/maestro.log"
run_step "$dir" ARTIFACTS_DIR="$artifacts" REDACT_ENV_NAMES='PEM' PEM=$'line-one-secret\nline-two-secret'
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals $'first: ***\nlater: ***' "$(cat "$artifacts/maestro.log")" 'maestro.log' \
    && pass_case

case_start 'a failed rewrite deletes the artifacts instead of uploading them half-redacted'
dir="$(new_workspace "$ACTION" "$STEP")"
artifacts="$dir/work/artifacts"
mkdir -p "$artifacts"
printf 'token=tok-9\n' > "$artifacts/maestro.log"
stub "$dir" perl 'exit 13'
run_step "$dir" ARTIFACTS_DIR="$artifacts" REDACT_ENV_NAMES='API_TOKEN' API_TOKEN='tok-9'
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_equals 'absent' "$([ -e "$artifacts" ] && echo present || echo absent)" 'artifacts dir' \
    && pass_case

case_start 'a bad name fails closed and leaves nothing to upload'
dir="$(new_workspace "$ACTION" "$STEP")"
artifacts="$dir/work/artifacts"
mkdir -p "$artifacts"
printf 'secret\n' > "$artifacts/maestro.log"
run_step "$dir" ARTIFACTS_DIR="$artifacts" REDACT_ENV_NAMES='NOT-A-NAME'
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_equals 'absent' "$([ -e "$artifacts" ] && echo present || echo absent)" 'artifacts dir' \
    && pass_case

case_start 'a missing artifacts directory is not an error'
dir="$(new_workspace "$ACTION" "$STEP")"
run_step "$dir" ARTIFACTS_DIR="$dir/work/never-written" REDACT_ENV_NAMES='X' X='y'
assert_equals 0 "$STEP_STATUS" 'exit status' && pass_case

finish_suite
