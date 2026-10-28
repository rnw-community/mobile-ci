#!/usr/bin/env bash
# eas-profile-env is the one eas.json build-profile resolver behind
# native-publish.yml's plan, eas-update and eas-channel-fingerprint: the env,
# channel and EAS environment a profile resolves to once its `extends` chain is
# followed. An OTA evaluated under a different env than the binary it lands on
# carries a different app config, so every malformed profile fails closed.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION_YML="$REPO_ROOT/actions/eas-profile-env/action.yml"
STEP='Resolve the eas.json build profiles'

EAS_JSON='{
  "build": {
    "base": {"env": {"APP_VARIANT": "base", "SHARED": "from-base"}, "channel": "base", "environment": "preview"},
    "production": {"extends": "base", "env": {"APP_VARIANT": "production"}, "channel": "production", "environment": "production"},
    "brand-a": {"extends": "production", "env": {"APP_BRAND": "a"}, "channel": "brand-a-production"},
    "bare": {},
    "loop-a": {"extends": "loop-b"},
    "loop-b": {"extends": "loop-a"},
    "orphan": {"extends": "missing"},
    "numeric": {"env": {"PORT": 8080}},
    "bad-name": {"env": {"1BAD": "x"}},
    "bad-channel": {"channel": 1}
  }
}'

workspace() {
    local ws
    ws="$(new_workspace "$ACTION_YML" "$STEP")"
    mkdir -p "$ws/work/apps/mobile"
    printf '%s\n' "$EAS_JSON" > "$ws/work/apps/mobile/eas.json"
    printf '%s\n' "$ws"
}

resolve() {
    WS="$(workspace)"
    run_step "$WS" APP_DIR=apps/mobile PROFILES="$1"
}

field() {
    jq -r "$1" <<< "$(step_output "$WS" resolved)"
}

case_start "a profile resolves env, channel and environment through extends, child wins"
resolve production
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals $'APP_VARIANT=production\nSHARED=from-base' "$(step_output "$WS" env-lines)" 'env-lines' \
    && assert_equals production "$(step_output "$WS" channel)" 'channel' \
    && assert_equals production "$(step_output "$WS" environment)" 'environment'; then
    pass_case
fi

case_start "a three-level chain merges every level and inherits what the child leaves unset"
resolve brand-a
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals $'APP_VARIANT=production\nSHARED=from-base\nAPP_BRAND=a' "$(step_output "$WS" env-lines)" 'env-lines' \
    && assert_equals brand-a-production "$(step_output "$WS" channel)" 'own channel' \
    && assert_equals production "$(step_output "$WS" environment)" 'inherited environment'; then
    pass_case
fi

case_start "several profiles resolve into one map, and the single-profile outputs stay empty"
resolve $'production\n  brand-a  \n\nproduction'
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals 'brand-a,production' "$(field 'keys | join(",")')" 'profiles' \
    && assert_equals 'APP_BRAND=a' "$(field '.["brand-a"].envLines | split("\n") | last')" 'brand-a env' \
    && assert_equals '' "$(step_output "$WS" env-lines)" 'no single env-lines' \
    && assert_equals '' "$(step_output "$WS" channel)" 'no single channel'; then
    pass_case
fi

case_start "a profile without env, channel or environment resolves to empty values"
resolve bare
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals '' "$(step_output "$WS" env-lines)" 'env-lines' \
    && assert_equals '' "$(step_output "$WS" channel)" 'channel' \
    && assert_equals 'null' "$(field '.bare.channel')" 'null channel in the map'; then
    pass_case
fi

for bad in 'loop-a|loop-a -> loop-b -> loop-a' \
    'staging|eas.json has no build profile "staging"' \
    'orphan|"missing" (extended by "orphan")' \
    'numeric|PORT must be single-line strings' \
    'bad-name|1BAD must match' \
    'bad-channel|channel is not a string' \
    '|no build profile to resolve'; do
    profile="${bad%%|*}"
    message="${bad#*|}"
    case_start "profile '${profile}' fails closed"
    resolve "$profile"
    if assert_equals 1 "$STEP_STATUS" 'status' \
        && assert_contains "$(cat "$WS/log")" "$message" 'message' \
        && assert_equals '' "$(step_output "$WS" resolved)" 'nothing resolved'; then
        pass_case
    fi
done

case_start "a missing eas.json fails closed"
WS="$(workspace)"
rm "$WS/work/apps/mobile/eas.json"
run_step "$WS" APP_DIR=apps/mobile PROFILES=production
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(cat "$WS/log")" 'No eas.json' 'message'; then
    pass_case
fi

case_start "an eas.json that is not an object fails closed"
WS="$(workspace)"
printf '[]\n' > "$WS/work/apps/mobile/eas.json"
run_step "$WS" APP_DIR=apps/mobile PROFILES=production
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(cat "$WS/log")" 'is not a JSON object' 'message'; then
    pass_case
fi

finish_suite
