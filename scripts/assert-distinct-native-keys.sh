#!/usr/bin/env bash
# Fails when two targets of one platform with different appId resolve to the
# same native key. Usage: assert-distinct-native-keys.sh <platform> <plans-json>
# <plans-json> is a JSON array of {name, appId, nativeKey, appDir?, fingerprint?,
# configHash?}. Same appId sharing a key is a legitimate dedupe and passes.
set -euo pipefail

platform="${1:?platform}"
plans="${2:?plans json}"

if ! jq -e 'type == "array"' >/dev/null 2>&1 <<< "$plans"; then
  echo "::error::The plans for the distinct-key check are not a JSON array."
  exit 1
fi

malformed=$(jq -r '[to_entries[] | select((.value.name // "") == "" or (.value.nativeKey // "") == "") | .key] | join(", ")' <<< "$plans")
if [ -n "$malformed" ]; then
  echo "::error::Plan entries at index $malformed have no name or no nativeKey; a target without a key cannot be proven distinct."
  exit 1
fi

collisions=$(jq -r --arg platform "$platform" '
  group_by(.nativeKey)
  | map(select((map(.appId // "") | unique | length) > 1))
  | .[]
  | "\($platform) targets " + (map("\(.name) (appId \(.appId // "unset"), appDir \(.appDir // "."))") | join(" and "))
    + " resolve to the same native key " + .[0].nativeKey
    + ". Shared fingerprint sources: fingerprint " + (map(.fingerprint // "unknown") | unique | join("/"))
    + ", fingerprint config hash " + (map(.configHash // "unknown") | unique | join("/"))
    + ", appDir " + (map(.appDir // ".") | unique | join("/")) + "."
' <<< "$plans")

if [ -n "$collisions" ]; then
  while IFS= read -r line; do
    echo "::error::$line Their native config differs in something the fingerprint does not see, so they would share one base binary and one would ship the wrong bundle id. Add that file to extraSources in fingerprint.config.js (see docs/repack.md, 'Targets that differ only in brand assets or per-target config')."
  done <<< "$collisions"
  exit 1
fi

echo "All $(jq 'length' <<< "$plans") $platform targets have distinct native keys, or share a key only with the same appId."
