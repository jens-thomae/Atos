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
t=$(mktemp -d); trap 'rm -rf "$t" 2>/dev/null || true' EXIT # podman's files in it: removed by its reset below
printf 'Host github.com\n  User git\nhost atos-pc other\n  HostName 192.168.1.20\nHost *\n  ServerAliveInterval 30\n' >"$t/config"
alias_ok atos-pc "$t/config" || fail "configured alias refused"
alias_ok other "$t/config" || fail "second name on a Host line refused"
printf 'Host -Fx\n' >>"$t/config"  # a leading - would be read as an ssh option
for h in -Fx 192.168.1.20 atos 'atos-pc;id' 'root@atos-pc' '*' '-oProxyCommand=x' ''; do
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
# Builder twice, then with a changed recipe, under the image's own container policy (#201: the
# second push failed). Needs podman; CI's ubuntu-24.04 has it. A private HOME keeps it apart.
if command -v podman >/dev/null; then
  h=$t/home; c=$h/.config/containers; mkdir -p "$c" "$h/w/components/c1-base"
  # podman < 5 does not know keyPaths; with keyPath the policy is otherwise the image's own.
  sed 's/"keyPaths": \["\([^"]*\)"\]/"keyPath": "\1"/' "$d/../../components/c1-base/usr/share/containers/policy.json" >"$c/policy.json"
  grep -q '"containers-storage"' "$c/policy.json" || fail "policy has no containers-storage rule"
  # Own runtime dir, so no systemd user session to talk to (CI has none either).
  printf '[engine]\ncgroup_manager = "cgroupfs"\nevents_logger = "file"\n' >"$c/containers.conf"
  cf=$h/w/components/c1-base/Containerfile
  # shellcheck disable=SC2016 # ${BASE} is for podman
  printf 'ARG BASE=registry.fedoraproject.org/fedora-minimal:43\nFROM ${BASE} AS shell\nRUN echo 1 >/v\nCOPY --from=repo x y\n' >"$cf"
  (
    mkdir -m 700 "$h/run"
    export HOME=$h XDG_CONFIG_HOME=$h/.config XDG_DATA_HOME=$h/.local/share XDG_RUNTIME_DIR=$h/run
    cd "$h/w"
    # shellcheck disable=SC2154 # cache: set in push
    mkdir -p "$h/$cache/src" "$h/$cache/target"
    builder shell || fail "first builder"
    builder shell || fail "second builder (cached recipe)"
    in_builder shell 'grep -qx 1 /v' || fail "builder image does not run"
    sed -i 's/echo 1/echo 2/' "$cf"
    builder shell || fail "builder after a recipe change"
    in_builder shell 'grep -qx 2 /v' || fail "changed builder does not run"
    [ "$(podman images -q --filter reference=localhost/atos-dev-push-shell | wc -l)" = 1 ] || fail "old builder kept"
    podman system reset -f >/dev/null 2>&1 || true # private runtime dir and storage: only this test's
  ) || exit 1
  echo "dev-push: builder twice under the image policy: ok"
else
  echo "dev-push: no podman, builder policy check skipped"
fi
echo "dev-push: all checks pass"
