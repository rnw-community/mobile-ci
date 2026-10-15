#!/usr/bin/env bash
# asc-dedupe-screenshots decides whether a missing App Store version is a
# failure or a no-op, and which App Store Connect filter selects that version.
# Its step runs here with a real openssl-signed JWT and real jq against a
# stubbed curl that serves canned App Store Connect responses by URL, so the
# request the step builds and the outputs it writes are what gets tested.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/asc-dedupe-screenshots/action.yml"
STEP='Deduplicate App Store Connect screenshots'
ASC='https://api.appstoreconnect.apple.com/v1'

stub_curl() {
    local dir="$1"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" curl '
method=GET out="" url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -X) method="$2"; shift 2 ;;
        -o) out="$2"; shift 2 ;;
        -H|-w|--max-time) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
printf "%s %s\n" "$method" "$url" >> "$CURL_LOG"
if [ "$method" = DELETE ]; then
    : > "$out"
    printf 204
    exit 0
fi
case "$url" in
    */apps\?*) body="{\"data\":[{\"id\":\"app-1\"}]}" ;;
    */apps/app-1/appStoreVersions\?*) body="$ASC_VERSIONS" ;;
    */appStoreVersions/ver-1/appStoreVersionLocalizations)
        body="{\"data\":[{\"id\":\"loc-1\",\"attributes\":{\"locale\":\"en-US\"}}]}" ;;
    */appStoreVersionLocalizations/loc-1/appScreenshotSets)
        body="{\"data\":[{\"id\":\"set-1\",\"attributes\":{\"screenshotDisplayType\":\"APP_IPHONE_67\"}}]}" ;;
    */appScreenshotSets/set-1/appScreenshots)
        body="{\"data\":[{\"id\":\"shot-1\",\"attributes\":{\"fileName\":\"home.png\",\"uploadedDate\":\"2026-01-01T00:00:00Z\"}},{\"id\":\"shot-2\",\"attributes\":{\"fileName\":\"home.png\",\"uploadedDate\":\"2026-01-02T00:00:00Z\"}}],\"links\":{}}" ;;
    *) printf "%s" "{}" > "$out"; printf 404; exit 0 ;;
esac
printf "%s" "$body" > "$out"
printf 200'
}

dedupe_workspace() {
    local dir
    dir="$(new_workspace "$ACTION" "$STEP")"
    stub_curl "$dir"
    : > "$dir/curl-log"
    openssl ecparam -name prime256v1 -genkey -noout -out "$dir/key.p8" 2>/dev/null
    printf '%s\n' "$dir"
}

dedupe() {
    local dir="$1" versions="$2"
    shift 2
    run_step "$dir" \
        CURL_LOG="$dir/curl-log" \
        ASC_VERSIONS="$versions" \
        APP_ID='com.example.app' \
        ASC_KEY_PATH="$dir/key.p8" \
        ASC_KEY_ID='ABC123DEFG' \
        ASC_ISSUER_ID='69a6de70-03db-47e3-e053-5b8c7c11a4d1' \
        VERSION_STATE='PREPARE_FOR_SUBMISSION' \
        FAIL_ON_DUPLICATES='true' \
        MISSING_VERSION='error' \
        "$@"
}

NO_VERSIONS='{"data":[]}'
ONE_VERSION='{"data":[{"id":"ver-1"}]}'

case_start 'missing-version defaults to error'
default="$(action_input_default "$ACTION" missing-version 2>&1 || true)"
if assert_equals 'error' "$default" 'missing-version default'; then
    pass_case
fi

case_start 'a missing version fails the step under the default'
dir="$(dedupe_workspace)"
dedupe "$dir" "$NO_VERSIONS"
log="$(cat "$dir/log")"
if assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$log" "::error::no app store version in state 'PREPARE_FOR_SUBMISSION' found for 'com.example.app'; nothing to dedupe." 'error' \
    && assert_equals '' "$(cat "$dir/outputs")" 'outputs'; then
    pass_case
fi

case_start 'a missing version is a zero-count notice under missing-version: skip'
dir="$(dedupe_workspace)"
dedupe "$dir" "$NO_VERSIONS" MISSING_VERSION='skip'
log="$(cat "$dir/log")"
if assert_equals 0 "$STEP_STATUS" "exit status (log: $log)" \
    && assert_contains "$log" "::notice::no app store version in state 'PREPARE_FOR_SUBMISSION'" 'notice' \
    && assert_not_contains "$log" '::error::' 'error annotation' \
    && assert_equals 0 "$(step_output "$dir" removed-count)" 'removed-count' \
    && assert_equals 0 "$(step_output "$dir" undeletable-count)" 'undeletable-count'; then
    pass_case
fi

case_start 'an unknown missing-version fails closed before any request'
dir="$(dedupe_workspace)"
dedupe "$dir" "$NO_VERSIONS" MISSING_VERSION='ignore'
log="$(cat "$dir/log")"
if assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$log" "::error::missing-version must be 'error' or 'skip'" 'error' \
    && assert_equals '' "$(cat "$dir/curl-log")" 'requests made'; then
    pass_case
fi

case_start 'versions are selected by the appVersionState filter'
dir="$(dedupe_workspace)"
dedupe "$dir" "$NO_VERSIONS" MISSING_VERSION='skip'
requests="$(cat "$dir/curl-log")"
if assert_contains "$requests" "GET $ASC/apps/app-1/appStoreVersions?filter%5BappVersionState%5D=PREPARE_FOR_SUBMISSION" 'versions request' \
    && assert_not_contains "$requests" 'appStoreState' 'deprecated filter'; then
    pass_case
fi

case_start 'the legacy READY_FOR_SALE state is translated to READY_FOR_DISTRIBUTION'
dir="$(dedupe_workspace)"
dedupe "$dir" "$NO_VERSIONS" MISSING_VERSION='skip' VERSION_STATE='READY_FOR_SALE'
log="$(cat "$dir/log")"
if assert_equals 0 "$STEP_STATUS" "exit status (log: $log)" \
    && assert_contains "$(cat "$dir/curl-log")" 'filter%5BappVersionState%5D=READY_FOR_DISTRIBUTION' 'versions request' \
    && assert_contains "$log" '::warning::version-state READY_FOR_SALE' 'deprecation warning'; then
    pass_case
fi

case_start 'a legacy state with no appVersionState equivalent fails closed'
dir="$(dedupe_workspace)"
dedupe "$dir" "$NO_VERSIONS" VERSION_STATE='REMOVED_FROM_SALE'
log="$(cat "$dir/log")"
if assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$log" "::error::version-state 'REMOVED_FROM_SALE' is not an App Store Connect AppVersionState" 'error' \
    && assert_equals '' "$(cat "$dir/curl-log")" 'requests made'; then
    pass_case
fi

case_start 'a found version is still deduped, keeping the oldest copy'
dir="$(dedupe_workspace)"
dedupe "$dir" "$ONE_VERSION" FAIL_ON_DUPLICATES='false' MISSING_VERSION='skip'
log="$(cat "$dir/log")"
if assert_equals 0 "$STEP_STATUS" "exit status (log: $log)" \
    && assert_contains "$(cat "$dir/curl-log")" "DELETE $ASC/appScreenshots/shot-2" 'delete request' \
    && assert_not_contains "$(cat "$dir/curl-log")" 'appScreenshots/shot-1' 'oldest copy kept' \
    && assert_equals 1 "$(step_output "$dir" removed-count)" 'removed-count' \
    && assert_equals 0 "$(step_output "$dir" undeletable-count)" 'undeletable-count'; then
    pass_case
fi

finish_suite
