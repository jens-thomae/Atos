#!/bin/bash
# Runs inside the VM before every `vm run` / `vm up` (docs/dev-environment.md).
# 1. Deletes ~/target/<path> build caches whose checkout <path> no longer exists.
#    Caches of checkouts that still exist are never touched.
# 2. Warns when less than 5 GB is free on the VM disk.
for rc in $(find "$HOME/target" -name .rustc_info.json 2>/dev/null); do
  cache="${rc%/.rustc_info.json}"
  checkout="${cache#"$HOME/target"}"
  [ -d "$checkout" ] || { echo "vm: removing build cache of deleted checkout $checkout" >&2; rm -rf "$cache"; }
done
free_kb=$(df --output=avail / | tail -1)
if [ "$free_kb" -lt 5242880 ]; then
  echo "vm: WARNING only $((free_kb / 1048576)) GB free on the VM disk (need 5 GB). Builds will fail." >&2
  echo "vm: see docs/dev-environment.md, 'Disk space'. Per-checkout caches:" >&2
  du -sh "$HOME"/target/*/*/* 2>/dev/null | sort -h | tail -5 >&2
  echo "vm: delete caches of finished checkouts with: limactl shell ${ATOS_VM:-atos} -- rm -rf ~/target/<checkout path>" >&2
fi
