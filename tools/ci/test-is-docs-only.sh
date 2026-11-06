#!/usr/bin/env bash
# Run: bash tools/ci/test-is-docs-only.sh
set -eu
d=$(dirname "$0")
check() { got=$(printf '%b' "$2" | bash "$d/is-docs-only.sh"); [ "$got" = "$1" ] || { echo "FAIL: '$2' -> $got, want $1"; exit 1; }; }
check true  'docs/a.md\nREADME.md\nLICENSE-MIT\n'
check false 'docs/a.md\ncomponents/x/src/lib.rs\n'
check false '.github/workflows/ci.yml\n'
check false 'tools/ci/x.sh\n'
# Rename src/a.rs -> docs/a.md: with --no-renames git lists both paths, so the old one counts as code.
check false 'docs/a.md\nsrc/a.rs\n'
# End-to-end: a real git rename must be caught by the diff flags ci.yml uses.
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
git -C "$t" init -q; mkdir "$t/src" "$t/docs"; printf 'fn main() {}\n' > "$t/src/a.rs"
git -C "$t" add -A; git -C "$t" -c user.name=t -c user.email=t@t commit -qm a
git -C "$t" mv src/a.rs docs/a.md; git -C "$t" -c user.name=t -c user.email=t@t commit -qam b
got=$(git -C "$t" diff --no-renames --name-only HEAD^1 HEAD | bash "$d/is-docs-only.sh")
[ "$got" = false ] || { echo "FAIL: rename classified docs-only"; exit 1; }
echo ok
