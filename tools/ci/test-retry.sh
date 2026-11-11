#!/usr/bin/env bash
# Run: bash tools/ci/test-retry.sh
set -eu
r="$(dirname "$0")/retry.sh"
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
# fails the first $1 calls with exit 7, then succeeds; counts calls in $t/n
# shellcheck disable=SC2016 # the $ expressions belong to the generated script
printf '#!/bin/sh\nc=$(($(cat %s/n 2>/dev/null || echo 0) + 1)); echo $c > %s/n; [ $c -gt $1 ] || exit 7\n' "$t" "$t" > "$t/flaky"
chmod +x "$t/flaky"
run() { rm -f "$t/n"; rc=0; RETRY_ATTEMPTS=3 RETRY_DELAY=0 bash "$r" "$t/flaky" "$1" 2>/dev/null || rc=$?; }
run 0; [ "$rc" = 0 ] && [ "$(cat "$t/n")" = 1 ] || { echo "FAIL: success at once"; exit 1; }
run 2; [ "$rc" = 0 ] && [ "$(cat "$t/n")" = 3 ] || { echo "FAIL: passes after 2 failures"; exit 1; }
run 3; [ "$rc" = 7 ] && [ "$(cat "$t/n")" = 3 ] || { echo "FAIL: must fail with exit 7 after 3 tries (rc $rc)"; exit 1; }
# arguments pass through unchanged, spaces included
rc=0; RETRY_DELAY=0 bash "$r" test "a b" = "a b" || rc=$?; [ "$rc" = 0 ] || { echo "FAIL: arguments"; exit 1; }
echo ok
