#!/usr/bin/env bash
# shellcheck disable=SC2016 # literal $ on purpose: names and arguments that must not expand
# SPDX-License-Identifier: MIT OR Apache-2.0
# Run: bash tools/dev-pc/test.sh   (pc's checks before it touches the PC; the host alias check is dev-push's, tested there)
set -eu
d=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091 # pc, next to this file
. "$d/pc"
fail() { echo "FAIL: $1"; exit 1; }
[ "$(stage_for components/c2-compositor)" = comp ] || fail "C2 root not comp"
[ "$(stage_for components/c2-compositor/src)" = comp ] || fail "C2 subdir not comp"
for r in . components/c3-shell components/c2-compositor-x tools; do
  [ "$(stage_for "$r")" = shell ] || fail "$r not shell"
done
name_ok vibrant-einstein-1e1116 || fail "worktree name refused"
name_ok Atos || fail "main checkout name refused"
for n in "" .. .x 'a b' 'a;b' 'a/b' '$(id)'; do name_ok "$n" && fail "name '$n' accepted"; done
# The command reaches the PC word for word: pc sends printf %q words, the remote login shell splits them.
args=(cargo test -- 'a b' "it's" '$HOME' $'x\ny' '*')
eval "set -- $(printf '%q ' "${args[@]}")"
[ "$*" = "${args[*]}" ] && [ $# = ${#args[@]} ] || fail "arguments changed on the way"
echo "dev-pc: all checks pass"
