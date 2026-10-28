#!/usr/bin/env bash
# junit-failure.sh <output.xml> <suite name> <test case name> <failure message>
#
# Writes a one-test-case JUnit report recording a failure. The run-maestro-*
# actions write it in place of Maestro's own `--format junit` report when a
# flow's final attempt produced none (its pre-flow-command failed, or Maestro
# died before reporting), so a failed flow is never missing from the shard's
# JUnit output.
set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "::error::usage: junit-failure.sh <output.xml> <suite name> <test case name> <failure message>" >&2
    exit 1
fi

xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

suite="$(xml_escape "$2")"
name="$(xml_escape "$3")"
message="$(xml_escape "$4")"
mkdir -p "$(dirname "$1")"
{
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<testsuites>\n'
    printf '  <testsuite name="%s" tests="1" failures="1">\n' "$suite"
    printf '    <testcase id="%s" name="%s" classname="%s" status="ERROR">\n' "$name" "$name" "$name"
    printf '      <failure message="%s"/>\n' "$message"
    printf '    </testcase>\n'
    printf '  </testsuite>\n'
    printf '</testsuites>\n'
} > "$1"
