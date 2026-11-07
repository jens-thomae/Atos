#!/usr/bin/env bash
# Run: bash tools/ci/test-check-no-private-keys.sh
# 1) passes on the current tree (the guard, the workflow and the docs must not match themselves); 2) fails on a planted fake key.
set -eu
d=$(cd "$(dirname "$0")" && pwd)
bash "$d/check-no-private-keys.sh" || { echo "FAIL: guard trips on the current tree"; exit 1; }
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
git -C "$t" init -q && printf -- '-----BEGIN OPENSSH PRIVATE KEY%s\nfake\n' ----- > "$t/id" && git -C "$t" add id \
  && git -C "$t" -c user.name=t -c user.email=t@t commit -qm x
(cd "$t" && ! bash "$d/check-no-private-keys.sh" > /dev/null 2>&1) || { echo "FAIL: planted key not caught"; exit 1; }
echo ok
