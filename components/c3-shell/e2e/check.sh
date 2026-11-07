#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Acceptance checks of #63 on one run.sh result dir. Usage: check.sh <out dir>
#   SHELL_RSS_MB      the shell's share of idle memory (D-006: 300 MB)
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
# Idle memory within the shell's share.
rss=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(next(v for k,v in d.items() if "rss" in k))' "$R/budgets.json")
python3 -c "import sys; sys.exit(0 if $rss <= ${SHELL_RSS_MB:-300} else 1)" || fail "idle RSS $rss MB over the ${SHELL_RSS_MB:-300} MB shell share"
cat "$R/budgets.md"
echo "checks passed (idle RSS $rss MB)"
