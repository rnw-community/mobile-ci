#!/usr/bin/env bash
# eas-channel-cleanup-reusable.yml deletes a closed pull request's EAS channel
# and branch, and sweeps channels matching a pattern that saw no activity for
# max-age-days. Deleting the wrong channel strands every installed build on
# it, so a protected name (the deny-list, any channel an eas.json build profile
# bakes into binaries, or one EAS marks protected) is never deleted, a dry run
# deletes nothing, and a channel list EAS cannot read fails the job. The job
# itself stays cheap: a sparse, blobless checkout of only what it reads and
# eas-cli alone, with no workspace install unless the caller asks for one.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

WORKFLOW_YML="$REPO_ROOT/.github/workflows/eas-channel-cleanup-reusable.yml"
STEP='Delete EAS channels'
PATHS_STEP='Resolve checkout paths'

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
pwd >> "$dir/eas-cwd"
[ ! -f app.json ] || cp app.json "$dir/app.json.seen"
[ ! -f package.json ] || cp package.json "$dir/package.json.seen"
[ ! -f eas.json ] || cp eas.json "$dir/eas.json.seen"
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
        PROTECTED_CHANNELS=$'production\nmain' DRY_RUN=false DELETE_SUBSCRIBED_BUILDS=false EAS_CLI_VERSION=20.5.1 PROJECT_ID='' PROJECT_SLUG='' "$@"
}

# resolve_paths [VAR=value ...]: the sparse-checkout patterns the checkout step receives.
resolve_paths() {
    PATHS_WS="$(new_workflow_workspace "$WORKFLOW_YML" cleanup "$PATHS_STEP")"
    run_step "$PATHS_WS" APP_DIR=packages/app PROJECT_ID='' INSTALL_COMMAND='' "$@"
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

PROJECT_UUID=4a70028a-5f9e-4ab6-9389-82d8b8b6c833

case_start "a project id and slug run eas-cli against a minimal app config, never the app's own"
WS="$(workspace)"
printf 'module.exports = require("not-installed");\n' > "$WS/work/app.config.js"
channels "[$(channel pr-7 "$NEW")]"
cleanup PROJECT_ID="$PROJECT_UUID" PROJECT_SLUG=demo-app
if assert_equals 0 "$STEP_STATUS" "status ($(tail -3 "$WS/log"))" \
    && assert_contains "$(calls)" 'channel:delete pr-7' 'channel deleted' \
    && assert_contains "$(cat "$WS/eas-cwd")" "$WS/runner-temp" 'runs outside the app dir' \
    && assert_equals "$PROJECT_UUID" "$(jq -r '.expo.extra.eas.projectId' "$WS/app.json.seen")" 'project id' \
    && assert_equals demo-app "$(jq -r '.expo.slug' "$WS/app.json.seen")" 'slug' \
    && assert_equals demo-app "$(jq -r '.name' "$WS/package.json.seen")" 'package name, which eas-cli defaults the slug from' \
    && assert_contains "$(cat "$WS/eas.json.seen")" '"channel":"store"' 'eas.json travels along'; then
    pass_case
fi

case_start "a project id keeps the eas.json build-profile channels protected"
WS="$(workspace)"
channels "[$(channel store "$OLD")]"
cleanup PROJECT_ID="$PROJECT_UUID" PROJECT_SLUG=demo-app CHANNEL_TEMPLATE=store
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_not_contains "$(calls)" 'delete' 'nothing deleted' \
    && assert_contains "$(cat "$WS/log")" 'Keeping store' 'logged'; then
    pass_case
fi

case_start "without a project id eas-cli runs in the app dir"
WS="$(workspace)"
channels "[$(channel pr-7 "$NEW")]"
cleanup
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals "$WS/work" "$(sort -u "$WS/eas-cwd")" 'cwd'; then
    pass_case
fi

for bad in "PROJECT_ID=nope PROJECT_SLUG=demo|project-id must be" "PROJECT_ID=$PROJECT_UUID PROJECT_SLUG=|project-slug is required" \
    "PROJECT_ID= PROJECT_SLUG=demo|project-id is required" "PROJECT_ID=$PROJECT_UUID PROJECT_SLUG=a/b|project-slug must be"; do
    settings="${bad%%|*}"
    message="${bad#*|}"
    case_start "invalid project settings fail closed: $settings"
    WS="$(workspace)"
    # shellcheck disable=SC2086
    cleanup $settings
    if assert_equals 1 "$STEP_STATUS" 'status' \
        && assert_contains "$(cat "$WS/log")" "$message" 'message' \
        && assert_equals '' "$(calls)" 'no call'; then
        pass_case
    fi
done

case_start "the checkout is sparse and blobless: eas.json plus the app config files of the app dir"
resolve_paths
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals $'/packages/app/eas.json\n/packages/app/app.json\n/packages/app/app.config.*\n/packages/app/package.json' "$(step_output "$PATHS_WS" sparse)" 'patterns'; then
    pass_case
fi

case_start "a project id needs nothing from the checkout but eas.json"
resolve_paths PROJECT_ID="$PROJECT_UUID"
if assert_equals 0 "$STEP_STATUS" 'status' \
    && assert_equals '/packages/app/eas.json' "$(step_output "$PATHS_WS" sparse)" 'patterns'; then
    pass_case
fi

for dir in '.' './' './packages/app/' 'packages/app/'; do
    case_start "app-dir $dir is normalised"
    resolve_paths APP_DIR="$dir"
    expected='/packages/app'
    case "$dir" in .|./) expected='' ;; esac
    if assert_equals 0 "$STEP_STATUS" 'status' \
        && assert_equals "$expected/eas.json" "$(step_output "$PATHS_WS" sparse | head -1)" 'first pattern'; then
        pass_case
    fi
done

case_start "an install-command needs the whole repository, so the checkout is full"
resolve_paths INSTALL_COMMAND='corepack enable && pnpm install --frozen-lockfile'
if assert_equals 0 "$STEP_STATUS" 'status' && assert_equals '' "$(step_output "$PATHS_WS" sparse)" 'no patterns'; then
    pass_case
fi

for bad in '../x' '/etc' 'a/../b' 'a/*' 'a[b]' '!a' '#a' 'a\b'; do
    case_start "app-dir $bad cannot become a sparse-checkout pattern"
    resolve_paths APP_DIR="$bad"
    if assert_equals 1 "$STEP_STATUS" 'status' && assert_contains "$(cat "$PATHS_WS/log")" 'app-dir' 'message'; then
        pass_case
    fi
done

case_start "the checkout step is sparse, blobless and fed by the resolved patterns; installs run only on request"
if WORKFLOW="$WORKFLOW_YML" python3 -I - <<'PYTHON'
import os
import sys

import yaml

steps = yaml.safe_load(open(os.environ['WORKFLOW'], encoding='utf-8'))['jobs']['cleanup']['steps']
by_name = {step['name']: step for step in steps}
names = [step['name'] for step in steps]
checkout = by_name['Checkout repository']
with_ = checkout['with']
problems = []
if names.index('Resolve checkout paths') > names.index('Checkout repository'):
    problems.append('paths are resolved after the checkout')
if with_.get('filter') != 'blob:none':
    problems.append('checkout is not blobless')
if with_.get('sparse-checkout') != '${{ steps.paths.outputs.sparse }}':
    problems.append('checkout is not fed by the resolved patterns')
if with_.get('sparse-checkout-cone-mode') is not False:
    problems.append('sparse checkout is not in non-cone mode')
if by_name['Resolve checkout paths'].get('id') != 'paths':
    problems.append('the paths step has no id')
if by_name['Install dependencies'].get('if') != "inputs.install-command != ''":
    problems.append('installs are not conditional on install-command')
if problems:
    sys.exit('; '.join(problems))
PYTHON
then
    pass_case
else
    fail_case "checkout step shape"
fi

finish_suite
