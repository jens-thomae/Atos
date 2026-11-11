#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Run: bash tools/dev-push/test.sh   (the checks push makes before it touches the PC)
set -eu
d=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091 # push, next to this file
. "$d/push"
fail() { echo "FAIL: $1"; exit 1; }
# Overlay guard, on findmnt -nr -o FSTYPE,OPTIONS --mountpoint /usr lines.
overlay_ok "overlay rw,relatime,lowerdir=/sysroot/x,upperdir=/run/u/upper,workdir=/run/u/work" || fail "rw overlay refused"
overlay_ok "" && fail "no overlay accepted"
overlay_ok "overlay ro,relatime,lowerdir=/sysroot/x,upperdir=/run/u/upper,workdir=/run/u/work" && fail "read-only overlay accepted"
overlay_ok "ext4 rw,relatime" && fail "plain rw mount accepted"
overlay_ok "overlay rw,relatime,lowerdir=/a:/b" && fail "overlay without upper layer accepted"
# Host alias: only literal names on Host lines.
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
printf 'Host github.com\n  User git\nhost atos-pc other\n  HostName 192.168.1.20\nHost *\n  ServerAliveInterval 30\n' >"$t/config"
alias_ok atos-pc "$t/config" || fail "configured alias refused"
alias_ok other "$t/config" || fail "second name on a Host line refused"
for h in 192.168.1.20 atos 'atos-pc;id' 'root@atos-pc' '*' '-oProxyCommand=x' ''; do
  alias_ok "$h" "$t/config" && fail "'$h' accepted"
done
# The builder is the image's own stage up to its first COPY: base pin, dnf packages, rustup; no source.
for s in shell comp; do
  f=$(stage_file "$d/../../components/c1-base/Containerfile" $s)
  grep -q '^ARG BASE=.*@sha256:' <<<"$f" || fail "$s: no pinned base"
  grep -q "^FROM \${BASE} AS $s\$" <<<"$f" || fail "$s: no FROM"
  grep -q 'dnf -y install' <<<"$f" || fail "$s: no packages"
  grep -q 'rustup-init.sha256' <<<"$f" || fail "$s: no pinned rustup"
  grep -q '^COPY' <<<"$f" && fail "$s: copies source"
  grep -c '^FROM' <<<"$f" | grep -qx 1 || fail "$s: more than one stage"
done
echo "dev-push: all checks pass"
