#!/usr/bin/env bash
# turbo-affected gates both Maestro workflows. Issue #186: an unset
# target-packages used to make every pull request affected; the package names
# are now read from each target's appDir, and every way that read can go wrong
# still fails closed.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/turbo-affected/action.yml"
STEP='Compute affected packages'

WORKSPACE_PACKAGES='@example/app @example/tv @example/landing @example/shared @example/other'

turbo_items() {
    local items='' name
    for name in "$@"; do
        items="${items:+$items,}{\"name\":\"$name\"}"
    done
    printf '{"packages":{"items":[%s]}}' "$items"
}

# prepare <turbo affected package names...>
# Stubs npx as `turbo ls --output=json`, listing $WORKSPACE_PACKAGES, and as
# `turbo ls --affected --output=json`, reporting the given names, and records
# that turbo ran.
prepare() {
    local dir
    dir="$(new_workspace "$ACTION" "$STEP")"
    turbo_items "$@" > "$dir/turbo.json"
    # shellcheck disable=SC2086 # the workspace package list is word-split on purpose.
    turbo_items $WORKSPACE_PACKAGES > "$dir/turbo-all.json"
    # shellcheck disable=SC2016 # the stub body is expanded when the stub runs.
    stub "$dir" npx 'printf "%s\n" "$2" >> "$TURBO_RAN_FILE"
case " $* " in
    *" --affected "*) cat "$TURBO_JSON_FILE" ;;
    *) cat "$TURBO_ALL_FILE" ;;
esac'
    printf '%s\n' "$dir"
}

package() {
    local dir="$1" app_dir="$2" name="$3"
    mkdir -p "$dir/work/$app_dir"
    printf '{"name":"%s","private":true}\n' "$name" > "$dir/work/$app_dir/package.json"
}

detect() {
    local dir="$1"
    shift
    run_step "$dir" \
        TURBO_VERSION=2.10.8 \
        TARGET_PACKAGES='' \
        TARGETS='' \
        TURBO_SCM_BASE=base-sha \
        ALWAYS_AFFECTED=false \
        EXEMPT_PATHS= \
        TRIGGER_PATHS= \
        FORCE_LABEL= \
        TURBO_RAN_FILE="$dir/turbo-ran" \
        TURBO_JSON_FILE="$dir/turbo.json" \
        TURBO_ALL_FILE="$dir/turbo-all.json" \
        "$@"
}

assert_failed_closed() {
    local dir="$1" message="$2"
    if [ "$STEP_STATUS" -eq 0 ]; then
        fail_case "the step succeeded with affected='$(step_output "$dir" affected)'"
        return 1
    fi
    assert_equals '' "$(step_output "$dir" affected)" 'affected output' \
        && assert_contains "$(cat "$dir/log")" "$message" 'error message'
}

TARGETS_JSON='[{"name":"bare","appDir":"packages/app"},{"name":"tablet","appDir":"packages/app"},{"name":"tv","appDir":"apps/tv"}]'

case_start 'target-packages defaults to empty so it can be derived'
if assert_equals '' "$(action_input_default "$ACTION" target-packages)" 'target-packages default'; then
    pass_case
fi

case_start 'derived names skip a pull request that changes only an unrelated package'
dir="$(prepare @example/landing)"
package "$dir" packages/app @example/app
package "$dir" apps/tv @example/tv
detect "$dir" TARGETS="$TARGETS_JSON"
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals false "$(step_output "$dir" affected)" 'affected' \
    && assert_contains "$(cat "$dir/log")" '@example/app' 'derived names logged' \
    && pass_case

case_start 'derived names report affected when a target app changes'
dir="$(prepare @example/landing @example/tv)"
package "$dir" packages/app @example/app
package "$dir" apps/tv @example/tv
detect "$dir" TARGETS="$TARGETS_JSON"
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals true "$(step_output "$dir" affected)" 'affected' \
    && pass_case

case_start 'explicit target-packages wins over the targets appDir names'
dir="$(prepare @example/app)"
detect "$dir" TARGETS="$TARGETS_JSON" TARGET_PACKAGES="$(printf '@example/shared\n@example/other\n')"
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals false "$(step_output "$dir" affected)" 'affected' \
    && pass_case

case_start 'a derived target package that is not a turbo workspace package fails closed'
dir="$(prepare @example/landing)"
package "$dir" packages/app @example/app
package "$dir" apps/outside @example/outside
detect "$dir" TARGETS='[{"name":"bare","appDir":"packages/app"},{"name":"tv","appDir":"apps/outside"}]'
assert_failed_closed "$dir" '@example/outside' && pass_case

case_start 'an explicit target package that is not a turbo workspace package fails closed'
dir="$(prepare @example/landing)"
detect "$dir" TARGET_PACKAGES="$(printf '@example/app\n@example/typo\n')"
assert_failed_closed "$dir" '@example/typo' && pass_case

case_start 'scoped names and appDir spellings that name one package are matched once'
dir="$(prepare @example/app)"
package "$dir" packages/app @example/app
detect "$dir" TARGETS='[{"name":"a","appDir":"./packages/app/"},{"name":"b","appDir":"packages/app"}]'
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals true "$(step_output "$dir" affected)" 'affected' \
    && assert_equals 1 "$(grep -c '^@example/app$' "$dir/log")" 'derived name listed once' \
    && pass_case

case_start 'no target-packages and no targets fails closed'
dir="$(prepare)"
detect "$dir"
assert_failed_closed "$dir" 'targets' && pass_case

case_start 'no target-packages and an empty targets array fails closed'
dir="$(prepare)"
detect "$dir" TARGETS='[]'
assert_failed_closed "$dir" 'targets' && pass_case

case_start 'a target whose package.json cannot be read fails closed'
dir="$(prepare)"
package "$dir" packages/app @example/app
detect "$dir" TARGETS="$TARGETS_JSON"
assert_failed_closed "$dir" 'apps/tv/package.json' && pass_case

case_start 'a target package.json without a name fails closed'
dir="$(prepare)"
package "$dir" packages/app @example/app
mkdir -p "$dir/work/apps/tv"
printf '{"private":true}\n' > "$dir/work/apps/tv/package.json"
detect "$dir" TARGETS="$TARGETS_JSON"
assert_failed_closed "$dir" 'apps/tv/package.json' && pass_case

case_start 'a target without an appDir fails closed'
dir="$(prepare)"
detect "$dir" TARGETS='[{"name":"bare"}]'
assert_failed_closed "$dir" 'appDir' && pass_case

case_start 'a target at the repository root fails closed'
dir="$(prepare)"
package "$dir" . @example/root
detect "$dir" TARGETS='[{"name":"bare","appDir":"./"}]'
assert_failed_closed "$dir" 'repository root' && pass_case

case_start 'a missing base SHA reports affected without running turbo'
dir="$(prepare)"
package "$dir" packages/app @example/app
package "$dir" apps/tv @example/tv
detect "$dir" TARGETS="$TARGETS_JSON" TURBO_SCM_BASE=''
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals true "$(step_output "$dir" affected)" 'affected' \
    && assert_equals no "$([ -e "$dir/turbo-ran" ] && echo yes || echo no)" 'turbo ran' \
    && pass_case

case_start 'a turbo failure fails closed'
dir="$(prepare)"
package "$dir" packages/app @example/app
package "$dir" apps/tv @example/tv
stub "$dir" npx 'echo "turbo exploded" >&2; exit 3'
detect "$dir" TARGETS="$TARGETS_JSON"
assert_failed_closed "$dir" 'turbo exploded' && pass_case

case_start 'always-affected reports affected without reading targets'
dir="$(prepare)"
detect "$dir" ALWAYS_AFFECTED=true
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals true "$(step_output "$dir" affected)" 'affected' \
    && pass_case

# Issue #189: an empty turbo-version runs the turbo the repository locks, so a
# turbo.json key newer than a pinned default no longer breaks detection.

# resolve <workspace> [VAR=value ...]
# Runs detection for one explicit target package with turbo-version empty.
resolve() {
    local dir="$1"
    shift
    detect "$dir" TURBO_VERSION='' TARGET_PACKAGES=@example/app "$@"
}

# assert_turbo <workspace> <version>
assert_turbo() {
    local dir="$1" version="$2"
    assert_equals 0 "$STEP_STATUS" 'detect exit status' \
        && assert_equals "turbo@$version" "$(sort -u "$dir/turbo-ran")" 'turbo invoked' \
        && assert_equals "$version" "$(step_output "$dir" turbo-version)" 'turbo-version output'
}

root_manifest() {
    printf '{"name":"root","private":true,"devDependencies":{"turbo":"%s"}}\n' "$2" > "$1/work/package.json"
}

case_start 'turbo-version defaults to empty so the installed turbo is resolved'
if assert_equals '' "$(action_input_default "$ACTION" turbo-version)" 'turbo-version default'; then
    pass_case
fi

case_start 'an explicit turbo-version wins over the lockfile'
dir="$(prepare)"
root_manifest "$dir" '^2.11.0'
printf 'lockfileVersion: %s\n\nimporters:\n\n  .:\n    devDependencies:\n      turbo:\n        specifier: ^2.11.0\n        version: 2.11.0\n' "'9.0'" > "$dir/work/pnpm-lock.yaml"
detect "$dir" TURBO_VERSION=2.9.3 TARGET_PACKAGES=@example/app
assert_turbo "$dir" 2.9.3 && pass_case

case_start 'pnpm-lock.yaml v9: the root importer version is used'
dir="$(prepare)"
root_manifest "$dir" '^2.11.0'
cat > "$dir/work/pnpm-lock.yaml" <<'LOCK'
lockfileVersion: '9.0'

importers:

  .:
    devDependencies:
      prettier:
        specifier: ^3.0.0
        version: 3.3.3
      turbo:
        specifier: ^2.11.0
        version: 2.11.2

  packages/app:
    devDependencies:
      turbo:
        specifier: 2.0.0
        version: 2.0.0

packages:

  turbo-linux-64@2.11.2:
    resolution: {integrity: sha512-x}

  turbo@2.11.2:
    resolution: {integrity: sha512-y}
LOCK
resolve "$dir"
assert_turbo "$dir" 2.11.2 && pass_case

case_start 'pnpm-lock.yaml v6 without importers: the root dependency version is used'
dir="$(prepare)"
root_manifest "$dir" '^2.11.0'
cat > "$dir/work/pnpm-lock.yaml" <<'LOCK'
lockfileVersion: '6.0'

devDependencies:
  turbo:
    specifier: ^2.11.0
    version: 2.11.1

packages:

  /turbo@2.11.1:
    resolution: {integrity: sha512-y}
LOCK
resolve "$dir"
assert_turbo "$dir" 2.11.1 && pass_case

case_start 'pnpm-lock.yaml v5: the inline root dependency version is used, not the specifier'
dir="$(prepare)"
root_manifest "$dir" '^1.13.0'
cat > "$dir/work/pnpm-lock.yaml" <<'LOCK'
lockfileVersion: 5.4

importers:

  .:
    specifiers:
      turbo: ^1.13.0
    devDependencies:
      turbo: 1.13.4

packages:

  /turbo/1.13.4:
    resolution: {integrity: sha512-y}
LOCK
resolve "$dir"
assert_turbo "$dir" 1.13.4 && pass_case

case_start 'pnpm-lock.yaml with turbo only in a workspace package: the single turbo package key is used'
dir="$(prepare)"
cat > "$dir/work/pnpm-lock.yaml" <<'LOCK'
lockfileVersion: '9.0'

importers:

  .: {}

  packages/app:
    devDependencies:
      turbo:
        specifier: ^2.11.0
        version: 2.11.9

packages:

  '@turbo/linux-64@2.11.9':
    resolution: {integrity: sha512-x}

  turbo@2.11.9:
    resolution: {integrity: sha512-y}

snapshots:

  turbo@2.11.9:
    optionalDependencies:
      '@turbo/linux-64': 2.11.9
LOCK
resolve "$dir"
assert_turbo "$dir" 2.11.9 && pass_case

case_start 'package-lock.json: the node_modules/turbo entry is used'
dir="$(prepare)"
root_manifest "$dir" '^2.11.0'
cat > "$dir/work/package-lock.json" <<'LOCK'
{
  "name": "root",
  "lockfileVersion": 3,
  "packages": {
    "": {"name": "root", "devDependencies": {"turbo": "^2.11.0"}},
    "node_modules/turbo": {"version": "2.11.3"},
    "node_modules/turbo-linux-64": {"version": "2.11.3"}
  }
}
LOCK
resolve "$dir"
assert_turbo "$dir" 2.11.3 && pass_case

case_start 'yarn.lock v1: the turbo entry version is used'
dir="$(prepare)"
root_manifest "$dir" '^2.11.0'
cat > "$dir/work/yarn.lock" <<'LOCK'
# THIS IS AN AUTOGENERATED FILE. DO NOT EDIT THIS FILE DIRECTLY.
# yarn lockfile v1


turbo-linux-64@2.11.4:
  version "2.11.4"

"turbo@^2.11.0", turbo@^2.11.4:
  version "2.11.4"
  resolved "https://registry.yarnpkg.com/turbo/-/turbo-2.11.4.tgz"
LOCK
resolve "$dir"
assert_turbo "$dir" 2.11.4 && pass_case

case_start 'yarn.lock berry: the turbo@npm entry version is used'
dir="$(prepare)"
root_manifest "$dir" '^2.11.0'
cat > "$dir/work/yarn.lock" <<'LOCK'
__metadata:
  version: 8
  cacheKey: 10c0

"turbo-linux-64@npm:2.11.5":
  version: 2.11.5
  languageName: node

"turbo@npm:^2.11.0":
  version: 2.11.5
  resolution: "turbo@npm:2.11.5"
LOCK
resolve "$dir"
assert_turbo "$dir" 2.11.5 && pass_case

case_start 'bun.lock: the turbo package entry is used'
dir="$(prepare)"
root_manifest "$dir" '^2.11.0'
cat > "$dir/work/bun.lock" <<'LOCK'
{
  "lockfileVersion": 1,
  "workspaces": {
    "": {
      "name": "root",
      "devDependencies": {
        "turbo": "^2.11.0",
      },
    },
  },
  "packages": {
    "turbo": ["turbo@2.11.6", "", { "optionalDependencies": { "turbo-linux-64": "2.11.6" } }, "sha512-x"],
  },
}
LOCK
resolve "$dir"
assert_turbo "$dir" 2.11.6 && pass_case

case_start 'an installed node_modules/turbo wins over the lockfile'
dir="$(prepare)"
root_manifest "$dir" '^2.11.0'
printf '{"packages":{"node_modules/turbo":{"version":"2.11.3"}}}\n' > "$dir/work/package-lock.json"
mkdir -p "$dir/work/node_modules/turbo"
printf '{"name":"turbo","version":"2.11.7"}\n' > "$dir/work/node_modules/turbo/package.json"
resolve "$dir"
assert_turbo "$dir" 2.11.7 && pass_case

case_start 'an exact root package.json turbo is used when there is no lockfile'
dir="$(prepare)"
root_manifest "$dir" '2.11.8'
resolve "$dir"
assert_turbo "$dir" 2.11.8 && pass_case

case_start 'a turbo range with no lockfile falls back to the pinned default with a notice'
dir="$(prepare)"
root_manifest "$dir" '^2.11.0'
resolve "$dir"
assert_turbo "$dir" 2.10.8 \
    && assert_contains "$(cat "$dir/log")" '::notice::' 'fallback notice' \
    && pass_case

case_start 'an explicit turbo-version that is not a semver fails closed before turbo runs'
dir="$(prepare)"
detect "$dir" TURBO_VERSION='2.11.0 && curl evil' TARGET_PACKAGES=@example/app
assert_failed_closed "$dir" '::error::' \
    && assert_equals no "$([ -e "$dir/turbo-ran" ] && echo yes || echo no)" 'turbo ran' \
    && pass_case

case_start 'a locked turbo version that is not a semver fails closed before turbo runs'
dir="$(prepare)"
printf '{"packages":{"node_modules/turbo":{"version":"latest;id"}}}\n' > "$dir/work/package-lock.json"
resolve "$dir"
assert_failed_closed "$dir" 'latest;id' \
    && assert_equals no "$([ -e "$dir/turbo-ran" ] && echo yes || echo no)" 'turbo ran' \
    && pass_case

case_start 'a turbo failure reports an error with the turbo version and its stderr'
dir="$(prepare)"
stub "$dir" npx 'echo "x Found an unknown key agentGuidance." >&2; exit 1'
detect "$dir" TARGET_PACKAGES=@example/app
assert_failed_closed "$dir" '::error::' \
    && assert_contains "$(grep '::error::' "$dir/log")" 'turbo@2.10.8' 'version in error' \
    && assert_contains "$(grep '::error::' "$dir/log")" 'agentGuidance' 'stderr in error' \
    && pass_case

case_start 'turbo printing no JSON reports an error with the turbo version and its stderr'
dir="$(prepare)"
stub "$dir" npx 'echo "warning: something odd" >&2; echo "not json"'
detect "$dir" TARGET_PACKAGES=@example/app
assert_failed_closed "$dir" '::error::' \
    && assert_contains "$(grep '::error::' "$dir/log")" 'turbo@2.10.8' 'version in error' \
    && assert_contains "$(grep '::error::' "$dir/log")" 'something odd' 'stderr in error' \
    && pass_case

# Issue #191: a pull request whose every changed file matches an exempt-paths
# glob is unaffected without running turbo; anything uncertain runs turbo.

# exempt_repo <workspace> <changed path...>
# Commits a base and then a change touching the given paths in ./work, a real
# git repository so the exemption is decided by git's own pathspec matching.
# Prints the base SHA.
exempt_repo() {
    local dir="$1" path
    shift
    (
        cd "$dir/work"
        git init -q -b main
        git config user.email fixture@example.com
        git config user.name Fixture
        mkdir -p docs packages/app
        printf 'base\n' > README.md
        printf 'base\n' > docs/guide.md
        printf 'base\n' > packages/app/index.js
        git add -A
        git commit -qm base
        for path in "$@"; do
            mkdir -p "$(dirname "$path")"
            printf 'change\n' >> "$path"
        done
        git add -A
        git commit -qm change
    ) > "$dir/git-log" 2>&1
    git -C "$dir/work" rev-parse HEAD~1
}

case_start 'exempt-paths defaults to empty'
if ! default="$(action_input_default "$ACTION" exempt-paths)"; then
    fail_case 'action.yml declares no exempt-paths input'
elif assert_equals '' "$default" 'exempt-paths default'; then
    pass_case
fi

case_start 'a pull request changing only exempt paths is unaffected without running turbo'
dir="$(prepare @example/app)"
base="$(exempt_repo "$dir" README.md docs/guide.md docs/new/page.md)"
detect "$dir" TARGET_PACKAGES=@example/app TURBO_SCM_BASE="$base" EXEMPT_PATHS="$(printf 'docs/**\n**/*.md\n')"
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals false "$(step_output "$dir" affected)" 'affected' \
    && assert_equals no "$([ -e "$dir/turbo-ran" ] && echo yes || echo no)" 'turbo ran' \
    && assert_contains "$(cat "$dir/log")" 'docs/new/page.md' 'exempt file logged' \
    && assert_contains "$(cat "$dir/log")" '**/*.md' 'exempt glob logged' \
    && pass_case

case_start 'a comma-separated exempt-paths list is honoured'
dir="$(prepare @example/app)"
base="$(exempt_repo "$dir" README.md docs/guide.md)"
detect "$dir" TARGET_PACKAGES=@example/app TURBO_SCM_BASE="$base" EXEMPT_PATHS='docs/**, README.md'
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals false "$(step_output "$dir" affected)" 'affected' \
    && assert_equals no "$([ -e "$dir/turbo-ran" ] && echo yes || echo no)" 'turbo ran' \
    && pass_case

case_start 'a pull request with one non-exempt file runs turbo detection'
dir="$(prepare @example/app)"
base="$(exempt_repo "$dir" docs/guide.md packages/app/index.js)"
detect "$dir" TARGET_PACKAGES=@example/app TURBO_SCM_BASE="$base" EXEMPT_PATHS='docs/**'
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals true "$(step_output "$dir" affected)" 'affected' \
    && assert_equals yes "$([ -e "$dir/turbo-ran" ] && echo yes || echo no)" 'turbo ran' \
    && pass_case

case_start 'a glob without ** does not exempt a nested file'
dir="$(prepare @example/app)"
base="$(exempt_repo "$dir" packages/app/README.md)"
detect "$dir" TARGET_PACKAGES=@example/app TURBO_SCM_BASE="$base" EXEMPT_PATHS='*.md'
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals true "$(step_output "$dir" affected)" 'affected' \
    && assert_equals yes "$([ -e "$dir/turbo-ran" ] && echo yes || echo no)" 'turbo ran' \
    && pass_case

case_start 'a file moved from a non-exempt path into an exempt one runs turbo detection'
dir="$(prepare @example/app)"
base="$(exempt_repo "$dir" docs/guide.md)"
(
    cd "$dir/work"
    git mv packages/app/index.js docs/index.js
    git commit -qm 'move the app entry into docs'
) >> "$dir/git-log" 2>&1
detect "$dir" TARGET_PACKAGES=@example/app TURBO_SCM_BASE="$base" EXEMPT_PATHS='docs/**'
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals true "$(step_output "$dir" affected)" 'affected' \
    && assert_equals yes "$([ -e "$dir/turbo-ran" ] && echo yes || echo no)" 'turbo ran' \
    && pass_case

case_start 'a base SHA git cannot diff against runs turbo detection instead of exempting'
dir="$(prepare @example/app)"
exempt_repo "$dir" docs/guide.md > /dev/null
detect "$dir" TARGET_PACKAGES=@example/app TURBO_SCM_BASE=0123456789abcdef0123456789abcdef01234567 EXEMPT_PATHS='docs/**'
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals true "$(step_output "$dir" affected)" 'affected' \
    && assert_equals yes "$([ -e "$dir/turbo-ran" ] && echo yes || echo no)" 'turbo ran' \
    && assert_contains "$(cat "$dir/log")" '::warning::' 'diff failure warned' \
    && pass_case

case_start 'an empty diff is not exempt and runs turbo detection'
dir="$(prepare)"
exempt_repo "$dir" docs/guide.md > /dev/null
detect "$dir" TARGET_PACKAGES=@example/app TURBO_SCM_BASE="$(git -C "$dir/work" rev-parse HEAD)" EXEMPT_PATHS='docs/**'
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals false "$(step_output "$dir" affected)" 'affected' \
    && assert_equals yes "$([ -e "$dir/turbo-ran" ] && echo yes || echo no)" 'turbo ran' \
    && pass_case

case_start 'always-affected wins over exempt-paths'
dir="$(prepare)"
detect "$dir" ALWAYS_AFFECTED=true EXEMPT_PATHS='**'
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals true "$(step_output "$dir" affected)" 'affected' \
    && pass_case

# v3.3.0 gated every pull request through turbo, removing v3.2.0's "empty
# target-packages runs every pull request" escape hatch, and turbo never lists
# a file outside a workspace package (the caller's own workflow, a .github/
# config) as affecting anything. trigger-paths runs the pipeline whenever a
# matching file changed.

case_start 'trigger-paths defaults to empty'
if ! default="$(action_input_default "$ACTION" trigger-paths)"; then
    fail_case 'action.yml declares no trigger-paths input'
elif assert_equals '' "$default" 'trigger-paths default'; then
    pass_case
fi

case_start 'a changed file outside every package that matches trigger-paths is affected without running turbo'
dir="$(prepare)"
base="$(exempt_repo "$dir" .github/workflows/media-smoke.yml)"
detect "$dir" TARGET_PACKAGES=@example/app TURBO_SCM_BASE="$base" TRIGGER_PATHS="$(printf '.github/workflows/media-smoke.yml\n.github/landing-media.config.json\n')"
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals true "$(step_output "$dir" affected)" 'affected' \
    && assert_equals no "$([ -e "$dir/turbo-ran" ] && echo yes || echo no)" 'turbo ran' \
    && assert_contains "$(cat "$dir/log")" '.github/workflows/media-smoke.yml' 'triggering file logged' \
    && pass_case

case_start 'trigger-paths ** runs every pull request that changes anything'
dir="$(prepare)"
base="$(exempt_repo "$dir" docs/guide.md)"
detect "$dir" TARGET_PACKAGES=@example/app TURBO_SCM_BASE="$base" TRIGGER_PATHS='**'
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals true "$(step_output "$dir" affected)" 'affected' \
    && assert_equals no "$([ -e "$dir/turbo-ran" ] && echo yes || echo no)" 'turbo ran' \
    && pass_case

case_start 'trigger-paths ** runs a pull request whose diff is empty'
dir="$(prepare)"
exempt_repo "$dir" docs/guide.md > /dev/null
detect "$dir" TARGET_PACKAGES=@example/app TURBO_SCM_BASE="$(git -C "$dir/work" rev-parse HEAD)" TRIGGER_PATHS='docs/**, **'
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals true "$(step_output "$dir" affected)" 'affected' \
    && assert_equals no "$([ -e "$dir/turbo-ran" ] && echo yes || echo no)" 'turbo ran' \
    && pass_case

case_start 'a comma-separated trigger-paths list is honoured'
dir="$(prepare)"
base="$(exempt_repo "$dir" README.md)"
detect "$dir" TARGET_PACKAGES=@example/app TURBO_SCM_BASE="$base" TRIGGER_PATHS='docs/**, README.md'
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals true "$(step_output "$dir" affected)" 'affected' \
    && assert_equals no "$([ -e "$dir/turbo-ran" ] && echo yes || echo no)" 'turbo ran' \
    && pass_case

case_start 'no changed file matching trigger-paths falls through to turbo detection'
dir="$(prepare)"
base="$(exempt_repo "$dir" packages/app/index.js)"
detect "$dir" TARGET_PACKAGES=@example/app TURBO_SCM_BASE="$base" TRIGGER_PATHS='.github/**'
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals false "$(step_output "$dir" affected)" 'affected' \
    && assert_equals yes "$([ -e "$dir/turbo-ran" ] && echo yes || echo no)" 'turbo ran' \
    && pass_case

case_start 'trigger-paths wins over exempt-paths for a file both match'
dir="$(prepare)"
base="$(exempt_repo "$dir" docs/guide.md)"
detect "$dir" TARGET_PACKAGES=@example/app TURBO_SCM_BASE="$base" EXEMPT_PATHS='docs/**' TRIGGER_PATHS='docs/guide.md'
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals true "$(step_output "$dir" affected)" 'affected' \
    && pass_case

case_start 'a file moved out of a trigger path still triggers'
dir="$(prepare)"
base="$(exempt_repo "$dir" README.md)"
(
    cd "$dir/work"
    mkdir -p .github
    printf 'base\n' > .github/flows.json
    git add -A
    git commit -qm 'add flows config'
) >> "$dir/git-log" 2>&1
base="$(git -C "$dir/work" rev-parse HEAD)"
(
    cd "$dir/work"
    git mv .github/flows.json packages/app/flows.json
    git commit -qm 'move the flows config'
) >> "$dir/git-log" 2>&1
detect "$dir" TARGET_PACKAGES=@example/app TURBO_SCM_BASE="$base" TRIGGER_PATHS='.github/**'
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals true "$(step_output "$dir" affected)" 'affected' \
    && pass_case

case_start 'a base SHA git cannot diff against reports affected rather than guessing no trigger matched'
dir="$(prepare)"
exempt_repo "$dir" docs/guide.md > /dev/null
detect "$dir" TARGET_PACKAGES=@example/app TURBO_SCM_BASE=0123456789abcdef0123456789abcdef01234567 TRIGGER_PATHS='.github/**'
assert_equals 0 "$STEP_STATUS" 'detect exit status' \
    && assert_equals true "$(step_output "$dir" affected)" 'affected' \
    && assert_contains "$(cat "$dir/log")" '::warning::' 'diff failure warned' \
    && pass_case

# Issue #224: a force label on the pull request runs the pipeline whatever
# turbo says, and says so, so a reviewer can force an e2e run on a change
# turbo cannot see without editing trigger-paths.
label_event() {
    local dir="$1"
    shift
    printf '{"pull_request": {"labels": [%s]}}' "$(printf '{"name": "%s"},' "$@" | sed 's/,$//')" > "$dir/event.json"
}

case_start 'a force label on the pull request reports affected and forced without running turbo'
dir="$(prepare)"
label_event "$dir" bug 'e2e:force'
detect "$dir" TARGET_PACKAGES=@example/app FORCE_LABEL='e2e:force' GITHUB_EVENT_PATH="$dir/event.json" EXEMPT_PATHS='**'
assert_equals 0 "$STEP_STATUS" "detect exit status ($(cat "$dir/log"))" \
    && assert_equals true "$(step_output "$dir" affected)" 'affected' \
    && assert_equals true "$(step_output "$dir" forced)" 'forced' \
    && assert_equals no "$([ -e "$dir/turbo-ran" ] && echo yes || echo no)" 'turbo ran' \
    && pass_case

case_start 'without the force label, detection runs as usual and forced is false'
dir="$(prepare)"
label_event "$dir" bug
detect "$dir" TARGET_PACKAGES=@example/app FORCE_LABEL='e2e:force' GITHUB_EVENT_PATH="$dir/event.json"
assert_equals 0 "$STEP_STATUS" "detect exit status ($(cat "$dir/log"))" \
    && assert_equals false "$(step_output "$dir" affected)" 'affected' \
    && assert_equals false "$(step_output "$dir" forced)" 'forced' \
    && assert_equals yes "$([ -e "$dir/turbo-ran" ] && echo yes || echo no)" 'turbo ran' \
    && pass_case

case_start 'an event with no pull request never forces'
dir="$(prepare)"
printf '{"ref": "refs/heads/main"}' > "$dir/event.json"
detect "$dir" TARGET_PACKAGES=@example/app FORCE_LABEL='e2e:force' GITHUB_EVENT_PATH="$dir/event.json"
assert_equals 0 "$STEP_STATUS" "detect exit status ($(cat "$dir/log"))" \
    && assert_equals false "$(step_output "$dir" forced)" 'forced' \
    && pass_case

case_start 'an unreadable event payload with a force label set fails closed'
dir="$(prepare)"
printf 'not json' > "$dir/event.json"
detect "$dir" TARGET_PACKAGES=@example/app FORCE_LABEL='e2e:force' GITHUB_EVENT_PATH="$dir/event.json"
assert_equals 1 "$STEP_STATUS" 'detect exit status' \
    && assert_contains "$(cat "$dir/log")" '::error::' 'error' \
    && pass_case

for workflow in ios-maestro android-maestro; do
    case_start "$workflow.yml passes force-label to turbo-affected and reports a forced run"
    if failure="$(WORKFLOW_YML="$REPO_ROOT/.github/workflows/$workflow.yml" python3 - <<'PYTHON' 2>&1
import os
import sys

import yaml

workflow = yaml.safe_load(open(os.environ['WORKFLOW_YML'], encoding='utf-8'))
inputs = workflow[True]['workflow_call']['inputs']
problems = []
if inputs.get('force-label', {}).get('default', 'MISSING') != '':
    problems.append('force-label must be an input defaulting to empty')
step = next(step for step in workflow['jobs']['detect']['steps'] if 'turbo-affected' in step.get('uses', ''))
if step['with'].get('force-label') != '${{ inputs.force-label }}':
    problems.append('turbo-affected does not receive force-label')
if workflow['jobs']['detect'].get('outputs', {}).get('forced') != '${{ steps.affected.outputs.forced }}':
    problems.append('detect does not output forced')
report = workflow['jobs']['status']['steps'][0]
if report.get('env', {}).get('DETECT_FORCED') != '${{ needs.detect.outputs.forced }}':
    problems.append('status does not read needs.detect.outputs.forced')
if 'forced' not in report.get('run', ''):
    problems.append('status never reports forced')
if problems:
    sys.exit('; '.join(problems))
PYTHON
)"; then
        pass_case
    else
        fail_case "$failure"
    fi
done

for workflow in ios-maestro android-maestro; do
    case_start "$workflow.yml hands its targets to turbo-affected and is always affected only off pull requests"
    wiring="$(WORKFLOW_YML="$REPO_ROOT/.github/workflows/$workflow.yml" python3 - <<'PYTHON'
import os

import yaml

workflow = yaml.safe_load(open(os.environ['WORKFLOW_YML'], encoding='utf-8'))
step = next(step for step in workflow['jobs']['detect']['steps'] if 'turbo-affected' in step.get('uses', ''))
print(step['with'].get('targets', ''))
print(step['with'].get('always-affected', ''))
print(step['with'].get('exempt-paths', ''))
print(workflow.get('on', workflow.get(True))['workflow_call']['inputs'].get('exempt-paths', {}).get('default', 'MISSING'))
print(step['with'].get('trigger-paths', ''))
print(workflow.get('on', workflow.get(True))['workflow_call']['inputs'].get('trigger-paths', {}).get('default', 'MISSING'))
PYTHON
)"
    # shellcheck disable=SC2016 # the expressions are matched literally.
    assert_equals "$(printf '%s\n%s\n%s\n\n%s\n' '${{ inputs.targets }}' "\${{ github.event_name != 'pull_request' }}" '${{ inputs.exempt-paths }}' '${{ inputs.trigger-paths }}')" "$wiring" 'turbo-affected with:' \
        && pass_case
done

finish_suite
