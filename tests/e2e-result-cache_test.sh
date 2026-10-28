#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"
ACTION="$REPO_ROOT/actions/e2e-result-cache/action.yml"
case_start 'both platform lanes opt in, filter test targets and publish only after all shards pass'
if output=$(REPO="$REPO_ROOT" python3 - <<'PY'
import os, yaml
for platform in ('ios', 'android'):
    workflow = yaml.safe_load(open(f"{os.environ['REPO']}/.github/workflows/{platform}-maestro.yml"))
    inputs = workflow[True]['workflow_call']['inputs']
    assert inputs['e2e-result-cache']['default'] is False
    assert 'e2e-cache-extra-paths' in inputs
    assert 'e2e-cache' in workflow['jobs']['plan']['with']
    planner = yaml.safe_load(open(f"{os.environ['REPO']}/.github/workflows/expo-base-plan.yml"))
    steps = {step.get('name'): step for step in planner['jobs']['plan']['steps']}
    assert 'Resolve executing workflow refs' in steps

    assert 'test-targets' in workflow['jobs']['test']['strategy']['matrix']['target']
    assert "needs.test.result == 'success'" in workflow['jobs']['cache-pass']['if']
    assert 'cache-pass' in workflow['jobs']['status']['needs']
PY
); then pass_case; else fail_case "$output"; fi

if [ ! -f "$ACTION" ]; then
    case_start 'cache action exists'
    fail_case 'missing e2e-result-cache action'
    finish_suite
fi
identity_workspace() {
    workspace=$(new_workspace "$ACTION" 'Export and hash the app and test contract')
    mkdir -p "$workspace/work/app" "$workspace/work/tests/flows" "$workspace/work/tests/fixtures"
    printf 'flow' > "$workspace/work/tests/flows/test.flow.yaml"
    printf 'fixture' > "$workspace/work/tests/fixtures/seed.db"
    stub "$workspace" npx "$(cat <<'STUB'
if [ "${EXPORT_FAIL:-false}" = true ]; then exit 1; fi
if [ "$3" = config ]; then printf "{\"extra\":{\"flag\":\"%s\"}}" "${CONFIG_FLAG:-one}"; exit 0; fi
out=''
maps=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-dir) shift; out="$1" ;;
    --source-maps) maps=true ;;
  esac
  shift
done
[ -n "$out" ] || exit 1
mkdir -p "$out/_expo/static/js/ios"
if [ "$maps" = true ]; then
  printf "%s" "${BUNDLE_CONTENT:-bundle}" > "$out/_expo/static/js/ios/app.hbc"
  printf "{\"sources\":[\"%s/index.js\"]}" "$(mktemp -u)" > "$out/_expo/static/js/ios/app.hbc.map"
else
  printf "%s %s" "${BUNDLE_CONTENT:-bundle}" "$(mktemp -u)" > "$out/_expo/static/js/ios/app.hbc"
fi
printf asset > "$out/asset.png"
STUB
)"
}
identity() {
    run_step "$workspace" ACTION_PATH="$REPO_ROOT/actions/e2e-result-cache" \
        APP_DIR=app PLATFORM=ios NATIVE_KEY=native-one LANE_INPUTS='{"device":"iPhone"}' \
        TARGET='{"name":"e2e","flowsDir":"tests/flows"}' \
        TEST_PATHS='tests' EXTRA_PATHS='' REPACK_ENV='' SECRETS_DIGEST=''  MOBILE_CI_REF=v4.5.0 \
        GITHUB_REPOSITORY=owner/repo "$@"
}
case_start 'production bundle, assets and config produce a content key'
identity_workspace
identity
original=$(step_output "$workspace" key)
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))" && [[ "$original" =~ ^[a-f0-9]{64}$ ]]; then pass_case; else fail_case 'no SHA-256 key'; fi
case_start 'two default exports of the same commit produce the same key'
: > "$workspace/outputs"
identity
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))" \
    && assert_equals "$original" "$(step_output "$workspace" key)" key; then pass_case; fi
case_start 'unreferenced metadata and docs do not change the key'
printf docs > "$workspace/work/README.md"
mkdir -p "$workspace/work/.github/workflows"
printf metadata > "$workspace/work/.github/workflows/store-metadata.yml"
identity
assert_equals "$original" "$(step_output "$workspace" key)" key && pass_case
for variable in 'BUNDLE_CONTENT=changed' 'CONFIG_FLAG=two' 'NATIVE_KEY=native-two' 'LANE_INPUTS={"device":"iPad"}' 'SECRETS_DIGEST=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' 'MOBILE_CI_REF=v4.6.0' 'WORKFLOW_REFS=[{"path":"ios-maestro.yml","sha":"changed"}]'; do
    case_start "identity changes for $variable"
    identity "$variable"
    if [ "$(step_output "$workspace" key)" = "$original" ]; then fail_case 'key reused'; else pass_case; fi
done
case_start 'fixture changes invalidate the key'
printf changed > "$workspace/work/tests/fixtures/seed.db"
identity
if [ "$(step_output "$workspace" key)" = "$original" ]; then fail_case 'key reused'; else pass_case; fi
case_start 'export failure cannot produce a key'
: > "$workspace/outputs"
identity EXPORT_FAIL=true
assert_equals '' "$(step_output "$workspace" key)" key && pass_case
case_start 'missing extra path cannot produce a key'
: > "$workspace/outputs"
identity EXTRA_PATHS=missing
assert_equals '' "$(step_output "$workspace" key)" key && pass_case
case_start 'empty native key cannot produce a key'
: > "$workspace/outputs"
identity NATIVE_KEY=''
assert_equals '' "$(step_output "$workspace" key)" key && pass_case
case_start 'new files matched by a dependency glob invalidate the key'
identity_workspace
identity TEST_PATHS='tests/fixtures/*.db'
glob_original=$(step_output "$workspace" key)
printf new > "$workspace/work/tests/fixtures/new.db"
identity TEST_PATHS='tests/fixtures/*.db'
if [ "$(step_output "$workspace" key)" = "$glob_original" ]; then fail_case 'new fixture missed'; else pass_case; fi
case_start 'state version changes invalidate the key without exposing the version'
identity STATE_COMMAND='printf version-one'
state_original=$(step_output "$workspace" key)
identity STATE_COMMAND='printf version-two'
if [ "$(step_output "$workspace" key)" = "$state_original" ]; then fail_case 'state change missed'; else pass_case; fi
case_start 'failed or empty state version cannot produce a key'
for command in false true; do
    : > "$workspace/outputs"
    identity STATE_COMMAND="$command"
    assert_equals '' "$(step_output "$workspace" key)" key
done
pass_case
case_start 'custom RN exporter hashes bundle, config and assets without Expo'
identity EXPORT_COMMAND="printf rn > \"\$E2E_CACHE_EXPORT_DIR/bundle\"; printf \"{}\" > \"\$E2E_CACHE_EXPORT_DIR/config.json\"; printf image > \"\$E2E_CACHE_EXPORT_DIR/image.png\"" EXPORT_FAIL=true
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))"; then pass_case; fi
case_start 'source maps from a custom exporter do not enter the key'
custom_export="printf rn > \"\$E2E_CACHE_EXPORT_DIR/bundle\"; printf \"{}\" > \"\$E2E_CACHE_EXPORT_DIR/config.json\"; mktemp -u > \"\$E2E_CACHE_EXPORT_DIR/bundle.map\""
custom_key() {
    : > "$workspace/outputs"
    identity EXPORT_COMMAND="$1"
    [ "$STEP_STATUS" -eq 0 ] && step_output "$workspace" key
}
custom_original=$(custom_key "$custom_export")
custom_repeat=$(custom_key "$custom_export")
if [ -z "$custom_original" ] || [ -z "$custom_repeat" ]; then fail_case "custom export failed ($(cat "$workspace/log"))"
elif assert_equals "$custom_original" "$custom_repeat" key; then pass_case; fi
case_start 'assets under a directory named like a source map still enter the key'
map_dir_export() {
    printf '%s' "printf rn > \"\$E2E_CACHE_EXPORT_DIR/bundle\"; printf \"{}\" > \"\$E2E_CACHE_EXPORT_DIR/config.json\"; mkdir -p \"\$E2E_CACHE_EXPORT_DIR/runtime.map\"; printf $1 > \"\$E2E_CACHE_EXPORT_DIR/runtime.map/chunk.js\""
}
map_dir_one=$(custom_key "$(map_dir_export one)")
map_dir_two=$(custom_key "$(map_dir_export two)")
if [ -z "$map_dir_one" ] || [ -z "$map_dir_two" ]; then fail_case "custom export failed ($(cat "$workspace/log"))"
elif [ "$map_dir_one" = "$map_dir_two" ]; then fail_case 'asset under runtime.map/ ignored'
else pass_case; fi
case_start 'custom exporter missing runtime config cannot produce a key'
: > "$workspace/outputs"
identity EXPORT_COMMAND="printf rn > \"\$E2E_CACHE_EXPORT_DIR/bundle\""
assert_equals '' "$(step_output "$workspace" key)" key && pass_case
case_start 'cyclic fixture symlinks cannot produce a key'
ln -s ../fixtures "$workspace/work/tests/fixtures/cycle"
: > "$workspace/outputs"
identity
assert_equals '' "$(step_output "$workspace" key)" key && pass_case
record_workspace() {
    workspace=$(new_workspace "$ACTION" 'Validate or create the pass record')
}
record() {
    run_step "$workspace" ACTION_PATH="$REPO_ROOT/actions/e2e-result-cache" MODE=lookup KEY="$original" \
        GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=owner/repo GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=2 "$@"
}
case_start 'publish writes only a pass record with producer attempt and lookup accepts it'
record_workspace
record MODE=publish
record
if assert_equals 0 "$STEP_STATUS" 'status' && assert_equals true "$(step_output "$workspace" hit)" hit \
    && assert_equals https://github.com/owner/repo/actions/runs/123/attempts/2 "$(step_output "$workspace" run-url)" link; then pass_case; fi
for corruption in key repository verdict schema runUrl; do
    case_start "corrupt $corruption never supplies a cached pass"
    record MODE=publish
    KEY="$original" WORK="$workspace/work" FIELD="$corruption" python3 - <<'PYTHON'
import json, os
from pathlib import Path
p = Path(os.environ['WORK']) / '.ci-cache/e2e-result' / os.environ['KEY'] / 'pass.json'
record = json.loads(p.read_text()); record[os.environ['FIELD']] = 'corrupt'; p.write_text(json.dumps(record))
PYTHON
    : > "$workspace/outputs"
    record
    assert_equals '' "$(step_output "$workspace" hit)" hit && pass_case
done
for platform in ios android; do
    case_start "$platform cached status passes only with complete evidence and skipped work"
    workspace=$(new_workflow_workspace "$REPO_ROOT/.github/workflows/$platform-maestro.yml" status Report)
    cached=$(jq -nc --arg key "$original" '[{name:"e2e",e2eCacheHit:true,e2eCacheKey:$key,e2eCacheRunUrl:"https://github.com/owner/repo/actions/runs/123/attempts/2"}]')
    run_step "$workspace" DETECT_RESULT=success DETECT_AFFECTED=true DETECT_FORCED=false FORCE_LABEL=e2e \
        PLAN_RESULT=success NATIVE_TARGETS='[]' TEST_TARGETS='[]' CACHED_TARGETS="$cached" BUILD_RESULT=skipped TEST_RESULT=skipped
    assert_equals passed "$(step_output "$workspace" result)" result && pass_case
    for evidence in '[]' '[{"e2eCacheHit":false}]'; do
        case_start "$platform refuses skipped tests without validated hits: $evidence"
        run_step "$workspace" DETECT_RESULT=success DETECT_AFFECTED=true DETECT_FORCED=false FORCE_LABEL=e2e \
            PLAN_RESULT=success NATIVE_TARGETS='[]' TEST_TARGETS='[]' CACHED_TARGETS="$evidence" BUILD_RESULT=skipped TEST_RESULT=skipped
        assert_equals 1 "$STEP_STATUS" status && pass_case
    done
done
case_start 'mixed plans run only misses and publish only eligible misses'
workspace=$(new_workflow_workspace "$REPO_ROOT/.github/workflows/expo-base-plan.yml" collect 'Collect the targets whose native key has no base')
mkdir -p "$workspace/work/.ci-artifacts/plans/hit" "$workspace/work/.ci-artifacts/plans/miss" "$workspace/work/.ci-artifacts/plans/quarantined"
printf '%s' '{"name":"hit","planArtifact":"plan-hit","needsNative":false,"e2eCacheHit":true,"e2eCacheKey":"key-hit"}' > "$workspace/work/.ci-artifacts/plans/hit/plan.json"
printf '%s' '{"name":"miss","planArtifact":"plan-miss","needsNative":true,"e2eCacheHit":false,"e2eCacheKey":"key-miss"}' > "$workspace/work/.ci-artifacts/plans/miss/plan.json"
printf '%s' '{"name":"quarantined","planArtifact":"plan-quarantined","needsNative":false,"tolerateTestFailures":true,"e2eCacheHit":false,"e2eCacheKey":""}' > "$workspace/work/.ci-artifacts/plans/quarantined/plan.json"
run_step "$workspace" TARGETS='[{"name":"hit"},{"name":"miss"},{"name":"quarantined"}]' PLAN_PREFIX=plan
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))" \
    && assert_equals miss "$(step_output "$workspace" targets | jq -r 'map(.name) | join(",")')" native \
    && assert_equals miss,quarantined "$(step_output "$workspace" test-targets | jq -r 'map(.name) | join(",")')" tests \
    && assert_equals miss "$(step_output "$workspace" cache-targets | jq -r 'map(.name) | join(",")')" publication; then pass_case; fi
case_start 'unvalidated reserved cache fields in a target cannot skip a real run'
workspace=$(new_workflow_workspace "$REPO_ROOT/.github/workflows/expo-base-plan.yml" plan "Record this target's plan")
run_step "$workspace" PLATFORM=ios TARGET='{"name":"e2e","e2eCacheHit":true,"e2eCacheKey":"stale"}' \
    NATIVE_KEY=native FINGERPRINT=fingerprint CONFIG_HASH=config BASE_FOUND='' BASE_SOURCE='' BASE_REFERENCE='' \
    BUILD_STRATEGY=auto REPACKED=true PLAN_ARTIFACT=plan-e2e CACHE_KEY='' CACHE_HIT='' CACHE_RUN_URL=''
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))" \
    && assert_equals false "$(jq -r '.e2eCacheHit' "$workspace/work/.ci-artifacts/plan/plan.json")" hit \
    && assert_equals true "$(jq -r '.needsNative' "$workspace/work/.ci-artifacts/plan/plan.json")" native; then pass_case; fi
case_start 'planner resolves the actual lane and nested planner SHAs'
workspace=$(new_workflow_workspace "$REPO_ROOT/.github/workflows/expo-base-plan.yml" plan 'Resolve executing workflow refs')
stub "$workspace" gh "$(cat <<'STUB'
printf '%s' "$REFS_JSON"
STUB
)"
refs='[{"path":"rnw-community/mobile-ci/.github/workflows/ios-maestro.yml@branch","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},{"path":"rnw-community/mobile-ci/.github/workflows/expo-base-plan.yml@v4.5.0","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]'
run_step "$workspace" GITHUB_REPOSITORY=owner/repo GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=1 PLATFORM=ios REFS_JSON="$refs"
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))"; then pass_case; fi
case_start 'unavailable workflow refs cannot supply identity evidence'
: > "$workspace/outputs"
run_step "$workspace" GITHUB_REPOSITORY=owner/repo GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=1 PLATFORM=ios REFS_JSON='[]'
if [ "$STEP_STATUS" -ne 0 ] && assert_equals '' "$(step_output "$workspace" refs)" refs; then pass_case; else fail_case 'missing workflow refs were accepted'; fi
finish_suite
