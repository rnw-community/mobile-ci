#!/usr/bin/env bash
# packages/e2e-simlock's own unit tests (node:test, TypeScript run by Node's type
# stripping): the farm queue, the relay's target check and local answers, the
# provider's lease, install, swap and release paths, and the exec helpers, all
# against stubs, so no farm is needed.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

case_start 'packages/e2e-simlock: node --test'
if [ "$(node -p 'process.features.typescript || ""' 2>/dev/null)" != strip ]; then
    fail_case "Node.js $(node --version 2>/dev/null || echo 'is missing') cannot strip TypeScript types; the package tests need Node 22.18+ or 24."
elif (cd "$REPO_ROOT/packages/e2e-simlock" && node --test --test-force-exit --test-reporter=dot test/*.test.ts) > "${TMPDIR:-/tmp}/e2e-simlock-node-test.log" 2>&1; then
    pass_case
else
    fail_case "$(cat "${TMPDIR:-/tmp}/e2e-simlock-node-test.log")"
fi

finish_suite
