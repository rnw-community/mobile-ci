#!/usr/bin/env bash
# pr-preview-comment keeps one sticky comment per pull request, found by a
# hidden marker: it edits that comment in place, creates it only when absent,
# replaces only the sections its caller owns, and verifies each write,
# retrying when a concurrent writer clobbered it. The curl stub below is a
# tiny in-memory comment store: $FAKE/comments/<id> holds each body.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/pr-preview-comment/action.yml"
STEP='Update the sticky preview comment'
MARKER='<!-- mobile-ci:preview -->'

# shellcheck disable=SC2016
CURL_STUB='
method=GET out="" url="" data=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    --data-binary) data="${2#@}"; shift 2 ;;
    -H|-w) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
path="${url#*/repos/acme/app/}"
printf "%s %s\n" "$method" "${path%%\?*}" >> "$FAKE/calls"
store="$FAKE/comments"
comment_json() { jq -n --arg id "$1" --rawfile body "$store/$1" "{id: (\$id | tonumber), body: \$body, html_url: \"https://github.com/acme/app/pull/42#issuecomment-\(\$id)\"}"; }
case "$method $path" in
  "GET issues/42/comments?"*page=1)
    if [ -n "${FAKE_LIST_STATUS:-}" ]; then printf "{}" > "$out"; printf "%s" "$FAKE_LIST_STATUS"; exit 0; fi
    if [ -n "${FAKE_PAGINATE:-}" ]; then jq -n "[range(1; 101) | {id: ., body: \"filler\"}]" > "$out"; printf 200; exit 0; fi
    for id in $(ls "$store" | sort -n); do comment_json "$id"; done | jq -s . > "$out"; printf 200 ;;
  "GET issues/42/comments?"*page=2)
    if [ -n "${FAKE_PAGINATE:-}" ]; then for id in $(ls "$store" | sort -n); do comment_json "$id"; done | jq -s . > "$out"; else printf "[]" > "$out"; fi
    printf 200 ;;
  "GET issues/42/comments?"*) printf "[]" > "$out"; printf 200 ;;
  "POST issues/42/comments")
    if [ -n "${FAKE_RACE_CREATE:-}" ] && [ ! -e "$FAKE/raced" ]; then
      touch "$FAKE/raced"
      printf "%s\n## Mobile preview\n\n<!-- mobile-ci:preview:section:ios-ota:start -->\nother writer\n<!-- mobile-ci:preview:section:ios-ota:end -->\n" "<!-- mobile-ci:preview -->" > "$store/150"
    fi
    id=$(( $(ls "$store" | sort -n | tail -n 1 | grep . || echo 199) + 1 ))
    jq -r .body "$data" > "$store/$id"; comment_json "$id" > "$out"; printf 201 ;;
  "GET issues/comments/"*)
    id="${path#issues/comments/}"
    if [ -f "$store/$id" ]; then comment_json "$id" > "$out"; printf 200; else printf "{}" > "$out"; printf 404; fi ;;
  "PATCH issues/comments/"*)
    id="${path#issues/comments/}"
    if [ -n "${FAKE_PATCH_STATUS:-}" ]; then printf "{\"message\":\"Resource not accessible by integration\"}" > "$out"; printf "%s" "$FAKE_PATCH_STATUS"; exit 0; fi
    jq -r .body "$data" > "$store/$id"
    clobbers="$(cat "$FAKE/clobbers" 2>/dev/null || echo 0)"
    if [ "$clobbers" -gt 0 ]; then
      echo $((clobbers - 1)) > "$FAKE/clobbers"
      cp "$FAKE/stale" "$store/$id"
    fi
    comment_json "$id" > "$out"; printf 200 ;;
  "DELETE issues/comments/"*) rm -f "$store/${path#issues/comments/}"; printf "" > "$out"; printf 204 ;;
  *) printf "{}" > "$out"; printf 404 ;;
esac
'

setup() {
    workspace="$(new_workspace "$ACTION" "$STEP")"
    mkdir -p "$workspace/fake/comments" "$workspace/sections"
    : > "$workspace/fake/calls"
    stub "$workspace" curl "$CURL_STUB"
    stub "$workspace" sleep ':'
}

comment() {
    run_step "$workspace" FAKE="$workspace/fake" GH_TOKEN='token' REPOSITORY='acme/app' \
        PR_NUMBER='42' SECTIONS_DIR="$workspace/sections" TITLE='## Mobile preview' \
        MAX_ATTEMPTS='5' GITHUB_API_URL='https://api.github.com' "$@"
}

section_body() {
    # section_body <comment id> <section>
    awk -v key="$2" '
        $0 == "<!-- mobile-ci:preview:section:" key ":end -->" { on = 0 }
        on { print }
        $0 == "<!-- mobile-ci:preview:section:" key ":start -->" { on = 1 }
    ' "$workspace/fake/comments/$1"
}

case_start 'no marked comment: creates exactly one'
setup
printf 'An unrelated comment\n' > "$workspace/fake/comments/100"
printf 'iOS update\n' > "$workspace/sections/ios-ota.md"
comment
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals "$MARKER" "$(head -n 1 "$workspace/fake/comments/101")" 'marker line' \
    && assert_equals 'iOS update' "$(section_body 101 ios-ota)" 'section' \
    && assert_equals '101' "$(step_output "$workspace" comment-id)" 'comment-id output' \
    && assert_equals 2 "$(find "$workspace/fake/comments" -type f | wc -l | tr -d ' ')" 'comment count'; then
    pass_case
fi

case_start 'a marked comment is edited in place, keeping sections other writers own'
setup
printf '%s\n## Mobile preview\n\n<!-- mobile-ci:preview:section:android-dev-build:start -->\nnative apk\n<!-- mobile-ci:preview:section:android-dev-build:end -->\n\n<!-- mobile-ci:preview:section:ios-ota:start -->\nold\n<!-- mobile-ci:preview:section:ios-ota:end -->\n' "$MARKER" > "$workspace/fake/comments/120"
printf 'new\nsecond line\n' > "$workspace/sections/ios-ota.md"
printf 'android update\n' > "$workspace/sections/android-ota.md"
comment
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals 1 "$(find "$workspace/fake/comments" -type f | wc -l | tr -d ' ')" 'comment count' \
    && assert_not_contains "$(cat "$workspace/fake/calls")" 'POST' 'no new comment' \
    && assert_equals "$(printf 'new\nsecond line')" "$(section_body 120 ios-ota)" 'own section replaced' \
    && assert_equals 'android update' "$(section_body 120 android-ota)" 'own section added' \
    && assert_equals 'native apk' "$(section_body 120 android-dev-build)" 'other writer kept'; then
    pass_case
fi

case_start 'an empty section file removes that section'
setup
printf '%s\n## Mobile preview\n\n<!-- mobile-ci:preview:section:ios-ota:start -->\nold\n<!-- mobile-ci:preview:section:ios-ota:end -->\n' "$MARKER" > "$workspace/fake/comments/120"
: > "$workspace/sections/ios-ota.md"
comment
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_not_contains "$(cat "$workspace/fake/comments/120")" 'ios-ota' 'section removed'; then
    pass_case
fi

case_start 'a quoted marker in a human comment is not taken over'
setup
printf '> %s\nquoted\n' "$MARKER" > "$workspace/fake/comments/110"
printf 'iOS update\n' > "$workspace/sections/ios-ota.md"
comment
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals "$(printf '> %s\nquoted' "$MARKER")" "$(cat "$workspace/fake/comments/110")" 'human comment untouched'; then
    pass_case
fi

case_start 'a marked comment past the first page of comments is found, not duplicated'
setup
printf '%s\n## Mobile preview\n' "$MARKER" > "$workspace/fake/comments/300"
printf 'iOS update\n' > "$workspace/sections/ios-ota.md"
comment FAKE_PAGINATE=1
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_not_contains "$(cat "$workspace/fake/calls")" 'POST' 'no new comment' \
    && assert_equals 'iOS update' "$(section_body 300 ios-ota)" 'section written'; then
    pass_case
fi

case_start 'a concurrent writer that clobbers this section is retried until it holds'
setup
printf '%s\n## Mobile preview\n\n<!-- mobile-ci:preview:section:android-dev-build:start -->\nnative apk\n<!-- mobile-ci:preview:section:android-dev-build:end -->\n' "$MARKER" > "$workspace/fake/comments/120"
cp "$workspace/fake/comments/120" "$workspace/fake/stale"
echo 2 > "$workspace/fake/clobbers"
printf 'iOS update\n' > "$workspace/sections/ios-ota.md"
comment
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals 3 "$(grep -c '^PATCH' "$workspace/fake/calls")" 'patch attempts' \
    && assert_equals 'iOS update' "$(section_body 120 ios-ota)" 'section finally written'; then
    pass_case
fi

case_start 'a writer clobbered on every attempt fails closed'
setup
printf '%s\n## Mobile preview\n' "$MARKER" > "$workspace/fake/comments/120"
cp "$workspace/fake/comments/120" "$workspace/fake/stale"
echo 99 > "$workspace/fake/clobbers"
printf 'iOS update\n' > "$workspace/sections/ios-ota.md"
comment MAX_ATTEMPTS='2'
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'after 2 attempt' 'error'; then
    pass_case
fi

case_start 'two writers creating at once converge on the older comment'
setup
printf 'android update\n' > "$workspace/sections/android-ota.md"
comment FAKE_RACE_CREATE=1
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_equals '150' "$(find "$workspace/fake/comments" -type f -exec basename {} \;)" 'only the older comment remains' \
    && assert_equals 'other writer' "$(section_body 150 ios-ota)" 'other section kept' \
    && assert_equals 'android update' "$(section_body 150 android-ota)" 'own section merged'; then
    pass_case
fi

case_start 'an unchanged comment is not edited'
setup
printf 'iOS update\n' > "$workspace/sections/ios-ota.md"
comment
: > "$workspace/fake/calls"
comment
if assert_equals 0 "$STEP_STATUS" "step status ($(cat "$workspace/log"))" \
    && assert_not_contains "$(cat "$workspace/fake/calls")" 'PATCH' 'no edit'; then
    pass_case
fi

case_start 'a refused edit fails closed naming the permission'
setup
printf '%s\n## Mobile preview\n' "$MARKER" > "$workspace/fake/comments/120"
printf 'iOS update\n' > "$workspace/sections/ios-ota.md"
comment FAKE_PATCH_STATUS=403
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_contains "$(cat "$workspace/log")" 'pull-requests: write' 'error'; then
    pass_case
fi

case_start 'an unreadable comment list fails closed without creating a comment'
setup
printf 'iOS update\n' > "$workspace/sections/ios-ota.md"
comment FAKE_LIST_STATUS=500
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_equals 0 "$(find "$workspace/fake/comments" -type f | wc -l | tr -d ' ')" 'no comment'; then
    pass_case
fi

case_start 'a section name outside [A-Za-z0-9._-] fails closed'
setup
printf 'x\n' > "$workspace/sections/bad name.md"
comment
if assert_equals 1 "$STEP_STATUS" 'step status' \
    && assert_equals '' "$(cat "$workspace/fake/calls")" 'no API call'; then
    pass_case
fi

case_start 'no section file fails closed'
setup
comment
if assert_equals 1 "$STEP_STATUS" 'step status'; then
    pass_case
fi

finish_suite
