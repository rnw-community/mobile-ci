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
# Maestro nests every `maestro test` process's output under
# .maestro/tests/<timestamp>/, keyed by invocation time and never by flow, so
# the only way to tell a failing flow's output apart from a passing one's is
# to diff the scratch dir's entries around each flow's attempt sequence. The
# manifest written below (final_status TAB flow TAB entry, one line per entry
# a flow's attempts and its recovery-flow runs produced) is what lets the
# capture step in ../action.yml stage only the failing flows' output instead
# of weighing the whole shard's output against the artifact cap.
maestro_debug_manifest_file="$maestro_debug_scratch_dir.manifest.tsv"
maestro_debug_units_before_file="$maestro_debug_manifest_file.before"
: > "$maestro_debug_manifest_file"
echo "MAESTRO_DEBUG_MANIFEST_FILE=$maestro_debug_manifest_file" >> "$GITHUB_ENV"

adb wait-for-device
# shellcheck disable=SC2016 # single quotes are deliberate: the child bash expands this, not the parent
timeout 180 bash -c 'until [ "$(adb shell getprop sys.boot_completed | tr -d "\r")" = "1" ]; do sleep 2; done'
ANDROID_SERIAL=$(adb devices | awk '$2 == "device" { print $1; exit }')
export ANDROID_SERIAL
adb install -r "$APK_PATH"

# Warm the app once between install and the first flow (pre-run-flow
# included) so first-launch cold-start cost (JS bundle load, cache priming)
# is not absorbed by the first flow's own timeout budget.
case "$APP_WARM_SECONDS" in
  ''|*[!0-9]*|0[0-9]*)
    echo "::error::app-warm-seconds '$APP_WARM_SECONDS' must be a non-negative integer without leading zeros."
    exit 1
    ;;
esac
if [ "$APP_WARM_SECONDS" != "0" ]; then
  echo "Warming '$APP_ID': launch, settle ${APP_WARM_SECONDS}s, force-stop."
  if ! adb shell monkey -p "$APP_ID" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; then
    echo "::warning::Warm-up launch of '$APP_ID' reported a non-zero status; continuing (warming is best-effort)."
  fi
  sleep "$APP_WARM_SECONDS"
  adb shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
fi

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
case "$INFRA_RETRIES" in
  ''|*[!0-9]*|0[0-9]*)
    echo "::error::infra-retries '$INFRA_RETRIES' must be a non-negative integer without leading zeros."
    exit 1
    ;;
esac
case "$SETTLE_BEFORE_FLOW" in
  true|false) ;;
  *)
    echo "::error::settle-before-flow '$SETTLE_BEFORE_FLOW' must be 'true' or 'false'."
    exit 1
    ;;
esac
case "$FLOWS_MAX_DEPTH" in
  ''|*[!0-9]*|0[0-9]*)
    echo "::error::flows-max-depth '$FLOWS_MAX_DEPTH' must be a non-negative integer without leading zeros."
    exit 1
    ;;
esac

if [ -n "$PRE_RUN_FLOW" ]; then
  test -f "$PRE_RUN_FLOW" || { echo "::error::pre-run-flow '$PRE_RUN_FLOW' is not a file."; exit 1; }
fi

if [ -n "$FLOW_RECOVERY_FLOW" ]; then
  test -f "$FLOW_RECOVERY_FLOW" || { echo "::error::flow-recovery-flow '$FLOW_RECOVERY_FLOW' is not a file."; exit 1; }
fi

maestro_config_args=()
if [ -n "${MAESTRO_CONFIG:-}" ]; then
  test -f "$MAESTRO_CONFIG" || { echo "::error::maestro-config '$MAESTRO_CONFIG' is not a file."; exit 1; }
  case "$MAESTRO_CONFIG" in
    /*) ;;
    *) MAESTRO_CONFIG="$PWD/$MAESTRO_CONFIG" ;;
  esac
  maestro_config_args=(--config "$MAESTRO_CONFIG")
fi

case "$JUNIT_REPORT" in
  true) junit_dir="${ARTIFACTS_DIR:?}/junit" ;;
  false) junit_dir='' ;;
  *)
    echo "::error::junit-report '$JUNIT_REPORT' must be 'true' or 'false'."
    exit 1
    ;;
esac

normalize_tags() {
  printf '%s\n' "$1" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | { grep -v '^$' || true; } | paste -s -d , -
}
included_tags="$(normalize_tags "$INCLUDE_TAGS")"
excluded_tags="$(normalize_tags "$EXCLUDE_TAGS")"
maestro_tag_args=()
if [ -n "$included_tags" ]; then
  maestro_tag_args+=(--include-tags "$included_tags")
fi
if [ -n "$excluded_tags" ]; then
  maestro_tag_args+=(--exclude-tags "$excluded_tags")
fi

junit_report_file() {
  local rel="${1#"$FLOWS_DIR"/}"
  rel="${rel%.yaml}"
  rel="${rel%.yml}"
  printf '%s/%s.xml' "$junit_dir" "${rel//[^A-Za-z0-9._-]/_}"
}

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

flow_env_scratch_dir=''
pre_flow_script=''
flow_env_seq=0
flow_env_args=()
if [ -n "${PRE_FLOW_COMMAND:-}" ]; then
  flow_env_scratch_dir="$(mktemp -d "$RUNNER_TEMP/maestro-flow-env-${SHARD_INDEX}-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-XXXXXX")"
  echo "FLOW_ENV_SCRATCH_DIR=$flow_env_scratch_dir" >> "$GITHUB_ENV"
  # Materialised as a script run by a child bash rather than eval'd in this
  # shell: bash suppresses `set -e` inside a function invoked from an `if`
  # condition, so an eval'd multi-command string would surface only its last
  # command's status and a failed precondition could pass as satisfied.
  pre_flow_script="$flow_env_scratch_dir/pre-flow-command.sh"
  printf '%s\n%s\n' 'set -euo pipefail' "$PRE_FLOW_COMMAND" > "$pre_flow_script"
fi

run_pre_flow_command() {
  local flow="$1" env_file="$2"
  echo "Running pre-flow-command before '$flow'."
  FLOW_PATH="$flow" FLOW_NAME="$(basename "$flow")" MAESTRO_FLOW_ENV_FILE="$env_file" bash "$pre_flow_script"
}

read_flow_env_file() {
  local env_file="$1" label="$2" line name
  flow_env_args=()
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [ -z "$line" ] && continue
    case "$line" in
      '#'*) continue ;;
    esac
    case "$line" in
      *=*) ;;
      *)
        echo "::error::pre-flow-command env line '$line' contributed for '$label' is missing '='; expected KEY=VALUE."
        exit 1
        ;;
    esac
    name="${line%%=*}"
    case "$name" in
      ''|[!A-Za-z_]*)
        echo "::error::pre-flow-command env variable name '$name' contributed for '$label' must match ^[A-Za-z_][A-Za-z0-9_]*\$."
        exit 1
        ;;
    esac
    case "$name" in
      *[!A-Za-z0-9_]*)
        echo "::error::pre-flow-command env variable name '$name' contributed for '$label' must match ^[A-Za-z_][A-Za-z0-9_]*\$."
        exit 1
        ;;
    esac
    flow_env_args+=(-e "$line")
  done < "$env_file"
}

maestro_debug_units() {
  local entry base
  [ -d "$maestro_debug_scratch_dir" ] || return 0
  for entry in "$maestro_debug_scratch_dir"/.maestro/tests/*; do
    [ -e "$entry" ] || continue
    printf '%s\n' ".maestro/tests/$(basename "$entry")"
  done
  for entry in "$maestro_debug_scratch_dir"/* "$maestro_debug_scratch_dir"/.[!.]* "$maestro_debug_scratch_dir"/..?*; do
    [ -e "$entry" ] || continue
    base=$(basename "$entry")
    if [ "$base" != '.maestro' ]; then
      printf '%s\n' "$base"
    fi
  done
  return 0
}

record_maestro_debug_units() {
  local label="$1" status="$2" unit
  maestro_debug_units | while IFS= read -r unit; do
    if ! grep -Fxq -- "$unit" "$maestro_debug_units_before_file"; then
      printf '%s\t%s\t%s\n' "$status" "$label" "$unit" >> "$maestro_debug_manifest_file"
    fi
  done
}

summary_rows=()
recovery_runs=0
recovery_failures=0
infra_retries_total=0

# Issue #192. Maestro's `launchApp: clearState: true` runs `pm clear` (which
# kills the running process) and starts the launcher activity within about a
# second. When that start reaches ActivityManager while it is still processing
# the killed process's death, it takes the `startProcessLocked ... with
# non-zero startSeq` path and never forks the app: the activity record exists,
# no process binds to it, and the flow times out on a blank screen. Stopping
# the app ourselves and waiting for its process to be gone before the attempt
# leaves `pm clear` nothing to kill, so there is no death in flight when
# Maestro launches. `am force-stop` keeps the app's data; clearing it stays
# Maestro's job, so a flow without clearState sees the same storage as before.
settle_app_process() {
  local deadline
  [ "$SETTLE_BEFORE_FLOW" = 'true' ] || return 0
  timeout 30 adb shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
  deadline=$((SECONDS + 5))
  while [ -n "$(timeout 10 adb shell pidof "$APP_ID" 2>/dev/null | tr -d '\r\n ' || true)" ]; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "::warning::'$APP_ID' still has a live process 5s after am force-stop; running the attempt unsettled."
      return 0
    fi
    sleep 0.25
  done
}

device_epoch() {
  local now
  now="$(timeout 10 adb shell date +%s 2>/dev/null | tr -d '\r\n ' || true)"
  case "$now" in
    ''|*[!0-9]*) return 0 ;;
  esac
  printf '%s' "$now"
}

events_evidence_dir="${ARTIFACTS_DIR:-}/logcat-events"

keep_events_evidence() {
  local label="$1" attempt="$2" name
  [ -n "${ARTIFACTS_DIR:-}" ] || return 0
  name="${label//[^A-Za-z0-9._-]/_}"
  mkdir -p "$events_evidence_dir"
  timeout 30 adb logcat -b events -d > "$events_evidence_dir/$name-attempt-$attempt.txt" 2>&1 || true
}

# Succeeds when the events buffer since <epoch> shows the race for APP_ID:
# the am_wtf naming it, or an activity of the app created with neither a
# process start for the app nor that activity's onCreate after it.
startseq_race_since() {
  local since="$1" events
  events="$(timeout 30 adb logcat -b events -d -T "$since.000" 2>/dev/null || true)"
  [ -n "$events" ] || return 1
  printf '%s\n' "$events" | awk -v app="$APP_ID" '
    function fields(line, out) {
      return split(substr(line, index(line, "[") + 1), out, ",")
    }
    index($0, "startProcessLocked processName:" app " with non-zero startSeq") { race = 1 }
    /[ \t](am|wm)_create_activity[ \t]*:/ {
      if (fields($0, f) >= 4 && index(f[4], app "/") == 1) { pending[f[2]] = 1 }
    }
    /[ \t]am_proc_start[ \t]*:/ {
      if (fields($0, f) >= 4 && f[4] == app) { for (t in pending) delete pending[t] }
    }
    /[ \t](am|wm)_on_create_called[ \t]*:/ {
      if (fields($0, f) >= 1) { delete pending[f[1]] }
    }
    END {
      if (race) exit 0
      for (t in pending) exit 0
      exit 1
    }
  '
}

run_flow_recovery() {
  local after="$1"
  [ -n "$FLOW_RECOVERY_FLOW" ] || return 0
  recovery_runs=$((recovery_runs + 1))
  echo "Running recovery flow '$FLOW_RECOVERY_FLOW' after the failed attempt of '$after'."
  if ! maestro test -e "APP_ID=$APP_ID" --debug-output "$maestro_debug_scratch_dir" ${maestro_env_args[@]+"${maestro_env_args[@]}"} ${maestro_config_args[@]+"${maestro_config_args[@]}"} "$FLOW_RECOVERY_FLOW"; then
    recovery_failures=$((recovery_failures + 1))
    echo "::warning::Recovery flow '$FLOW_RECOVERY_FLOW' failed after '$after'; continuing anyway because recovery is best-effort."
  fi
}

emulator_lost=0
device_state=''
emulator_gone() {
  device_state="$(timeout 10 adb get-state 2>/dev/null | tr -d '\r\n ' || true)"
  [ "$device_state" != 'device' ]
}

lost_emulator_error() {
  local log oom_kills cause=''
  for log in "${RUNNER_TEMP:-}"/mobile-ci-emulator-*.log; do
    [ -f "$log" ] || continue
    echo "Last emulator output ($log):"
    tail -n 40 "$log" || true
    cp "$log" "$ARTIFACTS_DIR/" 2>/dev/null || true
  done
  if [ -r "${CGROUP_ROOT:-/sys/fs/cgroup}/memory.events" ]; then
    echo "Job cgroup memory.events: $(tr '\n' ' ' < "${CGROUP_ROOT:-/sys/fs/cgroup}/memory.events")"
    oom_kills="$(awk '$1 == "oom_kill" { print $2 }' "${CGROUP_ROOT:-/sys/fs/cgroup}/memory.events")"
    [ "${oom_kills:-0}" = 0 ] || cause="; the job's cgroup recorded $oom_kills OOM kill(s)"
  fi
  echo "::error::Infrastructure failure: emulator '$ANDROID_SERIAL' is gone (adb get-state: '${device_state:-no answer}'$cause) $1."
}

run_flow_with_retries() {
  local flow="$1" label="$2" recover_after_last_attempt="$3" run_precondition="$4" attempts=0 status=failed start end duration
  local recovery_seconds=0 recovery_start attempt_ok flow_env_file infra_used=0 attempt_epoch retry junit_file=''
  local scenario_args=()
  if [ "$run_precondition" = '1' ]; then
    scenario_args=(${maestro_tag_args[@]+"${maestro_tag_args[@]}"})
    if [ -n "$junit_dir" ]; then
      mkdir -p "$junit_dir"
      junit_file="$(junit_report_file "$flow")"
      scenario_args+=(--format junit --output "$junit_file" --test-suite-name "maestro-android shard $SHARD_INDEX")
    fi
  fi
  start=$(date +%s)
  maestro_debug_units > "$maestro_debug_units_before_file"
  while :; do
    attempts=$((attempts + 1))
    attempt_ok=1
    if [ -n "$junit_file" ]; then
      rm -f "$junit_file"
    fi
    flow_env_args=()
    settle_app_process
    if [ "$run_precondition" = '1' ] && [ -n "$pre_flow_script" ]; then
      flow_env_seq=$((flow_env_seq + 1))
      flow_env_file="$flow_env_scratch_dir/flow-$flow_env_seq.env"
      : > "$flow_env_file"
      if run_pre_flow_command "$flow" "$flow_env_file"; then
        read_flow_env_file "$flow_env_file" "$label"
      else
        attempt_ok=0
        if emulator_gone; then
          emulator_lost=1
        else
          echo "::error::pre-flow-command failed before attempt $attempts of '$label'; failing the attempt without running the flow."
        fi
      fi
    fi
    attempt_epoch="$(device_epoch)"
    if [ "$attempt_ok" = '1' ] && maestro test -e "APP_ID=$APP_ID" --debug-output "$maestro_debug_scratch_dir" ${maestro_env_args[@]+"${maestro_env_args[@]}"} ${flow_env_args[@]+"${flow_env_args[@]}"} ${maestro_config_args[@]+"${maestro_config_args[@]}"} ${scenario_args[@]+"${scenario_args[@]}"} "$flow"; then
      status=passed
      break
    fi
    if [ "$emulator_lost" = '1' ] || emulator_gone; then
      emulator_lost=1
      break
    fi
    keep_events_evidence "$label" "$attempts"
    retry=0
    if [ "$attempt_ok" = '1' ]; then
      if [ -z "$attempt_epoch" ]; then
        echo "::warning::Could not read the device clock before attempt $attempts of '$label'; its failure is not checked for ActivityManager's startSeq race and counts as a flow failure."
      elif startseq_race_since "$attempt_epoch"; then
        if [ "$infra_used" -lt "$INFRA_RETRIES" ]; then
          infra_used=$((infra_used + 1))
          infra_retries_total=$((infra_retries_total + 1))
          retry=1
          echo "::warning::Attempt $attempts of '$label' hit ActivityManager's 'startProcessLocked ... with non-zero startSeq' race: '$APP_ID' was launched while its previous process's death was still being processed, so no process was started and the screen stayed blank. This is an emulator/infrastructure race, not an app failure; retrying on infra-retries ($infra_used of $INFRA_RETRIES)."
        else
          echo "::warning::Attempt $attempts of '$label' hit ActivityManager's 'startProcessLocked ... with non-zero startSeq' race (no '$APP_ID' process was started; not an app failure), but its infra-retries budget of $INFRA_RETRIES is spent."
        fi
      fi
    fi
    if [ "$retry" = '0' ] && [ $((attempts - infra_used)) -lt "$max_attempts" ]; then
      retry=1
    fi
    if [ "$retry" = '1' ] || [ "$recover_after_last_attempt" = '1' ]; then
      recovery_start=$(date +%s)
      run_flow_recovery "$label"
      recovery_seconds=$((recovery_seconds + $(date +%s) - recovery_start))
    fi
    [ "$retry" = '1' ] || break
  done
  if [ -n "$junit_file" ] && [ "$status" = failed ] && [ ! -f "$junit_file" ]; then
    bash "$MAESTRO_SCRIPTS_DIR/junit-failure.sh" "$junit_file" "maestro-android shard $SHARD_INDEX" "$label" "Failed after $attempts attempt(s) without a Maestro report; see the step log."
  fi
  end=$(date +%s)
  duration=$((end - start - recovery_seconds))
  record_maestro_debug_units "$label" "$status"
  summary_rows+=("| $label | ${duration}s | $status | $attempts | $infra_used |")
  [ "$status" = "passed" ]
}

write_summary() {
  {
    echo "### Maestro flow timing (shard $SHARD_INDEX)"
    echo "| Flow | Duration | Status | Attempts | Infra retries |"
    echo "| --- | --- | --- | --- | --- |"
    printf '%s\n' "${summary_rows[@]:-}"
    if [ "$infra_retries_total" -gt 0 ]; then
      echo ""
      echo "$infra_retries_total attempt(s) were retried on infra-retries after ActivityManager's startSeq race left no app process; see the warnings and logcat-events/ in the artifact."
    fi
    if [ -n "$FLOW_RECOVERY_FLOW" ]; then
      echo ""
      echo "Recovery flow \`$(basename "$FLOW_RECOVERY_FLOW")\` ran $recovery_runs time(s) after a failed attempt, $recovery_failures of which failed and were tolerated. Its duration is excluded from the rows above."
    fi
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
while IFS= read -r exclude_glob; do
  exclude_glob="${exclude_glob#"${exclude_glob%%[![:space:]]*}"}"
  exclude_glob="${exclude_glob%"${exclude_glob##*[![:space:]]}"}"
  [ -z "$exclude_glob" ] || find_cmd+=(! -name "$exclude_glob")
done < <(printf '%s\n' "$FLOWS_EXCLUDE_PATTERN" | tr ',' '\n')
flows=()
while IFS= read -r flow; do
  flows+=("$flow")
done < <("${find_cmd[@]}" | sort)
if [ "${#flows[@]}" -eq 0 ]; then
  echo "::error::No flows matching '$FLOWS_NAME_PATTERN' found under flows-dir '$FLOWS_DIR' (flows-max-depth=$FLOWS_MAX_DEPTH)."
  exit 1
fi
printf 'Resolved flow list (%s total):\n%s\n' "${#flows[@]}" "${flows[*]}"

# pre-run-flow (run once as priming below) and flow-recovery-flow (run on
# demand after a failed attempt) are not runnable scenarios. Whenever
# discovery above also finds either of them - a top-level match, or a match
# at any depth once flows-max-depth is raised - this filter is what stops
# the manifest or modulo split from selecting it and running it a second
# time as a scenario of its own. Compare with -ef (same-inode test) since
# the input and the discovered flow's path string may differ in form
# (relative vs "./"-prefixed, etc.) while resolving to the same file; -ef
# is POSIX-available in bash's test on both macOS and Linux, unlike
# GNU-only realpath -m.
if [ -n "$PRE_RUN_FLOW" ] || [ -n "$FLOW_RECOVERY_FLOW" ]; then
  remaining_flows=()
  for flow in "${flows[@]}"; do
    if [ -n "$PRE_RUN_FLOW" ] && [ "$flow" -ef "$PRE_RUN_FLOW" ]; then
      continue
    fi
    if [ -n "$FLOW_RECOVERY_FLOW" ] && [ "$flow" -ef "$FLOW_RECOVERY_FLOW" ]; then
      continue
    fi
    remaining_flows+=("$flow")
  done
  flows=(${remaining_flows[@]+"${remaining_flows[@]}"})
fi

discovered_flows=(${flows[@]+"${flows[@]}"})
select_by_tags=0
if [ -n "$included_tags$excluded_tags" ]; then
  select_by_tags=1
elif [ -n "${MAESTRO_CONFIG:-}" ] && grep -Eq '(include|exclude)Tags' "$MAESTRO_CONFIG"; then
  select_by_tags=1
fi
if [ "$select_by_tags" = '1' ] && [ "${#flows[@]}" -gt 0 ]; then
  tag_selection_file="$RUNNER_TEMP/maestro-tag-selection-${SHARD_INDEX}-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}.txt"
  if ! bash "$MAESTRO_SCRIPTS_DIR/select-flows-by-tags.sh" "${MAESTRO_CONFIG:-}" "$included_tags" "$excluded_tags" "${flows[@]}" > "$tag_selection_file"; then
    echo "::error::Could not select flows by tag (include-tags '$included_tags', exclude-tags '$excluded_tags', maestro-config '${MAESTRO_CONFIG:-}'); refusing to run an unfiltered shard."
    exit 1
  fi
  flows=()
  while IFS= read -r flow; do
    flows+=("$flow")
  done < "$tag_selection_file"
  rm -f "$tag_selection_file"
  if [ "${#flows[@]}" -eq 0 ]; then
    echo "::error::No flow under flows-dir '$FLOWS_DIR' is selected by include-tags '$included_tags' / exclude-tags '$excluded_tags' together with maestro-config '${MAESTRO_CONFIG:-}''s includeTags/excludeTags."
    exit 1
  fi
  printf 'Tag-selected flow list (%s total):\n%s\n' "${#flows[@]}" "${flows[*]}"
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
      for candidate in ${discovered_flows[@]+"${discovered_flows[@]}"}; do
        if [ "$candidate" = "$flow_path" ]; then
          match=2
          break
        fi
      done
    fi
    if [ "$match" -eq 2 ]; then
      echo "Skipping shard-manifest entry '$rel': deselected by tags."
      continue
    fi
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
  if ! run_flow_with_retries "$PRE_RUN_FLOW" "$(basename "$PRE_RUN_FLOW") (priming)" 0 0; then
    write_summary
    if [ "$emulator_lost" = '1' ]; then
      lost_emulator_error "during the priming flow '$(basename "$PRE_RUN_FLOW")', so shard $SHARD_INDEX ran none of its flows"
    else
      echo "::error::Priming flow '$PRE_RUN_FLOW' failed; aborting shard $SHARD_INDEX."
    fi
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
last_flow_index=$(( ${#selected[@]} - 1 ))
for flow_index in "${!selected[@]}"; do
  flow="${selected[$flow_index]}"
  recover_after_last_attempt=1
  if [ "$flow_index" -eq "$last_flow_index" ]; then
    recover_after_last_attempt=0
  fi
  if ! run_flow_with_retries "$flow" "$(basename "$flow")" "$recover_after_last_attempt" 1; then
    overall_status=1
    if [ "$emulator_lost" = '1' ]; then
      remaining=$(( last_flow_index - flow_index ))
      lost_emulator_error "during '$(basename "$flow")', so shard $SHARD_INDEX stops; its $remaining remaining flow(s) were not run"
      for skipped in "${selected[@]:$((flow_index + 1))}"; do
        summary_rows+=("| $(basename "$skipped") | 0s | not run (emulator lost) | 0 | 0 |")
        if [ -n "$junit_dir" ]; then
          bash "$MAESTRO_SCRIPTS_DIR/junit-failure.sh" "$(junit_report_file "$skipped")" "maestro-android shard $SHARD_INDEX" "$(basename "$skipped")" "Not run: emulator '$ANDROID_SERIAL' was lost earlier in the shard."
        fi
      done
      break
    fi
  fi
done

write_summary
exit "$overall_status"
