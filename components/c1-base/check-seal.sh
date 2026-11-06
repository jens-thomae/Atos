#!/bin/bash
# Checks that the sealed UKI in <image> carries the composefs digest that `bootc install` computes
# from the image's OCI layers, i.e. that the image installs and boots sealed (#54). bootc install
# refuses an image where the two differ. Rootless podman is enough. Usage: check-seal.sh <image>
set -euo pipefail
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
podman save -q --format oci-archive -o "$d/image.tar" "$1"
podman run --rm -v "$d:/w" "$1" sh -euc '
  cfs="bootc internals cfs --repo /w/repo --insecure"
  mkdir /w/repo && $cfs init >/dev/null
  $cfs oci pull oci-archive:/w/image.tar image >/dev/null && rm /w/image.tar
  id=$($cfs oci compute-id --bootable image)
  grep -qa "composefs.digest=v1-sha512-12:$id " /boot/EFI/Linux/*.efi \
    || { echo "UKI does not seal this image (composefs digest $id)" >&2; exit 1; }
  echo "UKI seals composefs image $id"'
