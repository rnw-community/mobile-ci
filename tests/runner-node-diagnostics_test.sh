#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

for job in build test; do
    case_start "$job diagnostics survive a broken Node under runner shell flags"
    dir=$(new_workflow_workspace "$REPO_ROOT/.github/workflows/ios-maestro.yml" "$job" "Diagnose the runner's bundled Node after a failure")
    mkdir -p "$dir/runner/externals/node24/bin" "$dir/runner/_work/_temp"
    printf '#!/bin/sh\nexit 126\n' > "$dir/runner/externals/node24/bin/node"
    chmod +x "$dir/runner/externals/node24/bin/node"
    for command in sw_vers uname uptime ls shasum file xxd codesign xattr sysctl vm_stat df; do
        stub "$dir" "$command" 'exit 0'
    done
    stub "$dir" sudo 'exit 1'
    stub "$dir" log 'echo "kernel node exec diagnostic reached"'
    status=0
    env PATH="$dir/stub-bin:$PATH" RUNNER_TEMP="$dir/runner/_work/_temp" \
        bash --noprofile --norc -e -o pipefail "$dir/step.sh" > "$dir/log" 2>&1 || status=$?
    assert_equals 0 "$status" 'diagnostics complete' &&
        assert_contains "$(cat "$dir/log")" 'exec exit status: 126' 'broken executable recorded' &&
        assert_contains "$(cat "$dir/log")" 'fresh copy exec exit status: 126' 'copy probed' &&
        assert_contains "$(cat "$dir/log")" 'kernel node exec diagnostic reached' 'later probes still run' && pass_case
done

finish_suite
