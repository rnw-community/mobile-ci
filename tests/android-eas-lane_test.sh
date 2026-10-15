#!/usr/bin/env bash
# An Android `eas build --local` needs Google's NDK, which ships for x86_64
# Linux and macOS but never for linux-aarch64, and needs no Mac at all
# (rnw-community/mobile-ci#149). Its jobs must default to the x86_64 Linux
# pool rather than claim a macOS slot the iOS jobs queue for.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

input_default() {
    WORKFLOW="$1" INPUT="$2" python3 - <<'PYTHON'
import os

import yaml

workflow = yaml.safe_load(open(os.environ['WORKFLOW'], encoding='utf-8'))
triggers = workflow.get('on', workflow.get(True))
print(triggers['workflow_call']['inputs'][os.environ['INPUT']]['default'])
PYTHON
}

for workflow in native-publish native-dev-release seed-native-cache; do
    case_start "$workflow: android-runner-labels defaults to the x86_64 Linux pool"
    default="$(input_default "$REPO_ROOT/.github/workflows/$workflow.yml" android-runner-labels)"
    assert_equals '["self-hosted","trf-linux-amd64-4x8"]' "$default" 'android-runner-labels default' && pass_case
done

finish_suite
