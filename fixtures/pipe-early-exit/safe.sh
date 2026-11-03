# None of these pipe into an early-exiting grep; the lint must report nothing.
grep -q x <<EOF
$(cmd)
EOF
grep -qxF "$name" file
cmd | grep -c x
cmd | grep -E -o 'a|b'
cmd | grep -e -q
cmd | grep -- -q
true || grep -q x file
cmd 2>&1 | tee log
# cmd | grep -q x
grep -rl pattern dir | sort
[ -n "$(git ls-remote origin)" ]
cmd | grep -equality
