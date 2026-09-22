#!/usr/bin/env bash
# swift-ios.yml decides which identifiers a shard starts from. The rule that
# matters: a narrowed run only happens when xcodebuild-affected-tests actually
# narrowed it, and anything else runs exactly what a push runs.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

WORKFLOW="$REPO_ROOT/.github/workflows/swift-ios.yml"
STEP='Resolve which test identifiers this shard starts from'

# Sets `workspace`; run_step's STEP_STATUS would be lost in a subshell, so this
# is deliberately not a command substitution.
resolve() {
    workspace="$(new_workflow_workspace "$WORKFLOW" test "$STEP")"
    run_step "$workspace" "$@"
}

case_start 'an affected selection is what the shard runs'
resolve AFFECTED_MODE='affected' AFFECTED_ONLY_TESTING='PonyUITests/MenuTests' ONLY_TESTING=''
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'PonyUITests/MenuTests' "$(step_output "$workspace" only-testing)" 'only-testing'; then
    pass_case
fi

case_start "mode 'all' runs exactly what a push runs, not an empty list"
resolve AFFECTED_MODE='all' AFFECTED_ONLY_TESTING='' ONLY_TESTING='PonyUITests'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'PonyUITests' "$(step_output "$workspace" only-testing)" 'only-testing'; then
    pass_case
fi

case_start 'affected-tests turned off leaves the caller list untouched'
resolve AFFECTED_MODE='' AFFECTED_ONLY_TESTING='' ONLY_TESTING='PonyUITests/MazeTests'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'PonyUITests/MazeTests' "$(step_output "$workspace" only-testing)" 'only-testing'; then
    pass_case
fi

case_start 'an empty list and no caller list means the whole scheme'
resolve AFFECTED_MODE='all' AFFECTED_ONLY_TESTING='' ONLY_TESTING=''
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals '' "$(step_output "$workspace" only-testing)" 'only-testing'; then
    pass_case
fi

case_start "mode 'affected' with an empty selection fails closed"
resolve AFFECTED_MODE='affected' AFFECTED_ONLY_TESTING='' ONLY_TESTING='PonyUITests'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'would test nothing' 'error message'; then
    pass_case
fi

finish_suite
