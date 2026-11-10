#!/usr/bin/env bash
# Run: bash tools/ci/test-is-image-change.sh
set -eu
d=$(cd "$(dirname "$0")" && pwd)
# check <pr> <publish> <paths>: the expected answer of each lane for one diff.
check() {
  for lane in pr publish; do
    want=$1; [ "$lane" = publish ] && want=$2
    got=$(printf '%b' "$3" | tr '\n' '\0' | bash "$d/is-image-change.sh" "$lane")
    [ "$got" = "$want" ] || { echo "FAIL $lane: '$3' -> $got, want $want"; exit 1; }
  done
}
# Image recipe, bootc patch, toolchain pin, the workflow: both lanes.
check true  true  'components/c1-base/Containerfile\n'
check true  true  'components/c1-base/usr/lib/systemd/system/x.service\n'
check true  true  'third_party/bootc/0001-boot-counting.patch\n'
check true  true  'rust-toolchain.toml\n'
check true  true  '.github/workflows/c1-base.yml\n'
# CI scripts: PR build only (they do not end up in the image).
check true  false 'tools/ci/is-docs-only.sh\n'
check true  false 'tools/ci/README.md\n'
# Code that ends up in the image but has its own PR checks: publish only.
check false true  'components/c2-compositor/src/main.rs\n'
check false true  'components/c3-shell/ui/dock.slint\n'
check false true  'components/c4-toolkit/ui/tokens.slint\n'
check false true  'third_party/slint/patch.toml\n'
check false true  'tools/slint-fork/slint-fork.sh\n'
check false true  'tools/slint-fork/README.md\n'
# Not in the image: neither lane.
check false false 'components/c5-apps/src/lib.rs\n'
check false false 'components/c11-installer/Containerfile\n'
check false false '.github/workflows/c11-installer.yml\n'
check false false '.github/workflows/c3-shell.yml\n'
check false false 'tools/budgets/src/main.rs\n'
check false false 'docs/design/tokens.json\n'
check false false 'Cargo.lock\n'
check false false ''
# Docs inside image paths do not count.
check false false 'components/c1-base/README.md\ndocs/ci.md\ncomponents/c2-compositor/LICENSE\n'
# One image path among others is enough.
check true  true  'docs/ci.md\ncomponents/c5-apps/x.rs\ncomponents/c1-base/check-seal.sh\n'
check false true  'components/c5-apps/x.rs\ncomponents/c3-shell/src/main.rs\n'
# Rename components/c1-base/x.sh -> docs/x.md: with --no-renames git lists the old path too.
check true  true  'docs/x.md\ncomponents/c1-base/x.sh\n'
bash "$d/is-image-change.sh" < /dev/null 2> /dev/null && { echo "FAIL: no lane accepted"; exit 1; }
# A path with a newline in its name is one path (NUL-separated input).
check false true  'components/c3-shell/a\nb.rs\n'

# End-to-end with real commits, through changed-paths.sh as c1-base.yml calls it.
t=$(mktemp -d); trap 'rm -rf "$t" "$t.out"' EXIT
g() { git -C "$t" -c user.name=t -c user.email=t@t "$@"; }
lanes() { (cd "$t" && bash "$d/changed-paths.sh" "$@" > "$t.out") || return $?
  echo "$(bash "$d/is-image-change.sh" pr < "$t.out") $(bash "$d/is-image-change.sh" publish < "$t.out")"; }
want() { got=$(lanes "${@:2}") || got="exit $?"; [ "$got" = "$1" ] || { echo "FAIL e2e ${*:2}: $got, want $1"; exit 1; }; }
git init -q "$t"; mkdir -p "$t/components/c1-base" "$t/components/c3-shell/ui" "$t/docs"
echo a > "$t/components/c1-base/x.sh"; g add -A; g commit -qm base; base=$(g rev-parse HEAD)
# Rename components/c1-base/x.sh -> docs/x.md: the old path counts.
g mv components/c1-base/x.sh docs/x.md; g commit -qm rename
want 'true true'
# A non-ASCII name: without -z git would print it quoted, and it would match no rule (fail open).
echo a > "$t/components/c3-shell/ui/ä.slint"; g add -A; g commit -qm umlaut
want 'false true'
# A push of two commits (rebase merge): C3, then docs. HEAD^1..HEAD alone sees only docs; the pushed range sees C3.
before=$(g rev-parse HEAD)
echo b > "$t/components/c3-shell/ui/ä.slint"; g commit -qam c3; echo b > "$t/docs/y.md"; g add -A; g commit -qm docs
want 'false false'
want 'false true' "$before"
# No usable range: exit 3, the workflow then runs every lane.
want 'exit 3' 0000000000000000000000000000000000000000
want 'exit 3' 1234567890123456789012345678901234567890
want 'exit 3' 'HEAD~1'
g checkout -q -b side "$base"; g commit -q --allow-empty -m side; forced=$(g rev-parse HEAD); g checkout -q -
want 'exit 3' "$forced"
want 'true true' "$base"  # the whole range, the c1-base rename included
echo ok
