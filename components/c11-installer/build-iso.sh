#!/bin/bash
# Builds the installer image and the installer ISO (#66). Used by CI and by vm-test.sh.
#   PAYLOAD=<image ref in local containers storage> OUTDIR=<dir> [BASE=<image@digest>] build-iso.sh
# The payload goes into the ISO's containers storage under PAYLOAD, so the install needs no network
# and the installed system tracks PAYLOAD for updates. Writes $OUTDIR/install.iso.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${PAYLOAD:?}" "${OUTDIR:?}"
# image-builder CLI, pinned by digest (v89.0.0).
IB=ghcr.io/osbuild/image-builder-cli@sha256:27d349fee2944029a9e47f5b8db5f4bf68392bc7878909d0c53ad8ddadb1a412
build_arg=()
[ -z "${BASE:-}" ] || build_arg=(--build-arg "BASE=$BASE")

# One retry for network failures inside the build (#246); finished layers come from local storage.
RETRY_ATTEMPTS=2 "$HERE/../../tools/ci/retry.sh" sudo podman build "${build_arg[@]}" --build-context repo="$HERE/../.." -t localhost/atos-installer "$HERE"
mkdir -p "$OUTDIR/ib"
# image-builder's podman 5 rewrites the shared storage's default network backend to netavark,
# which breaks the host's podman 4 (Ubuntu 24.04: CNI). Put it back afterwards.
nb=/var/lib/containers/storage/defaultNetworkBackend
old=$(sudo cat "$nb" 2>/dev/null || true)
trap 'if [ -n "$old" ]; then echo -n "$old" | sudo tee "$nb" >/dev/null; else sudo rm -f "$nb"; fi' EXIT
sudo podman run --rm --privileged --security-opt label=type:unconfined_t \
  -v /var/lib/containers/storage:/var/lib/containers/storage -v "$OUTDIR/ib:/output" \
  "$IB" build --bootc-ref localhost/atos-installer --bootc-installer-payload-ref "$PAYLOAD" \
  --bootc-default-fs ext4 generic-iso
iso=$(sudo find "$OUTDIR/ib" -name '*.iso' -print -quit)
sudo mv "$iso" "$OUTDIR/install.iso" && sudo chown "$(id -u):$(id -g)" "$OUTDIR/install.iso"
sudo rm -rf "$OUTDIR/ib"
ls -l "$OUTDIR/install.iso"
