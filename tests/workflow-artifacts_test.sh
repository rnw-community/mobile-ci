#!/usr/bin/env bash
# Every workflow here hands a built app to a later job through a named artifact,
# and both ends of that name live in different files: the repack uploads it from
# expo-base-plan.yml under the caller's app-artifact-prefix, the native build
# uploads it from the caller itself, and the test or capture job downloads it
# unconditionally. Nothing in actionlint or the schema connects those three, so
# a step deleted or renamed on one side fails only at runtime, after the
# expensive jobs have already run. This suite is that connection.
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
jobs = workflow['jobs']

TARGET_NAME = re.compile(r'\$\{\{[^}]*\}\}')


def prefix_of(name):
    """The literal head of an artifact name whose tail is the target name."""
    return TARGET_NAME.sub('', name or '').rstrip('-')


downloads, uploads, plan_prefixes = set(), set(), set()
for job_id, job in jobs.items():
    if 'uses' in job and 'expo-base-plan.yml' in job['uses']:
        prefix = job.get('with', {}).get('app-artifact-prefix')
        if prefix:
            plan_prefixes.add(prefix)
        continue
    for step in job.get('steps', []):
        uses = str(step.get('uses', ''))
        name = step.get('with', {}).get('name')
        if 'actions/download-artifact' in uses and name:
            downloads.add((job_id, prefix_of(name)))
        if 'actions/upload-artifact' in uses and name:
            uploads.add(prefix_of(name))

problems = []
for job_id, prefix in sorted(downloads):
    if prefix.startswith('e2e-base'):
        continue
    if prefix in uploads or prefix in plan_prefixes:
        continue
    problems.append(
        f"job '{job_id}' downloads '{prefix}-<target>', which no job in this "
        f"workflow uploads and no expo-base-plan call names as its "
        f"app-artifact-prefix")

# An app a plan job may repack must also be produced by the native build that
# runs when no base exists, or the run that had to compile has nothing to hand on.
for prefix in sorted(plan_prefixes):
    if prefix not in uploads:
        problems.append(
            f"expo-base-plan uploads '{prefix}-<target>' on the repack path, but "
            f"no native build job in this workflow uploads it, so a target with "
            f"no published base would build and hand on nothing")

if problems:
    sys.exit('; '.join(problems))
PYTHON
}

for workflow in ios-maestro android-maestro store-screenshots; do
    case_start "$workflow: every app artifact is uploaded by whoever built it"
    if failure="$(check_workflow "$REPO_ROOT/.github/workflows/${workflow}.yml" 2>&1)"; then
        pass_case
    else
        fail_case "$failure"
    fi
done

finish_suite
