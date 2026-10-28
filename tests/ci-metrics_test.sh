#!/usr/bin/env bash
# scripts/ci-metrics.py computes the #272 report from the Actions API. These
# cases answer every API path from fixtures (CI_METRICS_FIXTURES) and check
# each metric against values worked out by hand from the fixture timestamps.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

SCRIPT="$REPO_ROOT/scripts/ci-metrics.py"

fixtures="$(mktemp -d "${TMPDIR:-/tmp}/ci-metrics-XXXXXX")"
SCRIPT="$SCRIPT" FIXTURES="$fixtures" python3 - <<'PYTHON'
import importlib.util
import json
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location('metrics', os.environ['SCRIPT'])
metrics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metrics)
root = Path(os.environ['FIXTURES'])

def put(path, data):
    (root / f'{metrics.Api._slug(path)}.json').write_text(json.dumps(data))

def job(job_id, name, conclusion, created, started, completed, pool):
    return {'id': job_id, 'name': name, 'conclusion': conclusion, 'runner_name': 'runner' if started else '',
            'created_at': f'2026-10-01T{created}:00Z', 'started_at': started and f'2026-10-01T{started}:00Z',
            'completed_at': completed and f'2026-10-01T{completed}:00Z', 'labels': ['self-hosted', pool]}

runs = [
    {'id': 1, 'event': 'pull_request', 'status': 'completed', 'head_sha': 'a', 'created_at': '2026-10-01T10:00:00Z', 'run_attempt': 2},
    {'id': 2, 'event': 'pull_request', 'status': 'completed', 'head_sha': 'b', 'created_at': '2026-10-01T12:00:00Z', 'run_attempt': 1},
    {'id': 3, 'event': 'push', 'status': 'completed', 'head_sha': 'c', 'created_at': '2026-10-01T13:00:00Z', 'run_attempt': 1},
    {'id': 4, 'event': 'pull_request', 'status': 'in_progress', 'head_sha': 'd', 'created_at': '2026-10-01T14:00:00Z', 'run_attempt': 1},
    {'id': 5, 'event': 'pull_request', 'status': 'completed', 'head_sha': 'a', 'created_at': '2026-10-01T09:00:00Z', 'run_attempt': 1},
]
put('/repos/o/r/actions/runs?created=2026-10-01&per_page=100&page=1', {'workflow_runs': runs})
put('/repos/o/r/actions/runs/1/attempts/1/jobs?per_page=100&page=1', {'jobs': [
    job(11, 'iOS Maestro E2E / Plan the build strategy / Plan (e2e)', 'success', '10:00', '10:02', '10:05', 'trf-linux-amd64-2x4'),
    job(12, 'iOS Maestro E2E / Build (e2e)', 'success', '10:05', '10:15', '10:35', 'macos-maestro'),
    job(13, 'iOS Maestro E2E / Maestro shard 0 (e2e)', 'failure', '10:35', '10:40', '11:00', 'macos-maestro'),
]})
put('/repos/o/r/actions/runs/2/attempts/1/jobs?per_page=100&page=1', {'jobs': [
    job(21, 'iOS Maestro E2E / Plan the build strategy / Plan (e2e)', 'success', '12:00', '12:01', '12:03', 'trf-linux-amd64-2x4'),
    job(22, 'iOS Maestro E2E / Build (e2e)', 'skipped', '12:03', None, '12:03', 'macos-maestro'),
    job(23, 'iOS Maestro E2E / Maestro shard 0 (e2e)', 'failure', '12:03', '12:05', '12:15', 'macos-maestro'),
]})
put('/repos/o/r/actions/runs/3/attempts/1/jobs?per_page=100&page=1', {'jobs': [
    job(31, 'Seed', 'success', '13:00', '13:01', '13:02', 'trf-linux-amd64-2x4'),
]})
put('/repos/o/r/actions/runs/5/attempts/1/jobs?per_page=100&page=1', {'jobs': [
    job(51, 'CodeQL', 'success', '09:00', '09:00', '15:00', 'ubuntu-latest'),
    job(52, 'Required CI', 'failure', '09:00', '09:00', '09:01', 'ubuntu-latest'),
    job(53, 'Lint', 'failure', '09:00', '09:00', '09:02', 'ubuntu-latest'),
]})
put('/repos/o/r/check-runs/52/annotations', [{'message': 'Required jobs did not succeed: ios-maestro', 'title': ''}])
put('/repos/o/r/check-runs/53/annotations', [{'message': 'Process completed with exit code 127.', 'title': ''}])
put('/repos/o/r/check-runs/13/annotations', [{'message': 'Assertion is false: "Home" is visible', 'title': ''}])
put('/repos/o/r/check-runs/23/annotations', [{'message': 'The self-hosted runner lost communication with the server.', 'title': ''}])
PYTHON

metrics() {
    STEP_STATUS=0
    CI_METRICS_FIXTURES="$fixtures" python3 -I "$SCRIPT" --repo o/r --since 2026-10-01 --until 2026-10-02 \
        --json "$fixtures/out.json" "$@" > "$fixtures/report.md" 2> "$fixtures/err" || STEP_STATUS=$?
}
value() {
    jq -r "$1" "$fixtures/out.json"
}

case_start 'pull-request feedback spans the mobile-lane run per head commit, ignoring runs without one'
metrics
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$fixtures/err"))" \
    && assert_equals 2 "$(value '.results["o/r"].prCommits')" 'pull-request commits (push and unfinished runs excluded)' \
    && assert_equals 15.0 "$(value '.results["o/r"].feedbackP50')" 'feedback p50' \
    && assert_equals 60.0 "$(value '.results["o/r"].feedbackP90')" 'feedback p90 (a re-run commit counts its first attempt)'; then
    pass_case
fi

case_start 'queue time is grouped by pool and counts only jobs a runner picked up'
if assert_equals '3 1.0 2.0' "$(value '.results["o/r"].queue["trf-linux-amd64-2x4"] | "\(.jobs) \(.p50) \(.p90)"')" 'linux pool' \
    && assert_equals '3 5.0 10.0' "$(value '.results["o/r"].queue["macos-maestro"] | "\(.jobs) \(.p50) \(.p90)"')" 'mac pool (skipped build excluded)'; then
    pass_case
fi

case_start 'native share counts head commits whose lane ran a native build'
assert_equals 0.5 "$(value '.results["o/r"].nativeShare')" 'native share' && pass_case

case_start 'shard durations come from Maestro shard jobs'
assert_equals '2 10.0 20.0 20.0' "$(value '.results["o/r"].shards | "\(.jobs) \(.p50) \(.p90) \(.max)"')" shards && pass_case

case_start 'a lost runner and a missing command are infra, an assertion is a test failure, a roll-up is not counted'
assert_equals '2 1' "$(value '.results["o/r"].failures | "\(.infra) \(.test)"')" failures && pass_case

case_start 'a baseline window adds deltas to the report'
metrics --baseline-since 2026-10-01 --baseline-until 2026-10-02
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$fixtures/err"))" \
    && assert_contains "$(cat "$fixtures/report.md")" '15.0 min (+0.0)' 'feedback delta' \
    && assert_contains "$(cat "$fixtures/report.md")" '50% (+0 pp)' 'native share delta' \
    && assert_contains "$(cat "$fixtures/report.md")" '| `ubuntu-latest` | o/r | 3 |' 'hosted runner jobs are visible'; then
    pass_case
fi

case_start 'an empty window, an unpaired baseline or a malformed repository fails'
metrics --until 2026-10-01
first=$STEP_STATUS
metrics --baseline-since 2026-10-01
second=$STEP_STATUS
metrics --repo 'bad repo'
if [ "$first" -ne 0 ] && [ "$second" -ne 0 ] && [ "$STEP_STATUS" -ne 0 ]; then pass_case; else fail_case "statuses: $first $second $STEP_STATUS"; fi

case_start 'no token and no fixtures fails closed'
STEP_STATUS=0
env -u GH_TOKEN -u GITHUB_TOKEN python3 -I "$SCRIPT" --repo o/r --since 2026-10-01 --until 2026-10-02 > /dev/null 2> "$fixtures/err" || STEP_STATUS=$?
if [ "$STEP_STATUS" -ne 0 ] && assert_contains "$(cat "$fixtures/err")" 'GH_TOKEN' error; then pass_case; fi

rm -rf "$fixtures"
finish_suite
