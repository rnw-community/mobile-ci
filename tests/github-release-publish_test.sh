#!/usr/bin/env bash
# github-release-publish prunes releases under a prefix that several runs share
# (every pull request's OTA preview of one app), and expo-ota-preview.yml lets
# those runs overlap. Two overlapping runs see the same stale releases, so the
# second one to reach a release finds it already deleted. That is the expected
# outcome of a shared prefix, not a failure, and must not surface as a warning.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/github-release-publish/action.yml"
STEP='Stage and publish release'

# An already-published release holding exactly the one staged asset, so the
# step goes straight to pruning. Stale releases: pfx-old (present), pfx-gone
# (deleted by a concurrent run before the re-read) and pfx-raced (deleted by a
# concurrent run between the re-read and the delete). pfx-broken fails its
# re-read for a reason other than 404.
publish_stub() {
    local dir="$1"
    stub "$dir" gh "
log=\"$dir/gh-calls\"
printf '%s\n' \"\$*\" >> \"\$log\"
case \"\$*\" in
  'release view pfx-new') exit 0 ;;
  'release view pfx-new --json isDraft --jq .isDraft') echo false ;;
  'release view pfx-new --json assets --jq .assets[] | \"\\(.state)\\t\\(.name)\"') printf 'uploaded\ta.txt\n' ;;
  'release view pfx-new --json assets --jq '*) echo a.txt ;;
  'api --paginate '*)
    for tag in pfx-old pfx-gone pfx-raced \${EXTRA_STALE:-}; do
      printf '{\"tagName\":\"%s\",\"updatedAt\":\"2020-01-01T00:00:00Z\"}\n' \"\$tag\"
    done
    ;;
  'api repos/o/r/releases/tags/pfx-gone'*|'api repos/o/r/releases/tags/pfx-raced'*)
    if [ \"\${1}\${2}\" = 'apirepos/o/r/releases/tags/pfx-raced' ] && ! grep -q '^release delete pfx-raced' \"\$log\"; then
      echo 2020-01-01T00:00:00Z
      exit 0
    fi
    echo 'gh: Not Found (HTTP 404)' >&2
    exit 1
    ;;
  'api repos/o/r/releases/tags/pfx-broken'*) echo 'gh: Server Error (HTTP 502)' >&2; exit 1 ;;
  'api repos/o/r/releases/tags/'*) echo 2020-01-01T00:00:00Z ;;
  'release delete pfx-raced'*) echo 'release not found' >&2; exit 1 ;;
  'release delete '*) exit 0 ;;
  *) echo \"unexpected gh call: \$*\" >&2; exit 1 ;;
esac"
}

run_publish() {
    local dir="$1"
    shift
    mkdir -p "$dir/work/dist"
    printf 'asset\n' > "$dir/work/dist/a.txt"
    run_step "$dir" \
        SOURCE_DIR=dist RELEASE_TAG=pfx-new RELEASE_TITLE='' \
        PRUNE_PREFIX=pfx- PRUNE_KEEP=0 PRUNE_GRACE_MINUTES=10 DRY_RUN=false \
        REPOSITORY=o/r GH_REPO=o/r GH_TOKEN=t "$@"
}

case_start 'a release a concurrent run already pruned is skipped, not warned about'
dir="$(new_workspace "$ACTION" "$STEP")"
publish_stub "$dir"
run_publish "$dir"
log="$(cat "$dir/log")"
assert_equals 0 "$STEP_STATUS" 'exit status' &&
    assert_contains "$log" "Pruned 'pfx-old'." 'present release' &&
    assert_contains "$log" "'pfx-gone' is already gone" 'release deleted before the re-read' &&
    assert_contains "$log" "'pfx-raced' is already gone" 'release deleted between re-read and delete' &&
    assert_contains "$log" '::notice::Release pruning complete.' 'prune outcome' &&
    assert_not_contains "$log" '::warning::' 'warnings' &&
    pass_case

case_start 'a re-read that fails for another reason still reports a prune failure'
dir="$(new_workspace "$ACTION" "$STEP")"
publish_stub "$dir"
run_publish "$dir" EXTRA_STALE=pfx-broken
log="$(cat "$dir/log")"
assert_equals 0 "$STEP_STATUS" 'exit status' &&
    assert_contains "$log" '::warning::Release pruning failed' 'prune outcome' &&
    assert_contains "$log" 'HTTP 502' 'the reason' &&
    pass_case

finish_suite
