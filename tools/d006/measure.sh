#!/bin/bash
# D-006 measurements M1–M7 (docs/decisions/D-006-prototype-brief.md §7) for both Files prototypes.
# Needs: sway wtype wl-clipboard grim dbus-run-session at-spi2-core python3-gi gir1.2-atspi-2.0 bc
# Usage: measure.sh <d006-iced> <d006-slint> <budgets> <out-dir>
#   D006_RUNS         runs per number (default 5, the brief's minimum)
#   D006_CPU_WINDOW   idle-CPU window in seconds, or `full` (5 min, §7; default)
set -euo pipefail

# Own session bus: fresh AT-SPI bus, nothing leaks into or out of the host session.
[ -n "${D006_BUS:-}" ] || D006_BUS=1 exec dbus-run-session -- "$0" "$@"

HERE="$(cd "$(dirname "$0")" && pwd)"
ICED=$(realpath "$1"); SLINT=$(realpath "$2"); BUDGETS=$(realpath "$3")
mkdir -p "$4"; OUT=$(realpath "$4")
RUNS=${D006_RUNS:-5}; WINDOW=${D006_CPU_WINDOW:-full}
WORK=$(mktemp -d); export XDG_RUNTIME_DIR="$WORK/run"; mkdir -m 700 "$XDG_RUNTIME_DIR"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$WORK"' EXIT
APPS="iced:$ICED slint:$SLINT"

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
  echo "iced: $(sha256sum "$ICED" | cut -c1-16)  slint: $(sha256sum "$SLINT" | cut -c1-16)"
} >"$OUT/environment.txt"

# --- compositor: sway, headless backend, pixman (software) renderer ------------
WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
  sway -c "$HERE/sway.conf" >"$OUT/sway.log" 2>&1 &
for _ in $(seq 100); do [ -S "$XDG_RUNTIME_DIR/wayland-1" ] && break; [ -S "$XDG_RUNTIME_DIR/wayland-0" ] && break; sleep 0.1; done
export WAYLAND_DISPLAY=$(cd "$XDG_RUNTIME_DIR" && ls -d wayland-? | head -1)
export SWAYSOCK=$(ls "$XDG_RUNTIME_DIR"/sway-ipc.*.sock)
output_info() { swaymsg -t get_outputs | python3 -c "
import json, sys
o = json.load(sys.stdin)[0]; m = o['current_mode']
print('output: %s %dx%d@%.0fHz scale %s' % (o['name'], m['width'], m['height'], m['refresh'] / 1000, o['scale']))"; }
output_info >>"$OUT/environment.txt"

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

# --- M6, M7: accessibility and keyboard, with the AT-SPI bus switched on -------------
# AccessKit registers only when a screen reader is announced (see the iced README).
busctl --user set-property org.a11y.Bus /org/a11y/bus org.a11y.Status ScreenReaderEnabled b true
mkdir -p "$OUT/m6" "$OUT/m7"
for a in $APPS; do
  n=${a%%:*}; b=${a#*:}
  python3 -I "$HERE/atspi.py" m6 "$n" "$b" "$FX" "$OUT/m6" || echo "M6 $n failed"
  python3 -I "$HERE/atspi.py" m7 "$n" "$b" "$FX" "$OUT/m7" || echo "M7 $n failed"
done
echo "done: $OUT"
