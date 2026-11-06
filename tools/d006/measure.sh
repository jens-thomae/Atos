#!/bin/bash
# D-006 measurements M1–M7 (docs/decisions/D-006-prototype-brief.md §7) for both Files prototypes.
# Needs: sway wtype wl-clipboard grim dbus-run-session at-spi2-core python3-gi gir1.2-atspi-2.0 eglinfo
# Usage: measure.sh <bin-dir> <out-dir>
#   <bin-dir> holds budgets, d006-iced, d006-iced-wgpu (libcosmic --features wgpu) and d006-slint.
#   Four variants: iced, iced-wgpu, slint (femtovg on GL) and slint-sw (Slint software renderer,
#   SLINT_BACKEND=winit-software).
#   D006_RUNS         runs per number (default 5, the brief's minimum)
#   D006_CPU_WINDOW   idle-CPU window in seconds, or `full` (5 min, §7; default)
#   D006_RENDERER     sway's renderer: `pixman` (software, default) or `gles2` on the GPU's render node
#                     (D006_RENDER_DEVICE, default /dev/dri/renderD128). Option A of D-006 §3.3.
#   D006_COMPOSITOR   `existing`: do not start sway; use the running compositor (WAYLAND_DISPLAY,
#                     SWAYSOCK). Option B: tools/d006/sway-drm.conf.
#   D006_A11Y_VARIANTS  variants that get M6/M7 (default `iced slint`: the tree is renderer-independent)
set -euo pipefail

# Own session bus: fresh AT-SPI bus, nothing leaks into or out of the host session.
[ -n "${D006_BUS:-}" ] || D006_BUS=1 exec dbus-run-session -- "$0" "$@"

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN=$(realpath "$1"); BUDGETS="$BIN/budgets"
mkdir -p "$2"; OUT=$(realpath "$2")
RUNS=${D006_RUNS:-5}; WINDOW=${D006_CPU_WINDOW:-full}
RENDERER=${D006_RENDERER:-pixman}; COMPOSITOR=${D006_COMPOSITOR:-own}
A11Y=${D006_A11Y_VARIANTS:-iced slint}
WORK=$(mktemp -d)
# Own compositor: private runtime dir. Existing compositor: keep the real one (its socket lives there).
[ "$COMPOSITOR" = existing ] || { export XDG_RUNTIME_DIR="$WORK/run"; mkdir -m 700 "$XDG_RUNTIME_DIR"; }
export MESA_SHADER_CACHE_DIR="$WORK/mesa-cache"  # no shader cache left by earlier runs warms the first launch
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$WORK"' EXIT
# Variant wrappers: name, environment, binary. `exec` keeps the PID (the harness measures the PID).
mkdir -p "$WORK/v"
variant() { printf '#!/bin/sh\nexec env %s %s "$@"\n' "$2" "$BIN/$3" >"$WORK/v/$1"; chmod +x "$WORK/v/$1"; }
variant iced "" d006-iced
variant iced-wgpu "" d006-iced-wgpu
variant slint "" d006-slint
variant slint-sw "SLINT_BACKEND=winit-software" d006-slint
APPS="iced:$WORK/v/iced iced-wgpu:$WORK/v/iced-wgpu slint:$WORK/v/slint slint-sw:$WORK/v/slint-sw"

# --- environment -------------------------------------------------------------
{
  echo "date: $(date -u +%FT%TZ)"
  echo "host: ${RUNNER_NAME:-$(hostname)}"
  echo "cpu: $(lscpu | sed -n 's/^Model name: *//p' | head -1)"
  echo "cores: $(nproc)"
  echo "kernel: $(uname -srm)"
  echo "governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
  echo "os: $(. /etc/os-release; echo "$PRETTY_NAME")"
  echo "sway: $(sway --version)"; echo "wtype: $(dpkg -s wtype 2>/dev/null | sed -n 's/^Version: //p')"
  echo "mesa: $(dpkg -s libgl1-mesa-dri 2>/dev/null | sed -n 's/^Version: //p')"
  echo "runs: $RUNS  cpu_window: $WINDOW"
  echo "compositor: $COMPOSITOR  sway_renderer: $([ "$COMPOSITOR" = existing ] && echo '(existing compositor)' || echo "$RENDERER")"
  for b in d006-iced d006-iced-wgpu d006-slint; do echo "$b: $(sha256sum "$BIN/$b" | cut -c1-16)"; done
} >"$OUT/environment.txt"

# --- compositor: own sway (headless; pixman or gles2) or the running one ------------
if [ "$COMPOSITOR" = existing ]; then
  : "${WAYLAND_DISPLAY:?D006_COMPOSITOR=existing needs a running compositor}" "${SWAYSOCK:?needs SWAYSOCK}"
else
  case "$RENDERER" in
    pixman) ;;
    gles2) export WLR_RENDER_DRM_DEVICE="${D006_RENDER_DEVICE:-/dev/dri/renderD128}" ;;
    *) echo "D006_RENDERER must be pixman or gles2" >&2; exit 1 ;;
  esac
  WLR_BACKENDS=headless WLR_RENDERER=$RENDERER WLR_LIBINPUT_NO_DEVICES=1 \
    sway -c "$HERE/sway.conf" >"$OUT/sway.log" 2>&1 &
  for _ in $(seq 100); do [ -S "$XDG_RUNTIME_DIR/wayland-1" ] && break; [ -S "$XDG_RUNTIME_DIR/wayland-0" ] && break; sleep 0.1; done
  export WAYLAND_DISPLAY=$(cd "$XDG_RUNTIME_DIR" && ls -d wayland-? | head -1)
  export SWAYSOCK=$(ls "$XDG_RUNTIME_DIR"/sway-ipc.*.sock)
fi
output_info() { swaymsg -t get_outputs | python3 -c "
import json, sys
o = json.load(sys.stdin)[0]; m = o['current_mode']
print('output: %s %dx%d@%.0fHz scale %s' % (o['name'], m['width'], m['height'], m['refresh'] / 1000, o['scale']))"; }
output_info >>"$OUT/environment.txt"
# Renderer proof, part 1: the GL renderer the Wayland platform gives clients of this compositor. Only
# that block counts: the GBM and device platforms report the GPU whatever the compositor does.
{ eglinfo -B 2>/dev/null | awk '/platform:$/ { p = ($0 ~ /^Wayland platform:/) } p && /OpenGL ES profile renderer/' \
    | sort -u | sed 's/^[^:]*: */egl: /'; } >"$OUT/egl.txt" || true
[ -s "$OUT/egl.txt" ] || echo "egl: none (no renderer line in the Wayland platform block)" >"$OUT/egl.txt"
cat "$OUT/egl.txt" >>"$OUT/environment.txt"; rm "$OUT/egl.txt"

mkdir -p "$OUT/renderer"

# --- fixture --------------------------------------------------------------------
FX="$WORK/fx"; sh "$HERE/../../spikes/d006-fixture/make-fixture.sh" "$FX"
(cd "$FX" && TZ=UTC find . \( -type f -printf '%p f %s %TY%Tm%Td%TH%TM\n' \) -o \( -type d -printf '%p d %TY%Tm%Td%TH%TM\n' \) | LC_ALL=C sort | sha256sum) \
  | sed 's/^/fixture digest: /' >>"$OUT/environment.txt"

# --- M1–M4: harness ---------------------------------------------------------------
# Wrappers from the brief: exec keeps the PID. Paths contain a `/`.
mkdir -p "$OUT/m1-m4"
for a in $APPS; do
  n=${a%%:*}; b=${a#*:}
  for f in small 10k; do printf '#!/bin/sh\nexec %s %s\n' "$b" "$FX/$f" >"$WORK/$n-$f"; chmod +x "$WORK/$n-$f"; done
  for f in small 10k; do
    # M3 and M4 come from the `small` runs, which use the full window; 10k runs use 10 s.
    w=10; [ "$f" = small ] && w=$WINDOW
    for i in $(seq "$RUNS"); do
      rc=0
      "$BUDGETS" "$WORK/$n-$f" --cpu-window "$w" --json "$OUT/m1-m4/$n-$f-$i.json" \
        >"$OUT/m1-m4/$n-$f-$i.md" 2>"$OUT/m1-m4/$n-$f-$i.err" || rc=$?
      echo "$rc" >"$OUT/m1-m4/$n-$f-$i.rc"
      echo "M1-M4 $n $f run $i: harness exit $rc"
    done
  done
done

# --- M5: frame time while scrolling -------------------------------------------------
mkdir -p "$OUT/m5"
HZ=$(output_info | sed 's/.*@\([0-9]*\)Hz.*/\1/')
for a in $APPS; do
  n=${a%%:*}; b=${a#*:}
  for i in $(seq "$RUNS"); do
    rc=0
    D006_AUTOSCROLL=1 WAYLAND_DEBUG=client timeout 60 "$b" "$FX/10k" >"$OUT/m5/$n-$i.log" 2>&1 || rc=$?
    echo "$rc" >"$OUT/m5/$n-$i.rc"
    python3 "$HERE/frames.py" "$OUT/m5/$n-$i.log" "$HZ" >"$OUT/m5/$n-$i.json" 2>"$OUT/m5/$n-$i.err" || true
    echo "M5 $n run $i: exit $rc $(cat "$OUT/m5/$n-$i.json" 2>/dev/null)"
    # The raw logs are large; keep only the commit lines and markers.
    grep -E 'wl_surface@[0-9]+\.commit|BUDGET_FIRST_FRAME|D006_AUTOSCROLL' "$OUT/m5/$n-$i.log" | gzip -9 >"$OUT/m5/$n-$i.log.gz"
    rm "$OUT/m5/$n-$i.log"
  done
done

# --- Renderer proof, part 2 ---------------------------------------------------------------------
# Each variant's own renderer line (stderr, `D006_RENDERER: ...`). One extra launch per variant: iced
# queries the adapter only when D006_RENDERER_PROBE is set. It runs after M1–M5 so that it cannot warm
# the page cache or the shader cache before G1's first launch (§4.1). Same compositor, so the proof holds.
for a in $APPS; do
  n=${a%%:*}; b=${a#*:}
  D006_RENDERER_PROBE=1 "$b" "$FX/small" >/dev/null 2>"$OUT/renderer/$n.txt" & pid=$!
  for _ in $(seq 200); do grep -q '^D006_RENDERER:' "$OUT/renderer/$n.txt" && break; kill -0 $pid 2>/dev/null || break; sleep 0.1; done
  kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true
  grep -q '^D006_RENDERER:' "$OUT/renderer/$n.txt" || echo "warning: $n logged no renderer line within 20 s (slow first start?)" >&2
  grep -h '^D006_RENDERER:' "$OUT/renderer/$n.txt" | sed "s/^D006_RENDERER:/renderer $n:/" >>"$OUT/environment.txt" || true
  grep -q '^D006_RENDERER:' "$OUT/renderer/$n.txt" || echo "renderer $n: none" >>"$OUT/environment.txt"
done

# --- M6, M7: accessibility and keyboard, with the AT-SPI bus switched on -------------
# AccessKit registers only when a screen reader is announced (see the iced README).
busctl --user set-property org.a11y.Bus /org/a11y/bus org.a11y.Status ScreenReaderEnabled b true
mkdir -p "$OUT/m6" "$OUT/m7"
for a in $APPS; do
  n=${a%%:*}; b=${a#*:}
  case " $A11Y " in *" $n "*) ;; *) continue ;; esac
  python3 -I "$HERE/atspi.py" m6 "$n" "$b" "$FX" "$OUT/m6" || echo "M6 $n failed"
  python3 -I "$HERE/atspi.py" m7 "$n" "$b" "$FX" "$OUT/m7" || echo "M7 $n failed"
done
echo "done: $OUT"
