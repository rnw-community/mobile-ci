#!/usr/bin/env bash
# run-maestro-android-redroid discovers its shard's flows with the same
# flows-name-pattern / flows-exclude-pattern find as run-maestro-ios.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"
# shellcheck source=tests/lib/exclude-pattern-cases.sh
. "$REPO_ROOT/tests/lib/exclude-pattern-cases.sh"
# shellcheck source=tests/lib/maestro-tag-junit-cases.sh
. "$REPO_ROOT/tests/lib/maestro-tag-junit-cases.sh"
# shellcheck source=tests/lib/shard-timings-cases.sh
. "$REPO_ROOT/tests/lib/shard-timings-cases.sh"

ACTION="$REPO_ROOT/actions/run-maestro-android-redroid/action.yml"
SHARD_STEP='Run Maestro shard'

prepare_exclude() {
    local dir
    dir="$(new_workspace "$ACTION" "$SHARD_STEP")"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" maestro 'printf "%s\n" "$*" >> "$MAESTRO_CALLS"'
    write_exclude_fixture_flows "$dir/work/flows"
    printf '%s\n' "$dir"
}

invoke_shard() {
    local dir="$1"
    shift
    run_step "$dir" MAESTRO_CALLS="$dir/calls" \
        GITHUB_ENV="$dir/github-env" GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 \
        APP_ID=com.example.app FLOWS_DIR=flows FLOWS_MAX_DEPTH=1 \
        FLOWS_NAME_PATTERN='*.flow.yaml' FLOWS_EXCLUDE_PATTERN='' SHARD_MANIFEST_DIR='' SHARD_TIMINGS_FILE='' \
        SHARD_INDEX=0 SHARD_COUNT=1 PRE_RUN_FLOW='' FLOW_RECOVERY_FLOW='' FLOW_RETRIES=0 \
        PRE_FLOW_COMMAND='' MAESTRO_ENV='' MAESTRO_CONFIG='' INCLUDE_TAGS='' EXCLUDE_TAGS='' JUNIT_REPORT=false MAESTRO_SCRIPTS_DIR="$REPO_ROOT/scripts/maestro" \
        "$@"
}

invoke_exclude() {
    invoke_shard "$1" FLOWS_EXCLUDE_PATTERN="$2"
}

run_exclude_pattern_cases flow

prepare_tagged() {
    local dir
    dir="$(new_workspace "$ACTION" "$SHARD_STEP")"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" maestro 'printf "%s\n" "$*" >> "$MAESTRO_CALLS"; case "$*" in *fail.flow.yaml*) exit 1 ;; esac'
    printf '%s\n' "$dir"
}

invoke_tagged() {
    local dir="$1"
    shift
    invoke_shard "$dir" JUNIT_REPORT=true ARTIFACTS_DIR="$dir/artifacts" "$@"
}

run_maestro_tag_junit_cases
run_shard_timings_cases

finish_suite
