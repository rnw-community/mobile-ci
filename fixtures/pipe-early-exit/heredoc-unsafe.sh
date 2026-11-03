#!/usr/bin/env bash
# Each substitution holds one heredoc with more shell after it on the line.
text=a
first="$({
    if ! grep -q a <<EOF; then
$text
EOF
        echo miss
    fi
    echo end
} 2>&1)"
second="$(grep -q a <<'EOF' && echo hit
a
EOF
)"
third=$(cat <<EOF | tr a b
$text
EOF
)
printf '%s %s %s\n' "$first" "$second" "$third"
