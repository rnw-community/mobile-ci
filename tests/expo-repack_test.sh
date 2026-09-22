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
    # GITHUB_WORKSPACE deliberately points somewhere else: this step runs in the
    # caller's own working directory, so a relative base-path must resolve
    # against that and not against the workspace variable.
    run_step "$dir" PLATFORM="$platform" BASE_PATH="$base" \
        ANDROID_BUILD_TOOLS_DIR='' ANDROID_BUILD_TOOLS_VERSION='' \
        ANDROID_SDK_ROOT='' ANDROID_HOME='' GITHUB_WORKSPACE="$dir/elsewhere"
}

# install_build_tools <sdk root> <version> [tool ...] — a build-tools directory
# laid out the way sdkmanager installs it, holding the named tools (both by
# default).
install_build_tools() {
    local sdk="$1" version="$2" tool
    shift 2
    [ "$#" -gt 0 ] || set -- apksigner zipalign
    mkdir -p "$sdk/build-tools/$version"
    for tool in "$@"; do
        printf '#!/bin/sh\nexit 0\n' > "$sdk/build-tools/$version/$tool"
        chmod +x "$sdk/build-tools/$version/$tool"
    done
}

# resolve_build_tools <workspace> <platform> [VAR=value ...] — the unpack step
# on a valid base with no build-tools directory configured, so the SDK the
# workflow installed is what decides.
resolve_build_tools() {
    local dir="$1" platform="$2"
    shift 2
    if [ "$platform" = android ]; then
        make_android_base "$dir" true
        base=base.apk
    else
        make_ios_base "$dir" true
        base=base.tar.gz
    fi
    run_step "$dir" PLATFORM="$platform" BASE_PATH="$base" \
        ANDROID_BUILD_TOOLS_DIR='' ANDROID_BUILD_TOOLS_VERSION='' \
        ANDROID_SDK_ROOT='' ANDROID_HOME='' "$@"
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

case_start 'a large APK listing does not read as a missing bundle'
dir="$(new_workspace "$ACTION" "$UNPACK_STEP")"
make_android_base "$dir" true
# The bundle is named first and tens of thousands of entries follow. A `grep -q`
# here would match, close the pipe, kill unzip with SIGPIPE, and - under
# pipefail - report the bundle as absent on exactly the large apps that have one.
# shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
stub "$dir" unzip '
printf "assets/index.android.bundle\n"
index=0
while [ "$index" -lt 60000 ]; do
    printf "res/drawable/padding-entry-with-a-long-enough-name-%06d.xml\n" "$index"
    index=$((index + 1))
done'
unpack "$dir" android base.apk
if [ "$STEP_STATUS" -ne 0 ]; then
    fail_case "a base whose listing is larger than a pipe buffer was refused: $(cat "$dir/log")"
else
    pass_case
fi

case_start 'a relative build-tools directory is resolved once, for both steps'
dir="$(new_workspace "$ACTION" "$UNPACK_STEP")"
make_android_base "$dir" true
mkdir -p "$dir/work/tools/build-tools"
install_build_tools "$dir/sdk" 35.0.0
run_step "$dir" PLATFORM=android BASE_PATH=base.apk \
    ANDROID_BUILD_TOOLS_DIR=tools/build-tools ANDROID_BUILD_TOOLS_VERSION=35.0.0 \
    ANDROID_SDK_ROOT="$dir/sdk" ANDROID_HOME='' GITHUB_WORKSPACE="$dir/elsewhere"
assert_equals 0 "$STEP_STATUS" 'unpack exit status' \
    && assert_equals "$dir/work/tools/build-tools" "$(step_output "$dir" build-tools-dir)" 'build-tools-dir (an explicit directory wins over the SDK)' \
    && pass_case

case_start 'with no SDK installed an empty build-tools directory stays empty so PATH still decides'
dir="$(new_workspace "$ACTION" "$UNPACK_STEP")"
resolve_build_tools "$dir" android
assert_equals 0 "$STEP_STATUS" 'unpack exit status' \
    && assert_equals '' "$(step_output "$dir" build-tools-dir)" 'build-tools-dir' \
    && pass_case

case_start 'the build-tools version the workflow installed is found under ANDROID_SDK_ROOT (#163)'
dir="$(new_workspace "$ACTION" "$UNPACK_STEP")"
install_build_tools "$dir/sdk" 34.0.0
install_build_tools "$dir/sdk" 35.0.0
resolve_build_tools "$dir" android ANDROID_SDK_ROOT="$dir/sdk" ANDROID_BUILD_TOOLS_VERSION=35.0.0
assert_equals 0 "$STEP_STATUS" "unpack exit status: $(cat "$dir/log")" \
    && assert_equals "$dir/sdk/build-tools/35.0.0" "$(step_output "$dir" build-tools-dir)" 'build-tools-dir' \
    && pass_case

case_start 'ANDROID_HOME stands in for an unset ANDROID_SDK_ROOT'
dir="$(new_workspace "$ACTION" "$UNPACK_STEP")"
install_build_tools "$dir/sdk" 35.0.0
resolve_build_tools "$dir" android ANDROID_HOME="$dir/sdk" ANDROID_BUILD_TOOLS_VERSION=35.0.0
assert_equals 0 "$STEP_STATUS" "unpack exit status: $(cat "$dir/log")" \
    && assert_equals "$dir/sdk/build-tools/35.0.0" "$(step_output "$dir" build-tools-dir)" 'build-tools-dir' \
    && pass_case

case_start 'with no version asked for, the newest installed build-tools is used'
dir="$(new_workspace "$ACTION" "$UNPACK_STEP")"
install_build_tools "$dir/sdk" 9.0.0
install_build_tools "$dir/sdk" 35.0.0
install_build_tools "$dir/sdk" 36.0.0 zipalign
resolve_build_tools "$dir" android ANDROID_SDK_ROOT="$dir/sdk"
assert_equals 0 "$STEP_STATUS" "unpack exit status: $(cat "$dir/log")" \
    && assert_equals "$dir/sdk/build-tools/35.0.0" "$(step_output "$dir" build-tools-dir)" 'build-tools-dir (newest holding both tools, compared as versions)' \
    && pass_case

case_start 'a build-tools version the SDK does not hold is a named error, not a bare apksigner'
dir="$(new_workspace "$ACTION" "$UNPACK_STEP")"
install_build_tools "$dir/sdk" 34.0.0
resolve_build_tools "$dir" android ANDROID_SDK_ROOT="$dir/sdk" ANDROID_BUILD_TOOLS_VERSION=35.0.0
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case "a missing build-tools version resolved to '$(step_output "$dir" build-tools-dir)'"
else
    assert_contains "$(cat "$dir/log")" "$dir/sdk/build-tools/35.0.0" 'error names the resolved path' && pass_case
fi

case_start 'a build-tools directory missing zipalign is refused before the repack runs'
dir="$(new_workspace "$ACTION" "$UNPACK_STEP")"
install_build_tools "$dir/sdk" 35.0.0 apksigner
resolve_build_tools "$dir" android ANDROID_SDK_ROOT="$dir/sdk" ANDROID_BUILD_TOOLS_VERSION=35.0.0
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'a build-tools directory with no zipalign was accepted'
else
    assert_contains "$(cat "$dir/log")" 'zipalign' 'error names the missing tool' && pass_case
fi

case_start 'an iOS repack never resolves Android build-tools'
dir="$(new_workspace "$ACTION" "$UNPACK_STEP")"
install_build_tools "$dir/sdk" 35.0.0
resolve_build_tools "$dir" ios ANDROID_SDK_ROOT="$dir/sdk" ANDROID_BUILD_TOOLS_VERSION=35.0.0
assert_equals 0 "$STEP_STATUS" 'unpack exit status' \
    && assert_equals '' "$(step_output "$dir" build-tools-dir)" 'build-tools-dir' \
    && pass_case

case_start 'a base that is not a file at all is refused'
dir="$(new_workspace "$ACTION" "$UNPACK_STEP")"
unpack "$dir" ios nothing-here.tar.gz
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'a missing base was accepted'
else
    pass_case
fi

PLUTIL_STEP='Provide plutil where the host has none'

# host_path_without_plutil <workspace> — a PATH holding only what the step
# needs and no plutil, so the case means the same on a Mac as on Linux.
host_path_without_plutil() {
    local dir="$1" tool
    mkdir -p "$dir/host-bin"
    for tool in bash env mkdir chmod rm cat python3; do
        ln -sf "$(command -v "$tool")" "$dir/host-bin/$tool"
    done
    printf '%s\n' "$dir/stub-bin:$dir/host-bin"
}

# provide_plutil <workspace> <platform> [VAR=value ...]
provide_plutil() {
    local dir="$1" platform="$2"
    shift 2
    run_step "$dir" PLATFORM="$platform" PATH="$(host_path_without_plutil "$dir")" "$@"
}

# write_plist <path> <xml1|binary1> — an Info.plist carrying every value type
# repack-app round-trips through plutil.
write_plist() {
    PLIST_PATH="$1" PLIST_FORMAT="$2" python3 - <<'PYTHON'
import datetime, os, plistlib
value = {
    'CFBundleIdentifier': 'com.example.app',
    'CFBundleShortVersionString': '1.4.0',
    'CFBundleVersion': '42',
    'LSRequiresIPhoneOS': True,
    'UIDeviceFamily': [1, 2],
    'MinimumOSVersion': '15.1',
    'Scale': 1.5,
    'Blob': b'\x00\x01binary',
    'Built': datetime.datetime(2026, 9, 23, 12, 0, 0),
    'EXUpdatesEnabled': False,
    'Nested': {'Inner': ['a', {'Deep': 7}]},
}
fmt = plistlib.FMT_XML if os.environ['PLIST_FORMAT'] == 'xml1' else plistlib.FMT_BINARY
with open(os.environ['PLIST_PATH'], 'wb') as handle:
    plistlib.dump(value, handle, fmt=fmt)
PYTHON
}

# plist_state <path> — "<format> <same content as write_plist: true|false>".
plist_state() {
    PLIST_PATH="$1" python3 - <<'PYTHON'
import datetime, os, plistlib
raw = open(os.environ['PLIST_PATH'], 'rb').read()
fmt = 'binary1' if raw.startswith(b'bplist00') else ('xml1' if raw.lstrip().startswith(b'<?xml') else 'unknown')
try:
    value = plistlib.loads(raw)
except Exception:
    value = None
expected = {
    'CFBundleIdentifier': 'com.example.app',
    'CFBundleShortVersionString': '1.4.0',
    'CFBundleVersion': '42',
    'LSRequiresIPhoneOS': True,
    'UIDeviceFamily': [1, 2],
    'MinimumOSVersion': '15.1',
    'Scale': 1.5,
    'Blob': b'\x00\x01binary',
    'Built': datetime.datetime(2026, 9, 23, 12, 0, 0),
    'EXUpdatesEnabled': False,
    'Nested': {'Inner': ['a', {'Deep': 7}]},
}
same = value == expected and all(type(value[k]) is type(expected[k]) for k in expected) if isinstance(value, dict) else False
print(f"{fmt} {'true' if same else 'false'}")
PYTHON
}

case_start 'an iOS repack on a host with no plutil is given one (#163)'
dir="$(new_workspace "$ACTION" "$PLUTIL_STEP")"
provide_plutil "$dir" ios
shim_dir="$(step_output "$dir" shim-dir)"
if [ "$STEP_STATUS" -ne 0 ]; then
    fail_case "the step failed: $(cat "$dir/log")"
elif [ -z "$shim_dir" ] || [ ! -x "$shim_dir/plutil" ]; then
    fail_case "no executable plutil was provided (shim-dir='$shim_dir')"
else
    pass_case
fi

case_start 'a host that has a real plutil keeps it'
dir="$(new_workspace "$ACTION" "$PLUTIL_STEP")"
stub "$dir" plutil 'exit 0'
provide_plutil "$dir" ios
assert_equals 0 "$STEP_STATUS" 'step exit status' \
    && assert_equals '' "$(step_output "$dir" shim-dir)" 'shim-dir' \
    && pass_case

case_start 'an Android repack is never given a plutil'
dir="$(new_workspace "$ACTION" "$PLUTIL_STEP")"
provide_plutil "$dir" android
assert_equals 0 "$STEP_STATUS" 'step exit status' \
    && assert_equals '' "$(step_output "$dir" shim-dir)" 'shim-dir' \
    && pass_case

# shim_workspace — a provided plutil, and its directory printed after the
# workspace on the same line.
shim_workspace() {
    local dir
    dir="$(new_workspace "$ACTION" "$PLUTIL_STEP")"
    provide_plutil "$dir" ios
    printf '%s %s\n' "$dir" "$(step_output "$dir" shim-dir)"
}

# run_shim <shim dir> <arguments ...> — the shim as @expo/repack-app spawns
# it; its output lands in $dir/shim.log, its status in SHIM_STATUS.
run_shim() {
    local shim_dir="$1"
    shift
    SHIM_STATUS=0
    "$shim_dir/plutil" "$@" > "$dir/shim.log" 2>&1 || SHIM_STATUS=$?
}

case_start 'plutil -convert xml1 decodes a binary Info.plist in place, keeping every value and type'
read -r dir shim_dir <<< "$(shim_workspace)"
write_plist "$dir/Info.plist" binary1
run_shim "$shim_dir" -convert xml1 "$dir/Info.plist"
assert_equals 0 "$SHIM_STATUS" "shim exit status: $(cat "$dir/shim.log")" \
    && assert_equals 'xml1 true' "$(plist_state "$dir/Info.plist")" 'converted plist' \
    && pass_case

case_start 'plutil -convert xml1 on an XML Info.plist leaves the same plist'
read -r dir shim_dir <<< "$(shim_workspace)"
write_plist "$dir/Info.plist" xml1
run_shim "$shim_dir" -convert xml1 "$dir/Info.plist"
assert_equals 0 "$SHIM_STATUS" "shim exit status: $(cat "$dir/shim.log")" \
    && assert_equals 'xml1 true' "$(plist_state "$dir/Info.plist")" 'converted plist' \
    && pass_case

case_start 'plutil -convert binary1 encodes an XML Info.plist in place, keeping every value and type'
read -r dir shim_dir <<< "$(shim_workspace)"
write_plist "$dir/Info.plist" xml1
run_shim "$shim_dir" -convert binary1 "$dir/Info.plist"
assert_equals 0 "$SHIM_STATUS" "shim exit status: $(cat "$dir/shim.log")" \
    && assert_equals 'binary1 true' "$(plist_state "$dir/Info.plist")" 'converted plist' \
    && pass_case

case_start 'plutil -convert binary1 on a binary Info.plist leaves the same plist'
read -r dir shim_dir <<< "$(shim_workspace)"
write_plist "$dir/Info.plist" binary1
run_shim "$shim_dir" -convert binary1 "$dir/Info.plist"
assert_equals 0 "$SHIM_STATUS" "shim exit status: $(cat "$dir/shim.log")" \
    && assert_equals 'binary1 true' "$(plist_state "$dir/Info.plist")" 'converted plist' \
    && pass_case

case_start 'any plutil use repack-app does not make fails loudly and leaves the file alone'
read -r dir shim_dir <<< "$(shim_workspace)"
write_plist "$dir/Info.plist" binary1
before="$(cksum < "$dir/Info.plist")"
problems=''
for invocation in '-lint' '-convert json' '-convert xml1 -o out.plist' '-extract CFBundleVersion raw' '-replace CFBundleVersion -string 43' '-p'; do
    # shellcheck disable=SC2086 # each invocation is a word list on purpose.
    run_shim "$shim_dir" $invocation "$dir/Info.plist"
    if [ "$SHIM_STATUS" -eq 0 ]; then
        problems="$problems '$invocation' succeeded;"
    elif ! grep -q 'not implemented' "$dir/shim.log"; then
        problems="$problems '$invocation' failed without naming why: $(cat "$dir/shim.log");"
    fi
done
if [ -n "$problems" ]; then
    fail_case "$problems"
else
    assert_equals "$before" "$(cksum < "$dir/Info.plist")" 'Info.plist after refused invocations' && pass_case
fi

case_start 'a file that is not a property list fails the conversion and is left alone'
read -r dir shim_dir <<< "$(shim_workspace)"
printf 'not a plist\n' > "$dir/Info.plist"
run_shim "$shim_dir" -convert xml1 "$dir/Info.plist"
if [ "$SHIM_STATUS" -eq 0 ]; then
    fail_case 'a malformed plist converted'
else
    assert_equals 'not a plist' "$(cat "$dir/Info.plist")" 'Info.plist' && pass_case
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
        PLUTIL_SHIM_DIR='' \
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

case_start 'the provided plutil is on the PATH @expo/repack-app spawns it from'
dir="$(repack_workspace)"
# shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
stub "$dir" npx '
command -v plutil > "$NPX_PLUTIL_FILE" || printf "none\n" > "$NPX_PLUTIL_FILE"
previous=""
for argument in "$@"; do
    if [ "$previous" = --output ]; then mkdir -p "$argument"; fi
    previous="$argument"
done'
mkdir -p "$dir/shim"
printf '#!/bin/sh\nexit 0\n' > "$dir/shim/plutil"
chmod +x "$dir/shim/plutil"
run_step "$dir" \
    PLATFORM=ios \
    SOURCE_APP="$dir/runner-temp/expo-repack/base/Base.app" \
    REPACK_VERSION=0.7.2 REPACK_ENV='' ANDROID_BUILD_TOOLS_DIR='' \
    KEYSTORE_PATH='' KEYSTORE_PASSWORD='' KEYSTORE_KEY_ALIAS='' KEYSTORE_KEY_PASSWORD='' \
    VERBOSE=false PLUTIL_SHIM_DIR="$dir/shim" NPX_PLUTIL_FILE="$dir/npx-plutil"
assert_equals 0 "$STEP_STATUS" "repack exit status: $(cat "$dir/log")" \
    && assert_equals "$dir/shim/plutil" "$(cat "$dir/npx-plutil")" 'plutil @expo/repack-app resolves' \
    && pass_case

# sign_workspace <bundled: true|false> — a repacked APK laid out where the
# verify step looks for it, with an apksigner stub whose reported certificate
# per APK comes from SIGNER_<basename> so base and repack can differ.
sign_workspace() {
    local dir bundled="$1"
    dir="$(new_workspace "$ACTION" "$SIGN_STEP")"
    mkdir -p "$dir/runner-temp/expo-repack/out" "$dir/runner-temp/expo-repack/base" "$dir/staging/assets"
    if [ "$bundled" = true ]; then
        printf 'var bundle = 1\n' > "$dir/staging/assets/index.android.bundle"
    else
        printf 'placeholder\n' > "$dir/staging/assets/placeholder"
    fi
    (cd "$dir/staging" && zip -q -r "$dir/runner-temp/expo-repack/out/base.apk" .)
    cp "$dir/runner-temp/expo-repack/out/base.apk" "$dir/runner-temp/expo-repack/base/base.apk"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" apksigner '
apk="${!#}"
case "$apk" in
    */out/*) digest="$REPACKED_DIGEST" ;;
    *) digest="$BASE_DIGEST" ;;
esac
if [ -z "$digest" ]; then exit 1; fi
echo "Signer #1 certificate DN: CN=Android Debug"
echo "Signer #1 certificate SHA-256 digest: $digest"
exit 0'
    printf '%s\n' "$dir"
}

verify() {
    local dir="$1"
    shift
    run_step "$dir" SOURCE_APP="$dir/runner-temp/expo-repack/base/base.apk" ANDROID_BUILD_TOOLS_DIR='' "$@"
}

case_start 'an unsigned repacked APK is refused'
dir="$(sign_workspace true)"
verify "$dir" REPACKED_DIGEST='' BASE_DIGEST=aa11
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'an APK apksigner rejected was handed on'
else
    pass_case
fi

case_start 'a repack signed by a different key than the base is refused'
dir="$(sign_workspace true)"
verify "$dir" REPACKED_DIGEST=bb22 BASE_DIGEST=aa11
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'an APK no device could install over the base was handed on; a valid signature is not the right signature'
else
    assert_contains "$(cat "$dir/log")" 'signed by a different certificate' 'error message' && pass_case
fi

case_start 'a repack signed with the base key and keeping its bundle passes'
dir="$(sign_workspace true)"
verify "$dir" REPACKED_DIGEST=aa11 BASE_DIGEST=aa11
assert_equals 0 "$STEP_STATUS" 'verify exit status' && pass_case

case_start 'a correctly signed APK that lost its bundle is refused'
dir="$(sign_workspace false)"
verify "$dir" REPACKED_DIGEST=aa11 BASE_DIGEST=aa11
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
