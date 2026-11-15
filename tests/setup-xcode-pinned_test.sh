#!/usr/bin/env bash
# setup-xcode-pinned selects an exact Xcode version and build. Issue #357: an
# image that ships one Xcode at /Applications/Xcode.app, already selected, had
# no /Applications/Xcode_<version>.app and failed although it was the very
# Xcode asked for. The selected Xcode is accepted only on an exact match.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/setup-xcode-pinned/action.yml"
STEP='Select and assert Xcode toolchain'
VERSION='99.9.1'
BUILD='99Z999'

# prepare <selected xcodebuild -version output, or empty for no selected Xcode>
prepare() {
    local version_output="$1" dir developer_dir
    dir="$(new_workspace "$ACTION" "$STEP")"
    developer_dir="$dir/Xcode.app/Contents/Developer"
    if [ -n "$version_output" ]; then
        mkdir -p "$developer_dir/usr/bin"
        printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q\n' "$version_output" > "$developer_dir/usr/bin/xcodebuild"
        chmod +x "$developer_dir/usr/bin/xcodebuild"
        stub "$dir" xcode-select "echo '$developer_dir'"
    else
        stub "$dir" xcode-select 'echo "xcode-select: error: unable to get active developer directory" >&2; exit 2'
    fi
    printf '%s\n' "$dir"
}

invoke() {
    run_step "$1" XCODE_VERSION="$VERSION" XCODE_BUILD="$BUILD"
}

case_start 'a missing versioned install falls back to the selected Xcode when version and build match'
workspace="$(prepare "Xcode $VERSION
Build version $BUILD")"
invoke "$workspace"
developer_dir="$workspace/Xcode.app/Contents/Developer"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/env")" "DEVELOPER_DIR=$developer_dir" 'exported DEVELOPER_DIR' \
    && assert_equals "$developer_dir" "$(step_output "$workspace" developer-dir)" 'developer-dir output' \
    && assert_equals "xcode-$VERSION-$BUILD" "$(step_output "$workspace" toolchain-key)" 'toolchain-key output' \
    && assert_contains "$(cat "$workspace/log")" "/Applications/Xcode_$VERSION.app" 'the missing path is named'; then
    pass_case
fi

case_start 'a selected Xcode with another build fails closed and exports nothing'
workspace="$(prepare "Xcode $VERSION
Build version 99Z998")"
invoke "$workspace"
log="$(cat "$workspace/log")"
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$log" '::error::' 'error annotation' \
    && assert_contains "$log" "Build version $BUILD" 'the wanted build is named' \
    && assert_equals '' "$(cat "$workspace/env")" 'GITHUB_ENV' \
    && assert_equals '' "$(cat "$workspace/outputs")" 'GITHUB_OUTPUT'; then
    pass_case
fi

case_start 'a selected Xcode with another version fails closed'
workspace="$(prepare "Xcode 99.9
Build version $BUILD")"
invoke "$workspace"
log="$(cat "$workspace/log")"
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$log" "::error::" 'error annotation' \
    && assert_contains "$log" "Xcode $VERSION" 'the wanted version is named' \
    && assert_equals '' "$(cat "$workspace/env")" 'GITHUB_ENV'; then
    pass_case
fi

case_start 'no versioned install and no selected Xcode fails closed'
workspace="$(prepare '')"
invoke "$workspace"
log="$(cat "$workspace/log")"
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$log" '::error::' 'error annotation' \
    && assert_contains "$log" "/Applications/Xcode_$VERSION.app" 'the missing path is named' \
    && assert_equals '' "$(cat "$workspace/env")" 'GITHUB_ENV'; then
    pass_case
fi

case_start 'the version and build are compared literally, not as patterns'
workspace="$(prepare "Xcode 99x9x1
Build version $BUILD")"
invoke "$workspace"
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_equals '' "$(cat "$workspace/env")" 'GITHUB_ENV'; then
    pass_case
fi

finish_suite
