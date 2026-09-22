#!/usr/bin/env bash
# The native key is the address every base binary is published and looked up
# under, so what does and does not move it is the whole correctness argument.
# These cases run the real hashing and composing steps against a scratch tree.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/expo-native-key/action.yml"
IDENTITY_STEP='Hash the build action and the fingerprint config'
KEY_STEP='Compose the native key'
FINGERPRINT='abc123def456'

# identity_workspace <platform> — a scratch tree with a fake mobile-ci actions
# root next to it, so the build-action hash has something real to walk.
identity_workspace() {
    local dir
    dir="$(new_workspace "$ACTION" "$IDENTITY_STEP")"
    mkdir -p "$dir/actions/build-ios-app" "$dir/actions/setup-xcode-pinned" "$dir/actions/build-android-app"
    printf 'ios build action v1\n' > "$dir/actions/build-ios-app/action.yml"
    printf 'xcode pin v1\n' > "$dir/actions/setup-xcode-pinned/action.yml"
    printf 'android build action v1\n' > "$dir/actions/build-android-app/action.yml"
    printf '%s\n' "$dir"
}

identity() {
    local dir="$1"
    shift
    run_step "$dir" \
        PLATFORM="${PLATFORM:-ios}" \
        WORKING_DIRECTORY=. \
        FINGERPRINT_CONFIG=fingerprint.config.js \
        ACTIONS_ROOT="$dir/actions" \
        "$@"
}

compose() {
    local dir="$1" fingerprint="$2" build_action_hash="$3" config_hash="$4"
    shift 4
    run_step "$dir" \
        PLATFORM="${PLATFORM:-ios}" \
        FLAVOR="${FLAVOR:-e2e}" \
        TOOLCHAIN="${TOOLCHAIN:-xcode-26.4.1-17E202}" \
        FINGERPRINT="$fingerprint" \
        BUILD_ACTION_HASH="$build_action_hash" \
        CONFIG_HASH="$config_hash" \
        "$@"
}

case_start 'an empty fingerprint never becomes a key'
dir="$(new_workspace "$ACTION" "$KEY_STEP")"
compose "$dir" '' 'buildhash' 'confighash'
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case "an empty fingerprint produced key '$(step_output "$dir" key)' instead of failing"
elif ! grep -q 'empty hash' "$dir/log"; then
    fail_case "the failure did not name the empty hash: $(cat "$dir/log")"
else
    pass_case
fi

case_start 'the fingerprint config hash is part of the key'
dir="$(new_workspace "$ACTION" "$KEY_STEP")"
compose "$dir" "$FINGERPRINT" 'buildhash' 'config-before'
before="$(step_output "$dir" key)"
dir="$(new_workspace "$ACTION" "$KEY_STEP")"
compose "$dir" "$FINGERPRINT" 'buildhash' 'config-after'
after="$(step_output "$dir" key)"
if [ -z "$before" ] || [ -z "$after" ]; then
    fail_case "one of the two keys is empty (before='$before' after='$after')"
elif [ "$before" = "$after" ]; then
    fail_case "relaxing the fingerprint ignore list left the key at '$before', so every base published under the old list stays reachable"
else
    pass_case
fi

case_start 'the build action hash and the toolchain are part of the key'
dir="$(new_workspace "$ACTION" "$KEY_STEP")"
compose "$dir" "$FINGERPRINT" 'buildhash-before' 'confighash'
before="$(step_output "$dir" key)"
dir="$(new_workspace "$ACTION" "$KEY_STEP")"
compose "$dir" "$FINGERPRINT" 'buildhash-after' 'confighash'
after_build="$(step_output "$dir" key)"
dir="$(new_workspace "$ACTION" "$KEY_STEP")"
TOOLCHAIN='xcode-27.0.0-19A100' compose "$dir" "$FINGERPRINT" 'buildhash-before' 'confighash'
after_toolchain="$(step_output "$dir" key)"
if [ "$before" = "$after_build" ]; then
    fail_case 'a changed build action left the key where it was'
elif [ "$before" = "$after_toolchain" ]; then
    fail_case 'a changed toolchain left the key where it was'
else
    pass_case
fi

case_start 'the key carries the fingerprint it was composed from'
dir="$(new_workspace "$ACTION" "$KEY_STEP")"
compose "$dir" "$FINGERPRINT" 'buildhash' 'confighash'
assert_equals 0 "$STEP_STATUS" 'compose exit status' \
    && case "$(step_output "$dir" key)" in
        "${FINGERPRINT}-"????????????) pass_case ;;
        *) fail_case "key '$(step_output "$dir" key)' is not <fingerprint>-<12 hex>" ;;
    esac

case_start 'a missing fingerprint config warns and contributes none'
dir="$(identity_workspace)"
identity "$dir"
if [ "$STEP_STATUS" -ne 0 ]; then
    fail_case "a missing config failed the step instead of warning: $(cat "$dir/log")"
elif [ "$(step_output "$dir" config-hash)" != 'none' ]; then
    fail_case "config-hash is '$(step_output "$dir" config-hash)', expected 'none'"
elif ! grep -q '::warning::No fingerprint config' "$dir/log"; then
    fail_case "no warning named the missing config: $(cat "$dir/log")"
else
    pass_case
fi

case_start 'a present fingerprint config is hashed into the identity'
dir="$(identity_workspace)"
printf 'module.exports = { ignorePaths: ["ios"] }\n' > "$dir/work/fingerprint.config.js"
identity "$dir"
config_hash="$(step_output "$dir" config-hash)"
if [ "$STEP_STATUS" -ne 0 ]; then
    fail_case "the step failed: $(cat "$dir/log")"
elif [ "$config_hash" = 'none' ] || [ -z "$config_hash" ]; then
    fail_case "config-hash is '$config_hash', expected a digest"
else
    dir2="$(identity_workspace)"
    printf 'module.exports = { ignorePaths: ["ios", "android"] }\n' > "$dir2/work/fingerprint.config.js"
    identity "$dir2"
    if [ "$config_hash" = "$(step_output "$dir2" config-hash)" ]; then
        fail_case 'two different ignore lists hashed to the same value'
    else
        pass_case
    fi
fi

case_start 'a build action that is not there fails closed'
dir="$(identity_workspace)"
rm -rf "$dir/actions/build-ios-app"
identity "$dir"
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'the key was composed without the build-action component'
elif ! grep -q 'build-ios-app' "$dir/log"; then
    fail_case "the failure did not name the missing action: $(cat "$dir/log")"
else
    pass_case
fi

case_start 'the build-action hash covers every action the platform builds with'
dir="$(identity_workspace)"
identity "$dir"
ios_before="$(step_output "$dir" build-action-hash)"
dir="$(identity_workspace)"
printf 'xcode pin v2\n' > "$dir/actions/setup-xcode-pinned/action.yml"
identity "$dir"
ios_after="$(step_output "$dir" build-action-hash)"
dir="$(identity_workspace)"
PLATFORM=android identity "$dir"
android_hash="$(step_output "$dir" build-action-hash)"
if [ "$ios_before" = "$ios_after" ]; then
    fail_case 'a changed setup-xcode-pinned left the iOS build-action hash where it was'
elif [ "$ios_before" = "$android_hash" ]; then
    fail_case 'the iOS and Android build-action hashes are the same, so one platform can restore the other platform base'
else
    pass_case
fi

case_start 'an unsupported platform fails closed'
dir="$(identity_workspace)"
PLATFORM=windows identity "$dir"
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'an unsupported platform was accepted'
else
    assert_contains "$(cat "$dir/log")" "Unsupported platform 'windows'" 'error message' && pass_case
fi

finish_suite
