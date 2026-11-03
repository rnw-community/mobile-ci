# Each command below pipes into a grep that can exit before its producer has
# written everything; tests/pipe-early-exit_test.sh expects the lint to report
# each of the 12 once.
if git ls-remote origin | grep -q .; then :; fi
! printf '%s\n' "$list" | grep -qxF -- "$name"
printf '%s' "$v" | grep -Eq '^[0-9]+$' || exit 1
adb devices | awk '{ print $1 }' | grep -Fxq "$serial"
log show | grep --quiet amfid
find . | xargs cat | grep -m1 x
find . | grep -l x
cmd | grep -L x
cmd |    command grep -q x
cmd | egrep -q x
cmd |
    grep -q x
cmd \
    | grep -qF -e x
