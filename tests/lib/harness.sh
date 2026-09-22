# shellcheck shell=bash
# Test harness for this repo's composite actions.
#
# A composite action's `run:` body is plain shell that reads its inputs only
# through step-level `env:` (AGENTS.md's hard convention), so a step can be
# extracted from the parsed action.yml and executed in a scratch directory with
# stubbed binaries. That is what every tests/*_test.sh below does: no YAML is
# duplicated into the test, so a renamed step or a rewritten script fails the
# test instead of silently drifting from it.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# Exit status of the last run_step, read by the calling suite.
STEP_STATUS=0
export STEP_STATUS

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_CASE=''

extract_step_script() {
    ACTION_YML="$1" STEP_NAME="$2" python3 - <<'PYTHON'
import os
import sys

import yaml

action = yaml.safe_load(open(os.environ['ACTION_YML'], encoding='utf-8'))
wanted = os.environ['STEP_NAME']
for step in action['runs']['steps']:
    if step.get('name') == wanted:
        sys.stdout.write(step['run'])
        break
else:
    sys.exit(f"no step named {wanted!r} in {os.environ['ACTION_YML']}")
PYTHON
}

action_input_default() {
    ACTION_YML="$1" INPUT_NAME="$2" python3 - <<'PYTHON'
import os
import sys

import yaml

action = yaml.safe_load(open(os.environ['ACTION_YML'], encoding='utf-8'))
name = os.environ['INPUT_NAME']
if name not in action['inputs']:
    sys.exit(f"no input named {name!r} in {os.environ['ACTION_YML']}")
sys.stdout.write(str(action['inputs'][name].get('default', '')))
PYTHON
}

# new_workspace <action.yml> <step name>
# Prints a scratch directory holding the extracted step at ./step.sh, an empty
# ./outputs and ./summary, a ./stub-bin on PATH and a ./work working directory.
new_workspace() {
    local action_yml="$1" step_name="$2" dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/mobile-ci-test-XXXXXX")"
    extract_step_script "$action_yml" "$step_name" > "$dir/step.sh"
    mkdir -p "$dir/stub-bin" "$dir/work" "$dir/runner-temp"
    : > "$dir/outputs"
    : > "$dir/summary"
    printf '%s\n' "$dir"
}

# stub <workspace> <command name> <body>
stub() {
    local dir="$1" name="$2" body="$3"
    printf '#!/usr/bin/env bash\n%s\n' "$body" > "$dir/stub-bin/$name"
    chmod +x "$dir/stub-bin/$name"
}

# run_step <workspace> [VAR=value ...]
# Runs the extracted step with the workspace's stubs first on PATH. Stdout and
# stderr land in <workspace>/log; the exit status is returned in STEP_STATUS.
run_step() {
    local dir="$1"
    shift
    STEP_STATUS=0
    (
        cd "$dir/work" || exit 1
        env PATH="$dir/stub-bin:$PATH" \
            GITHUB_OUTPUT="$dir/outputs" \
            GITHUB_STEP_SUMMARY="$dir/summary" \
            RUNNER_TEMP="$dir/runner-temp" \
            "$@" \
            bash "$dir/step.sh"
    ) > "$dir/log" 2>&1 || STEP_STATUS=$?
    return 0
}

step_output() {
    local dir="$1" key="$2"
    OUTPUT_FILE="$dir/outputs" OUTPUT_KEY="$key" python3 - <<'PYTHON'
import os
import sys

lines = open(os.environ['OUTPUT_FILE'], encoding='utf-8').read().split('\n')
key = os.environ['OUTPUT_KEY']
value = None
index = 0
while index < len(lines):
    line = lines[index]
    if line.startswith(f'{key}<<'):
        delimiter = line.split('<<', 1)[1]
        collected = []
        index += 1
        while index < len(lines) and lines[index] != delimiter:
            collected.append(lines[index])
            index += 1
        value = '\n'.join(collected)
    elif line.startswith(f'{key}='):
        value = line.split('=', 1)[1]
    index += 1
sys.stdout.write(value if value is not None else '')
PYTHON
}

case_start() {
    CURRENT_CASE="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
}

fail_case() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL  %s\n      %s\n' "$CURRENT_CASE" "$1" >&2
}

pass_case() {
    printf 'ok    %s\n' "$CURRENT_CASE"
}

assert_equals() {
    local expected="$1" actual="$2" what="$3"
    if [ "$expected" != "$actual" ]; then
        fail_case "$what: expected '$expected', got '$actual'"
        return 1
    fi
    return 0
}

assert_contains() {
    local haystack="$1" needle="$2" what="$3"
    case "$haystack" in
        *"$needle"*) return 0 ;;
    esac
    fail_case "$what: '$needle' not found in: $haystack"
    return 1
}

assert_not_contains() {
    local haystack="$1" needle="$2" what="$3"
    case "$haystack" in
        *"$needle"*)
            fail_case "$what: '$needle' unexpectedly found in: $haystack"
            return 1
            ;;
    esac
    return 0
}

finish_suite() {
    if [ "$TESTS_FAILED" -gt 0 ]; then
        printf '\n%s of %s case(s) failed in %s\n' "$TESTS_FAILED" "$TESTS_RUN" "$(basename "$0")" >&2
        exit 1
    fi
    printf '\n%s case(s) passed in %s\n' "$TESTS_RUN" "$(basename "$0")"
}
