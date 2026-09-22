#!/usr/bin/env bash
# A base binary store has two ways to be wrong that matter: calling an
# unreadable store "empty" (so a pull request repacks nothing and quietly
# compiles), and overwriting an address other builds already repack onto.
# Both are exercised here against stubbed oras and gh.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/expo-base-binary/action.yml"
ADDRESS_STEP='Resolve the base address'
PROVISION_STEP='Provision oras'
FETCH_GHCR_STEP='Fetch the base binary from the registry'
FETCH_ARTIFACT_STEP='Fetch the base binary from workflow artifacts'
PUBLISH_GUARD_STEP='Refuse to overwrite a published base'
KEY='abc123-0123456789ab'

address() {
    local dir="$1"
    shift
    run_step "$dir" \
        MODE="${MODE:-fetch}" \
        BACKEND="${BACKEND:-ghcr}" \
        PLATFORM="${PLATFORM:-ios}" \
        FLAVOR="${FLAVOR:-e2e}" \
        KEY="${THE_KEY-$KEY}" \
        REGISTRY=ghcr.io \
        REPOSITORY='RNW-Community/Mobile-CI' \
        IMAGE_NAME=e2e-base \
        "$@"
}

# stub_oras <workspace> — `manifest fetch` answers from ORAS_MANIFEST_MODE,
# `pull` writes a base file into the requested output directory.
stub_oras() {
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$1" oras '
case "$1 $2" in
    "manifest fetch")
        case "${ORAS_MANIFEST_MODE:-missing}" in
            present) exit 0 ;;
            missing) echo "Error: $3: not found" >&2; exit 1 ;;
            unauthorized) echo "Error: unauthorized: authentication required" >&2; exit 1 ;;
        esac
        ;;
esac
if [ "$1" = pull ]; then
    output=""
    while [ "$#" -gt 0 ]; do
        if [ "$1" = --output ]; then output="$2"; fi
        shift
    done
    if [ "${ORAS_PULL_EMPTY:-false}" = true ]; then exit 0; fi
    mkdir -p "$output"
    printf "base binary\n" > "$output/Base.tar.gz"
    exit 0
fi
if [ "$1" = push ]; then
    printf "%s\n" "$*" >> "$ORAS_LOG"
    exit 0
fi
exit 0'
}

case_start 'the address is lowercased and fails closed on an empty key'
dir="$(new_workspace "$ACTION" "$ADDRESS_STEP")"
address "$dir"
reference="$(step_output "$dir" reference)"
assert_equals 0 "$STEP_STATUS" 'address exit status' \
    && assert_equals "ghcr.io/rnw-community/mobile-ci/e2e-base:ios-e2e-$KEY" "$reference" 'OCI reference' \
    && assert_equals "e2e-base-ios-e2e-$KEY" "$(step_output "$dir" artifact-name)" 'artifact name' \
    && pass_case

case_start 'an empty key is never an address'
dir="$(new_workspace "$ACTION" "$ADDRESS_STEP")"
THE_KEY='' address "$dir"
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case "an empty key resolved to '$(step_output "$dir" reference)'"
else
    assert_contains "$(cat "$dir/log")" 'key is empty' 'error message' && pass_case
fi

case_start 'a key an OCI tag cannot carry fails closed'
dir="$(new_workspace "$ACTION" "$ADDRESS_STEP")"
THE_KEY='abc/../def' address "$dir"
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case "a path-traversing key resolved to '$(step_output "$dir" reference)'"
else
    pass_case
fi

case_start 'an unknown backend fails closed'
dir="$(new_workspace "$ACTION" "$ADDRESS_STEP")"
BACKEND=s3 address "$dir"
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'an unknown backend was accepted'
else
    assert_contains "$(cat "$dir/log")" "backend must be 'ghcr' or 'artifact'" 'error message' && pass_case
fi

case_start 'no oras and no checksum for this runner is a named error, not a silent download'
dir="$(new_workspace "$ACTION" "$PROVISION_STEP")"
# shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
stub "$dir" uname 'case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; esac'
stub "$dir" curl 'echo "curl must not run" >&2; exit 90'
run_step "$dir" ORAS_VERSION=1.3.4 ORAS_CHECKSUMS='darwin_arm64=deadbeef'
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'an unverifiable oras was provisioned anyway'
elif ! grep -q 'linux_amd64' "$dir/log"; then
    fail_case "the error did not name the runner's os/arch: $(cat "$dir/log")"
elif grep -q 'curl must not run' "$dir/log"; then
    fail_case 'the step downloaded oras before finding it had no checksum to check it against'
else
    pass_case
fi

case_start 'an architecture oras is not published for is a named error'
dir="$(new_workspace "$ACTION" "$PROVISION_STEP")"
# shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
stub "$dir" uname 'case "$1" in -s) echo Linux ;; -m) echo riscv64 ;; esac'
stub "$dir" curl 'echo "curl must not run" >&2; exit 90'
run_step "$dir" ORAS_VERSION=1.3.4 ORAS_CHECKSUMS='linux_amd64=deadbeef'
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'an unsupported architecture was accepted'
else
    assert_contains "$(cat "$dir/log")" 'Use backend: artifact' 'error message' && pass_case
fi

case_start 'a downloaded oras that does not match its pinned checksum is refused'
dir="$(new_workspace "$ACTION" "$PROVISION_STEP")"
# shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
stub "$dir" uname 'case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; esac'
# shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
stub "$dir" curl 'while [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then out="$2"; fi; shift; done; printf "not oras\n" > "$out"'
stub "$dir" tar 'echo "tar must not run" >&2; exit 91'
run_step "$dir" ORAS_VERSION=1.3.4 ORAS_CHECKSUMS='linux_amd64=0000000000000000000000000000000000000000000000000000000000000000'
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'a mismatched tarball was installed'
elif grep -q 'tar must not run' "$dir/log"; then
    fail_case 'the tarball was unpacked before its checksum was checked'
else
    assert_contains "$(cat "$dir/log")" 'hashes to' 'error message' && pass_case
fi

case_start 'a registry that answers "not found" reports no base, not a failure'
dir="$(new_workspace "$ACTION" "$FETCH_GHCR_STEP")"
stub_oras "$dir"
run_step "$dir" ORAS_MANIFEST_MODE=missing REFERENCE='ghcr.io/o/r/e2e-base:ios-e2e-k' DESTINATION=base
assert_equals 0 "$STEP_STATUS" 'fetch exit status' \
    && assert_equals 'false' "$(step_output "$dir" found)" 'found' \
    && assert_equals 'none' "$(step_output "$dir" source)" 'source' \
    && assert_equals '' "$(step_output "$dir" path)" 'path' \
    && pass_case

case_start 'a registry that cannot answer is not an absent base'
dir="$(new_workspace "$ACTION" "$FETCH_GHCR_STEP")"
stub_oras "$dir"
run_step "$dir" ORAS_MANIFEST_MODE=unauthorized REFERENCE='ghcr.io/o/r/e2e-base:ios-e2e-k' DESTINATION=base
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case "an unauthorized registry reported found='$(step_output "$dir" found)' instead of failing"
else
    assert_contains "$(cat "$dir/log")" 'not an absent base' 'error message' && pass_case
fi

case_start 'a published base is pulled and its path reported'
dir="$(new_workspace "$ACTION" "$FETCH_GHCR_STEP")"
stub_oras "$dir"
run_step "$dir" ORAS_MANIFEST_MODE=present REFERENCE='ghcr.io/o/r/e2e-base:ios-e2e-k' DESTINATION=base
assert_equals 0 "$STEP_STATUS" 'fetch exit status' \
    && assert_equals 'true' "$(step_output "$dir" found)" 'found' \
    && assert_equals 'ghcr' "$(step_output "$dir" source)" 'source' \
    && assert_equals 'base/Base.tar.gz' "$(step_output "$dir" path)" 'path' \
    && pass_case

case_start 'a fetch never empties the directory it was pointed at'
dir="$(new_workspace "$ACTION" "$FETCH_GHCR_STEP")"
stub_oras "$dir"
mkdir -p "$dir/work/base"
printf 'someone else owns this\n' > "$dir/work/base/keep-me"
run_step "$dir" ORAS_MANIFEST_MODE=present REFERENCE='ghcr.io/o/r/e2e-base:ios-e2e-k' DESTINATION=base
if [ "$STEP_STATUS" -ne 0 ]; then
    fail_case "the fetch failed: $(cat "$dir/log")"
elif [ ! -f "$dir/work/base/keep-me" ]; then
    fail_case 'the fetch deleted a file it did not put there; a caller may name its checkout as the destination'
else
    assert_equals 'base/Base.tar.gz' "$(step_output "$dir" path)" 'path' && pass_case
fi

case_start 'a manifest that pulls no file is not a base'
dir="$(new_workspace "$ACTION" "$FETCH_GHCR_STEP")"
stub_oras "$dir"
run_step "$dir" ORAS_MANIFEST_MODE=present ORAS_PULL_EMPTY=true REFERENCE='ghcr.io/o/r/e2e-base:ios-e2e-k' DESTINATION=base
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case "an empty pull reported found='$(step_output "$dir" found)'"
else
    pass_case
fi

# stub_gh <workspace> <artifacts json>
stub_gh() {
    printf '%s' "$2" > "$1/artifacts.json"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$1" gh '
case "$2" in
    *"/artifacts?name="*) cat "$GH_ARTIFACTS_JSON" ;;
    *"/zip") printf "zip\n" ;;
esac
exit "${GH_STATUS:-0}"'
}

ARTIFACTS_ON_MAIN='{"artifacts":[{"id":11,"expired":false,"created_at":"2026-01-01T00:00:00Z","workflow_run":{"head_branch":"main","repository_id":1,"head_repository_id":1}}]}'
ARTIFACTS_ON_A_BRANCH='{"artifacts":[{"id":12,"expired":false,"created_at":"2026-01-02T00:00:00Z","workflow_run":{"head_branch":"feature","repository_id":1,"head_repository_id":1}}]}'

case_start 'the artifact backend accepts only a default-branch base'
dir="$(new_workspace "$ACTION" "$FETCH_ARTIFACT_STEP")"
stub_gh "$dir" "$ARTIFACTS_ON_A_BRANCH"
stub "$dir" unzip 'exit 0'
run_step "$dir" GH_ARTIFACTS_JSON="$dir/artifacts.json" GITHUB_REPOSITORY=o/r \
    ARTIFACT_NAME=e2e-base-ios-e2e-k DEFAULT_BRANCH=main DESTINATION=base
assert_equals 0 "$STEP_STATUS" 'fetch exit status' \
    && assert_equals 'false' "$(step_output "$dir" found)" 'found' \
    && pass_case

case_start 'the artifact backend downloads a default-branch base'
dir="$(new_workspace "$ACTION" "$FETCH_ARTIFACT_STEP")"
stub_gh "$dir" "$ARTIFACTS_ON_MAIN"
# shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
stub "$dir" unzip 'while [ "$#" -gt 0 ]; do if [ "$1" = -d ]; then out="$2"; fi; shift; done; mkdir -p "$out"; printf "apk\n" > "$out/app-release.apk"'
run_step "$dir" GH_ARTIFACTS_JSON="$dir/artifacts.json" GITHUB_REPOSITORY=o/r \
    ARTIFACT_NAME=e2e-base-ios-e2e-k DEFAULT_BRANCH=main DESTINATION=base
assert_equals 0 "$STEP_STATUS" 'fetch exit status' \
    && assert_equals 'true' "$(step_output "$dir" found)" 'found' \
    && assert_equals 'artifact' "$(step_output "$dir" source)" 'source' \
    && assert_equals 'base/app-release.apk' "$(step_output "$dir" path)" 'path' \
    && pass_case

case_start 'an artifacts API that fails is not an absent base'
dir="$(new_workspace "$ACTION" "$FETCH_ARTIFACT_STEP")"
stub_gh "$dir" "$ARTIFACTS_ON_MAIN"
run_step "$dir" GH_STATUS=1 GH_ARTIFACTS_JSON="$dir/artifacts.json" GITHUB_REPOSITORY=o/r \
    ARTIFACT_NAME=e2e-base-ios-e2e-k DEFAULT_BRANCH=main DESTINATION=base
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case "a failed API query reported found='$(step_output "$dir" found)'"
else
    pass_case
fi

case_start 'an empty default branch fails closed rather than accepting any branch'
dir="$(new_workspace "$ACTION" "$FETCH_ARTIFACT_STEP")"
stub_gh "$dir" "$ARTIFACTS_ON_A_BRANCH"
run_step "$dir" GH_ARTIFACTS_JSON="$dir/artifacts.json" GITHUB_REPOSITORY=o/r \
    ARTIFACT_NAME=e2e-base-ios-e2e-k DEFAULT_BRANCH='' DESTINATION=base
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'an unknown default branch let any branch supply the base'
else
    pass_case
fi

publish_workspace() {
    local dir
    dir="$(new_workspace "$ACTION" "$PUBLISH_GUARD_STEP")"
    stub_oras "$dir"
    printf 'base\n' > "$dir/work/base.tar.gz"
    printf '%s\n' "$dir"
}

publish_guard() {
    local dir="$1"
    shift
    run_step "$dir" \
        BACKEND=ghcr \
        REFERENCE='ghcr.io/o/r/e2e-base:ios-e2e-k' \
        ARTIFACT_NAME=e2e-base-ios-e2e-k \
        SOURCE_PATH=base.tar.gz \
        FORCE="${FORCE:-false}" \
        DEFAULT_BRANCH=main \
        "$@"
}

case_start 'a published base is immutable'
dir="$(publish_workspace)"
publish_guard "$dir" ORAS_MANIFEST_MODE=present
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'an address that already holds a base was published over'
else
    assert_contains "$(cat "$dir/log")" 'already holds a base binary' 'error message' && pass_case
fi

case_start 'force overwrites, and says what it cost'
dir="$(publish_workspace)"
FORCE=true publish_guard "$dir" ORAS_MANIFEST_MODE=present
assert_equals 0 "$STEP_STATUS" 'guard exit status' \
    && assert_equals 'true' "$(step_output "$dir" publish)" 'publish' \
    && assert_contains "$(cat "$dir/log")" '::warning::Overwriting' 'warning' \
    && pass_case

case_start 'a free address publishes'
dir="$(publish_workspace)"
publish_guard "$dir" ORAS_MANIFEST_MODE=missing
assert_equals 0 "$STEP_STATUS" 'guard exit status' \
    && assert_equals 'true' "$(step_output "$dir" publish)" 'publish' \
    && pass_case

case_start 'a registry that cannot answer never publishes blind'
dir="$(publish_workspace)"
publish_guard "$dir" ORAS_MANIFEST_MODE=unauthorized
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'the step published without knowing whether the address was free'
else
    assert_contains "$(cat "$dir/log")" 'publishing blind' 'error message' && pass_case
fi

case_start 'publishing a file that is not there fails closed'
dir="$(publish_workspace)"
rm -f "$dir/work/base.tar.gz"
publish_guard "$dir" ORAS_MANIFEST_MODE=missing
if [ "$STEP_STATUS" -eq 0 ]; then
    fail_case 'a missing binary was published'
else
    pass_case
fi

finish_suite
