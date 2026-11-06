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
old=$(( $(date +%s) - 100 * 86400 ))
GIT_COMMITTER_DATE="$old +0000" g tag -a epoch-1.12.0 -m x # newest tag is 100 days old
mkdir "$t/bin"
# Stub: one existing issue (the 1.12.0 merge card) so the dedup path is exercised.
printf '#!/bin/sh\ncat "$STUB_ISSUES"\n' > "$t/bin/gh"
printf '[{"title":"C2: merge epoch-1.12.0","createdAt":"2026-01-01T00:00:00Z"}]' > "$t/i1"
chmod +x "$t/bin/gh"
out=$(STUB_ISSUES=$t/i1 FORK_TAG=epoch-1.11.0 PATH="$t/bin:$PATH" UPSTREAM="$t/up" DRY_RUN=true bash "$d/upstream-watch.sh")
echo "$out" | grep -q '^exists: C2: merge epoch-1.12.0$' || { echo "FAIL dedup: $out"; exit 1; }
echo "$out" | grep -q '^would open: C2: cherry-pick upstream fix ' || { echo "FAIL commit hit: $out"; exit 1; }
[ "$(echo "$out" | grep -c 'cherry-pick')" = 1 ] || { echo "FAIL false positive: $out"; exit 1; }
# Fallback: newest tag is 100 days old. A fallback card from 100 days ago is outside the 90-day window
# (opens again); one from 10 days ago is inside it (exists).
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
now=$(date +%s)
run() { printf '[{"title":"C2: merge master (fallback)","createdAt":"%s"}]' "$(iso "$1")" > "$t/i2"
  STUB_ISSUES=$t/i2 FORK_TAG=epoch-1.12.0 PATH="$t/bin:$PATH" UPSTREAM="$t/up" DRY_RUN=true bash "$d/upstream-watch.sh"; }
run $(( now - 100 * 86400 )) | grep -q '^would open: C2: merge master (fallback)$' || { echo "FAIL fallback reopen"; exit 1; }
run $(( now - 10 * 86400 )) | grep -q '^exists: C2: merge master (fallback)$' || { echo "FAIL fallback dedup"; exit 1; }
echo ok
