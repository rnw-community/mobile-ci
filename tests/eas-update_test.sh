#!/usr/bin/env bash
# eas-update publishes an EAS Update and hands back what a pull-request comment
# or a release pipeline needs: the update and group ids per platform, the
# runtime version, and a manifest URL / expo-dev-client deep link. A missing
# token, a channel that would not serve the update, output that is not the
# JSON eas-cli documents or a platform missing from it fails the step: an
# update that did not land where the caller asked must never read as published.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION_YML="$REPO_ROOT/actions/eas-update/action.yml"
STEP='Publish the EAS update'

CONFIG='{"slug":"demo","extra":{"eas":{"projectId":"p-1"}},"updates":{"url":"https://u.expo.dev/p-1"}}'
BOTH='[
  {"id":"u-ios","group":"g-1","branch":"pr-7","platform":"ios","runtimeVersion":"rv-1","message":"m"},
  {"id":"u-and","group":"g-1","branch":"pr-7","platform":"android","runtimeVersion":"rv-1","message":"m"}]'
SPLIT='[
  {"id":"u-ios","group":"g-ios","branch":"pr-7","platform":"ios","runtimeVersion":"rv-ios"},
  {"id":"u-and","group":"g-and","branch":"pr-7","platform":"android","runtimeVersion":"rv-and"}]'

workspace() {
    local ws
    ws="$(new_workspace "$ACTION_YML" "$STEP")"
    printf '%s\n' "$CONFIG" > "$ws/config.json"
    # shellcheck disable=SC2016
    stub "$ws" npx '
dir="$(dirname "$0")/.."
printf "%s\n" "$*" >> "$dir/npx-calls"
if [ "$1" = --no-install ]; then
  var="RESOLVED_$5"
  printf "{\"runtimeVersion\":\"%s\"}\n" "${!var:-rv-1}"
  exit 0
fi
if [ "$1" = expo ]; then
  [ -z "${CONFIG_FAIL:-}" ] || exit 1
  cat "$dir/config.json"
  exit 0
fi
shift 2
. "$REPO_ROOT/tests/lib/eas-cli-contract.sh"
eas_cli_contract "$@"
case "$1" in
  channel:view)
    [ -z "${CHANNEL_MISSING:-}" ] || { echo "Could not find channel with the name $2" >&2; exit 1; }
    if [ -n "${CHANNEL_VIEW_JSON:-}" ]; then printf "%s\n" "$CHANNEL_VIEW_JSON"; else jq -nc --arg c "$2" "{currentPage: {name: \$c, updateBranches: [{name: \$c}]}}"; fi
    ;;
  channel:create|channel:edit) echo "{}" ;;
  update:list)
    [ -n "${EXISTING_HASH:-}" ] || { echo "Could not find branch" >&2; exit 1; }
    printf "{\"name\":\"%s\",\"currentPage\":[{\"group\":\"g-old-%s\"}]}\n" "$3" "$5"
    ;;
  update:view)
    p="${2#g-old-}"
    printf "[{\"id\":\"u-old-%s\",\"group\":\"%s\",\"branch\":\"pr-7\",\"platform\":\"%s\",\"runtimeVersion\":\"rv-1\",\"gitCommitHash\":\"%s\"}]\n" "$p" "$2" "$p" "$EXISTING_HASH"
    ;;
  update)
    printf "APP_VARIANT=%s EAS_BUILD_PROFILE=%s\n" "${APP_VARIANT:-}" "${EAS_BUILD_PROFILE:-}" >> "$dir/update-env"
    [ -z "${UPDATE_FAIL:-}" ] || { echo "upload failed" >&2; exit 1; }
    printf "%s\n" "$UPDATE_JSON"
    ;;
  *) echo "unexpected eas command $1" >&2; exit 64 ;;
esac'
    printf '%s\n' "$ws"
}

publish() {
    WS="$(workspace)"
    run_step "$WS" EXPO_TOKEN_INPUT=token EXPO_TOKEN='' CHANNEL=pr-7 BRANCH='' PLATFORM=all MESSAGE='Fix the board' \
        ENVIRONMENT='' PROFILE_ENVIRONMENT='' EAS_PROFILE='' PROFILE_ENV='' EAS_CLI_VERSION=20.5.1 \
        AUTO_CREATE_CHANNEL=true SCHEME='' UPDATE_JSON="$BOTH" GITHUB_SHA=0123456789abcdef \
        EXPECTED_IOS_RUNTIME='' EXPECTED_ANDROID_RUNTIME='' ROLLOUT_PERCENTAGE='' PRIVATE_KEY_PATH='' INPUT_DIR='' \
        SKIP_IF_PUBLISHED=true SKIP_STALE=true STALE_CHECK_TOKEN=gh-token GITHUB_EVENT_PATH='' GITHUB_REPOSITORY=owner/app "$@"
}

calls() {
    cat "$WS/npx-calls" 2>/dev/null || true
}

out() {
    step_output "$WS" "$1"
}

case_start "a missing Expo token fails closed before eas-cli runs"
publish EXPO_TOKEN_INPUT=''
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$WS/log")" 'needs an Expo access token' 'message' \
    && assert_equals '' "$(calls)" 'no eas-cli call'; then
    pass_case
fi

case_start "EXPO_TOKEN already in the job env is used when expo-token is empty"
publish EXPO_TOKEN_INPUT='' EXPO_TOKEN=from-env
if assert_equals 0 "$STEP_STATUS" 'status'; then
    pass_case
fi

case_start "the default publish targets the channel, which eas-cli creates with a same-name branch"
publish
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_contains "$(calls)" '--yes eas-cli@20.5.1 update --message Fix the board --platform all --channel pr-7 --json --non-interactive' 'update call' \
    && assert_not_contains "$(calls)" 'channel:view' 'no pre-check while auto-create is on' \
    && assert_equals pr-7 "$(out channel)" 'channel' \
    && assert_equals pr-7 "$(out branch)" 'branch' \
    && assert_equals g-1 "$(out update-group-id)" 'group' \
    && assert_equals rv-1 "$(out runtime-version)" 'runtime' \
    && assert_equals u-ios "$(out ios-update-id)" 'ios id' \
    && assert_equals u-and "$(out android-update-id)" 'android id' \
    && assert_equals https://u.expo.dev/p-1/group/g-1 "$(out manifest-url)" 'manifest url' \
    && assert_equals 'exp+demo://expo-development-client/?url=https%3A%2F%2Fu.expo.dev%2Fp-1%2Fgroup%2Fg-1' "$(out deep-link)" 'deep link' \
    && assert_equals "$(out deep-link)" "$(out android-deep-link)" 'per-platform deep link'; then
    pass_case
fi

case_start "per-platform groups and runtimes leave the shared outputs empty and fill the per-platform ones"
publish UPDATE_JSON="$SPLIT" SCHEME=demoapp
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals '' "$(out update-group-id)" 'no shared group' \
    && assert_equals '' "$(out runtime-version)" 'no shared runtime' \
    && assert_equals '' "$(out deep-link)" 'no shared deep link' \
    && assert_equals rv-ios "$(out ios-runtime-version)" 'ios runtime' \
    && assert_equals rv-and "$(out android-runtime-version)" 'android runtime' \
    && assert_equals https://u.expo.dev/p-1/group/g-and "$(out android-manifest-url)" 'android manifest' \
    && assert_contains "$(out ios-deep-link)" 'demoapp://expo-development-client/?url=https%3A%2F%2Fu.expo.dev%2Fp-1%2Fgroup%2Fg-ios' 'scheme input wins'; then
    pass_case
fi

case_start "auto-create-channel false refuses a channel EAS does not have, before publishing"
publish AUTO_CREATE_CHANNEL=false CHANNEL_MISSING=1
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$WS/log")" 'auto-create-channel is false' 'message' \
    && assert_not_contains "$(calls)" ' update ' 'nothing published'; then
    pass_case
fi

case_start "auto-create-channel false publishes to a channel that exists"
publish AUTO_CREATE_CHANNEL=false
if assert_equals 0 "$STEP_STATUS" 'status' && assert_contains "$(calls)" 'channel:view pr-7 --json' 'pre-check'; then
    pass_case
fi

case_start "a branch other than the channel is published to, then a missing channel is created and pointed at it"
publish BRANCH=feature-x CHANNEL_MISSING=1 UPDATE_JSON="${BOTH//\"pr-7\"/\"feature-x\"}"
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_contains "$(calls)" 'update --message Fix the board --platform all --branch feature-x --json --non-interactive' 'update to the branch' \
    && assert_contains "$(calls)" 'channel:create pr-7 --json --non-interactive' 'channel created' \
    && assert_contains "$(calls)" 'channel:edit pr-7 --branch feature-x --json --non-interactive' 'channel pointed at the branch' \
    && assert_equals feature-x "$(out branch)" 'branch output' \
    && assert_contains "$(calls)" 'channel:view pr-7 --json --non-interactive' 'pre-check'; then
    pass_case
fi

case_start "an existing channel that serves another branch fails closed before publishing"
publish BRANCH=feature-x CHANNEL_VIEW_JSON='{"currentPage":{"name":"pr-7","updateBranches":[{"name":"main"}]}}'
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$WS/log")" 'serves main, not feature-x' 'message' \
    && assert_not_contains "$(calls)" ' update ' 'nothing published'; then
    pass_case
fi

case_start "a failing eas update fails the step"
publish UPDATE_FAIL=1
if assert_equals 1 "$STEP_STATUS" 'status' && assert_equals '' "$(out update-group-id)" 'no outputs'; then
    pass_case
fi

for bad in 'not json' '{"id":"u"}' '[]' '[{"id":"u-ios","platform":"ios"}]'; do
    case_start "unparsable update output fails closed: $bad"
    publish PLATFORM=ios UPDATE_JSON="$bad"
    if assert_equals 1 "$STEP_STATUS" 'status' \
        && assert_contains "$(cat "$WS/log")" 'not the JSON array of updates' 'message' \
        && assert_equals '' "$(out ios-update-id)" 'no outputs'; then
        pass_case
    fi
done

case_start "platform all with one platform missing from the output fails closed"
publish UPDATE_JSON='[{"id":"u-ios","group":"g-1","branch":"pr-7","platform":"ios","runtimeVersion":"rv-1"}]'
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$WS/log")" 'no android update' 'message' \
    && assert_equals '' "$(out ios-update-id)" 'no outputs'; then
    pass_case
fi

case_start "platform ios publishes and requires only iOS"
publish PLATFORM=ios UPDATE_JSON='[{"id":"u-ios","group":"g-1","branch":"pr-7","platform":"ios","runtimeVersion":"rv-1"}]'
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_contains "$(calls)" '--platform ios --channel pr-7' 'platform flag' \
    && assert_equals u-ios "$(out ios-update-id)" 'ios id' \
    && assert_equals '' "$(out android-update-id)" 'no android id' \
    && assert_equals g-1 "$(out update-group-id)" 'group'; then
    pass_case
fi

case_start "the eas.json profile env and environment reach eas update; environment input wins"
publish EAS_PROFILE=preview PROFILE_ENV=$'APP_VARIANT=preview\nOTHER=x' PROFILE_ENVIRONMENT=preview
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals 'APP_VARIANT=preview EAS_BUILD_PROFILE=preview' "$(cat "$WS/update-env")" 'env seen by eas update' \
    && assert_contains "$(calls)" '--channel pr-7 --environment preview' 'profile environment'; then
    pass_case
fi
publish EAS_PROFILE=preview PROFILE_ENV='' PROFILE_ENVIRONMENT=preview ENVIRONMENT=staging
if assert_contains "$(calls)" '--environment staging' 'input environment wins'; then
    pass_case
fi

case_start "an empty message falls back to the commit"
publish MESSAGE=''
if assert_equals 0 "$STEP_STATUS" 'status' && assert_contains "$(calls)" '--message 0123456' 'commit message fallback'; then
    pass_case
fi

for bad in 'PLATFORM=web|platform must be' 'AUTO_CREATE_CHANNEL=yes|auto-create-channel must be' \
    'CHANNEL=|channel must' 'CHANNEL=--force|channel must' 'BRANCH=a b|branch must' \
    'EAS_CLI_VERSION=|eas-cli-version must' 'ROLLOUT_PERCENTAGE=0|rollout-percentage must' \
    'ROLLOUT_PERCENTAGE=101|rollout-percentage must' 'SKIP_STALE=yes|skip-stale must' \
    'PRIVATE_KEY_PATH=missing.pem|private-key-path' 'INPUT_DIR=missing-dist|input-dir'; do
    setting="${bad%%|*}"
    message="${bad#*|}"
    case_start "invalid input fails closed: $setting"
    publish "$setting"
    if assert_equals 1 "$STEP_STATUS" 'status' \
        && assert_contains "$(cat "$WS/log")" "$message" 'message' \
        && assert_equals '' "$(calls)" 'no eas-cli call'; then
        pass_case
    fi
done

case_start "an app config without an EAS project id fails closed before publishing"
WS="$(workspace)"
printf '{"slug":"demo"}\n' > "$WS/config.json"
run_step "$WS" EXPO_TOKEN_INPUT=token CHANNEL=pr-7 BRANCH='' PLATFORM=all MESSAGE=m ENVIRONMENT='' PROFILE_ENVIRONMENT='' \
    EAS_PROFILE='' PROFILE_ENV='' EAS_CLI_VERSION=20.5.1 AUTO_CREATE_CHANNEL=true SCHEME='' UPDATE_JSON="$BOTH" \
    EXPECTED_IOS_RUNTIME='' EXPECTED_ANDROID_RUNTIME='' ROLLOUT_PERCENTAGE='' PRIVATE_KEY_PATH='' INPUT_DIR='' \
    SKIP_IF_PUBLISHED=true SKIP_STALE=true STALE_CHECK_TOKEN=t GITHUB_EVENT_PATH='' GITHUB_REPOSITORY=owner/app
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$WS/log")" 'extra.eas.projectId' 'message' \
    && assert_not_contains "$(calls)" ' update ' 'nothing published'; then
    pass_case
fi

# --- staleness, idempotency, expected runtime, pass-through ---------------------------

pr_event() {
    printf '{"pull_request":{"number":7,"head":{"sha":"%s"}}}\n' "$1" > "$WS/event.json"
}

case_start "a pull-request run whose head moved on publishes nothing"
WS="$(workspace)"
pr_event aaa
# shellcheck disable=SC2016
stub "$WS" gh 'printf "%s\n" "$*" >> "$(dirname "$0")/../gh-calls"; echo bbb'
run_step "$WS" EXPO_TOKEN_INPUT=token CHANNEL=pr-7 BRANCH='' PLATFORM=all MESSAGE=m ENVIRONMENT='' PROFILE_ENVIRONMENT='' \
    EAS_PROFILE='' PROFILE_ENV='' EAS_CLI_VERSION=20.5.1 AUTO_CREATE_CHANNEL=true SCHEME='' UPDATE_JSON="$BOTH" \
    EXPECTED_IOS_RUNTIME='' EXPECTED_ANDROID_RUNTIME='' ROLLOUT_PERCENTAGE='' PRIVATE_KEY_PATH='' INPUT_DIR='' \
    SKIP_IF_PUBLISHED=true SKIP_STALE=true STALE_CHECK_TOKEN=t GITHUB_EVENT_PATH="$WS/event.json" GITHUB_REPOSITORY=owner/app
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals false "$(out published)" 'published' \
    && assert_equals stale-head "$(out skipped-reason)" 'reason' \
    && assert_contains "$(cat "$WS/gh-calls")" 'api repos/owner/app/pulls/7 --jq .head.sha' 'live head read' \
    && assert_equals '' "$(out ios-update-id)" 'no update outputs' \
    && assert_equals '' "$(calls)" 'no eas-cli call'; then
    pass_case
fi

case_start "a pull-request run on the current head publishes"
publish GITHUB_EVENT_PATH=/dev/null
WS_SAVED="$WS"
WS="$(workspace)"
pr_event aaa
stub "$WS" gh 'echo aaa'
run_step "$WS" EXPO_TOKEN_INPUT=token CHANNEL=pr-7 BRANCH='' PLATFORM=all MESSAGE=m ENVIRONMENT='' PROFILE_ENVIRONMENT='' \
    EAS_PROFILE='' PROFILE_ENV='' EAS_CLI_VERSION=20.5.1 AUTO_CREATE_CHANNEL=true SCHEME='' UPDATE_JSON="$BOTH" \
    EXPECTED_IOS_RUNTIME='' EXPECTED_ANDROID_RUNTIME='' ROLLOUT_PERCENTAGE='' PRIVATE_KEY_PATH='' INPUT_DIR='' \
    SKIP_IF_PUBLISHED=true SKIP_STALE=true STALE_CHECK_TOKEN=t GITHUB_EVENT_PATH="$WS/event.json" GITHUB_REPOSITORY=owner/app
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals true "$(out published)" 'published' \
    && assert_equals '' "$(out skipped-reason)" 'no reason' \
    && assert_contains "$(calls)" 'update --message m' 'published' \
    && assert_equals true "$(step_output "$WS_SAVED" published)" 'a non-PR run publishes'; then
    pass_case
fi

case_start "an unreadable pull-request head fails closed"
WS="$(workspace)"
pr_event aaa
stub "$WS" gh 'exit 1'
run_step "$WS" EXPO_TOKEN_INPUT=token CHANNEL=pr-7 BRANCH='' PLATFORM=all MESSAGE=m ENVIRONMENT='' PROFILE_ENVIRONMENT='' \
    EAS_PROFILE='' PROFILE_ENV='' EAS_CLI_VERSION=20.5.1 AUTO_CREATE_CHANNEL=true SCHEME='' UPDATE_JSON="$BOTH" \
    EXPECTED_IOS_RUNTIME='' EXPECTED_ANDROID_RUNTIME='' ROLLOUT_PERCENTAGE='' PRIVATE_KEY_PATH='' INPUT_DIR='' \
    SKIP_IF_PUBLISHED=true SKIP_STALE=true STALE_CHECK_TOKEN=t GITHUB_EVENT_PATH="$WS/event.json" GITHUB_REPOSITORY=owner/app
if assert_equals 1 "$STEP_STATUS" 'status' && assert_equals '' "$(calls)" 'no eas-cli call'; then
    pass_case
fi

case_start "a commit already on the branch for every platform is not published again"
WS="$(workspace)"
stub "$WS" git 'echo abc123'
run_step "$WS" EXPO_TOKEN_INPUT=token CHANNEL=pr-7 BRANCH='' PLATFORM=all MESSAGE=m ENVIRONMENT='' PROFILE_ENVIRONMENT='' \
    EAS_PROFILE='' PROFILE_ENV='' EAS_CLI_VERSION=20.5.1 AUTO_CREATE_CHANNEL=true SCHEME='' UPDATE_JSON="$BOTH" \
    EXPECTED_IOS_RUNTIME='' EXPECTED_ANDROID_RUNTIME='' ROLLOUT_PERCENTAGE='' PRIVATE_KEY_PATH='' INPUT_DIR='' \
    SKIP_IF_PUBLISHED=true SKIP_STALE=true STALE_CHECK_TOKEN=t GITHUB_EVENT_PATH='' GITHUB_REPOSITORY=owner/app EXISTING_HASH=abc123
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals false "$(out published)" 'published' \
    && assert_equals already-published "$(out skipped-reason)" 'reason' \
    && assert_equals u-old-ios "$(out ios-update-id)" 'existing ios update' \
    && assert_equals https://u.expo.dev/p-1/group/g-old-android "$(out android-manifest-url)" 'existing android manifest' \
    && assert_not_contains "$(calls)" 'update --message' 'nothing published'; then
    pass_case
fi

case_start "a branch whose latest update is another commit is published to"
WS="$(workspace)"
stub "$WS" git 'echo abc123'
run_step "$WS" EXPO_TOKEN_INPUT=token CHANNEL=pr-7 BRANCH='' PLATFORM=all MESSAGE=m ENVIRONMENT='' PROFILE_ENVIRONMENT='' \
    EAS_PROFILE='' PROFILE_ENV='' EAS_CLI_VERSION=20.5.1 AUTO_CREATE_CHANNEL=true SCHEME='' UPDATE_JSON="$BOTH" \
    EXPECTED_IOS_RUNTIME='' EXPECTED_ANDROID_RUNTIME='' ROLLOUT_PERCENTAGE='' PRIVATE_KEY_PATH='' INPUT_DIR='' \
    SKIP_IF_PUBLISHED=true SKIP_STALE=true STALE_CHECK_TOKEN=t GITHUB_EVENT_PATH='' GITHUB_REPOSITORY=owner/app EXISTING_HASH=old999
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals true "$(out published)" 'published' \
    && assert_contains "$(calls)" 'update --message m' 'published'; then
    pass_case
fi

case_start "an expected runtime the publish env does not resolve to fails before anything is published"
publish EXPECTED_IOS_RUNTIME=rv-1 EXPECTED_ANDROID_RUNTIME=rv-other
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$WS/log")" 'resolves android runtime rv-1 under the env eas update would publish with, but rv-other was expected' 'message' \
    && assert_not_contains "$(calls)" ' update --message' 'nothing published' \
    && assert_equals '' "$(out published)" 'no outputs'; then
    pass_case
fi

case_start "a runtime eas-cli publishes other than the expected one still fails the step"
publish EXPECTED_IOS_RUNTIME=rv-1 EXPECTED_ANDROID_RUNTIME=rv-other RESOLVED_android=rv-other
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$WS/log")" 'published android runtime rv-1, but rv-other was expected' 'message' \
    && assert_equals '' "$(out published)" 'no outputs'; then
    pass_case
fi

case_start "a commit already on a branch the channel does not serve fails instead of reporting it published"
WS="$(workspace)"
stub "$WS" git 'echo abc123'
run_step "$WS" EXPO_TOKEN_INPUT=token CHANNEL=pr-7 BRANCH=feature-x PLATFORM=all MESSAGE=m ENVIRONMENT='' PROFILE_ENVIRONMENT='' \
    EAS_PROFILE='' PROFILE_ENV='' EAS_CLI_VERSION=20.5.1 AUTO_CREATE_CHANNEL=true SCHEME='' UPDATE_JSON="$BOTH" \
    EXPECTED_IOS_RUNTIME='' EXPECTED_ANDROID_RUNTIME='' ROLLOUT_PERCENTAGE='' PRIVATE_KEY_PATH='' INPUT_DIR='' \
    SKIP_IF_PUBLISHED=true SKIP_STALE=true STALE_CHECK_TOKEN=t GITHUB_EVENT_PATH='' GITHUB_REPOSITORY=owner/app EXISTING_HASH=abc123 \
    CHANNEL_VIEW_JSON='{"currentPage":{"name":"pr-7","updateBranches":[{"name":"main"}]}}'
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$WS/log")" 'serves main, not feature-x' 'message' \
    && assert_equals '' "$(out skipped-reason)" 'not reported as already published'; then
    pass_case
fi

case_start "the expected runtime on every platform publishes"
publish EXPECTED_IOS_RUNTIME=rv-1 EXPECTED_ANDROID_RUNTIME=rv-1
if assert_equals 0 "$STEP_STATUS" 'status' && assert_equals true "$(out published)" 'published'; then
    pass_case
fi

case_start "rollout, code signing and a pre-built export pass through to eas update"
WS="$(workspace)"
mkdir -p "$WS/work/dist"
: > "$WS/work/private-key.pem"
run_step "$WS" EXPO_TOKEN_INPUT=token CHANNEL=pr-7 BRANCH='' PLATFORM=all MESSAGE=m ENVIRONMENT='' PROFILE_ENVIRONMENT='' \
    EAS_PROFILE='' PROFILE_ENV='' EAS_CLI_VERSION=20.5.1 AUTO_CREATE_CHANNEL=true SCHEME='' UPDATE_JSON="$BOTH" \
    EXPECTED_IOS_RUNTIME='' EXPECTED_ANDROID_RUNTIME='' ROLLOUT_PERCENTAGE=25 PRIVATE_KEY_PATH=private-key.pem INPUT_DIR=dist \
    SKIP_IF_PUBLISHED=true SKIP_STALE=true STALE_CHECK_TOKEN=t GITHUB_EVENT_PATH='' GITHUB_REPOSITORY=owner/app
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_contains "$(calls)" '--channel pr-7 --rollout-percentage 25 --private-key-path private-key.pem --skip-bundler --input-dir dist --json' 'flags'; then
    pass_case
fi

finish_suite
