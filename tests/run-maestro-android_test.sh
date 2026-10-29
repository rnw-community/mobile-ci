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

# lost_emulator_workspace <flows...>: adb answers get-state 'device' until
# $LOST exists; maestro creates it when it runs 02.lost.flow.yaml.
lost_emulator_workspace() {
    workspace="$(new_empty_workspace)"
    cp "$RUN_SHARD" "$workspace/step.sh"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$workspace" adb 'case "$*" in "shell getprop sys.boot_completed") echo 1 ;; get-state) [ -f "$LOST" ] && { echo "error: device not found" >&2; exit 1; }; echo device ;; devices) printf "List of devices attached\nemulator-5554\tdevice\n" ;; esac'
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$workspace" maestro 'printf "%s\n" "$*" >> "$MAESTRO_CALLS"; case "$*" in *02.lost*) : > "$LOST"; exit 1 ;; esac'
    mkdir -p "$workspace/work/flows"
    for name in "$@"; do printf 'appId: x\n' > "$workspace/work/flows/$name.flow.yaml"; done
}

case_start 'a shard whose emulator is lost stops at once with an infrastructure annotation and records the unrun flows'
lost_emulator_workspace 01.ok 02.lost 03.after 04.after
invoke_shard "$workspace" LOST="$workspace/lost" FLOW_RETRIES=2 JUNIT_REPORT=true ARTIFACTS_DIR="$workspace/artifacts"
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_equals 'flows/01.ok.flow.yaml flows/02.lost.flow.yaml' "$(shard_flows_run "$workspace")" 'flows run (the lost flow is not retried)' \
    && assert_contains "$(cat "$workspace/log")" "::error::Infrastructure failure: emulator 'emulator-5554' is gone (adb get-state: 'no answer') during '02.lost.flow.yaml'" 'log' \
    && assert_contains "$(cat "$workspace/summary")" '| 04.after.flow.yaml | 0s | not run (emulator lost) |' 'summary' \
    && assert_contains "$(cat "$workspace/artifacts/junit/03.after.flow.xml" 2>/dev/null)" 'emulator' 'unrun flow JUnit'; then
    pass_case
fi

case_start "a lost emulator's own log and the cgroup's OOM kills are reported"
lost_emulator_workspace 01.ok 02.lost
mkdir -p "$workspace/runner-temp" "$workspace/cgroup"
printf 'INFO | boot completed\nqemu-system-x86_64: terminating on signal 9\n' > "$workspace/runner-temp/mobile-ci-emulator-5554.log"
printf 'low 0\nhigh 12\nmax 40\noom 2\noom_kill 1\n' > "$workspace/cgroup/memory.events"
invoke_shard "$workspace" LOST="$workspace/lost" CGROUP_ROOT="$workspace/cgroup" ARTIFACTS_DIR="$workspace/artifacts-not-yet-created"
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" "is gone (adb get-state: 'no answer'; the job's cgroup recorded 1 OOM kill(s)) during '02.lost.flow.yaml'" 'annotation' \
    && assert_contains "$(cat "$workspace/log")" 'terminating on signal 9' 'emulator log tail' \
    && assert_contains "$(cat "$workspace/artifacts-not-yet-created/mobile-ci-emulator-5554.log" 2>/dev/null)" 'signal 9' 'emulator log artifact'; then
    pass_case
fi

case_start 'a pre-flow-command that fails because the emulator is gone leaves only the infrastructure annotation'
lost_emulator_workspace 01.ok 03.after
# shellcheck disable=SC2016 # the script expands $LOST when the shard runs it.
printf ': > "$LOST"\nexit 1\n' > "$workspace/pre-flow.sh"
invoke_shard "$workspace" LOST="$workspace/lost" PRE_FLOW_COMMAND="bash $workspace/pre-flow.sh"
errors="$(grep '^::error::' "$workspace/log" || true)"
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_equals 1 "$(grep -c . <<< "$errors")" 'error annotations' \
    && assert_contains "$errors" "Infrastructure failure: emulator 'emulator-5554' is gone" 'the one error'; then
    pass_case
fi

case_start 'a priming flow that loses the emulator is reported as infrastructure, not as a priming failure'
lost_emulator_workspace 01.ok
printf 'appId: x\n' > "$workspace/work/flows/02.lost.yaml"
invoke_shard "$workspace" LOST="$workspace/lost" PRE_RUN_FLOW=flows/02.lost.yaml
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" "Infrastructure failure: emulator 'emulator-5554' is gone (adb get-state: 'no answer') during the priming flow" 'log' \
    && assert_not_contains "$(cat "$workspace/log")" "Priming flow 'flows/02.lost.yaml' failed" 'log'; then
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
