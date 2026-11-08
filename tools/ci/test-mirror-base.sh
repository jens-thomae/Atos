#!/usr/bin/env bash
# Run: bash tools/ci/test-mirror-base.sh
# Check mode of mirror-base.sh against a fake skopeo (no network): a good pin passes; a digest that differs
# from `# upstream:`, a quay.io pin and mirror bytes that do not match the digest all fail.
set -eu
s=$(cd "$(dirname "$0")" && pwd)/mirror-base.sh
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
printf '{"fake":"index"}' > "$t/index"
d=sha256:$(sha256sum < "$t/index" | cut -d' ' -f1)
mkdir "$t/bin" "$t/repo" && printf '#!/bin/sh\ncat "%s"\n' "$t/index" > "$t/bin/skopeo" && chmod +x "$t/bin/skopeo"
git -C "$t/repo" init -q && mkdir -p "$t/repo/components/x"
run() { printf '%s\n' "$@" > "$t/repo/components/x/Containerfile"; (cd "$t/repo" && PATH="$t/bin:$PATH" bash "$s") > /dev/null 2>&1; }
other=sha256:$(printf 0%.0s {1..64})

run "# upstream: quay.io/fedora/fedora-bootc:45@$d" "ARG BASE=ghcr.io/jens-thomae/atos/fedora-bootc:45.1@$d" \
  || { echo "FAIL: good pin rejected"; exit 1; }
! run "# upstream: quay.io/fedora/fedora-bootc:45@$other" "ARG BASE=ghcr.io/jens-thomae/atos/fedora-bootc:45.1@$d" \
  || { echo "FAIL: upstream digest mismatch accepted"; exit 1; }
! run "# upstream: quay.io/fedora/fedora-bootc:45@$d" "ARG BASE=quay.io/fedora/fedora-bootc:45@$d" \
  || { echo "FAIL: quay.io pin accepted"; exit 1; }
! run "# upstream: quay.io/fedora/fedora-bootc:45@$other" "ARG BASE=ghcr.io/jens-thomae/atos/fedora-bootc:45.1@$other" \
  || { echo "FAIL: mirror bytes not matching the digest accepted"; exit 1; }
echo ok
