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
#   update   the update and rollback loop (#55), on its own disk ~/sealed/update.raw. Steps:
#            images    builds dev-1 (as shipped) and dev-2 (plus IMAGE_VERSION=dev-2 in os-release,
#                      VM-only), pushes both to a registry in this VM (localhost:5000)
#            install   installs dev-1, tracking <registry>/atos/c1-base:latest, which points at dev-1
#            stage     points :latest at dev-2, boots dev-1 with networking, runs `bootc upgrade`
#            apply     boots the default entry: dev-2
#            previous  opens the boot menu and picks the second entry with the arrow keys: dev-1
#            rollback  boots the default entry (dev-2) and runs `bootc rollback`
#            back      boots the default entry: dev-1
#            `update <step>` runs one step; `update` runs all of them in order
#   counting automatic rollback through boot counting (#56), on its own disk ~/sealed/counting.raw:
#            images      as for `update`, plus dev-bad (dev-2 whose atos-comp is /usr/bin/false)
#            install     installs dev-1, as `update install` does
#            stage-good  boots dev-1, stages dev-2 (`bootc upgrade` writes its entry with `+3`)
#            good        boots dev-2 (counted), the health check passes, the entry loses its counter
#            stage-bad   boots dev-2, stages dev-bad
#            bad         boots dev-bad three times, the health check fails and reboots each time,
#                        then systemd-boot boots dev-2 by itself
#            `counting <step>` runs one step; `counting` runs all of them in order
# Disks live on the VM disk in ~/sealed; logs go to tools/dev-vm/out/sealed/.
# QEMU runs without KVM (Apple M1 has no nested virtualisation): a boot takes minutes.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE=localhost/c1-base
WORK=~/sealed
OUT="$HERE/out/sealed"
mkdir -p "$WORK" "$OUT"

# Once startup has finished: prints Secure Boot state, `bootc status`, the mounts, the image's
# IMAGE_VERSION and boot time, runs the optional `atos.action` credential (ACTION=<script>),
# then powers off. Passed in as systemd credentials over SMBIOS, so the image carries no test hook.
# shellcheck disable=SC2016 # expands in the guest
REPORT_UNIT='[Unit]
Description=Atos sealed-boot report (dev VM only)
ConditionPathExists=!/etc/initrd-release
After=multi-user.target
[Service]
Type=exec
ImportCredential=atos.*
StandardOutput=journal+console
ExecStart=/bin/sh -c "systemctl is-system-running --wait >/dev/null; echo ATOS-REPORT-BEGIN; bootctl status --no-pager 2>&1 | head -20; echo; bootc status; echo; cat /proc/cmdline; findmnt -no SOURCE,FSTYPE,OPTIONS /; grep -s IMAGE_VERSION /usr/lib/os-release; systemd-analyze; [ ! -f $$CREDENTIALS_DIRECTORY/atos.action ] || sh -x $$CREDENTIALS_DIRECTORY/atos.action; echo ATOS-REPORT-END; systemctl poweroff --no-block"'

# Every boot, early: the image version and the boot counter systemd-boot reports (the entry file
# after its rename, e.g. `...+2-1.conf`; none for an entry without a counter).
# shellcheck disable=SC2016 # expands in the guest
BOOTINFO='v=$(sed -n s/^IMAGE_VERSION=//p /usr/lib/os-release)
e=$(tail -c +5 /sys/firmware/efi/efivars/LoaderBootCountPath-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f 2>/dev/null | tr -d "\000")
echo "ATOS-BOOT image=${v:-dev-1} counter=${e:-none}"'
# shellcheck disable=SC2016 # systemd expands it
BOOTINFO_UNIT='[Unit]
Description=Atos boot info (dev VM only)
ConditionPathExists=!/etc/initrd-release
After=local-fs.target
[Service]
Type=oneshot
ImportCredential=atos.*
StandardOutput=journal+console
ExecStart=/bin/sh ${CREDENTIALS_DIRECTORY}/atos.bootinfo'

# One systemd credential, passed over SMBIOS: cred <name> <content>
cred() { printf -- '-smbios\0type=11,value=io.systemd.credential.binary:%s=%s\0' "$1" "$(printf '%s' "$2" | base64 -w0)"; }

# Env for boot(): VARS=<firmware variables file>, ACTION=<script run after the report>,
# NET=1 for user networking (the guest reaches this VM at 10.0.2.2), MENU=1 to open the
# systemd-boot menu and pick its second entry through the serial console.
boot() { # <disk> <log> [fresh]: fresh = new firmware variables, i.e. setup mode
  local disk=$1 log=$2 vars=${VARS:-$WORK/vars.fd}
  [ "${3:-}" = fresh ] || [ ! -f "$vars" ] && cp /usr/share/AAVMF/AAVMF_VARS.fd "$vars"
  local CREDS
  mapfile -d '' CREDS < <(
    cred systemd.extra-unit.atos-report.service "$REPORT_UNIT"
    cred systemd.unit-dropin.multi-user.target~atos-report $'[Unit]\nWants=atos-report.service'
    # Without KVM, udev in the initrd needs longer than the default 45 s to find the root partition.
    cred 'systemd.unit-dropin.dev-gpt\x2dauto\x2droot.device~timeout' $'[Unit]\nJobRunningTimeoutSec=10min'
    # The same for the boot-counting timeouts (#56): a counted boot takes minutes here.
    cred systemd.unit-dropin.atos-session-check.service~vm $'[Service]\nTimeoutStartSec=20min'
    cred systemd.unit-dropin.boot-complete.target~vm $'[Unit]\nJobTimeoutSec=40min'
    cred systemd.extra-unit.atos-bootinfo.service "$BOOTINFO_UNIT"
    cred systemd.unit-dropin.sysinit.target~atos-bootinfo $'[Unit]\nWants=atos-bootinfo.service'
    cred atos.bootinfo "$BOOTINFO"
    [ -z "${ACTION:-}" ] || cred atos.action "$ACTION")
  local nic=(-nic none) serial=(-serial file:"$log") sock=$WORK/serial.sock
  # shellcheck disable=SC2054 # commas are QEMU option syntax; no PXE option ROM (not installed)
  [ -z "${NET:-}" ] || nic=(-netdev user,id=n0 -device virtio-net-pci,netdev=n0,romfile=)
  # shellcheck disable=SC2054
  [ -z "${MENU:-}" ] || serial=(-chardev socket,id=s0,path="$sock",server=on,wait=off,logfile="$log" -serial chardev:s0)
  echo "booting $disk, serial log: $log"
  rm -f "$log" "$sock"
  # virtio-gpu: atos-comp needs a DRM device for the session the health check (#56) waits for.
  timeout "${TIMEOUT:-45m}" qemu-system-aarch64 -machine virt -cpu max -smp 4 -m 4G -display none \
    -device virtio-gpu-pci "${nic[@]}" \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.secboot.fd \
    -drive if=pflash,format=raw,file="$vars" \
    -drive if=virtio,format=raw,file="$disk" \
    "${serial[@]}" "${CREDS[@]}" &
  local pid=$!
  [ -z "${MENU:-}" ] || pick_second_entry "$sock"
  # A good boot powers off after the report; a halted one is stopped here.
  local halt='Freezing execution|Entering emergency mode|Kernel panic|[Ss]ecurity [Vv]iolation|Access [Dd]enied'
  while kill -0 "$pid" 2>/dev/null; do
    # The firmware tries its built-in EFI Shell first, which Secure Boot refuses: not a halt.
    grep -av 'EFI Internal Shell' "$log" 2>/dev/null | grep -aqE "$halt" && kill "$pid"
    sleep 5
  done
  tr -d '\r' < "$log" | grep -av 'EFI Internal Shell' | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' \
    | grep -aE "Enrolling|enrolled|secureboot:|ATOS-REPORT|ATOS-BOOT|sh\[[0-9]+\]:|session-check|boot is (good|bad)|reboot: Restarting|fs-verity|/sbin/init|$halt"
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

# Holds space until systemd-boot shows its menu (with timeout 0 it is hidden otherwise), then
# picks the second entry: Down, Enter. Types on the serial console, as a user at the keyboard.
# Keeps reading the console until QEMU exits: an unread socket fills up and blocks the guest.
pick_second_entry() { # <serial socket>
  python3 - "$1" <<'EOF' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
for _ in range(100):
    try:
        s.connect(sys.argv[1])
        break
    except OSError:
        time.sleep(0.1)
s.settimeout(0.5)
seen, picked = b"", False
while True:
    try:
        data = s.recv(65536)
        if not data:
            break
        seen = (seen + data)[-4096:]
    except socket.timeout:
        pass
    if picked:
        continue
    if b"Fedora Linux" in seen:  # the menu lists the entries by their title
        time.sleep(2)
        s.send(b"\x1b[B")
        time.sleep(1)
        s.send(b"\r")
        picked = True
    else:
        s.send(b" ")
EOF
}

# Update loop (#55). The registry runs in this VM; the QEMU guest reaches it at 10.0.2.2.
REG=localhost:5000/atos/c1-base GUEST_REG=10.0.2.2:5000/atos/c1-base
UDISK=$WORK/update.raw UVARS=$WORK/update-vars.fd
registry_up() { # CNCF distribution (registry:2), pinned by digest; dev VM only, plain HTTP
  sudo podman container exists atos-registry || sudo podman create --name atos-registry -p 5000:5000 \
    docker.io/library/registry:2@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373 >/dev/null
  sudo podman start atos-registry >/dev/null
}
push() { sudo podman push -q --tls-verify=false "$1" "docker://$2"; } # <local image> <registry ref>

# dev-2 differs from dev-1 by one line in os-release, inside the sealed digest, so the boot menu
# and `bootc status` can tell them apart. The shipped Containerfile is not changed.
update_images() {
  local ctx="$HERE/../../components/c1-base"
  registry_up
  sudo podman build --build-context repo="$HERE/../.." \
    -t "$IMAGE:dev-1" "$ctx"
  sed '/^LABEL org.opencontainers.image.title/i RUN echo IMAGE_VERSION=dev-2 >> /usr/lib/os-release' \
    "$ctx/Containerfile" > "$WORK/Containerfile.dev-2"
  grep -q IMAGE_VERSION=dev-2 "$WORK/Containerfile.dev-2"
  sudo podman build --build-context repo="$HERE/../.." \
    -f "$WORK/Containerfile.dev-2" -t "$IMAGE:dev-2" "$ctx"
  push "$IMAGE:dev-1" "$REG:dev-1"
  push "$IMAGE:dev-2" "$REG:dev-2"
}
update_install() { # [disk]
  local disk=${1:-$UDISK}
  registry_up
  push "$IMAGE:dev-1" "$REG:latest"
  rm -f "$disk" && truncate -s 20G "$disk"
  sudo podman run --rm --privileged --pid=host --security-opt label=type:unconfined_t \
    -v /var/lib/containers:/var/lib/containers -v /dev:/dev -v "$WORK:/out" \
    "$IMAGE:dev-1" bootc install to-disk --generic-image --via-loopback \
    --target-imgref "$GUEST_REG:latest" "/out/$(basename "$disk")"
}
# Runs in the guest: marks the plain-HTTP dev registry as insecure, then times `bootc upgrade`
# and counts the bytes received on the network while it runs.
# shellcheck disable=SC2016 # expands in the guest
STAGE_ACTION='printf "[[registry]]\nlocation = \"10.0.2.2:5000\"\ninsecure = true\n" > /etc/containers/registries.conf.d/50-atos-dev.conf
until curl -sf http://10.0.2.2:5000/v2/ >/dev/null; do sleep 2; done
rx() { cat /sys/class/net/[!l]*/statistics/rx_bytes | awk "{ s += \$1 } END { print s }"; }
r0=$(rx); t0=$(date +%s)
bootc upgrade
t1=$(date +%s); r1=$(rx)
echo "ATOS-STAGED seconds=$((t1 - t0)) rx_bytes=$((r1 - r0))"
bootc status'
update_stage() {
  registry_up
  push "$IMAGE:dev-2" "$REG:latest"
  VARS=$UVARS NET=1 ACTION=$STAGE_ACTION boot "$UDISK" "$OUT/update-stage.log" fresh
}
update_apply() { VARS=$UVARS boot "$UDISK" "$OUT/update-apply.log"; }
update_previous() { VARS=$UVARS MENU=1 boot "$UDISK" "$OUT/update-previous.log"; }
update_rollback() { VARS=$UVARS ACTION='bootc rollback && bootc status' boot "$UDISK" "$OUT/update-rollback.log"; }
update_back() { VARS=$UVARS boot "$UDISK" "$OUT/update-back.log"; }

# Boot counting (#56). dev-bad is dev-2 with a compositor that exits at once: it boots, but the
# session never comes up, so the health check fails.
CDISK=$WORK/counting.raw CVARS=$WORK/counting-vars.fd
# Printed after the report: the boot entries, with their counters.
ENTRIES_ACTION='bootctl list --no-pager 2>&1 | grep -E "title|id:|tries" || true
ls /boot/loader/entries.staged 2>/dev/null || true'
counting_images() {
  update_images
  sed -e '/^LABEL org.opencontainers.image.title/i RUN echo IMAGE_VERSION=dev-bad >> /usr/lib/os-release' \
    -e '/^LABEL org.opencontainers.image.title/i RUN ln -sf false /usr/bin/atos-comp' \
    "$HERE/../../components/c1-base/Containerfile" > "$WORK/Containerfile.dev-bad"
  grep -q IMAGE_VERSION=dev-bad "$WORK/Containerfile.dev-bad"
  sudo podman build --build-context repo="$HERE/../.." \
    -f "$WORK/Containerfile.dev-bad" -t "$IMAGE:dev-bad" "$HERE/../../components/c1-base"
  push "$IMAGE:dev-bad" "$REG:dev-bad"
}
counting_install() { update_install "$CDISK"; }
counting_stage() { # <image> <log> [fresh]: points :latest at <image>, boots the default entry, stages it
  registry_up
  push "$IMAGE:$1" "$REG:latest"
  VARS=$CVARS NET=1 ACTION="$STAGE_ACTION
$ENTRIES_ACTION" boot "$CDISK" "$OUT/$2.log" "${3:-}"
}
counting_stage-good() { counting_stage dev-2 counting-stage-good fresh; }
counting_good() { VARS=$CVARS ACTION=$ENTRIES_ACTION boot "$CDISK" "$OUT/counting-good.log"; }
counting_stage-bad() { counting_stage dev-bad counting-stage-bad; }
counting_bad() { VARS=$CVARS TIMEOUT=120m ACTION=$ENTRIES_ACTION boot "$CDISK" "$OUT/counting-bad.log"; }

case "${1:-}" in
  build|disk|boot) "step_$1" ;;
  tamper) step_tamper "${2:-}" ;;
  all) step_build; step_disk; step_boot; step_tamper ;;
  update) for s in ${2:-images install stage apply previous rollback back}; do "update_$s"; done ;;
  counting) for s in ${2:-images install stage-good good stage-bad bad}; do "counting_$s"; done ;;
  *) sed -n '2,32p' "$0" >&2; exit 2 ;;
esac
