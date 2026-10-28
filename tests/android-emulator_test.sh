#!/usr/bin/env bash
# android-emulator, the one AVD implementation run-maestro-android and
# store-screenshots' avd capture leg share (issues #169, #96). On a shared
# x86_64 KVM host the emulator is sized from the container's cgroup limits
# rather than the host's, a fleet-owned directory of slot files caps how many
# emulators a host boots at once, the boot fails closed without hardware
# acceleration instead of crawling under software emulation, and the teardown
# kills only the emulator processes this job started.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/android-emulator/action.yml"
WORKFLOW="$REPO_ROOT/.github/workflows/android-maestro.yml"
VALIDATE_STEP='Validate emulator inputs'
ACCEL_STEP='Check hardware acceleration'
SIZE_STEP='Size emulator from container limits'
BOOT_STEP='Boot emulator'
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
    : > "$dir/adb-calls"
    run_step "$dir" ADB_CALLS="$dir/adb-calls" EMULATOR_EXIT_GRACE_SECONDS=1 \
        GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=1 GITHUB_JOB=test RUNNER_NAME=runner-a "$@"
}

case_start 'teardown kills only the emulator processes carrying this job RUNNER_TRACKING_ID, then releases the slot'
workspace="$(new_workspace "$ACTION" "$SLOT_STEP")"
new_slots_dir "$workspace" 1
run_step "$workspace" EMULATOR_SLOTS_DIR="$workspace/slots" EMULATOR_SLOT_TIMEOUT_MINUTES=1
extract_step_script "$ACTION" "$TEARDOWN_STEP" > "$workspace/step.sh"
printf 'emulator-5554\t0\n' > "$workspace/runner-temp/mobile-ci-emulator"
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
    && assert_contains "$(cat "$workspace/adb-calls")" '-s emulator-5554 emu kill' 'adb emu kill on the booted serial' \
    && assert_equals false "$([ -e "$workspace/runner-temp/mobile-ci-emulator" ] && echo true || echo false)" 'emulator record removed' \
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
    && assert_not_contains "$(cat "$workspace/adb-calls")" 'kill-server' 'no own adb server, no kill-server' \
    && assert_not_contains "$(cat "$workspace/adb-calls")" 'emu kill' 'no booted serial recorded, no blind adb emu kill'; then
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

# validate [VAR=value ...]: sets `workspace`; deliberately not a command
# substitution so STEP_STATUS survives.
validate() {
    workspace="$(new_workspace "$ACTION" "$VALIDATE_STEP")"
    run_step "$workspace" MODE=start API_LEVEL=34 TARGET=google_apis ARCH=x86_64 PROFILE=pixel_6 \
        AVD_NAME=test PORT=5554 BOOT_TIMEOUT_SECONDS=600 WIPE_DATA=false RAM_SIZE='' HEAP_SIZE='' CORES='' "$@"
}

case_start 'the default start inputs validate'
validate
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))"; then
    pass_case
fi

case_start 'stop validates nothing but the mode, so a teardown never fails on a start-only input'
validate MODE=stop PORT=bogus API_LEVEL=''
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))"; then
    pass_case
fi

case_start 'an unknown mode fails closed'
validate MODE=restart
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" "mode 'restart'" 'error message'; then
    pass_case
fi

case_start 'an odd or out-of-range emulator port fails closed'
validate PORT=5555
odd_status=$STEP_STATUS
validate PORT=6000
if assert_equals 1 "$odd_status" 'odd port status' \
    && assert_equals 1 "$STEP_STATUS" 'out-of-range port status' \
    && assert_contains "$(cat "$workspace/log")" "port '6000'" 'error message'; then
    pass_case
fi

case_start 'a zero-padded emulator port fails closed instead of booting an unmatched serial'
validate PORT=05554
octal_status=$STEP_STATUS
validate PORT=05558
if assert_equals 1 "$octal_status" 'octal-valid padded port status' \
    && assert_equals 1 "$STEP_STATUS" 'octal-invalid padded port status' \
    && assert_contains "$(cat "$workspace/log")" "port '05558'" 'error message'; then
    pass_case
fi

case_start 'a system-image component that would split the sdkmanager package list fails closed'
validate TARGET='google_apis platform-tools'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'target' 'error names the input'; then
    pass_case
fi

case_start 'a ram-size carrying a newline cannot inject AVD config lines'
validate RAM_SIZE=$'2048\nhw.gpu.enabled=no'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'ram-size' 'error names the input'; then
    pass_case
fi

case_start 'a non-boolean wipe-data fails closed'
validate WIPE_DATA=yes
if assert_equals 1 "$STEP_STATUS" 'step status'; then
    pass_case
fi

# fake_sdk <workspace>: an ANDROID_HOME whose emulator binary answers
# -accel-check from ACCEL_OUTPUT/ACCEL_EXIT and otherwise records its argv and
# stays up like a booted emulator (or exits at once with EMULATOR_EXITS=1).
fake_sdk() {
    local dir="$1"
    mkdir -p "$dir/sdk/emulator"
    cat > "$dir/sdk/emulator/emulator" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = -accel-check ]; then
  printf '%b' "$ACCEL_OUTPUT"
  exit "${ACCEL_EXIT:-0}"
fi
printf '%s\n' "$*" > "$EMULATOR_ARGS"
echo 'emulator: fake boot log line'
[ "${EMULATOR_EXITS:-0}" = 1 ] && exit 3
exec sleep 300
STUB
    chmod +x "$dir/sdk/emulator/emulator"
}

accel() {
    workspace="$(new_workspace "$ACTION" "$ACCEL_STEP")"
    fake_sdk "$workspace"
    run_step "$workspace" ANDROID_HOME="$workspace/sdk" ANDROID_SDK_ROOT='' "$@"
}

KVM_OK='accel:\n0\nKVM (version 12) is installed and usable.\naccel\n'
KVM_MISSING='accel:\n9\n/dev/kvm is not found: VT disabled in BIOS or KVM kernel module not loaded\naccel\n'

case_start 'accel-check confirming KVM passes the preflight'
accel ACCEL_OUTPUT="$KVM_OK" ACCEL_EXIT=0
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_contains "$(cat "$workspace/summary")" 'KVM (version 12) is installed and usable.' 'accelerator in summary'; then
    pass_case
fi

case_start 'accel-check reporting no acceleration fails closed instead of booting under software emulation'
accel ACCEL_OUTPUT="$KVM_MISSING" ACCEL_EXIT=9
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" '/dev/kvm is not found' 'accel-check reason surfaced'; then
    pass_case
fi

case_start 'a non-zero accel status fails closed even when the emulator exits 0'
accel ACCEL_OUTPUT="$KVM_MISSING" ACCEL_EXIT=0
if assert_equals 1 "$STEP_STATUS" 'step status'; then
    pass_case
fi

case_start 'accel-check output with no status line fails closed'
accel ACCEL_OUTPUT='something unexpected\n' ACCEL_EXIT=0
if assert_equals 1 "$STEP_STATUS" 'step status'; then
    pass_case
fi

case_start 'an SDK with no emulator binary fails the preflight closed'
workspace="$(new_workspace "$ACTION" "$ACCEL_STEP")"
mkdir -p "$workspace/sdk"
run_step "$workspace" ANDROID_HOME="$workspace/sdk" ANDROID_SDK_ROOT=''
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'emulator' 'error message'; then
    pass_case
fi

# boot <workspace> [VAR=value ...]: runs the boot step against fake avdmanager,
# adb and emulator binaries. ADB_BOOTED=0 keeps getprop sys.boot_completed
# from ever reporting a booted device.
boot() {
    local dir="$1"
    shift
    fake_sdk "$dir"
    mkdir -p "$dir/home"
    # shellcheck disable=SC2016 # expanded when the stub runs.
    stub "$dir" avdmanager 'printf "%s\n" "$*" >> "$AVDMANAGER_CALLS"
name=""; package=""
while [ $# -gt 0 ]; do
  case "$1" in
    -n) name="$2"; shift ;;
    --package) package="$2"; shift ;;
  esac
  shift
done
mkdir -p "$ANDROID_AVD_HOME/$name.avd"
sysdir="$(printf "%s" "$package" | tr ";" "/")"
printf "image.sysdir.1=%s/\nhw.ramSize=1536\n" "$sysdir" > "$ANDROID_AVD_HOME/$name.avd/config.ini"'
    # shellcheck disable=SC2016 # expanded when the stub runs.
    stub "$dir" adb 'printf "%s\n" "$*" >> "$ADB_CALLS"
case "$*" in
  devices) printf "List of devices attached\n%s" "${ADB_DEVICES:-}" ;;
  *"getprop sys.boot_completed"*) [ "${ADB_BOOTED:-1}" = 1 ] && [ -s "${EMULATOR_ARGS:-/nonexistent}" ] && echo 1 || echo ;;
esac
exit 0'
    : > "$dir/adb-calls"
    [ -e "$dir/avdmanager-calls" ] || : > "$dir/avdmanager-calls"
    run_step "$dir" ANDROID_HOME="$dir/sdk" ANDROID_SDK_ROOT='' HOME="$dir/home" ANDROID_AVD_HOME='' \
        ADB_CALLS="$dir/adb-calls" AVDMANAGER_CALLS="$dir/avdmanager-calls" EMULATOR_ARGS="$dir/emulator-args" \
        API_LEVEL=34 TARGET=google_apis ARCH=x86_64 PROFILE=pixel_6 AVD_NAME=test PORT=5554 \
        BOOT_TIMEOUT_SECONDS=30 WIPE_DATA=false RAM_SIZE=2048 HEAP_SIZE='' CORES=2 \
        EMULATOR_OPTIONS='-no-snapshot-save -no-window -gpu swiftshader_indirect -noaudio -no-boot-anim -camera-back none' \
        "$@"
}

stop_booted() {
    local dir="$1" pid
    [ -f "$dir/runner-temp/mobile-ci-emulator" ] || return 0
    pid="$(cut -f2 "$dir/runner-temp/mobile-ci-emulator")"
    [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null
    return 0
}

case_start 'boot creates the AVD, applies the budget, boots detached and reports the serial'
workspace="$(new_workspace "$ACTION" "$BOOT_STEP")"
boot "$workspace"
config="$workspace/home/.android/avd/test.avd/config.ini"
emulator_pid="$(cut -f2 "$workspace/runner-temp/mobile-ci-emulator" 2>/dev/null || true)"
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals emulator-5554 "$(step_output "$workspace" android-serial)" 'android-serial' \
    && assert_contains "$(cat "$workspace/avdmanager-calls")" "--package system-images;android-34;google_apis;x86_64" 'avdmanager package' \
    && assert_contains "$(cat "$workspace/avdmanager-calls")" '--device pixel_6' 'avdmanager profile' \
    && assert_equals 1 "$(grep -c '^hw.ramSize=' "$config")" 'one hw.ramSize line' \
    && assert_contains "$(cat "$config")" 'hw.ramSize=2048' 'hw.ramSize' \
    && assert_contains "$(cat "$config")" 'hw.cpu.ncore=2' 'hw.cpu.ncore' \
    && assert_contains "$(cat "$workspace/emulator-args")" '-port 5554 -avd test -no-snapshot-save -no-window -gpu swiftshader_indirect -noaudio -no-boot-anim -camera-back none' 'emulator argv' \
    && assert_not_contains "$(cat "$workspace/emulator-args")" '-wipe-data' 'no wipe by default' \
    && assert_not_contains "$(cat "$workspace/emulator-args")" '-accel off' 'never software emulation' \
    && assert_contains "$(cat "$workspace/adb-calls")" '-s emulator-5554 shell settings put global window_animation_scale 0.0' 'window animations off' \
    && assert_contains "$(cat "$workspace/adb-calls")" '-s emulator-5554 shell settings put global transition_animation_scale 0.0' 'transition animations off' \
    && assert_contains "$(cat "$workspace/adb-calls")" '-s emulator-5554 shell settings put global animator_duration_scale 0.0' 'animator off' \
    && assert_contains "$(cat "$workspace/adb-calls")" '-s emulator-5554 shell settings put secure spell_checker_enabled 0' 'spellchecker off' \
    && assert_equals alive "$([ -n "$emulator_pid" ] && process_alive "$emulator_pid" && echo alive || echo dead)" 'emulator outlives the step' \
    && assert_contains "$(cat "$config")" 'image.sysdir.1=system-images/android-34/google_apis/x86_64/' 'AVD image'; then
    pass_case
fi
stop_booted "$workspace"

case_start 'a reused AVD keeps one value per key and is not recreated'
workspace="$(new_workspace "$ACTION" "$BOOT_STEP")"
boot "$workspace"
stop_booted "$workspace"
: > "$workspace/outputs"
boot "$workspace" RAM_SIZE=3072 CORES=4
config="$workspace/home/.android/avd/test.avd/config.ini"
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals 1 "$(grep -c 'create avd' "$workspace/avdmanager-calls")" 'avdmanager calls' \
    && assert_equals 'hw.ramSize=3072' "$(grep '^hw.ramSize=' "$config")" 'hw.ramSize' \
    && assert_equals 'hw.cpu.ncore=4' "$(grep '^hw.cpu.ncore=' "$config")" 'hw.cpu.ncore'; then
    pass_case
fi
stop_booted "$workspace"

case_start 'an AVD built for another system image is recreated'
workspace="$(new_workspace "$ACTION" "$BOOT_STEP")"
boot "$workspace"
stop_booted "$workspace"
boot "$workspace" API_LEVEL=35
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals 2 "$(grep -c 'create avd' "$workspace/avdmanager-calls")" 'avdmanager calls' \
    && assert_contains "$(cat "$workspace/home/.android/avd/test.avd/config.ini")" 'android-35' 'AVD image'; then
    pass_case
fi
stop_booted "$workspace"

case_start 'wipe-data true boots from a wiped userdata partition'
workspace="$(new_workspace "$ACTION" "$BOOT_STEP")"
boot "$workspace" WIPE_DATA=true
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_contains "$(cat "$workspace/emulator-args")" '-wipe-data' 'emulator argv'; then
    pass_case
fi
stop_booted "$workspace"

case_start 'an emulator that exits before boot fails closed with its log'
workspace="$(new_workspace "$ACTION" "$BOOT_STEP")"
boot "$workspace" EMULATOR_EXITS=1 ADB_BOOTED=0
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'fake boot log line' 'emulator log surfaced' \
    && assert_equals '' "$(step_output "$workspace" android-serial)" 'android-serial'; then
    pass_case
fi

case_start 'a device that never reports sys.boot_completed fails closed at the boot timeout'
workspace="$(new_workspace "$ACTION" "$BOOT_STEP")"
boot "$workspace" ADB_BOOTED=0 BOOT_TIMEOUT_SECONDS=3
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'sys.boot_completed' 'error message' \
    && assert_equals true "$([ -f "$workspace/runner-temp/mobile-ci-emulator" ] && echo true || echo false)" 'record kept for the stop step'; then
    pass_case
fi
stop_booted "$workspace"

case_start 'a serial already attached to adb fails closed rather than driving another job device'
workspace="$(new_workspace "$ACTION" "$BOOT_STEP")"
boot "$workspace" ADB_DEVICES=$'emulator-5554\tdevice\n'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'emulator-5554' 'error names the serial' \
    && assert_equals false "$([ -e "$workspace/emulator-args" ] && echo true || echo false)" 'no emulator launched'; then
    pass_case
fi

RESOLVE_STEP='Resolve preinstalled Android SDK'

# preinstalled_sdk <root> [missing component]: an SDK laid out like the fleet
# image's /opt/android-sdk, optionally without one of emulator, adb,
# avdmanager or image.
preinstalled_sdk() {
    local root="$1" missing="${2:-}" image="$1/system-images/android-34/google_apis/x86_64"
    mkdir -p "$root/emulator" "$root/platform-tools" "$root/cmdline-tools/latest/bin"
    [ "$missing" = emulator ] || { printf '#!/bin/sh\n' > "$root/emulator/emulator"; chmod +x "$root/emulator/emulator"; }
    [ "$missing" = adb ] || { printf '#!/bin/sh\n' > "$root/platform-tools/adb"; chmod +x "$root/platform-tools/adb"; }
    if [ "$missing" != avdmanager ]; then
        printf '#!/bin/sh\n' > "$root/cmdline-tools/latest/bin/avdmanager"
        chmod +x "$root/cmdline-tools/latest/bin/avdmanager"
    fi
    # shellcheck disable=SC2016 # expanded when the fake sdkmanager runs.
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$SDKMANAGER_CALLS"\n[ "${SDKMANAGER_FAILS:-0}" = 1 ] && exit 1\nfor arg in "$@"; do case "$arg" in --sdk_root=*) root="${arg#--sdk_root=}" ;; system-images\\;*) pkg="$arg" ;; esac; done\ndir="$root/$(printf "%%s" "$pkg" | tr ";" "/")"\nmkdir -p "$dir" && touch "$dir/package.xml" "$dir/system.img"\n' > "$root/cmdline-tools/latest/bin/sdkmanager"
    chmod +x "$root/cmdline-tools/latest/bin/sdkmanager"
    if [ "$missing" != image ]; then
        mkdir -p "$image"
        : > "$image/package.xml"
        : > "$image/system.img"
    fi
}

resolve_sdk() {
    local dir="$1"
    shift
    : > "$dir/sdkmanager-calls"
    run_step "$dir" API_LEVEL=34 TARGET=google_apis ARCH=x86_64 SDKMANAGER_CALLS="$dir/sdkmanager-calls" "$@"
}

case_start 'a complete preinstalled SDK is used as is and setup-android is skipped'
workspace="$(new_workspace "$ACTION" "$RESOLVE_STEP")"
preinstalled_sdk "$workspace/opt-sdk"
resolve_sdk "$workspace" ANDROID_SDK_ROOT="$workspace/opt-sdk" ANDROID_HOME="$workspace/elsewhere"
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals true "$(step_output "$workspace" sdk-ready)" 'sdk-ready' \
    && assert_equals "$workspace/opt-sdk" "$(step_output "$workspace" sdk-root)" 'sdk-root' \
    && assert_contains "$(cat "$workspace/env")" "ANDROID_HOME=$workspace/opt-sdk" 'ANDROID_HOME exported' \
    && assert_contains "$(cat "$workspace/env")" "ANDROID_SDK_ROOT=$workspace/opt-sdk" 'ANDROID_SDK_ROOT exported' \
    && assert_contains "$(cat "$workspace/path")" "$workspace/opt-sdk/platform-tools" 'platform-tools on PATH' \
    && assert_contains "$(cat "$workspace/path")" "$workspace/opt-sdk/cmdline-tools/latest/bin" 'avdmanager on PATH' \
    && assert_equals '' "$(cat "$workspace/sdkmanager-calls")" 'no sdkmanager install' \
    && assert_contains "$(cat "$workspace/summary")" 'preinstalled' 'path in summary'; then
    pass_case
fi

case_start 'ANDROID_HOME is used when ANDROID_SDK_ROOT is unset'
workspace="$(new_workspace "$ACTION" "$RESOLVE_STEP")"
preinstalled_sdk "$workspace/opt-sdk"
resolve_sdk "$workspace" ANDROID_SDK_ROOT='' ANDROID_HOME="$workspace/opt-sdk"
if assert_equals true "$(step_output "$workspace" sdk-ready)" "sdk-ready ($(cat "$workspace/log"))" \
    && assert_equals "$workspace/opt-sdk" "$(step_output "$workspace" sdk-root)" 'sdk-root'; then
    pass_case
fi

case_start 'a preinstalled SDK missing only the system image installs just that package into it'
workspace="$(new_workspace "$ACTION" "$RESOLVE_STEP")"
preinstalled_sdk "$workspace/opt-sdk" image
resolve_sdk "$workspace" ANDROID_SDK_ROOT="$workspace/opt-sdk" ANDROID_HOME=''
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals true "$(step_output "$workspace" sdk-ready)" 'sdk-ready' \
    && assert_equals "$workspace/opt-sdk" "$(step_output "$workspace" sdk-root)" 'sdk-root' \
    && assert_contains "$(cat "$workspace/sdkmanager-calls")" "--sdk_root=$workspace/opt-sdk system-images;android-34;google_apis;x86_64" 'sdkmanager installs only the image' \
    && assert_equals true "$([ -f "$workspace/opt-sdk/system-images/android-34/google_apis/x86_64/system.img" ] && echo true || echo false)" 'image installed into the existing SDK' \
    && assert_contains "$(cat "$workspace/summary")" 'installed the system image' 'path in summary'; then
    pass_case
fi

case_start 'a failed system-image install falls back to setup-android on the same SDK root'
workspace="$(new_workspace "$ACTION" "$RESOLVE_STEP")"
preinstalled_sdk "$workspace/opt-sdk" image
resolve_sdk "$workspace" ANDROID_SDK_ROOT="$workspace/opt-sdk" ANDROID_HOME='' SDKMANAGER_FAILS=1
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals false "$(step_output "$workspace" sdk-ready)" 'sdk-ready' \
    && assert_equals "$workspace/opt-sdk" "$(step_output "$workspace" sdk-root)" 'sdk-root handed to setup-android' \
    && assert_contains "$(cat "$workspace/log")" '::warning::' 'fallback warned'; then
    pass_case
fi

case_start 'a preinstalled SDK without the emulator binary goes through setup-android'
workspace="$(new_workspace "$ACTION" "$RESOLVE_STEP")"
preinstalled_sdk "$workspace/opt-sdk" emulator
resolve_sdk "$workspace" ANDROID_SDK_ROOT="$workspace/opt-sdk" ANDROID_HOME=''
if assert_equals false "$(step_output "$workspace" sdk-ready)" "sdk-ready ($(cat "$workspace/log"))" \
    && assert_equals "$workspace/opt-sdk" "$(step_output "$workspace" sdk-root)" 'sdk-root' \
    && assert_contains "$(cat "$workspace/summary")" 'setup-android' 'path in summary'; then
    pass_case
fi

case_start 'no SDK in the environment goes through setup-android with its default root'
workspace="$(new_workspace "$ACTION" "$RESOLVE_STEP")"
resolve_sdk "$workspace" ANDROID_SDK_ROOT='' ANDROID_HOME=''
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals false "$(step_output "$workspace" sdk-ready)" 'sdk-ready' \
    && assert_equals '' "$(step_output "$workspace" sdk-root)" 'sdk-root' \
    && assert_equals '' "$(cat "$workspace/env")" 'nothing exported'; then
    pass_case
fi

case_start 'setup-android runs only when the SDK is not ready, on the resolved root'
setup_step="$(ACTION_YML="$ACTION" python3 -c '
import json, os, yaml
action = yaml.safe_load(open(os.environ["ACTION_YML"], encoding="utf-8"))
step = [s for s in action["runs"]["steps"] if s.get("name") == "Set up Android SDK"][0]
print(json.dumps({"if": step.get("if"), "env": step.get("env")}, sort_keys=True), end="")
' 2>&1 || true)"
# shellcheck disable=SC2016 # a literal ${{ }} expression.
expected_root='"ANDROID_SDK_ROOT": "${{ steps.sdk.outputs.sdk-root }}"'
if assert_contains "$setup_step" "steps.sdk.outputs.sdk-ready != 'true'" 'setup-android condition' \
    && assert_contains "$setup_step" "$expected_root" 'setup-android root'; then
    pass_case
fi

# action_steps <action.yml>: "<name>\t<if>\t<uses>" per step, in order.
action_steps() {
    ACTION_YML="$1" python3 -c '
import os, yaml
action = yaml.safe_load(open(os.environ["ACTION_YML"], encoding="utf-8"))
for step in action["runs"]["steps"]:
    print("%s\t%s\t%s" % (step.get("name", ""), step.get("if", ""), step.get("uses", "")))
'
}

case_start 'start runs validate, SDK resolution, SDK setup, acceleration, sizing, slot, boot in order; stop runs only the teardown, always'
steps="$(action_steps "$ACTION" 2>/dev/null || true)"
order="$(printf '%s\n' "$steps" | cut -f1 | tr '\n' '|')"
start_steps="$(printf '%s\n' "$steps" | awk -F'\t' '$2 ~ /inputs.mode == .start./ { print $1 }' | tr '\n' '|')"
stop_steps="$(printf '%s\n' "$steps" | awk -F'\t' '$2 ~ /inputs.mode == .stop./ { print $1 "\t" $2 }')"
if assert_equals "$VALIDATE_STEP|$RESOLVE_STEP|Set up Android SDK|$ACCEL_STEP|$SIZE_STEP|$SLOT_STEP|$BOOT_STEP|$TEARDOWN_STEP|" "$order" 'step order' \
    && assert_equals "$RESOLVE_STEP|Set up Android SDK|$ACCEL_STEP|$SIZE_STEP|$SLOT_STEP|$BOOT_STEP|" "$start_steps" 'start-only steps' \
    && assert_contains "$stop_steps" "$TEARDOWN_STEP" 'teardown is stop-only' \
    && assert_contains "$stop_steps" 'always()' 'teardown runs even after a failed step'; then
    pass_case
fi

finish_suite
