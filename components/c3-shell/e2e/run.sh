#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# End-to-end check of the shell (#63, #65) on our compositor: headless sway hosts atos-comp (nested,
# winit backend); inside it the shell and two client windows run. Checks that the dock lists both
# windows on the AT-SPI bus, that pressing the unfocused one through AT-SPI activates it, and
# measures the shell's idle RSS and CPU with the budgets harness (docs/budgets.md).
# Needs sway, grim, weston (its demo clients), dbus-run-session, busctl, python3-gi + gir1.2-atspi-2.0.
# Usage: run.sh <atos-shell> <atos-comp> <budgets> <out dir>
#   SHELL_RENDERER   sway renderer: pixman (default) or gles2 on /dev/dri/renderD128
#   SHELL_CPU_WINDOW idle CPU window for the budgets harness, seconds or `full` (default 10)
set -euo pipefail
[ -n "${E2E_BUS:-}" ] || E2E_BUS=1 exec dbus-run-session -- "$0" "$@"

HERE="$(cd "$(dirname "$0")" && pwd)"

if [ "${1:-}" = inner ]; then
  # Runs inside atos-comp (its kiosk command), which sets WAYLAND_DISPLAY to its own socket.
  SHELL_BIN=$2 BUDGETS=$3 OUT=$4
  "$SHELL_BIN" >"$OUT/shell.log" 2>"$OUT/shell.err" & SH=$!
  for _ in $(seq 100); do grep -q BUDGET_FIRST_FRAME "$OUT/shell.log" && break; sleep 0.1; done
  grep -q BUDGET_FIRST_FRAME "$OUT/shell.log" || { echo "shell drew no frame" >"$OUT/inner-error"; exit 1; }
  if command -v weston-flower >/dev/null; then
    weston-flower >/dev/null 2>&1 & sleep 1
    weston-clickdot >/dev/null 2>&1 & sleep 2  # the newer window is focused
  fi
  python3 -I "$HERE/atspi.py" dump "$OUT/atspi-1.txt" || true
  # atos-comp's nested window as the host sway shows it.
  WAYLAND_DISPLAY=$HOST_WAYLAND_DISPLAY grim "$OUT/1-two-windows.png" 2>/dev/null || true
  python3 -I "$HERE/atspi.py" press "Flower, running" >"$OUT/press.txt" 2>&1 || true
  sleep 1.5
  python3 -I "$HERE/atspi.py" dump "$OUT/atspi-2.txt" || true
  # Control centre (#65): open it with the dock's button through AT-SPI, dump the tree, close it.
  python3 -I "$HERE/atspi.py" press "Control centre" >>"$OUT/press.txt" 2>&1 || true
  sleep 1
  python3 -I "$HERE/atspi.py" dump "$OUT/atspi-cc.txt" || true
  python3 -I "$HERE/atspi.py" press "Control centre" >>"$OUT/press.txt" 2>&1 || true
  sleep 0.5
  python3 -I "$HERE/atspi.py" dump "$OUT/atspi-cc-closed.txt" || true
  # Four more openings, each timed by the shell (CONTROL_CENTRE_OPEN_MS, press to frame shown).
  for i in 1 2 3 4; do
    python3 -I "$HERE/atspi.py" press "Control centre" >>"$OUT/press.txt" 2>&1 || true; sleep 1
    python3 -I "$HERE/atspi.py" press "Control centre" >>"$OUT/press.txt" 2>&1 || true; sleep 0.5
  done
  grep '^CONTROL_CENTRE_OPEN_MS' "$OUT/shell.log" | cut -d' ' -f2 >"$OUT/control-centre-open-ms.txt" || true
  # Dark mode reaches apps through the portal backend (owner decision on #65): read it back.
  busctl --user call org.freedesktop.impl.portal.desktop.atos /org/freedesktop/portal/desktop \
    org.freedesktop.impl.portal.Settings Read ss org.freedesktop.appearance color-scheme >"$OUT/portal-color-scheme.txt" 2>&1 || true
  kill $SH; wait $SH 2>/dev/null || true
  # Idle RSS and CPU of a fresh shell process with the two windows in its dock.
  "$BUDGETS" "$SHELL_BIN" --cpu-window "$WINDOW" --json "$OUT/budgets.json" >"$OUT/budgets.md" 2>"$OUT/budgets.err" \
    || echo "budgets harness exit $?" >>"$OUT/budgets.err"
  touch "$OUT/inner-done"
  exit 0
fi

SHELL_BIN=$(realpath "$1"); COMP=$(realpath "$2"); BUDGETS=$(realpath "$3"); mkdir -p "$4"; OUT=$(realpath "$4")
RENDERER=${SHELL_RENDERER:-pixman}; export WINDOW=${SHELL_CPU_WINDOW:-10}
WORK=$(mktemp -d)
export XDG_RUNTIME_DIR="$WORK/run"; mkdir -m 700 "$XDG_RUNTIME_DIR"
export MESA_SHADER_CACHE_DIR="$WORK/mesa"  # cold shader cache, as after install
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$WORK"' EXIT

case "$RENDERER" in
  pixman) ;;
  gles2) export WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128 ;;
  *) echo "SHELL_RENDERER must be pixman or gles2" >&2; exit 1 ;;
esac
printf 'output HEADLESS-1 mode 1920x1080@60Hz scale 1\n' >"$WORK/sway.conf"
WLR_BACKENDS=headless WLR_RENDERER=$RENDERER WLR_LIBINPUT_NO_DEVICES=1 sway -c "$WORK/sway.conf" >"$OUT/sway.log" 2>&1 &
for _ in $(seq 100); do ls "$XDG_RUNTIME_DIR"/wayland-? >/dev/null 2>&1 && break; sleep 0.1; done
export WAYLAND_DISPLAY=$(cd "$XDG_RUNTIME_DIR" && ls -d wayland-? | head -1)
{
  echo "date: $(date -u +%FT%TZ)"
  echo "host: ${RUNNER_NAME:-$(hostname)}"
  echo "cpu: $(lscpu | sed -n 's/^Model name: *//p' | head -1)"
  echo "kernel: $(uname -srm)"
  echo "sway: $(sway --version)  renderer: $RENDERER"
  eglinfo -B 2>/dev/null | awk '/platform:$/ { p = ($0 ~ /^Wayland platform:/) } p && /OpenGL ES profile renderer/' | sort -u | sed 's/^[^:]*: */egl: /' || true
  echo "shell: $(sha256sum "$SHELL_BIN" | cut -c1-16)  atos-comp: $(sha256sum "$COMP" | cut -c1-16)"
} >"$OUT/environment.txt"

# AccessKit registers only when a screen reader is announced.
busctl --user set-property org.a11y.Bus /org/a11y/bus org.a11y.Status ScreenReaderEnabled b true

# atos-comp exits when its kiosk command does.
HOST_WAYLAND_DISPLAY=$WAYLAND_DISPLAY timeout 900 "$COMP" --no-xwayland "$0" inner "$SHELL_BIN" "$BUDGETS" "$OUT" >"$OUT/atos-comp.log" 2>&1 || true
grep -h '^ATOS_SHELL_GL_RENDERER' "$OUT/shell.err" | sed 's/^ATOS_SHELL_GL_RENDERER: /shell renderer: /' >>"$OUT/environment.txt" \
  || echo "shell renderer: none" >>"$OUT/environment.txt"
cat "$OUT/environment.txt"
[ -f "$OUT/inner-done" ] || { echo "::error::inner run did not finish: $(cat "$OUT/inner-error" 2>/dev/null)"; tail -30 "$OUT/atos-comp.log"; exit 1; }
