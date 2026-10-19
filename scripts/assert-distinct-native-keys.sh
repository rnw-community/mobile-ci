#!/usr/bin/env bash
# Fails when two targets of one platform with different appId resolve to the
# same native key. Usage: assert-distinct-native-keys.sh <platform> <plans-json> [require-app-id]
# <plans-json> is a JSON array of {name, appId, nativeKey, appDir?, fingerprint?,
# configHash?}. Same appId sharing a key is a legitimate dedupe and passes.
# require-app-id (default true) makes appId mandatory. With false, targets that
# all omit appId (seed-native-cache's target shape) skip the comparison; a mix
# of targets with and without appId still fails.
set -euo pipefail

platform="${1:?platform}"
plans="${2:?plans json}"
require_app_id="${3:-true}"

case "$require_app_id" in
  true|false) ;;
  *)
    echo "::error::require-app-id must be 'true' or 'false', got '$require_app_id'."
    exit 1
    ;;
esac

if ! jq -e 'type == "array"' >/dev/null 2>&1 <<< "$plans"; then
  echo "::error::The plans for the distinct-key check are not a JSON array."
  exit 1
fi

if [ "$require_app_id" = false ]; then
  unkeyed=$(jq -r '[to_entries[] | select((.value.name // "") == "" or (.value.nativeKey // "") == "") | .key] | join(", ")' <<< "$plans")
  if [ -n "$unkeyed" ]; then
    echo "::error::Plan entries at index $unkeyed have no name or nativeKey."
    exit 1
  fi
  with_app_id=$(jq '[.[] | select((.appId // "") != "")] | length' <<< "$plans")
  if [ "$with_app_id" -eq 0 ]; then
    echo "::notice::No $platform target declares an appId, so there is no appId to prove distinct; skipped the shared-key comparison. The callers that consume these bases (ios-maestro, android-maestro, store-screenshots) run it with their appIds."
    exit 0
  fi
fi

malformed=$(jq -r '[to_entries[] | select((.value.name // "") == "" or (.value.appId // "") == "" or (.value.nativeKey // "") == "") | .key] | join(", ")' <<< "$plans")
if [ -n "$malformed" ]; then
  echo "::error::Plan entries at index $malformed have no name, appId or nativeKey; a target without an appId or key cannot be proven distinct."
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
