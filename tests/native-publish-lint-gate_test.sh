#!/usr/bin/env bash
# native-publish.yml's android-lint-gate runs :app:lintVitalRelease on a fresh
# runner. Two things keep that gate usable and nothing else checks them: a Gradle
# User Home cache restored before Gradle runs (after prebuild, because the basic
# provider hashes the generated android/ build files into its key), and the
# lint-results reports uploaded when the gate fails, so a failure leaves more
# than console output. This suite pins both to the job's step order.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

WORKFLOW_YML="$REPO_ROOT/.github/workflows/native-publish.yml"
DOC_MD="$REPO_ROOT/docs/workflows/native-publish.md"

check_gate() {
    WORKFLOW="$WORKFLOW_YML" DOC="$DOC_MD" CHECK="$1" python3 - <<'PYTHON'
import os
import re
import sys

import yaml

workflow = yaml.safe_load(open(os.environ['WORKFLOW'], encoding='utf-8'))
inputs = workflow[True]['workflow_call']['inputs']
steps = workflow['jobs']['android-lint-gate']['steps']
check = os.environ['CHECK']
PINNED = re.compile(r'@[0-9a-f]{40}$')


def index_of(predicate, what):
    for i, step in enumerate(steps):
        if predicate(step):
            return i
    sys.exit(f"android-lint-gate has no {what} step")


prebuild = index_of(lambda s: 'expo prebuild' in str(s.get('run', '')), 'expo prebuild')
lint = index_of(lambda s: 'lintVitalRelease' in str(s.get('run', '')), 'lintVitalRelease')

if check == 'cache':
    gradle = index_of(
        lambda s: str(s.get('uses', '')).startswith('gradle/actions/setup-gradle@'),
        'gradle/actions/setup-gradle')
    step = steps[gradle]
    if not PINNED.search(step['uses']):
        sys.exit(f"setup-gradle is not pinned to a full commit SHA: {step['uses']}")
    if not prebuild < gradle < lint:
        sys.exit(
            f"setup-gradle is step {gradle}; it must sit after prebuild ({prebuild}), "
            f"which generates the build files its cache key hashes, and before "
            f"lintVitalRelease ({lint})")
    if step.get('with', {}).get('cache-provider') != 'basic':
        sys.exit("setup-gradle must use cache-provider: basic (MIT, no Free Preview terms)")
    if 'inputs.android-lint-gate-gradle-cache' not in str(step.get('if', '')):
        sys.exit("setup-gradle is not gated on inputs.android-lint-gate-gradle-cache")
    declared = inputs.get('android-lint-gate-gradle-cache')
    if not declared or declared.get('type') != 'boolean' or declared.get('default') is not True:
        sys.exit("input android-lint-gate-gradle-cache must be a boolean defaulting to true")
    if '`android-lint-gate-gradle-cache`' not in open(os.environ['DOC'], encoding='utf-8').read():
        sys.exit("docs/workflows/native-publish.md does not document android-lint-gate-gradle-cache")

elif check == 'reports':
    upload = index_of(
        lambda s: str(s.get('uses', '')).startswith('actions/upload-artifact@')
        and 'lint-results' in str(s.get('with', {}).get('path', '')),
        'lint-results upload')
    step = steps[upload]
    if not PINNED.search(step['uses']):
        sys.exit(f"upload-artifact is not pinned to a full commit SHA: {step['uses']}")
    if upload < lint:
        sys.exit("the lint-results upload runs before lintVitalRelease")
    if 'failure()' not in str(step.get('if', '')):
        sys.exit("the lint-results upload is not gated on failure()")
    with_ = step['with']
    path = str(with_.get('path', ''))
    for suffix in ('lint-results-*.html', 'lint-results-*.xml'):
        if f"/build/reports/{suffix}" not in path:
            sys.exit(f"upload path does not cover **/build/reports/{suffix}: {path!r}")
    if '${{ inputs.app-dir }}/android/' not in path:
        sys.exit(f"upload path is not rooted at the app's android dir: {path!r}")
    if str(with_.get('retention-days')) != '14':
        sys.exit("lint-results upload retention-days must be 14")
    if with_.get('if-no-files-found') != 'ignore':
        sys.exit("lint-results upload must set if-no-files-found: ignore")
    if 'github.run_attempt' not in str(with_.get('name', '')):
        sys.exit("lint-results artifact name must be unique per run attempt")
else:
    sys.exit(f"unknown check {check!r}")
PYTHON
}

case_start "android-lint-gate restores a basic Gradle cache between prebuild and lint"
if failure="$(check_gate cache 2>&1)"; then pass_case; else fail_case "$failure"; fi

case_start "android-lint-gate uploads lint-results reports when it fails"
if failure="$(check_gate reports 2>&1)"; then pass_case; else fail_case "$failure"; fi

finish_suite
