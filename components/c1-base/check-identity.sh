#!/bin/bash
# Checks that <image> identifies itself as Atos, not Fedora (#248; docs/components/c1-base/README.md, "Identity"):
# 1. Fedora's release and logo packages are gone (Fedora trademark guidelines: a derived system removes
#    fedora-release, fedora-logos and fedora-release-notes);
# 2. os-release, system-release and issue name Atos and no Fedora or Red Hat name, logo or URL;
#    the one allowed mention is ID_LIKE=fedora;
# 3. the UKI's embedded os-release (.osrel, read by systemd-boot and bootc) equals the image's,
#    if the image has a UKI (c1-base does, the installer image does not);
# 4. no Fedora logo or icon file is in the image.
# Rootless podman is enough; objcopy (binutils) reads the UKI. Usage: check-identity.sh <image>
set -euo pipefail
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
fail() { echo "identity: $*" >&2; exit 1; }

c=$(podman create "$1")
podman cp "$c:/usr/lib/os-release" "$d/os-release"
podman cp "$c:/usr/lib/fedora-release" "$d/system-release"
podman cp "$c:/usr/lib/issue" "$d/issue"
podman cp "$c:/usr/lib/issue.net" "$d/issue.net"
podman cp "$c:/boot/EFI/Linux" "$d/uki" 2>/dev/null || true
podman rm "$c" >/dev/null

# shellcheck disable=SC2016 # expands in the image
podman run --rm "$1" sh -c '
  ! rpm -q fedora-release fedora-release-common fedora-logos fedora-release-notes \
      $(rpm -qa "fedora-release-*" "fedora-logos*") 2>/dev/null | grep -v "is not installed" &&
  ! find /usr/share/icons /usr/share/pixmaps /usr/share/plymouth -iname "*fedora*" 2>/dev/null | grep .' \
  || fail "Fedora release or logo packages or files are in the image (listed above)"

for l in 'NAME="Atos"' 'ID=atos' 'DEFAULT_HOSTNAME="atos"'; do
  grep -qx "$l" "$d/os-release" || fail "os-release lacks $l"
done
grep -qx 'Atos release [0-9]*' "$d/system-release" || fail "system-release does not name Atos: $(cat "$d/system-release")"
for f in os-release system-release issue issue.net; do
  ! grep -v -x 'ID_LIKE=fedora' "$d/$f" | grep -inE 'fedora|red ?hat|bugzilla' || fail "$f names Fedora or Red Hat (above)"
done

for uki in "$d"/uki/*.efi; do
  [ -e "$uki" ] || continue
  objcopy -O binary --only-section=.osrel "$uki" "$d/osrel"
  cmp -s "$d/os-release" "$d/osrel" || { diff "$d/os-release" "$d/osrel" >&2 || true; fail "the UKI's .osrel differs from os-release: ${uki#"$d"/}"; }
  echo "UKI carries the Atos os-release: ${uki#"$d"/}"
done
echo "identity: $(sed -n 's/^PRETTY_NAME=//p' "$d/os-release"), no Fedora identity"
