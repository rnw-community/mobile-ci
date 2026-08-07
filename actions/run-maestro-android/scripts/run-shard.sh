#!/usr/bin/env bash
# Invoked as a single `script:` line by reactivecircus/android-emulator-runner
# (see the "Boot emulator, install app, and run Maestro shard" step in
# ../action.yml for why this lives in its own file). All inputs arrive as
# environment variables set on that step, inherited through to here.
set -euo pipefail

adb wait-for-device
timeout 180 bash -c 'until [ "$(adb shell getprop sys.boot_completed | tr -d "\r")" = "1" ]; do sleep 2; done'
adb install -r "$APK_PATH"

case "$SHARD_COUNT" in
  ''|*[!0-9]*)
    echo "::error::shard-count '$SHARD_COUNT' must be a non-negative integer."
    exit 1
    ;;
esac
if [ "$SHARD_COUNT" -lt 1 ]; then
  echo "::error::shard-count must be >= 1, got $SHARD_COUNT."
  exit 1
fi
case "$SHARD_INDEX" in
  ''|*[!0-9]*)
    echo "::error::shard-index '$SHARD_INDEX' must be a non-negative integer."
    exit 1
    ;;
esac
if [ "$SHARD_INDEX" -ge "$SHARD_COUNT" ]; then
  echo "::error::shard-index $SHARD_INDEX is out of range [0, $SHARD_COUNT)."
  exit 1
fi
case "$FLOW_RETRIES" in
  ''|*[!0-9]*)
    echo "::error::flow-retries '$FLOW_RETRIES' must be a non-negative integer."
    exit 1
    ;;
esac
max_attempts=$((1 + FLOW_RETRIES))

if [ -n "$PRE_RUN_FLOW" ]; then
  test -f "$PRE_RUN_FLOW" || { echo "::error::pre-run-flow '$PRE_RUN_FLOW' is not a file."; exit 1; }
fi

summary_rows=()

run_flow_with_retries() {
  local flow="$1" label="$2" attempts=0 status=failed start end duration
  start=$(date +%s)
  while [ "$attempts" -lt "$max_attempts" ]; do
    attempts=$((attempts + 1))
    if maestro test -e "APP_ID=$APP_ID" "$flow"; then
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
    printf '%s\n' "${summary_rows[@]}"
  } >> "$GITHUB_STEP_SUMMARY"
}

flows=()
# Only top-level files matching flows-name-pattern are runnable scenarios.
# Recursing over every flow file sweeps in reusable subflows and
# capture-only flows conventionally kept in subdirectories of the flows
# dir; those expect a caller to pass env or leave the app mid-journey, so
# running them standalone fails.
while IFS= read -r flow; do
  flows+=("$flow")
done < <(find "$FLOWS_DIR" -maxdepth 1 -type f -name "$FLOWS_NAME_PATTERN" | sort)
if [ "${#flows[@]}" -eq 0 ]; then
  echo "::error::No flows matching '$FLOWS_NAME_PATTERN' found directly inside flows-dir '$FLOWS_DIR'."
  exit 1
fi
selected=()
for index in "${!flows[@]}"; do
  if (( index % SHARD_COUNT == SHARD_INDEX )); then
    selected+=("${flows[$index]}")
  fi
done

if [ -n "$PRE_RUN_FLOW" ]; then
  if ! run_flow_with_retries "$PRE_RUN_FLOW" "$(basename "$PRE_RUN_FLOW") (priming)"; then
    write_summary
    echo "::error::Priming flow '$PRE_RUN_FLOW' failed; aborting shard $SHARD_INDEX."
    exit 1
  fi
fi

if [ "${#selected[@]}" -eq 0 ]; then
  echo "Shard $SHARD_INDEX has no flows; nothing to run."
  if [ "${#summary_rows[@]}" -gt 0 ]; then
    write_summary
  fi
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
