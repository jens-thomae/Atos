#!/bin/bash
# M9 (brief §7): clean release build time, stripped size, crates in Cargo.lock, lines of code.
# Usage: m9-build.sh <out.json>   (builds spikes/d006-iced and spikes/d006-slint; copies the binaries to <out dir>/bin)
set -euo pipefail
OUT=$(realpath -m "$1")
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET=${CARGO_TARGET_DIR:-target}
echo '{' >"$OUT"
first=1
for s in iced slint; do
  dir="$ROOT/spikes/d006-$s"
  cd "$dir"
  cargo clean
  t0=$(date +%s.%N)
  cargo build --release --locked
  t1=$(date +%s.%N)
  bin="$TARGET/release/d006-$s"
  mkdir -p "$(dirname "$OUT")/bin" && cp "$bin" "$(dirname "$OUT")/bin/"  # unstripped, for measure.sh
  strip -o "/tmp/d006-$s.stripped" "$bin"
  size=$(stat -c %s "/tmp/d006-$s.stripped")
  crates=$(grep -c '^\[\[package\]\]' Cargo.lock)
  # Lines of Rust and markup, blank lines and whole-line // comments excluded.
  loc=$({ cat src/*.rs ui/*.slint build.rs 2>/dev/null || true; } | grep -Ev '^\s*($|//)' | wc -l)
  [ $first = 1 ] || echo ',' >>"$OUT"; first=0
  printf '"%s": {"build_seconds": %.1f, "stripped_bytes": %s, "crates": %s, "lines": %s}' \
    "$s" "$(echo "$t1 - $t0" | bc)" "$size" "$crates" "$loc" >>"$OUT"
done
echo '}' >>"$OUT"
cat "$OUT"
