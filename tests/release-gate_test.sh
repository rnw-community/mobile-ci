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

for scenario in candidate mismatch ordinary existing; do
    case_start "self-reference resolution handles $scenario without a publication cycle"
    workspace=$(new_workflow_workspace "$REPO_ROOT/.github/workflows/self-test.yml" self-reference-resolution 'Every self-reference is tag-form and resolves')
    mkdir -p "$workspace/work/.github/workflows" "$workspace/work/actions/example"
    printf '%s\n' 'uses: rnw-community/mobile-ci/actions/example@v9.8.7 # v9.8.7' > "$workspace/work/actions/example/action.yml"
    printf '%s\n' 'uses: rnw-community/mobile-ci/.github/workflows/example.yml@v9.8.7 # v9.8.7' > "$workspace/work/.github/workflows/example.yml"
    stub "$workspace" sleep ':'
    # shellcheck disable=SC2016
    stub "$workspace" git '[ "${TAG_EXISTS:-false}" = true ] && printf "%s\n" "deadbeef refs/tags/v9.8.7"'
    message='release: v9.8.7 (#123)'
    tag_exists=false
    expected=0
    case "$scenario" in
        mismatch) message='release: v9.8.8'; expected=1 ;;
        ordinary) message='fix: ordinary commit'; expected=1 ;;
        existing) message='fix: ordinary commit'; tag_exists=true ;;
    esac
    run_step "$workspace" HEAD_MESSAGE="$message" TAG_EXISTS="$tag_exists"
    if assert_equals "$expected" "$STEP_STATUS" 'reference resolution status'; then
        pass_case
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
