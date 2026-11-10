#!/usr/bin/env bash
# Run: bash tools/ci/test-is-image-change.sh
set -eu
d=$(dirname "$0")
# check <pr> <publish> <paths>: the expected answer of each lane for one diff.
check() {
  for lane in pr publish; do
    want=$1; [ "$lane" = publish ] && want=$2
    got=$(printf '%b' "$3" | bash "$d/is-image-change.sh" "$lane")
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
echo ok
