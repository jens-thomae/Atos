#!/usr/bin/env bash
# Reads changed paths on stdin; prints `true` if any is an input of the given lane, else `false` (docs/ci.md).
#   pr:      c1-base.yml `build` on a pull request: the image recipe, our bootc patch, the CI scripts, the toolchain
#            pin and the workflow. C2, C3, C4 and Slint changes are checked by their own workflows and the nightly.
#   publish: c1-base.yml `publish` on main: everything that ends up in the image (the Containerfile's `repo` inputs),
#            plus the workflow, so a change to how the image is published runs once it is merged.
# Docs (*.md, LICENSE*) never count, as in is-docs-only.sh, except under .github/ and tools/.
# Test: tools/ci/test-is-image-change.sh
case "${1:-}" in pr|publish) lane=$1 ;; *) echo "usage: $0 pr|publish < paths" >&2; exit 2 ;; esac
hit=false
while IFS= read -r f; do
  case "$f" in
    .github/workflows/c1-base.yml|rust-toolchain.toml) hit=true ;;
    tools/ci/*) [ "$lane" = pr ] && hit=true ;;
    tools/slint-fork/*) [ "$lane" = publish ] && hit=true ;;
    *.md|LICENSE*|*/LICENSE*) ;;
    components/c1-base/*|third_party/bootc/*) hit=true ;;
    components/c2-compositor/*|components/c3-shell/*|components/c4-toolkit/*|third_party/*) [ "$lane" = publish ] && hit=true ;;
  esac
done
echo "$hit"
