#!/usr/bin/env bash
# select-flows-by-tags.sh <workspace-config-or-empty> <include-tags> <exclude-tags> <flow>...
#
# Prints the flows Maestro's own tag filter would keep, one per line, in input
# order. include/exclude are comma-separated; the workspace config's
# includeTags/excludeTags are added to them, as `maestro test <dir>` does.
#
# The YAML is read by MaestroTagSelection.java, run with the Java source
# launcher against the lib/ directory of the `maestro` on PATH, so the parser
# is the Jackson YAML parser Maestro itself uses and nothing else has to be
# installed on the runner beyond the JDK Maestro already needs. Any failure -
# no maestro, no JDK, an unparsable config section - exits non-zero: the
# caller must never run an unfiltered shard in place of a filtered one.
set -euo pipefail

if [ "$#" -lt 4 ]; then
    echo "::error::usage: select-flows-by-tags.sh <workspace-config-or-empty> <include-tags> <exclude-tags> <flow>..." >&2
    exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

maestro_bin="$(command -v maestro || true)"
if [ -z "$maestro_bin" ]; then
    echo "::error::Selecting flows by tag needs the Maestro CLI on PATH (its bundled YAML parser reads each flow's tags), but 'maestro' was not found." >&2
    exit 1
fi
hops=0
while [ -L "$maestro_bin" ]; do
    hops=$((hops + 1))
    if [ "$hops" -gt 40 ]; then
        echo "::error::'maestro' on PATH is a symlink loop; cannot locate the Maestro CLI's lib/ directory." >&2
        exit 1
    fi
    link="$(readlink "$maestro_bin")"
    case "$link" in
        /*) maestro_bin="$link" ;;
        *) maestro_bin="$(dirname "$maestro_bin")/$link" ;;
    esac
done
maestro_lib="$(dirname "$maestro_bin")/../lib"
if ! ls "$maestro_lib"/jackson-dataformat-yaml-*.jar > /dev/null 2>&1; then
    echo "::error::Selecting flows by tag reads YAML with the Jackson jars bundled in the Maestro CLI, but '$maestro_lib' (next to '$maestro_bin') holds no jackson-dataformat-yaml jar." >&2
    exit 1
fi

java_bin=java
if [ -n "${JAVA_HOME:-}" ]; then
    java_bin="$JAVA_HOME/bin/java"
fi
if ! command -v "$java_bin" > /dev/null 2>&1; then
    echo "::error::Selecting flows by tag needs the Java that runs Maestro, but '$java_bin' was not found." >&2
    exit 1
fi

if ! "$java_bin" -cp "$maestro_lib/*" "$script_dir/MaestroTagSelection.java" "$@"; then
    echo "::error::Selecting flows by tag failed (see above). MaestroTagSelection.java runs on the Java source launcher, which needs a full JDK (not a JRE) on the runner." >&2
    exit 1
fi
