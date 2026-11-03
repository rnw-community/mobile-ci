#!/usr/bin/env bash
# budgie-at/budgie#1885: `producer | grep -q` under the runner's
# `bash -eo pipefail` turns a match into a miss whenever the producer is still
# writing when grep exits. tests/lib/pipe-early-exit.py forbids the form in
# every run: body and repo script; these cases pin what it catches.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

LINT="$REPO_ROOT/tests/lib/pipe-early-exit.py"
FIXTURES="$REPO_ROOT/fixtures/pipe-early-exit"

reported() {
    python3 "$LINT" "$1" | grep -c "^$1: " || true
}

case_start 'no run: body or repo script pipes into an early-exiting grep'
if output="$(python3 "$LINT" 2>&1)"; then
    pass_case
else
    fail_case "$output"
fi

case_start 'every early-exiting grep after a pipe is reported, multi-line pipes included'
if assert_equals 15 "$(reported "$FIXTURES/unsafe.sh")" 'reported pipes'; then
    pass_case
fi

case_start 'a grep that reads to the end, or reads no pipe, is not reported'
if assert_equals 0 "$(reported "$FIXTURES/safe.sh")" 'reported pipes'; then
    pass_case
fi

case_start 'a heredoc with more shell after it inside $(...) is reported'
if assert_equals 3 "$(reported "$FIXTURES/heredoc-unsafe.sh")" 'reported heredocs'; then
    pass_case
fi

case_start 'a heredoc alone in $(...), outside one, or a here-string is not reported'
if assert_equals 0 "$(reported "$FIXTURES/heredoc-safe.sh")" 'reported heredocs'; then
    pass_case
fi

finish_suite
