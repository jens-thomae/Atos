#!/usr/bin/env bash
# Reads changed paths on stdin; prints `false` if any is code, else `true` (docs-only).
# Docs = docs/**, *.md, LICENSE*; never under .github/ or tools/, nor docs/design/tokens.json.
code=false
while IFS= read -r f; do
  case "$f" in
    # tokens.json is data, but `cargo test` and the tokens-drift check read it (card #61).
    .github/*|tools/*|docs/design/tokens.json) code=true ;;
    docs/*|*.md|LICENSE*|*/LICENSE*) ;;
    *) code=true ;;
  esac
done
[ "$code" = true ] && echo false || echo true
