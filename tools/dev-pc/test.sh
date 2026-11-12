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
# No forwarding of any kind from the client side, whatever ~/.ssh/config says (review of #274).
# shellcheck disable=SC2154 # ssh_opts: set in pc
for o in -a -x ClearAllForwardings=yes ForwardAgent=no ForwardX11=no BatchMode=yes PasswordAuthentication=no; do
  printf '%s\n' "${ssh_opts[@]}" | grep -qx -- "$o" || fail "ssh option $o missing"
done
grep -q 'ssh "${ssh_opts\[@\]}" "$host"' "$d/pc" || fail "ssh call does not use ssh_opts"
echo "dev-pc: all checks pass"
