#!/usr/bin/env bash
# maestro-flow-timings (#267): fetch reads the newest default-branch timings
# artifact through the Actions API, select hands one target's timings to a
# shard, record folds a run's shard records into a new aggregate. A local
# HTTP server stands in for the API and for the blob storage its artifact
# download redirects to, which must not receive the GitHub token.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/maestro-flow-timings/action.yml"

api_root="$(mktemp -d "${TMPDIR:-/tmp}/timings-api-XXXXXX")"
port_file="$api_root/port"
python3 -I - "$api_root" "$port_file" <<'PYTHON' &
import http.server
import os
import sys

root, port_file = sys.argv[1], sys.argv[2]

class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, code, body=b'', headers=()):
        self.send_response(code)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split('?')[0]
        if path.startswith('/blob/'):
            if self.headers.get('Authorization'):
                self.reply(400, b'blob storage refuses a GitHub token')
                return
            self.reply(200, open(os.path.join(root, path[len('/blob/'):] + '.zip'), 'rb').read())
            return
        if self.headers.get('Authorization') != 'Bearer token':
            self.reply(401)
            return
        if path == '/repos/o/r/actions/artifacts':
            self.reply(200, open(os.path.join(root, 'artifacts.json'), 'rb').read())
        elif path.startswith('/zip/'):
            self.reply(302, headers=[('Location', f'http://{self.headers["Host"]}/blob/{path[len("/zip/"):]}')])
        else:
            self.reply(404)

    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
with open(port_file + '.tmp', 'w') as handle:
    handle.write(str(server.server_address[1]))
os.rename(port_file + '.tmp', port_file)
server.serve_forever()
PYTHON
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null; rm -rf "$api_root"' EXIT
for _ in $(seq 1 100); do [ -f "$port_file" ] && break; sleep 0.1; done
api_url="http://127.0.0.1:$(cat "$port_file")"

# artifact <id> <timings json>: a downloadable flow-timings.json artifact.
artifact() {
    ID="$1" BODY="$2" ROOT="$api_root" python3 -I -c '
import os, zipfile
with zipfile.ZipFile(os.path.join(os.environ["ROOT"], os.environ["ID"] + ".zip"), "w") as archive:
    archive.writestr("flow-timings.json", os.environ["BODY"])'
}
listing() {
    printf '{"artifacts": [%s]}' "$1" > "$api_root/artifacts.json"
}
entry() {
    printf '{"id": %s, "expired": %s, "archive_download_url": "%s/zip/%s", "workflow_run": {"id": 9, "head_branch": "%s"}}' "$1" "$2" "$api_url" "$1" "$3"
}
fetch() {
    workspace="$(new_workspace "$ACTION" 'Fetch the recorded flow timings')"
    run_step "$workspace" GH_TOKEN=token GITHUB_API_URL="$api_url" GITHUB_ACTION_PATH="$REPO_ROOT/actions/maestro-flow-timings" \
        REPOSITORY=o/r ARTIFACT_NAME=maestro-flow-timings-ios BRANCH=main "$@"
}

case_start 'fetch reads the newest unexpired default-branch artifact, without the token on blob storage'
artifact 1 '{"version": 1, "targets": {"app": {"old.flow.yaml": 1}}}'
artifact 2 '{"version": 1, "targets": {"app": {"a.flow.yaml": 42}}}'
artifact 3 '{"version": 1, "targets": {"app": {"branch.flow.yaml": 7}}}'
listing "$(entry 3 false feature),$(entry 4 true main),$(entry 2 false main),$(entry 1 false main)"
fetch
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))" \
    && assert_equals '{"targets": {"app": {"a.flow.yaml": 42}}, "version": 1}' "$(step_output "$workspace" timings)" timings; then
    pass_case
fi

case_start 'fetch with no recorded artifact yet prints empty timings and succeeds'
listing "$(entry 3 false feature)"
fetch
if assert_equals 0 "$STEP_STATUS" status \
    && assert_equals '{"version": 1, "targets": {}}' "$(step_output "$workspace" timings)" timings; then
    pass_case
fi

case_start 'fetch warns and prints empty timings when the API refuses the token'
listing "$(entry 2 false main)"
fetch GH_TOKEN=wrong
if assert_equals 0 "$STEP_STATUS" status \
    && assert_equals '{"version": 1, "targets": {}}' "$(step_output "$workspace" timings)" timings \
    && assert_contains "$(cat "$workspace/log")" '::warning::could not read the recorded flow timings' log; then
    pass_case
fi

case_start 'a malformed API body never fails fetch, and an artifact without an id is still read'
statuses=''
for body in '[1, 2]' '{"artifacts": ["not an object"]}' '{"artifacts": [{"expired": false, "archive_download_url": "'"$api_url"'/zip/2", "workflow_run": {"head_branch": "main"}}]}'; do
    printf '%s' "$body" > "$api_root/artifacts.json"
    fetch
    statuses="$statuses$STEP_STATUS$( (step_output "$workspace" timings 2>/dev/null || true) | grep -c '"targets": {}' || true)"
done
assert_equals 010100 "$statuses" 'per body: status, then 1 when the timings are empty' && pass_case

case_start 'select writes one target as a shard-timings-file, and an unknown target as empty timings'
workspace="$(new_workspace "$ACTION" "Write the target's shard timings file")"
run_step "$workspace" GITHUB_ACTION_PATH="$REPO_ROOT/actions/maestro-flow-timings" GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 \
    FLOW_TIMINGS='{"version": 1, "targets": {"app": {"a.flow.yaml": 42}}}' TARGET=app
app="$(cat "$(step_output "$workspace" file)")"
run_step "$workspace" GITHUB_ACTION_PATH="$REPO_ROOT/actions/maestro-flow-timings" GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 \
    FLOW_TIMINGS='{"version": 1, "targets": {}}' TARGET=other
if assert_equals '{"version": 1, "flows": {"a.flow.yaml": 42}}' "$app" 'app timings' \
    && assert_equals '{"version": 1, "flows": {}}' "$(cat "$(step_output "$workspace" file | tail -n 1)")" 'other timings'; then
    pass_case
fi

record() {
    workspace="$(new_workspace "$ACTION" "Fold this run's shard records into the timings")"
    mkdir -p "$workspace/records"
    run_step "$workspace" GITHUB_ACTION_PATH="$REPO_ROOT/actions/maestro-flow-timings" GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 \
        RECORDS_DIR="$workspace/records" ARTIFACT_PREFIX=maestro-flow-timings-ios- ARTIFACT_NAME=maestro-flow-timings-ios "$@"
}
shard_record() {
    mkdir -p "$workspace/records/$1"
    printf '%b' "$2" > "$workspace/records/$1/flow-timings.tsv"
}

case_start 'record folds every shard of every target into the previous timings'
record
shard_record maestro-flow-timings-ios-app-shard-0 'a.flow.yaml\t200\tpassed\n'
shard_record maestro-flow-timings-ios-app-shard-1 'b.flow.yaml\t30\tpassed\nc.flow.yaml\t9\tfailed\n'
shard_record maestro-flow-timings-ios-my-app-2-shard-0 'x.flow.yaml\t5\tpassed\n'
run_step "$workspace" GITHUB_ACTION_PATH="$REPO_ROOT/actions/maestro-flow-timings" GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 \
    RECORDS_DIR="$workspace/records" ARTIFACT_PREFIX=maestro-flow-timings-ios- ARTIFACT_NAME=maestro-flow-timings-ios \
    FLOW_TIMINGS='{"version": 1, "targets": {"app": {"a.flow.yaml": 100}, "gone": {"z.flow.yaml": 1}}}'
recorded="$(python3 -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1] + "/flow-timings.json"))["targets"], sort_keys=True))' "$(step_output "$workspace" dir)")"
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))" \
    && assert_equals '{"app": {"a.flow.yaml": 130.0, "b.flow.yaml": 30.0}, "gone": {"z.flow.yaml": 1}, "my-app-2": {"x.flow.yaml": 5.0}}' "$recorded" 'recorded timings'; then
    pass_case
fi

case_start 'record with no shard record fails rather than publish timings nothing measured'
record FLOW_TIMINGS=''
if assert_equals 1 "$STEP_STATUS" status \
    && assert_contains "$(cat "$workspace/log")" 'holds a flow-timings.tsv' log; then
    pass_case
fi

case_start 'an unknown mode fails closed'
workspace="$(new_workspace "$ACTION" 'Validate the mode and tooling')"
run_step "$workspace" MODE=publish
assert_equals 1 "$STEP_STATUS" status && pass_case

finish_suite
