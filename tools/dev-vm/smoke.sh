#!/bin/bash
# Smoke check, runs inside the dev VM: `tools/dev-vm/vm smoke`.
# 1. Headless weston (software rendering), a Wayland client, a screenshot.
# 2. The AT-SPI accessibility tree of a running GTK app.
# Output: tools/dev-vm/out/{screenshot.png,atspi-tree.txt,weston.log}
set -euo pipefail

# Own session bus, so the AT-SPI bus is fresh and nothing leaks into the VM session.
[ -n "${ATOS_SMOKE_BUS:-}" ] || ATOS_SMOKE_BUS=1 exec dbus-run-session -- "$0" "$@"

OUT="$(cd "$(dirname "$0")" && pwd)/out"
mkdir -p "$OUT"
rm -f "$OUT"/*
export XDG_RUNTIME_DIR="$(mktemp -d)"
export WAYLAND_DISPLAY=atos-smoke
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$XDG_RUNTIME_DIR"' EXIT

wait_for() { for _ in $(seq 100); do eval "$1" && return; sleep 0.1; done; echo "timeout: $1" >&2; exit 1; }

# --debug exposes the screenshot protocol to weston-screenshooter.
weston --backend=headless --renderer=pixman --width=1024 --height=768 \
  --socket="$WAYLAND_DISPLAY" --debug --log="$OUT/weston.log" &
wait_for '[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]'

weston-simple-shm &
GDK_BACKEND=wayland zenity --info --title="Atos smoke" --text="Hello from the dev VM" &
sleep 2
kill -0 %2 %3 # both clients still running

(cd "$OUT" && weston-screenshooter && mv wayland-screenshot-*.png screenshot.png)
head -c 8 "$OUT/screenshot.png" | grep -q PNG
echo "screenshot: $OUT/screenshot.png"

python3 - >"$OUT/atspi-tree.txt" <<'EOF'
import gi
gi.require_version("Atspi", "2.0")
from gi.repository import Atspi

def dump(node, depth=0):
    print(f"{'  ' * depth}{node.get_role_name()} {node.get_name()!r}")
    for i in range(node.get_child_count()):
        dump(node.get_child_at_index(i), depth + 1)

desktop = Atspi.get_desktop(0)
apps = [desktop.get_child_at_index(i) for i in range(desktop.get_child_count())]
app = next((a for a in apps if a.get_name() == "zenity"), None)
assert app, f"zenity not on the AT-SPI bus; apps: {[a.get_name() for a in apps]}"
dump(app)
EOF
grep -q "Hello from the dev VM" "$OUT/atspi-tree.txt"
cat "$OUT/atspi-tree.txt"
echo "smoke: ok"
