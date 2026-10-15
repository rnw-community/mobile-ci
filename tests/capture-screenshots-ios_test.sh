#!/usr/bin/env bash
# capture-screenshots-ios discovers flow-backed scenes with the same
# name-pattern / exclude-pattern find as run-maestro-ios.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"
# shellcheck source=tests/lib/exclude-pattern-cases.sh
. "$REPO_ROOT/tests/lib/exclude-pattern-cases.sh"

ACTION="$REPO_ROOT/actions/capture-screenshots-ios/action.yml"
CAPTURE_STEP='Run screenshot capture matrix'

prepare_exclude() {
    local dir
    dir="$(new_workspace "$ACTION" "$CAPTURE_STEP")"
    stub "$dir" xcrun 'exit 1'
    stub "$dir" maestro 'exit 1'
    write_exclude_fixture_flows "$dir/work/flows"
    printf '%s\n' "$dir"
}

invoke_exclude() {
    run_step "$1" GITHUB_ENV="$1/github-env" SIMULATOR_UDID=UDID-1 \
        APP_ID=com.example.app APP_PATH=App.app SCREENSHOTS_DIR=flows \
        SCENES_NAME_PATTERN='*.flow.yaml' SCENES_EXCLUDE_PATTERN="$2" SCENES_JSON='' \
        SEED_COMMAND='' SETTLE_SECONDS=0 LAUNCH_SETTLE_SECONDS=0 HAS_DEEPLINK=false \
        DEEPLINK_CONFIRM_TITLE='' DEEPLINK_CONFIRM_BUTTON='' CAPTURE_LOCALES=en-US \
        CAPTURE_APPEARANCES=light ORIENTATION=portrait MAESTRO_ENV='' LOCALE_ENV_JSON='' \
        MAESTRO_CONFIG='' DEVICE_SLUG=iphone
}

run_exclude_pattern_cases scene

finish_suite
