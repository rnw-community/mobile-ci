#!/usr/bin/env bash
# build-ios-app retries pod install once on CocoaPods' intermittent
# 'path name contains null byte' (CocoaPods/CocoaPods#12798, #12866), which no
# input causes, and reports a second one as infrastructure for
# rerun-infra-failures. Any other pod install failure fails at once.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/build-ios-app/action.yml"
STEP='Install CocoaPods dependencies'

# scenario <exit status and stderr of each pod call, one 'status|message' per line; the last repeats>
scenario() {
    workspace="$(new_workspace "$ACTION" "$STEP")"
    printf '%s\n' "$1" > "$workspace/pod-answers"
    stub "$workspace" pod "
echo \"pod \$* RNCORE=\${RCT_USE_PREBUILT_RNCORE:-}\" >> '$workspace/pod-calls'
calls=\$(wc -l < '$workspace/pod-calls')
answer=\$(sed -n \"\${calls}p\" '$workspace/pod-answers')
[ -n \"\$answer\" ] || answer=\$(tail -n 1 '$workspace/pod-answers')
echo 'Analyzing dependencies'
echo \"\${answer#*|}\" >&2
exit \"\${answer%%|*}\""
    run_step "$workspace" RCT_USE_PREBUILT_RNCORE_ENABLED=true RCT_USE_RN_DEP_ENABLED=false EXPO_USE_PRECOMPILED_MODULES_ENABLED=false
}
calls() {
    wc -l < "$workspace/pod-calls" | tr -d ' '
}
NULL_BYTE='ArgumentError - path name contains null byte'

case_start 'a pod install that passes runs once, with the prebuilt flags exported'
scenario '0|'
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))" \
    && assert_equals 1 "$(calls)" 'pod calls' \
    && assert_equals 'pod install --repo-update RNCORE=1' "$(cat "$workspace/pod-calls")" 'pod call'; then pass_case; fi

case_start 'the null-byte error is retried once, and the step passes when the retry does'
scenario "1|$NULL_BYTE
0|"
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))" \
    && assert_equals 2 "$(calls)" 'pod calls' \
    && assert_contains "$(tail -n 1 "$workspace/pod-calls")" 'RNCORE=1' 'flags on the retry' \
    && assert_contains "$(cat "$workspace/log")" '::warning::' 'warning' \
    && assert_contains "$(cat "$workspace/log")" "$NULL_BYTE" 'pod output stays in the log'; then pass_case; fi

case_start 'a second null-byte error fails as an infrastructure failure, with no third attempt'
scenario "7|$NULL_BYTE"
if assert_equals 7 "$STEP_STATUS" 'status' \
    && assert_equals 2 "$(calls)" 'pod calls' \
    && assert_contains "$(cat "$workspace/log")" '::error::Infrastructure failure: pod install failed twice' 'annotation'; then pass_case; fi

case_start 'any other pod install failure fails at once'
scenario '3|[!] Unable to find a specification for Foo'
if assert_equals 3 "$STEP_STATUS" 'status' \
    && assert_equals 1 "$(calls)" 'pod calls' \
    && assert_not_contains "$(cat "$workspace/log")" '::warning::' 'warning' \
    && assert_not_contains "$(cat "$workspace/log")" 'Infrastructure failure' 'annotation'; then pass_case; fi

case_start 'a failure after a retry that is not the null-byte error is not called infrastructure'
scenario "1|$NULL_BYTE
3|[!] Unable to find a specification for Foo"
if assert_equals 3 "$STEP_STATUS" 'status' \
    && assert_equals 2 "$(calls)" 'pod calls' \
    && assert_not_contains "$(cat "$workspace/log")" 'Infrastructure failure' 'annotation'; then pass_case; fi

finish_suite
