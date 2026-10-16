#!/usr/bin/env bash
# A reusable workflow's concurrency runs inside the caller's run, so an
# unconditional `cancel-in-progress: true` there cancels an older default-branch
# run whenever a newer push lands, whatever the caller decided for its own
# workflow. Cancellation is only ever right for a superseded pull request, so
# every concurrency block here must either never cancel or cancel only on
# pull_request events.
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

PULL_REQUEST_ONLY = re.compile(
    r"^\$\{\{\s*github\.event_name\s*==\s*'pull_request'\s*\}\}$")


def check(where, concurrency, problems):
    if not isinstance(concurrency, dict):
        return
    cancel = concurrency.get('cancel-in-progress', False)
    if cancel is False:
        return
    if isinstance(cancel, str) and PULL_REQUEST_ONLY.match(cancel.strip()):
        group = str(concurrency.get('group', ''))
        if 'github.run_id' not in group:
            problems.append(
                f"{where}: a non-pull_request run's group must be unique to "
                f"the run (github.run_id), or a third default-branch run "
                f"still displaces the pending second one")
        return
    problems.append(
        f"{where}: cancel-in-progress is {cancel!r}; use "
        f"${{{{ github.event_name == 'pull_request' }}}} or false")


problems = []
check('workflow concurrency', workflow.get('concurrency'), problems)
for job_id, job in (workflow.get('jobs') or {}).items():
    check(f"job '{job_id}' concurrency", job.get('concurrency'), problems)

if problems:
    sys.exit('; '.join(problems))
PYTHON
}

for workflow_path in "$REPO_ROOT"/.github/workflows/*.yml; do
    workflow="$(basename "$workflow_path" .yml)"
    case_start "$workflow: concurrency cancels only superseded pull request runs"
    if failure="$(check_workflow "$workflow_path" 2>&1)"; then
        pass_case
    else
        fail_case "$failure"
    fi
done

finish_suite
