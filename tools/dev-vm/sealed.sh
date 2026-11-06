#!/bin/bash
# Build, install and boot the sealed base image in the dev VM with Secure Boot (#54).
# Runs inside the VM: tools/dev-vm/vm run tools/dev-vm/sealed.sh <step>
#   build    podman build components/c1-base (aarch64, signed with the committed TEST key)
#   disk     bootc install to-disk into a fresh raw disk image
#   boot     boot it under QEMU with AAVMF Secure Boot firmware in setup mode; systemd-boot
#            enrols the TEST keys (if-safe), resets, then boots the sealed UKI with Secure Boot on
#   tamper   copy the disk, swap the composefs object behind /usr/lib/systemd/systemd for a
#            modified one (with a valid fs-verity digest of its own), and boot that copy
#   all      all four
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
  rm -f "$log"
  timeout 45m qemu-system-aarch64 -machine virt -cpu max -smp 4 -m 4G -display none -nic none \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.secboot.fd \
    -drive if=pflash,format=raw,file="$WORK/vars.fd" \
    -drive if=virtio,format=raw,file="$disk" \
    -serial file:"$log" "${CREDS[@]}" &
  # A good boot powers off after the report; a halted one is stopped here.
  local pid=$! halt='Freezing execution|Entering emergency mode|Kernel panic'
  while kill -0 "$pid" 2>/dev/null; do
    grep -aqE "$halt" "$log" 2>/dev/null && kill "$pid"
    sleep 5
  done
  tr -d '\r' < "$log" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' \
    | grep -aE "Enrolling|enrolled|secureboot:|ATOS-REPORT|sh\[[0-9]+\]:|fs-verity|/sbin/init|$halt"
}

step_build() { sudo podman build -t "$IMAGE" "$HERE/../../components/c1-base"; }

step_disk() {
  rm -f "$WORK/disk.raw" && truncate -s 20G "$WORK/disk.raw"
  sudo podman run --rm --privileged --pid=host --security-opt label=type:unconfined_t \
    -v /var/lib/containers:/var/lib/containers -v /dev:/dev -v "$WORK:/out" \
    "$IMAGE" bootc install to-disk --generic-image --via-loopback /out/disk.raw
}

step_boot() { boot "$WORK/disk.raw" "$OUT/boot.log" fresh; }

step_tamper() {
  cp --sparse=always "$WORK/disk.raw" "$WORK/tampered.raw"
  local dev mnt=$WORK/mnt img=$WORK/img
  dev=$(sudo losetup -fP --show "$WORK/tampered.raw")
  mkdir -p "$mnt" "$img"
  sudo mount "$(sudo blkid -t TYPE=ext4 -o device "$dev"p*)" "$mnt"
  # The deployed EROFS image (named by its digest) names, per file, the object holding its content.
  sudo mount -t erofs -o ro,loop "$mnt/composefs/images/$(sudo ls "$mnt/state/deploy")" "$img"
  local obj
  obj=$(sudo python3 -c 'import os,sys; print(os.getxattr(sys.argv[1], "trusted.overlay.redirect").decode())' \
    "$img/usr/lib/systemd/systemd")
  obj="$mnt/composefs/objects/${obj#/}"
  echo "tampering with $obj (/usr/lib/systemd/systemd)"
  # Objects are immutable while fs-verity is on, so: copy, modify, replace, re-enable verity.
  sudo cp -a "$obj" "$obj.new" && printf 'tampered' | sudo tee -a "$obj.new" >/dev/null
  sudo mv "$obj.new" "$obj" && sudo fsverity enable "$obj"
  sudo umount "$img" "$mnt" && sudo losetup -d "$dev"
  boot "$WORK/tampered.raw" "$OUT/tamper.log"
}

case "${1:-}" in
  build|disk|boot|tamper) "step_$1" ;;
  all) step_build; step_disk; step_boot; step_tamper ;;
  *) sed -n '2,12p' "$0" >&2; exit 2 ;;
esac
