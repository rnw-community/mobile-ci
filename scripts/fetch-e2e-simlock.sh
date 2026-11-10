#!/usr/bin/env bash
# Installs @mobile-ci/e2e-simlock (packages/e2e-simlock) into an e2e project's
# node_modules. Run it to fetch the package at a pinned mobile-ci tag or commit:
#
#   fetch-e2e-simlock.sh v4.12.3 e2e
#
# or source it for e2e_simlock_install, which the e2e-simlock-install action
# calls with the package from its own ref. Run it after the project's own
# install (npm ci and the like replace node_modules wholesale).

# e2e_simlock_install <package dir> <e2e dir>
e2e_simlock_install() {
    local package_dir="$1" e2e_dir="$2" dest entry entries
    if [ ! -f "$package_dir/package.json" ]; then
        echo "e2e-simlock: no package at '$package_dir' (expected packages/e2e-simlock of rnw-community/mobile-ci)." >&2
        return 1
    fi
    if [ ! -d "$e2e_dir/node_modules" ]; then
        echo "e2e-simlock: '$e2e_dir' has no node_modules; install the e2e project's dependencies first, or its install would wipe the package." >&2
        return 1
    fi
    if ! entries="$(jq -er '.files[]' "$package_dir/package.json")"; then
        echo "e2e-simlock: could not read the files '$package_dir/package.json' ships; is jq installed?" >&2
        return 1
    fi
    dest="$e2e_dir/node_modules/@mobile-ci/e2e-simlock"
    rm -rf "$dest"
    mkdir -p "$dest"
    cp "$package_dir/package.json" "$dest/"
    while IFS= read -r entry; do
        if [ ! -e "$package_dir/$entry" ]; then
            echo "e2e-simlock: '$package_dir' lacks '$entry', which its package.json ships." >&2
            return 1
        fi
        cp -R "$package_dir/$entry" "$dest/"
    done <<<"$entries"
    echo "Installed @mobile-ci/e2e-simlock into $dest."
}

# e2e_simlock_fetch <tag or commit SHA> <e2e dir>
e2e_simlock_fetch() {
    local ref="$1" e2e_dir="$2" scratch status=0
    if ! [[ "$ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ || "$ref" =~ ^[0-9a-f]{40}$ ]]; then
        echo "e2e-simlock: pin a release tag (vX.Y.Z) or a full commit SHA; got '$ref'." >&2
        return 1
    fi
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/mobile-ci-e2e-simlock-XXXXXX")"
    if ! curl -fsSL "https://codeload.github.com/rnw-community/mobile-ci/tar.gz/$ref" | tar -xz -C "$scratch" --strip-components=1; then
        echo "e2e-simlock: could not download rnw-community/mobile-ci at '$ref'." >&2
        status=1
    else
        e2e_simlock_install "$scratch/packages/e2e-simlock" "$e2e_dir" || status=$?
    fi
    rm -rf "$scratch"
    return "$status"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    if [ "$#" -ne 2 ]; then
        echo "usage: $0 <mobile-ci tag or commit SHA> <e2e dir>" >&2
        exit 2
    fi
    e2e_simlock_fetch "$1" "$2"
fi
