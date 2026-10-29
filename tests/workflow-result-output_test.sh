#!/usr/bin/env bash
# The e2e and screenshot workflows' status job is the one place that knows
# whether a run passed, failed or was skipped as unaffected (a skip is a green
# check, not a pass). Its `result` output hands that verdict to a caller's
# Slack or comment job, so it must match what the status job decided.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

# rollup_lines <log>: the log's ::error:: lines rerun-infra-failures reads as a
# roll-up (scripts/ci-metrics.py ROLLUP), so a roll-up never blocks a retry.
rollup_lines() {
    SCRIPT="$REPO_ROOT/scripts/ci-metrics.py" python3 -I -c '
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("metrics", os.environ["SCRIPT"])
metrics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metrics)
print(sum(1 for line in sys.stdin if line.startswith("::error::") and metrics.ROLLUP.search(line)))' < "$1"
}

report_maestro() {
    workspace="$(new_workflow_workspace "$REPO_ROOT/.github/workflows/$1.yml" status Report)"
    shift
    run_step "$workspace" DETECT_RESULT=success DETECT_AFFECTED=true DETECT_FORCED=false FORCE_LABEL=e2e \
        PLAN_RESULT=success NATIVE_TARGETS='[]' BUILD_RESULT=skipped TEST_RESULT=success "$@"
}

for workflow in ios-maestro android-maestro; do
    case_start "$workflow: a passing suite reports result=passed"
    report_maestro "$workflow"
    if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))" \
        && assert_equals passed "$(step_output "$workspace" result)" 'result'; then
        pass_case
    fi

    case_start "$workflow: a forced passing suite reports result=passed"
    report_maestro "$workflow" DETECT_FORCED=true
    if assert_equals 0 "$STEP_STATUS" 'status' \
        && assert_equals passed "$(step_output "$workspace" result)" 'result'; then
        pass_case
    fi

    case_start "$workflow: an unaffected run reports result=skipped, not passed"
    report_maestro "$workflow" DETECT_AFFECTED=false TEST_RESULT=skipped
    if assert_equals 0 "$STEP_STATUS" 'status' \
        && assert_equals skipped "$(step_output "$workspace" result)" 'result'; then
        pass_case
    fi

    case_start "$workflow: a failed suite reports result=failed"
    report_maestro "$workflow" TEST_RESULT=failure
    if assert_equals 1 "$STEP_STATUS" 'status' \
        && assert_equals failed "$(step_output "$workspace" result)" 'result'; then
        pass_case
    fi

    case_start "$workflow: a failed job is reported as the roll-up annotation the infra retry skips"
    statuses=''
    for failed in DETECT_RESULT PLAN_RESULT BUILD_RESULT TEST_RESULT; do
        report_maestro "$workflow" "$failed=failure"
        statuses="$statuses$STEP_STATUS$(rollup_lines "$workspace/log")"
    done
    report_maestro "$workflow" NATIVE_TARGETS='["app"]'
    own="$STEP_STATUS$(rollup_lines "$workspace/log")"
    if assert_equals 11111111 "$statuses" 'status and roll-up annotations per failed job' \
        && assert_equals 10 "$own" "the status job's own skipped-build verdict"; then
        pass_case
    fi

    case_start "$workflow: a failed detection reports result=failed"
    report_maestro "$workflow" DETECT_RESULT=failure
    if assert_equals 1 "$STEP_STATUS" 'status' \
        && assert_equals failed "$(step_output "$workspace" result)" 'result'; then
        pass_case
    fi
done

report_screenshots() {
    workspace="$(new_workflow_workspace "$REPO_ROOT/.github/workflows/store-screenshots.yml" status Report)"
    run_step "$workspace" VALIDATE_RESULT=success HAS_IOS=true HAS_ANDROID=false \
        PLAN_IOS_RESULT=success NATIVE_TARGETS_IOS='[]' BUILD_IOS_RESULT=skipped \
        PLAN_ANDROID_RESULT=skipped NATIVE_TARGETS_ANDROID='' BUILD_ANDROID_RESULT=skipped \
        CAPTURE_IOS_RESULT=success CAPTURE_ANDROID_RESULT=skipped UPLOAD_ENABLED=false UPLOAD_RESULT=skipped "$@"
}

case_start 'store-screenshots: a complete capture reports result=passed'
report_screenshots
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))" \
    && assert_equals passed "$(step_output "$workspace" result)" 'result'; then
    pass_case
fi

case_start 'store-screenshots: a failed capture reports result=failed'
report_screenshots CAPTURE_IOS_RESULT=failure
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_equals failed "$(step_output "$workspace" result)" 'result'; then
    pass_case
fi

case_start 'store-screenshots: a failed capture is reported as the roll-up annotation the infra retry skips'
report_screenshots CAPTURE_IOS_RESULT=failure
if assert_equals 1 "$STEP_STATUS" 'status' && assert_equals 1 "$(rollup_lines "$workspace/log")" 'roll-up annotations'; then
    pass_case
fi

case_start 'wiring: every workflow exposes the status job result'
if failure="$(REPO="$REPO_ROOT" python3 - <<'PYTHON' 2>&1
import os
import sys

import yaml

problems = []
for name in ('ios-maestro', 'android-maestro', 'store-screenshots'):
    workflow = yaml.safe_load(open(f"{os.environ['REPO']}/.github/workflows/{name}.yml", encoding='utf-8'))
    output = workflow[True]['workflow_call'].get('outputs', {}).get('result', {})
    if 'jobs.status.outputs.result' not in str(output.get('value', '')):
        problems.append(f'{name}: workflow output result must read jobs.status.outputs.result')
    if 'steps.report.outputs.result' not in str(workflow['jobs']['status'].get('outputs', {}).get('result', '')):
        problems.append(f'{name}: status job output result must read steps.report.outputs.result')
if problems:
    sys.exit('\n'.join(problems))
PYTHON
)"; then
    pass_case
else
    fail_case "$failure"
fi

finish_suite
