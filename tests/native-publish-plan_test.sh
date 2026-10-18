#!/usr/bin/env bash
# native-publish.yml's plan job decides what a store release does: which
# targets it builds, the env every eas build / eas submit / hook sees (the
# eas.json build profile env with `extends` resolved, so submit resolves the
# same app config the build did), the build number, and whether the release
# needs a native build at all or only an OTA. Each of those is a fail-closed
# decision that ships, or fails to ship, a binary to the stores; this suite
# runs the extracted step scripts against stubbed gh/npx and pins every
# branch, plus the step order that makes the env reach eas submit.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

WORKFLOW_YML="$REPO_ROOT/.github/workflows/native-publish.yml"
TARGETS_STEP='Resolve publish targets and their eas.json profile env'
VERSION_STEP='Resolve the store build number and marketing version'
BASELINE_STEP='Resolve the store baseline'
DECIDE_STEP='Decide between a native build and an OTA'
FINGERPRINT_STEP='Fingerprint every target under its build env'

EAS_JSON='{
  "cli": {"appVersionSource": "local"},
  "build": {
    "base": {"env": {"APP_VARIANT": "base", "SHARED": "from-base"}},
    "production": {"extends": "base", "env": {"APP_VARIANT": "production"}},
    "brand-a": {"extends": "production", "env": {"APP_BRAND": "a"}},
    "brand-b": {"extends": "production", "env": {"APP_BRAND": "b"}},
    "loop-a": {"extends": "loop-b"},
    "loop-b": {"extends": "loop-a"},
    "orphan": {"extends": "missing"},
    "numeric": {"env": {"PORT": 8080}},
    "bad-name": {"env": {"1BAD": "x"}}
  },
  "submit": {"production": {}}
}'

# targets_workspace: a plan workspace with EAS_JSON at apps/mobile/eas.json
targets_workspace() {
    local workspace
    workspace="$(new_workflow_workspace "$WORKFLOW_YML" plan "$TARGETS_STEP")"
    mkdir -p "$workspace/work/apps/mobile"
    printf '%s\n' "$EAS_JSON" > "$workspace/work/apps/mobile/eas.json"
    printf '%s\n' "$workspace"
}

run_targets() {
    local workspace="$1"
    shift
    run_step "$workspace" APP_DIR=apps/mobile TARGETS='' ENABLE_IOS=true ENABLE_ANDROID=false \
        BUILD_PROFILE=production SUBMIT_PROFILE=production MODE=native WRITE_STORE_RECORD=false \
        RELEASE_TAG_INPUT='' REF_TYPE=branch REF_NAME=main "$@"
}

target_field() {
    jq -r "$2" <<< "$(step_output "$1" targets)"
}

log_of() {
    cat "$1/log"
}

# --- eas.json profile env, following extends -------------------------------

case_start "targets: single-profile inputs resolve the profile env through extends, child wins"
ws="$(targets_workspace)"
run_targets "$ws" ENABLE_ANDROID=true
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals 'ios,android' "$(target_field "$ws" '[.[].name] | join(",")')" 'legacy target names' \
    && assert_equals $'APP_VARIANT=production\nSHARED=from-base' "$(target_field "$ws" '.[0].envLines')" 'resolved env' \
    && assert_equals '' "$(target_field "$ws" '.[0].artifactSuffix')" 'legacy artifact suffix keeps today''s artifact names' \
    && assert_equals true "$(step_output "$ws" has-ios)" 'has-ios' \
    && assert_equals true "$(step_output "$ws" has-android)" 'has-android' \
    && assert_equals false "$(step_output "$ws" record)" 'mode native writes no record' \
    && assert_equals store-record-apps-mobile.json "$(step_output "$ws" record-asset)" 'record asset scoped to app-dir'; then
    pass_case
fi

case_start "targets: a three-level extends chain merges every level"
ws="$(targets_workspace)"
run_targets "$ws" BUILD_PROFILE=brand-a
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals $'APP_VARIANT=production\nSHARED=from-base\nAPP_BRAND=a' "$(target_field "$ws" '.[0].envLines')" 'resolved env'; then
    pass_case
fi

case_start "targets: an extends cycle fails closed and names the chain"
ws="$(targets_workspace)"
run_targets "$ws" BUILD_PROFILE=loop-a
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(log_of "$ws")" 'loop-a -> loop-b -> loop-a' 'cycle chain'; then
    pass_case
fi

case_start "targets: an unknown build profile fails closed"
ws="$(targets_workspace)"
run_targets "$ws" BUILD_PROFILE=staging
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(log_of "$ws")" 'eas.json has no build profile "staging"' 'unknown profile'; then
    pass_case
fi

case_start "targets: extending an unknown profile fails closed and names the profile extending it"
ws="$(targets_workspace)"
run_targets "$ws" BUILD_PROFILE=orphan
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(log_of "$ws")" '"missing" (extended by "orphan")' 'unknown parent'; then
    pass_case
fi

case_start "targets: a non-string profile env value fails closed"
ws="$(targets_workspace)"
run_targets "$ws" BUILD_PROFILE=numeric
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(log_of "$ws")" 'PORT must be single-line strings' 'non-string value'; then
    pass_case
fi

case_start "targets: an invalid profile env name fails closed"
ws="$(targets_workspace)"
run_targets "$ws" BUILD_PROFILE=bad-name
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(log_of "$ws")" '1BAD must match' 'bad name'; then
    pass_case
fi

case_start "targets: a missing eas.json fails closed"
ws="$(targets_workspace)"
rm "$ws/work/apps/mobile/eas.json"
run_targets "$ws"
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(log_of "$ws")" 'No eas.json' 'message'; then
    pass_case
fi

case_start "targets: no enabled platform fails closed"
ws="$(targets_workspace)"
run_targets "$ws" ENABLE_IOS=false
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(log_of "$ws")" 'No publish target' 'message'; then
    pass_case
fi

# --- targets matrix ----------------------------------------------------------

case_start "targets: a brand x platform matrix resolves each brand's own profile env and defaults"
ws="$(targets_workspace)"
run_targets "$ws" TARGETS='[
  {"name":"a-ios","platform":"ios","buildProfile":"brand-a","submitProfile":"production"},
  {"platform":"android","buildProfile":"brand-b"}]'
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals 'a-ios,brand-b-android' "$(target_field "$ws" '[.[].name] | join(",")')" 'names (default <buildProfile>-<platform>)' \
    && assert_equals 'production' "$(target_field "$ws" '.[1].submitProfile')" 'submit profile defaults to submit-profile' \
    && assert_equals '-a-ios' "$(target_field "$ws" '.[0].artifactSuffix')" 'artifact suffix' \
    && assert_contains "$(target_field "$ws" '.[1].envLines')" 'APP_BRAND=b' 'brand b env' \
    && assert_equals '["a-ios"]' "$(jq -c '[.[].name]' <<< "$(step_output "$ws" ios-targets)")" 'ios matrix' \
    && assert_equals '["brand-b-android"]' "$(jq -c '[.[].name]' <<< "$(step_output "$ws" android-targets)")" 'android matrix'; then
    pass_case
fi

for bad in '{"platform":"ios"}|must be a JSON array' \
    '[]|empty array' \
    '[{"platform":"web"}]|platform ios or android' \
    '[{"platform":"ios","profile":"x"}]|unknown key(s): profile' \
    '[{"platform":"ios","name":"x"},{"platform":"android","name":"x"}]|duplicate targets name(s): x' \
    '[{"platform":"ios","name":"has space"}]|must match' \
    '[{"platform":"ios","buildProfile":"staging"}]|no build profile' \
    'not json|'; do
    input="${bad%%|*}"
    message="${bad#*|}"
    case_start "targets: rejects $input"
    ws="$(targets_workspace)"
    run_targets "$ws" TARGETS="$input"
    if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(log_of "$ws")" "$message" 'message'; then
        pass_case
    fi
done

# --- mode and release tag ------------------------------------------------------

case_start "targets: an unknown mode fails closed"
ws="$(targets_workspace)"
run_targets "$ws" MODE=sometimes
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(log_of "$ws")" 'mode must be' 'message'; then
    pass_case
fi

for mode in auto ota-only; do
    case_start "targets: mode $mode without a release tag fails closed"
    ws="$(targets_workspace)"
    run_targets "$ws" MODE="$mode"
    if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(log_of "$ws")" 'needs a release tag' 'message'; then
        pass_case
    fi
done

case_start "targets: write-store-record in mode native also needs a release tag"
ws="$(targets_workspace)"
run_targets "$ws" WRITE_STORE_RECORD=true
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(log_of "$ws")" 'needs a release tag' 'message'; then
    pass_case
fi

case_start "targets: mode auto on a tag run records under the triggering tag"
ws="$(targets_workspace)"
run_targets "$ws" MODE=auto REF_TYPE=tag REF_NAME=v1.4.0
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals v1.4.0 "$(step_output "$ws" release-tag)" 'release tag' \
    && assert_equals true "$(step_output "$ws" record)" 'record'; then
    pass_case
fi

case_start "targets: release-tag overrides the triggering ref"
ws="$(targets_workspace)"
run_targets "$ws" MODE=auto RELEASE_TAG_INPUT=mobile@2.0.0
if assert_equals 0 "$STEP_STATUS" 'status' && assert_equals mobile@2.0.0 "$(step_output "$ws" release-tag)" 'release tag'; then
    pass_case
fi

case_start "targets: app-dir '.' scopes the record asset to root"
ws="$(targets_workspace)"
cp "$ws/work/apps/mobile/eas.json" "$ws/work/eas.json"
run_targets "$ws" APP_DIR=.
if assert_equals 0 "$STEP_STATUS" 'status' && assert_equals store-record-root.json "$(step_output "$ws" record-asset)" 'asset'; then
    pass_case
fi

# --- build number ---------------------------------------------------------------

version_workspace() {
    local workspace
    workspace="$(new_workflow_workspace "$WORKFLOW_YML" plan "$VERSION_STEP")"
    # shellcheck disable=SC2016
    stub "$workspace" gh '
printf "%s\n" "$*" >> "$(dirname "$0")/../gh-calls"
[ -z "${GH_FAIL:-}" ] || exit 1
printf "%s\n" "$CREATED_AT"'
    printf '%s\n' "$workspace"
}

run_version() {
    local workspace="$1"
    shift
    run_step "$workspace" BUILD_NUMBER_INPUT='' MARKETING_VERSION_INPUT=auto RELEASE_TAG='' \
        GH_TOKEN=token REPOSITORY=owner/app RUN_ID=4242 CREATED_AT=2026-10-18T09:30:59Z "$@"
}

case_start "build-number: empty exports nothing (today's behaviour)"
ws="$(version_workspace)"
run_version "$ws"
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals '' "$(step_output "$ws" build-number)" 'build number' \
    && assert_equals '' "$(cat "$ws/gh-calls" 2>/dev/null || true)" 'no API call'; then
    pass_case
fi

case_start "build-number: auto is whole minutes since the epoch at run creation"
ws="$(version_workspace)"
run_version "$ws" BUILD_NUMBER_INPUT=auto
expected=$(( $(date -u -d 2026-10-18T09:30:59Z +%s) / 60 ))
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals "$expected" "$(step_output "$ws" build-number)" 'build number' \
    && assert_equals 29871930 "$expected" 'known value for 2026-10-18T09:30Z' \
    && assert_contains "$(cat "$ws/gh-calls")" 'repos/owner/app/actions/runs/4242' 'reads the run, not the attempt'; then
    pass_case
fi

case_start "build-number: auto reads created_at, which every re-run attempt shares"
ws="$(version_workspace)"
run_version "$ws" BUILD_NUMBER_INPUT=auto
first="$(step_output "$ws" build-number)"
ws="$(version_workspace)"
run_version "$ws" BUILD_NUMBER_INPUT=auto
if assert_contains "$(cat "$ws/gh-calls")" '.created_at' 'created_at, not run_started_at' \
    && assert_equals "$first" "$(step_output "$ws" build-number)" 'same number on a re-run'; then
    pass_case
fi

case_start "build-number: auto stays inside Android's versionCode limit for millennia"
ws="$(version_workspace)"
run_version "$ws" BUILD_NUMBER_INPUT=auto CREATED_AT=2999-12-31T23:59:59Z
year_3000="$(step_output "$ws" build-number)"
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals 1 "$(( year_3000 < 2100000000 ))" "year-2999 build number $year_3000 below 2100000000" \
    && assert_equals 1 "$(( (2100000000 * 60) > $(date -u -d 5900-01-01T00:00:00Z +%s) ))" 'limit reached only after the year 5900'; then
    pass_case
fi

case_start "build-number: auto fails closed when the run API is unreadable"
ws="$(version_workspace)"
run_version "$ws" BUILD_NUMBER_INPUT=auto GH_FAIL=1
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(log_of "$ws")" "actions: read" 'message'; then
    pass_case
fi

case_start "build-number: auto fails closed on an unparseable created_at"
ws="$(version_workspace)"
run_version "$ws" BUILD_NUMBER_INPUT=auto CREATED_AT=yesterday-ish
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(log_of "$ws")" 'Cannot parse' 'message'; then
    pass_case
fi

case_start "build-number: the versionCode maximum is accepted as is"
ws="$(version_workspace)"
run_version "$ws" BUILD_NUMBER_INPUT=2100000000
if assert_equals 0 "$STEP_STATUS" 'status' && assert_equals 2100000000 "$(step_output "$ws" build-number)" 'build number'; then
    pass_case
fi

for bad in 2100000001 99999999999 0 007 -3 12.5 latest; do
    case_start "build-number: rejects '$bad'"
    ws="$(version_workspace)"
    run_version "$ws" BUILD_NUMBER_INPUT="$bad"
    if assert_equals 1 "$STEP_STATUS" 'status' && assert_equals '' "$(step_output "$ws" build-number)" 'no output'; then
        pass_case
    fi
done

# --- marketing version ------------------------------------------------------------

for row in 'auto|v1.2.3|1.2.3' 'auto|mobile@v2.0|2.0' 'auto|7|7' 'auto|release-2026|' 'auto||' \
    'tag|v3.1.4|3.1.4' 'none|v1.2.3|' '4.5.6|v1.2.3|4.5.6'; do
    IFS='|' read -r input tag expected <<< "$row"
    case_start "marketing-version: $input with tag '${tag:-<none>}' exports '${expected:-<nothing>}'"
    ws="$(version_workspace)"
    run_version "$ws" MARKETING_VERSION_INPUT="$input" RELEASE_TAG="$tag"
    if assert_equals 0 "$STEP_STATUS" 'status' && assert_equals "$expected" "$(step_output "$ws" marketing-version)" 'marketing version'; then
        pass_case
    fi
done

for row in 'tag|release-2026' 'tag|' '1.2.3.4|v1.0.0' 'one|v1.0.0'; do
    IFS='|' read -r input tag <<< "$row"
    case_start "marketing-version: $input with tag '${tag:-<none>}' fails closed"
    ws="$(version_workspace)"
    run_version "$ws" MARKETING_VERSION_INPUT="$input" RELEASE_TAG="$tag"
    if assert_equals 1 "$STEP_STATUS" 'status'; then
        pass_case
    fi
done

# --- fingerprints ------------------------------------------------------------------

case_start "fingerprint: each target is hashed under its profile env, then publish-env, then the store version"
ws="$(new_workflow_workspace "$WORKFLOW_YML" plan "$FINGERPRINT_STEP")"
# shellcheck disable=SC2016
stub "$ws" npx '
printf "%s APP_BRAND=%s APP_VARIANT=%s EXTRA=%s STORE_BUILD_NUMBER=%s EAS_BUILD_PROFILE=%s\n" "${*: -1}" "${APP_BRAND:-}" "${APP_VARIANT:-}" "${EXTRA:-}" "${STORE_BUILD_NUMBER:-}" "${EAS_BUILD_PROFILE:-}" >> "$(dirname "$0")/../npx-calls"
printf "{\"hash\":\"hash-%s-%s\"}" "${APP_BRAND:-none}" "${*: -1}"'
run_step "$ws" FINGERPRINT_VERSION=0.20.6 PUBLISH_ENV=$'EXTRA=1\nAPP_VARIANT=override' \
    STORE_BUILD_NUMBER_VALUE=29854170 STORE_MARKETING_VERSION_VALUE='' \
    TARGETS='[{"name":"a-ios","platform":"ios","buildProfile":"brand-a","envLines":"APP_VARIANT=production\nAPP_BRAND=a"},
              {"name":"b-android","platform":"android","buildProfile":"brand-b","envLines":"APP_BRAND=b"}]'
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals '{"a-ios":"hash-a-ios","b-android":"hash-b-android"}' "$(step_output "$ws" fingerprints)" 'fingerprints' \
    && assert_contains "$(cat "$ws/npx-calls")" 'ios APP_BRAND=a APP_VARIANT=override EXTRA=1 STORE_BUILD_NUMBER=29854170 EAS_BUILD_PROFILE=brand-a' 'ios env'; then
    pass_case
fi

case_start "fingerprint: EAS_EXTRA_ENV the plan job applied for the install stays out of every fingerprint"
ws="$(new_workflow_workspace "$WORKFLOW_YML" plan "$FINGERPRINT_STEP")"
# shellcheck disable=SC2016
stub "$ws" npx '
printf "TURBO_TOKEN=%s MAPS_KEY=%s APP_BRAND=%s\n" "${TURBO_TOKEN:-unset}" "${MAPS_KEY:-unset}" "${APP_BRAND:-unset}" >> "$(dirname "$0")/../npx-calls"
printf "{\"hash\":\"h\"}"'
run_step "$ws" FINGERPRINT_VERSION=0.20.6 PUBLISH_ENV='' STORE_BUILD_NUMBER_VALUE='' STORE_MARKETING_VERSION_VALUE='' \
    TURBO_TOKEN=secret-turbo MAPS_KEY=secret-maps EAS_EXTRA_ENV_NAMES=$'TURBO_TOKEN\nMAPS_KEY' \
    TARGETS='[{"name":"ios","platform":"ios","buildProfile":"production","envLines":"APP_BRAND=a"}]'
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals 'TURBO_TOKEN=unset MAPS_KEY=unset APP_BRAND=a' "$(cat "$ws/npx-calls")" 'fingerprint env'; then
    pass_case
fi

case_start "fingerprint: an empty hash fails closed after the retry"
ws="$(new_workflow_workspace "$WORKFLOW_YML" plan "$FINGERPRINT_STEP")"
stub "$ws" npx 'printf "{}"'
run_step "$ws" FINGERPRINT_VERSION=0.20.6 PUBLISH_ENV='' STORE_BUILD_NUMBER_VALUE='' STORE_MARKETING_VERSION_VALUE='' \
    TARGETS='[{"name":"ios","platform":"ios","buildProfile":"production","envLines":""}]'
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(log_of "$ws")" 'wrote no hash' 'message'; then
    pass_case
fi

case_start "fingerprint: a failing generate fails closed after one retry"
ws="$(new_workflow_workspace "$WORKFLOW_YML" plan "$FINGERPRINT_STEP")"
# shellcheck disable=SC2016
stub "$ws" npx 'echo x >> "$(dirname "$0")/../npx-calls"; exit 3'
run_step "$ws" FINGERPRINT_VERSION=0.20.6 PUBLISH_ENV='' STORE_BUILD_NUMBER_VALUE='' STORE_MARKETING_VERSION_VALUE='' \
    TARGETS='[{"name":"ios","platform":"ios","buildProfile":"production","envLines":""}]'
if assert_equals 1 "$STEP_STATUS" 'status' && assert_equals 2 "$(wc -l < "$ws/npx-calls" | tr -d ' ')" 'attempts'; then
    pass_case
fi

# --- baseline ------------------------------------------------------------------------

record_json() {
    # record_json <recordedAt> <targets json>
    jq -nc --arg at "$1" --argjson targets "$2" '{schema: 1, recordedAt: $at, targets: $targets}'
}

baseline_workspace() {
    local workspace
    workspace="$(new_workflow_workspace "$WORKFLOW_YML" plan "$BASELINE_STEP")"
    mkdir -p "$workspace/assets"
    # shellcheck disable=SC2016
    stub "$workspace" gh '
dir="$(dirname "$0")/.."
[ -z "${GH_FAIL:-}" ] || exit 1
case "$*" in
  *releases/assets/*) last="${!#}"; cat "$dir/assets/${last##*/}.json" ;;
  *releases?per_page=100*) cat "$dir/releases.json" ;;
  *) exit 9 ;;
esac'
    printf '%s\n' "$workspace"
}

BOTH='{"ios":{"platform":"ios","fingerprint":"i1"},"android":{"platform":"android","fingerprint":"a1"}}'
TARGET_PAIR='[{"name":"ios","platform":"ios"},{"name":"android","platform":"android"}]'

case_start "baseline: the most recently recorded complete record wins; partial, draft and current-tag records do not"
ws="$(baseline_workspace)"
record_json 2026-01-01T00:00:00Z "$BOTH" > "$ws/assets/1.json"
record_json 2026-03-01T00:00:00Z '{"ios":{"platform":"ios","fingerprint":"i3"}}' > "$ws/assets/2.json"
record_json 2026-02-01T00:00:00Z "$BOTH" > "$ws/assets/3.json"
record_json 2026-04-01T00:00:00Z "$BOTH" > "$ws/assets/4.json"
record_json 2026-05-01T00:00:00Z "$BOTH" > "$ws/assets/5.json"
cat > "$ws/releases.json" <<'JSON'
[[{"tag_name":"v1.0.0","draft":false,"assets":[{"name":"store-record-root.json","id":1},{"name":"notes.txt","id":99}]},
  {"tag_name":"v1.2.0","draft":false,"assets":[{"name":"store-record-root.json","id":2}]}],
 [{"tag_name":"v1.1.0","draft":false,"assets":[{"name":"store-record-root.json","id":3}]},
  {"tag_name":"v1.3.0","draft":true,"assets":[{"name":"store-record-root.json","id":4}]},
  {"tag_name":"v2.0.0","draft":false,"assets":[{"name":"store-record-root.json","id":5}]},
  {"tag_name":"v0.9.0","draft":false,"assets":[{"name":"store-record-other.json","id":6}]}]]
JSON
run_step "$ws" GH_TOKEN=t REPOSITORY=owner/app RELEASE_TAG=v2.0.0 RECORD_ASSET=store-record-root.json TARGETS="$TARGET_PAIR"
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals v1.1.0 "$(step_output "$ws" baseline-tag)" 'baseline tag' \
    && assert_contains "$(log_of "$ws")" 'Release v1.2.0: record does not show every current target shipped' 'partial skipped'; then
    pass_case
fi

case_start "baseline: a record whose target changed platform is not a baseline"
ws="$(baseline_workspace)"
record_json 2026-01-01T00:00:00Z '{"ios":{"platform":"android","fingerprint":"i1"},"android":{"platform":"android","fingerprint":"a1"}}' > "$ws/assets/1.json"
echo '[[{"tag_name":"v1.0.0","draft":false,"assets":[{"name":"store-record-root.json","id":1}]}]]' > "$ws/releases.json"
run_step "$ws" GH_TOKEN=t REPOSITORY=owner/app RELEASE_TAG=v2.0.0 RECORD_ASSET=store-record-root.json TARGETS="$TARGET_PAIR"
if assert_equals 0 "$STEP_STATUS" 'status' && assert_equals '' "$(step_output "$ws" baseline-tag)" 'no baseline'; then
    pass_case
fi

case_start "baseline: no releases means no baseline, not an error"
ws="$(baseline_workspace)"
echo '[[]]' > "$ws/releases.json"
run_step "$ws" GH_TOKEN=t REPOSITORY=owner/app RELEASE_TAG=v1.0.0 RECORD_ASSET=store-record-root.json TARGETS="$TARGET_PAIR"
if assert_equals 0 "$STEP_STATUS" 'status' && assert_equals '' "$(step_output "$ws" baseline-file)" 'no baseline'; then
    pass_case
fi

case_start "baseline: an unreadable release list fails closed"
ws="$(baseline_workspace)"
run_step "$ws" GH_TOKEN=t REPOSITORY=owner/app RELEASE_TAG=v1.0.0 RECORD_ASSET=store-record-root.json TARGETS="$TARGET_PAIR" GH_FAIL=1
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(log_of "$ws")" 'Cannot list the releases' 'message'; then
    pass_case
fi

case_start "baseline: a corrupt record fails closed"
ws="$(baseline_workspace)"
echo '{"targets":"nope"}' > "$ws/assets/1.json"
echo '[[{"tag_name":"v1.0.0","draft":false,"assets":[{"name":"store-record-root.json","id":1}]}]]' > "$ws/releases.json"
run_step "$ws" GH_TOKEN=t REPOSITORY=owner/app RELEASE_TAG=v2.0.0 RECORD_ASSET=store-record-root.json TARGETS="$TARGET_PAIR"
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(log_of "$ws")" 'not a schema-1 store build record' 'message'; then
    pass_case
fi

# --- decision -----------------------------------------------------------------------

decide() {
    local workspace
    workspace="$(new_workflow_workspace "$WORKFLOW_YML" plan "$DECIDE_STEP")"
    if [ -n "${BASELINE:-}" ]; then
        printf '%s\n' "$BASELINE" > "$workspace/baseline.json"
        run_step "$workspace" TARGETS="$TARGET_PAIR" BASELINE_TAG=v1.0.0 BASELINE_FILE="$workspace/baseline.json" "$@"
    else
        run_step "$workspace" TARGETS="$TARGET_PAIR" BASELINE_TAG='' BASELINE_FILE='' "$@"
    fi
    DECIDE_WS="$workspace"
}

case_start "decision: mode native always builds, without fingerprints or a baseline"
BASELINE='' decide MODE=native FINGERPRINTS=''
if assert_equals 0 "$STEP_STATUS" 'status' && assert_equals native "$(step_output "$DECIDE_WS" decision)" 'decision'; then
    pass_case
fi

case_start "decision: auto with no baseline builds natively"
BASELINE='' decide MODE=auto FINGERPRINTS='{"ios":"i1","android":"a1"}'
if assert_equals 0 "$STEP_STATUS" 'status' && assert_equals native "$(step_output "$DECIDE_WS" decision)" 'decision'; then
    pass_case
fi

case_start "decision: ota-only with no baseline fails closed"
BASELINE='' decide MODE=ota-only FINGERPRINTS='{"ios":"i1","android":"a1"}'
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_equals '' "$(step_output "$DECIDE_WS" decision)" 'no decision' \
    && assert_contains "$(log_of "$DECIDE_WS")" 'found no release' 'message'; then
    pass_case
fi

case_start "decision: auto with every runtime unchanged ships an OTA"
BASELINE="$(record_json 2026-01-01T00:00:00Z "$BOTH")" decide MODE=auto FINGERPRINTS='{"ios":"i1","android":"a1"}'
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals ota "$(step_output "$DECIDE_WS" decision)" 'decision' \
    && assert_equals '' "$(step_output "$DECIDE_WS" changed-targets)" 'changed' \
    && assert_contains "$(cat "$DECIDE_WS/summary")" "| android | \`a1\` | \`a1\` |" 'summary row'; then
    pass_case
fi

case_start "decision: auto with one changed runtime builds natively and names it"
BASELINE="$(record_json 2026-01-01T00:00:00Z "$BOTH")" decide MODE=auto FINGERPRINTS='{"ios":"i1","android":"a2"}'
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals native "$(step_output "$DECIDE_WS" decision)" 'decision' \
    && assert_equals android "$(step_output "$DECIDE_WS" changed-targets)" 'changed'; then
    pass_case
fi

case_start "decision: ota-only with every runtime unchanged ships an OTA"
BASELINE="$(record_json 2026-01-01T00:00:00Z "$BOTH")" decide MODE=ota-only FINGERPRINTS='{"ios":"i1","android":"a1"}'
if assert_equals 0 "$STEP_STATUS" 'status' && assert_equals ota "$(step_output "$DECIDE_WS" decision)" 'decision'; then
    pass_case
fi

case_start "decision: ota-only with a changed runtime fails closed"
BASELINE="$(record_json 2026-01-01T00:00:00Z "$BOTH")" decide MODE=ota-only FINGERPRINTS='{"ios":"i2","android":"a2"}'
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(log_of "$DECIDE_WS")" 'ios,android changed' 'message'; then
    pass_case
fi

case_start "decision: a target without a fingerprint fails closed"
BASELINE="$(record_json 2026-01-01T00:00:00Z "$BOTH")" decide MODE=auto FINGERPRINTS='{"ios":"i1"}'
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(log_of "$DECIDE_WS")" 'No fingerprint was computed for target android' 'message'; then
    pass_case
fi

# --- applying the env in the publish jobs ---------------------------------------------

for job in ios-publish android-lint-gate android-publish; do
    case_start "$job: the resolved profile env reaches \$GITHUB_ENV and a drifting publish-env override warns"
    ws="$(new_workflow_workspace "$WORKFLOW_YML" "$job" 'Apply eas.json build profile env')"
    run_step "$ws" PROFILE_ENV=$'APP_VARIANT=production\nURL=https://x.test/?a=b' BUILD_PROFILE=production \
        PUBLISH_ENV=$'APP_VARIANT=staging\nOTHER=1'
    if assert_equals 0 "$STEP_STATUS" 'status' \
        && assert_equals $'APP_VARIANT=production\nURL=https://x.test/?a=b' "$(cat "$ws/env")" 'GITHUB_ENV' \
        && assert_contains "$(log_of "$ws")" '::warning::publish-env sets APP_VARIANT' 'drift warning' \
        && assert_not_contains "$(log_of "$ws")" 'publish-env sets URL' 'no warning for an unset key'; then
        pass_case
    fi
done

case_start "ios-publish: a malformed resolved env line fails closed"
ws="$(new_workflow_workspace "$WORKFLOW_YML" ios-publish 'Apply eas.json build profile env')"
run_step "$ws" PROFILE_ENV='NO_EQUALS' BUILD_PROFILE=production PUBLISH_ENV=''
if assert_equals 1 "$STEP_STATUS" 'status' && assert_equals '' "$(cat "$ws/env")" 'nothing written'; then
    pass_case
fi

# --- the store build record -------------------------------------------------------------

record_workspace() {
    local workspace
    workspace="$(new_workflow_workspace "$WORKFLOW_YML" record 'Write the store build record to the release')"
    mkdir -p "$workspace/markers"
    # shellcheck disable=SC2016
    stub "$workspace" gh '
dir="$(dirname "$0")/.."
printf "%s\n" "$*" >> "$dir/gh-calls"
case "$1 $2" in
  "release download")
    [ -f "$dir/previous.json" ] || exit 1
    while [ "$#" -gt 0 ]; do [ "$1" = --dir ] && out="$2"; shift; done
    mkdir -p "$out"; cp "$dir/previous.json" "$out/store-record-root.json" ;;
  "release view") [ -n "${RELEASE_EXISTS:-}" ] ;;
  "release create") : ;;
  "release upload") cp "$4" "$dir/uploaded.json" ;;
  *) exit 9 ;;
esac'
    printf '%s\n' "$workspace"
}

run_record() {
    local workspace="$1"
    shift
    run_step "$workspace" GH_TOKEN=t REPOSITORY=owner/app RELEASE_TAG=v1.4.0 RECORD_ASSET=store-record-root.json \
        MARKER_DIR="$workspace/markers" COMMIT=abc123 RUN_ID=4242 RUN_ATTEMPT=1 BUILD_NUMBER=29854170 \
        MARKETING_VERSION=1.4.0 "$@"
}

case_start "record: markers become a schema-1 record uploaded to a release created for the tag"
ws="$(record_workspace)"
echo '{"name":"ios","platform":"ios","buildProfile":"production","submitProfile":"production","fingerprint":"i1"}' > "$ws/markers/ios.json"
echo '{"name":"android","platform":"android","buildProfile":"production","submitProfile":"production","fingerprint":"a1"}' > "$ws/markers/android.json"
run_record "$ws"
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals '1 v1.4.0 abc123 29854170 1.4.0' "$(jq -r '"\(.schema) \(.tag) \(.commit) \(.buildNumber) \(.marketingVersion)"' "$ws/uploaded.json")" 'header' \
    && assert_equals 'android=a1,ios=i1' "$(jq -r '.targets | to_entries | map("\(.key)=\(.value.fingerprint)") | join(",")' "$ws/uploaded.json")" 'targets' \
    && assert_contains "$(cat "$ws/gh-calls")" 'release create v1.4.0 --repo owner/app --verify-tag' 'release created from the existing tag' \
    && assert_contains "$(cat "$ws/gh-calls")" '--clobber' 'record replaced on a re-run'; then
    pass_case
fi

case_start "record: a re-run merges the targets an earlier attempt recorded for the same commit"
ws="$(record_workspace)"
echo '{"name":"android","platform":"android","buildProfile":"production","submitProfile":"production","fingerprint":"a1"}' > "$ws/markers/android.json"
record_json 2026-01-01T00:00:00Z '{"ios":{"platform":"ios","fingerprint":"i1"}}' | jq -c '. + {commit: "abc123"}' > "$ws/previous.json"
run_record "$ws" RELEASE_EXISTS=1
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals 'android,ios' "$(jq -r '.targets | keys | join(",")' "$ws/uploaded.json")" 'merged targets' \
    && assert_not_contains "$(cat "$ws/gh-calls")" 'release create' 'existing release reused'; then
    pass_case
fi

case_start "record: a previous record from another commit is replaced, not merged"
ws="$(record_workspace)"
echo '{"name":"android","platform":"android","buildProfile":"production","submitProfile":"production","fingerprint":"a2"}' > "$ws/markers/android.json"
record_json 2026-01-01T00:00:00Z '{"ios":{"platform":"ios","fingerprint":"i1"}}' | jq -c '. + {commit: "old"}' > "$ws/previous.json"
run_record "$ws" RELEASE_EXISTS=1
if assert_equals 0 "$STEP_STATUS" 'status' && assert_equals 'android' "$(jq -r '.targets | keys | join(",")' "$ws/uploaded.json")" 'targets'; then
    pass_case
fi

case_start "record: no successful submit writes nothing"
ws="$(record_workspace)"
run_record "$ws"
if assert_equals 0 "$STEP_STATUS" 'status' && assert_equals '' "$(cat "$ws/gh-calls" 2>/dev/null || true)" 'no API call'; then
    pass_case
fi

case_start "record: a marker without a fingerprint fails closed"
ws="$(record_workspace)"
echo '{"name":"ios","platform":"ios","fingerprint":""}' > "$ws/markers/ios.json"
run_record "$ws"
if assert_equals 1 "$STEP_STATUS" 'status' && assert_not_contains "$(cat "$ws/gh-calls" 2>/dev/null || true)" 'release upload' 'nothing uploaded'; then
    pass_case
fi

# --- wiring --------------------------------------------------------------------------------

check_wiring() {
    WORKFLOW="$WORKFLOW_YML" CHECK="$1" python3 - <<'PYTHON'
import os
import sys

import yaml

workflow = yaml.safe_load(open(os.environ['WORKFLOW'], encoding='utf-8'))
inputs = workflow[True]['workflow_call']['inputs']
jobs = workflow['jobs']
check = os.environ['CHECK']


def names(job):
    return [step.get('name') for step in jobs[job]['steps']]


def before(job, first, second):
    order = names(job)
    for name in (first, second):
        if name not in order:
            sys.exit(f"{job} has no step {name!r}")
    if order.index(first) > order.index(second):
        sys.exit(f"{job}: {first!r} runs after {second!r}")


if check == 'defaults':
    expected = {'mode': 'native', 'targets': '', 'build-number': '', 'release-tag': '',
                'write-store-record': False, 'build-profile': 'production',
                'submit-profile': 'production', 'enable-ios': True, 'enable-android': False}
    for name, value in expected.items():
        if inputs[name].get('default') != value:
            sys.exit(f"input {name} defaults to {inputs[name].get('default')!r}, expected {value!r}")
elif check == 'env-order':
    for job, platform in (('ios-publish', 'iOS'), ('android-publish', 'Android')):
        before(job, 'Apply eas.json build profile env', 'Apply publish-env')
        before(job, 'Apply publish-env', 'Apply the store build number and marketing version')
        before(job, 'Apply the store build number and marketing version', 'Apply EAS_EXTRA_ENV')
        before(job, 'Apply EAS_EXTRA_ENV', f'Run {platform} pre-submit command')
        before(job, f'Run {platform} pre-submit command', f'EAS build ({platform})')
        before(job, f'EAS build ({platform})', f'EAS submit ({platform})')
        before(job, f'EAS submit ({platform})', 'Record the submitted target')
        before(job, 'Record the submitted target', f'Run {platform} post-submit command')
        steps = {step.get('name'): step for step in jobs[job]['steps']}
        for name in (f'EAS build ({platform})', f'EAS submit ({platform})'):
            env = steps[name].get('env') or {}
            for key in ('BUILD_PROFILE', 'SUBMIT_PROFILE'):
                if key in env and 'matrix.target' not in env[key]:
                    sys.exit(f"{job} {name} reads {key} from {env[key]!r}, not the matrix target")
    before('android-lint-gate', 'Apply eas.json build profile env', 'Generate production Android project')
elif check == 'gates':
    for job in ('ios-publish', 'android-lint-gate', 'android-publish'):
        condition = str(jobs[job].get('if', ''))
        if "needs.plan.outputs.decision == 'native'" not in condition:
            sys.exit(f"{job} runs without the plan's native decision: {condition}")
        if jobs[job].get('permissions') != {'contents': 'read'}:
            sys.exit(f"{job} must pin permissions to contents: read")
        if jobs[job]['strategy'].get('fail-fast') is not False:
            sys.exit(f"{job}: one target's failure must not cancel another target's submit")
    if 'permissions' in workflow:
        sys.exit("a workflow-level permissions block would cap plan and record below what build-number auto and the record need")
    for job in ('plan', 'record'):
        if 'permissions' in jobs[job]:
            sys.exit(f"{job} declares permissions; a grant above the caller's is a startup failure for every caller")
    record_if = str(jobs['record'].get('if', ''))
    if "needs.plan.outputs.record == 'true'" not in record_if or 'always()' not in record_if:
        sys.exit(f"record job gate is {record_if!r}")
PYTHON
}

for check in defaults env-order gates; do
    case_start "wiring: $check"
    if failure="$(check_wiring "$check" 2>&1)"; then
        pass_case
    else
        fail_case "$failure"
    fi
done

finish_suite
