#!/usr/bin/env bash
# GitHub keeps one pending run per concurrency group and cancels the previous
# pending one when another arrives, so a group shared by every pull request of
# a consumer lets one PR's push cancel another PR's queued OTA preview
# (rnw-community/mobile-ci#151). The group has to be scoped to the caller's ref
# while still serialising pushes to the same ref.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

WORKFLOW="$REPO_ROOT/.github/workflows/expo-ota-preview.yml"

read_concurrency() {
    WORKFLOW="$WORKFLOW" python3 - <<'PYTHON'
import os

import yaml

concurrency = yaml.safe_load(open(os.environ['WORKFLOW'], encoding='utf-8'))['concurrency']
print(concurrency['group'])
print(str(concurrency['cancel-in-progress']).lower())
PYTHON
}

case_start 'previews of different refs never share a concurrency group'
concurrency="$(read_concurrency)"
group="$(printf '%s\n' "$concurrency" | sed -n 1p)"
cancel="$(printf '%s\n' "$concurrency" | sed -n 2p)"
assert_contains "$group" "\${{ github.ref }}" 'concurrency group' &&
    assert_contains "$group" "\${{ inputs.app-dir }}" 'concurrency group' &&
    assert_equals false "$cancel" 'cancel-in-progress' &&
    pass_case

finish_suite
