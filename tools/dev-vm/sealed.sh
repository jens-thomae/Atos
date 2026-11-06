#!/bin/bash
# Build, install and boot the sealed base image in the dev VM with Secure Boot (#54).
# Runs inside the VM: tools/dev-vm/vm run tools/dev-vm/sealed.sh <step>
#   build    podman build components/c1-base (aarch64, signed with the committed TEST key)
#   disk     bootc install to-disk into a fresh raw disk image
#   boot     boot it under QEMU with AAVMF Secure Boot firmware in setup mode; systemd-boot
#            enrols the TEST keys (if-safe), resets, then boots the sealed UKI with Secure Boot on
#   tamper   three cases, each on a fresh copy of the installed disk, booted with the keys enrolled:
#            object  the composefs object behind /usr/lib/systemd/systemd, modified, with a valid
#                    fs-verity digest of its own
#            erofs   one byte flipped in the deployed EROFS image, fs-verity re-enabled
#            uki     one hex digit of the composefs digest in the UKI's command line changed
#            `tamper <case>` runs one case
#   all      all four steps
# Disks live on the VM disk in ~/sealed; logs go to tools/dev-vm/out/sealed/.
# QEMU runs without KVM (Apple M1 has no nested virtualisation): a boot takes minutes.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE=localhost/c1-base
WORK=~/sealed
OUT="$HERE/out/sealed"
mkdir -p "$WORK" "$OUT"

# Prints Secure Boot state, `bootc status` and the mounts, then powers off. Passed in as
# systemd credentials over SMBIOS, so the image itself carries no test hook.
REPORT_UNIT='[Unit]
Description=Atos sealed-boot report (dev VM only)
ConditionPathExists=!/etc/initrd-release
After=multi-user.target
[Service]
Type=oneshot
StandardOutput=journal+console
ExecStart=/bin/sh -c "echo ATOS-REPORT-BEGIN; bootctl status --no-pager 2>&1 | head -20; echo; bootc status; echo; cat /proc/cmdline; findmnt -no SOURCE,FSTYPE,OPTIONS /; echo ATOS-REPORT-END"
ExecStartPost=/usr/bin/systemctl poweroff --no-block'

# One systemd credential, passed over SMBIOS: cred <name> <content>
cred() { printf -- '-smbios\0type=11,value=io.systemd.credential.binary:%s=%s\0' "$1" "$(printf '%s' "$2" | base64 -w0)"; }

boot() { # <disk> <log> [fresh]: fresh = new firmware variables, i.e. setup mode
  local disk=$1 log=$2
  [ "${3:-}" = fresh ] || [ ! -f "$WORK/vars.fd" ] && cp /usr/share/AAVMF/AAVMF_VARS.fd "$WORK/vars.fd"
  local CREDS
  mapfile -d '' CREDS < <(
    cred systemd.extra-unit.atos-report.service "$REPORT_UNIT"
    cred systemd.unit-dropin.multi-user.target~atos-report $'[Unit]\nWants=atos-report.service'
    # Without KVM, udev in the initrd needs longer than the default 45 s to find the root partition.
    cred 'systemd.unit-dropin.dev-gpt\x2dauto\x2droot.device~timeout' $'[Unit]\nJobRunningTimeoutSec=10min')
  echo "booting $disk, serial log: $log"
  rm -f "$log"
  timeout 45m qemu-system-aarch64 -machine virt -cpu max -smp 4 -m 4G -display none -nic none \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.secboot.fd \
    -drive if=pflash,format=raw,file="$WORK/vars.fd" \
    -drive if=virtio,format=raw,file="$disk" \
    -serial file:"$log" "${CREDS[@]}" &
  # A good boot powers off after the report; a halted one is stopped here.
  local pid=$! halt='Freezing execution|Entering emergency mode|Kernel panic|[Ss]ecurity [Vv]iolation|Access [Dd]enied'
  while kill -0 "$pid" 2>/dev/null; do
    grep -aqE "$halt" "$log" 2>/dev/null && kill "$pid"
    sleep 5
  done
  tr -d '\r' < "$log" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' \
    | grep -aE "Enrolling|enrolled|secureboot:|ATOS-REPORT|sh\[[0-9]+\]:|fs-verity|/sbin/init|$halt"
}

step_build() { sudo podman build --build-context repo="$HERE/../.." -t "$IMAGE" "$HERE/../../components/c1-base"; }

step_disk() {
  rm -f "$WORK/disk.raw" && truncate -s 20G "$WORK/disk.raw"
  sudo podman run --rm --privileged --pid=host --security-opt label=type:unconfined_t \
    -v /var/lib/containers:/var/lib/containers -v /dev:/dev -v "$WORK:/out" \
    "$IMAGE" bootc install to-disk --generic-image --via-loopback /out/disk.raw
}

step_boot() { boot "$WORK/disk.raw" "$OUT/boot.log" fresh; }

# Tamper cases work on ~/sealed/tampered.raw, with its root at $mnt and its ESP at $esp.
mnt=$WORK/mnt esp=$WORK/esp dev=
open_copy() {
  cp --sparse=always "$WORK/disk.raw" "$WORK/tampered.raw"
  dev=$(sudo losetup -fP --show "$WORK/tampered.raw")
  mkdir -p "$mnt" "$esp"
  sudo mount "$(sudo blkid -t TYPE=ext4 -o device "$dev"p*)" "$mnt"
  sudo mount "$(sudo blkid -t TYPE=vfat -o device "$dev"p*)" "$esp"
}
close_and_boot() { # <case>
  sudo umount "$mnt" "$esp" && sudo losetup -d "$dev"
  boot "$WORK/tampered.raw" "$OUT/tamper-$1.log"
}
# Rewrites <file> with <python expression on bytes b>. A file with fs-verity is immutable, so this
# writes a modified copy over it and re-enables fs-verity: the result has a valid digest of its own.
rewrite() { # <file> <expr> [verity]
  sudo python3 -c 'import sys; p=sys.argv[1]; b=open(p,"rb").read(); open(p+".new","wb").write(eval(sys.argv[2]))' "$1" "$2"
  sudo mv "$1.new" "$1"
  # composefs uses fs-verity with SHA-512 and 4 KiB blocks (fsverity-sha512-12).
  [ "${3:-}" != verity ] || sudo fsverity enable --hash-alg=sha512 --block-size=4096 "$1"
}
# The deployed EROFS image, named by its digest.
deployed_image() { echo "$mnt/composefs/images/$(sudo ls "$mnt/state/deploy")"; }

tamper_object() {
  local img=$WORK/img obj
  mkdir -p "$img"
  # The EROFS image names, per file, the object holding its content.
  sudo mount -t erofs -o ro,loop "$(deployed_image)" "$img"
  obj=$(sudo python3 -c 'import os,sys; print(os.getxattr(sys.argv[1], "trusted.overlay.redirect").decode())' \
    "$img/usr/lib/systemd/systemd")
  sudo umount "$img"
  obj="$mnt/composefs/objects/${obj#/}"
  echo "tampering with $obj (/usr/lib/systemd/systemd): 8 bytes appended"
  rewrite "$obj" 'b + b"tampered"' verity
}
tamper_erofs() {
  local img
  img=$(sudo readlink -f "$(deployed_image)")
  echo "tampering with the deployed EROFS image $img: last byte flipped"
  rewrite "$img" 'b[:-1] + bytes([b[-1] ^ 1])' verity
}
tamper_uki() {
  local uki
  uki=$(sudo find "$esp/EFI/Linux" -name '*.efi')
  echo "tampering with $uki: first digit of composefs.digest= in .cmdline changed"
  rewrite "$uki" '(lambda i: b[:i] + (b"1" if b[i:i+1] == b"0" else b"0") + b[i+1:])(b.find(b"composefs.digest=v1-sha512-12:") + 30)'
}

step_tamper() {
  for c in ${1:-object erofs uki}; do
    open_copy
    "tamper_$c"
    close_and_boot "$c"
  done
}

case "${1:-}" in
  build|disk|boot) "step_$1" ;;
  tamper) step_tamper "${2:-}" ;;
  all) step_build; step_disk; step_boot; step_tamper ;;
  *) sed -n '2,12p' "$0" >&2; exit 2 ;;
esac
