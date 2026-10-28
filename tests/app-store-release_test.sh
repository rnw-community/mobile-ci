#!/usr/bin/env bash
# app-store-release's step runs its real Node script with a real ES256 key
# against a preloaded fetch mock (tests/lib/fetch-mock.mjs) that serves canned
# App Store Connect responses and logs every request, so the plan it resolves,
# the calls a dry run is allowed to make and what an already-submitted version
# does are what gets tested.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/app-store-release/action.yml"
ASC='https://api.appstoreconnect.apple.com/v1'
APP='6449440933'
BUILDS_QUERY="filter[app]=$APP&filter[preReleaseVersion.version]=2.35.0&filter[preReleaseVersion.platform]=IOS&sort=-uploadedDate&limit=1"
VERSIONS="$ASC/apps/$APP/appStoreVersions?filter[platform]=IOS&limit=1"
EDITABLE='PREPARE_FOR_SUBMISSION,READY_FOR_REVIEW,DEVELOPER_REJECTED,REJECTED,METADATA_REJECTED,INVALID_BINARY'
SUBMISSIONS="$ASC/reviewSubmissions?filter[app]=$APP&filter[platform]=IOS&filter[state]=READY_FOR_REVIEW,UNRESOLVED_ISSUES&limit=1"
VALID_BUILD='{"data":[{"id":"build-1","attributes":{"version":"123","processingState":"VALID","usesNonExemptEncryption":false}}]}'

asc_workspace() {
    local dir
    dir="$(new_workspace "$ACTION" 'Release on the App Store')"
    openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null \
        | openssl pkcs8 -topk8 -nocrypt -out "$dir/key.p8"
    : > "$dir/routes.jsonl"
    : > "$dir/requests.jsonl"
    printf '%s\n' "$dir"
}

route() {
    local dir="$1" key="$2" status="$3" body="$4"
    jq -cn --arg key "$key" --argjson status "$status" --argjson body "$body" \
        '{($key): {status: $status, body: $body}}' >> "$dir/routes.jsonl"
}

base_routes() {
    local dir="$1"
    route "$dir" "GET $ASC/apps/$APP" 200 '{"data":{"id":"6449440933","attributes":{"bundleId":"com.example.app"}}}'
    route "$dir" "GET $ASC/builds?$BUILDS_QUERY&filter[processingState]=VALID&filter[expired]=false" 200 "$VALID_BUILD"
}

new_version_routes() {
    local dir="$1"
    base_routes "$dir"
    route "$dir" "GET $VERSIONS&filter[versionString]=2.35.0" 200 '{"data":[]}'
    route "$dir" "GET $VERSIONS&filter[appVersionState]=$EDITABLE" 200 '{"data":[]}'
    route "$dir" "GET $SUBMISSIONS" 200 '{"data":[]}'
}

release() {
    local dir="$1"
    shift
    jq -s 'add // {}' "$dir/routes.jsonl" > "$dir/routes.json"
    run_step "$dir" \
        GITHUB_ACTION_PATH="$REPO_ROOT/actions/app-store-release" \
        NODE_OPTIONS="--import=$REPO_ROOT/tests/lib/fetch-mock.mjs" \
        FETCH_MOCK_ROUTES="$dir/routes.json" \
        FETCH_MOCK_LOG="$dir/requests.jsonl" \
        APP_ID="$APP" \
        BUNDLE_ID='' \
        VERSION='2.35.0' \
        BUILD_NUMBER='' \
        RELEASE_TYPE='MANUAL' \
        SCHEDULED_RELEASE_DATE='' \
        PHASED_RELEASE='false' \
        DRY_RUN='true' \
        ASC_KEY_PATH="$dir/key.p8" \
        ASC_KEY_ID='ABC123DEFG' \
        ASC_ISSUER_ID='69a6de70-03db-47e3-e053-5b8c7c11a4d1' \
        "$@"
}

requests() {
    jq -r '.key' "$1/requests.jsonl"
}

mutations() {
    jq -r 'select(.key | startswith("GET ") | not) | .key' "$1/requests.jsonl"
}

case_start 'dry-run defaults to true'
assert_equals 'true' "$(action_input_default "$ACTION" dry-run)" 'dry-run default' && pass_case

case_start 'a dry run resolves the newest valid build and plans the whole submission with GETs only'
dir="$(asc_workspace)"
new_version_routes "$dir"
release "$dir"
log="$(cat "$dir/log")"
assert_equals 0 "$STEP_STATUS" "exit status (log: $log)" \
    && assert_equals '' "$(mutations "$dir")" 'mutating requests' \
    && assert_equals planned "$(step_output "$dir" result)" 'result' \
    && assert_equals 123 "$(step_output "$dir" build-number)" 'build-number' \
    && assert_contains "$(cat "$dir/summary")" '| Create App Store version | 2.35.0, MANUAL | would do |' 'create planned' \
    && assert_contains "$(cat "$dir/summary")" '| Submit for App Review | 2.35.0 (123) | would do |' 'submit planned' \
    && assert_contains "$(cat "$dir/summary")" 'dry run: nothing was changed' 'dry-run title' \
    && pass_case

case_start 'the request is signed with a verifiable ES256 JWT for appstoreconnect-v1'
token="$(jq -r 'select(.key == "GET '"$ASC/apps/$APP"'") | .authorization' "$dir/requests.jsonl" | sed 's/^Bearer //')"
# shellcheck disable=SC2016 # the script is JavaScript, expanded by node, not the shell.
verdict="$(TOKEN="$token" KEY="$dir/key.p8" node --input-type=module -e '
import { createPublicKey, verify } from "node:crypto";
import { readFileSync } from "node:fs";
const [header, payload, signature] = process.env.TOKEN.split(".");
const ok = verify("sha256", Buffer.from(`${header}.${payload}`), { key: createPublicKey(readFileSync(process.env.KEY)), dsaEncoding: "ieee-p1363" }, Buffer.from(signature, "base64url"));
const claims = JSON.parse(Buffer.from(payload, "base64url"));
console.log(`${ok} ${JSON.parse(Buffer.from(header, "base64url")).kid} ${claims.aud} ${claims.exp - claims.iat}`);
')"
assert_equals 'true ABC123DEFG appstoreconnect-v1 1200' "$verdict" 'jwt' && pass_case

case_start 'a real run creates the version, attaches the build and submits it for review'
dir="$(asc_workspace)"
new_version_routes "$dir"
route "$dir" "POST $ASC/appStoreVersions" 201 '{"data":{"id":"ver-1","attributes":{"versionString":"2.35.0","appVersionState":"PREPARE_FOR_SUBMISSION","releaseType":"AFTER_APPROVAL"}}}'
route "$dir" "PATCH $ASC/appStoreVersions/ver-1/relationships/build" 204 null
route "$dir" "GET $ASC/appStoreVersions/ver-1/appStoreVersionPhasedRelease" 200 '{"data":null}'
route "$dir" "POST $ASC/appStoreVersionPhasedReleases" 201 '{"data":{"id":"phased-1"}}'
route "$dir" "POST $ASC/reviewSubmissions" 201 '{"data":{"id":"sub-1","attributes":{"state":"READY_FOR_REVIEW"}}}'
route "$dir" "GET $ASC/reviewSubmissions/sub-1/items?include=appStoreVersion&limit=50" 200 '{"data":[]}'
route "$dir" "POST $ASC/reviewSubmissionItems" 201 '{"data":{"id":"item-1"}}'
route "$dir" "PATCH $ASC/reviewSubmissions/sub-1" 200 '{"data":{"id":"sub-1","attributes":{"state":"WAITING_FOR_REVIEW"}}}'
release "$dir" DRY_RUN=false RELEASE_TYPE=AFTER_APPROVAL PHASED_RELEASE=true
log="$(cat "$dir/log")"
expected="POST $ASC/appStoreVersions
PATCH $ASC/appStoreVersions/ver-1/relationships/build
POST $ASC/appStoreVersionPhasedReleases
POST $ASC/reviewSubmissions
POST $ASC/reviewSubmissionItems
PATCH $ASC/reviewSubmissions/sub-1"
assert_equals 0 "$STEP_STATUS" "exit status (log: $log)" \
    && assert_equals "$expected" "$(mutations "$dir")" 'mutating requests in order' \
    && assert_equals AFTER_APPROVAL "$(jq -r 'select(.key == "POST '"$ASC"'/appStoreVersions") | .body | fromjson | .data.attributes.releaseType' "$dir/requests.jsonl")" 'release type' \
    && assert_equals build-1 "$(jq -r 'select(.key | endswith("/relationships/build")) | .body | fromjson | .data.id' "$dir/requests.jsonl")" 'attached build' \
    && assert_equals true "$(jq -r 'select(.key == "PATCH '"$ASC"'/reviewSubmissions/sub-1") | .body | fromjson | .data.attributes.submitted' "$dir/requests.jsonl")" 'submitted' \
    && assert_equals submitted "$(step_output "$dir" result)" 'result' \
    && pass_case

case_start 'a re-run against a version already waiting for review with that build changes nothing'
dir="$(asc_workspace)"
base_routes "$dir"
route "$dir" "GET $VERSIONS&filter[versionString]=2.35.0" 200 '{"data":[{"id":"ver-1","attributes":{"versionString":"2.35.0","appVersionState":"WAITING_FOR_REVIEW"}}]}'
route "$dir" "GET $ASC/appStoreVersions/ver-1/build" 200 '{"data":{"id":"build-1"}}'
release "$dir" DRY_RUN=false
log="$(cat "$dir/log")"
assert_equals 0 "$STEP_STATUS" "exit status (log: $log)" \
    && assert_equals '' "$(mutations "$dir")" 'mutating requests' \
    && assert_equals already-submitted "$(step_output "$dir" result)" 'result' \
    && assert_contains "$(cat "$dir/summary")" '2.35.0 is already WAITING_FOR_REVIEW with build 123' 'summary' \
    && pass_case

case_start 'a version in review with another build fails closed'
dir="$(asc_workspace)"
base_routes "$dir"
route "$dir" "GET $VERSIONS&filter[versionString]=2.35.0" 200 '{"data":[{"id":"ver-1","attributes":{"versionString":"2.35.0","appStoreState":"IN_REVIEW"}}]}'
route "$dir" "GET $ASC/appStoreVersions/ver-1/build" 200 '{"data":{"id":"build-0"}}'
release "$dir" DRY_RUN=false
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" '::error::version 2.35.0 is IN_REVIEW with another build, not build 123' 'error' \
    && assert_equals '' "$(mutations "$dir")" 'mutating requests' \
    && pass_case

case_start 'an existing editable version reuses the submission and only attaches and submits'
dir="$(asc_workspace)"
base_routes "$dir"
route "$dir" "GET $VERSIONS&filter[versionString]=2.35.0" 200 '{"data":[{"id":"ver-1","attributes":{"versionString":"2.35.0","appVersionState":"PREPARE_FOR_SUBMISSION","releaseType":"MANUAL"}}]}'
route "$dir" "GET $ASC/appStoreVersions/ver-1/build" 200 '{"data":null}'
route "$dir" "GET $ASC/appStoreVersions/ver-1/appStoreVersionPhasedRelease" 404 '{"errors":[]}'
route "$dir" "GET $SUBMISSIONS" 200 '{"data":[{"id":"sub-9","attributes":{"state":"READY_FOR_REVIEW"}}]}'
route "$dir" "GET $ASC/reviewSubmissions/sub-9/items?include=appStoreVersion&limit=50" 200 '{"data":[{"id":"item-1","relationships":{"appStoreVersion":{"data":{"id":"ver-1"}}}}]}'
route "$dir" "PATCH $ASC/appStoreVersions/ver-1/relationships/build" 204 null
route "$dir" "PATCH $ASC/reviewSubmissions/sub-9" 200 '{"data":{"id":"sub-9"}}'
release "$dir" DRY_RUN=false
log="$(cat "$dir/log")"
assert_equals 0 "$STEP_STATUS" "exit status (log: $log)" \
    && assert_equals "PATCH $ASC/appStoreVersions/ver-1/relationships/build
PATCH $ASC/reviewSubmissions/sub-9" "$(mutations "$dir")" 'mutating requests' \
    && pass_case

case_start 'a build without an export compliance answer fails before any change'
dir="$(asc_workspace)"
route "$dir" "GET $ASC/apps/$APP" 200 '{"data":{"id":"6449440933","attributes":{}}}'
route "$dir" "GET $ASC/builds?$BUILDS_QUERY&filter[processingState]=VALID&filter[expired]=false" 200 \
    '{"data":[{"id":"build-1","attributes":{"version":"123","processingState":"VALID","usesNonExemptEncryption":null}}]}'
route "$dir" "GET $VERSIONS&filter[versionString]=2.35.0" 200 '{"data":[]}'
release "$dir" DRY_RUN=false
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" '::error::build 123 has no export compliance answer' 'error' \
    && assert_equals '' "$(mutations "$dir")" 'mutating requests' \
    && pass_case

case_start 'an explicit build number that is still processing fails closed'
dir="$(asc_workspace)"
route "$dir" "GET $ASC/apps/$APP" 200 '{"data":{"id":"6449440933","attributes":{}}}'
route "$dir" "GET $ASC/builds?$BUILDS_QUERY&filter[version]=124" 200 \
    '{"data":[{"id":"build-2","attributes":{"version":"124","processingState":"PROCESSING"}}]}'
release "$dir" BUILD_NUMBER=124
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" '::error::build 124 of version 2.35.0 is PROCESSING, not VALID' 'error' \
    && pass_case

case_start "a rejected submission surfaces App Store Connect's associated errors"
dir="$(asc_workspace)"
new_version_routes "$dir"
route "$dir" "POST $ASC/appStoreVersions" 201 '{"data":{"id":"ver-1","attributes":{}}}'
route "$dir" "PATCH $ASC/appStoreVersions/ver-1/relationships/build" 204 null
route "$dir" "GET $ASC/appStoreVersions/ver-1/appStoreVersionPhasedRelease" 200 '{"data":null}'
route "$dir" "POST $ASC/reviewSubmissions" 201 '{"data":{"id":"sub-1","attributes":{"state":"READY_FOR_REVIEW"}}}'
route "$dir" "GET $ASC/reviewSubmissions/sub-1/items?include=appStoreVersion&limit=50" 200 '{"data":[]}'
route "$dir" "POST $ASC/reviewSubmissionItems" 409 \
    '{"errors":[{"code":"STATE_ERROR.ENTITY_STATE_INVALID","title":"appStoreVersions is not in valid state","detail":"This resource cannot be reviewed","meta":{"associatedErrors":{"/v1/appScreenshotSets/set-1":[{"code":"ENTITY_ERROR.ATTRIBUTE.REQUIRED","detail":"You must upload a screenshot for 6.9-inch iPhone displays."}]}}}]}'
release "$dir" DRY_RUN=false
log="$(cat "$dir/log")"
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$log" "::error::App Store Connect 'POST /reviewSubmissionItems' returned HTTP 409:" 'status' \
    && assert_contains "$log" '::error::  /v1/appScreenshotSets/set-1: ENTITY_ERROR.ATTRIBUTE.REQUIRED: You must upload a screenshot for 6.9-inch iPhone displays.' 'associated error' \
    && pass_case

case_start 'SCHEDULED without a date fails before any request'
dir="$(asc_workspace)"
release "$dir" RELEASE_TYPE=SCHEDULED
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" '::error::release-type SCHEDULED needs scheduled-release-date' 'error' \
    && assert_equals '' "$(requests "$dir")" 'requests' \
    && pass_case

case_start 'a bundle id passed as app-id fails before any request'
dir="$(asc_workspace)"
release "$dir" APP_ID=com.example.app
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" "::error::app-id 'com.example.app' must be the numeric App Store Connect app id" 'error' \
    && assert_equals '' "$(requests "$dir")" 'requests' \
    && pass_case

case_start 'release-type defaults to empty, keeping the version as App Store Connect has it'
assert_equals '' "$(action_input_default "$ACTION" release-type)" 'release-type default' && pass_case

case_start 'a bundle id resolves the numeric app id'
dir="$(asc_workspace)"
new_version_routes "$dir"
route "$dir" "GET $ASC/apps?filter[bundleId]=com.example.app&limit=2" 200 '{"data":[{"id":"6449440933","attributes":{"bundleId":"com.example.app"}}]}'
release "$dir" APP_ID='' BUNDLE_ID=com.example.app
log="$(cat "$dir/log")"
assert_equals 0 "$STEP_STATUS" "exit status (log: $log)" \
    && assert_contains "$(requests "$dir")" "GET $ASC/apps?filter[bundleId]=com.example.app&limit=2" 'lookup' \
    && assert_equals planned "$(step_output "$dir" result)" 'result' \
    && pass_case

case_start 'a bundle id that matches no app, or only a different one, fails closed'
failed=false
for body in '{"data":[]}' '{"data":[{"id":"1","attributes":{"bundleId":"com.example.app.widget"}}]}'; do
    dir="$(asc_workspace)"
    route "$dir" "GET $ASC/apps?filter[bundleId]=com.example.app&limit=2" 200 "$body"
    release "$dir" APP_ID='' BUNDLE_ID=com.example.app
    if ! { assert_equals 1 "$STEP_STATUS" "exit status ($body)" \
        && assert_contains "$(cat "$dir/log")" "::error::no App Store Connect app has bundle id com.example.app" 'error'; }; then
        failed=true
        break
    fi
done
[ "$failed" = true ] || pass_case

case_start 'an app id and a bundle id that disagree fail before any change'
dir="$(asc_workspace)"
base_routes "$dir"
release "$dir" BUNDLE_ID=com.example.other DRY_RUN=false
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" "::error::app 6449440933 has bundle id com.example.app, not com.example.other" 'error' \
    && assert_equals '' "$(mutations "$dir")" 'mutating requests' \
    && pass_case

case_start 'neither app-id nor bundle-id fails before any request'
dir="$(asc_workspace)"
release "$dir" APP_ID=''
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" '::error::pass app-id (numeric) or bundle-id' 'error' \
    && assert_equals '' "$(requests "$dir")" 'requests' \
    && pass_case

case_start 'an empty release type leaves an existing version alone and creates a new one as MANUAL'
dir="$(asc_workspace)"
base_routes "$dir"
route "$dir" "GET $VERSIONS&filter[versionString]=2.35.0" 200 '{"data":[{"id":"ver-1","attributes":{"versionString":"2.35.0","appVersionState":"PREPARE_FOR_SUBMISSION","releaseType":"AFTER_APPROVAL"}}]}'
route "$dir" "GET $ASC/appStoreVersions/ver-1/build" 200 '{"data":null}'
route "$dir" "GET $ASC/appStoreVersions/ver-1/appStoreVersionPhasedRelease" 404 '{"errors":[]}'
route "$dir" "GET $SUBMISSIONS" 200 '{"data":[]}'
release "$dir" RELEASE_TYPE=''
kept="$(cat "$dir/summary")"
dir="$(asc_workspace)"
new_version_routes "$dir"
release "$dir" RELEASE_TYPE=''
log="$(cat "$dir/log")"
assert_equals 0 "$STEP_STATUS" "exit status (log: $log)" \
    && assert_not_contains "$kept" 'Set release type' 'existing version release type' \
    && assert_contains "$kept" 'AFTER_APPROVAL (kept)' 'kept release type reported' \
    && assert_contains "$(cat "$dir/summary")" '| Create App Store version | 2.35.0, MANUAL | would do |' 'new version is MANUAL' \
    && pass_case

case_start 'a missing key file fails closed'
dir="$(asc_workspace)"
release "$dir" ASC_KEY_PATH="$dir/absent.p8"
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" "is not a readable EC private key" 'error' \
    && pass_case

finish_suite
