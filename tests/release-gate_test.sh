#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

case_start 'release waits for completed self-test runs on main instead of push'
if python3 - "$REPO_ROOT/.github/workflows/release.yml" <<'PY'
import sys, yaml
workflow = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
trigger = workflow.get("on", workflow.get(True, {}))
assert "push" not in trigger, "a push must not publish before self-test"
assert trigger["workflow_run"] == {"workflows": ["self-test"], "types": ["completed"], "branches": ["main"]}
PY
then
    pass_case
else
    fail_case "release workflow contract violated"
fi

case_start 'release admits only successful trusted main push runs'
if python3 - "$REPO_ROOT/.github/workflows/release.yml" <<'PY'
import sys, yaml
from types import SimpleNamespace
workflow = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
condition = workflow["jobs"]["auto-tag-release"].get("if", "True")
condition = condition.removeprefix("${{").removesuffix("}}").strip().replace("&&", " and ").replace("||", " or ")
for conclusion, event, branch, repository, expected in [
    ("success", "push", "main", "rnw-community/mobile-ci", True),
    ("failure", "push", "main", "rnw-community/mobile-ci", False),
    ("cancelled", "push", "main", "rnw-community/mobile-ci", False),
    ("success", "pull_request", "main", "rnw-community/mobile-ci", False),
    ("success", "push", "feature", "rnw-community/mobile-ci", False),
    ("success", "push", "main", "someone/mobile-ci", False),
]:
    run = SimpleNamespace(conclusion=conclusion, event=event, head_branch=branch, head_repository=SimpleNamespace(full_name=repository))
    github = SimpleNamespace(repository="rnw-community/mobile-ci", event=SimpleNamespace(workflow_run=run))
    actual = eval(condition, {"__builtins__": {}}, {"github": github})
    assert actual is expected, f"incorrect release admission: {(conclusion, event, branch, repository)}"
PY
then
    pass_case
else
    fail_case "release workflow contract violated"
fi

case_start 'release checkout and detection use the exact tested commit'
if python3 - "$REPO_ROOT/.github/workflows/release.yml" <<'PY'
import sys, yaml
workflow = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
steps = workflow["jobs"]["auto-tag-release"]["steps"]
checkout = next(step for step in steps if step.get("uses", "").startswith("actions/checkout@"))
detect = next(step for step in steps if step.get("id") == "detect")
expected = "${{ github.event.workflow_run.head_sha }}"
assert checkout.get("with", {}).get("ref") == expected, "checkout must not follow a newer main"
assert detect["env"]["HEAD_SHA"] == expected, "release detection must inspect the tested commit"
PY
then
    pass_case
else
    fail_case "release workflow contract violated"
fi

# new_self_reference_origin <workspace> <tag> <path>...
# Builds <workspace>/origin, a repository whose <tag> contains exactly the given
# paths, and wires it up as the work tree's `origin`, so the step's ls-remote,
# fetch and cat-file run against real git instead of a stub.
new_self_reference_origin() {
    local workspace="$1" tag="$2" path
    shift 2
    git init -q "$workspace/origin"
    for path in "$@"; do
        mkdir -p "$workspace/origin/$(dirname "$path")"
        printf '%s\n' 'name: example' > "$workspace/origin/$path"
    done
    git -C "$workspace/origin" add -A
    git -C "$workspace/origin" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false \
        commit -q --allow-empty -m "release: $tag"
    git -C "$workspace/origin" tag "$tag"
    git init -q "$workspace/work"
    git -C "$workspace/work" remote add origin "file://$workspace/origin"
}

for scenario in candidate mismatch ordinary existing pr-existing pr-unreleased pr-missing-action pr-missing-workflow push-missing-action; do
    case_start "self-reference resolution handles $scenario"
    workspace=$(new_workflow_workspace "$REPO_ROOT/.github/workflows/self-test.yml" self-reference-resolution 'Every self-reference is tag-form and resolves')
    stub "$workspace" sleep ':'
    event=push
    message='fix: ordinary commit'
    ref_tag=v9.8.7
    action=example
    expected=0
    released_paths='actions/example/action.yml .github/workflows/example.yml'
    origin_tag=v9.8.6
    case "$scenario" in
        candidate) message='release: v9.8.7 (#123)' ;;
        mismatch) message='release: v9.8.8'; expected=1 ;;
        ordinary) expected=1 ;;
        existing) origin_tag=v9.8.7 ;;
        pr-existing) event=pull_request; origin_tag=v9.8.7 ;;
        pr-unreleased) event=pull_request; ref_tag=v9.9.0; origin_tag=v9.8.7 ;;
        pr-missing-action) event=pull_request; origin_tag=v9.8.7; action=brand-new; expected=1 ;;
        pr-missing-workflow) event=pull_request; origin_tag=v9.8.7; released_paths='actions/example/action.yml'; expected=1 ;;
        push-missing-action) origin_tag=v9.8.7; action=brand-new; expected=1 ;;
    esac
    # shellcheck disable=SC2086
    new_self_reference_origin "$workspace" "$origin_tag" $released_paths
    mkdir -p "$workspace/work/.github/workflows" "$workspace/work/actions/example"
    printf '%s\n' "uses: rnw-community/mobile-ci/actions/$action@$ref_tag # $ref_tag" > "$workspace/work/actions/example/action.yml"
    printf '%s\n' "uses: rnw-community/mobile-ci/.github/workflows/example.yml@$ref_tag # $ref_tag" > "$workspace/work/.github/workflows/example.yml"
    run_step "$workspace" EVENT_NAME="$event" HEAD_MESSAGE="$message"
    log=$(cat "$workspace/log")
    if assert_equals "$expected" "$STEP_STATUS" "reference resolution status ($log)"; then
        case "$scenario" in
            *-missing-action)
                assert_contains "$log" "actions/brand-new@v9.8.7" 'missing action named' \
                    && assert_contains "$log" 'upcoming release tag' 'remedy named' && pass_case ;;
            pr-missing-workflow)
                assert_contains "$log" ".github/workflows/example.yml@v9.8.7" 'missing workflow named' \
                    && assert_contains "$log" 'upcoming release tag' 'remedy named' && pass_case ;;
            *) pass_case ;;
        esac
    fi
done

for scenario in matching mismatched-workflow; do
    case_start "release consistency checks $scenario action and workflow tags"
    workspace=$(new_workflow_workspace "$REPO_ROOT/.github/workflows/release.yml" auto-tag-release 'Verify self-reference consistency before tagging')
    mkdir -p "$workspace/work/.github/workflows" "$workspace/work/actions/example"
    printf '%s\n' 'uses: rnw-community/mobile-ci/actions/example@v9.8.7 # v9.8.7' > "$workspace/work/actions/example/action.yml"
    workflow_tag=v9.8.7
    expected=0
    if [ "$scenario" = mismatched-workflow ]; then workflow_tag=v9.8.6; expected=1; fi
    printf '%s\n' "uses: rnw-community/mobile-ci/.github/workflows/example.yml@$workflow_tag # $workflow_tag" > "$workspace/work/.github/workflows/example.yml"
    run_step "$workspace" TAG=v9.8.7
    if assert_equals "$expected" "$STEP_STATUS" 'release consistency status'; then
        pass_case
    fi
done

finish_suite
