#!/usr/bin/env bash
# rerun-infra-failures re-runs a run's failed jobs only when every failure is
# infrastructure, and only once. Its step runs the real script against
# fixtures answering every API path (CI_METRICS_FIXTURES); POSTs land in
# posts.log, so a case can prove a re-run was or was not requested.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/rerun-infra-failures/action.yml"
STEP='Classify the failures and re-run infra-only runs'

# scenario <run json> <job json lines: id|name|conclusion|annotations>, where
# annotations are separated by ^^ and a warning: or notice: prefix sets the level;
# a runner exit-code line carries the job name as its title, as GitHub sends it
scenario() {
    workspace="$(new_workspace "$ACTION" "$STEP")"
    fixtures="$workspace/fixtures"
    mkdir -p "$fixtures"
    RUN="$1" JOBS="$2" FIXTURES="$fixtures" SCRIPT="$REPO_ROOT/scripts/ci-metrics.py" PYTHONDONTWRITEBYTECODE=1 python3 - <<'PYTHON'
import importlib.util
import json
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location('metrics', os.environ['SCRIPT'])
metrics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metrics)
root = Path(os.environ['FIXTURES'])
put = lambda path, data: (root / f'{metrics.Api._slug(path)}.json').write_text(json.dumps(data))
run = json.loads(os.environ['RUN'])
put('/repos/o/r/actions/runs/7', run)
jobs = []
for line in filter(None, os.environ['JOBS'].splitlines()):
    job_id, name, conclusion, annotation = line.split('|')
    jobs.append({'id': int(job_id), 'name': name, 'conclusion': conclusion})
    notes = [note.split(':', 1) if note.startswith(('warning:', 'notice:')) else ('failure', note) for note in filter(None, annotation.split('^^'))]
    put(f'/repos/o/r/check-runs/{job_id}/annotations', [{'message': text, 'title': 'Build (e2e)' if text.startswith('Process completed') else '', 'annotation_level': level} for level, text in notes])
put(f"/repos/o/r/actions/runs/7/attempts/{run.get('run_attempt', 1)}/jobs?per_page=100&page=1", {'jobs': jobs})
PYTHON
}
classify() {
    run_step "$workspace" GITHUB_ACTION_PATH="$REPO_ROOT/actions/rerun-infra-failures" CI_METRICS_FIXTURES="$fixtures" \
        GH_TOKEN=token REPOSITORY=o/r RUN_ID=7 MAX_ATTEMPTS=1 DRY_RUN=false "$@"
}
posts() {
    cat "$fixtures/posts.log" 2>/dev/null || true
}
FAILED='{"status":"completed","conclusion":"failure","run_attempt":1,"html_url":"https://github.com/o/r/actions/runs/7"}'
LOST='The self-hosted runner lost communication with the server.'

case_start 'a run whose only failures are infra is re-run once'
scenario "$FAILED" "1|iOS Maestro E2E / Maestro shard 0 (e2e)|failure|$LOST
2|Build (e2e)|failure|Process completed with exit code 127.
3|Lint|success|"
classify
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))" \
    && assert_equals rerun "$(step_output "$workspace" decision)" decision \
    && assert_equals 2 "$(step_output "$workspace" infra-jobs)" 'infra jobs' \
    && assert_equals 'POST /repos/o/r/actions/runs/7/rerun-failed-jobs' "$(posts)" 'rerun request' \
    && assert_contains "$(cat "$workspace/summary")" '| Build (e2e) | infra | Process completed with exit code 127. |' summary; then
    pass_case
fi

case_start 'a test failure anywhere in the run means nothing is re-run'
scenario "$FAILED" "1|Maestro shard 0 (e2e)|failure|$LOST
2|Maestro shard 1 (e2e)|failure|Assertion is false: \"Home\" is visible"
classify
if assert_equals test-failure "$(step_output "$workspace" decision)" decision \
    && assert_equals '' "$(posts)" 'rerun request'; then pass_case; fi

case_start 'a job whose infra-looking annotation sits beside a test failure is a test failure'
scenario "$FAILED" "1|Maestro shard 0 (e2e)|failure|$LOST
2|Playwright web E2E|failure|Error: expect(received).toBe(200): request to http://localhost:3000 failed, connection refused^^1 failed^^Process completed with exit code 1."
classify
if assert_equals test-failure "$(step_output "$workspace" decision)" decision \
    && assert_equals '' "$(posts)" 'rerun request'; then pass_case; fi

case_start 'warnings and the bare exit-code line beside an infra cause still allow the retry'
scenario "$FAILED" "1|Build (e2e)|failure|warning:Maestro failed and tolerate-test-failures kept the job green^^No space left on device^^Process completed with exit code 1."
classify
if assert_equals rerun "$(step_output "$workspace" decision)" decision \
    && assert_equals 'POST /repos/o/r/actions/runs/7/rerun-failed-jobs' "$(posts)" 'rerun request'; then pass_case; fi

case_start 'a failed job with no annotation counts as a test failure'
scenario "$FAILED" "1|Maestro shard 0 (e2e)|failure|$LOST
2|Unit tests|failure|"
classify
assert_equals test-failure "$(step_output "$workspace" decision)" decision && pass_case

case_start 'a roll-up job does not block the retry of the jobs it reports'
scenario "$FAILED" "1|Maestro shard 0 (e2e)|timed_out|
2|Required CI|failure|Required jobs did not succeed: ios-maestro"
classify
if assert_equals rerun "$(step_output "$workspace" decision)" decision \
    && assert_equals 'POST /repos/o/r/actions/runs/7/rerun-failed-jobs' "$(posts)" 'rerun request'; then pass_case; fi

case_start 'a run already retried is left alone'
scenario '{"status":"completed","conclusion":"failure","run_attempt":2}' "1|Maestro shard 0 (e2e)|failure|$LOST"
classify
if assert_equals retries-exhausted "$(step_output "$workspace" decision)" decision \
    && assert_equals '' "$(posts)" 'rerun request'; then pass_case; fi

case_start 'a dry run decides but re-runs nothing'
scenario "$FAILED" "1|Maestro shard 0 (e2e)|failure|$LOST"
classify DRY_RUN=true
if assert_equals rerun "$(step_output "$workspace" decision)" decision \
    && assert_equals '' "$(posts)" 'rerun request' \
    && assert_contains "$(cat "$workspace/log")" 'dry run: nothing was re-run' log; then pass_case; fi

case_start 'a successful or unfinished run is reported and left alone'
scenario '{"status":"completed","conclusion":"success","run_attempt":1}' ''
classify
passed="$(step_output "$workspace" decision)"
scenario '{"status":"in_progress","conclusion":null,"run_attempt":1}' ''
classify
if assert_equals nothing-failed "$passed" 'successful run' \
    && assert_equals not-finished "$(step_output "$workspace" decision)" 'unfinished run' \
    && assert_equals '' "$(posts)" 'rerun request'; then pass_case; fi

case_start 'malformed inputs fail closed before any request'
scenario "$FAILED" "1|Maestro shard 0 (e2e)|failure|$LOST"
statuses=''
for override in 'RUN_ID=abc' 'REPOSITORY=bad' 'MAX_ATTEMPTS=0' 'DRY_RUN=yes'; do
    classify "$override"
    statuses="$statuses$STEP_STATUS"
done
if assert_equals 1111 "$statuses" statuses && assert_equals '' "$(posts)" 'rerun request'; then pass_case; fi

case_start 'the action re-runs with the classifier the metrics report uses'
assert_contains "$(cat "$REPO_ROOT/actions/rerun-infra-failures/rerun.py")" "'scripts' / 'ci-metrics.py'" 'shared classifier' && pass_case

finish_suite
