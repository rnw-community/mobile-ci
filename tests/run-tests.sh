#!/usr/bin/env bash
# Runs every tests/*_test.sh. Each suite extracts the step scripts it exercises
# from the parsed action.yml and runs them against fixtures with stubbed
# binaries, so no test ever duplicates the shell it is testing. Each suite gets
# its own TMPDIR, removed when it passes and kept for inspection when it fails,
# so no run leaves its scratch workspaces behind.
set -euo pipefail

tests_dir="$(cd "$(dirname "$0")" && pwd)"
status=0
suites=0

for suite in "$tests_dir"/*_test.sh; do
    [ -f "$suite" ] || continue
    suites=$((suites + 1))
    printf '\n== %s\n' "$(basename "$suite")"
    suite_tmp="$(mktemp -d "${TMPDIR:-/tmp}/mobile-ci-suite-XXXXXX")"
    if TMPDIR="$suite_tmp" bash "$suite"; then
        rm -rf "$suite_tmp"
    else
        status=1
        printf 'Scratch workspaces of the failed suite kept in %s\n' "$suite_tmp" >&2
    fi
done

if [ "$suites" -eq 0 ]; then
    echo "::error::No test suites found under '$tests_dir'; an empty run is never a pass."
    exit 1
fi

exit "$status"
