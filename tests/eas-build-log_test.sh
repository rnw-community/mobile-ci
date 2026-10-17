#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"
PAYLOAD=$(printf '%0200d' 0)

for lane in 'native-dev-release.yml ios-dev-release iOS development' \
    'native-dev-release.yml android-dev-release Android development' \
    'native-publish.yml ios-publish iOS production' \
    'native-publish.yml android-publish Android production'; do
    read -r workflow job platform profile <<< "$lane"
    step="EAS build ($platform, $profile)"
    if [ "$profile" = production ]; then step="EAS build ($platform)"; fi
    for result in success failure; do
        case_start "$job: $result redacts encoded jobs from both streams and preserves status"
        workspace=$(new_workflow_workspace "$REPO_ROOT/.github/workflows/$workflow" "$job" "$step")
        # shellcheck disable=SC2016
        stub "$workspace" npx '
printf "stdout diagnostic %s\n" "$PAYLOAD"
printf "stderr diagnostic %s\n" "$PAYLOAD" >&2
[ "$RESULT" != failure ] || exit 17
printf binary > "${!#}"'
        run_step "$workspace" EAS_CLI_VERSION=20.5.1 BUILD_PROFILE=development \
            ANDROID_ARTIFACT_EXTENSION=apk PAYLOAD="$PAYLOAD" RESULT="$result"
        wanted=0
        if [ "$result" = failure ]; then wanted=17; fi
        if assert_equals "$wanted" "$STEP_STATUS" 'step status' \
            && assert_not_contains "$(cat "$workspace/log")" "$PAYLOAD" 'encoded payload' \
            && assert_contains "$(cat "$workspace/log")" 'stdout diagnostic' 'stdout context' \
            && assert_contains "$(cat "$workspace/log")" 'stderr diagnostic' 'stderr context'; then
            pass_case
        fi
    done
    case_start "$job: a failed output filter fails the build step"
    workspace=$(new_workflow_workspace "$REPO_ROOT/.github/workflows/$workflow" "$job" "$step")
    # shellcheck disable=SC2016
    stub "$workspace" npx 'printf binary > "${!#}"'
    stub "$workspace" sed 'exit 19'
    run_step "$workspace" EAS_CLI_VERSION=20.5.1 BUILD_PROFILE=development ANDROID_ARTIFACT_EXTENSION=apk
    if assert_equals 19 "$STEP_STATUS" 'failed filter status' \
        && assert_equals '' "$(step_output "$workspace" artifact-path)" 'no artifact output'; then
        pass_case
    fi
done
finish_suite
