#!/usr/bin/env bash
# run-maestro-android's shard runs as scripts/run-shard.sh inside
# android-emulator-runner rather than as a run: step, so the suite runs that
# file directly with adb and maestro stubbed.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"
# shellcheck source=tests/lib/exclude-pattern-cases.sh
. "$REPO_ROOT/tests/lib/exclude-pattern-cases.sh"

RUN_SHARD="$REPO_ROOT/actions/run-maestro-android/scripts/run-shard.sh"

prepare_exclude() {
    local dir
    dir="$(new_empty_workspace)"
    cp "$RUN_SHARD" "$dir/step.sh"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" adb 'case "$*" in "shell getprop sys.boot_completed") echo 1 ;; devices) printf "List of devices attached\nemulator-5554\tdevice\n" ;; esac'
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" maestro 'printf "%s\n" "$*" >> "$MAESTRO_CALLS"'
    write_exclude_fixture_flows "$dir/work/flows"
    printf '%s\n' "$dir"
}

invoke_exclude() {
    local dir="$1"
    run_step "$dir" MAESTRO_CALLS="$dir/calls" \
        GITHUB_ENV="$dir/github-env" GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 \
        APK_PATH=app.apk APP_ID=com.example.app APP_WARM_SECONDS=0 PRE_TEST_COMMAND='' \
        FLOWS_DIR=flows FLOWS_MAX_DEPTH=1 \
        FLOWS_NAME_PATTERN='*.flow.yaml' FLOWS_EXCLUDE_PATTERN="$2" SHARD_MANIFEST_DIR='' \
        SHARD_INDEX=0 SHARD_COUNT=1 PRE_RUN_FLOW='' FLOW_RECOVERY_FLOW='' FLOW_RETRIES=0 \
        INFRA_RETRIES=1 SETTLE_BEFORE_FLOW=true \
        PRE_FLOW_COMMAND='' MAESTRO_ENV='' MAESTRO_CONFIG=''
}

run_exclude_pattern_cases flow

finish_suite
