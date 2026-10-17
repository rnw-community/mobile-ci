#!/usr/bin/env bash
# A job gated on `needs.<job>.result != 'failure'` also runs when that job was
# cancelled, which is what a job that hit its timeout-minutes reports. A test
# shard then claims a device slot and fails downloading an app nobody built.
# Every job-level gate on an upstream result must name the results it accepts
# ('success', and 'skipped' where a skipped upstream is legitimate) instead of
# the one it rejects.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

check_workflow() {
    WORKFLOW="$1" python3 - <<'PYTHON'
import os
import re
import sys

import yaml

path = os.environ['WORKFLOW']
workflow = yaml.safe_load(open(path, encoding='utf-8'))

NEGATIVE_GATE = re.compile(r"needs\.([A-Za-z0-9_-]+)\.result\s*!=\s*'([a-z]+)'")

problems = []
for job_id, job in (workflow.get('jobs') or {}).items():
    condition = str(job.get('if', ''))
    for upstream, result in NEGATIVE_GATE.findall(condition):
        problems.append(
            f"job '{job_id}' runs when needs.{upstream}.result != '{result}', "
            f"which admits a cancelled or timed-out {upstream}; accept "
            f"'success' (or 'skipped') explicitly instead")

if problems:
    sys.exit('; '.join(problems))
PYTHON
}

for workflow_path in "$REPO_ROOT"/.github/workflows/*.yml; do
    workflow="$(basename "$workflow_path" .yml)"
    case_start "$workflow: job gates accept upstream results, never merely reject failure"
    if failure="$(check_workflow "$workflow_path" 2>&1)"; then
        pass_case
    else
        fail_case "$failure"
    fi
done

finish_suite
