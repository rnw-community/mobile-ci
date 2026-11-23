#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

helper="$REPO_ROOT/scripts/slim-simulator.sh"
udid='cccccccc-cccc-cccc-cccc-cccccccccccc'

workspace() {
    local dir
    dir="$(new_empty_workspace)"
    # shellcheck disable=SC2016 # expanded by the shell executing the helper.
    printf '. "$HELPER"\nslim_simulator "$UDID"\n' > "$dir/step.sh"
    # shellcheck disable=SC2016
    stub "$dir" simslim '
printf "%s\n" "$*" >> "$CALLS"
case "$1" in
    verify)
        [ "${VERIFY_ALWAYS_FAIL:-}" != 1 ] || exit 1
        [ -f "$REPAIRED" ] || [ "${VERIFY_DRIFT:-}" != 1 ]
        ;;
    on)
        [ "${ON_FAIL:-}" != 1 ] || exit 1
        touch "$REPAIRED"
        ;;
esac'
    printf '%s\n' "$dir"
}

run_helper() {
    local dir="$1"
    shift
    run_step "$dir" HELPER="$helper" UDID="$udid" \
        CALLS="$dir/calls" REPAIRED="$dir/repaired" \
        SIMSLIM_PROFILE="$REPO_ROOT/profiles/ci.json" "$@"
}

case_start 'a matching profile needs no mutation'
dir="$(workspace)"
run_helper "$dir"
if assert_equals 0 "$STEP_STATUS" 'helper status' \
    && assert_not_contains "$(cat "$dir/calls")" 'on ' 'no repair'; then
    pass_case
fi

case_start 'a repaired profile is verified again'
dir="$(workspace)"
run_helper "$dir" VERIFY_DRIFT=1
if assert_equals 0 "$STEP_STATUS" 'helper status' \
    && assert_equals 2 "$(rg -c '^verify ' "$dir/calls")" 'verification count'; then
    pass_case
fi

case_start 'remaining drift after live repair fails closed'
dir="$(workspace)"
run_helper "$dir" VERIFY_ALWAYS_FAIL=1
if assert_equals 1 "$STEP_STATUS" 'helper status' \
    && assert_contains "$(cat "$dir/log")" 'still does not match' 'actionable drift error'; then
    pass_case
fi

case_start 'a failed repair propagates failure'
dir="$(workspace)"
run_helper "$dir" VERIFY_DRIFT=1 ON_FAIL=1
if assert_equals 1 "$STEP_STATUS" 'helper status'; then
    pass_case
fi

case_start 'a standalone helper fetches the current exact release profile'
dir="$(workspace)"
mkdir -p "$dir/standalone/scripts"
cp "$helper" "$dir/standalone/scripts/slim-simulator.sh"
# shellcheck disable=SC2016 # expanded by the shell resolving the profile.
printf '. "$HELPER"\nsimslim_profile_path\n' > "$dir/step.sh"
# shellcheck disable=SC2016
stub "$dir" curl '
printf "%s\n" "$*" > "$CALLS"
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then printf "{}\n" > "$2"; break; fi
    shift
done'
run_step "$dir" HELPER="$dir/standalone/scripts/slim-simulator.sh" \
    SIMSLIM_PROFILE='' SIMSLIM_PROFILE_REF='' TMPDIR="$dir" CALLS="$dir/calls"
if assert_equals 0 "$STEP_STATUS" 'profile resolution status' \
    && assert_contains "$(cat "$dir/calls")" '/v4.0.0/profiles/ci.json' 'immutable release profile'; then
    pass_case
fi

finish_suite
