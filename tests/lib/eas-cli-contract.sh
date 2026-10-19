# shellcheck shell=bash
# The flags each eas-cli command the actions call actually accepts, read from
# eas-cli 20.5.1 and 25.2.0's command definitions (both identical here). A stub
# that accepts any flag let `update:view --non-interactive` and
# `build:delete --json` pass the unit tests while eas-cli rejected both on the
# fleet ("Nonexistent flag"). Every eas-cli stub sources this and calls
# eas_cli_contract "$@" first, after shifting off `--yes eas-cli@<version>`.
eas_cli_contract() {
    local command="$1" arg
    shift
    for arg in "$@"; do
        case "$command:$arg" in
            update:view:--non-interactive | build:delete:--json)
                echo "Nonexistent flag: $arg" >&2
                echo "See more help with --help" >&2
                exit 2
                ;;
        esac
    done
}
