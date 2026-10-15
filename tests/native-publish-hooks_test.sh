#!/usr/bin/env bash
# A consumer's pre/post hook (a fastlane lane, a metadata upload) needs the same
# signing key eas build/submit was handed, at the absolute path the workflow
# resolved. That path reaches a step only through its own env: block, and only
# once the step that writes the key has run, so a hook placed before the key
# step, or one whose env forgot the variable, silently gets an empty path. This
# suite pins every hook's key-path variables to the right step output and that
# step to an earlier position in the job.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

# check_hook <workflow> <job id> <hook step name> <VAR=step-id>...
check_hook() {
    local workflow="$1" job="$2" hook="$3"
    shift 3
    WORKFLOW="$REPO_ROOT/.github/workflows/$workflow" JOB_ID="$job" HOOK="$hook" \
        python3 - "$@" <<'PYTHON'
import os
import re
import sys

import yaml

workflow = yaml.safe_load(open(os.environ['WORKFLOW'], encoding='utf-8'))
steps = workflow['jobs'][os.environ['JOB_ID']]['steps']
names = [step.get('name') for step in steps]
hook_name = os.environ['HOOK']
if hook_name not in names:
    sys.exit(f"no step named {hook_name!r}")
hook_index = names.index(hook_name)
env = steps[hook_index].get('env') or {}

problems = []
for expectation in sys.argv[1:]:
    variable, step_id = expectation.split('=', 1)
    wanted = f'${{{{ steps.{step_id}.outputs.key-path }}}}'
    actual = env.get(variable)
    if actual != wanted:
        problems.append(f"env {variable} is {actual!r}, expected {wanted!r}")
    ids = [step.get('id') for step in steps]
    if step_id not in ids:
        problems.append(f"no step with id {step_id!r}")
    elif ids.index(step_id) > hook_index:
        problems.append(
            f"step {step_id!r} writes the key after {hook_name!r} runs, so the "
            f"hook would see an empty {variable}")

for variable, value in env.items():
    for step_id in re.findall(r'steps\.([A-Za-z0-9_-]+)\.outputs', str(value)):
        ids = [step.get('id') for step in steps]
        if step_id not in ids or ids.index(step_id) > hook_index:
            problems.append(f"env {variable} reads step {step_id!r}, which has not run yet")

if problems:
    sys.exit('; '.join(problems))
PYTHON
}

run_case() {
    local description="$1"
    shift
    case_start "$description"
    if failure="$(check_hook "$@" 2>&1)"; then
        pass_case
    else
        fail_case "$failure"
    fi
}

run_case "native-publish: iOS pre-submit hook gets the resolved ASC key path" \
    native-publish.yml ios-publish 'Run iOS pre-submit command' \
    EXPO_ASC_API_KEY_PATH=asc-key
run_case "native-publish: iOS post-submit hook gets the resolved ASC key path" \
    native-publish.yml ios-publish 'Run iOS post-submit command' \
    EXPO_ASC_API_KEY_PATH=asc-key
run_case "native-publish: Android pre-submit hook reads no step output before it is written" \
    native-publish.yml android-publish 'Run Android pre-submit command'
run_case "native-publish: Android post-submit hook gets the resolved Google key path" \
    native-publish.yml android-publish 'Run Android post-submit command' \
    GOOGLE_APPLICATION_CREDENTIALS=google-key GOOGLE_SERVICE_ACCOUNT_KEY_PATH=google-key
run_case "native-dev-release: iOS pre-build hook gets the resolved ASC key path" \
    native-dev-release.yml ios-dev-release 'Run iOS pre-build command' \
    EXPO_ASC_API_KEY_PATH=asc-key

finish_suite
