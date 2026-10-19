#!/usr/bin/env bash
# native-dev-release.yml's distribution: eas hands testers an EAS internal
# distribution link instead of a GitHub Release asset, which a private
# repository's testers cannot install. Every case here pins a way that link
# could come back wrong, or a combination of inputs that could not produce an
# installable build, to a failed step rather than a green run with nothing
# behind it.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

WORKFLOW="$REPO_ROOT/.github/workflows/native-dev-release.yml"
VALIDATE='Validate distribution and build location'
DISTRIBUTE='Distribute through EAS'
BUILD_ID='0f3c2a5e-1b2d-4c3e-8f4a-5b6c7d8e9f01'
BUILD_PAGE="https://expo.dev/accounts/acme/projects/app/builds/${BUILD_ID}"

validate() {
    local job="$1"
    shift
    workspace="$(new_workflow_workspace "$WORKFLOW" "$job" "$VALIDATE")"
    run_step "$workspace" DISTRIBUTION=github-release BUILD_LOCATION=local POST_BUILD_COMMAND='' \
        VERIFY_EMBEDDED_BUILD_NUMBER=false ARTIFACT_EXTENSION=apk "$@"
}

for job in ios-dev-release android-dev-release; do
    case_start "$job: the defaults (github-release, local) validate"
    validate "$job"
    if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))"; then
        pass_case
    fi

    case_start "$job: eas distribution of a local build validates"
    validate "$job" DISTRIBUTION=eas
    if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))"; then
        pass_case
    fi

    case_start "$job: an EAS cloud build distributed through EAS validates"
    validate "$job" DISTRIBUTION=eas BUILD_LOCATION=cloud
    if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))"; then
        pass_case
    fi

    case_start "$job: an unknown distribution fails closed"
    validate "$job" DISTRIBUTION=testflight
    if assert_equals 1 "$STEP_STATUS" 'status' \
        && assert_contains "$(cat "$workspace/log")" "'testflight'" 'error names the value'; then
        pass_case
    fi

    case_start "$job: an unknown build-location fails closed"
    validate "$job" BUILD_LOCATION=remote
    if assert_equals 1 "$STEP_STATUS" 'status' \
        && assert_contains "$(cat "$workspace/log")" "'remote'" 'error names the value'; then
        pass_case
    fi

    case_start "$job: a cloud build cannot become a GitHub Release asset"
    validate "$job" BUILD_LOCATION=cloud
    if assert_equals 1 "$STEP_STATUS" 'status' \
        && assert_contains "$(cat "$workspace/log")" 'distribution: eas' 'hint'; then
        pass_case
    fi

    case_start "$job: a cloud build with a post-build hook fails rather than skipping the hook"
    validate "$job" DISTRIBUTION=eas BUILD_LOCATION=cloud POST_BUILD_COMMAND='./gate.sh'
    if assert_equals 1 "$STEP_STATUS" 'status' \
        && assert_contains "$(cat "$workspace/log")" 'post-build' 'error'; then
        pass_case
    fi
done

case_start 'ios-dev-release: a cloud build cannot verify the embedded build number, so asking for it fails'
validate ios-dev-release DISTRIBUTION=eas BUILD_LOCATION=cloud VERIFY_EMBEDDED_BUILD_NUMBER=true
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$workspace/log")" 'ios-verify-embedded-build-number' 'error'; then
    pass_case
fi

case_start 'android-dev-release: an aab handed out through EAS fails, no tester could install it'
validate android-dev-release DISTRIBUTION=eas ARTIFACT_EXTENSION=aab
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$workspace/log")" 'apk' 'hint'; then
    pass_case
fi

case_start 'android-dev-release: an aab on a GitHub Release keeps validating as before'
validate android-dev-release ARTIFACT_EXTENSION=aab
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))"; then
    pass_case
fi

# --- eas upload of a local build -------------------------------------------------------

stub_upload() {
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$workspace" npx 'printf "%s\n" "$@" > "$FAKE_NPX_ARGS"
echo "Uploading your app archive to EAS" >&2
'"$1"
}

for lane in 'ios-dev-release ios' 'android-dev-release android'; do
    read -r job platform <<< "$lane"

    case_start "$job: eas upload's build page becomes install-url and build-id"
    workspace="$(new_workflow_workspace "$WORKFLOW" "$job" "$DISTRIBUTE")"
    stub_upload "printf '{\"url\":\"%s\"}\n' '$BUILD_PAGE'"
    : > "$workspace/runner-temp/app.bin"
    run_step "$workspace" EAS_CLI_VERSION=20.5.1 PLATFORM="$platform" BUILD_LOCATION=local \
        ARTIFACT_PATH="$workspace/runner-temp/app.bin" BUILD_JSON='' FAKE_NPX_ARGS="$workspace/npx-args"
    args="$(tr '\n' ' ' < "$workspace/npx-args" 2>/dev/null || true)"
    if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))" \
        && assert_contains "$args" "eas-cli@20.5.1 upload --platform $platform --build-path $workspace/runner-temp/app.bin --non-interactive --json" 'eas upload invocation' \
        && assert_equals "$BUILD_PAGE" "$(step_output "$workspace" install-url)" 'install-url' \
        && assert_equals "$BUILD_ID" "$(step_output "$workspace" build-id)" 'build-id' \
        && assert_contains "$(cat "$workspace/summary")" "$BUILD_PAGE" 'job summary link'; then
        pass_case
    fi

    case_start "$job: a failed eas upload fails the step"
    workspace="$(new_workflow_workspace "$WORKFLOW" "$job" "$DISTRIBUTE")"
    stub_upload 'exit 3'
    : > "$workspace/runner-temp/app.bin"
    run_step "$workspace" EAS_CLI_VERSION=20.5.1 PLATFORM="$platform" BUILD_LOCATION=local \
        ARTIFACT_PATH="$workspace/runner-temp/app.bin" BUILD_JSON='' FAKE_NPX_ARGS="$workspace/npx-args"
    if assert_equals 3 "$STEP_STATUS" 'status' \
        && assert_equals '' "$(step_output "$workspace" install-url)" 'no install-url'; then
        pass_case
    fi
done

case_start 'eas upload that exits 0 without a URL fails closed'
workspace="$(new_workflow_workspace "$WORKFLOW" android-dev-release "$DISTRIBUTE")"
stub_upload "echo '{}'"
: > "$workspace/runner-temp/app.bin"
run_step "$workspace" EAS_CLI_VERSION=20.5.1 PLATFORM=android BUILD_LOCATION=local \
    ARTIFACT_PATH="$workspace/runner-temp/app.bin" BUILD_JSON='' FAKE_NPX_ARGS="$workspace/npx-args"
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$workspace/log")" '::error::' 'error' \
    && assert_equals '' "$(step_output "$workspace" install-url)" 'no install-url'; then
    pass_case
fi

case_start 'eas upload printing something other than an EAS build page fails closed'
workspace="$(new_workflow_workspace "$WORKFLOW" android-dev-release "$DISTRIBUTE")"
stub_upload "echo '{\"url\":\"https://example.invalid/builds/${BUILD_ID}\"}'"
: > "$workspace/runner-temp/app.bin"
run_step "$workspace" EAS_CLI_VERSION=20.5.1 PLATFORM=android BUILD_LOCATION=local \
    ARTIFACT_PATH="$workspace/runner-temp/app.bin" BUILD_JSON='' FAKE_NPX_ARGS="$workspace/npx-args"
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_equals '' "$(step_output "$workspace" build-id)" 'no build-id'; then
    pass_case
fi

for job in ios-dev-release android-dev-release; do
    case_start "$job: a build page followed by an injected line fails closed, never reaching GITHUB_OUTPUT"
    workspace="$(new_workflow_workspace "$WORKFLOW" "$job" "$DISTRIBUTE")"
    stub_upload "jq -nc --arg url '${BUILD_PAGE}'\$'\\n''build-id=injected' '{url: \$url}'"
    : > "$workspace/runner-temp/app.bin"
    run_step "$workspace" EAS_CLI_VERSION=20.5.1 PLATFORM="${job%%-*}" BUILD_LOCATION=local \
        ARTIFACT_PATH="$workspace/runner-temp/app.bin" BUILD_JSON='' FAKE_NPX_ARGS="$workspace/npx-args"
    if assert_equals 1 "$STEP_STATUS" 'status' \
        && assert_equals '' "$(cat "$workspace/outputs" 2>/dev/null)" 'no output'; then
        pass_case
    fi
done

case_start 'eas upload printing non-JSON fails closed'
workspace="$(new_workflow_workspace "$WORKFLOW" ios-dev-release "$DISTRIBUTE")"
stub_upload "echo 'Shareable link to the build: ${BUILD_PAGE}'"
: > "$workspace/runner-temp/app.bin"
run_step "$workspace" EAS_CLI_VERSION=20.5.1 PLATFORM=ios BUILD_LOCATION=local \
    ARTIFACT_PATH="$workspace/runner-temp/app.bin" BUILD_JSON='' FAKE_NPX_ARGS="$workspace/npx-args"
if assert_equals 1 "$STEP_STATUS" 'status'; then
    pass_case
fi

# --- an EAS cloud build ----------------------------------------------------------------

cloud_build_json() {
    # cloud_build_json <status> <distribution> <buildUrl>
    jq -n --arg id "$BUILD_ID" --arg status "$1" --arg distribution "$2" --arg url "$3" \
        '[{id: $id, status: $status, distribution: $distribution, platform: "ANDROID",
           artifacts: {buildUrl: $url},
           project: {__typename: "App", slug: "app", ownerAccount: {name: "acme"}}}]'
}

distribute_cloud() {
    local job="$1" platform="$2" json="$3"
    workspace="$(new_workflow_workspace "$WORKFLOW" "$job" "$DISTRIBUTE")"
    printf '%s\n' "$json" > "$workspace/runner-temp/eas-build.json"
    stub "$workspace" npx 'echo "a cloud build must not upload anything" >&2; exit 42'
    run_step "$workspace" EAS_CLI_VERSION=20.5.1 PLATFORM="$platform" BUILD_LOCATION=cloud \
        ARTIFACT_PATH='' BUILD_JSON="$workspace/runner-temp/eas-build.json"
}

for lane in 'ios-dev-release ios https://expo.dev/artifacts/eas/abc.ipa' \
    'android-dev-release android https://expo.dev/artifacts/eas/abc.apk'; do
    read -r job platform artifact <<< "$lane"
    case_start "$job: a finished internal cloud build's page becomes install-url"
    distribute_cloud "$job" "$platform" "$(cloud_build_json FINISHED INTERNAL "$artifact")"
    if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))" \
        && assert_equals "$BUILD_PAGE" "$(step_output "$workspace" install-url)" 'install-url' \
        && assert_equals "$BUILD_ID" "$(step_output "$workspace" build-id)" 'build-id'; then
        pass_case
    fi
done

case_start 'a cloud build that did not finish fails closed'
distribute_cloud android-dev-release android "$(cloud_build_json ERRORED INTERNAL '')"
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$workspace/log")" 'ERRORED' 'status named'; then
    pass_case
fi

case_start 'a store-distribution cloud build fails closed, testers cannot install it'
distribute_cloud android-dev-release android "$(cloud_build_json FINISHED STORE https://expo.dev/artifacts/eas/abc.apk)"
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$workspace/log")" 'internal' 'hint'; then
    pass_case
fi

case_start 'a cloud build with no artifact fails closed'
distribute_cloud ios-dev-release ios "$(cloud_build_json FINISHED INTERNAL '')"
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$workspace/log")" 'buildUrl' 'error'; then
    pass_case
fi

case_start 'an Android cloud build that produced an aab fails closed'
distribute_cloud android-dev-release android "$(cloud_build_json FINISHED INTERNAL https://expo.dev/artifacts/eas/abc.aab)"
if assert_equals 1 "$STEP_STATUS" 'status' \
    && assert_contains "$(cat "$workspace/log")" 'aab' 'error'; then
    pass_case
fi

case_start 'a cloud build JSON with more than one build fails closed'
distribute_cloud android-dev-release android "$(cloud_build_json FINISHED INTERNAL https://expo.dev/artifacts/eas/abc.apk | jq -c '. + .')"
if assert_equals 1 "$STEP_STATUS" 'status'; then
    pass_case
fi

case_start 'an empty cloud build JSON fails closed'
distribute_cloud android-dev-release android ''
if assert_equals 1 "$STEP_STATUS" 'status'; then
    pass_case
fi

for lane in 'ios-dev-release iOS ios' 'android-dev-release Android android'; do
    read -r job label platform <<< "$lane"
    case_start "$job: the cloud build waits for EAS and prints JSON, never --local"
    workspace="$(new_workflow_workspace "$WORKFLOW" "$job" "EAS cloud build ($label, development)")"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$workspace" npx 'printf "%s\n" "$@" > "$FAKE_NPX_ARGS"; echo "[{\"id\":\"x\"}]"'
    run_step "$workspace" EAS_CLI_VERSION=20.5.1 BUILD_PROFILE=development PLATFORM="$platform" FAKE_NPX_ARGS="$workspace/npx-args"
    args="$(tr '\n' ' ' < "$workspace/npx-args" 2>/dev/null || true)"
    if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))" \
        && assert_contains "$args" "build --platform $platform --profile development --non-interactive --json --wait" 'invocation' \
        && assert_not_contains "$args" '--local' 'no local build' \
        && assert_equals '[{"id":"x"}]' "$(cat "$(step_output "$workspace" build-json)" 2>/dev/null || true)" 'build JSON kept'; then
        pass_case
    fi

    case_start "$job: a failed cloud build fails the step and shows what EAS said"
    workspace="$(new_workflow_workspace "$WORKFLOW" "$job" "EAS cloud build ($label, development)")"
    stub "$workspace" npx 'echo "[{\"status\":\"ERRORED\",\"error\":{\"message\":\"Gradle failed\"}}]"; exit 1'
    run_step "$workspace" EAS_CLI_VERSION=20.5.1 BUILD_PROFILE=development PLATFORM="$platform"
    if assert_equals 1 "$STEP_STATUS" 'status' \
        && assert_contains "$(cat "$workspace/log")" 'Gradle failed' 'EAS error shown' \
        && assert_equals '' "$(step_output "$workspace" build-json)" 'no build-json'; then
        pass_case
    fi
done

# --- the pull request comment ----------------------------------------------------------

case_start 'pr-comment: an EAS-distributed build links its install page, not a release asset'
workspace="$(new_workflow_workspace "$WORKFLOW" pr-comment 'Render development build comment sections')"
run_step "$workspace" SECTIONS_DIR="$workspace/runner-temp/sections" \
    SERVER_URL='https://github.com' REPOSITORY='acme/app' HEAD_SHA='abcdef0123456789' \
    RUN_URL='https://github.com/acme/app/actions/runs/7' \
    ENABLE_IOS=false IOS_RESULT=skipped IOS_TAG='' IOS_ASSET='' IOS_FINGERPRINT='' IOS_INSTALL_URL='' \
    ENABLE_ANDROID=true ANDROID_RESULT=success ANDROID_TAG='' ANDROID_ASSET='' ANDROID_FINGERPRINT='ff' \
    ANDROID_INSTALL_URL="$BUILD_PAGE"
section="$(cat "$workspace/runner-temp/sections/android-dev-build.md" 2>/dev/null || true)"
if assert_equals 0 "$STEP_STATUS" "status ($(cat "$workspace/log"))" \
    && assert_contains "$section" "($BUILD_PAGE)" 'install link' \
    && assert_not_contains "$section" 'did not publish' 'not reported as a failure'; then
    pass_case
fi

# --- wiring ----------------------------------------------------------------------------

case_start 'wiring: inputs, gates and outputs of the EAS distribution'
if failure="$(WORKFLOW_YML="$WORKFLOW" python3 - <<'PYTHON' 2>&1
import os
import sys

import yaml

workflow = yaml.safe_load(open(os.environ['WORKFLOW_YML'], encoding='utf-8'))
call = workflow[True]['workflow_call']
inputs = call['inputs']
problems = []
for name, default in (('distribution', 'github-release'), ('build-location', 'local')):
    if inputs.get(name, {}).get('default') != default:
        problems.append(f'input {name} must default to {default!r}')
outputs = call.get('outputs', {})
for platform in ('ios', 'android'):
    job_id = f'{platform}-dev-release'
    for key in ('install-url', 'build-id', 'release-url', 'fingerprint'):
        wanted = f'jobs.{job_id}.outputs.{key}'
        if wanted not in str(outputs.get(f'{platform}-{key}', {}).get('value', '')):
            problems.append(f'workflow output {platform}-{key} must read {wanted}')
    job = workflow['jobs'][job_id]
    for key in ('install-url', 'build-id', 'release-url'):
        if key not in job.get('outputs', {}):
            problems.append(f'{job_id}: missing job output {key}')
    steps = {step.get('name'): step for step in job['steps']}
    names = [step.get('name') for step in job['steps']]
    label = 'iOS' if platform == 'ios' else 'Android'
    order = ['Validate distribution and build location', 'Checkout repository',
             f'EAS build ({label}, development)', f'EAS cloud build ({label}, development)',
             f'Run {label} post-build command', 'Distribute through EAS', 'Create GitHub Release (draft)']
    missing = [name for name in order if name not in names]
    if missing:
        problems.append(f'{job_id}: missing step(s) {missing}')
        continue
    positions = [names.index(name) for name in order]
    if positions != sorted(positions):
        problems.append(f'{job_id}: expected order {order}')
    gates = {
        f'EAS build ({label}, development)': "inputs.build-location == 'local'",
        f'EAS cloud build ({label}, development)': "inputs.build-location == 'cloud'",
        'Read embedded build number': "inputs.build-location == 'local'",
        f'Upload {label} dev build artifact': "inputs.build-location == 'local'",
        'Distribute through EAS': "inputs.distribution == 'eas'",
        'Compute build metadata': "inputs.distribution == 'github-release'",
        'Create GitHub Release (draft)': "inputs.distribution == 'github-release'",
        'Publish GitHub Release': "inputs.distribution == 'github-release'",
        f'Prune old {label} dev releases': "inputs.distribution == 'github-release'",
    }
    if platform == 'android':
        gates['Fit the native build into the container limits'] = "inputs.build-location == 'local'"
    for name, condition in gates.items():
        if condition not in str(steps.get(name, {}).get('if', '')):
            problems.append(f'{job_id}: step {name!r} must be gated on {condition}')
if problems:
    sys.exit('\n'.join(problems))
PYTHON
)"; then
    pass_case
else
    fail_case "$failure"
fi

finish_suite
