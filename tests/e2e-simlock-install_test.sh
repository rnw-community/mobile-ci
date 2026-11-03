#!/usr/bin/env bash
# @mobile-ci/e2e-simlock ships inside this repository, not on npm. The
# e2e-simlock-install action copies packages/e2e-simlock from its own ref into
# an e2e project's node_modules, and scripts/fetch-e2e-simlock.sh does the same
# from a pinned tag for local runs. Both copy exactly what package.json ships,
# replace an earlier copy, and fail closed before an install that would wipe it.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/e2e-simlock-install/action.yml"
SCRIPT="$REPO_ROOT/scripts/fetch-e2e-simlock.sh"
PACKAGE="$REPO_ROOT/packages/e2e-simlock"

# shipped <dir>: the files under an installed copy, relative to it, sorted.
shipped() {
    (cd "$1" && find . -type f -not -path './node_modules/*' | sed 's|^\./||' | LC_ALL=C sort)
}

expected="$(cd "$PACKAGE" && { echo package.json; jq -r '.files[]' package.json | while read -r entry; do find "$entry" -type f; done; } | LC_ALL=C sort)"

action_workspace() {
    dir="$(new_workspace "$ACTION" "Install @mobile-ci/e2e-simlock from this action's ref")"
}

install_with_action() {
    run_step "$dir" GITHUB_ACTION_PATH="$REPO_ROOT/actions/e2e-simlock-install" "$@"
}

case_start 'the action installs exactly what package.json ships, from its own ref, keeping the E2EDrop executable'
action_workspace
mkdir -p "$dir/work/e2e/node_modules"
install_with_action E2E_DIR=e2e
dest="$dir/work/e2e/node_modules/@mobile-ci/e2e-simlock"
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))" \
    && assert_equals "$expected" "$(shipped "$dest")" 'files' \
    && assert_equals '@mobile-ci/e2e-simlock' "$(jq -r .name "$dest/package.json")" 'name' \
    && assert_equals yes "$([ -x "$dest/e2e-drop/E2EDrop.app/E2EDrop" ] && echo yes || echo no)" 'executable' \
    && assert_contains "$(cat "$dir/log")" "Installed @mobile-ci/e2e-simlock into e2e/node_modules/@mobile-ci/e2e-simlock." 'log'; then
    pass_case
fi

case_start 'the action fails closed when the e2e project has no node_modules yet'
action_workspace
install_with_action E2E_DIR=e2e
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$dir/log")" "e2e-simlock: 'e2e' has no node_modules; install the e2e project's dependencies first, or its install would wipe the package." 'error' \
    && assert_equals no "$([ -e "$dir/work/e2e/node_modules" ] && echo yes || echo no)" 'nothing created'; then
    pass_case
fi

# shellcheck source=/dev/null
. "$SCRIPT"

case_start 'a reinstall replaces an earlier copy, leaving no stale file behind'
work="$(new_empty_workspace)"
mkdir -p "$work/e2e/node_modules/@mobile-ci/e2e-simlock/src"
: > "$work/e2e/node_modules/@mobile-ci/e2e-simlock/src/stale.ts"
if e2e_simlock_install "$PACKAGE" "$work/e2e" > "$work/log" 2>&1 \
    && assert_equals "$expected" "$(shipped "$work/e2e/node_modules/@mobile-ci/e2e-simlock")" 'files'; then
    pass_case
fi

case_start 'a package directory that is not the package, or lacks a file it ships, fails closed'
work="$(new_empty_workspace)"
mkdir -p "$work/e2e/node_modules" "$work/pkg"
status=0
e2e_simlock_install "$work/nowhere" "$work/e2e" 2> "$work/missing" || status=$?
printf '{"files":["src"]}' > "$work/pkg/package.json"
e2e_simlock_install "$work/pkg" "$work/e2e" 2> "$work/partial" || status="$status$?"
if assert_equals 11 "$status" 'statuses' \
    && assert_equals "e2e-simlock: no package at '$work/nowhere' (expected packages/e2e-simlock of rnw-community/mobile-ci)." "$(cat "$work/missing")" 'missing' \
    && assert_equals "e2e-simlock: '$work/pkg' lacks 'src', which its package.json ships." "$(cat "$work/partial")" 'partial'; then
    pass_case
fi

case_start 'without a working jq the action fails closed and leaves an earlier copy alone, not an empty package'
action_workspace
mkdir -p "$dir/work/e2e/node_modules/@mobile-ci/e2e-simlock"
: > "$dir/work/e2e/node_modules/@mobile-ci/e2e-simlock/earlier"
stub "$dir" jq 'exit 127'
install_with_action E2E_DIR=e2e
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$dir/log")" 'is jq installed?' 'log' \
    && assert_not_contains "$(cat "$dir/log")" 'Installed @mobile-ci/e2e-simlock' 'log' \
    && assert_equals earlier "$(ls "$dir/work/e2e/node_modules/@mobile-ci/e2e-simlock")" 'earlier copy'; then
    pass_case
fi

# fetch <ref> [VAR=value ...]: runs the script with curl serving a tarball of this checkout.
fetch() {
    local ref="$1"
    shift
    work="$(new_empty_workspace)"
    mkdir -p "$work/e2e/node_modules" "$work/archive/mobile-ci-x/packages"
    cp -R "$PACKAGE" "$work/archive/mobile-ci-x/packages/e2e-simlock"
    rm -rf "$work/archive/mobile-ci-x/packages/e2e-simlock/node_modules"
    tar -czf "$work/repo.tar.gz" -C "$work/archive" mobile-ci-x
    # shellcheck disable=SC2016 # expanded when the stub runs.
    stub "$work" curl 'printf "%s\n" "$*" > "$(dirname "$0")/../curl-args"; [ -z "${CURL_FAIL:-}" ] || exit 22; cat "$(dirname "$0")/../repo.tar.gz"'
    status=0
    (cd "$work" && env PATH="$work/stub-bin:$PATH" TMPDIR="$work" "$@" bash "$SCRIPT" "$ref" e2e) > "$work/log" 2>&1 || status=$?
}

case_start 'the script fetches the package at a pinned tag, and cleans up its download'
fetch v4.9.0
if assert_equals 0 "$status" "status ($(cat "$work/log"))" \
    && assert_equals '-fsSL https://codeload.github.com/rnw-community/mobile-ci/tar.gz/v4.9.0' "$(cat "$work/curl-args")" 'url' \
    && assert_equals "$expected" "$(shipped "$work/e2e/node_modules/@mobile-ci/e2e-simlock")" 'files' \
    && assert_equals '' "$(find "$work" -maxdepth 1 -name 'mobile-ci-e2e-simlock-*')" 'scratch removed'; then
    pass_case
fi

case_start 'the script takes a full commit SHA and refuses a floating ref'
fetch 3e22c383f15427da8e9b5e211701f133cc111535
sha="$status"
for ref in v4 main v4.9 3e22c38 'v4.9.0;rm'; do
    fetch "$ref"
    assert_equals 1 "$status" "status for $ref" || break
done
if assert_equals 0 "$sha" 'sha status' \
    && assert_equals "e2e-simlock: pin a release tag (vX.Y.Z) or a full commit SHA; got 'v4.9.0;rm'." "$(cat "$work/log")" 'error' \
    && assert_equals no "$([ -e "$work/curl-args" ] && echo yes || echo no)" 'nothing fetched'; then
    pass_case
fi

case_start 'the script fails closed when the download fails, and on a wrong argument count'
fetch v4.9.0 CURL_FAIL=1
download="$status $(cat "$work/log")"
usage=0
bash "$SCRIPT" v4.9.0 > /dev/null 2>&1 || usage=$?
if assert_equals 1 "${download%% *}" 'download status' \
    && assert_contains "$download" "e2e-simlock: could not download rnw-community/mobile-ci at 'v4.9.0'." 'download' \
    && assert_equals '' "$(find "$work" -maxdepth 1 -name 'mobile-ci-e2e-simlock-*')" 'scratch removed' \
    && assert_equals 2 "$usage" 'usage status'; then
    pass_case
fi

finish_suite
