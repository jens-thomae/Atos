#!/bin/bash
# Checks the NVIDIA driver in a built c1-base image (D-017, #162; docs/components/c1-base/nvidia.md):
# 1. exactly our four modules, each signed by the TEST db key, with the image's vermagic and the
#    pinned driver version, which the userspace has too;
# 2. NVIDIA's packaged files are unmodified: every installed file is verified against the pinned
#    RPM Fusion packages, downloaded fresh and signature-checked;
# 3. NVIDIA's licence is installed, the NGX updater is not turned on, NVK is present;
# 4. driver selection, module options and the suspend services are in place.
# That the initramfs has no NVIDIA or nouveau module is checked when it is built (Containerfile, `kernel`).
# Rootless podman and network access are enough. Usage: check.sh <image>
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
podman run --rm -v "$here:/nv:ro,z" "$1" bash -euo pipefail -c '
fail() { echo "FAIL: $*" >&2; exit 1; }
. /nv/UPSTREAM; kver=$(ls /usr/lib/modules); dir=/usr/lib/modules/$kver/extra/nvidia

# Outside kernel/, where the in-tree modules are (aarch64 has nvidia_* perf drivers there).
found=$(find /usr/lib/modules -name "nvidia*.ko*" ! -path "*/$kver/kernel/*" | sort)
want=$(for m in nvidia nvidia-drm nvidia-modeset nvidia-uvm; do echo "$dir/$m.ko"; done | sort)
[ "$found" = "$want" ] || fail "NVIDIA modules in the image: $found"
for m in $found; do
  [ "$(modinfo -F signer "$m")" = "Atos TEST db - not for release, do not trust" ] || fail "$m: signer $(modinfo -F signer "$m")"
  [ "$(modinfo -F vermagic "$m" | cut -d" " -f1)" = "$kver" ] || fail "$m: vermagic $(modinfo -F vermagic "$m")"
done
[ "$(modinfo -F version "$dir/nvidia.ko")" = "$tag" ] || fail "nvidia.ko version $(modinfo -F version "$dir/nvidia.ko"), pinned $tag"
[ "$(rpm -q --qf "%{VERSION}" xorg-x11-drv-nvidia)" = "$tag" ] || fail "userspace $(rpm -q xorg-x11-drv-nvidia), modules $tag"
echo "ok: 4 modules signed by the TEST db key, vermagic $kver, driver $tag = userspace"

pkgs=""
for p in xorg-x11-drv-nvidia xorg-x11-drv-nvidia-libs xorg-x11-drv-nvidia-cuda xorg-x11-drv-nvidia-cuda-libs \
         xorg-x11-drv-nvidia-power nvidia-modprobe nvidia-persistenced; do pkgs="$pkgs $p-$userspace"; done
k=/nv/RPM-GPG-KEY-rpmfusion-nonfree-fedora-2020
dnf -q download --repofrompath="rpmfusion-nonfree,$rpmfusion/$(uname -m)/os/" --repo=rpmfusion-nonfree \
  --setopt=rpmfusion-nonfree.gpgcheck=1 --setopt=rpmfusion-nonfree.gpgkey="file://$k" --destdir /tmp/rpm $pkgs
rpmkeys --import "$k"; rpmkeys --checksig /tmp/rpm/*.rpm >/dev/null || fail "RPM Fusion package signature"
# Digest, size, mode, owner of every file the packages ship. Documentation is not installed (nodocs).
diff=$(rpm -Vp --nodeps --nomtime /tmp/rpm/*.rpm | grep -v " d /usr/share/\(doc\|man\)/" || true)
[ -z "$diff" ] || fail "files differ from the packages:
$diff"
echo "ok: $(rpm -qlp /tmp/rpm/*.rpm | wc -l) packaged paths match the signed RPM Fusion packages"

head -1 /usr/share/licenses/xorg-x11-drv-nvidia/LICENSE | grep -qx "NVIDIA Driver License Agreement" || fail "NVIDIA licence missing"
! grep -rsqE "\"allow_ngx_updater\"[[:space:]]*:[[:space:]]*true" /usr/share/nvidia /etc || fail "NGX updater turned on"
ls /usr/share/vulkan/icd.d/nouveau_icd.*.json >/dev/null || fail "NVK missing"
echo "ok: NVIDIA licence installed, NGX updater not turned on, NVK present"

conf=$(modprobe -c)
for l in "softdep nouveau pre: nvidia-drm" "options nvidia_drm modeset=1 fbdev=1" \
         "options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_TemporaryFilePath=/var/tmp"; do
  grep -qxF "$l" <<<"$conf" || fail "modprobe config lacks: $l"
done
for s in nvidia-suspend nvidia-resume nvidia-hibernate nvidia-suspend-then-hibernate; do
  [ "$(systemctl is-enabled "$s.service")" = enabled ] || fail "$s.service not enabled"
done
echo "ok: driver selection, module options and suspend services"
'
