#!/bin/sh
# Runs every tests/_test_*.lua in its own interpreter.
LUA="${LUA:-luajit}"
cd "$(dirname "$0")/.." || exit 1
fail=0
ran=0
for t in tests/_test_*.lua; do
    [ -f "$t" ] || continue
    ran=$((ran + 1))
    out=$("$LUA" "$t" 2>&1)
    rc=$?
    name=$(basename "$t")
    if [ $rc -ne 0 ] || echo "$out" | grep -q "^FAIL"; then
        fail=$((fail + 1))
        printf 'FAIL  %-32s\n' "$name"
        echo "$out" | sed 's/^/      /'
    else
        printf 'ok    %-32s %s\n' "$name" "$(echo "$out" | tail -1)"
    fi
done
echo "------------------------------------------------------------"
echo "ran $ran suites, $fail failed"
[ $fail -eq 0 ]
