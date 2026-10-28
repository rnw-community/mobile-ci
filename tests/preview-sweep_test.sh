#!/usr/bin/env bash
# preview-sweep-reusable.yml deletes, on a schedule, the expo-ota-preview
# releases pr-closed-cleanup missed: every preview of a closed pull request and
# every branch preview older than max-age-days. It never touches an open pull
# request's previews, anything newer than the grace period, or anything that
# is not a preview tag, deletes at most max-deletions per run, and in a dry run
# deletes nothing at all. The curl stub below plays the REST API from fixtures.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

WORKFLOW="$REPO_ROOT/.github/workflows/preview-sweep-reusable.yml"
JOB='sweep'
STEP='Delete stale preview releases'

SHA='0123456789abcdef0123456789abcdef01234567'
NOW='1792281600' # 2026-10-18T00:00:00Z

# GET releases answers page 1 from $FAKE/releases.json; GET pulls/<n> answers
# from $FAKE/pull-<n>.json with HTTP 200, or 404 when that file is absent;
# every DELETE is recorded in $FAKE/deleted and answered 204.
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
  printf "{}" > "$out"
  printf "204"
  exit 0
fi
case "$path" in
  releases\?*page=1) cp "$FAKE/releases.json" "$out"; printf "%s" "${FAKE_LIST_STATUS:-200}" ;;
  releases\?*) printf "[]" > "$out"; printf 200 ;;
  pulls/*)
    number="${path#pulls/}"
    if [ -n "${FAKE_PULL_STATUS:-}" ]; then printf "{}" > "$out"; printf "%s" "$FAKE_PULL_STATUS"
    elif [ -f "$FAKE/pull-${number}.json" ]; then cp "$FAKE/pull-${number}.json" "$out"; printf 200
    else printf "{\"message\":\"Not Found\"}" > "$out"; printf 404; fi ;;
  *) printf "{}" > "$out"; printf 404 ;;
esac
'

setup() {
    workspace="$(new_workflow_workspace "$WORKFLOW" "$JOB" "$STEP")"
    mkdir -p "$workspace/fake"
    : > "$workspace/fake/deleted"
    # Oldest first in the expected deletion order: 4, 1, 6.
    cat > "$workspace/fake/releases.json" <<JSON
[
  {"id": 1, "tag_name": "ota-apps-mobile-1a2b3c4d-pr-42-${SHA}", "created_at": "2026-10-10T00:00:00Z"},
  {"id": 2, "tag_name": "ota-apps-mobile-1a2b3c4d-pr-43-${SHA}", "created_at": "2026-08-01T00:00:00Z"},
  {"id": 3, "tag_name": "ota-apps-mobile-1a2b3c4d-pr-44-${SHA}", "created_at": "2026-10-17T18:00:00Z"},
  {"id": 4, "tag_name": "ota-apps-mobile-1a2b3c4d-main-5e6f7a8b-${SHA}", "created_at": "2026-09-01T00:00:00Z"},
  {"id": 5, "tag_name": "ota-apps-mobile-1a2b3c4d-feature-0a0b0c0d-${SHA}", "created_at": "2026-10-15T00:00:00Z"},
  {"id": 6, "tag_name": "ota-apps-mobile-1a2b3c4d-pr-45-${SHA}", "created_at": "2026-10-12T00:00:00Z"},
  {"id": 7, "tag_name": "v1.2.3", "created_at": "2025-01-01T00:00:00Z"},
  {"id": 8, "tag_name": "dev-ios-12", "created_at": "2025-01-01T00:00:00Z"},
  {"id": 9, "tag_name": "ota-apps-mobile-1a2b3c4d-pr-46-${SHA}", "created_at": "2026-09-01T00:00:00Z"}
]
JSON
    echo '{"number": 42, "state": "closed"}' > "$workspace/fake/pull-42.json"
    echo '{"number": 43, "state": "open"}' > "$workspace/fake/pull-43.json"
    echo '{"number": 44, "state": "closed"}' > "$workspace/fake/pull-44.json"
    echo '{"number": 45, "state": "closed"}' > "$workspace/fake/pull-45.json"
    stub "$workspace" curl "$CURL_STUB"
    stub "$workspace" jq "exec $(command -v jq) \"\$@\""
    stub "$workspace" date "if [ \"\$*\" = '-u +%s' ]; then echo $NOW; else exec $(command -v date) \"\$@\"; fi"
}

sweep() {
    run_step "$workspace" FAKE="$workspace/fake" GH_TOKEN='token' REPOSITORY='acme/app' \
        TAG_PREFIX='ota' DRY_RUN='false' MAX_AGE_DAYS='30' GRACE_PERIOD_HOURS='24' \
        MAX_DELETIONS='50' GITHUB_API_URL='https://api.github.com' "$@"
}

case_start 'deletes closed-PR previews and expired branch previews, oldest first'
setup
sweep
expected="releases/4
git/refs/tags/ota-apps-mobile-1a2b3c4d-main-5e6f7a8b-${SHA}
releases/1
git/refs/tags/ota-apps-mobile-1a2b3c4d-pr-42-${SHA}
releases/6
git/refs/tags/ota-apps-mobile-1a2b3c4d-pr-45-${SHA}"
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals "$expected" "$(cat "$workspace/fake/deleted")" 'deleted' \
    && assert_contains "$(cat "$workspace/log")" 'pull request #43 is open' 'open PR skipped' \
    && assert_contains "$(cat "$workspace/log")" 'newer than the 24-hour grace period' 'grace period' \
    && assert_contains "$(cat "$workspace/log")" '::warning::' 'unknown PR warned'; then
    pass_case
fi

case_start 'a dry run deletes nothing and reports what it would delete'
setup
sweep DRY_RUN='true'
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals '' "$(cat "$workspace/fake/deleted")" 'deleted' \
    && assert_contains "$(cat "$workspace/log")" "Would delete ota-apps-mobile-1a2b3c4d-pr-42-${SHA}" 'dry-run log' \
    && assert_contains "$(cat "$workspace/summary")" 'dry run' 'summary'; then
    pass_case
fi

case_start 'max-deletions caps the run, oldest first'
setup
sweep MAX_DELETIONS='1'
expected="releases/4
git/refs/tags/ota-apps-mobile-1a2b3c4d-main-5e6f7a8b-${SHA}"
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals "$expected" "$(cat "$workspace/fake/deleted")" 'deleted' \
    && assert_contains "$(cat "$workspace/log")" 'max-deletions' 'cap reported'; then
    pass_case
fi

case_start 'an unreadable pull request fails closed before deleting it'
setup
printf '[{"id": 1, "tag_name": "ota-apps-mobile-1a2b3c4d-pr-42-%s", "created_at": "2026-10-10T00:00:00Z"}]' "$SHA" > "$workspace/fake/releases.json"
sweep FAKE_PULL_STATUS=500
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_equals '' "$(cat "$workspace/fake/deleted")" 'nothing deleted'; then
    pass_case
fi

case_start 'an unreadable release list fails closed'
setup
sweep FAKE_LIST_STATUS=403
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_equals '' "$(cat "$workspace/fake/deleted")" 'nothing deleted'; then
    pass_case
fi

for bad in 'DRY_RUN=maybe' 'MAX_AGE_DAYS=ten' 'GRACE_PERIOD_HOURS=-1' 'MAX_DELETIONS=0' 'TAG_PREFIX=ota/*'; do
    case_start "invalid input ${bad} fails closed"
    setup
    sweep "$bad"
    if assert_equals 1 "$STEP_STATUS" 'step status' \
        && assert_equals '' "$(cat "$workspace/fake/deleted")" 'nothing deleted'; then
        pass_case
    fi
done

case_start 'the sweep defaults to a dry run in a group nothing cancels'
if failure="$(WORKFLOW="$WORKFLOW" python3 - <<'PYTHON' 2>&1
import os
import sys

import yaml

workflow = yaml.safe_load(open(os.environ['WORKFLOW'], encoding='utf-8'))
inputs = workflow[True]['workflow_call']['inputs']
problems = []
if inputs['dry-run'].get('default') is not True:
    problems.append('dry-run must default to true')
if (workflow.get('concurrency') or {}).get('cancel-in-progress', None) is not False:
    problems.append('workflow concurrency must set cancel-in-progress: false')
if problems:
    sys.exit('; '.join(problems))
PYTHON
)"; then
    pass_case
else
    fail_case "$failure"
fi

finish_suite
