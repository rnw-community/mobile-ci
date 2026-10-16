#!/usr/bin/env bash
# pr-closed-cleanup-reusable.yml's opt-in OTA preview cleanup deletes every
# expo-ota-preview release and tag of the closed pull request, and nothing of
# any other pull request. It talks to the REST API through curl, since a fleet
# runner may have no gh, so the stub below plays the API from fixture files.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

WORKFLOW="$REPO_ROOT/.github/workflows/pr-closed-cleanup-reusable.yml"
JOB='delete-ota-previews'
STEP="Delete this pull request's preview releases and tags"

SHA_A='0123456789abcdef0123456789abcdef01234567'
SHA_B='89abcdef0123456789abcdef0123456789abcdef'

# The stub answers GET releases / matching-refs from $FAKE/releases.json and
# $FAKE/refs.json (one page), records every DELETE in $FAKE/deleted, and
# answers DELETEs with $FAKE_DELETE_STATUS (default 204).
# shellcheck disable=SC2016
CURL_STUB='
method=GET out="" url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    -H|-w) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
path="${url#*/repos/acme/app/}"
if [ "$method" = DELETE ]; then
  printf "%s\n" "$path" >> "$FAKE/deleted"
  printf "{\"message\":\"%s\"}" "${FAKE_DELETE_MESSAGE:-}" > "$out"
  printf "%s" "${FAKE_DELETE_STATUS:-204}"
  exit 0
fi
case "$path" in
  releases\?*page=1) cp "$FAKE/releases.json" "$out"; printf "%s" "${FAKE_LIST_STATUS:-200}" ;;
  git/matching-refs/tags/*page=1) cp "$FAKE/refs.json" "$out"; printf "%s" 200 ;;
  *) printf "[]" > "$out"; printf "%s" 200 ;;
esac
'

setup() {
    workspace="$(new_workflow_workspace "$WORKFLOW" "$JOB" "$STEP")"
    mkdir -p "$workspace/fake"
    : > "$workspace/fake/deleted"
    cat > "$workspace/fake/releases.json" <<JSON
[
  {"id": 1, "tag_name": "ota-apps-mobile-1a2b3c4d-pr-42-${SHA_A}"},
  {"id": 2, "tag_name": "ota-apps-mobile-1a2b3c4d-pr-42-${SHA_B}"},
  {"id": 3, "tag_name": "ota-apps-mobile-1a2b3c4d-pr-421-${SHA_A}"},
  {"id": 4, "tag_name": "ota-apps-mobile-1a2b3c4d-main-5e6f7a8b-${SHA_A}"},
  {"id": 5, "tag_name": "v1.2.3"},
  {"id": 6, "tag_name": "other-apps-mobile-1a2b3c4d-pr-42-${SHA_A}"}
]
JSON
    cat > "$workspace/fake/refs.json" <<JSON
[
  {"ref": "refs/tags/ota-apps-mobile-1a2b3c4d-pr-42-${SHA_A}"},
  {"ref": "refs/tags/ota-apps-mobile-1a2b3c4d-pr-42-${SHA_B}"},
  {"ref": "refs/tags/ota-apps-mobile-1a2b3c4d-pr-4-${SHA_A}"}
]
JSON
    stub "$workspace" curl "$CURL_STUB"
    stub "$workspace" jq "exec $(command -v jq) \"\$@\""
}

cleanup() {
    run_step "$workspace" FAKE="$workspace/fake" GH_TOKEN='token' REPOSITORY='acme/app' \
        TAG_PREFIX='ota' PR_NUMBER='42' GITHUB_API_URL='https://api.github.com' "$@"
}

case_start "deletes exactly the closed PR's preview releases and tags"
setup
cleanup
expected="releases/1
releases/2
git/refs/tags/ota-apps-mobile-1a2b3c4d-pr-42-${SHA_A}
git/refs/tags/ota-apps-mobile-1a2b3c4d-pr-42-${SHA_B}"
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals "$expected" "$(cat "$workspace/fake/deleted")" 'deleted'; then
    pass_case
fi

case_start 'a release or tag already gone (404) is not an error'
setup
cleanup FAKE_DELETE_STATUS=404
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))"; then
    pass_case
fi

case_start 'a tag ref that no longer exists (422) is not an error'
setup
printf '[]' > "$workspace/fake/releases.json"
cleanup FAKE_DELETE_STATUS=422 FAKE_DELETE_MESSAGE='Reference does not exist'
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))"; then
    pass_case
fi

case_start 'a refused delete fails closed'
setup
cleanup FAKE_DELETE_STATUS=403 FAKE_DELETE_MESSAGE='Resource not accessible by integration'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'contents: write' 'error names the missing permission'; then
    pass_case
fi

case_start 'an unreadable release list fails closed'
setup
cleanup FAKE_LIST_STATUS=500
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_equals '' "$(cat "$workspace/fake/deleted")" 'nothing deleted'; then
    pass_case
fi

case_start 'no pull request number fails closed'
setup
cleanup PR_NUMBER=''
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_equals '' "$(cat "$workspace/fake/deleted")" 'nothing deleted'; then
    pass_case
fi

case_start 'a prefix outside [A-Za-z0-9._-] fails closed'
setup
cleanup TAG_PREFIX='ota/*'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_equals '' "$(cat "$workspace/fake/deleted")" 'nothing deleted'; then
    pass_case
fi

case_start 'a runner without curl fails with a clear error'
setup
rm "$workspace/stub-bin/curl" "$workspace/stub-bin/jq"
for tool in bash cat jq mktemp rm; do
    ln -s "$(command -v "$tool")" "$workspace/stub-bin/$tool"
done
run_step "$workspace" PATH="$workspace/stub-bin" FAKE="$workspace/fake" GH_TOKEN='token' \
    REPOSITORY='acme/app' TAG_PREFIX='ota' PR_NUMBER='42'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" "needs 'curl'" 'error message'; then
    pass_case
fi

finish_suite
