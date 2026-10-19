#!/usr/bin/env bash
# eas-channel-cleanup-reusable.yml deletes a closed pull request's EAS channel
# and branch, and sweeps channels matching a pattern that saw no activity for
# max-age-days. Deleting the wrong channel strands every installed build on
# it, so a protected name (the deny-list, any channel an eas.json build profile
# bakes into binaries, or one EAS marks protected) is never deleted, a dry run
# deletes nothing, and a channel list EAS cannot read fails the job.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

WORKFLOW_YML="$REPO_ROOT/.github/workflows/eas-channel-cleanup-reusable.yml"
STEP='Delete EAS channels'

OLD=2001-01-01T00:00:00.000Z
NEW=2999-01-01T00:00:00.000Z

workspace() {
    local ws
    ws="$(new_workflow_workspace "$WORKFLOW_YML" cleanup "$STEP")"
    printf '%s\n' '{"build":{"production":{"channel":"store"},"preview":{"extends":"production"}}}' > "$ws/work/eas.json"
    printf '[]\n' > "$ws/channels.json"
    # Channels live in channels.json ({name, createdAt, updatedAt, isProtected?,
    # updateBranches}); MISSING_BRANCHES names branches that do not exist.
    # shellcheck disable=SC2016
    stub "$ws" npx '
dir="$(dirname "$0")/.."
shift 2
. "$REPO_ROOT/tests/lib/eas-cli-contract.sh"
eas_cli_contract "$@"
printf "%s\n" "$*" >> "$dir/eas-calls"
case "$1" in
  channel:list)
    [ -z "${LIST_FAIL:-}" ] || { echo "network error" >&2; exit 1; }
    jq -c --argjson offset "$5" --argjson limit "$3" "{currentPage: .[\$offset:\$offset + \$limit]}" "$dir/channels.json"
    ;;
  channel:view)
    [ "$2" != "${VIEW_ERROR:-}" ] || { echo "Internal server error" >&2; exit 1; }
    [ "$2" != "${VIEW_GARBAGE:-}" ] || { echo "{\"unexpected\":true}"; exit 0; }
    jq -e --arg n "$2" "any(.[]; .name == \$n)" "$dir/channels.json" > /dev/null \
      || { echo "Could not find channel with the name $2" >&2; exit 1; }
    jq -c --arg n "$2" "{currentPage: (.[] | select(.name == \$n))}" "$dir/channels.json"
    ;;
  channel:delete)
    if [ -n "${SUBSCRIBED:-}" ] && [ ! -e "$dir/builds-deleted" ]; then
      echo "Cannot delete channel $2: it has builds that subscribe to it" >&2
      exit 1
    fi
    echo "{\"id\":\"c\"}"
    ;;
  build:list)
    if [ -e "$dir/builds-deleted" ]; then echo "[]"; else echo "[{\"id\":\"b-1\"},{\"id\":\"b-2\"}]"; fi
    ;;
  build:delete)
    [ "$2" != b-2 ] || touch "$dir/builds-deleted"
    echo "{}"
    ;;
  branch:delete)
    case " ${MISSING_BRANCHES:-} " in
      *" $2 "*) echo "Could not find branch $2 on @owner/demo" >&2; exit 1 ;;
    esac
    echo "{\"id\":\"b\"}"
    ;;
  *) echo "unexpected eas command $1" >&2; exit 64 ;;
esac'
    printf '%s\n' "$ws"
}

channels() {
    printf '%s\n' "$1" > "$WS/channels.json"
}

cleanup() {
    run_step "$WS" EXPO_TOKEN=token CHANNEL_TEMPLATE='pr-{number}' PR_NUMBER=7 SWEEP_PATTERN='' MAX_AGE_DAYS=30 \
        PROTECTED_CHANNELS=$'production\nmain' DRY_RUN=false DELETE_SUBSCRIBED_BUILDS=false EAS_CLI_VERSION=20.5.1 "$@"
}

calls() {
    cat "$WS/eas-calls" 2>/dev/null || true
}

channel() {
    jq -nc --arg name "$1" --arg at "$2" --argjson protected "${3:-false}" \
        '{name: $name, createdAt: $at, updatedAt: $at, isProtected: $protected, updateBranches: [{name: $name, updateGroups: []}]}'
}

case_start "a missing EXPO_TOKEN fails before eas-cli runs"
WS="$(workspace)"
cleanup EXPO_TOKEN=''
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$WS/log")" 'EXPO_TOKEN' 'message' \
    && assert_equals '' "$(calls)" 'no call'; then
    pass_case
fi

case_start "a closed pull request's channel and its same-name branch are deleted"
WS="$(workspace)"
channels "[$(channel pr-7 "$NEW")]"
cleanup
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_contains "$(calls)" 'channel:delete pr-7 --json --non-interactive' 'channel deleted' \
    && assert_contains "$(calls)" 'branch:delete pr-7 --json --non-interactive' 'branch deleted' \
    && assert_contains "$(cat "$WS/summary")" 'pr-7' 'summary'; then
    pass_case
fi

case_start "a pull request that never published deletes nothing and succeeds"
WS="$(workspace)"
cleanup MISSING_BRANCHES=pr-7
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_not_contains "$(calls)" 'channel:delete' 'no channel delete' \
    && assert_contains "$(cat "$WS/log")" 'No channel pr-7' 'logged'; then
    pass_case
fi

case_start "a branch left behind without its channel is still deleted"
WS="$(workspace)"
cleanup
if assert_equals 0 "$STEP_STATUS" 'status' && assert_contains "$(calls)" 'branch:delete pr-7' 'branch deleted'; then
    pass_case
fi

for spec in 'main|protected-channels' 'store|eas.json' 'production|protected-channels' 'release-production|protected-channels'; do
    name="${spec%%|*}"
    case_start "channel $name is never deleted ($(printf '%s' "${spec#*|}"))"
    WS="$(workspace)"
    channels "[$(channel "$name" "$OLD")]"
    cleanup CHANNEL_TEMPLATE="$name" PROTECTED_CHANNELS=$'production\nmain\n*-production'
    if assert_equals 0 "$STEP_STATUS" 'status' \
        && assert_not_contains "$(calls)" 'delete' 'nothing deleted' \
        && assert_contains "$(cat "$WS/log")" "Keeping $name" 'logged'; then
        pass_case
    fi
done

case_start "a channel EAS marks protected is never deleted"
WS="$(workspace)"
channels "[$(channel pr-7 "$OLD" true)]"
cleanup
if assert_equals 0 "$STEP_STATUS" 'status' && assert_not_contains "$(calls)" 'delete' 'nothing deleted'; then
    pass_case
fi

case_start "dry-run deletes nothing"
WS="$(workspace)"
channels "[$(channel pr-7 "$NEW"), $(channel rc-1.0 "$OLD")]"
cleanup DRY_RUN=true SWEEP_PATTERN='rc-*'
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_not_contains "$(calls)" 'delete' 'nothing deleted' \
    && assert_contains "$(cat "$WS/log")" 'Would delete channel rc-1.0' 'logged'; then
    pass_case
fi

case_start "the sweep deletes only stale channels matching the pattern, across pages"
WS="$(workspace)"
filler="$(for i in $(seq 1 25); do channel "keep-$i" "$OLD"; done | jq -sc .)"
channels "$(jq -c --argjson more "[$(channel rc-1.0 "$OLD"), $(channel rc-2.0 "$NEW"), $(channel rc-production "$OLD")]" '. + $more' <<< "$filler")"
recent="$(jq -c '(.[] | select(.name == "rc-2.0")) |= (.createdAt = "2001-01-01T00:00:00.000Z")' "$WS/channels.json")"
channels "$(jq -c --arg new "$NEW" '(.[] | select(.name == "rc-2.0")).updateBranches[0].updateGroups = [[{createdAt: $new}]]' <<< "$recent")"
cleanup CHANNEL_TEMPLATE='' SWEEP_PATTERN='rc-*' PROTECTED_CHANNELS='*-production'
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_contains "$(calls)" 'channel:list --limit 25 --offset 25' 'second page' \
    && assert_contains "$(calls)" 'channel:delete rc-1.0' 'stale match deleted' \
    && assert_not_contains "$(calls)" 'channel:delete rc-2.0' 'recently updated kept' \
    && assert_not_contains "$(calls)" 'channel:delete keep-' 'non-matching kept' \
    && assert_not_contains "$(calls)" 'channel:delete rc-production' 'protected kept'; then
    pass_case
fi

case_start "a channel list EAS cannot read fails the job"
WS="$(workspace)"
cleanup CHANNEL_TEMPLATE='' SWEEP_PATTERN='rc-*' LIST_FAIL=1
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(cat "$WS/log")" 'Cannot list' 'message'; then
    pass_case
fi

case_start "an unexpected channel error fails the job after the other deletions ran"
WS="$(workspace)"
channels "[$(channel rc-1.0 "$OLD"), $(channel rc-2.0 "$OLD")]"
cleanup CHANNEL_TEMPLATE='' SWEEP_PATTERN='rc-*' VIEW_ERROR=rc-1.0
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(calls)" 'channel:delete rc-2.0' 'other channel still deleted' \
    && assert_not_contains "$(calls)" 'channel:delete rc-1.0' 'unreadable channel kept'; then
    pass_case
fi

case_start "without a pull request number the template is skipped"
WS="$(workspace)"
cleanup PR_NUMBER=''
if assert_equals 0 "$STEP_STATUS" 'status' && assert_equals '' "$(calls)" 'no call'; then
    pass_case
fi

case_start "an unreadable eas.json fails closed: its channels cannot be protected"
WS="$(workspace)"
printf 'not json\n' > "$WS/work/eas.json"
cleanup
if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(cat "$WS/log")" 'eas.json' 'message'; then
    pass_case
fi

for bad in 'DELETE_SUBSCRIBED_BUILDS=yes|delete-subscribed-builds must be' 'DRY_RUN=maybe|dry-run must be' 'MAX_AGE_DAYS=0|max-age-days must be' 'MAX_AGE_DAYS=x|max-age-days must be' \
    'PR_NUMBER=7a|pull request number' 'CHANNEL_TEMPLATE=-{number}|channel-template' 'EAS_CLI_VERSION=|eas-cli-version must be'; do
    setting="${bad%%|*}"
    message="${bad#*|}"
    case_start "invalid input fails closed: $setting"
    WS="$(workspace)"
    cleanup "$setting"
    if assert_equals 1 "$STEP_STATUS" 'status' \
        && assert_contains "$(cat "$WS/log")" "$message" 'message' \
        && assert_equals '' "$(calls)" 'no call'; then
        pass_case
    fi
done

case_start "a channel builds still subscribe to is kept by default and the job fails naming it"
WS="$(workspace)"
channels "[$(channel pr-7 "$NEW")]"
cleanup SUBSCRIBED=1
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$WS/log")" 'Set delete-subscribed-builds' 'hint' \
    && assert_not_contains "$(calls)" 'build:delete' 'no build deleted' \
    && assert_not_contains "$(calls)" 'branch:delete' 'branch kept with its channel'; then
    pass_case
fi

case_start "delete-subscribed-builds deletes every subscribed build, then the channel and branch"
WS="$(workspace)"
channels "[$(channel pr-7 "$NEW")]"
cleanup SUBSCRIBED=1 DELETE_SUBSCRIBED_BUILDS=true
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_contains "$(calls)" 'build:list --channel pr-7 --limit 50' 'builds listed' \
    && assert_contains "$(calls)" 'build:delete b-1' 'first build' \
    && assert_contains "$(calls)" 'build:delete b-2' 'second build' \
    && assert_contains "$(calls)" 'branch:delete pr-7' 'branch deleted' \
    && assert_equals 2 "$(grep -c 'channel:delete pr-7' "$WS/eas-calls")" 'channel:delete retried once'; then
    pass_case
fi

case_start "the concurrency group is per channel, so several cleanups in one run never cancel each other"
group="$(WORKFLOW="$WORKFLOW_YML" python3 -c 'import os, yaml; print(yaml.safe_load(open(os.environ["WORKFLOW"]))["concurrency"]["group"])')"
if assert_contains "$group" 'inputs.channel-template' 'template' \
    && assert_contains "$group" 'inputs.sweep-pattern' 'pattern' \
    && assert_contains "$group" 'github.event.pull_request.number' 'pull request'; then
    pass_case
fi

case_start "a channel:view answer of an unexpected shape keeps the channel and fails the job"
WS="$(workspace)"
channels "[$(channel rc-1.0 "$OLD"), $(channel rc-2.0 "$OLD")]"
cleanup CHANNEL_TEMPLATE='' SWEEP_PATTERN='rc-*' VIEW_GARBAGE=rc-1.0
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$WS/log")" 'Cannot tell whether channel rc-1.0 is protected' 'message' \
    && assert_not_contains "$(calls)" 'channel:delete rc-1.0' 'kept' \
    && assert_contains "$(calls)" 'channel:delete rc-2.0' 'others still deleted'; then
    pass_case
fi

finish_suite
