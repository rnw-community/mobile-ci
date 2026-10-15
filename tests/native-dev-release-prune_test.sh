#!/usr/bin/env bash
# The dev-release prune steps run on whatever runner the job lands on. Since
# Android EAS builds default to the x86_64 Linux pool, that includes Ubuntu's
# packaged gh 2.45, which predates `gh api --slurp` (gh 2.48): the prune
# failed after a successful build and publish, turning the run red. Listing
# must work with any gh that has --paginate/--jq, keep the newest releases and
# delete only the older ones of this platform's prefix.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

WORKFLOW="$REPO_ROOT/.github/workflows/native-dev-release.yml"

prune_workspace() {
    local job="$1" step="$2" dir
    dir="$(new_workflow_workspace "$WORKFLOW" "$job" "$step")"
    : > "$dir/gh-calls"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" gh '
printf "%s\n" "$*" >> "$GH_CALLS"
case " $* " in
    *" --slurp "*) echo "unknown flag: --slurp" >&2; exit 1 ;;
esac
case "$1 $2" in
    "api repos/o/r/releases")
        case " $* " in
            *" --paginate --jq "*)
                # Two pages, newest-first within a page but not across pages, one draft.
                printf "2026-10-01T00:00:00Z\tdev-ios-1\n2026-10-03T00:00:00Z\tdev-ios-3\n2026-10-04T00:00:00Z\tdev-android-4\n"
                printf "2026-10-05T00:00:00Z\tdev-ios-5\n2026-10-02T00:00:00Z\tdev-ios-2\n2026-10-06T00:00:00Z\tdev-ios-6\n"
                ;;
            *) echo "unexpected gh api form: $*" >&2; exit 1 ;;
        esac
        ;;
    "release delete") exit 0 ;;
    *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac'
    printf '%s\n' "$dir"
}

case_start 'iOS prune works on a gh without --slurp and keeps the newest releases'
dir="$(prune_workspace ios-dev-release 'Prune old iOS dev releases')"
run_step "$dir" GH_CALLS="$dir/gh-calls" GH_TOKEN=t REPOSITORY=o/r TAG_PREFIX=dev-ios- KEEP_RELEASES=2 CURRENT_TAG=dev-ios-6
calls="$(cat "$dir/gh-calls")"
assert_equals 0 "$STEP_STATUS" 'step status' &&
    assert_contains "$calls" 'release delete dev-ios-2 --yes --cleanup-tag' 'older release deleted' &&
    assert_contains "$calls" 'release delete dev-ios-1 --yes --cleanup-tag' 'oldest release deleted' &&
    assert_not_contains "$calls" 'release delete dev-ios-5' 'newest kept' &&
    assert_not_contains "$calls" 'release delete dev-ios-3' 'second newest kept' &&
    assert_not_contains "$calls" 'release delete dev-ios-6' 'current release kept' &&
    assert_not_contains "$calls" 'release delete dev-android-4' 'other platform untouched' &&
    pass_case

case_start 'Android prune uses the same gh-version-independent listing'
dir="$(prune_workspace android-dev-release 'Prune old Android dev releases')"
run_step "$dir" GH_CALLS="$dir/gh-calls" GH_TOKEN=t REPOSITORY=o/r TAG_PREFIX=dev-android- KEEP_RELEASES=0 CURRENT_TAG=dev-android-9
calls="$(cat "$dir/gh-calls")"
assert_equals 0 "$STEP_STATUS" 'step status' &&
    assert_contains "$calls" 'release delete dev-android-4 --yes --cleanup-tag' 'old android release deleted' &&
    assert_not_contains "$calls" 'release delete dev-ios' 'ios releases untouched' &&
    pass_case

case_start 'a failed listing still fails the step'
dir="$(prune_workspace ios-dev-release 'Prune old iOS dev releases')"
run_step "$dir" GH_CALLS="$dir/gh-calls" GH_TOKEN=t REPOSITORY=x/y TAG_PREFIX=dev-ios- KEEP_RELEASES=2 CURRENT_TAG=dev-ios-6
assert_equals 1 "$STEP_STATUS" 'step status' &&
    assert_contains "$(cat "$dir/log")" "Failed to list existing releases" 'error message' &&
    pass_case

finish_suite
