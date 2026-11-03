#!/bin/sh
# D-006 fixture: same names, sizes and mtimes on every run (POSIX sh, no GNU extensions).
set -eu
root=${1:?usage: make-fixture.sh <new-dir>}
[ ! -e "$root" ] || { echo "make-fixture.sh: $root already exists" >&2; exit 1; }
export TZ=UTC LC_ALL=C

# file <path> <size in bytes>: sparse file of that size
file() { dd if=/dev/zero of="$1" bs=1 count=0 seek="$2" 2>/dev/null; }
# stamp <path> <minutes after 2026-01-01 00:00 UTC> (< 31 days)
stamp() { touch -t "$(printf '202601%02d%02d%02d' $(($2 / 1440 + 1)) $(($2 % 1440 / 60)) $(($2 % 60)))" "$1"; }

mkdir -p "$root/small/docs/2026/november" "$root/small/empty" "$root/10k"
for f in notes-1.txt:120 notes-2.txt:2048 notes-3.txt:0 photo.png:345678 report.pdf:1048576 \
    'with space.md':64 'Ünïcödé.txt':10; do
    file "$root/small/${f%:*}" "${f##*:}"
done
i=1
while [ "$i" -le 10000 ]; do
    p=$(printf '%s/10k/item-%05d' "$root" "$i")
    if [ $((i % 100)) -eq 0 ]; then
        mkdir "$p"
    else
        case $((i % 5)) in 0) e=txt ;; 1) e=png ;; 2) e=pdf ;; 3) e=rs ;; *) e=md ;; esac
        p=$p.$e
        file "$p" $((i * 7919 % 1048576))
    fi
    stamp "$p" "$i"
    i=$((i + 1))
done
# Children first, so creating entries does not move a folder's mtime afterwards.
find "$root/small" -depth -exec touch -t 202601010000 {} +
stamp "$root/10k" 0
stamp "$root" 0
