# `simctl` fixtures

JSON exactly as `xcrun simctl list devicetypes|runtimes|devices -j` prints it,
trimmed to the fields the actions read. `tests/simulator-lease_test.sh` serves
these from a stubbed `xcrun`, so the step scripts under test run their real
`jq` filters against real `simctl` shapes without a Mac.
