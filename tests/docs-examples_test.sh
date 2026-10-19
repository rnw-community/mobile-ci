#!/usr/bin/env bash
# The documented callers are code a consumer copies, so they must not drift
# from the workflows and actions they call. check-doc-uses.py resolves every
# rnw-community/mobile-ci/...@<ref> in docs/examples/ and in the Markdown docs'
# yaml blocks to the file at this commit and rejects an undeclared input or
# secret; the complete examples must also pass every required input, pin
# @vX.Y.Z # vX.Y.Z and grant the permissions the workflow needs. The negative
# cases prove the checker rejects each kind of drift rather than passing
# everything.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

CHECKER="$REPO_ROOT/tests/lib/check-doc-uses.py"
EXAMPLE="$REPO_ROOT/docs/examples/public-expo-app/e2e.yml"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

expect_rejected() {
    local description="$1" file="$2" needle="$3" output
    case_start "$description"
    if output="$(python3 "$CHECKER" "$REPO_ROOT" "$file" 2>&1)"; then
        fail_case "the checker accepted it: $output"
        return
    fi
    assert_contains "$output" "$needle" 'reason named' && pass_case
}

case_start 'every documented call matches the workflows and actions at this commit'
if output="$(python3 "$CHECKER" "$REPO_ROOT" 2>&1)"; then
    pass_case
else
    fail_case "$output"
fi

sed 's/^            flows-dir: apps\/mobile\/e2e\/flows$/&\n            flows-directory: apps\/mobile\/e2e\/flows/' "$EXAMPLE" > "$scratch/unknown-input.yml"
expect_rejected 'an example passing an input the workflow does not declare is rejected' \
    "$scratch/unknown-input.yml" "has no input 'flows-directory'"

grep -v '^            flows-dir: ' "$EXAMPLE" > "$scratch/missing-required.yml"
expect_rejected 'an example omitting a required input is rejected' \
    "$scratch/missing-required.yml" "requires input 'flows-dir'"

sed '0,/^            packages: write$/{/^            packages: write$/d}' "$EXAMPLE" > "$scratch/missing-permission.yml"
expect_rejected 'an example whose calling job lacks a required grant is rejected' \
    "$scratch/missing-permission.yml" 'without packages: write'

sed '0,/@v4\.2\.0 # v4\.2\.0/s//@v4.2.0/' "$EXAMPLE" > "$scratch/unpinned.yml"
expect_rejected 'an example self-reference without its # vX.Y.Z comment is rejected' \
    "$scratch/unpinned.yml" 'not pinned as @vX.Y.Z # vX.Y.Z'

sed 's/EXPO_TOKEN: \${{ secrets.EXPO_PREVIEW_TOKEN }}/EXPO_ACCESS_TOKEN: ${{ secrets.EXPO_PREVIEW_TOKEN }}/' \
    "$REPO_ROOT/docs/examples/private-multi-brand-expo-app/ota-preview.yml" > "$scratch/unknown-secret.yml"
expect_rejected 'an example passing a secret the workflow does not declare is rejected' \
    "$scratch/unknown-secret.yml" "declares no secret 'EXPO_ACCESS_TOKEN'"

sed 's/^                  channel: production-/                  channel-name: production-/' \
    "$REPO_ROOT/docs/examples/private-multi-brand-expo-app/store-release.yml" > "$scratch/action-input.yml"
expect_rejected 'an example step passing an input the action does not declare is rejected' \
    "$scratch/action-input.yml" "has no input 'channel-name'"

cat > "$scratch/doc.md" <<'MARKDOWN'
# A doc

```yaml
jobs:
    e2e:
        uses: rnw-community/mobile-ci/.github/workflows/android-maestro.yml@v4.2.0 # v4.2.0
        with:
            android-driver: redroid
            emulator-flavour: google_apis
```
MARKDOWN
expect_rejected 'a Markdown yaml block passing an undeclared input is rejected' \
    "$scratch/doc.md" "has no input 'emulator-flavour'"

cat > "$scratch/unparsable.md" <<'MARKDOWN'
```yaml
- uses: rnw-community/mobile-ci/actions/eas-update@v4.2.0 # v4.2.0
  with: ...
  run: echo "a: b"
```
MARKDOWN
expect_rejected 'a Markdown yaml block that calls this repo but does not parse is rejected' \
    "$scratch/unparsable.md" 'does not parse'

cat > "$scratch/missing-target.md" <<'MARKDOWN'
```yaml
- uses: rnw-community/mobile-ci/actions/eas-updater@v4.2.0 # v4.2.0
```
MARKDOWN
expect_rejected 'a Markdown yaml block calling an action that does not exist is rejected' \
    "$scratch/missing-target.md" 'not a workflow_call workflow or action at this commit'

mkdir -p "$scratch/docs/workflows"
cat > "$scratch/docs/workflows/pr-closed-cleanup-reusable.md" <<'MARKDOWN'
## Examples

### Minimal

```yaml
jobs:
    cleanup:
        permissions:
            actions: write
        uses: rnw-community/mobile-ci/.github/workflows/pr-closed-cleanup-reusable.yml@v4.2.0 # v4.2.0
```
MARKDOWN
expect_rejected 'a workflow doc without a Full example block is rejected' \
    "$scratch/docs/workflows/pr-closed-cleanup-reusable.md" "no '### Full' yaml block calling pr-closed-cleanup-reusable.yml"

sed -i 's/^            actions: write$/            actions: read/' "$scratch/docs/workflows/pr-closed-cleanup-reusable.md"
expect_rejected 'a workflow doc whose Minimal example lacks a required grant is rejected' \
    "$scratch/docs/workflows/pr-closed-cleanup-reusable.md" 'without actions: write'

finish_suite
