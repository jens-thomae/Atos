#!/bin/bash
# Test for gc.sh against a temporary tree with spaces in names. Runs anywhere with bash.
set -euo pipefail
GC="$(cd "$(dirname "$0")" && pwd)/gc.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
M="$T/mount/My Repo"; TG="$T/target"; OUT="$T/outside"
mkdir -p "$M/live one" "$M/.claude/worktrees/live two" "$OUT/other checkout"
# caches: live (with space), live prefix-clash, stale (with space + odd chars), outside mount, nested stale
mk() { mkdir -p "$TG$1/debug" && touch "$TG$1/.rustc_info.json" "$TG$1/debug/data"; }
mk "$M/live one"; mk "$M/.claude/worktrees/live two"; mk "$M/live"            # "live" is stale, "live one" must survive
mk "$M/gone 'x' \$(y)"; mk "$M/.claude/worktrees/gone two"; mk "$OUT/other checkout"; mk "$OUT/never existed"
touch "$T/canary" "$M/live one/canary"
cd "$M/live one"   # a stray relative rm would hit here
GC_TARGET_ROOT="$TG" GC_MOUNT_ROOT="$T/mount/My Repo" GC_MIN_FREE_KB=0 "$GC" 2>"$T/err"
ok() { [ -e "$1" ] || { echo "FAIL: $1 missing"; exit 1; }; }
gone() { [ ! -e "$1" ] || { echo "FAIL: $1 still exists"; exit 1; }; }
ok "$TG$M/live one/.rustc_info.json"; ok "$TG$M/.claude/worktrees/live two/.rustc_info.json"
gone "$TG$M/live"; gone "$TG$M/gone 'x' \$(y)"; gone "$TG$M/.claude/worktrees/gone two"
ok "$TG$OUT/other checkout/.rustc_info.json"; ok "$TG$OUT/never existed/.rustc_info.json"   # outside mount: untouched
ok "$T/canary"; ok "$M/live one/canary"; ok "$M/live one"
# mount missing: nothing is deleted
GC_TARGET_ROOT="$TG" GC_MOUNT_ROOT="$T/nomount" GC_MIN_FREE_KB=0 "$GC" 2>/dev/null
ok "$TG$M/live one/.rustc_info.json"
mk "$M/stale again"; GC_TARGET_ROOT="$TG" GC_MOUNT_ROOT="$T/nomount" "$GC" 2>/dev/null; ok "$TG$M/stale again/.rustc_info.json"
# Started from a worktree, without GC_MOUNT_ROOT: the mount is the main checkout.
R="$T/repo dir"; TG2="$T/target2"; mkdir -p "$R"
git -C "$R" init -q && git -C "$R" -c user.name=t -c user.email=t@t commit -q --allow-empty -m i
git -C "$R" worktree add -q -b wta "$R/.claude/worktrees/wt a" && git -C "$R" worktree add -q -b wtb "$R/.claude/worktrees/wt b"
mkdir -p "$R/.claude/worktrees/wt a/tools/dev-vm" && cp "$GC" "$R/.claude/worktrees/wt a/tools/dev-vm/"
mk2() { mkdir -p "$TG2$1" && touch "$TG2$1/.rustc_info.json"; }
mk2 "$R"; mk2 "$R/.claude/worktrees/wt a"; mk2 "$R/.claude/worktrees/wt b"; mk2 "$R/.claude/worktrees/stale sibling"
cd "$R/.claude/worktrees/wt a"
GC_TARGET_ROOT="$TG2" GC_MIN_FREE_KB=0 "$R/.claude/worktrees/wt a/tools/dev-vm/gc.sh" 2>/dev/null
gone "$TG2$R/.claude/worktrees/stale sibling/.rustc_info.json"
ok "$TG2$R/.rustc_info.json"; ok "$TG2$R/.claude/worktrees/wt a/.rustc_info.json"; ok "$TG2$R/.claude/worktrees/wt b/.rustc_info.json"
echo "gc-test: ok"
