#!/usr/bin/env bash
# The plan and repack jobs need Node, a JDK and the Android build-tools, never
# /dev/kvm. Defaulting them to the KVM emulator pool made every pull request's
# light jobs queue behind Android emulator shards on the one host that has KVM
# (rnw-community/mobile-ci#169). Their defaults must name a pool without KVM.
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

for spec in ios-maestro:repack-runner-labels android-maestro:repack-runner-labels \
    store-screenshots:repack-runner-labels seed-native-cache:plan-runner-labels \
    expo-base-plan:runner-labels; do
    workflow="${spec%%:*}"
    input="${spec#*:}"
    case_start "$workflow: $input defaults to the non-KVM x86_64 pool"
    default="$(input_default "$REPO_ROOT/.github/workflows/$workflow.yml" "$input")"
    assert_equals '["self-hosted","trf-linux-amd64-2x4"]' "$default" "$input default" && pass_case
done

finish_suite
