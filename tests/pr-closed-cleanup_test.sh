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

# The wait step polls the closed PR's runs until none is active, so the
# preview deletion never races a run that is still publishing. The gh stub
# answers each poll from $FAKE/poll-<n>.json (the poll number counts the
# `status=queued` listing that opens every poll; later statuses answer from the
# same file), records every cancel in $FAKE/cancelled, and fails the listing
# when FAKE_LIST_FAIL is set.
WAIT_STEP="Wait for the closed PR's runs to stop"
# shellcheck disable=SC2016
GH_STUB='
if [ "$1 $2 $3" = "api --method POST" ]; then
  printf "%s\n" "$4" >> "$FAKE/cancelled"
  exit 0
fi
[ -z "${FAKE_LIST_FAIL:-}" ] || { echo "HTTP 502" >&2; exit 1; }
status="" page=1
for arg in "$@"; do
  case "$arg" in
    status=*) status="${arg#status=}" ;;
    page=*) page="${arg#page=}" ;;
  esac
done
if [ "$status" = queued ] && [ "$page" = 1 ]; then
  echo $(( $(cat "$FAKE/polls") + 1 )) > "$FAKE/polls"
fi
poll="$(cat "$FAKE/polls")"
file="$FAKE/poll-${poll}.json"
[ -f "$file" ] || file="$FAKE/poll-last.json"
if [ "$page" = 1 ]; then
  jq --arg status "$status" "{workflow_runs: [.workflow_runs[] | select(.status == \$status)]}" "$file"
else
  echo "{\"workflow_runs\": []}"
fi
'

run_json() {
    # run_json <id> <status> [event] [pr number] [head repo]
    local pr=''
    [ -z "${4:-}" ] || pr="{\"number\": $4}"
    printf '{"id": %s, "status": "%s", "event": "%s", "html_url": "https://github.com/acme/app/actions/runs/%s", "head_repository": {"full_name": "%s"}, "pull_requests": [%s]}' \
        "$1" "$2" "${3:-pull_request}" "$1" "${5:-acme/app}" "$pr"
}

wait_setup() {
    workspace="$(new_workflow_workspace "$WORKFLOW" cancel-queued-runs "$WAIT_STEP")"
    mkdir -p "$workspace/fake"
    : > "$workspace/fake/cancelled"
    : > "$workspace/fake/slept"
    echo 0 > "$workspace/fake/polls"
    echo '{"workflow_runs": []}' > "$workspace/fake/poll-last.json"
    stub "$workspace" gh "$GH_STUB"
    # shellcheck disable=SC2016
    stub "$workspace" sleep 'echo "slept $1" >> "$FAKE/slept"'
}

wait_for_runs() {
    run_step "$workspace" FAKE="$workspace/fake" GH_TOKEN='token' REPOSITORY='acme/app' \
        HEAD_BRANCH='feature' CURRENT_RUN_ID='999' PR_NUMBER='42' \
        WAIT_TIMEOUT_MINUTES='10' POLL_INTERVAL_SECONDS='15' "$@"
}

case_start 'no active run of the closed PR: the wait returns without sleeping'
wait_setup
printf '{"workflow_runs": [%s, %s, %s, %s]}' \
    "$(run_json 999 in_progress pull_request 42)" \
    "$(run_json 7 in_progress pull_request 43)" \
    "$(run_json 8 queued pull_request 42 fork/app)" \
    "$(run_json 9 in_progress push 42)" > "$workspace/fake/poll-last.json"
wait_for_runs
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals '' "$(cat "$workspace/fake/slept")" 'slept' \
    && assert_equals '' "$(cat "$workspace/fake/cancelled")" 'cancelled'; then
    pass_case
fi

case_start 'a run still stopping is polled (and cancelled again) until it completes'
wait_setup
printf '{"workflow_runs": [%s, %s]}' "$(run_json 5 in_progress pull_request 42)" "$(run_json 6 queued pull_request 42)" > "$workspace/fake/poll-1.json"
printf '{"workflow_runs": [%s]}' "$(run_json 5 in_progress pull_request 42)" > "$workspace/fake/poll-2.json"
wait_for_runs
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals "$(printf 'slept 15\nslept 15')" "$(cat "$workspace/fake/slept")" 'slept' \
    && assert_contains "$(cat "$workspace/fake/cancelled")" 'actions/runs/6/cancel' 'queued run cancelled again'; then
    pass_case
fi

case_start 'a run that ignores cancel for two minutes of polls is force-cancelled'
wait_setup
for poll in 1 2 3 4 5 6 7 8 9; do
    printf '{"workflow_runs": [%s]}' "$(run_json 6 queued pull_request 42)" > "$workspace/fake/poll-${poll}.json"
done
wait_for_runs
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals 8 "$(grep -c 'actions/runs/6/cancel$' "$workspace/fake/cancelled")" 'plain cancels before escalating' \
    && assert_equals 1 "$(grep -c 'actions/runs/6/force-cancel$' "$workspace/fake/cancelled")" 'force-cancels' \
    && assert_contains "$(cat "$workspace/log")" 'force-cancel' 'escalation is logged'; then
    pass_case
fi

case_start 'an in-progress run is never force-cancelled, so its teardown steps still run'
wait_setup
for poll in 1 2 3 4 5 6 7 8 9; do
    printf '{"workflow_runs": [%s]}' "$(run_json 5 in_progress pull_request 42)" > "$workspace/fake/poll-${poll}.json"
done
wait_for_runs
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals 9 "$(grep -c 'actions/runs/5/cancel$' "$workspace/fake/cancelled")" 'plain cancels' \
    && assert_not_contains "$(cat "$workspace/fake/cancelled")" 'force-cancel' 'force-cancels'; then
    pass_case
fi

case_start 'a run on the branch that lost its PR association is still waited for'
wait_setup
printf '{"workflow_runs": [%s]}' "$(run_json 5 waiting)" > "$workspace/fake/poll-1.json"
wait_for_runs
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals 'slept 15' "$(cat "$workspace/fake/slept")" 'slept'; then
    pass_case
fi

case_start 'a run still active when the budget runs out fails closed'
wait_setup
printf '{"workflow_runs": [%s]}' "$(run_json 5 in_progress pull_request 42)" > "$workspace/fake/poll-last.json"
wait_for_runs WAIT_TIMEOUT_MINUTES='0'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'actions/runs/5' 'error names the active run'; then
    pass_case
fi

case_start 'an unreadable run list fails closed'
wait_setup
wait_for_runs FAKE_LIST_FAIL=1
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" '::error::' 'error annotation'; then
    pass_case
fi

case_start 'a non-numeric wait budget fails closed'
wait_setup
wait_for_runs WAIT_TIMEOUT_MINUTES='ten'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_equals '0' "$(cat "$workspace/fake/polls")" 'no poll'; then
    pass_case
fi

case_start 'preview deletion waits for the runs to stop, in a group nothing cancels'
if failure="$(WORKFLOW="$WORKFLOW" python3 - <<'PYTHON' 2>&1
import os
import sys

import yaml

workflow = yaml.safe_load(open(os.environ['WORKFLOW'], encoding='utf-8'))
problems = []
concurrency = workflow.get('concurrency') or {}
if 'github.event.pull_request.number' not in str(concurrency.get('group', '')):
    problems.append('workflow concurrency group is not keyed on the pull request')
if concurrency.get('cancel-in-progress', None) is not False:
    problems.append('workflow concurrency must set cancel-in-progress: false')
needs = workflow['jobs']['delete-ota-previews'].get('needs', [])
needs = [needs] if isinstance(needs, str) else needs
if 'cancel-queued-runs' not in needs:
    problems.append('delete-ota-previews does not need cancel-queued-runs')
names = [step.get('name') for step in workflow['jobs']['cancel-queued-runs']['steps']]
if "Wait for the closed PR's runs to stop" not in names:
    problems.append('cancel-queued-runs has no wait step')
if problems:
    sys.exit('; '.join(problems))
PYTHON
)"; then
    pass_case
else
    fail_case "$failure"
fi

finish_suite
