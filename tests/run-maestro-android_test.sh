#!/usr/bin/env bash
# run-maestro-android's shard runs as scripts/run-shard.sh inside
# android-emulator-runner rather than as a run: step, so the suite runs that
# file directly with adb and maestro stubbed.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"
# shellcheck source=tests/lib/exclude-pattern-cases.sh
. "$REPO_ROOT/tests/lib/exclude-pattern-cases.sh"
# shellcheck source=tests/lib/maestro-tag-junit-cases.sh
. "$REPO_ROOT/tests/lib/maestro-tag-junit-cases.sh"

RUN_SHARD="$REPO_ROOT/actions/run-maestro-android/scripts/run-shard.sh"

prepare_exclude() {
    local dir
    dir="$(new_empty_workspace)"
    cp "$RUN_SHARD" "$dir/step.sh"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" adb 'case "$*" in "shell getprop sys.boot_completed") echo 1 ;; get-state) echo device ;; devices) printf "List of devices attached\nemulator-5554\tdevice\n" ;; esac'
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
        APK_PATH=app.apk APP_ID=com.example.app APP_WARM_SECONDS=0 PRE_TEST_COMMAND='' \
        FLOWS_DIR=flows FLOWS_MAX_DEPTH=1 \
        FLOWS_NAME_PATTERN='*.flow.yaml' FLOWS_EXCLUDE_PATTERN='' SHARD_MANIFEST_DIR='' \
        SHARD_INDEX=0 SHARD_COUNT=1 PRE_RUN_FLOW='' FLOW_RECOVERY_FLOW='' FLOW_RETRIES=0 \
        INFRA_RETRIES=1 SETTLE_BEFORE_FLOW=true \
        PRE_FLOW_COMMAND='' MAESTRO_ENV='' MAESTRO_CONFIG='' INCLUDE_TAGS='' EXCLUDE_TAGS='' JUNIT_REPORT=false MAESTRO_SCRIPTS_DIR="$REPO_ROOT/scripts/maestro" \
        "$@"
}

invoke_exclude() {
    invoke_shard "$1" FLOWS_EXCLUDE_PATTERN="$2"
}

run_exclude_pattern_cases flow

prepare_tagged() {
    local dir
    dir="$(new_empty_workspace)"
    cp "$RUN_SHARD" "$dir/step.sh"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" adb 'case "$*" in "shell getprop sys.boot_completed") echo 1 ;; get-state) echo device ;; devices) printf "List of devices attached\nemulator-5554\tdevice\n" ;; esac'
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" maestro 'printf "%s\n" "$*" >> "$MAESTRO_CALLS"; case "$*" in *fail.flow.yaml*) exit 1 ;; esac'
    printf '%s\n' "$dir"
}

invoke_tagged() {
    local dir="$1"
    shift
    invoke_shard "$dir" JUNIT_REPORT=true ARTIFACTS_DIR="$dir/artifacts" "$@"
}

case_start 'a shard whose emulator is lost stops with an infrastructure annotation and records the unrun flows'
workspace="$(new_empty_workspace)"
cp "$RUN_SHARD" "$workspace/step.sh"
# shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
stub "$workspace" adb 'case "$*" in "shell getprop sys.boot_completed") echo 1 ;; get-state) [ -f "$LOST" ] && { echo "error: device not found" >&2; exit 1; }; echo device ;; devices) printf "List of devices attached\nemulator-5554\tdevice\n" ;; esac'
# shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
stub "$workspace" maestro 'printf "%s\n" "$*" >> "$MAESTRO_CALLS"; case "$*" in *02.lost.flow.yaml*) : > "$LOST"; exit 1 ;; esac'
mkdir -p "$workspace/work/flows"
for name in 01.ok 02.lost 03.after 04.after; do printf 'appId: x\n' > "$workspace/work/flows/$name.flow.yaml"; done
invoke_shard "$workspace" LOST="$workspace/lost" JUNIT_REPORT=true ARTIFACTS_DIR="$workspace/artifacts"
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_equals 'flows/01.ok.flow.yaml flows/02.lost.flow.yaml' "$(shard_flows_run "$workspace")" 'flows run' \
    && assert_contains "$(cat "$workspace/log")" "::error::Infrastructure failure: emulator 'emulator-5554' is gone" 'log' \
    && assert_contains "$(cat "$workspace/summary")" '| 04.after.flow.yaml | 0s | not run (emulator lost) |' 'summary' \
    && assert_contains "$(cat "$workspace/artifacts/junit/03.after.flow.xml" 2>/dev/null)" 'emulator' 'unrun flow JUnit'; then
    pass_case
fi

case_start 'a failed flow on a live emulator keeps running the rest of the shard'
workspace="$(new_empty_workspace)"
cp "$RUN_SHARD" "$workspace/step.sh"
# shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
stub "$workspace" adb 'case "$*" in "shell getprop sys.boot_completed") echo 1 ;; get-state) echo device ;; devices) printf "List of devices attached\nemulator-5554\tdevice\n" ;; esac'
# shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
stub "$workspace" maestro 'printf "%s\n" "$*" >> "$MAESTRO_CALLS"; case "$*" in *02.fail.flow.yaml*) exit 1 ;; esac'
mkdir -p "$workspace/work/flows"
for name in 01.ok 02.fail 03.after; do printf 'appId: x\n' > "$workspace/work/flows/$name.flow.yaml"; done
invoke_shard "$workspace"
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_equals 'flows/01.ok.flow.yaml flows/02.fail.flow.yaml flows/03.after.flow.yaml' "$(shard_flows_run "$workspace")" 'flows run' \
    && assert_not_contains "$(cat "$workspace/log")" 'Infrastructure failure' 'log'; then
    pass_case
fi

run_maestro_tag_junit_cases

finish_suite
