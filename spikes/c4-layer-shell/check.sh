#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Acceptance checks of #59 on one measure.sh result dir: both surfaces are on the AT-SPI bus with
# named controls, and the popover is drawn in every opening path. Usage: check.sh <out dir>
set -euo pipefail
R=$1
grep -q "'Quick settings'" "$R/atspi-1-panel.txt"
grep -q "'Wi-Fi'" "$R/atspi-2-popover.txt"
grep -q "'Bluetooth'" "$R/atspi-2-popover.txt"
cat "$R/popover-pixels.txt"
# One AT-SPI open plus one keyboard open per run (0-cold, 1-cold, 1-warm).
[ "$(wc -l <"$R/popover-pixels.txt")" -eq 4 ] || { echo "::error::expected 4 pixel checks"; exit 1; }
while read -r line; do
  inside=${line#*inside }; inside=${inside%%,*}; outside=${line##*outside }
  [ -n "$inside" ] && [ "$inside" != "$outside" ] || { echo "::error::popover not drawn: $line"; exit 1; }
done <"$R/popover-pixels.txt"
echo "checks passed"
