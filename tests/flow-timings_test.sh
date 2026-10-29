#!/usr/bin/env bash
# scripts/maestro/flow-timings.py (#267): balance must give every shard a
# disjoint, complete and deterministic share; merge must fold only passed
# flows into the timings as an exponentially weighted average.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

SCRIPT="$REPO_ROOT/scripts/maestro/flow-timings.py"
work="$(new_empty_workspace)"

balance() {
    python3 -I "$SCRIPT" balance --flows-dir flows "$@" 2> "$work/stderr"
}
flows() {
    printf 'flows/%s.flow.yaml\n' "$@"
}

case_start 'the shards of a balance are disjoint, complete and identical on every call'
printf '{"version": 1, "flows": {"a.flow.yaml": 50, "b.flow.yaml": 40, "c.flow.yaml": 30, "d.flow.yaml": 30, "e.flow.yaml": 20}}\n' > "$work/t.json"
all=''
for index in 0 1 2; do
    all="$all$(flows a b c d e f | balance --count 3 --index "$index" --timings "$work/t.json")"$'\n'
done
again="$(flows a b c d e f | balance --count 3 --index 1 --timings "$work/t.json")"
if assert_equals "$(flows a b c d e f)" "$(sort <<< "${all%$'\n'}")" 'union of the shards' \
    && assert_equals "$(flows b f)" "$again" 'shard 1 (b 40 + f at the median 30)'; then
    pass_case
fi

case_start 'no timings file is the index-modulo split'
if assert_equals "$(flows b d)" "$(flows a b c d | balance --count 2 --index 1)" 'shard 1'; then
    pass_case
fi

case_start 'a timings file with a negative or non-numeric duration is refused'
statuses=''
for body in '{"version": 1, "flows": {"a.flow.yaml": -1}}' '{"version": 1, "flows": {"a.flow.yaml": "9"}}' '{"version": 2, "flows": {}}'; do
    printf '%s\n' "$body" > "$work/bad.json"
    [ "$(flows a b | balance --count 2 --index 1 --timings "$work/bad.json")" = "$(flows b)" ] && grep -q '::warning::' "$work/stderr" && statuses="${statuses}w"
done
assert_equals www "$statuses" 'warned and split by index' && pass_case

case_start 'an out-of-range shard index fails'
if flows a | balance --count 2 --index 2 > /dev/null; then status=0; else status=$?; fi
assert_equals 1 "$status" status && pass_case

case_start 'merge averages passed flows, ignores failed ones and keeps unseen history'
printf '{"version": 1, "flows": {"a.flow.yaml": 100, "z.flow.yaml": 7}}\n' > "$work/prev.json"
printf 'a.flow.yaml\t200\tpassed\nb.flow.yaml\t30\tpassed\nc.flow.yaml\t999\tfailed\n' > "$work/s0.tsv"
python3 -I "$SCRIPT" merge --previous "$work/prev.json" --output "$work/out.json" "$work/s0.tsv" > /dev/null
merged="$(python3 -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))["flows"], sort_keys=True))' "$work/out.json")"
assert_equals '{"a.flow.yaml": 130.0, "b.flow.yaml": 30.0, "z.flow.yaml": 7}' "$merged" 'merged timings' && pass_case

case_start 'merge without previous timings starts from the records'
python3 -I "$SCRIPT" merge --previous "$work/missing.json" --output "$work/out.json" "$work/s0.tsv" > /dev/null
assert_contains "$(cat "$work/out.json")" '"b.flow.yaml": 30.0' 'merged timings' && pass_case

case_start 'merge fails on a malformed record'
printf 'a.flow.yaml\tslow\tpassed\n' > "$work/bad.tsv"
if python3 -I "$SCRIPT" merge --output "$work/out.json" "$work/bad.tsv" > "$work/log" 2>&1; then status=0; else status=$?; fi
if assert_equals 1 "$status" status && assert_contains "$(cat "$work/log")" 'bad.tsv:1' 'log'; then pass_case; fi

finish_suite
