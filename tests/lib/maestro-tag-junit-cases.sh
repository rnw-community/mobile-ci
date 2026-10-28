# shellcheck shell=bash
# Issue #220: include-tags / exclude-tags select flows by their config
# section's `tags:` when the shard is planned (honouring maestro-config's
# includeTags/excludeTags), and every flow's final attempt leaves a JUnit
# report in artifacts-dir/junit. Three shard scripts implement it, so every
# suite that owns one runs these same cases against its own script.
#
# The calling suite defines:
#   prepare_tagged <dir-var-unused>  prints a workspace whose ./stub-bin/maestro
#                                    logs each invocation's argv to $MAESTRO_CALLS
#                                    and fails for any *fail.flow.yaml
#   invoke_tagged <dir> [VAR=value ...]
#                                    runs the shard step with FLOWS_DIR=flows,
#                                    one shard, no retries, no priming or
#                                    recovery flow, INCLUDE_TAGS='',
#                                    EXCLUDE_TAGS='', MAESTRO_CONFIG='',
#                                    JUNIT_REPORT=true and the junit directory
#                                    at <dir>/artifacts/junit, overridden by
#                                    any VAR=value passed
#
# Tag selection reads YAML with the Jackson jars of the Maestro CLI the
# `maestro` on PATH belongs to, through the Java source launcher. The cases
# that need it get those jars from Maven Central (checked against the digests
# of the copies Maestro 2.10.0 ships) and a JDK from PATH or JAVA_HOME; with
# either missing they are skipped, unless MAESTRO_TAGS_REQUIRE_TOOLS=1 (as in
# self-test.yml) turns the skip into a failure.

MAESTRO_TEST_JARS=(
    'com/fasterxml/jackson/core/jackson-annotations/2.17.1/jackson-annotations-2.17.1.jar fccad82e13172c0e4384db71577219c9b8631c0820f4b18daaa57016fb661c76'
    'com/fasterxml/jackson/core/jackson-core/2.17.1/jackson-core-2.17.1.jar ddb26c8a1f1a84535e8213c48b35b253370434e3287b3cf15777856fc4e58ce6'
    'com/fasterxml/jackson/core/jackson-databind/2.17.1/jackson-databind-2.17.1.jar b6ca2f7d5b1ab245cec5495ec339773d2d90554c48592590673fb18f4400a948'
    'com/fasterxml/jackson/dataformat/jackson-dataformat-yaml/2.17.1/jackson-dataformat-yaml-2.17.1.jar 83f38459593bc10caeb1fa2653616813b1743b6bed67163c8ae8e5a4d32a5456'
    'org/yaml/snakeyaml/2.5/snakeyaml-2.5.jar e6682acf1ace77508ef13649cbf4f8d09d2cf5457bdb61d25ffb6ac0233d78dd'
)

maestro_test_sha256() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$1" | cut -d ' ' -f 1
    else
        shasum -a 256 "$1" | cut -d ' ' -f 1
    fi
}

# Prints the cached directory holding the Jackson YAML jars, fetching any
# missing one; returns non-zero (printing nothing) when they cannot be had.
maestro_test_lib_dir() {
    local cache="${MOBILE_CI_TEST_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/mobile-ci-tests}/maestro-2.10.0-lib"
    local entry rel digest jar
    mkdir -p "$cache" || return 1
    for entry in "${MAESTRO_TEST_JARS[@]}"; do
        rel="${entry%% *}"
        digest="${entry##* }"
        jar="$cache/$(basename "$rel")"
        if [ ! -f "$jar" ] || [ "$(maestro_test_sha256 "$jar")" != "$digest" ]; then
            curl -fsSL --retry 3 -o "$jar.part" "https://repo1.maven.org/maven2/$rel" > /dev/null 2>&1 || { rm -f "$jar.part"; return 1; }
            if [ "$(maestro_test_sha256 "$jar.part")" != "$digest" ]; then
                rm -f "$jar.part"
                return 1
            fi
            mv "$jar.part" "$jar"
        fi
    done
    printf '%s\n' "$cache"
}

maestro_test_java_available() {
    local java_bin=java
    if [ -n "${JAVA_HOME:-}" ]; then
        java_bin="$JAVA_HOME/bin/java"
    fi
    "$java_bin" -version > /dev/null 2>&1
}

MAESTRO_TEST_LIB=''
maestro_tag_tools_ready() {
    if [ -z "$MAESTRO_TEST_LIB" ] && maestro_test_java_available; then
        MAESTRO_TEST_LIB="$(maestro_test_lib_dir || true)"
    fi
    if [ -n "$MAESTRO_TEST_LIB" ]; then
        return 0
    fi
    if [ "${MAESTRO_TAGS_REQUIRE_TOOLS:-0}" = '1' ]; then
        fail_case "a JDK and the Jackson YAML jars are required (MAESTRO_TAGS_REQUIRE_TOOLS=1) but are unavailable"
    else
        printf 'skip  %s (no JDK or no Jackson YAML jars)\n' "$CURRENT_CASE"
    fi
    return 1
}

# Gives the workspace's stub maestro a sibling lib/ like a real Maestro CLI's.
link_maestro_lib() {
    ln -s "$MAESTRO_TEST_LIB" "$1/lib"
}

write_tagged_flows() {
    local flows_dir="$1"
    mkdir -p "$flows_dir"
    printf 'appId: x\ntags:\n  - smoke\n  - android-only\n---\n- launchApp\n' > "$flows_dir/01.alpha.flow.yaml"
    printf 'appId: x\ntags: [smoke, checkout]\n---\n- launchApp\n' > "$flows_dir/02.beta.flow.yaml"
    printf 'appId: x\ntags: [slow]\n---\n- launchApp\n' > "$flows_dir/03.gamma.flow.yaml"
    printf 'appId: x\n---\n- launchApp\n' > "$flows_dir/04.delta.flow.yaml"
}

shard_flows_run() {
    [ -f "$1/calls" ] || return 0
    sed -nE 's#.* (flows/[^ ]+\.flow\.yaml)$#\1#p' "$1/calls" | tr '\n' ' ' | sed 's/ $//'
}

run_maestro_tag_junit_cases() {
    local workspace calls

    case_start 'no tags and no maestro-config tags plan the shard without the YAML reader'
    workspace="$(prepare_tagged)"
    write_tagged_flows "$workspace/work/flows"
    invoke_tagged "$workspace"
    calls="$(cat "$workspace/calls" 2>/dev/null || true)"
    if assert_equals 0 "$STEP_STATUS" 'step status' \
        && assert_equals 'flows/01.alpha.flow.yaml flows/02.beta.flow.yaml flows/03.gamma.flow.yaml flows/04.delta.flow.yaml' \
            "$(shard_flows_run "$workspace")" 'flows run' \
        && assert_not_contains "$calls" '--include-tags' 'maestro argv' \
        && assert_not_contains "$(cat "$workspace/log")" 'Tag-selected flow list' 'log'; then
        pass_case
    fi

    case_start 'include-tags keeps flows holding any listed tag, in block and inline tag lists'
    workspace="$(prepare_tagged)"
    write_tagged_flows "$workspace/work/flows"
    if maestro_tag_tools_ready; then
        link_maestro_lib "$workspace"
        invoke_tagged "$workspace" INCLUDE_TAGS=' checkout ,slow, '
        calls="$(cat "$workspace/calls" 2>/dev/null || true)"
        if assert_equals 0 "$STEP_STATUS" 'step status' \
            && assert_equals 'flows/02.beta.flow.yaml flows/03.gamma.flow.yaml' "$(shard_flows_run "$workspace")" 'flows run' \
            && assert_contains "$calls" '--include-tags checkout,slow' 'maestro argv'; then
            pass_case
        fi
    fi

    case_start 'exclude-tags wins over include-tags'
    workspace="$(prepare_tagged)"
    write_tagged_flows "$workspace/work/flows"
    if maestro_tag_tools_ready; then
        link_maestro_lib "$workspace"
        invoke_tagged "$workspace" INCLUDE_TAGS=smoke EXCLUDE_TAGS=android-only
        calls="$(cat "$workspace/calls" 2>/dev/null || true)"
        if assert_equals 0 "$STEP_STATUS" 'step status' \
            && assert_equals 'flows/02.beta.flow.yaml' "$(shard_flows_run "$workspace")" 'flows run' \
            && assert_contains "$calls" '--include-tags smoke --exclude-tags android-only' 'maestro argv'; then
            pass_case
        fi
    fi

    case_start "maestro-config's includeTags/excludeTags are honoured with no tag inputs"
    workspace="$(prepare_tagged)"
    write_tagged_flows "$workspace/work/flows"
    printf 'flows:\n  - "*"\nincludeTags: smoke\nexcludeTags:\n  - android-only\n' > "$workspace/work/config.yaml"
    if maestro_tag_tools_ready; then
        link_maestro_lib "$workspace"
        invoke_tagged "$workspace" MAESTRO_CONFIG=config.yaml
        calls="$(cat "$workspace/calls" 2>/dev/null || true)"
        if assert_equals 0 "$STEP_STATUS" 'step status' \
            && assert_equals 'flows/02.beta.flow.yaml' "$(shard_flows_run "$workspace")" 'flows run' \
            && assert_not_contains "$calls" '--exclude-tags' 'maestro argv'; then
            pass_case
        fi
    fi

    case_start "tag inputs are added to maestro-config's tags, as maestro test <dir> does"
    workspace="$(prepare_tagged)"
    write_tagged_flows "$workspace/work/flows"
    printf 'includeTags: [slow]\n' > "$workspace/work/config.yaml"
    if maestro_tag_tools_ready; then
        link_maestro_lib "$workspace"
        invoke_tagged "$workspace" MAESTRO_CONFIG=config.yaml INCLUDE_TAGS=checkout
        if assert_equals 0 "$STEP_STATUS" 'step status' \
            && assert_equals 'flows/02.beta.flow.yaml flows/03.gamma.flow.yaml' "$(shard_flows_run "$workspace")" 'flows run'; then
            pass_case
        fi
    fi

    case_start 'a selection left with no flow fails closed'
    workspace="$(prepare_tagged)"
    write_tagged_flows "$workspace/work/flows"
    if maestro_tag_tools_ready; then
        link_maestro_lib "$workspace"
        invoke_tagged "$workspace" INCLUDE_TAGS=nightly
        if assert_equals 1 "$STEP_STATUS" 'step status' \
            && assert_contains "$(cat "$workspace/log")" '::error::No flow under flows-dir' 'error message' \
            && assert_equals '' "$(shard_flows_run "$workspace")" 'flows run'; then
            pass_case
        fi
    fi

    case_start 'a flow whose tags are not a list fails closed'
    workspace="$(prepare_tagged)"
    write_tagged_flows "$workspace/work/flows"
    printf 'appId: x\ntags: smoke\n---\n- launchApp\n' > "$workspace/work/flows/05.scalar.flow.yaml"
    if maestro_tag_tools_ready; then
        link_maestro_lib "$workspace"
        invoke_tagged "$workspace" INCLUDE_TAGS=smoke
        if assert_equals 1 "$STEP_STATUS" 'step status' \
            && assert_contains "$(cat "$workspace/log")" "tags must be a YAML list" 'error message' \
            && assert_equals '' "$(shard_flows_run "$workspace")" 'flows run'; then
            pass_case
        fi
    fi

    case_start 'an unparsable flow config section fails closed'
    workspace="$(prepare_tagged)"
    write_tagged_flows "$workspace/work/flows"
    printf 'appId: [x\ntags: [smoke]\n---\n- launchApp\n' > "$workspace/work/flows/05.broken.flow.yaml"
    if maestro_tag_tools_ready; then
        link_maestro_lib "$workspace"
        invoke_tagged "$workspace" EXCLUDE_TAGS=slow
        if assert_equals 1 "$STEP_STATUS" 'step status' \
            && assert_contains "$(cat "$workspace/log")" "is not parsable YAML" 'error message' \
            && assert_equals '' "$(shard_flows_run "$workspace")" 'flows run'; then
            pass_case
        fi
    fi

    case_start 'tag selection without the Maestro lib directory fails closed'
    workspace="$(prepare_tagged)"
    write_tagged_flows "$workspace/work/flows"
    invoke_tagged "$workspace" INCLUDE_TAGS=smoke
    if assert_equals 1 "$STEP_STATUS" 'step status' \
        && assert_contains "$(cat "$workspace/log")" 'refusing to run an unfiltered shard' 'error message' \
        && assert_equals '' "$(shard_flows_run "$workspace")" 'flows run'; then
        pass_case
    fi

    case_start 'a shard-manifest entry deselected by tags is skipped, not rejected'
    workspace="$(prepare_tagged)"
    write_tagged_flows "$workspace/work/flows"
    mkdir -p "$workspace/work/manifest"
    printf '01.alpha.flow.yaml\n02.beta.flow.yaml\n' > "$workspace/work/manifest/shard-0.txt"
    if maestro_tag_tools_ready; then
        link_maestro_lib "$workspace"
        invoke_tagged "$workspace" SHARD_MANIFEST_DIR=manifest EXCLUDE_TAGS=android-only
        if assert_equals 0 "$STEP_STATUS" 'step status' \
            && assert_equals 'flows/02.beta.flow.yaml' "$(shard_flows_run "$workspace")" 'flows run' \
            && assert_contains "$(cat "$workspace/log")" "Skipping shard-manifest entry '01.alpha.flow.yaml': deselected by tags." 'log'; then
            pass_case
        fi
    fi

    case_start 'every flow writes a JUnit report into artifacts-dir/junit'
    workspace="$(prepare_tagged)"
    write_tagged_flows "$workspace/work/flows"
    invoke_tagged "$workspace"
    calls="$(cat "$workspace/calls" 2>/dev/null || true)"
    if assert_equals 0 "$STEP_STATUS" 'step status' \
        && assert_contains "$calls" "--format junit --output $workspace/artifacts/junit/01.alpha.flow.xml" 'maestro argv' \
        && assert_contains "$calls" "--output $workspace/artifacts/junit/04.delta.flow.xml" 'maestro argv'; then
        pass_case
    fi

    case_start 'a failed flow with no Maestro report gets a JUnit failure in its place'
    workspace="$(prepare_tagged)"
    write_tagged_flows "$workspace/work/flows"
    printf 'appId: x\n---\n- launchApp\n' > "$workspace/work/flows/05.fail.flow.yaml"
    invoke_tagged "$workspace"
    if assert_equals 1 "$STEP_STATUS" 'step status' \
        && assert_contains "$(cat "$workspace/artifacts/junit/05.fail.flow.xml" 2>/dev/null || true)" \
            '<failure message="Failed after 1 attempt(s) without a Maestro report' 'synthetic report' \
        && assert_contains "$(cat "$workspace/artifacts/junit/05.fail.flow.xml" 2>/dev/null || true)" \
            'name="05.fail.flow.yaml"' 'synthetic report'; then
        pass_case
    fi

    case_start "junit-report 'false' writes no report"
    workspace="$(prepare_tagged)"
    write_tagged_flows "$workspace/work/flows"
    invoke_tagged "$workspace" JUNIT_REPORT=false
    calls="$(cat "$workspace/calls" 2>/dev/null || true)"
    if assert_equals 0 "$STEP_STATUS" 'step status' \
        && assert_not_contains "$calls" '--format' 'maestro argv' \
        && assert_equals 'no' "$( [ -e "$workspace/artifacts/junit" ] && echo yes || echo no)" 'junit dir'; then
        pass_case
    fi

    case_start "junit-report rejects anything but 'true' or 'false'"
    workspace="$(prepare_tagged)"
    write_tagged_flows "$workspace/work/flows"
    invoke_tagged "$workspace" JUNIT_REPORT=yes
    if assert_equals 1 "$STEP_STATUS" 'step status' \
        && assert_contains "$(cat "$workspace/log")" "junit-report 'yes' must be 'true' or 'false'" 'error message'; then
        pass_case
    fi
}
