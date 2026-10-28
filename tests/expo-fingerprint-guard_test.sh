#!/usr/bin/env bash
# expo-fingerprint-guard.yml reads its override label live so that labelling a
# pull request and re-running the job is enough. Callers grant only
# pull-requests: read, so the read must use a route that scope covers: the gh
# stub refuses issues/* routes with a 403, as GitHub does for that token.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

WORKFLOW_YML="$REPO_ROOT/.github/workflows/expo-fingerprint-guard.yml"

label_workspace() {
    workspace=$(new_workflow_workspace "$WORKFLOW_YML" guard 'Read the override label')
    stub "$workspace" gh "$(cat <<'STUB'
[ "$1" = api ] || exit 1
case "$2" in
  */issues/*) echo 'gh: Resource not accessible by integration (HTTP 403)' >&2; exit 1 ;;
  repos/owner/repo/pulls/42)
    [ "${API_FAIL:-false}" = true ] && exit 1
    printf '%s' "$LIVE_LABELS" | tr ',' '\n' ;;
  *) exit 1 ;;
esac
STUB
)"
}
read_label() {
    run_step "$workspace" OVERRIDE_LABEL=native-change-acknowledged PR_NUMBER=42 REPOSITORY=owner/repo \
        GH_TOKEN=token "$@"
}

case_start 'a label added after the run started is read live with pull-requests: read'
label_workspace
read_label LIVE_LABELS='e2e,native-change-acknowledged' PAYLOAD_LABELS='e2e'
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))" \
    && assert_equals true "$(step_output "$workspace" acknowledged)" acknowledged \
    && assert_not_contains "$(cat "$workspace/log")" 'falling back' log; then pass_case; fi

case_start 'a label removed after the run started no longer acknowledges'
label_workspace
read_label LIVE_LABELS='e2e' PAYLOAD_LABELS='e2e,native-change-acknowledged'
assert_equals false "$(step_output "$workspace" acknowledged)" acknowledged && pass_case

case_start 'a label name only containing the override label does not acknowledge'
label_workspace
read_label LIVE_LABELS='not-native-change-acknowledged' PAYLOAD_LABELS=''
assert_equals false "$(step_output "$workspace" acknowledged)" acknowledged && pass_case

case_start 'an API failure falls back to the payload labels and says so'
label_workspace
read_label API_FAIL=true LIVE_LABELS='' PAYLOAD_LABELS='e2e,native-change-acknowledged'
if assert_equals true "$(step_output "$workspace" acknowledged)" acknowledged \
    && assert_contains "$(cat "$workspace/log")" 'falling back' log; then pass_case; fi

finish_suite
