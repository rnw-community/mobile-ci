#!/usr/bin/env bash
# turbo-affected gates both Maestro workflows. Issue #186: an unset
# target-packages used to make every pull request affected; the package names
# are now read from each target's appDir, and every way that read can go wrong
# still fails closed.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/turbo-affected/action.yml"
STEP='Compute affected packages'

WORKSPACE_PACKAGES='@example/app @example/tv @example/landing @example/shared @example/other'

turbo_items() {
    local items='' name
    for name in "$@"; do
        items="${items:+$items,}{\"name\":\"$name\"}"
    done
    printf '{"packages":{"items":[%s]}}' "$items"
}

# prepare <turbo affected package names...>
# Stubs npx as `turbo ls --output=json`, listing $WORKSPACE_PACKAGES, and as
# `turbo ls --affected --output=json`, reporting the given names, and records
# that turbo ran.
prepare() {
    local dir
    dir="$(new_workspace "$ACTION" "$STEP")"
    turbo_items "$@" > "$dir/turbo.json"
    # shellcheck disable=SC2086 # the workspace package list is word-split on purpose.
    turbo_items $WORKSPACE_PACKAGES > "$dir/turbo-all.json"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" npx 'touch "$TURBO_RAN_FILE"
case " $* " in
    *" --affected "*) cat "$TURBO_JSON_FILE" ;;
    *) cat "$TURBO_ALL_FILE" ;;
esac'
    printf '%s\n' "$dir"
}

package() {
    local dir="$1" app_dir="$2" name="$3"
    mkdir -p "$dir/work/$app_dir"
    printf '{"name":"%s","private":true}\n' "$name" > "$dir/work/$app_dir/package.json"
}

detect() {
    local dir="$1"
    shift
    run_step "$dir" \
        TURBO_VERSION=2.10.8 \
        TARGET_PACKAGES='' \
        TARGETS='' \
        TURBO_SCM_BASE=base-sha \
        ALWAYS_AFFECTED=false \
        TURBO_RAN_FILE="$dir/turbo-ran" \
        TURBO_JSON_FILE="$dir/turbo.json" \
        TURBO_ALL_FILE="$dir/turbo-all.json" \
        "$@"
}

assert_failed_closed() {
    local dir="$1" message="$2"
    if [ "$STEP_STATUS" -eq 0 ]; then
        fail_case "the step succeeded with affected='$(step_output "$dir" affected)'"
        return 1
    fi
    assert_equals '' "$(step_output "$dir" affected)" 'affected output' \
        && assert_contains "$(cat "$dir/log")" "$message" 'error message'
}

TARGETS_JSON='[{"name":"bare","appDir":"packages/app"},{"name":"tablet","appDir":"packages/app"},{"name":"tv","appDir":"apps/tv"}]'

case_start 'target-packages defaults to empty so it can be derived'
if assert_equals '' "$(action_input_default "$ACTION" target-packages)" 'target-packages default'; then
    pass_case
fi

case_start 'derived names skip a pull request that changes only an unrelated package'
dir="$(prepare @example/landing)"
package "$dir" packages/app @example/app
package "$dir" apps/tv @example/tv
detect "$dir" TARGETS="$TARGETS_JSON"
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals false "$(step_output "$dir" affected)" 'affected' \
    && assert_contains "$(cat "$dir/log")" '@example/app' 'derived names logged' \
    && pass_case

case_start 'derived names report affected when a target app changes'
dir="$(prepare @example/landing @example/tv)"
package "$dir" packages/app @example/app
package "$dir" apps/tv @example/tv
detect "$dir" TARGETS="$TARGETS_JSON"
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals true "$(step_output "$dir" affected)" 'affected' \
    && pass_case

case_start 'explicit target-packages wins over the targets appDir names'
dir="$(prepare @example/app)"
detect "$dir" TARGETS="$TARGETS_JSON" TARGET_PACKAGES="$(printf '@example/shared\n@example/other\n')"
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals false "$(step_output "$dir" affected)" 'affected' \
    && pass_case

case_start 'a derived target package that is not a turbo workspace package fails closed'
dir="$(prepare @example/landing)"
package "$dir" packages/app @example/app
package "$dir" apps/outside @example/outside
detect "$dir" TARGETS='[{"name":"bare","appDir":"packages/app"},{"name":"tv","appDir":"apps/outside"}]'
assert_failed_closed "$dir" '@example/outside' && pass_case

case_start 'an explicit target package that is not a turbo workspace package fails closed'
dir="$(prepare @example/landing)"
detect "$dir" TARGET_PACKAGES="$(printf '@example/app\n@example/typo\n')"
assert_failed_closed "$dir" '@example/typo' && pass_case

case_start 'scoped names and appDir spellings that name one package are matched once'
dir="$(prepare @example/app)"
package "$dir" packages/app @example/app
detect "$dir" TARGETS='[{"name":"a","appDir":"./packages/app/"},{"name":"b","appDir":"packages/app"}]'
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals true "$(step_output "$dir" affected)" 'affected' \
    && assert_equals 1 "$(grep -c '^@example/app$' "$dir/log")" 'derived name listed once' \
    && pass_case

case_start 'no target-packages and no targets fails closed'
dir="$(prepare)"
detect "$dir"
assert_failed_closed "$dir" 'targets' && pass_case

case_start 'no target-packages and an empty targets array fails closed'
dir="$(prepare)"
detect "$dir" TARGETS='[]'
assert_failed_closed "$dir" 'targets' && pass_case

case_start 'a target whose package.json cannot be read fails closed'
dir="$(prepare)"
package "$dir" packages/app @example/app
detect "$dir" TARGETS="$TARGETS_JSON"
assert_failed_closed "$dir" 'apps/tv/package.json' && pass_case

case_start 'a target package.json without a name fails closed'
dir="$(prepare)"
package "$dir" packages/app @example/app
mkdir -p "$dir/work/apps/tv"
printf '{"private":true}\n' > "$dir/work/apps/tv/package.json"
detect "$dir" TARGETS="$TARGETS_JSON"
assert_failed_closed "$dir" 'apps/tv/package.json' && pass_case

case_start 'a target without an appDir fails closed'
dir="$(prepare)"
detect "$dir" TARGETS='[{"name":"bare"}]'
assert_failed_closed "$dir" 'appDir' && pass_case

case_start 'a target at the repository root fails closed'
dir="$(prepare)"
package "$dir" . @example/root
detect "$dir" TARGETS='[{"name":"bare","appDir":"./"}]'
assert_failed_closed "$dir" 'repository root' && pass_case

case_start 'a missing base SHA reports affected without running turbo'
dir="$(prepare)"
package "$dir" packages/app @example/app
package "$dir" apps/tv @example/tv
detect "$dir" TARGETS="$TARGETS_JSON" TURBO_SCM_BASE=''
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals true "$(step_output "$dir" affected)" 'affected' \
    && assert_equals no "$([ -e "$dir/turbo-ran" ] && echo yes || echo no)" 'turbo ran' \
    && pass_case

case_start 'a turbo failure fails closed'
dir="$(prepare)"
package "$dir" packages/app @example/app
package "$dir" apps/tv @example/tv
stub "$dir" npx 'echo "turbo exploded" >&2; exit 3'
detect "$dir" TARGETS="$TARGETS_JSON"
assert_failed_closed "$dir" 'turbo exploded' && pass_case

case_start 'always-affected reports affected without reading targets'
dir="$(prepare)"
detect "$dir" ALWAYS_AFFECTED=true
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals true "$(step_output "$dir" affected)" 'affected' \
    && pass_case

for workflow in ios-maestro android-maestro; do
    case_start "$workflow.yml hands its targets to turbo-affected and is always affected only off pull requests"
    wiring="$(WORKFLOW_YML="$REPO_ROOT/.github/workflows/$workflow.yml" python3 - <<'PYTHON'
import os

import yaml

workflow = yaml.safe_load(open(os.environ['WORKFLOW_YML'], encoding='utf-8'))
step = next(step for step in workflow['jobs']['detect']['steps'] if 'turbo-affected' in step.get('uses', ''))
print(step['with'].get('targets', ''))
print(step['with'].get('always-affected', ''))
PYTHON
)"
    # shellcheck disable=SC2016 # the expressions are matched literally.
    assert_equals "$(printf '%s\n%s' '${{ inputs.targets }}' "\${{ github.event_name != 'pull_request' }}")" "$wiring" 'turbo-affected with:' \
        && pass_case
done

finish_suite
