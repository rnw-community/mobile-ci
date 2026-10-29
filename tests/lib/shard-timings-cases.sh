# shellcheck shell=bash
# Issue #267: shard-timings-file balances a shard's flows on recorded
# durations instead of the index-modulo split, and every shard records its
# flows' durations to artifacts-dir/flow-timings.tsv. Three shard scripts
# implement it, so every suite that owns one runs these same cases.
#
# The calling suite defines prepare_tagged and invoke_tagged as described in
# tests/lib/maestro-tag-junit-cases.sh, which it sources first (for
# shard_flows_run).

write_timed_flows() {
    mkdir -p "$1"
    for name in a b c d; do
        printf 'appId: x\n---\n- launchApp\n' > "$1/$name.flow.yaml"
    done
    printf '{"version": 1, "flows": {"a.flow.yaml": 100, "b.flow.yaml": 10, "c.flow.yaml": 10, "d.flow.yaml": 80}}\n' > "$2"
}

run_shard_timings_cases() {
    local workspace first second

    case_start 'shard-timings-file packs the longest flows first onto the least-loaded shard'
    workspace="$(prepare_tagged)"
    write_timed_flows "$workspace/work/flows" "$workspace/timings.json"
    invoke_tagged "$workspace" SHARD_COUNT=2 SHARD_INDEX=0 SHARD_TIMINGS_FILE="$workspace/timings.json"
    first="$(shard_flows_run "$workspace")"
    workspace="$(prepare_tagged)"
    write_timed_flows "$workspace/work/flows" "$workspace/timings.json"
    invoke_tagged "$workspace" SHARD_COUNT=2 SHARD_INDEX=1 SHARD_TIMINGS_FILE="$workspace/timings.json"
    second="$(shard_flows_run "$workspace")"
    if assert_equals 0 "$STEP_STATUS" 'step status' \
        && assert_equals 'flows/a.flow.yaml' "$first" 'shard 0 flows' \
        && assert_equals 'flows/b.flow.yaml flows/c.flow.yaml flows/d.flow.yaml' "$second" 'shard 1 flows'; then
        pass_case
    fi

    case_start 'a flows-dir with a trailing slash records and balances on the same flow keys'
    workspace="$(prepare_tagged)"
    write_timed_flows "$workspace/work/flows" "$workspace/timings.json"
    invoke_tagged "$workspace" FLOWS_DIR=flows/ SHARD_COUNT=2 SHARD_INDEX=0 SHARD_TIMINGS_FILE="$workspace/timings.json"
    if assert_equals 0 "$STEP_STATUS" 'step status' \
        && assert_equals 'flows/a.flow.yaml' "$(shard_flows_run "$workspace" | sed 's#//*#/#g')" 'shard 0 flows' \
        && assert_equals 'a.flow.yaml' "$(cut -f 1 "$workspace/artifacts/flow-timings.tsv" 2>/dev/null)" 'recorded flow key'; then
        pass_case
    fi

    case_start 'an unreadable shard-timings-file falls back to the index-modulo split with a warning'
    workspace="$(prepare_tagged)"
    write_timed_flows "$workspace/work/flows" "$workspace/timings.json"
    printf 'not json\n' > "$workspace/timings.json"
    invoke_tagged "$workspace" SHARD_COUNT=2 SHARD_INDEX=0 SHARD_TIMINGS_FILE="$workspace/timings.json"
    if assert_equals 0 "$STEP_STATUS" 'step status' \
        && assert_equals 'flows/a.flow.yaml flows/c.flow.yaml' "$(shard_flows_run "$workspace")" 'flows run' \
        && assert_contains "$(cat "$workspace/log")" 'splitting the flows by index instead' 'log'; then
        pass_case
    fi

    case_start 'every scenario flow records its duration and status to flow-timings.tsv'
    workspace="$(prepare_tagged)"
    mkdir -p "$workspace/work/flows"
    printf 'appId: x\n' > "$workspace/work/flows/ok.flow.yaml"
    printf 'appId: x\n' > "$workspace/work/flows/fail.flow.yaml"
    invoke_tagged "$workspace"
    if assert_equals 1 "$STEP_STATUS" 'step status (fail.flow.yaml fails)' \
        && assert_equals $'fail.flow.yaml\tfailed\nok.flow.yaml\tpassed' \
            "$(cut -f 1,3 "$workspace/artifacts/flow-timings.tsv" 2>/dev/null)" 'recorded flows' \
        && assert_equals 0 "$(cut -f 2 "$workspace/artifacts/flow-timings.tsv" | grep -cv '^[0-9][0-9]*$')" 'whole-second durations'; then
        pass_case
    fi
}
