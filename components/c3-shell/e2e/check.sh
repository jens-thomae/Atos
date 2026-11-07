#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Acceptance checks of #63, #65 on one run.sh result dir. Usage: check.sh <out dir>
#   SHELL_RSS_MB      the shell's share of idle memory (D-006: 300 MB)
#   SHELL_OPEN_MS     if set, every control centre opening must be at most this (§7 popover: 100 ms)
#   SHELL_CHECK_TREE  0 skips the dock checks (no client windows ran)
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
fi
# The control centre opened from the dock with its agreed contents (no Brightness: the runner has
# no backlight and the slider is hidden then), and closed again.
for n in "Dark mode, " "Do not disturb, " "Record screen, Not available yet" "'Volume'" "'Open Settings'" "'Power options'"; do
  grep -q "$n" "$R/atspi-cc.txt" || fail "control centre lacks $n (atspi-cc.txt)"
done
! grep -q "'Power options'" "$R/atspi-cc-closed.txt" || fail "control centre still open after the second press (atspi-cc-closed.txt)"
# Opening times, press to first frame shown (the §7 popover budget).
[ "$(wc -l <"$R/control-centre-open-ms.txt")" -eq 5 ] || fail "expected 5 control centre openings, got $(wc -l <"$R/control-centre-open-ms.txt") (shell.log)"
echo "control centre opening (ms, five times): $(paste -sd' ' "$R/control-centre-open-ms.txt")"
if [ -n "${SHELL_OPEN_MS:-}" ]; then
  max=$(sort -n "$R/control-centre-open-ms.txt" | tail -1)
  python3 -c "import sys; sys.exit(0 if $max <= $SHELL_OPEN_MS else 1)" || fail "control centre opened in $max ms, over $SHELL_OPEN_MS ms"
fi
# The shell's portal backend answers with the light colour scheme (2) by default.
grep -q "v u 2" "$R/portal-color-scheme.txt" || fail "portal Settings backend did not answer color-scheme 2 ($(cat "$R/portal-color-scheme.txt"))"
# Idle memory within the shell's share.
rss=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(next(v for k,v in d.items() if "rss" in k))' "$R/budgets.json")
python3 -c "import sys; sys.exit(0 if $rss <= ${SHELL_RSS_MB:-300} else 1)" || fail "idle RSS $rss MB over the ${SHELL_RSS_MB:-300} MB shell share"
cat "$R/budgets.md"
echo "checks passed (idle RSS $rss MB)"
