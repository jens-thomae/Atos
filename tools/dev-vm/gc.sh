#!/bin/bash
# Runs inside the VM before every `vm run` / `vm up` (docs/dev-environment.md).
# 1. Deletes ~/target/<path> build caches whose checkout <path> is under the mounted
#    repo (the main checkout and its worktrees) and no longer exists. Caches of existing
#    checkouts, and of checkouts outside the mount (not visible here), are never touched.
# 2. Warns when less than 5 GB is free on the VM disk.
# GC_TARGET_ROOT and GC_MOUNT_ROOT exist for tools/dev-vm/gc-test.sh.
TARGET="${GC_TARGET_ROOT:-$HOME/target}"
MOUNT="${GC_MOUNT_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"

# Mount missing: every checkout would look deleted, so do nothing.
if [ -n "$TARGET" ] && [ "${TARGET#/}" != "$TARGET" ] && [ -n "$MOUNT" ] && [ -d "$MOUNT" ] && [ -d "$TARGET" ]; then
  # Do not descend into debug/release: a cache is found at its root. The main checkout's
  # cache nests the worktree caches, so a hit must not prune the rest.
  find "$TARGET" \( -name debug -o -name release \) -prune -o -name .rustc_info.json -type f -print0 |
    while IFS= read -r -d '' rc; do
      cache="${rc%/.rustc_info.json}"
      checkout="${cache#"$TARGET"}"
      # Only an absolute path strictly under TARGET, whose checkout is under the mount.
      [ "$cache" != "$TARGET" ] && [ "${checkout#/}" != "$checkout" ] && [ "$checkout" != "/" ] || continue
      case "$checkout/" in "$MOUNT"/*) ;; *) continue ;; esac
      [ -d "$checkout" ] && continue
      echo "vm: removing build cache of deleted checkout $checkout" >&2
      rm -rf -- "$cache"
    done
fi

free_kb=$(df --output=avail / | tail -1)
if [ "$free_kb" -lt "${GC_MIN_FREE_KB:-5242880}" ]; then
  echo "vm: WARNING only $((free_kb / 1048576)) GB free on the VM disk (need 5 GB). Builds will fail." >&2
  echo "vm: see docs/dev-environment.md, 'Disk space'. Largest build caches:" >&2
  du -sh "$HOME"/target/*/*/* 2>/dev/null | sort -h | tail -5 >&2
  echo "vm: delete caches of finished checkouts with: limactl shell ${ATOS_VM:-atos} -- rm -rf ~/target/<checkout path>" >&2
fi
