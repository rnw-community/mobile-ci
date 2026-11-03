#!/usr/bin/env bash
# A heredoc alone in a substitution, one outside any, and a here-string are fine.
text=a
inside="$(cat <<EOF
$text
EOF
)"
redirected="$(python3 - <<'PY' 2>&1
print("$(not a substitution; <<EOF; here)")
PY
)"
if ! grep -q a <<EOF; then
$text
EOF
    echo miss
fi
herestring="$(if ! grep -q a <<<"$text"; then echo miss; fi; echo end)"
quoted="$(echo 'a <<EOF; b')"
printf '%s %s %s %s\n' "$inside" "$redirected" "$herestring" "$quoted"
