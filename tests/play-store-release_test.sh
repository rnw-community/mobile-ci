#!/usr/bin/env bash
# play-store-release's step runs its real Node script with a real RSA service
# account key against a preloaded fetch mock (tests/lib/fetch-mock.mjs) that
# serves canned OAuth and Play Developer API responses and logs every request,
# so the version code it resolves, the release it writes, what a dry run may
# call and how rollout is validated are what gets tested.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/play-store-release/action.yml"
TOKEN_URI='https://oauth2.example.test/token'
EDITS='https://androidpublisher.googleapis.com/androidpublisher/v3/applications/com.example.app/edits'
INTERNAL='{"track":"internal","releases":[{"name":"56 (2.34.0)","versionCodes":["56"],"status":"completed"},{"name":"57 (2.35.0)","versionCodes":["57"],"status":"completed","releaseNotes":[{"language":"en-US","text":"Bug fixes"}]}]}'
PRODUCTION='{"track":"production","releases":[{"name":"56 (2.34.0)","versionCodes":["56"],"status":"completed"}]}'

play_workspace() {
    local dir
    dir="$(new_workspace "$ACTION" 'Release on Google Play')"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$dir/key.pem" 2>/dev/null
    jq -n --rawfile key "$dir/key.pem" --arg uri "$TOKEN_URI" \
        '{type: "service_account", client_email: "ci@example.iam.gserviceaccount.com", private_key: $key, token_uri: $uri}' \
        > "$dir/service-account.json"
    : > "$dir/routes.jsonl"
    : > "$dir/requests.jsonl"
    printf '%s\n' "$dir"
}

route() {
    local dir="$1" key="$2" status="$3" body="$4"
    jq -cn --arg key "$key" --argjson status "$status" --argjson body "$body" \
        '{($key): {status: $status, body: $body}}' >> "$dir/routes.jsonl"
}

edit_routes() {
    local dir="$1" production="${2:-$PRODUCTION}"
    route "$dir" "POST $TOKEN_URI" 200 '{"access_token":"play-token","expires_in":3600}'
    route "$dir" "POST $EDITS" 200 '{"id":"edit-1"}'
    route "$dir" "GET $EDITS/edit-1/tracks/internal" 200 "$INTERNAL"
    route "$dir" "GET $EDITS/edit-1/tracks/production" 200 "$production"
    route "$dir" "PUT $EDITS/edit-1/tracks/production" 200 '{}'
    route "$dir" "POST $EDITS/edit-1:commit" 200 '{"id":"edit-1"}'
    route "$dir" "DELETE $EDITS/edit-1" 204 null
}

release() {
    local dir="$1"
    shift
    jq -s 'add // {}' "$dir/routes.jsonl" > "$dir/routes.json"
    run_step "$dir" \
        GITHUB_ACTION_PATH="$REPO_ROOT/actions/play-store-release" \
        NODE_OPTIONS="--import=$REPO_ROOT/tests/lib/fetch-mock.mjs" \
        FETCH_MOCK_ROUTES="$dir/routes.json" \
        FETCH_MOCK_LOG="$dir/requests.jsonl" \
        PACKAGE_NAME='com.example.app' \
        FROM_TRACK='internal' \
        TO_TRACK='production' \
        VERSION_CODE='' \
        ROLLOUT='1' \
        RELEASE_NOTES_FROM_SOURCE='true' \
        DRY_RUN='true' \
        SERVICE_ACCOUNT_KEY_PATH="$dir/service-account.json" \
        "$@"
}

requests() {
    jq -r '.key' "$1/requests.jsonl"
}

track_update() {
    jq -c 'select(.key | startswith("PUT ")) | .body | fromjson' "$1/requests.jsonl"
}

case_start 'dry-run defaults to true and the tracks to internal -> production'
assert_equals 'true internal production 1' \
    "$(action_input_default "$ACTION" dry-run) $(action_input_default "$ACTION" from-track) $(action_input_default "$ACTION" to-track) $(action_input_default "$ACTION" rollout)" \
    'defaults' && pass_case

case_start 'a dry run resolves the highest version code, reads both tracks and discards the edit'
dir="$(play_workspace)"
edit_routes "$dir"
release "$dir"
log="$(cat "$dir/log")"
assert_equals 0 "$STEP_STATUS" "exit status (log: $log)" \
    && assert_equals "POST $TOKEN_URI
POST $EDITS
GET $EDITS/edit-1/tracks/internal
GET $EDITS/edit-1/tracks/production
DELETE $EDITS/edit-1" "$(requests "$dir")" 'requests' \
    && assert_equals 57 "$(step_output "$dir" version-code)" 'version-code' \
    && assert_equals planned "$(step_output "$dir" result)" 'result' \
    && assert_contains "$(cat "$dir/summary")" '| Promote to production | 57, completed (100%), 1 release-note language(s) copied | would do |' 'summary' \
    && pass_case

case_start 'the OAuth assertion is a verifiable RS256 JWT for the androidpublisher scope'
assertion="$(jq -r 'select(.key == "POST '"$TOKEN_URI"'") | .body' "$dir/requests.jsonl" | sed -E 's/.*assertion=([^&]+).*/\1/')"
# shellcheck disable=SC2016 # the script is JavaScript, expanded by node, not the shell.
verdict="$(TOKEN="$assertion" KEY="$dir/key.pem" node --input-type=module -e '
import { createPublicKey, verify } from "node:crypto";
import { readFileSync } from "node:fs";
const [header, payload, signature] = process.env.TOKEN.split(".");
const ok = verify("sha256", Buffer.from(`${header}.${payload}`), createPublicKey(readFileSync(process.env.KEY)), Buffer.from(signature, "base64url"));
const claims = JSON.parse(Buffer.from(payload, "base64url"));
console.log(`${ok} ${claims.iss} ${claims.scope} ${claims.aud}`);
')"
assert_equals "true ci@example.iam.gserviceaccount.com https://www.googleapis.com/auth/androidpublisher $TOKEN_URI" "$verdict" 'jwt' \
    && pass_case

case_start 'a real run completes the release with the source name and notes, then commits'
dir="$(play_workspace)"
edit_routes "$dir"
release "$dir" DRY_RUN=false
log="$(cat "$dir/log")"
assert_equals 0 "$STEP_STATUS" "exit status (log: $log)" \
    && assert_equals '{"track":"production","releases":[{"name":"57 (2.35.0)","versionCodes":["57"],"status":"completed","releaseNotes":[{"language":"en-US","text":"Bug fixes"}]}]}' \
        "$(track_update "$dir")" 'track update' \
    && assert_contains "$(requests "$dir")" "POST $EDITS/edit-1:commit" 'commit' \
    && assert_not_contains "$(requests "$dir")" "DELETE $EDITS/edit-1" 'committed edit not discarded' \
    && assert_equals released "$(step_output "$dir" result)" 'result' \
    && pass_case

case_start 'a fractional rollout is a staged inProgress release without copied notes when disabled'
dir="$(play_workspace)"
edit_routes "$dir" '{"track":"production"}'
release "$dir" DRY_RUN=false ROLLOUT=0.2 RELEASE_NOTES_FROM_SOURCE=false VERSION_CODE=56
assert_equals 0 "$STEP_STATUS" "exit status ($(cat "$dir/log"))" \
    && assert_equals '{"track":"production","releases":[{"name":"56 (2.34.0)","versionCodes":["56"],"status":"inProgress","userFraction":0.2}]}' \
        "$(track_update "$dir")" 'track update' \
    && pass_case

case_start 'a re-run when to-track already carries the version code completed changes nothing'
dir="$(play_workspace)"
edit_routes "$dir" '{"track":"production","releases":[{"name":"57 (2.35.0)","versionCodes":["57"],"status":"completed"}]}'
release "$dir" DRY_RUN=false
assert_equals 0 "$STEP_STATUS" "exit status ($(cat "$dir/log"))" \
    && assert_equals '' "$(track_update "$dir")" 'track update' \
    && assert_not_contains "$(requests "$dir")" ':commit' 'commit' \
    && assert_contains "$(requests "$dir")" "DELETE $EDITS/edit-1" 'edit discarded' \
    && assert_equals already-released "$(step_output "$dir" result)" 'result' \
    && pass_case

case_start 'a re-run at the same staged fraction changes nothing, a larger fraction moves the rollout'
dir="$(play_workspace)"
edit_routes "$dir" '{"track":"production","releases":[{"versionCodes":["57"],"status":"inProgress","userFraction":0.2}]}'
release "$dir" DRY_RUN=false ROLLOUT=0.2
same="$(step_output "$dir" result)"
dir="$(play_workspace)"
edit_routes "$dir" '{"track":"production","releases":[{"versionCodes":["57"],"status":"inProgress","userFraction":0.2}]}'
release "$dir" DRY_RUN=false ROLLOUT=0.5
assert_equals already-released "$same" 'same fraction' \
    && assert_equals released "$(step_output "$dir" result)" 'larger fraction' \
    && assert_contains "$(track_update "$dir")" '"userFraction":0.5' 'fraction' \
    && pass_case

case_start 'a version code that is not on from-track fails closed and discards the edit'
dir="$(play_workspace)"
edit_routes "$dir"
release "$dir" DRY_RUN=false VERSION_CODE=99
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" "::error::version code 99 is not on track 'internal'" 'error' \
    && assert_equals '' "$(track_update "$dir")" 'track update' \
    && assert_contains "$(requests "$dir")" "DELETE $EDITS/edit-1" 'edit discarded' \
    && pass_case

for rollout in 0 1.5 50% abc ''; do
    case_start "rollout '$rollout' fails before any request"
    dir="$(play_workspace)"
    release "$dir" ROLLOUT="$rollout"
    assert_equals 1 "$STEP_STATUS" 'exit status' \
        && assert_contains "$(cat "$dir/log")" "::error::rollout '$rollout' must be a fraction in (0, 1]" 'error' \
        && assert_equals '' "$(requests "$dir")" 'requests' \
        && pass_case
done

case_start 'promoting a track onto itself fails before any request'
dir="$(play_workspace)"
release "$dir" TO_TRACK=internal
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" "::error::from-track and to-track are both 'internal'" 'error' \
    && assert_equals '' "$(requests "$dir")" 'requests' \
    && pass_case

case_start 'a Play API error is reported with its status and message'
dir="$(play_workspace)"
route "$dir" "POST $TOKEN_URI" 200 '{"access_token":"play-token"}'
route "$dir" "POST $EDITS" 403 '{"error":{"code":403,"status":"PERMISSION_DENIED","message":"The caller does not have permission"}}'
release "$dir"
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" "returned HTTP 403: PERMISSION_DENIED: The caller does not have permission" 'error' \
    && pass_case

finish_suite
