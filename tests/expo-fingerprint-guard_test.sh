#!/usr/bin/env bash
# expo-fingerprint-guard.yml reads its override label live so that labelling a
# pull request and re-running the job is enough. The guard's Linux pools do
# not all ship gh (the linux-portable arm64 guests have none), so the read
# runs on the Node the job already set up. These cases run that Node code
# against a local HTTP server standing in for the pulls API.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

WORKFLOW_YML="$REPO_ROOT/.github/workflows/expo-fingerprint-guard.yml"

api_root="$(mktemp -d "${TMPDIR:-/tmp}/guard-api-XXXXXX")"
mkdir -p "$api_root/repos/owner/repo/pulls"
port_file="$api_root/port"
python3 -I - "$api_root" "$port_file" <<'PYTHON' &
import http.server
import os
import sys

root, port_file = sys.argv[1], sys.argv[2]

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=root, **kwargs)

    def do_GET(self):
        if self.headers.get('Authorization') != 'Bearer token':
            self.send_error(401)
            return
        super().do_GET()

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

live_labels() {
    printf '{"number":42,"labels":[%s]}' "$1" > "$api_root/repos/owner/repo/pulls/42"
}
read_label() {
    workspace=$(new_workflow_workspace "$WORKFLOW_YML" guard 'Read the override label')
    run_step "$workspace" OVERRIDE_LABEL=native-change-acknowledged PR_NUMBER=42 REPOSITORY=owner/repo \
        GH_TOKEN=token GITHUB_API_URL="$api_url" PATH="$workspace/stub-bin:/usr/bin:/bin:$(dirname "$(command -v node)")" "$@"
}

case_start 'a label added after the run started is read live, without gh on the runner'
live_labels '{"name":"e2e"},{"name":"native-change-acknowledged"}'
read_label PAYLOAD_LABELS='e2e'
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))" \
    && assert_equals true "$(step_output "$workspace" acknowledged)" acknowledged \
    && assert_not_contains "$(cat "$workspace/log")" 'falling back' log; then pass_case; fi

case_start 'a label removed after the run started no longer acknowledges'
live_labels '{"name":"e2e"}'
read_label PAYLOAD_LABELS='e2e,native-change-acknowledged'
assert_equals false "$(step_output "$workspace" acknowledged)" acknowledged && pass_case

case_start 'a label name only containing the override label does not acknowledge'
live_labels '{"name":"not-native-change-acknowledged"}'
read_label PAYLOAD_LABELS=''
assert_equals false "$(step_output "$workspace" acknowledged)" acknowledged && pass_case

case_start 'an API failure falls back to the payload labels and names the error'
read_label PAYLOAD_LABELS='e2e,native-change-acknowledged' GH_TOKEN=wrong
if assert_equals true "$(step_output "$workspace" acknowledged)" acknowledged \
    && assert_contains "$(cat "$workspace/log")" 'falling back' log \
    && assert_contains "$(cat "$workspace/log")" 'HTTP 401' 'error reason'; then pass_case; fi

finish_suite
