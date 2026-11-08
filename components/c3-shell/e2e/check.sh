#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Acceptance checks of #63, #64 and #65 on one run.sh result dir. Usage: check.sh <out dir>
#   SHELL_RSS_MB      the shell's share of idle memory (D-006: 300 MB)
#   SHELL_CHECK_TREE  0 skips the checks that need client windows (weston's demo clients)
#   SHELL_GATE        1 (the NUC job) fails on any budgets-harness breach: idle CPU and cold start as well
#                     as RSS. Unset (hosted job): CPU and cold start are only reported as warnings.
#   SHELL_OPEN_MS     if set, every launcher opening, the cold first one included, must be at most
#                     this (§7 popover: 100 ms), timed from the start of `atos-shell --launcher`
set -euo pipefail
R=$1
fail() { echo "::error::$1"; exit 1; }
if [ "${SHELL_CHECK_TREE:-1}" != 0 ]; then
# The dock lists both windows, the newer one focused.
grep -q "push button 'Flower, running'" "$R/atspi-1.txt" || fail "dock does not list Flower (atspi-1.txt)"
grep -q "push button 'Wayland ClickDot, focused'" "$R/atspi-1.txt" || fail "dock does not show ClickDot focused (atspi-1.txt)"
# Pressing Flower through AT-SPI activated it.
grep -q "push button 'Flower, focused'" "$R/atspi-2.txt" || fail "Flower not activated (atspi-2.txt)"
grep -q "push button 'Wayland ClickDot, running'" "$R/atspi-2.txt" || fail "ClickDot still focused (atspi-2.txt)"
# The app started from the launcher runs and has the focus; the launcher closed.
grep -q "push button 'simple-shm, focused'" "$R/atspi-3.txt" || fail "app from the launcher not running (atspi-3.txt)"
! grep -q "'Search apps'" "$R/atspi-3.txt" || fail "launcher still open after starting an app (atspi-3.txt)"
fi
# The launcher opened with its search field, the fixture app and the dock's button.
grep -q "'Search apps'" "$R/atspi-launcher.txt" || fail "launcher search field not on the bus (atspi-launcher.txt)"
grep -q "push button 'Smoke Test'" "$R/atspi-launcher.txt" || fail "launcher does not list the fixture app (atspi-launcher.txt)"
grep -q "push button 'Open launcher'" "$R/atspi-launcher.txt" || fail "dock has no launcher button (atspi-launcher.txt)"
# Opening times: command start to first frame shown, and the shell's own share.
[ "$(wc -l <"$R/launcher-open-ms.txt")" -eq 5 ] || fail "expected 5 launcher openings, got $(wc -l <"$R/launcher-open-ms.txt") (shell.log)"
echo "launcher opening, command start to frame shown (ms; first is cold): $(paste -sd' ' "$R/launcher-open-ms.txt")"
echo "of which in the shell, request to frame shown (ms): $(paste -sd' ' "$R/launcher-shell-ms.txt")"
if [ -n "${SHELL_OPEN_MS:-}" ]; then
  max=$(sort -n "$R/launcher-open-ms.txt" | tail -1)
  python3 -c "import sys; sys.exit(0 if $max <= $SHELL_OPEN_MS else 1)" || fail "launcher opened in $max ms, over $SHELL_OPEN_MS ms"
fi
# The control centre opened from the dock with its agreed contents (no Brightness: the runner has
# no backlight and the slider is hidden then), and closed again.
for n in "Dark mode, " "Do not disturb, " "Record screen, Not available yet" "'Volume'" "'Open Settings'" "'Power options'"; do
  grep -q "$n" "$R/atspi-cc.txt" || fail "control centre lacks $n (atspi-cc.txt)"
done
! grep -q "'Power options'" "$R/atspi-cc-closed.txt" || fail "control centre still open after the second press (atspi-cc-closed.txt)"
# Opening times, request to first frame shown (the §7 popover budget); every opening, the cold
# first one included, must be within SHELL_OPEN_MS.
[ "$(wc -l <"$R/control-centre-open-ms.txt")" -eq 5 ] || fail "expected 5 control centre openings, got $(wc -l <"$R/control-centre-open-ms.txt") (shell.log)"
echo "control centre opening, request to frame shown (ms; first is cold): $(paste -sd' ' "$R/control-centre-open-ms.txt")"
if [ -n "${SHELL_OPEN_MS:-}" ]; then
  max=$(sort -n "$R/control-centre-open-ms.txt" | tail -1)
  python3 -c "import sys; sys.exit(0 if $max <= $SHELL_OPEN_MS else 1)" || fail "control centre opened in $max ms, over $SHELL_OPEN_MS ms"
fi
# The shell's portal backend answers with the light colour scheme (2) by default.
grep -q "v u 2" "$R/portal-color-scheme.txt" || fail "portal Settings backend did not answer color-scheme 2 ($(cat "$R/portal-color-scheme.txt"))"
# The harness' own verdict (idle CPU, cold start; RSS against §7's 800 MB). 2 = it could not
# measure, always an error. 1 = a §7 breach: an error on the NUC, a warning on hosted runners
# (llvmpipe, shared CPUs, short CPU window: indicative only).
brc=$(cat "$R/budgets.exit" 2>/dev/null) || fail "budgets.exit missing: run.sh did not reach the budgets harness"
[ "$brc" != 2 ] || fail "budgets harness could not measure ($(cat "$R/budgets.err"))"
# Idle memory within the shell's share.
rss=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(next(v for k,v in d.items() if "rss" in k))' "$R/budgets.json")
python3 -c "import sys; sys.exit(0 if $rss <= ${SHELL_RSS_MB:-300} else 1)" || fail "idle RSS $rss MB over the ${SHELL_RSS_MB:-300} MB shell share"
cat "$R/budgets.md"
if [ "$brc" != 0 ]; then
  msg="budget breach (cold start $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cold_start_ms"])' "$R/budgets.json") ms, idle CPU $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["idle_cpu_percent"])' "$R/budgets.json") %), see budgets.md"
  [ "${SHELL_GATE:-0}" = 1 ] && fail "$msg"
  echo "::warning::$msg (advisory on this runner)"
fi
echo "checks passed (idle RSS $rss MB)"
