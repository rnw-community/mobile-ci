#!/usr/bin/env bash
# simlock-lease hands one job one simulator from the host's simlock worker, so
# several host-mode jobs on one Mac never share a device. The acquire and
# release steps run here against recorded simlock JSON (fixtures/simlock) with
# a stubbed `simlock`, so the real jq paths and the real exit-code mapping are
# what gets tested.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/simlock-lease/action.yml"
FIXTURES="$REPO_ROOT/fixtures/simlock"
VALIDATE_STEP='Validate the lease mode'
ACQUIRE_STEP='Acquire a simlock simulator'
RELEASE_STEP='Release the simlock simulator'
UDID='6F1D2A8C-3B4E-4F7A-9C2D-8E5B1A7F3C90'
LEASE_ID='lse_3b9d6c1e-7f2a-4c55-9e0b-8a41d2f6c7e3'

# The stub answers `status --json` from SIMLOCK_STATUS, `lease` from
# SIMLOCK_GRANT (or fails with SIMLOCK_LEASE_EXIT and SIMLOCK_LEASE_ERROR on
# stderr) and `release` with SIMLOCK_RELEASE_EXIT / SIMLOCK_RELEASE_ERROR.
# Every call, and the SIMLOCK_AGENT_ID it saw, lands in SIMLOCK_LOG.
stub_simlock() {
    local dir="$1"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" simlock '
printf "agent=%s %s\n" "${SIMLOCK_AGENT_ID:-}" "$*" >> "$SIMLOCK_LOG"
case "$*" in
    "--local status --json") cat "$SIMLOCK_STATUS" ;;
    "--local lease "*)
        echo "{\"push\":\"progress\",\"stage\":\"booting\",\"etaMs\":1000}" >&2
        if [ -n "${SIMLOCK_LEASE_EXIT:-}" ]; then
            printf "%s\n" "$SIMLOCK_LEASE_ERROR" >&2
            exit "$SIMLOCK_LEASE_EXIT"
        fi
        cat "$SIMLOCK_GRANT"
        ;;
    "--local release "*)
        if [ -n "${SIMLOCK_RELEASE_EXIT:-}" ]; then
            printf "%s\n" "$SIMLOCK_RELEASE_ERROR" >&2
            exit "$SIMLOCK_RELEASE_EXIT"
        fi
        echo "{\"released\":true}"
        ;;
    *) echo "unexpected simlock call: $*" >&2; exit 99 ;;
esac'
}

acquire_workspace() {
    local dir
    dir="$(new_workspace "$ACTION" "$ACQUIRE_STEP")"
    stub_simlock "$dir"
    : > "$dir/simlock-log"
    printf '%s\n' "$dir"
}

acquire() {
    local dir="$1"
    shift
    run_step "$dir" \
        SIMLOCK_LOG="$dir/simlock-log" \
        SIMLOCK_STATUS="$FIXTURES/status-0.3.0.json" \
        SIMLOCK_GRANT="$FIXTURES/grant-ios-slim.json" \
        GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=11 GITHUB_RUN_ATTEMPT=2 GITHUB_JOB=test RUNNER_NAME='trf host 7' \
        LEASE_DEVICE='iPhone 16' \
        LEASE_OS='' \
        LEASE_MODE='slim' \
        LEASE_TTL='75m' \
        QUEUE_TIMEOUT='20m' \
        SIMLOCK_VERSION='0.3.0' \
        LEASE_FILE_INPUT="$dir/lease.json" \
        "$@"
}

case_start 'acquire leases a detached simulator and records the lease'
dir="$(acquire_workspace)"
acquire "$dir"
log="$(cat "$dir/simlock-log")"
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))" \
    && assert_contains "$log" '--local lease --platform ios --detach --ttl 75m --agent-id github-actions.o.r.11.2.test.trf-host-7 --mode slim --device iPhone 16 --timeout 20m' 'lease argv' \
    && assert_equals "$UDID" "$(step_output "$dir" udid)" udid \
    && assert_equals "$LEASE_ID" "$(step_output "$dir" lease-id)" 'lease id' \
    && assert_equals slim "$(step_output "$dir" device-mode)" mode \
    && assert_equals 'iPhone 16' "$(step_output "$dir" device)" device \
    && assert_equals 18.6 "$(step_output "$dir" os)" os \
    && assert_equals "$dir/lease.json" "$(step_output "$dir" lease-file)" 'lease file output' \
    && assert_equals "$LEASE_ID|github-actions.o.r.11.2.test.trf-host-7|$UDID" "$(jq -r '"\(.leaseId)|\(.agentId)|\(.udid)"' "$dir/lease.json")" 'lease file'; then
    pass_case
fi

case_start 'acquire names no device or OS it was not given'
dir="$(acquire_workspace)"
acquire "$dir" LEASE_DEVICE='' LEASE_OS='>=18 <27' QUEUE_TIMEOUT=''
log="$(cat "$dir/simlock-log")"
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))" \
    && assert_contains "$log" '--mode slim --os >=18 <27' 'os range passed' \
    && assert_not_contains "$log" '--device' 'no device flag' \
    && assert_not_contains "$log" '--timeout' 'no queue timeout flag'; then
    pass_case
fi

case_start 'a slim request granted a full device warns and reports full'
dir="$(acquire_workspace)"
jq '.device.mode = "full"' "$FIXTURES/grant-ios-slim.json" > "$dir/full.json"
acquire "$dir" SIMLOCK_GRANT="$dir/full.json"
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))" \
    && assert_equals full "$(step_output "$dir" device-mode)" mode \
    && assert_contains "$(cat "$dir/log")" '::warning::simlock granted a full simulator' 'fallback warning'; then
    pass_case
fi

case_start 'a worker on the simlock device set is refused and the lease handed back'
dir="$(acquire_workspace)"
acquire "$dir" SIMLOCK_GRANT="$FIXTURES/grant-ios-full-simlock-set.json"
log="$(cat "$dir/simlock-log")"
if assert_equals 1 "$STEP_STATUS" status \
    && assert_contains "$(cat "$dir/log")" "::error::simlock lease refused: the worker keeps its simulators in its own device set" 'device-set error' \
    && assert_contains "$log" '--local release lse_3c9a7e10-52b4-4f6d-8e21-b07d4a9c6f35' 'lease handed back' \
    && assert_not_contains "$(cat "$dir/outputs")" 'udid=' 'no udid output'; then
    pass_case
fi

case_start 'a grant without a simulator UDID is handed back'
dir="$(acquire_workspace)"
jq '.device.driverDeviceId = null' "$FIXTURES/grant-ios-slim.json" > "$dir/no-udid.json"
acquire "$dir" SIMLOCK_GRANT="$dir/no-udid.json"
if assert_equals 1 "$STEP_STATUS" status \
    && assert_contains "$(cat "$dir/log")" "::error::simlock granted lease $LEASE_ID without a simulator UDID" error \
    && assert_contains "$(cat "$dir/simlock-log")" "--local release $LEASE_ID" 'lease handed back' \
    && assert_equals '' "$(find "$dir" -maxdepth 1 -name lease.json)" 'lease file removed'; then
    pass_case
fi

case_start 'a grant without a lease id fails without guessing'
dir="$(acquire_workspace)"
echo '{"device":{}}' > "$dir/no-lease.json"
acquire "$dir" SIMLOCK_GRANT="$dir/no-lease.json"
if assert_equals 1 "$STEP_STATUS" status \
    && assert_contains "$(cat "$dir/log")" '::error::simlock lease exited 0 but printed no lease id' error; then
    pass_case
fi

case_start 'a daemon on another version than the pin fails before leasing'
dir="$(acquire_workspace)"
acquire "$dir" SIMLOCK_VERSION='0.4.0'
if assert_equals 1 "$STEP_STATUS" status \
    && assert_contains "$(cat "$dir/log")" "::error::simlock lease refused: the host's simlock worker runs 0.3.0, but simlock-version pins 0.4.0" 'version error' \
    && assert_not_contains "$(cat "$dir/simlock-log")" 'lease --platform' 'no lease attempted'; then
    pass_case
fi

case_start 'no simlock on PATH fails closed'
dir="$(acquire_workspace)"
rm "$dir/stub-bin/simlock"
acquire "$dir" PATH="$dir/stub-bin:/usr/bin:/bin"
if assert_equals 1 "$STEP_STATUS" status \
    && assert_contains "$(cat "$dir/log")" "::error::simlock lease refused: 'simlock' is not on PATH" 'missing binary error'; then
    pass_case
fi

case_start 'a full queue is an infrastructure failure'
ok=1
for spec in '11|NO_CAPACITY' '10|QUEUE_TIMEOUT' '1|DAEMON_STARTUP_FAILED'; do
    exit_code="${spec%%|*}" code="${spec#*|}"
    dir="$(acquire_workspace)"
    acquire "$dir" SIMLOCK_LEASE_EXIT="$exit_code" SIMLOCK_LEASE_ERROR="{\"error\":{\"code\":\"$code\",\"message\":\"m\"}}"
    assert_equals 1 "$STEP_STATUS" "$code status" \
        && assert_contains "$(cat "$dir/log")" "::error::Infrastructure failure: simlock lease failed with $code (exit $exit_code): m" "$code annotation" \
        || ok=0
done
[ "$ok" -eq 0 ] || pass_case

case_start 'an unknown model is a configuration error, not infrastructure'
dir="$(acquire_workspace)"
acquire "$dir" SIMLOCK_LEASE_EXIT=12 SIMLOCK_LEASE_ERROR='{"error":{"code":"UNKNOWN_MODEL","message":"Unknown ios model: iPhone 19"}}'
if assert_equals 1 "$STEP_STATUS" status \
    && assert_contains "$(cat "$dir/log")" '::error::simlock lease refused with UNKNOWN_MODEL (exit 12): Unknown ios model: iPhone 19' annotation \
    && assert_not_contains "$(cat "$dir/log")" 'Infrastructure failure' 'not infra'; then
    pass_case
fi

case_start 'malformed inputs fail before any simlock call'
ok=1
for bad in 'LEASE_MODE=tiny' 'LEASE_TTL=2 hours' 'QUEUE_TIMEOUT=soon' 'SIMLOCK_VERSION=latest'; do
    dir="$(acquire_workspace)"
    acquire "$dir" "$bad"
    assert_equals 1 "$STEP_STATUS" "$bad status" \
        && assert_equals '' "$(cat "$dir/simlock-log")" "$bad made no call" \
        || ok=0
done
[ "$ok" -eq 0 ] || pass_case

release_workspace() {
    local dir
    dir="$(new_workspace "$ACTION" "$RELEASE_STEP")"
    stub_simlock "$dir"
    : > "$dir/simlock-log"
    printf '%s\n' "$dir"
}

release() {
    local dir="$1"
    shift
    run_step "$dir" SIMLOCK_LOG="$dir/simlock-log" LEASE_FILE_INPUT='' "$@"
}

write_lease() {
    jq -n --arg id "$2" --arg agent "$3" --arg udid "$UDID" '{leaseId: $id, agentId: $agent, udid: $udid}' > "$1"
}

case_start 'release hands back the recorded lease as the requester that took it'
dir="$(release_workspace)"
write_lease "$dir/runner-temp/simlock-lease-a.json" "$LEASE_ID" agent-a
release "$dir"
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))" \
    && assert_equals "agent=agent-a --local release $LEASE_ID" "$(cat "$dir/simlock-log")" 'release call' \
    && assert_equals '' "$(find "$dir/runner-temp" -name 'simlock-lease-*.json')" 'lease file removed'; then
    pass_case
fi

case_start 'release with nothing leased warns and succeeds'
dir="$(release_workspace)"
release "$dir"
if assert_equals 0 "$STEP_STATUS" status \
    && assert_contains "$(cat "$dir/log")" '::warning::No simlock lease file' warning \
    && assert_equals '' "$(cat "$dir/simlock-log")" 'no call'; then
    pass_case
fi

case_start 'a lease simlock already ended is a warning, not a failure'
dir="$(release_workspace)"
write_lease "$dir/lease.json" "$LEASE_ID" agent-a
release "$dir" LEASE_FILE_INPUT="$dir/lease.json" SIMLOCK_RELEASE_EXIT=12 SIMLOCK_RELEASE_ERROR='{"error":{"code":"UNKNOWN_LEASE","message":"gone"}}'
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$dir/log"))" \
    && assert_contains "$(cat "$dir/log")" "::warning::simlock lease $LEASE_ID had already ended" warning; then
    pass_case
fi

case_start 'a recorded lease that cannot be released fails the step'
dir="$(release_workspace)"
write_lease "$dir/lease.json" "$LEASE_ID" agent-a
release "$dir" LEASE_FILE_INPUT="$dir/lease.json" SIMLOCK_RELEASE_EXIT=1 SIMLOCK_RELEASE_ERROR='{"error":{"code":"DAEMON_CONNECTION_LOST","message":"down"}}'
if assert_equals 1 "$STEP_STATUS" status \
    && assert_contains "$(cat "$dir/log")" "::error::Infrastructure failure: simlock could not release lease $LEASE_ID (DAEMON_CONNECTION_LOST, exit 1): down" annotation \
    && assert_equals 1 "$(find "$dir" -maxdepth 1 -name lease.json | wc -l | tr -d ' ')" 'lease file kept'; then
    pass_case
fi

case_start 'an unknown mode fails instead of skipping both steps'
dir="$(new_workspace "$ACTION" "$VALIDATE_STEP")"
run_step "$dir" LEASE_ACTION_MODE=renew
if assert_equals 1 "$STEP_STATUS" status \
    && assert_contains "$(cat "$dir/log")" "::error::simlock-lease mode 'renew'" error; then
    pass_case
fi

finish_suite
