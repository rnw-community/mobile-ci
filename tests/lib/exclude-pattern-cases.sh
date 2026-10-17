# shellcheck shell=bash
# Issue #114: flows-exclude-pattern (scenes-exclude-pattern in
# capture-screenshots-ios) accepts a comma- and/or newline-separated list of
# globs. Four discovery steps implement it, so every suite that owns one runs
# these same cases against its own step.
#
# The calling suite defines:
#   prepare_exclude              prints a workspace whose ./work/flows holds
#                                the four fixture flows written below
#   invoke_exclude <dir> <globs> runs the step with that exclude value
# and passes the word its step logs ("flow" or "scene").

write_exclude_fixture_flows() {
    local flows_dir="$1"
    mkdir -p "$flows_dir"
    printf 'appId: x\n' > "$flows_dir/01.alpha.flow.yaml"
    printf 'appId: x\n' > "$flows_dir/02.beta.flow.yaml"
    printf 'appId: x\n' > "$flows_dir/03.gamma.flow.yaml"
    printf 'appId: x\n' > "$flows_dir/04.delta-clip-1.flow.yaml"
}

resolved_list() {
    sed -n "/^Resolved $2 list/{n;p;}" "$1/log"
}

run_exclude_pattern_cases() {
    local noun="$1" workspace

    case_start "a single exclude glob keeps working unchanged"
    workspace="$(prepare_exclude)"
    invoke_exclude "$workspace" '*-clip-1.flow.yaml'
    if assert_equals 'flows/01.alpha.flow.yaml flows/02.beta.flow.yaml flows/03.gamma.flow.yaml' \
        "$(resolved_list "$workspace" "$noun")" "resolved $noun list"; then
        pass_case
    fi

    case_start "a comma-separated exclude list drops every listed glob"
    workspace="$(prepare_exclude)"
    invoke_exclude "$workspace" '02.beta.flow.yaml,*-clip-1.flow.yaml'
    if assert_equals 'flows/01.alpha.flow.yaml flows/03.gamma.flow.yaml' \
        "$(resolved_list "$workspace" "$noun")" "resolved $noun list"; then
        pass_case
    fi

    case_start "a newline-separated exclude list drops every listed glob"
    workspace="$(prepare_exclude)"
    invoke_exclude "$workspace" $'02.beta.flow.yaml\n*-clip-1.flow.yaml\n'
    if assert_equals 'flows/01.alpha.flow.yaml flows/03.gamma.flow.yaml' \
        "$(resolved_list "$workspace" "$noun")" "resolved $noun list"; then
        pass_case
    fi

    case_start "exclude entries are trimmed and empty entries ignored"
    workspace="$(prepare_exclude)"
    invoke_exclude "$workspace" $'  02.beta.flow.yaml ,\n\n , \t*-clip-1.flow.yaml\t,\r\n'
    if assert_equals 'flows/01.alpha.flow.yaml flows/03.gamma.flow.yaml' \
        "$(resolved_list "$workspace" "$noun")" "resolved $noun list"; then
        pass_case
    fi

    case_start "an exclude list matching every $noun fails closed"
    workspace="$(prepare_exclude)"
    invoke_exclude "$workspace" '0[12].*,03.gamma.flow.yaml, *-clip-1.flow.yaml'
    if assert_equals 1 "$STEP_STATUS" 'step status' \
        && assert_contains "$(cat "$workspace/log")" "::error::No ${noun}s matching" 'error message' \
        && assert_equals '' "$(resolved_list "$workspace" "$noun")" "resolved $noun list"; then
        pass_case
    fi
}
