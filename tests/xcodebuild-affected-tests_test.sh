#!/usr/bin/env bash
# xcodebuild-affected-tests decides what a pull request does NOT run, so every
# case here is about the selection being provably complete: an unmapped file, a
# touched full-suite path, a push, or a base ref the checkout cannot reach all
# have to widen back to the full suite.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/xcodebuild-affected-tests/action.yml"
MAPS="$REPO_ROOT/fixtures/affected-tests"

# A scratch repository with one commit per file set, so the step runs a real
# `git diff` rather than a stubbed one.
repo_workspace() {
    local dir
    dir="$(new_workspace "$ACTION" 'Select the tests the changed files affect')"
    (
        cd "$dir/work"
        git init -q -b main
        git config user.email fixture@example.com
        git config user.name Fixture
        mkdir -p Sources/Maze Sources/Menu Resources/levels 'Pony.xcodeproj' ci
        cp "$MAPS"/*.json ci/
        echo base > Sources/Maze/Maze.swift
        echo base > Sources/Menu/Menu.swift
        echo base > Resources/levels/one.json
        echo base > README.md
        echo base > 'Pony.xcodeproj/project.pbxproj'
        git add -A
        git commit -qm base
    ) > "$dir/git-log" 2>&1
    printf '%s\n' "$dir"
}

commit_change() {
    local dir="$1"
    shift
    (
        cd "$dir/work"
        for path in "$@"; do
            mkdir -p "$(dirname "$path")"
            echo changed >> "$path"
        done
        git add -A
        git commit -qm change
    ) >> "$dir/git-log" 2>&1
}

select_tests() {
    local dir="$1"
    shift
    run_step "$dir" \
        MAP_FILE='ci/map.json' \
        BASE_REF='main~1' \
        HEAD_REF='main' \
        FULL_SUITE_PATHS='' \
        FALLBACK='all' \
        WORKING_DIRECTORY='.' \
        GITHUB_EVENT_NAME='pull_request' \
        "$@"
}

case_start 'a mapped change selects exactly the tests that cover it'
workspace="$(repo_workspace)"
commit_change "$workspace" Sources/Menu/Menu.swift
select_tests "$workspace"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'affected' "$(step_output "$workspace" mode)" 'mode' \
    && assert_equals 'PonyUITests/MenuTests/testStart
PonyUITests/MenuTests/testResume' "$(step_output "$workspace" only-testing)" 'only-testing'; then
    pass_case
fi

case_start 'a file claimed by two entries selects both, without duplicates'
workspace="$(repo_workspace)"
commit_change "$workspace" Sources/Maze/Maze.swift Resources/levels/one.json
select_tests "$workspace"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'affected' "$(step_output "$workspace" mode)" 'mode' \
    && assert_equals 'PonyUITests/LevelLoadingTests
PonyUITests/MazeTests' "$(step_output "$workspace" only-testing)" 'only-testing (changed-file order, then map order, deduped)'; then
    pass_case
fi

case_start 'a rename across two entries selects both sides, not just the destination'
workspace="$(repo_workspace)"
(
    cd "$workspace/work"
    git mv Sources/Maze/Maze.swift Sources/Menu/Maze.swift
    git commit -qm 'move the maze under the menu'
) >> "$workspace/git-log" 2>&1
select_tests "$workspace"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'affected' "$(step_output "$workspace" mode)" 'mode' \
    && assert_contains "$(step_output "$workspace" only-testing)" 'PonyUITests/MazeTests' 'the vacated entry still runs' \
    && assert_contains "$(step_output "$workspace" only-testing)" 'PonyUITests/MenuTests/testStart' 'the destination entry runs'; then
    pass_case
fi

case_start 'a changed path that begins with a space is not trimmed into a mapped one'
workspace="$(repo_workspace)"
commit_change "$workspace" ' Sources/Menu/Menu.swift'
select_tests "$workspace"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'all' "$(step_output "$workspace" mode)" 'mode'; then
    pass_case
fi

case_start 'a changed file no entry claims runs the full suite'
workspace="$(repo_workspace)"
commit_change "$workspace" Sources/Menu/Menu.swift README.md
select_tests "$workspace"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'all' "$(step_output "$workspace" mode)" 'mode' \
    && assert_equals '' "$(step_output "$workspace" only-testing)" 'only-testing' \
    && assert_contains "$(cat "$workspace/summary")" 'README.md' 'the unmapped file is named in the summary'; then
    pass_case
fi

case_start 'changing the map itself runs the full suite'
workspace="$(repo_workspace)"
(
    cd "$workspace/work"
    printf '[{"paths": ["Sources/Menu/**"], "tests": ["PonyUITests/MenuTests"]}]' > ci/map.json
    echo changed >> Sources/Menu/Menu.swift
    git add -A
    git commit -qm 'remap the menu'
) >> "$workspace/git-log" 2>&1
select_tests "$workspace"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'all' "$(step_output "$workspace" mode)" 'mode' \
    && assert_equals '' "$(step_output "$workspace" only-testing)" 'only-testing'; then
    pass_case
fi

# A path containing a newline can match no glob at all (the compiled patterns
# never cross a newline), so it lands in the unmapped bucket and widens the run.
# The map's own path is read NUL-delimited for the same reason: a quoted
# "ci/map\nwith-newline.json" would be a full-suite glob matching nothing.
case_start 'a map whose own path contains a newline still widens the run'
workspace="$(repo_workspace)"
map_with_newline="$(printf 'ci/map\nwith-newline.json')"
(
    cd "$workspace/work"
    printf '[{"paths": ["Sources/Menu/**", "ci/**"], "tests": ["PonyUITests/MenuTests"]}]' > "$map_with_newline"
    git add -A
    git commit -qm 'a self-claiming map, at a path with a newline in it'
    printf '[{"paths": ["Sources/Menu/**", "ci/**"], "tests": ["PonyUITests/MenuTests/testStart"]}]' > "$map_with_newline"
    echo changed >> Sources/Menu/Menu.swift
    git add -A
    git commit -qm 'remap the menu'
) >> "$workspace/git-log" 2>&1
select_tests "$workspace" MAP_FILE="$map_with_newline"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'all' "$(step_output "$workspace" mode)" 'mode'; then
    pass_case
fi

case_start 'a map git does not track fails the step'
workspace="$(repo_workspace)"
commit_change "$workspace" Sources/Menu/Menu.swift
cp "$MAPS/map.json" "$workspace/work/untracked-map.json"
select_tests "$workspace" MAP_FILE='untracked-map.json'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'not tracked by git' 'error message'; then
    pass_case
fi

case_start 'a test identifier named like the output delimiter survives the output'
workspace="$(repo_workspace)"
(
    cd "$workspace/work"
    printf '[{"paths": ["Sources/Menu/**"], "tests": ["ONLY_TESTING_EOF"]}]' > ci/delimiter-map.json
    git add -A
    git commit -qm delimiter-map
) >> "$workspace/git-log" 2>&1
commit_change "$workspace" Sources/Menu/Menu.swift
select_tests "$workspace" MAP_FILE='ci/delimiter-map.json'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'affected' "$(step_output "$workspace" mode)" 'mode' \
    && assert_equals 'ONLY_TESTING_EOF' "$(step_output "$workspace" only-testing)" 'only-testing'; then
    pass_case
fi

case_start 'a touched full-suite path runs the full suite'
workspace="$(repo_workspace)"
commit_change "$workspace" Sources/Menu/Menu.swift 'Pony.xcodeproj/project.pbxproj'
select_tests "$workspace" FULL_SUITE_PATHS='**/*.pbxproj .github/workflows/**'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'all' "$(step_output "$workspace" mode)" 'mode' \
    && assert_equals '' "$(step_output "$workspace" only-testing)" 'only-testing'; then
    pass_case
fi

# The changed file is mapped, so only the full-suite glob can widen this run -
# a glob split in half would leave it at 'affected'.
case_start 'a full-suite glob containing a space is one glob, not two'
workspace="$(repo_workspace)"
commit_change "$workspace" 'Sources/Menu/Main Menu.swift'
select_tests "$workspace" FULL_SUITE_PATHS='Sources/Menu/Main Menu.swift
.github/workflows/**'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'all' "$(step_output "$workspace" mode)" 'mode' \
    && assert_contains "$(cat "$workspace/summary")" 'full suite' 'the reason is stated'; then
    pass_case
fi

case_start 'a push event runs the full suite without consulting git at all'
workspace="$(repo_workspace)"
commit_change "$workspace" Sources/Menu/Menu.swift
run_step "$workspace" \
    MAP_FILE='ci/map.json' \
    BASE_REF='' HEAD_REF='' FULL_SUITE_PATHS='' FALLBACK='all' WORKING_DIRECTORY='.' \
    GITHUB_EVENT_NAME='push'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'all' "$(step_output "$workspace" mode)" 'mode' \
    && assert_equals '' "$(step_output "$workspace" only-testing)" 'only-testing'; then
    pass_case
fi

case_start 'explicit refs on a push still run the full suite'
workspace="$(repo_workspace)"
commit_change "$workspace" Sources/Menu/Menu.swift
select_tests "$workspace" GITHUB_EVENT_NAME='push'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'all' "$(step_output "$workspace" mode)" 'mode' \
    && assert_equals '' "$(step_output "$workspace" only-testing)" 'only-testing'; then
    pass_case
fi

case_start "an empty base-ref resolves the pull request's base and head from the event payload"
workspace="$(repo_workspace)"
commit_change "$workspace" Sources/Menu/Menu.swift
base_sha="$(git -C "$workspace/work" rev-parse main~1)"
head_sha="$(git -C "$workspace/work" rev-parse main)"
printf '{"pull_request":{"base":{"sha":"%s"},"head":{"sha":"%s"}}}' "$base_sha" "$head_sha" > "$workspace/event.json"
run_step "$workspace" \
    MAP_FILE='ci/map.json' \
    BASE_REF='' HEAD_REF='' FULL_SUITE_PATHS='' FALLBACK='all' WORKING_DIRECTORY='.' \
    GITHUB_EVENT_NAME='pull_request' GITHUB_EVENT_PATH="$workspace/event.json"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'affected' "$(step_output "$workspace" mode)" 'mode' \
    && assert_contains "$(step_output "$workspace" only-testing)" 'PonyUITests/MenuTests/testStart' 'only-testing'; then
    pass_case
fi

case_start 'a base ref the checkout cannot reach runs the full suite and says why'
workspace="$(repo_workspace)"
commit_change "$workspace" Sources/Menu/Menu.swift
select_tests "$workspace" BASE_REF='0000000000000000000000000000000000000000'
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'all' "$(step_output "$workspace" mode)" 'mode' \
    && assert_contains "$(cat "$workspace/log")" 'fetch-depth' 'the shallow-checkout cause is named'; then
    pass_case
fi

case_start "fallback 'fail' turns an undeterminable diff into a failed step"
workspace="$(repo_workspace)"
commit_change "$workspace" Sources/Menu/Menu.swift
select_tests "$workspace" BASE_REF='0000000000000000000000000000000000000000' FALLBACK='fail'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" '::error::' 'error annotation'; then
    pass_case
fi

case_start 'an unknown fallback value fails closed'
workspace="$(repo_workspace)"
select_tests "$workspace" FALLBACK='maybe'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" "fallback must be 'all' or 'fail'" 'error message'; then
    pass_case
fi

case_start 'a base-ref git would read as an option fails closed'
workspace="$(repo_workspace)"
commit_change "$workspace" Sources/Menu/Menu.swift
select_tests "$workspace" BASE_REF='--upload-pack=touch /tmp/pwned'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'would be read by git as an option' 'error message'; then
    pass_case
fi

case_start 'a changed path with a space or a non-ASCII name is matched, not quoted'
workspace="$(repo_workspace)"
commit_change "$workspace" 'Sources/Menu/Main Menu.swift' 'Sources/Menu/Ünicode.swift'
select_tests "$workspace"
if assert_equals 0 "$STEP_STATUS" 'step status' \
    && assert_equals 'affected' "$(step_output "$workspace" mode)" 'mode' \
    && assert_equals 'PonyUITests/MenuTests/testStart
PonyUITests/MenuTests/testResume' "$(step_output "$workspace" only-testing)" 'only-testing'; then
    pass_case
fi

case_start 'a missing map file fails the step rather than quietly running everything'
workspace="$(repo_workspace)"
commit_change "$workspace" Sources/Menu/Menu.swift
select_tests "$workspace" MAP_FILE='does-not-exist.json'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'No affected-tests map' 'error message'; then
    pass_case
fi

case_start 'an entry with no tests is refused, because it would skip a change silently'
workspace="$(repo_workspace)"
commit_change "$workspace" Sources/Menu/Menu.swift
select_tests "$workspace" MAP_FILE='ci/map-empty-tests.json'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" "non-empty 'tests' array" 'error message'; then
    pass_case
fi

case_start 'a test identifier xcodebuild would read as a flag is refused'
workspace="$(repo_workspace)"
commit_change "$workspace" Sources/Menu/Menu.swift
select_tests "$workspace" MAP_FILE='ci/map-bad-identifier.json'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'is not a' 'error message'; then
    pass_case
fi

case_start 'a map that is not an array is refused'
workspace="$(repo_workspace)"
commit_change "$workspace" Sources/Menu/Menu.swift
select_tests "$workspace" MAP_FILE='ci/map-not-an-array.json'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'non-empty JSON array' 'error message'; then
    pass_case
fi

case_start 'the step summary lists every changed file and what it selected'
workspace="$(repo_workspace)"
commit_change "$workspace" Sources/Menu/Menu.swift
select_tests "$workspace"
summary="$(cat "$workspace/summary")"
if assert_contains "$summary" '### Affected tests' 'summary heading' \
    && assert_contains "$summary" "| \`Sources/Menu/Menu.swift\` |" 'changed file row' \
    && assert_contains "$summary" 'PonyUITests/MenuTests/testResume' 'selected tests'; then
    pass_case
fi

finish_suite
