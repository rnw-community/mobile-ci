#!/usr/bin/env bash
# run-maestro-android on a shared x86_64 KVM host (issue #169): the emulator is
# sized from the container's cgroup limits rather than the host's, a fleet-owned
# directory of slot files caps how many emulators a host boots at once, and the
# teardown kills only the emulator processes this job started.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/run-maestro-android/action.yml"
WORKFLOW="$REPO_ROOT/.github/workflows/android-maestro.yml"
SIZE_STEP='Size emulator from container limits'
SLOT_STEP='Acquire host emulator slot'
TEARDOWN_STEP='Shutdown emulator'

SPAWNED_PIDS=''
# track <pid>: kill it when the suite exits, and keep the shell from reporting
# its expected death as a job notification.
track() {
    SPAWNED_PIDS="$SPAWNED_PIDS $1"
    disown "$1" 2>/dev/null || true
}

cleanup_spawned() {
    local pid
    for pid in $SPAWNED_PIDS; do
        kill -KILL "$pid" 2>/dev/null || true
    done
}
trap cleanup_spawned EXIT

GIB=1073741824

# cgroup_v2 <root> <memory.max> <cpu.max>
cgroup_v2() {
    mkdir -p "$1"
    printf 'cpu memory pids\n' > "$1/cgroup.controllers"
    printf '%s\n' "$2" > "$1/memory.max"
    printf '%s\n' "$3" > "$1/cpu.max"
}

# cgroup_v1 <root> <limit_in_bytes> <cfs_quota_us> <cfs_period_us>
cgroup_v1() {
    mkdir -p "$1/memory" "$1/cpu"
    printf '%s\n' "$2" > "$1/memory/memory.limit_in_bytes"
    printf '%s\n' "$3" > "$1/cpu/cpu.cfs_quota_us"
    printf '%s\n' "$4" > "$1/cpu/cpu.cfs_period_us"
}

size_step() {
    local dir="$1"
    shift
    run_step "$dir" RAM_SIZE='' CORES='' CGROUP_ROOT="$dir/cgroup" "$@"
}

case_start 'cgroup v2 8 GiB / 4 CPU derives 2048 MB and 2 cores, the default pool unchanged'
workspace="$(new_workspace "$ACTION" "$SIZE_STEP")"
cgroup_v2 "$workspace/cgroup" $((8 * GIB)) '400000 100000'
size_step "$workspace"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 2048 "$(step_output "$workspace" ram-size)" 'ram-size' \
    && assert_equals 2 "$(step_output "$workspace" cores)" 'cores' \
    && assert_contains "$(cat "$workspace/summary")" '8192 MiB' 'detected memory in summary' \
    && assert_contains "$(cat "$workspace/summary")" 'cgroup v2' 'detected source in summary'; then
    pass_case
fi

case_start 'cgroup v2 16 GiB / 8 CPU derives the 4096 MB and 4 core ceilings'
workspace="$(new_workspace "$ACTION" "$SIZE_STEP")"
cgroup_v2 "$workspace/cgroup" $((16 * GIB)) '800000 100000'
size_step "$workspace"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 4096 "$(step_output "$workspace" ram-size)" 'ram-size' \
    && assert_equals 4 "$(step_output "$workspace" cores)" 'cores'; then
    pass_case
fi

case_start 'cgroup v2 32 GiB / 16 CPU stays clamped at 4096 MB and 4 cores'
workspace="$(new_workspace "$ACTION" "$SIZE_STEP")"
cgroup_v2 "$workspace/cgroup" $((32 * GIB)) '1600000 100000'
size_step "$workspace"
if assert_equals 4096 "$(step_output "$workspace" ram-size)" 'ram-size' \
    && assert_equals 4 "$(step_output "$workspace" cores)" 'cores'; then
    pass_case
fi

case_start 'cgroup v2 4 GiB / 1.5 CPU clamps to the 1536 MB and 2 core floors and warns'
workspace="$(new_workspace "$ACTION" "$SIZE_STEP")"
cgroup_v2 "$workspace/cgroup" $((4 * GIB)) '150000 100000'
size_step "$workspace"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 1536 "$(step_output "$workspace" ram-size)" 'ram-size' \
    && assert_equals 2 "$(step_output "$workspace" cores)" 'cores' \
    && assert_contains "$(cat "$workspace/log")" '::warning::' 'warning below 6 GiB'; then
    pass_case
fi

case_start 'explicit ram-size and cores always win over the derived values'
workspace="$(new_workspace "$ACTION" "$SIZE_STEP")"
cgroup_v2 "$workspace/cgroup" $((8 * GIB)) '400000 100000'
size_step "$workspace" RAM_SIZE=3072M CORES=3
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 3072M "$(step_output "$workspace" ram-size)" 'ram-size' \
    && assert_equals 3 "$(step_output "$workspace" cores)" 'cores' \
    && assert_contains "$(cat "$workspace/summary")" '8192 MiB' 'detected memory still reported'; then
    pass_case
fi

case_start 'cgroup v1 limits are read when there is no cgroup v2 hierarchy'
workspace="$(new_workspace "$ACTION" "$SIZE_STEP")"
cgroup_v1 "$workspace/cgroup" $((8 * GIB)) 400000 100000
size_step "$workspace"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 2048 "$(step_output "$workspace" ram-size)" 'ram-size' \
    && assert_equals 2 "$(step_output "$workspace" cores)" 'cores' \
    && assert_contains "$(cat "$workspace/summary")" 'cgroup v1' 'detected source in summary'; then
    pass_case
fi

case_start 'cgroup v1 unbounded sentinels keep the profile defaults'
workspace="$(new_workspace "$ACTION" "$SIZE_STEP")"
cgroup_v1 "$workspace/cgroup" 9223372036854771712 -1 100000
size_step "$workspace"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals '' "$(step_output "$workspace" ram-size)" 'ram-size' \
    && assert_equals '' "$(step_output "$workspace" cores)" 'cores' \
    && assert_contains "$(cat "$workspace/summary")" 'unbounded' 'summary'; then
    pass_case
fi

case_start 'cgroup v2 max keeps the profile defaults'
workspace="$(new_workspace "$ACTION" "$SIZE_STEP")"
cgroup_v2 "$workspace/cgroup" max 'max 100000'
size_step "$workspace"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals '' "$(step_output "$workspace" ram-size)" 'ram-size' \
    && assert_equals '' "$(step_output "$workspace" cores)" 'cores'; then
    pass_case
fi

case_start 'no cgroup hierarchy at all keeps the profile defaults'
workspace="$(new_workspace "$ACTION" "$SIZE_STEP")"
mkdir -p "$workspace/cgroup"
size_step "$workspace"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals '' "$(step_output "$workspace" ram-size)" 'ram-size' \
    && assert_equals '' "$(step_output "$workspace" cores)" 'cores'; then
    pass_case
fi

case_start 'an unparseable memory.max fails closed'
workspace="$(new_workspace "$ACTION" "$SIZE_STEP")"
cgroup_v2 "$workspace/cgroup" lots '400000 100000'
size_step "$workspace"
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" "memory.max" 'error names the file'; then
    pass_case
fi

case_start 'an unparseable cpu.max fails closed'
workspace="$(new_workspace "$ACTION" "$SIZE_STEP")"
cgroup_v2 "$workspace/cgroup" $((8 * GIB)) '400000 0'
size_step "$workspace"
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" "cpu.max" 'error names the file'; then
    pass_case
fi

case_start 'android-maestro.yml derives the emulator RAM instead of hand-setting 2048'
default_ram="$(WORKFLOW_YML="$WORKFLOW" python3 -c '
import os, yaml
w = yaml.safe_load(open(os.environ["WORKFLOW_YML"], encoding="utf-8"))
print(w[True]["workflow_call"]["inputs"]["emulator-ram-size"].get("default", ""), end="")
')"
if assert_equals '' "$default_ram" 'emulator-ram-size default'; then
    pass_case
fi

# hold_slot <slot file>: holds an exclusive flock on it from a background
# process, returning once the lock is held.
hold_slot() {
    local slot="$1" marker
    marker="$(mktemp -u "${TMPDIR:-/tmp}/mobile-ci-held-XXXXXX")"
    flock -o -x "$slot" -c "touch '$marker'; exec sleep 60" </dev/null >/dev/null 2>&1 &
    HELD_PID=$!
    track "$HELD_PID"
    while [ ! -e "$marker" ]; do sleep 0.05; done
    rm -f "$marker"
}

slot_is_free() {
    flock -n -x "$1" -c true
}

release_holder() {
    local dir="$1" pgid
    [ -f "$dir/runner-temp/mobile-ci-emulator-slot" ] || return 0
    pgid="$(cut -f1 "$dir/runner-temp/mobile-ci-emulator-slot")"
    kill -KILL -- "-$pgid" 2>/dev/null || true
}

new_slots_dir() {
    local dir="$1" count="$2" index=0
    mkdir -p "$dir/slots"
    while [ "$index" -lt "$count" ]; do
        : > "$dir/slots/slot-$index"
        index=$((index + 1))
    done
}

case_start 'emulator-slots-dir empty skips the slot entirely'
workspace="$(new_workspace "$ACTION" "$SLOT_STEP")"
run_step "$workspace" EMULATOR_SLOTS_DIR='' EMULATOR_SLOT_TIMEOUT_MINUTES=60
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals '' "$(step_output "$workspace" slot)" 'slot' \
    && assert_equals false "$([ -e "$workspace/runner-temp/mobile-ci-emulator-slot" ] && echo true || echo false)" 'holder record'; then
    pass_case
fi

case_start 'a free slot is locked by a detached holder that outlives the step'
workspace="$(new_workspace "$ACTION" "$SLOT_STEP")"
new_slots_dir "$workspace" 2
hold_slot "$workspace/slots/slot-0"
run_step "$workspace" EMULATOR_SLOTS_DIR="$workspace/slots" EMULATOR_SLOT_TIMEOUT_MINUTES=1
acquired="$(step_output "$workspace" slot)"
slot1_free="$(slot_is_free "$workspace/slots/slot-1" && echo true || echo false)"
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals slot-1 "$acquired" 'slot' \
    && assert_equals false "$slot1_free" 'slot-1 still locked after the step exited' \
    && assert_contains "$(cat "$workspace/summary")" 'slot-1' 'slot in summary'; then
    pass_case
fi
release_holder "$workspace"
kill -KILL "$HELD_PID" 2>/dev/null || true

case_start 'all slots busy past the timeout fails closed and names the busy slots'
workspace="$(new_workspace "$ACTION" "$SLOT_STEP")"
new_slots_dir "$workspace" 2
hold_slot "$workspace/slots/slot-0"
first_holder=$HELD_PID
hold_slot "$workspace/slots/slot-1"
run_step "$workspace" EMULATOR_SLOTS_DIR="$workspace/slots" EMULATOR_SLOT_TIMEOUT_MINUTES=0
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'slot-0 slot-1' 'busy slots logged' \
    && assert_equals '' "$(step_output "$workspace" slot)" 'slot' \
    && assert_equals false "$([ -e "$workspace/runner-temp/mobile-ci-emulator-slot" ] && echo true || echo false)" 'holder record'; then
    pass_case
fi
kill -KILL "$first_holder" "$HELD_PID" 2>/dev/null || true

case_start 'a busy host is waited out until a slot frees up'
workspace="$(new_workspace "$ACTION" "$SLOT_STEP")"
new_slots_dir "$workspace" 1
hold_slot "$workspace/slots/slot-0"
(sleep 2; kill -KILL "$HELD_PID") </dev/null >/dev/null 2>&1 &
run_step "$workspace" EMULATOR_SLOTS_DIR="$workspace/slots" EMULATOR_SLOT_TIMEOUT_MINUTES=1
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals slot-0 "$(step_output "$workspace" slot)" 'slot' \
    && assert_contains "$(cat "$workspace/log")" 'busy' 'wait logged'; then
    pass_case
fi
release_holder "$workspace"

case_start 'a missing emulator-slots-dir fails closed'
workspace="$(new_workspace "$ACTION" "$SLOT_STEP")"
run_step "$workspace" EMULATOR_SLOTS_DIR="$workspace/nowhere" EMULATOR_SLOT_TIMEOUT_MINUTES=1
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'is not a directory' 'error message'; then
    pass_case
fi

case_start 'an emulator-slots-dir holding no slot files fails closed'
workspace="$(new_workspace "$ACTION" "$SLOT_STEP")"
mkdir -p "$workspace/slots"
run_step "$workspace" EMULATOR_SLOTS_DIR="$workspace/slots" EMULATOR_SLOT_TIMEOUT_MINUTES=1
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'no slot-* files' 'error message'; then
    pass_case
fi

case_start 'an unwritable slot file fails closed'
workspace="$(new_workspace "$ACTION" "$SLOT_STEP")"
new_slots_dir "$workspace" 1
chmod 444 "$workspace/slots/slot-0"
run_step "$workspace" EMULATOR_SLOTS_DIR="$workspace/slots" EMULATOR_SLOT_TIMEOUT_MINUTES=1
if [ "$(id -u)" -eq 0 ]; then
    pass_case
elif assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'not writable' 'error message'; then
    pass_case
fi
release_holder "$workspace"

case_start 'a non-integer emulator-slot-timeout-minutes fails closed'
workspace="$(new_workspace "$ACTION" "$SLOT_STEP")"
new_slots_dir "$workspace" 1
run_step "$workspace" EMULATOR_SLOTS_DIR="$workspace/slots" EMULATOR_SLOT_TIMEOUT_MINUTES=soon
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" "emulator-slot-timeout-minutes 'soon'" 'error message'; then
    pass_case
fi
release_holder "$workspace"

# spawn_fake <argv0> [VAR=value ...]: a long-running process whose argv[0] and
# environment look like an emulator process of some job.
spawn_fake() {
    local argv0="$1"
    shift
    # shellcheck disable=SC2016 # expanded by the spawned bash.
    env -i PATH="$PATH" "$@" bash -c 'exec -a "$0" sleep 300' "$argv0" </dev/null >/dev/null 2>&1 &
    FAKE_PID=$!
    track "$FAKE_PID"
}

process_alive() {
    [ -n "$(tr -d '\0' 2>/dev/null < "/proc/$1/cmdline")" ]
}

teardown_step() {
    local dir="$1"
    shift
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" adb 'printf "%s\n" "$*" >> "$ADB_CALLS"'
    run_step "$dir" ADB_CALLS="$dir/adb-calls" EMULATOR_EXIT_GRACE_SECONDS=1 \
        GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=1 GITHUB_JOB=test RUNNER_NAME=runner-a "$@"
}

case_start 'teardown kills only the emulator processes carrying this job RUNNER_TRACKING_ID, then releases the slot'
workspace="$(new_workspace "$ACTION" "$SLOT_STEP")"
new_slots_dir "$workspace" 1
run_step "$workspace" EMULATOR_SLOTS_DIR="$workspace/slots" EMULATOR_SLOT_TIMEOUT_MINUTES=1
extract_step_script "$ACTION" "$TEARDOWN_STEP" > "$workspace/step.sh"
spawn_fake /sdk/emulator/qemu/linux-x86_64/qemu-system-x86_64 RUNNER_TRACKING_ID=github_ours
own_qemu=$FAKE_PID
spawn_fake /sdk/emulator/emulator RUNNER_TRACKING_ID=github_ours
own_emulator=$FAKE_PID
spawn_fake adb RUNNER_TRACKING_ID=github_ours
own_adb_client=$FAKE_PID
spawn_fake /sdk/emulator/qemu/linux-x86_64/qemu-system-x86_64 RUNNER_TRACKING_ID=github_theirs \
    GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=1 GITHUB_JOB=test RUNNER_NAME=runner-a
their_qemu=$FAKE_PID
spawn_fake /sdk/emulator/qemu/linux-x86_64/qemu-system-x86_64
anonymous_qemu=$FAKE_PID
sleep 0.2
teardown_step "$workspace" RUNNER_TRACKING_ID=github_ours
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals dead "$(process_alive "$own_qemu" && echo alive || echo dead)" 'own qemu' \
    && assert_equals dead "$(process_alive "$own_emulator" && echo alive || echo dead)" 'own emulator' \
    && assert_equals alive "$(process_alive "$own_adb_client" && echo alive || echo dead)" 'own non-emulator process' \
    && assert_equals alive "$(process_alive "$their_qemu" && echo alive || echo dead)" "another job's qemu" \
    && assert_equals alive "$(process_alive "$anonymous_qemu" && echo alive || echo dead)" 'an unattributable qemu' \
    && assert_contains "$(cat "$workspace/adb-calls")" 'emu kill' 'adb emu kill' \
    && assert_contains "$(cat "$workspace/log")" "$own_qemu" 'killed pid logged' \
    && assert_equals true "$(slot_is_free "$workspace/slots/slot-0" && echo true || echo false)" 'slot released'; then
    pass_case
fi
release_holder "$workspace"

case_start 'without RUNNER_TRACKING_ID teardown matches run id, attempt, job and runner name'
workspace="$(new_workspace "$ACTION" "$TEARDOWN_STEP")"
spawn_fake /sdk/emulator/qemu/linux-x86_64/qemu-system-x86_64 \
    GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=1 GITHUB_JOB=test RUNNER_NAME=runner-a
own_qemu=$FAKE_PID
spawn_fake /sdk/emulator/qemu/linux-x86_64/qemu-system-x86_64 \
    GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=1 GITHUB_JOB=test RUNNER_NAME=runner-b
sibling_qemu=$FAKE_PID
sleep 0.2
teardown_step "$workspace" RUNNER_TRACKING_ID=''
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals dead "$(process_alive "$own_qemu" && echo alive || echo dead)" 'own qemu' \
    && assert_equals alive "$(process_alive "$sibling_qemu" && echo alive || echo dead)" "a sibling matrix shard's qemu" \
    && assert_not_contains "$(cat "$workspace/adb-calls")" 'kill-server' 'no own adb server, no kill-server'; then
    pass_case
fi

case_start 'teardown stops the adb server only when this job started it'
workspace="$(new_workspace "$ACTION" "$TEARDOWN_STEP")"
env -i PATH="$PATH" RUNNER_TRACKING_ID=github_ours bash -c 'exec -a adb bash -c "sleep 300; :" fork-server server' </dev/null >/dev/null 2>&1 &
own_adb_server=$!
track "$own_adb_server"
env -i PATH="$PATH" RUNNER_TRACKING_ID=github_theirs bash -c 'exec -a adb bash -c "sleep 300; :" fork-server server' </dev/null >/dev/null 2>&1 &
their_adb_server=$!
track "$their_adb_server"
sleep 0.2
teardown_step "$workspace" RUNNER_TRACKING_ID=github_ours
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_contains "$(cat "$workspace/adb-calls")" 'kill-server' 'adb kill-server' \
    && assert_equals dead "$(process_alive "$own_adb_server" && echo alive || echo dead)" 'own adb server' \
    && assert_equals alive "$(process_alive "$their_adb_server" && echo alive || echo dead)" "another job's adb server"; then
    pass_case
fi

finish_suite
