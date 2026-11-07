#!/bin/bash
# Checks that <image> is sealed (#54):
# 1. the UKI and systemd-boot are signed by the TEST db key (sbverify, from sbsigntool), and
# 2. the UKI carries the composefs digest that `bootc install` computes from the image's OCI
#    layers; bootc install refuses an image where the two differ.
# Rootless podman is enough. Usage: check-seal.sh <image>
set -euo pipefail
cert="$(cd "$(dirname "$0")" && pwd)/secureboot-test/db.crt"
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT

c=$(podman create "$1")
podman cp "$c:/boot/EFI/Linux" "$d/uki" && podman cp "$c:/usr/lib/systemd/boot/efi" "$d/sdboot"
podman rm "$c" >/dev/null
for f in "$d"/uki/*.efi "$d"/sdboot/systemd-boot*.efi.signed; do
  sbverify --cert "$cert" "$f" >/dev/null || { echo "not signed by the TEST db key: ${f#"$d"/}" >&2; exit 1; }
  echo "signed by the TEST db key: ${f#"$d"/}"
done

podman save -q --format oci-archive -o "$d/image.tar" "$1"
podman run --rm -v "$d:/w" "$1" sh -euc '
  cfs="bootc internals cfs --repo /w/repo --insecure"
  mkdir /w/repo && $cfs init >/dev/null
  $cfs oci pull oci-archive:/w/image.tar image >/dev/null && rm /w/image.tar
  id=$($cfs oci compute-id --bootable image)
  grep -qa "composefs.digest=v1-sha512-12:$id " /boot/EFI/Linux/*.efi \
    || { echo "UKI does not seal this image (composefs digest $id)" >&2; exit 1; }
  echo "UKI seals composefs image $id"'
# measurement
