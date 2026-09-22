#!/usr/bin/env bash
# The fingerprint step takes both its control variables and consumer-supplied
# env through the same shell, so what extra-env is allowed to set decides
# whether the hash describes the platform the caller asked for.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/native-fingerprint/action.yml"
STEP='Generate native fingerprint'

# fingerprint_workspace — stubs npx so the recorded platform and env are what
# the step actually handed the CLI, and node so the hash is read back.
fingerprint_workspace() {
    local dir
    dir="$(new_workspace "$ACTION" "$STEP")"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" npx '
platform=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = --platform ]; then platform="$2"; fi
    shift
done
printf "%s\n" "$platform" > "$NPX_PLATFORM_FILE"
printf "%s\n" "${BRAND:-}" > "$NPX_BRAND_FILE"
printf "{\"hash\":\"hash-for-%s\"}" "$platform"'
    printf '%s\n' "$dir"
}

generate() {
    local dir="$1" platform="$2" extra_env="$3"
    run_step "$dir" \
        FINGERPRINT_VERSION=0.20.6 \
        FINGERPRINT_PLATFORM="$platform" \
        FINGERPRINT_EXTRA_ENV="$extra_env" \
        NPX_PLATFORM_FILE="$dir/platform" \
        NPX_BRAND_FILE="$dir/brand"
}

case_start 'extra-env reaches the fingerprint evaluation'
dir="$(fingerprint_workspace)"
generate "$dir" ios 'BRAND=Example'
assert_equals 0 "$STEP_STATUS" 'generate exit status' \
    && assert_equals 'Example' "$(cat "$dir/brand")" 'BRAND seen by the CLI' \
    && assert_equals 'hash-for-ios' "$(step_output "$dir" hash)" 'hash' \
    && pass_case

case_start 'extra-env cannot overwrite the platform the caller asked for'
dir="$(fingerprint_workspace)"
generate "$dir" ios 'FINGERPRINT_PLATFORM=android'
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case "extra-env fingerprinted '$(cat "$dir/platform")' while the inputs said ios, so an iOS-only change could reuse a stale base"
else
    assert_contains "$(cat "$dir/log")" 'own control variable' 'error message' && pass_case
fi

case_start 'extra-env cannot overwrite the pinned fingerprint version'
dir="$(fingerprint_workspace)"
generate "$dir" ios 'FINGERPRINT_VERSION=0.1.0'
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'extra-env replaced the pinned @expo/fingerprint version'
else
    pass_case
fi

case_start 'a malformed extra-env line fails closed'
dir="$(fingerprint_workspace)"
generate "$dir" ios 'NOT_AN_ASSIGNMENT'
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'a line with no = was accepted'
else
    assert_contains "$(cat "$dir/log")" "is missing '='" 'error message' && pass_case
fi

case_start 'an extra-env name that is not a shell identifier fails closed'
dir="$(fingerprint_workspace)"
generate "$dir" ios '2BAD=value'
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'an invalid variable name was exported'
else
    pass_case
fi

finish_suite
