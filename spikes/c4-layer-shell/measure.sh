#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Spike #59: run the layer-shell panel in headless sway, show its AT-SPI tree, time the popover and
# read idle memory. Needs sway, wtype, grim, dbus-run-session, python3-gi + gir1.2-atspi-2.0, eglinfo.
# Usage: measure.sh <spike binary> <budgets binary> <out dir>
#   T59_RENDERER   sway renderer: pixman (default) or gles2 on T59_RENDER_DEVICE (/dev/dri/renderD128)
#   T59_OPENS      popover opens to time (default 20)
#   T59_CPU_WINDOW idle window for the budgets harness, seconds or `full` (default 10)
set -euo pipefail
[ -n "${T59_BUS:-}" ] || T59_BUS=1 exec dbus-run-session -- "$0" "$@"

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN=$(realpath "$1"); BUDGETS=$(realpath "$2"); mkdir -p "$3"; OUT=$(realpath "$3")
RENDERER=${T59_RENDERER:-pixman}; OPENS=${T59_OPENS:-20}; WINDOW=${T59_CPU_WINDOW:-10}
WORK=$(mktemp -d)
export XDG_RUNTIME_DIR="$WORK/run"; mkdir -m 700 "$XDG_RUNTIME_DIR"
# Every launch gets its own empty Mesa shader cache (cold), except the `warm` run, which reuses the
# cache its cold run filled (an installed system after first use). The page cache stays warm.
export MESA_SHADER_CACHE_DIR="$WORK/mesa-atspi"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$WORK"' EXIT

case "$RENDERER" in
  pixman) ;;
  gles2) export WLR_RENDER_DRM_DEVICE="${T59_RENDER_DEVICE:-/dev/dri/renderD128}" ;;
  *) echo "T59_RENDERER must be pixman or gles2" >&2; exit 1 ;;
esac
printf 'output HEADLESS-1 mode 1920x1080@60Hz scale 1\n' >"$WORK/sway.conf"
WLR_BACKENDS=headless WLR_RENDERER=$RENDERER WLR_LIBINPUT_NO_DEVICES=1 sway -c "$WORK/sway.conf" >"$OUT/sway.log" 2>&1 &
for _ in $(seq 100); do ls "$XDG_RUNTIME_DIR"/wayland-? >/dev/null 2>&1 && break; sleep 0.1; done
export WAYLAND_DISPLAY=$(cd "$XDG_RUNTIME_DIR" && ls -d wayland-? | head -1)
export SWAYSOCK=$(ls "$XDG_RUNTIME_DIR"/sway-ipc.*.sock)
{
  echo "date: $(date -u +%FT%TZ)"
  echo "host: ${RUNNER_NAME:-$(hostname)}"
  echo "cpu: $(lscpu | sed -n 's/^Model name: *//p' | head -1)"
  echo "kernel: $(uname -srm)"
  echo "sway: $(sway --version)  renderer: $RENDERER"
  echo "mesa: $(dpkg -s libgl1-mesa-dri 2>/dev/null | sed -n 's/^Version: //p')"
  # The GL renderer Wayland clients of this compositor get (the spike's EGL uses the same platform).
  eglinfo -B 2>/dev/null | awk '/platform:$/ { p = ($0 ~ /^Wayland platform:/) } p && /OpenGL ES profile renderer/' | sort -u | sed 's/^[^:]*: */egl: /' || true
  echo "binary: $(sha256sum "$BIN" | cut -c1-16)"
} >"$OUT/environment.txt"
cat "$OUT/environment.txt"

# AccessKit registers only when a screen reader is announced.
busctl --user set-property org.a11y.Bus /org/a11y/bus org.a11y.Status ScreenReaderEnabled b true

# Colour of one screen pixel, as "r g b" (grim writes a 1x1 PPM).
px() { grim -g "$1,$2 1x1" -t ppm - | tail -c 3 | od -An -tu1 | xargs; }
# Inside the popover (it opens at 8,44 below the panel, 280 px wide) and outside it.
IN_X=150 IN_Y=100 OUT_X=600 OUT_Y=100

# --- 1. Surfaces and the AT-SPI tree ---------------------------------------------------------
T59_EXCLUSIVE_KEYBOARD=1 "$BIN" >"$OUT/app.log" 2>"$OUT/app.err" & APP=$!
for _ in $(seq 100); do grep -q BUDGET_FIRST_FRAME "$OUT/app.log" && break; sleep 0.1; done
sleep 1.5  # AT-SPI registration
grep -h '^T59_GL_RENDERER' "$OUT/app.err" | sed 's/^T59_GL_RENDERER: /spike renderer: /' | tee -a "$OUT/environment.txt" || echo "spike renderer: none" >>"$OUT/environment.txt"
grim "$OUT/1-panel.png"
python3 -I "$HERE/atspi_dump.py" dump "$OUT/atspi-1-panel.txt" || true
# Open the popover through AT-SPI (the assistant fallback path, C12): press the panel's button.
python3 -I "$HERE/atspi_dump.py" press "Quick settings" || true
sleep 1.5
grim "$OUT/2-popover.png"
python3 -I "$HERE/atspi_dump.py" dump "$OUT/atspi-2-popover.txt" || true
# The popover is on screen when the pixel inside it differs from the one outside it.
echo "popover pixels: inside $(px $IN_X $IN_Y), outside $(px $OUT_X $OUT_Y)" | tee "$OUT/popover-pixels.txt"
wtype -k Escape; sleep 0.5
kill $APP; wait $APP 2>/dev/null || true

# --- 2. Popover fully visible, keyboard path, without and with the popup pool -------------------
# Pool 0: every open creates the popover's EGL context and renderer. Pool 1: one pre-warmed popup
# window is reused (see src/platform.rs). Run names: <pool>-<shader cache>.
for RUN in 0-cold 1-cold 1-warm; do
  POOL=${RUN%-*}
  export MESA_SHADER_CACHE_DIR="$WORK/mesa-pool$POOL"
  [ "${RUN#*-}" = cold ] && rm -rf "$MESA_SHADER_CACHE_DIR"
  T59_POPUP_POOL=$POOL T59_EXCLUSIVE_KEYBOARD=1 "$BIN" >"$OUT/app-$RUN.log" 2>"$OUT/app-$RUN.err" & APP=$!
  for _ in $(seq 100); do grep -q BUDGET_FIRST_FRAME "$OUT/app-$RUN.log" && break; sleep 0.1; done
  sleep 1.5
  # A virtual keyboard that stays alive keeps the seat's keyboard, so each wtype below is one press.
  wtype -s 3600000 -k Shift_L & KEEP=$!
  sleep 0.5
  for i in $(seq "$OPENS"); do
    wtype -k space; sleep 0.6
    [ "$i" = 2 ] && echo "run $RUN, open 2: inside $(px $IN_X $IN_Y), outside $(px $OUT_X $OUT_Y)" | tee -a "$OUT/popover-pixels.txt"
    wtype -k Escape; sleep 0.4
  done
  kill $KEEP 2>/dev/null || true
  sleep 5  # idle after the popover was used: the steady state of a running shell
  grep -E '^(VmRSS|RssAnon|RssFile|RssShmem):' /proc/$APP/status >"$OUT/rss-$RUN.txt"
  kill $APP; wait $APP 2>/dev/null || true
  grep '^T59_' "$OUT/app-$RUN.log" >"$OUT/popover-$RUN.txt" || true
done

# --- 3. Idle RSS and CPU at start (budgets harness, single process, pool on, cold shader cache) ---
export MESA_SHADER_CACHE_DIR="$WORK/mesa-budgets"
"$BUDGETS" "$BIN" --cpu-window "$WINDOW" --json "$OUT/budgets.json" >"$OUT/budgets.md" 2>"$OUT/budgets.err" || echo "budgets harness exit $?"
python3 -I "$HERE/summarize.py" "$OUT" | tee "$OUT/summary.md"
