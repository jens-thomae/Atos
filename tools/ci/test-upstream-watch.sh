#!/usr/bin/env bash
# Run: bash tools/ci/test-upstream-watch.sh  (local fake upstream, stubbed gh, DRY_RUN)
set -eu
d=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
g() { git -C "$t/up" -c user.name=t -c user.email=t@t "$@"; }
git init -q -b master "$t/up"
g commit -q --allow-empty -m "init"; g tag -a epoch-1.11.0 -m x
g commit -q --allow-empty -m "Fix use-after-free in seat handling"
g commit -q --allow-empty -m "Add wallpaper option"
g tag -a epoch-1.12.0 -m x
mkdir "$t/bin"
# Stub: one existing issue (the 1.12.0 merge card) so the dedup path is exercised.
printf '#!/bin/sh\necho %s\n' "'[{\"title\":\"C2: merge epoch-1.12.0\",\"createdAt\":\"2026-01-01T00:00:00Z\"}]'" > "$t/bin/gh"
chmod +x "$t/bin/gh"
out=$(PATH="$t/bin:$PATH" UPSTREAM="$t/up" DRY_RUN=true bash "$d/upstream-watch.sh")
echo "$out" | grep -q '^exists: C2: merge epoch-1.12.0$' || { echo "FAIL dedup: $out"; exit 1; }
echo "$out" | grep -q '^would open: C2: cherry-pick upstream fix ' || { echo "FAIL commit hit: $out"; exit 1; }
[ "$(echo "$out" | grep -c 'cherry-pick')" = 1 ] || { echo "FAIL false positive: $out"; exit 1; }
# Old tag (fork_days=0) -> fallback issue.
out=$(PATH="$t/bin:$PATH" UPSTREAM="$t/up" DRY_RUN=true FALLBACK_DAYS=-1 bash "$d/upstream-watch.sh")
echo "$out" | grep -q '^would open: C2: merge master (fallback)$' || { echo "FAIL fallback: $out"; exit 1; }
echo ok
