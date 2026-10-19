#!/usr/bin/env bash
# eas-channel-fingerprint answers "can this commit ship as an OTA on channel
# X?" by comparing the runtime version expo-updates resolves for this commit
# with the latest update and the latest finished build on the channel. An OTA
# shipped to a runtime no build on the channel has is lost, so every doubt
# decides native: a channel EAS cannot read, an update or build listing that
# fails, a channel nobody published to yet. A runtime version that cannot be
# resolved, or a missing token, fails the step instead.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION_YML="$REPO_ROOT/actions/eas-channel-fingerprint/action.yml"
TARGETS_STEP='Resolve the comparison targets'
STEP='Compare the runtime versions with the channel'

workspace() {
    local ws
    ws="$(new_workspace "$ACTION_YML" "$TARGETS_STEP")"
    mv "$ws/step.sh" "$ws/targets.sh"
    extract_step_script "$ACTION_YML" "$STEP" > "$ws/compare.sh"
    # UPDATE_RV_<branch>_<platform> and BUILD_RV_<channel>_<platform>
    # drive the stub; *_FAIL variables make that query fail.
    # shellcheck disable=SC2016
    stub "$ws" npx '
dir="$(dirname "$0")/.."
printf "%s\n" "$*" >> "$dir/npx-calls"
key() { printf "%s" "$1" | tr -c "A-Za-z0-9\n" _; }
shift 2
. "$REPO_ROOT/tests/lib/eas-cli-contract.sh"
eas_cli_contract "$@"
case "$1" in
  channel:view)
    [ -z "${VIEW_FAIL:-}" ] || { echo "Could not find channel with the name $2" >&2; exit 1; }
    jq -nc --arg c "$2" --arg extra "${EXTRA_BRANCH:-}" "{currentPage: {name: \$c, updateBranches: ([{name: \$c}] + (if \$extra == \"\" then [] else [{name: \$extra}] end))}}"
    ;;
  update:list)
    [ -z "${UPDATES_FAIL:-}" ] || exit 1
    var="UPDATE_RV_$(key "$3")_$5"
    if [ -n "${!var:-}" ]; then
      jq -nc --arg rv "${!var}" --arg b "$3" "{name: \$b, currentPage: [{branch: \$b, runtimeVersion: \$rv}]}"
    else
      jq -nc --arg b "$3" "{name: \$b, currentPage: []}"
    fi
    ;;
  build:list)
    [ -z "${BUILDS_FAIL:-}" ] || exit 1
    var="BUILD_RV_$(key "$3")_$5"
    if [ -n "${!var:-}" ]; then
      jq -nc --arg rv "${!var}" "[{id: \"b\", runtime: {version: \$rv}}]"
    else
      echo "[]"
    fi
    ;;
  *) echo "unexpected eas command $1" >&2; exit 64 ;;
esac'
    printf '%s\n' "$ws"
}

# check runs the targets step, then (as the action does after
# ota-runtime-version) the compare step with RUNTIMES.
check() {
    WS="$(workspace)"
    cp "$WS/targets.sh" "$WS/step.sh"
    run_step "$WS" EXPO_TOKEN_INPUT=token EXPO_TOKEN='' TARGETS='' CHANNEL=production PLATFORM=all EAS_PROFILE='' \
        PROFILE_ENV='' PROFILE_CHANNEL='' BASELINE=update-or-build EAS_CLI_VERSION=20.5.1 "$@"
    cp "$WS/log" "$WS/targets.log"
    if [ "$STEP_STATUS" -eq 0 ]; then
        cp "$WS/compare.sh" "$WS/step.sh"
        run_step "$WS" EXPO_TOKEN_INPUT=token EXPO_TOKEN='' BASELINE=update-or-build EAS_CLI_VERSION=20.5.1 \
            RUNTIMES='{"ios":"rv-i","android":"rv-a"}' "$@" TARGETS="$(step_output "$WS" targets)"
        cat "$WS/targets.log" "$WS/log" > "$WS/log.all" && mv "$WS/log.all" "$WS/log"
    fi
}

out() {
    step_output "$WS" "$1"
}

calls() {
    cat "$WS/npx-calls" 2>/dev/null || true
}

case_start "runtimes matching the latest update on the channel decide ota"
check UPDATE_RV_production_ios=rv-i UPDATE_RV_production_android=rv-a
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals ota "$(out decision)" 'decision' \
    && assert_equals '' "$(out changed-targets)" 'changed' \
    && assert_equals '{"ios":"rv-i","android":"rv-a"}' "$(out runtime-versions)" 'runtime versions' \
    && assert_contains "$(calls)" 'update:list --branch production --platform ios --limit 1 --json --non-interactive' 'update query' \
    && assert_contains "$(calls)" 'build:list --channel production --platform android --status finished --limit 1 --json --non-interactive' 'build query'; then
    pass_case
fi

case_start "a runtime matching only the latest finished build decides ota"
check UPDATE_RV_production_ios=old BUILD_RV_production_ios=rv-i UPDATE_RV_production_android=rv-a
if assert_equals 0 "$STEP_STATUS" 'status' && assert_equals ota "$(out decision)" 'decision'; then
    pass_case
fi

case_start "one platform whose runtime moved decides native and names it"
check UPDATE_RV_production_ios=rv-i UPDATE_RV_production_android=old BUILD_RV_production_android=older
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals native "$(out decision)" 'decision' \
    && assert_equals android "$(out changed-targets)" 'changed' \
    && assert_contains "$(out reason)" 'android: runtime rv-a is on neither the latest update (old) nor the latest build (older) of channel production' 'reason' \
    && assert_contains "$(cat "$WS/summary")" "| android | \`production\` | \`rv-a\` | \`old\` | \`older\` | native |" 'summary row'; then
    pass_case
fi

case_start "a channel with no update and no build decides native"
check
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals native "$(out decision)" 'decision' \
    && assert_equals ios,android "$(out changed-targets)" 'changed'; then
    pass_case
fi

for failing in VIEW_FAIL UPDATES_FAIL BUILDS_FAIL; do
    case_start "$failing: an EAS query that fails decides native, never ota"
    check UPDATE_RV_production_ios=rv-i UPDATE_RV_production_android=rv-a "$failing=1"
    if assert_equals 0 "$STEP_STATUS" 'status' \
        && assert_equals native "$(out decision)" 'decision' \
        && assert_contains "$(out reason)" 'could not be read' 'reason'; then
        pass_case
    fi
done

case_start "a channel serving two branches (a rollout) is compared with the latest update of each"
check EXTRA_BRANCH=rollout UPDATE_RV_production_ios=old UPDATE_RV_rollout_ios=rv-i UPDATE_RV_production_android=rv-a PLATFORM=ios
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals ota "$(out decision)" 'decision' \
    && assert_contains "$(calls)" 'update:list --branch rollout --platform ios' 'second branch queried'; then
    pass_case
fi

case_start "the channel and env come from the eas.json profile when channel is empty"
check CHANNEL='' PROFILE_CHANNEL=brand-production EAS_PROFILE=brand PROFILE_ENV='APP_VARIANT=brand' PLATFORM=android \
    UPDATE_RV_brand_production_android=rv-a
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals ota "$(out decision)" 'decision' \
    && assert_contains "$(calls)" 'channel:view brand-production' 'profile channel' \
    && assert_equals '[{"name":"android","platform":"android","channel":"brand-production","envLines":"APP_VARIANT=brand","buildProfile":"brand"}]' "$(step_output "$WS" targets)" 'targets handed to ota-runtime-version'; then
    pass_case
fi

case_start "targets compare each target with its own channel under its own env"
check CHANNEL='' TARGETS='[
  {"name":"a-ios","platform":"ios","channel":"a-production","buildProfile":"a","envLines":"APP_VARIANT=a"},
  {"name":"b-ios","platform":"ios","channel":"b-production","buildProfile":"b","envLines":"APP_VARIANT=b","submitProfile":"production"}]' \
    UPDATE_RV_a_production_ios=rv-i RUNTIMES='{"a-ios":"rv-i","b-ios":"rv-i"}'
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals native "$(out decision)" 'decision' \
    && assert_equals b-ios "$(out changed-targets)" 'changed' \
    && assert_equals '{"a-ios":"rv-i","b-ios":"rv-i"}' "$(out runtime-versions)" 'runtime versions'; then
    pass_case
fi

case_start "a target without a resolved runtime version fails the step"
check RUNTIMES='{"ios":"rv-i"}' UPDATE_RV_production_ios=rv-i
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$WS/log")" 'No runtime version was resolved for android' 'message' \
    && assert_equals '' "$(out decision)" 'no decision'; then
    pass_case
fi

case_start "baseline build ignores a matching update and needs a matching finished build"
check BASELINE=build UPDATE_RV_production_ios=rv-i UPDATE_RV_production_android=rv-a BUILD_RV_production_ios=rv-i
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals native "$(out decision)" 'decision' \
    && assert_equals android "$(out changed-targets)" 'changed' \
    && assert_not_contains "$(calls)" 'update:list' 'updates never consulted' \
    && assert_contains "$(out reason)" "not the latest finished build's (none)" 'reason'; then
    pass_case
fi

case_start "baseline build with a matching build on every platform decides ota"
check BASELINE=build BUILD_RV_production_ios=rv-i BUILD_RV_production_android=rv-a
if assert_equals 0 "$STEP_STATUS" 'status' && assert_equals ota "$(out decision)" 'decision'; then
    pass_case
fi

case_start "a missing Expo token fails the step before anything runs"
check EXPO_TOKEN_INPUT=''
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$WS/log")" 'needs an Expo access token' 'message' \
    && assert_equals '' "$(calls)" 'no call'; then
    pass_case
fi

for bad in 'PLATFORM=web|platform must be' 'CHANNEL=|no channel' 'TARGETS=[]|targets must be' 'BASELINE=any|baseline must be' \
    'TARGETS=[{"name":"x","platform":"ios"}]|targets must be' \
    'TARGETS=[{"name":"x","platform":"ios","channel":"-c"}]|targets must be' \
    'TARGETS=not json|targets must be'; do
    setting="${bad%%|*}"
    message="${bad#*|}"
    case_start "invalid input fails the step: $setting"
    check "$setting"
    if assert_equals 1 "$STEP_STATUS" 'status' \
        && assert_contains "$(cat "$WS/log")" "$message" 'message' \
        && assert_equals '' "$(out decision)" 'no decision'; then
        pass_case
    fi
done

finish_suite
