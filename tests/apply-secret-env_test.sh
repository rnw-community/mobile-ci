#!/usr/bin/env bash
# A secret's KEY=VALUE entries are masked, exported and digested by one step
# every reusable workflow shares. What must hold: every value is masked before
# anything else can print it, nothing about a malformed entry is echoed, no
# value can break out of its $GITHUB_ENV entry, the digest moves with a value
# and reveals none, and an empty secret changes nothing.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/apply-secret-env/action.yml"
STEP='Parse, mask and export the secret entries'

apply() {
    local dir="$1" secret="$2"
    shift 2
    run_step "$dir" \
        SECRET_ENV="$secret" \
        SECRET_LABEL=build-secrets-env \
        EXPORT_ENV=true \
        ALLOW_MULTILINE=true \
        APPEND_TO='' \
        "$@"
}

# env_value <workspace> <name> — the value $GITHUB_ENV ends up holding for name,
# parsed the way the runner parses the file.
env_value() {
    local dir="$1" key="$2"
    ENV_FILE="$dir/env" ENV_KEY="$key" python3 - <<'PYTHON'
import os

lines = open(os.environ['ENV_FILE'], encoding='utf-8').read().split('\n')
key = os.environ['ENV_KEY']
values = {}
index = 0
while index < len(lines):
    line = lines[index]
    if '<<' in line and ('=' not in line or line.index('<<') < line.index('=')):
        name, delimiter = line.split('<<', 1)
        collected = []
        index += 1
        while lines[index] != delimiter:
            collected.append(lines[index])
            index += 1
        values[name] = '\n'.join(collected)
    elif '=' in line:
        name, value = line.split('=', 1)
        values[name] = value
    index += 1
print(values.get(key, '<unset>'), end='')
PYTHON
}

case_start 'an empty secret is a no-op'
dir="$(new_workspace "$ACTION" "$STEP")"
apply "$dir" ''
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals '' "$(cat "$dir/env")" 'GITHUB_ENV file' \
    && assert_equals '' "$(step_output "$dir" digest)" 'digest' \
    && assert_equals '0' "$(step_output "$dir" count)" 'count' \
    && assert_not_contains "$(cat "$dir/log")" '::add-mask::' 'log' \
    && pass_case

case_start 'every value is masked and exported'
dir="$(new_workspace "$ACTION" "$STEP")"
apply "$dir" $'TURBO_TOKEN=tok-123\n\nMAPS_KEY=AIza=with=equals\nEMPTY='
log="$(cat "$dir/log")"
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_contains "$log" '::add-mask::tok-123' 'mask of TURBO_TOKEN' \
    && assert_contains "$log" '::add-mask::AIza=with=equals' 'mask of MAPS_KEY' \
    && assert_not_contains "$log" '::add-mask::'$'\n' 'empty value is not masked' \
    && assert_equals 'tok-123' "$(env_value "$dir" TURBO_TOKEN)" 'TURBO_TOKEN' \
    && assert_equals 'AIza=with=equals' "$(env_value "$dir" MAPS_KEY)" 'MAPS_KEY' \
    && assert_equals '' "$(env_value "$dir" EMPTY)" 'EMPTY' \
    && assert_equals '3' "$(step_output "$dir" count)" 'count' \
    && assert_equals $'TURBO_TOKEN\nMAPS_KEY\nEMPTY' "$(step_output "$dir" names)" 'names' \
    && pass_case

case_start 'a value that is itself a GITHUB_ENV heredoc cannot inject a second variable'
dir="$(new_workspace "$ACTION" "$STEP")"
apply "$dir" $'SAFE<<EOF\nfirst\nEOF\nINJECTED=evil\nEOF'
assert_equals 1 "$STEP_STATUS" 'a dangling delimiter line is not KEY=VALUE' \
    && assert_not_contains "$(cat "$dir/env")" 'INJECTED' 'GITHUB_ENV file' \
    && pass_case

case_start 'a value that looks like a heredoc header stays one value'
dir="$(new_workspace "$ACTION" "$STEP")"
apply "$dir" $'A=B<<EOF\nC=d'
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals 'B<<EOF' "$(env_value "$dir" A)" 'A' \
    && assert_equals 'd' "$(env_value "$dir" C)" 'C' \
    && pass_case

case_start 'a multi-line value is exported intact and every line is masked'
dir="$(new_workspace "$ACTION" "$STEP")"
apply "$dir" $'PEM<<END\n-----BEGIN KEY-----\nc2VjcmV0\n-----END KEY-----\nEND\nNEXT=1'
log="$(cat "$dir/log")"
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals $'-----BEGIN KEY-----\nc2VjcmV0\n-----END KEY-----' "$(env_value "$dir" PEM)" 'PEM' \
    && assert_equals '1' "$(env_value "$dir" NEXT)" 'NEXT' \
    && assert_contains "$log" '::add-mask::c2VjcmV0' 'middle line mask' \
    && assert_contains "$log" '::add-mask::-----END KEY-----' 'last line mask' \
    && pass_case

case_start 'a multi-line value is refused where values must fit on one line'
dir="$(new_workspace "$ACTION" "$STEP")"
apply "$dir" $'PEM<<END\nline\nEND' ALLOW_MULTILINE=false
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" 'multi-line value' 'error' \
    && assert_equals '' "$(cat "$dir/env")" 'GITHUB_ENV file' \
    && pass_case

case_start 'an unclosed multi-line value fails closed'
dir="$(new_workspace "$ACTION" "$STEP")"
apply "$dir" $'PEM<<END\nline'
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" 'never closes' 'error' \
    && assert_equals '' "$(cat "$dir/env")" 'GITHUB_ENV file' \
    && pass_case

case_start 'a line without = fails closed without echoing it'
dir="$(new_workspace "$ACTION" "$STEP")"
apply "$dir" $'GOOD=1\nhunter2-not-a-key'
log="$(cat "$dir/log")"
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$log" 'line 2 is missing' 'error names the line number' \
    && assert_not_contains "$log" 'hunter2' 'the line is not echoed' \
    && assert_equals '' "$(cat "$dir/env")" 'nothing is exported before the whole secret parses' \
    && pass_case

case_start 'an invalid variable name fails closed without echoing it'
dir="$(new_workspace "$ACTION" "$STEP")"
apply "$dir" '1BAD-name=hunter2'
log="$(cat "$dir/log")"
assert_equals 1 "$STEP_STATUS" 'exit status' \
    && assert_contains "$log" 'must match' 'error' \
    && assert_not_contains "$log" 'hunter2' 'the value is not echoed' \
    && pass_case

case_start 'a value with % and CR is masked as the runner unescapes it'
dir="$(new_workspace "$ACTION" "$STEP")"
apply "$dir" $'ODD=50%25off\r'
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_contains "$(cat "$dir/log")" '::add-mask::50%2525off%0D' 'escaped mask' \
    && pass_case

case_start 'a short value is warned about by name, since masking it hides that string everywhere'
dir="$(new_workspace "$ACTION" "$STEP")"
apply "$dir" $'FLAG=1\nTOKEN=long-enough-token'
log="$(cat "$dir/log")"
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_contains "$log" "::warning::build-secrets-env entry 'FLAG' has a value shorter than 8 characters" 'warning' \
    && assert_not_contains "$log" "entry 'TOKEN'" 'no warning for a long value' \
    && pass_case

case_start 'the digest moves with a value and never contains one'
dir="$(new_workspace "$ACTION" "$STEP")"
apply "$dir" 'MAPS_KEY=before'
before="$(step_output "$dir" digest)"
dir="$(new_workspace "$ACTION" "$STEP")"
apply "$dir" 'MAPS_KEY=before'
again="$(step_output "$dir" digest)"
dir="$(new_workspace "$ACTION" "$STEP")"
apply "$dir" 'MAPS_KEY=rotated'
after="$(step_output "$dir" digest)"
if ! printf '%s' "$before" | grep -qE '^[0-9a-f]{64}$'; then
    fail_case "digest '$before' is not a SHA-256"
elif [ "$before" != "$again" ]; then
    fail_case "the same secret digested to '$before' and '$again', so a warm-up and a pull request never agree on a key"
elif [ "$before" = "$after" ]; then
    fail_case 'rotating MAPS_KEY left the digest unchanged, so a base compiled with the old key stays reachable'
else
    pass_case
fi

case_start 'export false leaves GITHUB_ENV alone and lines merges after append-to'
dir="$(new_workspace "$ACTION" "$STEP")"
apply "$dir" $'PASSWORD=s3cret' EXPORT_ENV=false ALLOW_MULTILINE=false APPEND_TO=$'USER=demo\nURL=https://x\n'
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals '' "$(cat "$dir/env")" 'GITHUB_ENV file' \
    && assert_equals $'USER=demo\nURL=https://x\nPASSWORD=s3cret' "$(step_output "$dir" lines)" 'lines' \
    && pass_case

case_start 'with no entries lines is append-to unchanged'
dir="$(new_workspace "$ACTION" "$STEP")"
apply "$dir" '' ALLOW_MULTILINE=false APPEND_TO=$'USER=demo\n'
assert_equals 0 "$STEP_STATUS" 'exit status' \
    && assert_equals $'USER=demo\n.' "$(step_output "$dir" lines; printf .)" 'lines' \
    && pass_case

finish_suite
