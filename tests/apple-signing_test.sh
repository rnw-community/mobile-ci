#!/usr/bin/env bash
# A distribution .p12 exported from Keychain Access usually bundles the Apple
# WWDR intermediate, so importing the separately downloaded WWDR certificate a
# second time made `security import` fail with "The specified item already
# exists in the keychain" on every run (vitalyiegorov/pony-labirinth#646). The
# WWDR step must skip an intermediate the keychain already holds, import one it
# does not, and still fail on any other error.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/apple-signing/action.yml"
STEP='Add the WWDR intermediate unless the distribution certificate already brought it'
WWDR_SHA256='dcf21878c77f4198e4b4614f03d696d89c66c66008d4244e1b99161aac91601f'

wwdr_workspace() {
    local dir
    dir="$(new_workspace "$ACTION" "$STEP")"
    printf 'not really DER, only hashed\n' > "$dir/wwdr.cer"
    : > "$dir/security-log"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" security '
printf "%s\n" "$*" >> "$SECURITY_LOG"
case "$1" in
    find-certificate) [ -n "${SECURITY_LIST_FAIL:-}" ] && exit 1; printf "%s\n" "${SECURITY_HELD:-}" ;;
    import) exit "${SECURITY_IMPORT_EXIT:-0}" ;;
esac'
    printf '%s\n' "$dir"
}

run_wwdr() {
    local dir="$1"
    shift
    run_step "$dir" \
        SECURITY_LOG="$dir/security-log" \
        KEYCHAIN_PATH="$dir/signing.keychain-db" \
        WWDR_PATH="$dir/wwdr.cer" \
        WWDR_SHA256="$WWDR_SHA256" \
        "$@"
}

upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

case_start 'a WWDR intermediate the .p12 already brought is not imported again'
dir="$(wwdr_workspace)"
run_wwdr "$dir" SECURITY_HELD="SHA-256 hash: $(upper "$WWDR_SHA256")
SHA-1 hash: 0000000000000000000000000000000000000000"
assert_equals 0 "$STEP_STATUS" 'step status' &&
    assert_not_contains "$(cat "$dir/security-log")" 'import' 'security calls' &&
    pass_case

case_start 'a keychain whose listing only reports SHA-1 is matched on SHA-1'
dir="$(wwdr_workspace)"
run_wwdr "$dir" SECURITY_HELD="SHA-1 hash: $(shasum -a 1 "$dir/wwdr.cer" | awk '{print toupper($1)}')"
assert_equals 0 "$STEP_STATUS" 'step status' &&
    assert_not_contains "$(cat "$dir/security-log")" 'import' 'security calls' &&
    pass_case

case_start 'a keychain without the intermediate gets it imported'
dir="$(wwdr_workspace)"
run_wwdr "$dir" SECURITY_HELD='SHA-256 hash: 1111111111111111111111111111111111111111111111111111111111111111'
assert_equals 0 "$STEP_STATUS" 'step status' &&
    assert_contains "$(cat "$dir/security-log")" "import $dir/wwdr.cer -A -t cert -f x509 -k $dir/signing.keychain-db" 'security calls' &&
    pass_case

case_start 'any other import failure still fails the step'
dir="$(wwdr_workspace)"
run_wwdr "$dir" SECURITY_IMPORT_EXIT=1
assert_equals 1 "$STEP_STATUS" 'step status' && pass_case

case_start 'a keychain that cannot be listed fails closed'
dir="$(wwdr_workspace)"
run_wwdr "$dir" SECURITY_LIST_FAIL=1
assert_equals 1 "$STEP_STATUS" 'step status' &&
    assert_not_contains "$(cat "$dir/security-log")" 'import' 'security calls' &&
    pass_case

finish_suite
