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

case_start "an action's own 'Infrastructure failure:' annotation is infra"
scenario "$FAILED" "1|Maestro shard 0 (e2e)|failure|Infrastructure failure: emulator 'emulator-5554' is gone (adb get-state: 'no answer') after 'a.flow.yaml', so shard 0 stops; its 2 remaining flow(s) were not run.^^Process completed with exit code 1."
classify
if assert_equals rerun "$(step_output "$workspace" decision)" decision; then pass_case; fi

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

case_start 'a run that concluded timed_out is classified like a failed one'
scenario '{"status":"completed","conclusion":"timed_out","run_attempt":1}' "1|Maestro shard 0 (e2e)|timed_out|"
classify
if assert_equals rerun "$(step_output "$workspace" decision)" decision \
    && assert_equals 'POST /repos/o/r/actions/runs/7/rerun-failed-jobs' "$(posts)" 'rerun request'; then pass_case; fi

CANCELLED='{"status":"completed","conclusion":"cancelled","run_attempt":1}'
TIMEOUT='The job has exceeded the maximum execution time of 5m0s'
USER_CANCEL='The operation was canceled.'

# budgie-at/budgie run 41624461881: its annotations, verbatim.
case_start 'a run a job timeout left cancelled is re-run: the lost checkout beside the timeout is infra too'
scenario "$CANCELLED" "1|Lint workflows|cancelled|$TIMEOUT^^fetch-pack: invalid index-pack output^^early EOF^^6788 bytes of body are still expected^^RPC failed; curl 56 Recv failure: Connection reset by peer
2|Required CI|failure|Process completed with exit code 1.^^Required jobs did not succeed: lint-workflows
3|Unit tests|success|"
classify
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))" \
    && assert_equals rerun "$(step_output "$workspace" decision)" decision \
    && assert_equals 1 "$(step_output "$workspace" infra-jobs)" 'infra jobs' \
    && assert_equals 'POST /repos/o/r/actions/runs/7/rerun-failed-jobs' "$(posts)" 'rerun request'; then pass_case; fi

case_start 'a run a user or concurrency cancelled is left alone'
scenario "$CANCELLED" "1|Build (e2e)|cancelled|$USER_CANCEL
2|Lint|cancelled|"
classify
if assert_equals nothing-failed "$(step_output "$workspace" decision)" decision \
    && assert_equals '' "$(posts)" 'rerun request'; then pass_case; fi

case_start 'a user-cancelled run is left alone even beside an infra failure or a roll-up: nobody asked to run it again'
scenario "$CANCELLED" "1|Build (e2e)|cancelled|$USER_CANCEL
2|Lint|failure|$LOST
3|Required CI|failure|Required jobs did not succeed: lint"
classify
if assert_equals nothing-failed "$(step_output "$workspace" decision)" decision \
    && assert_equals '' "$(posts)" 'rerun request'; then pass_case; fi

case_start 'a timeout next to a test failure is a test failure, in another job or in its own annotations'
scenario "$CANCELLED" "1|Lint|cancelled|$TIMEOUT
2|Unit tests|failure|Assertion is false: \"Home\" is visible"
classify
other_job="$(step_output "$workspace" decision)"
scenario "$CANCELLED" "1|Unit tests|cancelled|$TIMEOUT^^Assertion is false: \"Home\" is visible"
classify
if assert_equals test-failure "$other_job" 'test failure in another job' \
    && assert_equals test-failure "$(step_output "$workspace" decision)" 'test failure in the same job' \
    && assert_equals '' "$(posts)" 'rerun request'; then pass_case; fi

case_start 'a failed run ignores the jobs its own failure cancelled, but counts one that timed out'
scenario "$FAILED" "1|Maestro shard 0 (e2e)|failure|$LOST
2|Maestro shard 1 (e2e)|cancelled|$USER_CANCEL
3|Maestro shard 2 (e2e)|cancelled|$TIMEOUT"
classify
if assert_equals rerun "$(step_output "$workspace" decision)" decision \
    && assert_equals 2 "$(step_output "$workspace" infra-jobs)" 'infra jobs'; then pass_case; fi

case_start 'a timed-out run already retried is left alone'
scenario '{"status":"completed","conclusion":"cancelled","run_attempt":2}' "1|Lint workflows|cancelled|$TIMEOUT"
classify
if assert_equals retries-exhausted "$(step_output "$workspace" decision)" decision \
    && assert_equals '' "$(posts)" 'rerun request'; then pass_case; fi

case_start "build-ios-app's CocoaPods null-byte annotation is infra"
scenario "$FAILED" "1|Build (e2e)|failure|Infrastructure failure: pod install failed twice with CocoaPods' intermittent 'path name contains null byte' (CocoaPods/CocoaPods#12798).^^Process completed with exit code 1."
classify
assert_equals rerun "$(step_output "$workspace" decision)" decision && pass_case

# budgie-at/budgie run 41799163541 (decided test-failure by retry run 41805197648): its annotations, with what
# e2e-suite now says about that run: an exit 3, no report and no test executed.
case_start 'an e2e run that ended in an infrastructure error, with no report and no tests, is re-run'
suite="$(new_workspace "$REPO_ROOT/actions/e2e-suite/action.yml" 'Run the e2e suite')"
stub "$suite" curl 'exit 7'
mkdir -p "$suite/work/Base.app"
run_step "$suite" E2E_PLATFORM=ios E2E_COMMAND='exit 3' E2E_APP_PATH="$suite/work/Base.app" E2E_WORKERS=1 E2E_SHADOW=false SIMLOCK_URL=https://farm.invalid SIMLOCK_TOKEN=t
e2e_annotations="$(sed -n 's/^::error:://p' "$suite/log")"
scenario "$FAILED" "1|iOS E2E / E2E suite (e2e)|failure|notice:The farm has 5 free ios devices; running 5 workers instead of 10.^^$e2e_annotations^^Process completed with exit code 3.
2|iOS E2E / iOS Maestro E2E result|failure|Process completed with exit code 1.^^Required jobs did not succeed: e2e suite (result: failure).
3|Required CI|failure|Process completed with exit code 1.^^Required jobs did not succeed: ios-maestro"
classify
if assert_equals rerun "$(step_output "$workspace" decision)" decision \
    && assert_equals 1 "$(step_output "$workspace" infra-jobs)" 'infra jobs' \
    && assert_equals 'POST /repos/o/r/actions/runs/7/rerun-failed-jobs' "$(posts)" 'rerun request'; then pass_case; fi

case_start 'an e2e run whose tests failed stays a test failure'
suite="$(new_workspace "$REPO_ROOT/actions/e2e-suite/action.yml" 'Run the e2e suite')"
stub "$suite" curl 'exit 7'
mkdir -p "$suite/work/Base.app"
run_step "$suite" E2E_PLATFORM=ios E2E_COMMAND="mkdir -p .e2e; printf '%s' '{\"run\":{\"status\":\"failed\",\"errors\":[],\"summary\":{\"executed\":3,\"failed\":1}}}' > .e2e/report.json; exit 1" E2E_APP_PATH="$suite/work/Base.app" E2E_WORKERS=1 E2E_SHADOW=false SIMLOCK_URL=https://farm.invalid SIMLOCK_TOKEN=t
e2e_annotations="$(sed -n 's/^::error:://p' "$suite/log")"
scenario "$FAILED" "1|iOS E2E / E2E suite (e2e)|failure|$e2e_annotations^^Process completed with exit code 1."
classify
if assert_equals test-failure "$(step_output "$workspace" decision)" decision \
    && assert_equals '' "$(posts)" 'rerun request'; then pass_case; fi

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
