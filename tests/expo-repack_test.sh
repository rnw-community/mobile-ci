#!/usr/bin/env bash
# A repack is only trustworthy because of what it refuses: a base whose
# JavaScript comes from a dev server, a binary whose embedded config nobody
# checked, and an APK nothing signed. Those refusals are what is tested here.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/expo-repack/action.yml"
UNPACK_STEP='Unpack the base binary'
ASSERT_STEP="Assert the repacked binary carries this build's config"
SIGN_STEP="Verify the repacked APK's signature"
PACKAGE_STEP='Package the repacked binary'
APP_ID='com.example.app'

# make_ios_base <workspace> <with bundle: true|false>
make_ios_base() {
    local dir="$1" with_bundle="$2" staging="$1/staging"
    rm -rf "$staging"
    mkdir -p "$staging/Base.app"
    printf 'binary\n' > "$staging/Base.app/Base"
    if [ "$with_bundle" = true ]; then
        printf 'var bundle = 1\n' > "$staging/Base.app/main.jsbundle"
    fi
    tar -czf "$dir/work/base.tar.gz" -C "$staging" Base.app
}

# make_android_base <workspace> <with bundle: true|false>
make_android_base() {
    local dir="$1" with_bundle="$2" staging="$1/staging"
    rm -rf "$staging"
    mkdir -p "$staging/assets"
    printf 'manifest\n' > "$staging/AndroidManifest.xml"
    if [ "$with_bundle" = true ]; then
        printf 'var bundle = 1\n' > "$staging/assets/index.android.bundle"
    else
        printf 'placeholder\n' > "$staging/assets/placeholder"
    fi
    (cd "$staging" && zip -q -r "$dir/work/base.apk" .)
}

unpack() {
    local dir="$1" platform="$2" base="$3"
    run_step "$dir" PLATFORM="$platform" BASE_PATH="$base"
}

case_start 'an iOS base with no embedded bundle is refused'
dir="$(new_workspace "$ACTION" "$UNPACK_STEP")"
make_ios_base "$dir" false
unpack "$dir" ios base.tar.gz
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'a Debug .app was accepted as a base'
else
    assert_contains "$(cat "$dir/log")" 'no embedded main.jsbundle' 'error message' && pass_case
fi

case_start 'an iOS base with an embedded bundle is accepted'
dir="$(new_workspace "$ACTION" "$UNPACK_STEP")"
make_ios_base "$dir" true
unpack "$dir" ios base.tar.gz
assert_equals 0 "$STEP_STATUS" 'unpack exit status' \
    && assert_contains "$(step_output "$dir" source-app)" 'Base.app' 'source-app' \
    && pass_case

case_start 'an APK with no embedded bundle is refused'
dir="$(new_workspace "$ACTION" "$UNPACK_STEP")"
make_android_base "$dir" false
unpack "$dir" android base.apk
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'a Debug APK was accepted as a base'
else
    assert_contains "$(cat "$dir/log")" 'no embedded assets/index.android.bundle' 'error message' && pass_case
fi

case_start 'an APK with an embedded bundle is accepted'
dir="$(new_workspace "$ACTION" "$UNPACK_STEP")"
make_android_base "$dir" true
unpack "$dir" android base.apk
assert_equals 0 "$STEP_STATUS" 'unpack exit status' \
    && assert_equals "$dir/work/base.apk" "$(cd "$dir/work" && readlink -f "$(step_output "$dir" source-app)")" 'source-app' \
    && pass_case

case_start 'a base that is not a file at all is refused'
dir="$(new_workspace "$ACTION" "$UNPACK_STEP")"
unpack "$dir" ios nothing-here.tar.gz
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'a missing base was accepted'
else
    pass_case
fi

# assert_workspace <embedded app.config json> — an iOS repack output laid out
# the way the repack step leaves it, so the assertion step reads a real file.
assert_workspace() {
    local dir config
    dir="$(new_workspace "$ACTION" "$ASSERT_STEP")"
    config="$dir/runner-temp/expo-repack/out/Base.app/EXConstants.bundle"
    mkdir -p "$config"
    printf '%s' "$1" > "$config/app.config"
    printf '%s\n' "$dir"
}

run_assert() {
    local dir="$1" expect="$2"
    run_step "$dir" \
        PLATFORM=ios \
        SOURCE_APP="$dir/runner-temp/expo-repack/base/Base.app" \
        APP_ID="$APP_ID" \
        EXPECT_CONFIG="$expect"
}

CONFIG='{"version":"1.4.0","ios":{"bundleIdentifier":"com.example.app","buildNumber":"42"},"extra":{"apiUrl":"https://staging.example.com"}}'

case_start 'every assertion holding passes'
dir="$(assert_workspace "$CONFIG")"
run_assert "$dir" 'version=1.4.0
extra.apiUrl=https://staging.example.com
ios.buildNumber=42'
assert_equals 0 "$STEP_STATUS" 'assert exit status' \
    && assert_contains "$(cat "$dir/log")" 'satisfies 4 assertion(s)' 'summary line' \
    && pass_case

case_start 'a config value the repack did not rewrite fails the build'
dir="$(assert_workspace "$CONFIG")"
run_assert "$dir" 'version=1.5.0'
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'a stale version passed the assertion'
else
    assert_contains "$(cat "$dir/log")" 'version is "1.4.0", expected "1.5.0"' 'error message' && pass_case
fi

case_start 'an assertion on a path the config does not carry fails the build'
dir="$(assert_workspace "$CONFIG")"
run_assert "$dir" 'extra.featureBranch=https://pr-1.example.com'
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'an absent config path passed the assertion'
else
    assert_contains "$(cat "$dir/log")" 'is absent from the embedded app.config' 'error message' && pass_case
fi

case_start 'the wrong app ends up asserted as the wrong app'
dir="$(assert_workspace "$CONFIG")"
run_step "$dir" PLATFORM=ios SOURCE_APP="$dir/runner-temp/expo-repack/base/Base.app" \
    APP_ID='com.example.other' EXPECT_CONFIG=''
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'a binary carrying another bundle identifier passed'
else
    assert_contains "$(cat "$dir/log")" 'ios.bundleIdentifier' 'error message' && pass_case
fi

case_start 'a repacked binary with no embedded app.config is refused'
dir="$(new_workspace "$ACTION" "$ASSERT_STEP")"
mkdir -p "$dir/runner-temp/expo-repack/out/Base.app"
run_assert "$dir" ''
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'a binary whose rewrite could not be checked was accepted'
else
    assert_contains "$(cat "$dir/log")" 'embeds no app.config' 'error message' && pass_case
fi

REPACK_STEP="Repack the base binary with this build's JavaScript"

# repack_workspace — stubs npx so the argument vector handed to
# @expo/repack-app is what gets asserted, and creates the output it promises.
repack_workspace() {
    local dir
    dir="$(new_workspace "$ACTION" "$REPACK_STEP")"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" npx '
printf "%s\n" "$@" > "$NPX_ARGS_FILE"
output=""
previous=""
for argument in "$@"; do
    if [ "$previous" = --output ]; then output="$argument"; fi
    previous="$argument"
done
mkdir -p "$output"
exit 0'
    mkdir -p "$dir/work/apps/mobile/android/app"
    printf 'keystore\n' > "$dir/work/apps/mobile/android/app/debug.keystore"
    printf '%s\n' "$dir"
}

repack() {
    local dir="$1" keystore="$2"
    run_step "$dir" \
        PLATFORM=android \
        SOURCE_APP="$dir/runner-temp/expo-repack/base/base.apk" \
        REPACK_VERSION=0.7.2 \
        REPACK_ENV='' \
        ANDROID_BUILD_TOOLS_DIR='' \
        KEYSTORE_PATH="$keystore" \
        KEYSTORE_PASSWORD=android \
        KEYSTORE_KEY_ALIAS=androiddebugkey \
        KEYSTORE_KEY_PASSWORD=android \
        VERBOSE=false \
        GITHUB_WORKSPACE="$dir/work" \
        NPX_ARGS_FILE="$dir/npx-args"
}

case_start 'a repository-relative keystore is resolved once, not twice'
dir="$(repack_workspace)"
repack "$dir" 'apps/mobile/android/app/debug.keystore'
if [ "$STEP_STATUS" -ne 0 ]; then
    fail_case "the repack failed: $(cat "$dir/log")"
else
    signed_with="$(grep -A1 -Fx -- '--ks' "$dir/npx-args" | tail -1)"
    assert_equals "$dir/work/apps/mobile/android/app/debug.keystore" "$signed_with" 'keystore handed to @expo/repack-app' \
        && pass_case
fi

case_start 'an absolute keystore path is left alone'
dir="$(repack_workspace)"
repack "$dir" "$dir/work/apps/mobile/android/app/debug.keystore"
if [ "$STEP_STATUS" -ne 0 ]; then
    fail_case "the repack failed: $(cat "$dir/log")"
else
    signed_with="$(grep -A1 -Fx -- '--ks' "$dir/npx-args" | tail -1)"
    assert_equals "$dir/work/apps/mobile/android/app/debug.keystore" "$signed_with" 'keystore handed to @expo/repack-app' \
        && pass_case
fi

case_start 'a keystore that is not there fails before the repack runs'
dir="$(repack_workspace)"
repack "$dir" 'apps/mobile/android/app/missing.keystore'
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'the repack ran with a keystore that does not exist'
elif [ -f "$dir/npx-args" ]; then
    fail_case 'the repack was invoked before the keystore was checked'
else
    assert_contains "$(cat "$dir/log")" 'No keystore at' 'error message' && pass_case
fi

case_start 'an unsigned repacked APK is refused'
dir="$(new_workspace "$ACTION" "$SIGN_STEP")"
out="$dir/runner-temp/expo-repack/out"
mkdir -p "$out" "$dir/staging/assets"
printf 'var bundle = 1\n' > "$dir/staging/assets/index.android.bundle"
(cd "$dir/staging" && zip -q -r "$out/base.apk" .)
stub "$dir" apksigner 'echo "jar signature not found" >&2; exit 1'
run_step "$dir" SOURCE_APP="$dir/runner-temp/expo-repack/base/base.apk" ANDROID_BUILD_TOOLS_DIR=''
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'an APK apksigner rejected was handed on'
else
    pass_case
fi

case_start 'a signed repacked APK that kept its bundle passes'
dir="$(new_workspace "$ACTION" "$SIGN_STEP")"
out="$dir/runner-temp/expo-repack/out"
mkdir -p "$out" "$dir/staging/assets"
printf 'var bundle = 1\n' > "$dir/staging/assets/index.android.bundle"
(cd "$dir/staging" && zip -q -r "$out/base.apk" .)
stub "$dir" apksigner 'echo "Signer #1 certificate DN: CN=Android Debug"; exit 0'
run_step "$dir" SOURCE_APP="$dir/runner-temp/expo-repack/base/base.apk" ANDROID_BUILD_TOOLS_DIR=''
assert_equals 0 "$STEP_STATUS" 'verify exit status' && pass_case

case_start 'a signed APK that lost its bundle is refused'
dir="$(new_workspace "$ACTION" "$SIGN_STEP")"
out="$dir/runner-temp/expo-repack/out"
mkdir -p "$out" "$dir/staging/assets"
printf 'placeholder\n' > "$dir/staging/assets/placeholder"
(cd "$dir/staging" && zip -q -r "$out/base.apk" .)
stub "$dir" apksigner 'exit 0'
run_step "$dir" SOURCE_APP="$dir/runner-temp/expo-repack/base/base.apk" ANDROID_BUILD_TOOLS_DIR=''
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'an APK with no JavaScript bundle was handed on'
else
    assert_contains "$(cat "$dir/log")" 'lost its embedded JavaScript bundle' 'error message' && pass_case
fi

case_start 'an apksigner that is not installed is a named error, not a skipped check'
dir="$(new_workspace "$ACTION" "$SIGN_STEP")"
out="$dir/runner-temp/expo-repack/out"
mkdir -p "$out"
printf 'apk\n' > "$out/base.apk"
run_step "$dir" SOURCE_APP="$dir/runner-temp/expo-repack/base/base.apk" \
    ANDROID_BUILD_TOOLS_DIR="$dir/no-such-build-tools"
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'the signature check was skipped because the tool was missing'
else
    assert_contains "$(cat "$dir/log")" 'apksigner was not found' 'error message' && pass_case
fi

case_start 'the iOS repack round-trips back into the tarball the test job unpacks'
dir="$(new_workspace "$ACTION" "$PACKAGE_STEP")"
out="$dir/runner-temp/expo-repack/out/Base.app"
mkdir -p "$out"
printf 'binary\n' > "$out/Base"
printf 'var repacked = 1\n' > "$out/main.jsbundle"
run_step "$dir" PLATFORM=ios SOURCE_APP="$dir/runner-temp/expo-repack/base/Base.app" \
    OUTPUT_PATH=.ci-artifacts/ios-e2e-app-bare.tar.gz
if [ "$STEP_STATUS" -ne 0 ]; then
    fail_case "packaging failed: $(cat "$dir/log")"
else
    mkdir -p "$dir/unpacked"
    tar -xzf "$dir/work/.ci-artifacts/ios-e2e-app-bare.tar.gz" -C "$dir/unpacked"
    if [ ! -f "$dir/unpacked/Base.app/main.jsbundle" ]; then
        fail_case 'the tarball does not hold Base.app/main.jsbundle'
    elif [ "$(cat "$dir/unpacked/Base.app/main.jsbundle")" != 'var repacked = 1' ]; then
        fail_case 'the tarball carries the base bundle, not the repacked one'
    else
        assert_equals '.ci-artifacts/ios-e2e-app-bare.tar.gz' "$(step_output "$dir" app-path)" 'app-path' && pass_case
    fi
fi

case_start 'an iOS repack that lost its bundle is never packaged'
dir="$(new_workspace "$ACTION" "$PACKAGE_STEP")"
mkdir -p "$dir/runner-temp/expo-repack/out/Base.app"
run_step "$dir" PLATFORM=ios SOURCE_APP="$dir/runner-temp/expo-repack/base/Base.app" \
    OUTPUT_PATH=.ci-artifacts/ios-e2e-app-bare.tar.gz
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'an .app with no main.jsbundle was packaged for the test job'
else
    pass_case
fi

case_start 'the Android repack is copied to the path the test job installs from'
dir="$(new_workspace "$ACTION" "$PACKAGE_STEP")"
mkdir -p "$dir/runner-temp/expo-repack/out"
printf 'repacked apk\n' > "$dir/runner-temp/expo-repack/out/base.apk"
run_step "$dir" PLATFORM=android SOURCE_APP="$dir/runner-temp/expo-repack/base/base.apk" \
    OUTPUT_PATH=.ci-artifacts/android-e2e-app-bare/app-release.apk
assert_equals 0 "$STEP_STATUS" 'packaging exit status' \
    && assert_equals 'repacked apk' "$(cat "$dir/work/.ci-artifacts/android-e2e-app-bare/app-release.apk")" 'packaged APK' \
    && pass_case

finish_suite
