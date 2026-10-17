#!/usr/bin/env bash
# build-android-app's Gradle cache must warm even when the build does not
# finish. A build that times out on a cold cache and saves nothing restores
# the same cold cache next time and times out again, forever. So a build that
# failed or was cancelled saves what it downloaded under a run-unique partial
# key the next restore falls back to, and a successful build saves the exact
# key unless it was already an exact hit.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/build-android-app/action.yml"
STEP='Choose the Gradle cache save key'
KEY='gradle-bare-Linux-abc123'

choose() {
    workspace="$(new_workspace "$ACTION" "$STEP")"
    run_step "$workspace" CACHE_KEY="$KEY" RUN_ID='777' RUN_ATTEMPT='2' "$@"
}

case_start 'a successful build on a cache miss saves the exact key'
choose BUILD_OUTCOME='success' CACHE_HIT='false'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals "$KEY" "$(step_output "$workspace" key)" 'save key'; then
    pass_case
fi

case_start 'a successful build on an exact hit saves nothing'
choose BUILD_OUTCOME='success' CACHE_HIT='true'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals '' "$(step_output "$workspace" key)" 'save key'; then
    pass_case
fi

case_start 'a failed build saves a run-unique partial key'
choose BUILD_OUTCOME='failure' CACHE_HIT='false'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals "$KEY-partial-777-2" "$(step_output "$workspace" key)" 'save key'; then
    pass_case
fi

case_start 'a build cancelled by its timeout saves a run-unique partial key'
choose BUILD_OUTCOME='cancelled' CACHE_HIT='false'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals "$KEY-partial-777-2" "$(step_output "$workspace" key)" 'save key'; then
    pass_case
fi

case_start 'a failed build that restored the exact key saves nothing new'
choose BUILD_OUTCOME='failure' CACHE_HIT='true'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals '' "$(step_output "$workspace" key)" 'save key'; then
    pass_case
fi

case_start 'a build that never ran saves nothing'
choose BUILD_OUTCOME='skipped' CACHE_HIT=''
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals '' "$(step_output "$workspace" key)" 'save key'; then
    pass_case
fi

case_start 'the save runs after a failed or cancelled build, and the restore falls back to partials first'
if wiring="$(ACTION_YML="$ACTION" python3 - <<'PYTHON' 2>&1
import os
import sys

import yaml

steps = yaml.safe_load(open(os.environ['ACTION_YML'], encoding='utf-8'))['runs']['steps']
by_name = {step.get('name'): step for step in steps}
problems = []
for name in ('Choose the Gradle cache save key', 'Save Gradle cache'):
    if 'always()' not in str(by_name.get(name, {}).get('if', '')):
        problems.append(f"step {name!r} does not run if: always()")
restore = by_name.get('Restore Gradle cache', {})
first = str(restore.get('with', {}).get('restore-keys', '')).strip().split('\n')[0]
if first != '${{ inputs.gradle-cache-key }}-partial-':
    problems.append(f"restore-keys does not try this key's partials first: {first!r}")
if problems:
    sys.exit('; '.join(problems))
PYTHON
)"; then
    pass_case
else
    fail_case "$wiring"
fi

finish_suite
