#!/usr/bin/env bash
# ota-runtime-version is the one runtime-version source every OTA path uses:
# the project's own `expo-updates runtimeversion:resolve`, the value
# `eas update` and the expo-updates client agree on, under each target's
# eas.json profile env plus any extra env. A runtime that cannot be resolved,
# or a malformed env line, fails the step: an OTA targeting a guessed runtime
# reaches no build.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION_YML="$REPO_ROOT/actions/ota-runtime-version/action.yml"
STEP='Resolve the runtime versions'

workspace() {
    local ws
    ws="$(new_workspace "$ACTION_YML" "$STEP")"
    # shellcheck disable=SC2016
    stub "$ws" npx '
dir="$(dirname "$0")/.."
printf "%s\n" "$*" >> "$dir/npx-calls"
platform="$5"
printf "%s APP_VARIANT=%s EAS_BUILD_PROFILE=%s STORE=%s SECRET=%s\n" "$platform" "${APP_VARIANT:-}" "${EAS_BUILD_PROFILE:-}" "${STORE_BUILD_NUMBER:-}" "${SECRET:-unset}" >> "$dir/resolve-env"
[ -z "${RESOLVE_FAIL:-}" ] || exit 1
var="RUNTIME_${platform}"
printf "{\"runtimeVersion\":\"%s%s\",\"workflow\":\"managed\"}\n" "${!var:-}" "${APP_VARIANT:+-$APP_VARIANT}"'
    printf '%s\n' "$ws"
}

resolve() {
    WS="$(workspace)"
    run_step "$WS" TARGETS='' PLATFORM=all EAS_PROFILE='' PROFILE_ENV='' EXTRA_ENV='' UNSET_ENV='' \
        RUNTIME_ios=rv-i RUNTIME_android=rv-a SECRET=s "$@"
}

out() {
    step_output "$WS" "$1"
}

case_start "both platforms resolve with the project's own expo-updates, never a downloaded one"
resolve
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals rv-i "$(out ios-runtime-version)" 'ios' \
    && assert_equals rv-a "$(out android-runtime-version)" 'android' \
    && assert_equals '{"ios":"rv-i","android":"rv-a"}' "$(out runtime-versions)" 'map' \
    && assert_contains "$(cat "$WS/npx-calls")" '--no-install expo-updates runtimeversion:resolve --platform ios' 'local CLI'; then
    pass_case
fi

case_start "the eas.json profile env and EAS_BUILD_PROFILE apply, then extra env wins"
resolve PLATFORM=android EAS_PROFILE=preview PROFILE_ENV=$'APP_VARIANT=preview\nOTHER=1' EXTRA_ENV=$'APP_VARIANT=store\nSTORE_BUILD_NUMBER=42'
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals rv-a-store "$(out android-runtime-version)" 'runtime' \
    && assert_equals '' "$(out ios-runtime-version)" 'no ios' \
    && assert_equals 'android APP_VARIANT=store EAS_BUILD_PROFILE=preview STORE=42 SECRET=s' "$(cat "$WS/resolve-env")" 'env'; then
    pass_case
fi

case_start "unset-env keeps named variables out of the resolution"
resolve PLATFORM=ios UNSET_ENV=$'SECRET\nOTHER_SECRET'
if assert_equals 0 "$STEP_STATUS" 'status' && assert_contains "$(cat "$WS/resolve-env")" 'SECRET=unset' 'unset'; then
    pass_case
fi

case_start "targets resolve each target under its own env"
resolve TARGETS='[{"name":"a-ios","platform":"ios","envLines":"APP_VARIANT=a","buildProfile":"a","channel":"x"},{"name":"b-ios","platform":"ios","envLines":"APP_VARIANT=b"}]'
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals '{"a-ios":"rv-i-a","b-ios":"rv-i-b"}' "$(out runtime-versions)" 'map' \
    && assert_equals $'ios APP_VARIANT=a EAS_BUILD_PROFILE=a STORE= SECRET=s\nios APP_VARIANT=b EAS_BUILD_PROFILE= STORE= SECRET=s' "$(cat "$WS/resolve-env")" 'per-target env'; then
    pass_case
fi

case_start "a failing resolution fails the step"
resolve RESOLVE_FAIL=1
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$WS/log")" 'runtimeversion:resolve failed' 'message' \
    && assert_equals '' "$(out runtime-versions)" 'no output'; then
    pass_case
fi

case_start "an empty runtime version fails the step"
resolve RUNTIME_android=''
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(cat "$WS/log")" 'no runtime version' 'message'; then
    pass_case
fi

for bad in 'PLATFORM=web|platform must be' 'EXTRA_ENV=NOEQUALS|env line' 'EXTRA_ENV=1X=y|env line' \
    'UNSET_ENV=bad-name|unset-env' 'TARGETS=[]|targets must be' 'TARGETS=[{"name":"x","platform":"web"}]|targets must be'; do
    case_start "invalid input fails closed: ${bad%%|*}"
    resolve "${bad%%|*}"
    if assert_equals 1 "$STEP_STATUS" 'status' \
        && assert_contains "$(cat "$WS/log")" "${bad#*|}" 'message' \
        && assert_equals '' "$(cat "$WS/npx-calls" 2>/dev/null || true)" 'nothing resolved'; then
        pass_case
    fi
done

finish_suite
