#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Does Slint's live preview (reloading .slint files in the running program) work in atos-shell, with
# our pinned Slint fork and our own platform backend? (#201, docs/dev-loop.md)
# Builds the shell with SLINT_LIVE_PREVIEW=1 and slint's `live-preview` feature from a private copy
# of the source, runs it in headless sway, edits the dock's .slint file in the copy and checks with
# grim whether the running dock changes. Prints LIVE_PREVIEW=works or LIVE_PREVIEW=broken.
# Run in the dev VM: tools/dev-vm/vm run tools/dev-push/live-preview-test.sh  (needs sway, grim, dbus)
set -euo pipefail
[ -n "${LP_BUS:-}" ] || LP_BUS=1 exec dbus-run-session -- "$0" "$@"
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
w=$HOME/live-preview-test
rm -rf "$w/src" "$w/run" && mkdir -p "$w/src" "$w/run"
(cd "$root" && git ls-files -co --exclude-standard -- rust-toolchain.toml tools/slint-fork third_party/slint \
  components/c4-toolkit components/c3-shell | while IFS= read -r f; do [ -e "$f" ] && echo "$f"; done | tar -c -T -) | tar -x -C "$w/src"
cd "$w/src" && tools/slint-fork/slint-fork.sh setup >/dev/null
cd components/c3-shell
export CARGO_TARGET_DIR=$w/target
SLINT_LIVE_PREVIEW=1 cargo build -q --features slint/live-preview --config ../../third_party/slint/patch.toml

export XDG_RUNTIME_DIR=$w/run; chmod 700 "$XDG_RUNTIME_DIR"
printf 'output HEADLESS-1 mode 1920x1080@60Hz scale 1\n' >"$w/sway.conf"
WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 sway -c "$w/sway.conf" >"$w/sway.log" 2>&1 &
trap 'kill $(jobs -p) 2>/dev/null || true' EXIT
for _ in $(seq 100); do ls "$XDG_RUNTIME_DIR"/wayland-? >/dev/null 2>&1 && break; sleep 0.1; done
WAYLAND_DISPLAY=$(cd "$XDG_RUNTIME_DIR" && ls -d wayland-? | head -1); export WAYLAND_DISPLAY
"$CARGO_TARGET_DIR/debug/atos-shell" >"$w/shell.log" 2>"$w/shell.err" &
for _ in $(seq 300); do grep -q BUDGET_FIRST_FRAME "$w/shell.log" && break; sleep 0.1; done
grep -q BUDGET_FIRST_FRAME "$w/shell.log" || { cat "$w/shell.err"; echo "LIVE_PREVIEW=broken (no first frame)"; exit 1; }
sleep 1

# Pure red (#ff0000) pixels on screen; the dock uses no such colour.
red() { grim -t ppm - | python3 -I -c '
import sys
d = sys.stdin.buffer.read()
parts = d.split(maxsplit=4)  # P6, width, height, maxval, pixels
px = parts[4]
print(sum(1 for i in range(0, len(px), 3) if px[i:i + 3] == b"\xff\x00\x00"))'; }
before=$(red)
# The dock window's own background: transparent -> red. Changes the copy only.
sed -i 's/^    background: transparent;$/    background: #ff0000;/' ui/dock.slint
grep -q 'background: #ff0000;' ui/dock.slint || { echo "edit did not apply"; exit 1; }
after=0
for i in $(seq 20); do after=$(red); [ "$after" -gt 1000 ] && break; sleep 0.5; done
echo "red pixels before: $before, after edit: $after (waited up to $((i / 2)) s); shell still running: $(pgrep -f "$CARGO_TARGET_DIR/debug/atos-shell" >/dev/null && echo yes || echo no)"
echo "shell stderr (last lines):"; tail -5 "$w/shell.err"
if [ "$before" -lt 1000 ] && [ "$after" -gt 1000 ]; then echo LIVE_PREVIEW=works; else echo LIVE_PREVIEW=broken; exit 1; fi
