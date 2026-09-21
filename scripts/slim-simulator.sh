#!/usr/bin/env bash
# Slim a booted iOS Simulator against the same profile CI verifies. Source it for
# slim_simulator/slim_booted_simulators, or run it to slim every booted device.

simslim_profile_path() {
    if [ -n "${SIMSLIM_PROFILE:-}" ]; then
        printf '%s\n' "$SIMSLIM_PROFILE"
        return 0
    fi

    local bundled
    bundled="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/profiles/ci.json"
    if [ -f "$bundled" ]; then
        printf '%s\n' "$bundled"
        return 0
    fi

    local ref="${SIMSLIM_PROFILE_REF:-v2}"
    local cached="${TMPDIR:-/tmp}/mobile-ci-simslim-${ref//\//-}-ci.json"
    if [ ! -s "$cached" ] && ! curl -fsSL \
        "https://raw.githubusercontent.com/rnw-community/mobile-ci/${ref}/profiles/ci.json" \
        -o "$cached"; then
        rm -f "$cached"
        echo "slim-simulator: could not fetch the mobile-ci ci.json profile; set SIMSLIM_PROFILE to a local one." >&2
        return 1
    fi
    printf '%s\n' "$cached"
}

slim_simulator() {
    local udid="$1"
    local profile

    if ! command -v simslim >/dev/null 2>&1; then
        echo "slim-simulator: simslim not found; every simulator must run slim. Install it with: brew install mobai-app/tap/simslim" >&2
        return 1
    fi

    profile="$(simslim_profile_path)" || return 1

    if simslim verify "$udid" --profile "$profile" >/dev/null 2>&1; then
        return 0
    fi

    simslim on "$udid" --no-reboot --profile "$profile"
}

booted_simulator_udids() {
    local listing

    if ! listing="$(xcrun simctl list devices booted)"; then
        echo "slim-simulator: 'xcrun simctl list devices booted' failed, so which simulators need slimming is unknown." >&2
        return 1
    fi

    printf '%s\n' "$listing" | sed -n 's/.*(\([0-9A-Fa-f-]\{36\}\)) (Booted).*/\1/p'
}

slim_booted_simulators() {
    local udids
    local udid

    udids="$(booted_simulator_udids)" || return 1

    while IFS= read -r udid; do
        [ -n "$udid" ] || continue
        slim_simulator "$udid" || return 1
    done <<<"$udids"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    if [ "$#" -gt 0 ]; then
        for argument in "$@"; do
            slim_simulator "$argument"
        done
    else
        slim_booted_simulators
    fi
fi
