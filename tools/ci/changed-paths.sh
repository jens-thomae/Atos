#!/usr/bin/env bash
# Prints the paths this run changes, NUL-separated, for is-image-change.sh (docs/ci.md).
# `-z` prints names verbatim: without it git quotes non-ASCII names ("…\303\244…"), which match no rule.
# `--no-renames`: a rename lists both its old and new path.
# Usage: changed-paths.sh [<before>]
#   no argument (pull request): HEAD^1..HEAD. HEAD is the merge commit, HEAD^1 the base.
#   <before> (push): <before>..HEAD, the whole pushed range, so every commit of a rebase merge or multi-commit push counts.
#     Exit 3 when <before> is all zeros (new branch), unknown, or not an ancestor of HEAD (force push).
#     The caller then treats every lane as changed.
# Needs the history back to <before> (checkout fetch-depth: 0). Test: tools/ci/test-is-image-change.sh
set -euo pipefail
base=HEAD^1
if [ $# -gt 0 ]; then
  base=$1
  [[ $base =~ ^[0-9a-f]{40}$ && ! $base =~ ^0+$ ]] || exit 3
  { git cat-file -e "$base^{commit}" && git merge-base --is-ancestor "$base" HEAD; } 2> /dev/null || exit 3
fi
git diff -z --no-renames --name-only "$base" HEAD
