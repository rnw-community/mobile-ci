#!/usr/bin/env bash
# Invoked as a single `script:` line by reactivecircus/android-emulator-runner
# (see the "Boot emulator, install app, and run Maestro shard" step in
# ../action.yml for why this lives in its own file). All inputs arrive as
# environment variables set on that step, inherited through to here.
set -euo pipefail

# A shard-private scratch directory passed to every `maestro test`
# invocation's --debug-output below, rather than relying on Maestro's
# shared, unscoped ~/.maestro/tests default: two shards (this repo's own
# concurrent matrix cells, or a different workflow entirely) can share one
# self-hosted runner's $HOME, and a directory selected by "created since a
# timestamp marker" can't tell this shard's debug output apart from a
# sibling's landing in the same window. A path derived from
# shard-index/run-id/attempt can never collide with another shard's.
maestro_debug_scratch_dir="$RUNNER_TEMP/maestro-debug-${SHARD_INDEX}-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
mkdir -p "$maestro_debug_scratch_dir"
echo "MAESTRO_DEBUG_SCRATCH_DIR=$maestro_debug_scratch_dir" >> "$GITHUB_ENV"

adb wait-for-device
timeout 180 bash -c 'until [ "$(adb shell getprop sys.boot_completed | tr -d "\r")" = "1" ]; do sleep 2; done'
ANDROID_SERIAL=$(adb devices | awk '$2 == "device" { print $1; exit }')
export ANDROID_SERIAL
adb install -r "$APK_PATH"

if [ -n "${PRE_TEST_COMMAND:-}" ]; then
  eval "$PRE_TEST_COMMAND"
fi

case "$SHARD_COUNT" in
  ''|*[!0-9]*|0[0-9]*)
    echo "::error::shard-count '$SHARD_COUNT' must be a non-negative integer without leading zeros."
    exit 1
    ;;
esac
if [ "$SHARD_COUNT" -lt 1 ]; then
  echo "::error::shard-count must be >= 1, got $SHARD_COUNT."
  exit 1
fi
case "$SHARD_INDEX" in
  ''|*[!0-9]*|0[0-9]*)
    echo "::error::shard-index '$SHARD_INDEX' must be a non-negative integer without leading zeros."
    exit 1
    ;;
esac
if [ "$SHARD_INDEX" -ge "$SHARD_COUNT" ]; then
  echo "::error::shard-index $SHARD_INDEX is out of range [0, $SHARD_COUNT)."
  exit 1
fi
case "$FLOW_RETRIES" in
  ''|*[!0-9]*|0[0-9]*)
    echo "::error::flow-retries '$FLOW_RETRIES' must be a non-negative integer without leading zeros."
    exit 1
    ;;
esac
max_attempts=$((1 + FLOW_RETRIES))
case "$FLOWS_MAX_DEPTH" in
  ''|*[!0-9]*|0[0-9]*)
    echo "::error::flows-max-depth '$FLOWS_MAX_DEPTH' must be a non-negative integer without leading zeros."
    exit 1
    ;;
esac

if [ -n "$PRE_RUN_FLOW" ]; then
  test -f "$PRE_RUN_FLOW" || { echo "::error::pre-run-flow '$PRE_RUN_FLOW' is not a file."; exit 1; }
fi

maestro_env_args=()
if [ -n "${MAESTRO_ENV:-}" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      *=*) ;;
      *)
        echo "::error::maestro-env line '$line' is missing '='; expected KEY=VALUE."
        exit 1
        ;;
    esac
    name="${line%%=*}"
    case "$name" in
      ''|[!A-Za-z_]*)
        echo "::error::maestro-env variable name '$name' must match ^[A-Za-z_][A-Za-z0-9_]*\$."
        exit 1
        ;;
    esac
    case "$name" in
      *[!A-Za-z0-9_]*)
        echo "::error::maestro-env variable name '$name' must match ^[A-Za-z_][A-Za-z0-9_]*\$."
        exit 1
        ;;
    esac
    maestro_env_args+=(-e "$line")
  done <<< "$MAESTRO_ENV"
fi

summary_rows=()

run_flow_with_retries() {
  local flow="$1" label="$2" attempts=0 status=failed start end duration
  start=$(date +%s)
  while [ "$attempts" -lt "$max_attempts" ]; do
    attempts=$((attempts + 1))
    if maestro test -e "APP_ID=$APP_ID" --debug-output "$maestro_debug_scratch_dir" ${maestro_env_args[@]+"${maestro_env_args[@]}"} "$flow"; then
      status=passed
      break
    fi
  done
  end=$(date +%s)
  duration=$((end - start))
  summary_rows+=("| $label | ${duration}s | $status | $attempts |")
  [ "$status" = "passed" ]
}

write_summary() {
  {
    echo "### Maestro flow timing (shard $SHARD_INDEX)"
    echo "| Flow | Duration | Status | Attempts |"
    echo "| --- | --- | --- | --- |"
    printf '%s\n' "${summary_rows[@]:-}"
  } >> "$GITHUB_STEP_SUMMARY"
}

# Only files matching flows-name-pattern within flows-max-depth are runnable
# scenarios. The default (max-depth 1) keeps reusable subflows and
# capture-only flows conventionally kept in subdirectories of the flows dir
# out of the shard; those expect a caller to pass env or leave the app
# mid-journey, so running them standalone fails.
find_cmd=(find "$FLOWS_DIR")
if [ "$FLOWS_MAX_DEPTH" != '0' ]; then
  find_cmd+=(-maxdepth "$FLOWS_MAX_DEPTH")
fi
find_cmd+=(-type f)
IFS=' ' read -r -a name_patterns <<< "$FLOWS_NAME_PATTERN"
name_args=('(')
for i in "${!name_patterns[@]}"; do
  if [ "$i" -gt 0 ]; then
    name_args+=(-o)
  fi
  name_args+=(-name "${name_patterns[$i]}")
done
name_args+=(')')
find_cmd+=("${name_args[@]}")
if [ -n "$FLOWS_EXCLUDE_PATTERN" ]; then
  find_cmd+=(! -name "$FLOWS_EXCLUDE_PATTERN")
fi
flows=()
while IFS= read -r flow; do
  flows+=("$flow")
done < <("${find_cmd[@]}" | sort)
if [ "${#flows[@]}" -eq 0 ]; then
  echo "::error::No flows matching '$FLOWS_NAME_PATTERN' found under flows-dir '$FLOWS_DIR' (flows-max-depth=$FLOWS_MAX_DEPTH)."
  exit 1
fi
printf 'Resolved flow list (%s total):\n%s\n' "${#flows[@]}" "${flows[*]}"

# pre-run-flow is run once as a priming flow below, outside of sharding. If
# it also happens to be a top-level file inside flows-dir matching
# flows-name-pattern, discovery above finds it too, and without this filter
# it would be selected again by the manifest or modulo split and run a
# second time. Compare with -ef (same-inode test) since PRE_RUN_FLOW and the
# discovered flow's path string may differ in form (relative vs
# "./"-prefixed, etc.) while resolving to the same file; -ef is
# POSIX-available in bash's test on both macOS and Linux, unlike GNU-only
# realpath -m.
if [ -n "$PRE_RUN_FLOW" ]; then
  remaining_flows=()
  for flow in "${flows[@]}"; do
    if [ ! "$flow" -ef "$PRE_RUN_FLOW" ]; then
      remaining_flows+=("$flow")
    fi
  done
  flows=(${remaining_flows[@]+"${remaining_flows[@]}"})
fi

selected=()
if [ -n "$SHARD_MANIFEST_DIR" ]; then
  manifest_file="$SHARD_MANIFEST_DIR/shard-$SHARD_INDEX.txt"
  if [ ! -f "$manifest_file" ]; then
    echo "::error::shard-manifest-dir '$SHARD_MANIFEST_DIR' is set but '$manifest_file' is missing for shard-index $SHARD_INDEX."
    exit 1
  fi
  while IFS= read -r rel || [ -n "$rel" ]; do
    rel="${rel%$'\r'}"
    rel="${rel#./}"
    [ -n "$rel" ] || continue
    flow_path="$FLOWS_DIR/$rel"
    match=0
    for candidate in ${flows[@]+"${flows[@]}"}; do
      if [ "$candidate" = "$flow_path" ]; then
        match=1
        break
      fi
    done
    if [ "$match" -ne 1 ]; then
      echo "::error::shard-manifest entry '$rel' (resolved '$flow_path') is not among the flows discovered under '$FLOWS_DIR' (flows-max-depth=$FLOWS_MAX_DEPTH, flows-name-pattern='$FLOWS_NAME_PATTERN'); refusing an entry that bypasses discovery."
      exit 1
    fi
    selected+=("$flow_path")
  done < "$manifest_file"
else
  for index in "${!flows[@]}"; do
    if (( index % SHARD_COUNT == SHARD_INDEX )); then
      selected+=("${flows[$index]}")
    fi
  done
fi

if [ -n "$PRE_RUN_FLOW" ]; then
  if ! run_flow_with_retries "$PRE_RUN_FLOW" "$(basename "$PRE_RUN_FLOW") (priming)"; then
    write_summary
    echo "::error::Priming flow '$PRE_RUN_FLOW' failed; aborting shard $SHARD_INDEX."
    exit 1
  fi
fi

if [ "${#selected[@]}" -eq 0 ]; then
  echo "Shard $SHARD_INDEX has no flows; nothing to run."
  write_summary
  exit 0
fi
printf 'Shard %s flows:\n%s\n' "$SHARD_INDEX" "${selected[*]}"

overall_status=0
for flow in "${selected[@]}"; do
  if ! run_flow_with_retries "$flow" "$(basename "$flow")"; then
    overall_status=1
  fi
done

write_summary
exit "$overall_status"
