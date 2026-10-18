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
        IOS_SIMULATOR_ARCHS=arm64 \
        SECRETS_DIGEST='' \
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

case_start 'no secrets digest leaves every existing key exactly where it was'
dir="$(new_workspace "$ACTION" "$KEY_STEP")"
compose "$dir" "$FINGERPRINT" 'buildhash' 'confighash' SECRETS_DIGEST=''
expected_identity="$(printf '%s\n' ios e2e 'xcode-26.4.1-17E202' buildhash confighash | sha256sum | cut -c1-12)"
assert_equals 0 "$STEP_STATUS" 'compose exit status' \
    && assert_equals "${FINGERPRINT}-${expected_identity}" "$(step_output "$dir" key)" 'key without secrets' \
    && pass_case

case_start 'with no secrets the key is byte-identical to the keys main published bases under'
# Golden keys computed with origin/main's (pre-secrets) compose step for these
# exact inputs. A drift here orphans every base already published.
golden_ok=1
for golden in \
    'ios arm64 0123456789abcdef0123456789abcdef01234567-a731cde412a7' \
    'ios x86_64 0123456789abcdef0123456789abcdef01234567-f685f9d47926' \
    'android arm64 0123456789abcdef0123456789abcdef01234567-8608e8919356'; do
    read -r golden_platform golden_archs golden_key <<< "$golden"
    dir="$(new_workspace "$ACTION" "$KEY_STEP")"
    PLATFORM="$golden_platform" TOOLCHAIN='xcode-26.4.1-17E202-MyApp.xcworkspace-MyApp' \
        compose "$dir" 0123456789abcdef0123456789abcdef01234567 buildhash confighash \
        IOS_SIMULATOR_ARCHS="$golden_archs" SECRETS_DIGEST=''
    if ! assert_equals "$golden_key" "$(step_output "$dir" key)" "$golden_platform/$golden_archs key"; then
        golden_ok=0
        break
    fi
done
[ "$golden_ok" -eq 1 ] && pass_case

case_start 'a rotated build secret moves the key, through its digest alone'
digest_a="$(printf 'a' | sha256sum | cut -d' ' -f1)"
digest_b="$(printf 'b' | sha256sum | cut -d' ' -f1)"
dir="$(new_workspace "$ACTION" "$KEY_STEP")"
compose "$dir" "$FINGERPRINT" 'buildhash' 'confighash' SECRETS_DIGEST=''
without="$(step_output "$dir" key)"
dir="$(new_workspace "$ACTION" "$KEY_STEP")"
compose "$dir" "$FINGERPRINT" 'buildhash' 'confighash' SECRETS_DIGEST="$digest_a"
with_a="$(step_output "$dir" key)"
dir="$(new_workspace "$ACTION" "$KEY_STEP")"
compose "$dir" "$FINGERPRINT" 'buildhash' 'confighash' SECRETS_DIGEST="$digest_b"
with_b="$(step_output "$dir" key)"
if [ -z "$with_a" ] || [ "$with_a" = "$without" ]; then
    fail_case "a secrets digest left the key at '$without'"
elif [ "$with_a" = "$with_b" ]; then
    fail_case 'two different secrets digests gave the same key, so a rotated Maps key repacks onto a base compiled with the old one'
else
    assert_not_contains "$(cat "$dir/log")" "$digest_b" 'the digest is not logged' && pass_case
fi

case_start 'a secrets digest that is not a SHA-256 is refused, since it may be a secret value'
dir="$(new_workspace "$ACTION" "$KEY_STEP")"
compose "$dir" "$FINGERPRINT" 'buildhash' 'confighash' SECRETS_DIGEST='AIzaSyPlainTextKey'
assert_equals 1 "$STEP_STATUS" 'compose exit status' \
    && assert_not_contains "$(cat "$dir/outputs")" 'key=' 'no key is written' \
    && pass_case

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

# Captured from the compose step as it stood before ios-simulator-archs
# existed (v4.0.0). Every base already published is addressed by a key
# composed this way, so the default must keep reproducing it byte for byte.
GOLDEN_IOS_KEY='abc123def456-2ff4aed6e7eb'
GOLDEN_ANDROID_KEY='abc123def456-4a6473419d68'

case_start 'the default arm64 simulator key is byte-identical to the pre-archs key'
dir="$(new_workspace "$ACTION" "$KEY_STEP")"
compose "$dir" "$FINGERPRINT" 'buildhash' 'confighash' IOS_SIMULATOR_ARCHS=arm64
ios_key="$(step_output "$dir" key)"
dir="$(new_workspace "$ACTION" "$KEY_STEP")"
PLATFORM=android TOOLCHAIN=cmdline-12266719-assembleRelease \
    compose "$dir" "$FINGERPRINT" 'buildhash' 'confighash' IOS_SIMULATOR_ARCHS=arm64
android_key="$(step_output "$dir" key)"
if assert_equals "$GOLDEN_IOS_KEY" "$ios_key" "arm64 iOS key ($(cat "$dir/log"))" \
    && assert_equals "$GOLDEN_ANDROID_KEY" "$android_key" 'Android key'; then
    pass_case
fi

case_start 'an x86_64 simulator base never shares a key with the arm64 one'
dir="$(new_workspace "$ACTION" "$KEY_STEP")"
compose "$dir" "$FINGERPRINT" 'buildhash' 'confighash' IOS_SIMULATOR_ARCHS=x86_64
x86_key="$(step_output "$dir" key)"
if [ "$STEP_STATUS" -ne 0 ]; then
    fail_case "x86_64 was rejected: $(cat "$dir/log")"
elif [ "$x86_key" = "$GOLDEN_IOS_KEY" ]; then
    fail_case "x86_64 and arm64 bases both resolve to '$x86_key', so a pull request can repack onto a binary its test host cannot run"
else
    case "$x86_key" in
        "${FINGERPRINT}-"????????????) pass_case ;;
        *) fail_case "key '$x86_key' is not <fingerprint>-<12 hex>" ;;
    esac
fi

case_start 'ios-simulator-archs does not move an Android key'
dir="$(new_workspace "$ACTION" "$KEY_STEP")"
PLATFORM=android TOOLCHAIN=cmdline-12266719-assembleRelease \
    compose "$dir" "$FINGERPRINT" 'buildhash' 'confighash' IOS_SIMULATOR_ARCHS=x86_64
if assert_equals "$GOLDEN_ANDROID_KEY" "$(step_output "$dir" key)" "Android key ($(cat "$dir/log"))"; then
    pass_case
fi

case_start 'an ios-simulator-archs other than arm64 or x86_64 fails closed'
rejected=''
for archs in '' 'i386' 'arm64 x86_64' 'ARM64' 'x86_64,arm64'; do
    dir="$(new_workspace "$ACTION" "$KEY_STEP")"
    compose "$dir" "$FINGERPRINT" 'buildhash' 'confighash' IOS_SIMULATOR_ARCHS="$archs"
    if [ "$STEP_STATUS" -eq 0 ] || ! grep -q "ios-simulator-archs" "$dir/log"; then
        rejected="$rejected '$archs'"
    fi
done
if assert_equals '' "$rejected" 'values accepted or rejected without naming the input'; then
    pass_case
fi

finish_suite
