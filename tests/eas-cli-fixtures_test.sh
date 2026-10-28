#!/usr/bin/env bash
# eas-cli's --json output is not a versioned contract. fixtures/eas-cli/<version>/
# holds output recorded from real eas-cli runs against an EAS project (see
# fixtures/eas-cli/README.md); this suite feeds every recorded version to the
# real step scripts of eas-update, eas-channel-fingerprint and
# eas-channel-cleanup, so a field eas-cli renames or moves fails here instead
# of on a consumer's release.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

FIXTURES="$REPO_ROOT/fixtures/eas-cli"
UPDATE_YML="$REPO_ROOT/actions/eas-update/action.yml"
FINGERPRINT_YML="$REPO_ROOT/actions/eas-channel-fingerprint/action.yml"
CLEANUP_YML="$REPO_ROOT/.github/workflows/eas-channel-cleanup-reusable.yml"

# fixture_stub <workspace> <version dir>: eas-cli answers from the recordings.
fixture_stub() {
    printf '{"slug":"demo","extra":{"eas":{"projectId":"p-1"}},"updates":{"url":"https://u.expo.dev/p-1"}}\n' > "$1/config.json"
    printf '%s\n' "$2" > "$1/fixture-dir"
    # shellcheck disable=SC2016
    stub "$1" npx '
dir="$(dirname "$0")/.."
fx="$(cat "$dir/fixture-dir")"
printf "%s\n" "$*" >> "$dir/npx-calls"
if [ "$1" = expo ]; then cat "$dir/config.json"; exit 0; fi
if [ "$1" = --no-install ]; then jq -c --arg p "$5" "[.[] | select(.platform == \$p)][0] | {runtimeVersion}" "$fx/update.json"; exit 0; fi
shift 2
. "$REPO_ROOT/tests/lib/eas-cli-contract.sh"
eas_cli_contract "$@"
case "$1" in
  update) cat "$fx/update.json" ;;
  update:list) cat "$fx/update-list.json" ;;
  update:view) cat "$fx/update-view.json" ;;
  build:list) cat "$fx/build-list.json" ;;
  channel:list) cat "$fx/channel-list.json" ;;
  channel:view)
    case "$2" in
      *-missing) cat "$fx/channel-view-missing.err" >&2; exit 1 ;;
      *) cat "$fx/channel-view.json" ;;
    esac
    ;;
  branch:delete) cat "$fx/branch-delete-missing.err" >&2; exit 1 ;;
  *) echo "unexpected eas command $1" >&2; exit 64 ;;
esac'
}

versions=0
for fx in "$FIXTURES"/*/; do
    [ -f "$fx/update.json" ] || continue
    versions=$((versions + 1))
    fx="${fx%/}"
    version="$(basename "$fx")"
    ios_id="$(jq -r '.[] | select(.platform == "ios") | .id' "$fx/update.json")"
    ios_runtime="$(jq -r '.[] | select(.platform == "ios") | .runtimeVersion' "$fx/update.json")"
    android_runtime="$(jq -r '.[] | select(.platform == "android") | .runtimeVersion' "$fx/update.json")"
    channel="$(jq -r '.[0].branch' "$fx/update.json")"

    case_start "eas-cli $version: eas update --json yields every per-platform output"
    ws="$(new_workspace "$UPDATE_YML" 'Publish the EAS update')"
    fixture_stub "$ws" "$fx"
    run_step "$ws" EXPO_TOKEN_INPUT=token CHANNEL="$channel" BRANCH='' PLATFORM=all MESSAGE=m ENVIRONMENT='' \
        PROFILE_ENVIRONMENT='' EAS_PROFILE='' PROFILE_ENV='' EAS_CLI_VERSION="$version" AUTO_CREATE_CHANNEL=true SCHEME='' \
        EXPECTED_IOS_RUNTIME="$ios_runtime" EXPECTED_ANDROID_RUNTIME="$android_runtime" ROLLOUT_PERCENTAGE='' PRIVATE_KEY_PATH='' \
        INPUT_DIR='' SKIP_IF_PUBLISHED=false SKIP_STALE=false STALE_CHECK_TOKEN=t GITHUB_EVENT_PATH='' GITHUB_REPOSITORY=o/a
    if assert_equals 0 "$STEP_STATUS" "status ($(tail -3 "$ws/log"))" \
        && assert_equals true "$(step_output "$ws" published)" 'published' \
        && assert_equals "$ios_id" "$(step_output "$ws" ios-update-id)" 'ios update id' \
        && assert_equals "$android_runtime" "$(step_output "$ws" android-runtime-version)" 'android runtime' \
        && assert_contains "$(step_output "$ws" ios-manifest-url)" "https://u.expo.dev/p-1/group/" 'manifest url'; then
        pass_case
    fi

    case_start "eas-cli $version: update:list and update:view recognise a commit already published"
    ws="$(new_workspace "$UPDATE_YML" 'Publish the EAS update')"
    fixture_stub "$ws" "$fx"
    stub "$ws" git "echo $(jq -r '.[] | select(.platform == "ios") | .gitCommitHash' "$fx/update-view.json")"
    run_step "$ws" EXPO_TOKEN_INPUT=token CHANNEL="$channel" BRANCH='' PLATFORM=ios MESSAGE=m ENVIRONMENT='' \
        PROFILE_ENVIRONMENT='' EAS_PROFILE='' PROFILE_ENV='' EAS_CLI_VERSION="$version" AUTO_CREATE_CHANNEL=true SCHEME='' \
        EXPECTED_IOS_RUNTIME='' EXPECTED_ANDROID_RUNTIME='' ROLLOUT_PERCENTAGE='' PRIVATE_KEY_PATH='' \
        INPUT_DIR='' SKIP_IF_PUBLISHED=true SKIP_STALE=false STALE_CHECK_TOKEN=t GITHUB_EVENT_PATH='' GITHUB_REPOSITORY=o/a
    if assert_equals 0 "$STEP_STATUS" "status ($(tail -3 "$ws/log"))" \
        && assert_equals already-published "$(step_output "$ws" skipped-reason)" 'skipped' \
        && assert_equals "$(jq -r '.[] | select(.platform == "ios") | .id' "$fx/update-view.json")" "$(step_output "$ws" ios-update-id)" 'existing update id' \
        && assert_not_contains "$(cat "$ws/npx-calls")" ' update --message' 'nothing published'; then
        pass_case
    fi

    case_start "eas-cli $version: channel:view, update:list and build:list decide ota for the channel's runtime"
    ws="$(new_workspace "$FINGERPRINT_YML" 'Compare the runtime versions with the channel')"
    fixture_stub "$ws" "$fx"
    run_step "$ws" EXPO_TOKEN_INPUT=token BASELINE=update-or-build EAS_CLI_VERSION="$version" \
        TARGETS="[{\"name\":\"ios\",\"platform\":\"ios\",\"channel\":\"$channel\",\"envLines\":\"\",\"buildProfile\":\"\"}]" \
        RUNTIMES="{\"ios\":\"$ios_runtime\"}"
    if assert_equals 0 "$STEP_STATUS" "status ($(tail -3 "$ws/log"))" \
        && assert_equals ota "$(step_output "$ws" decision)" 'decision'; then
        pass_case
    fi

    case_start "eas-cli $version: a missing channel and branch read as absent, and channel:list parses"
    ws="$(new_workflow_workspace "$CLEANUP_YML" cleanup 'Delete EAS channels')"
    fixture_stub "$ws" "$fx"
    run_step "$ws" EXPO_TOKEN=token CHANNEL_TEMPLATE="$channel-missing" PR_NUMBER=1 SWEEP_PATTERN='no-such-channel-*' \
        MAX_AGE_DAYS=30 PROTECTED_CHANNELS=production DRY_RUN=false DELETE_SUBSCRIBED_BUILDS=false EAS_CLI_VERSION="$version"
    if assert_equals 0 "$STEP_STATUS" "status ($(tail -3 "$ws/log"))" \
        && assert_contains "$(cat "$ws/log")" "No channel $channel-missing" 'absent channel' \
        && assert_contains "$(cat "$ws/log")" "No branch $channel-missing" 'absent branch' \
        && assert_contains "$(cat "$ws/log")" "0 channel(s) matching" 'channel list parsed'; then
        pass_case
    fi
done

case_start "fixtures exist for at least one eas-cli version"
if assert_equals yes "$([ "$versions" -gt 0 ] && echo yes || echo no)" 'recorded versions'; then
    pass_case
fi

finish_suite
