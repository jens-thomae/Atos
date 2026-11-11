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
#   nvidia   NVIDIA's modules under Secure Boot (#162, docs/components/c1-base/nvidia.md), after `disk`:
#            enrols the TEST keys as `boot` does, then loads nvidia-drm in the guest. The VM has no
#            NVIDIA GPU, so `No such device` from nvidia.ko's init means the kernel accepted the
#            signature (it is checked before init runs); `Key was rejected` means it did not. Also
#            shows that no NVIDIA or nouveau module loads by itself on a machine without NVIDIA
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
#            images      as for `update`, plus four images that fail on a counted boot: dev-bad
#                        (the login prompt exits at once), dev-hang (greetd never starts it), dev-panic
#                        (the kernel panics) and dev-emerg (the initrd enters emergency mode)
#            install     installs dev-1, as `update install` does
#            stage-good  boots dev-1, stages dev-2 (`bootc upgrade` writes its entry with `+3`)
#            good        boots dev-2 (counted), the health check passes, the entry loses its counter
#            bad, hang, panic, emerg
#                        each boots dev-2 and stages the failing image, then boots it until all
#                        three tries are used and systemd-boot boots dev-2 by itself. hang keeps the
#                        image's 2 min check timeout
#            hang-target as hang, with the image's 5 min boot-complete.target timeout as well
#            `counting <step>` runs one step; `counting` runs all of them in order
#   trust    the client trust policy (#75), on its own disk ~/sealed/trust.raw. Images are the shipped
#            Containerfile with the policy pointed at this VM's registry and a VM-only cosign key
#            (generated in ~/sealed/trust-keys, with a second, wrong one). Steps:
#            images    builds trust-1 (version 1.10), trust-2 (1.30, signed), trust-unsigned (1.30),
#                      trust-wrong (1.30, signed with the wrong key), trust-old (1.0, signed) and
#                      trust-mid (1.20, signed: newer than trust-1, older than trust-2)
#            install   installs trust-1, tracking :latest, which points at trust-1
#            local     on a copy of that disk: `bootc switch --transport containers-storage` refused
#                      (#150); with the developer-mode policy in /etc only the fixed reference passes
#            transports  on a copy of that disk: `bootc switch` from oci, oci-archive, docker-archive,
#                      dir and docker-daemon refused (#185, carried bootc patch 0003), also for trust-2
#                      in an OCI directory; `podman load` and `podman pull oci:`/`dir:` still work
#            stage     points :latest at trust-2, boots trust-1, tries `bootc switch` to the
#                      unsigned, wrongly signed and old images (all refused), then `bootc upgrade`
#                      stages trust-2; then the guest points :latest at trust-mid (refused: the
#                      floor is the staged version), then at trust-old and tries two upgrades
#                      and a switch (refused; trust-2 must stay staged)
#            apply     boots the default entry: trust-2
#            previous  picks the second boot entry from the menu: trust-1 (older) still boots
#            `trust <step>` runs one step; `trust` runs all of them in order
# Disks live on the VM disk in ~/sealed; logs go to tools/dev-vm/out/sealed/.
# QEMU runs without KVM (Apple M1 has no nested virtualisation): a boot takes minutes.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE=localhost/c1-base
WORK=~/sealed
OUT="$HERE/out/sealed"
mkdir -p "$WORK" "$OUT"
# The image's policy refuses local images (#150), and `bootc install` reads its own image from
# local storage. So the install container alone gets the installer's install-only policy (#176).
INSTALL_POLICY=$HERE/../../components/c11-installer/install-policy.json

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
n=$(sed -n s/^PRETTY_NAME=//p /usr/lib/os-release)
echo "ATOS-BOOT image=${v:-dev-1} counter=${e:-none} os=${n} host=$(cat /proc/sys/kernel/hostname)"'
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
    # SHIPPED_CHECK / SHIPPED_TARGET keep the image's own timeouts, to exercise them (counting hang).
    [ -n "${SHIPPED_CHECK:-}" ] || cred systemd.unit-dropin.atos-session-check.service~vm $'[Service]\nTimeoutStartSec=20min'
    [ -n "${SHIPPED_TARGET:-}" ] || cred systemd.unit-dropin.boot-complete.target~vm $'[Unit]\nJobTimeoutSec=40min'
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
  # virtio-gpu: atos-comp needs a DRM device once someone logs in (the health check, #56, needs only the prompt).
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
  # HALT=<regex> narrows what stops QEMU: boot counting expects panics and emergency mode to reboot.
  local stop=${HALT:-$halt}
  while kill -0 "$pid" 2>/dev/null; do
    # The firmware tries its built-in EFI Shell first, which Secure Boot refuses: not a halt.
    grep -av 'EFI Internal Shell' "$log" 2>/dev/null | grep -aqE "$stop" && kill "$pid"
    sleep 5
  done
  tr -d '\r' < "$log" | grep -av 'EFI Internal Shell' | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' \
    | grep -aE "Enrolling|enrolled|secureboot:|ATOS-REPORT|ATOS-BOOT|ATOS-NVIDIA|sh\[[0-9]+\]:|session-check|boot is (good|bad)|reboot: Restarting|counted boot failed|Timed out|timed out|fs-verity|/sbin/init|$halt"
}

step_build() { sudo podman build --build-context repo="$HERE/../.." -t "$IMAGE" "$HERE/../../components/c1-base"; }

step_disk() {
  rm -f "$WORK/disk.raw" && truncate -s 20G "$WORK/disk.raw"
  sudo podman run --rm --privileged --pid=host --security-opt label=type:unconfined_t \
    -v /var/lib/containers:/var/lib/containers -v /dev:/dev -v "$WORK:/out" \
    -v "$INSTALL_POLICY:/etc/containers/policy.json:ro" \
    "$IMAGE" bootc install to-disk --generic-image --via-loopback /out/disk.raw
}

step_boot() { boot "$WORK/disk.raw" "$OUT/boot.log" fresh; }

# shellcheck disable=SC2016 # expands in the guest
NVIDIA_ACTION='echo "ATOS-NVIDIA lockdown: $(cat /sys/kernel/security/lockdown)"
echo "ATOS-NVIDIA loaded at boot: $(lsmod | grep -oE "^(nvidia|nouveau)[a-z_]*" | tr "\n" " ")(end)"
for m in nvidia nvidia-modeset nvidia-drm nvidia-uvm; do echo "ATOS-NVIDIA $m: signer $(modinfo -F signer $m), vermagic $(modinfo -F vermagic $m)"; done
modprobe nvidia-drm 2>&1 | sed "s/^/ATOS-NVIDIA /"
journalctl -k -b -o cat --no-pager | grep -E "NVRM|nvidia|Loading of|Key was rejected|PKCS#7" | sed "s/^/ATOS-NVIDIA kernel: /"'
step_nvidia() { ACTION=$NVIDIA_ACTION boot "$WORK/disk.raw" "$OUT/nvidia.log" fresh; }

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
    # The menu lists the entries by their title: PRETTY_NAME, "Atos 45" (#248), or, for an entry
    # of an image from before #248, "Fedora Linux 45 (Forty Five)".
    if b"Atos 45" in seen or b"Fedora Linux" in seen:
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
    -v "$INSTALL_POLICY:/etc/containers/policy.json:ro" \
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

# Boot counting (#56). Each failing image is dev-2 plus one or two lines, from a copy of the
# Containerfile: dev-bad's login prompt (agreety) exits at once, so greetd fails; dev-hang's greetd
# never starts one (the check times out); the check needs only the prompt (A1 on #187).
# dev-panic's kernel panics (rdinit exits) and dev-emerg's initrd goes to emergency mode. The last
# two fail before switch-root.
CDISK=$WORK/counting.raw CVARS=$WORK/counting-vars.fd
# Printed after the report: the boot entries, with their counters.
ENTRIES_ACTION='bootctl list --no-pager 2>&1 | grep -E "title|id:|tries" || true
ls /boot/loader/entries.staged 2>/dev/null || true'
variant() { # <name> <RUN line>...: builds dev-<name> and pushes it to the registry
  local name=$1 f=$WORK/Containerfile.dev-$1 l args=()
  shift
  for l in "IMAGE_VERSION=dev-$name >> /usr/lib/os-release" "$@"; do
    [ "${l#IMAGE_VERSION}" = "$l" ] || l="echo $l"
    args+=(-e "/^LABEL org.opencontainers.image.title/i RUN $l")
  done
  sed "${args[@]}" "$HERE/../../components/c1-base/Containerfile" > "$f"
  grep -q "IMAGE_VERSION=dev-$name" "$f"
  sudo podman build --build-context repo="$HERE/../.." -f "$f" -t "$IMAGE:dev-$name" "$HERE/../../components/c1-base"
  push "$IMAGE:dev-$name" "$REG:dev-$name"
}
counting_images() {
  update_images
  # shellcheck disable=SC2016 # expands in the image build
  variant bad 'ln -sf false "$(command -v agreety)"'
  variant hang "printf '#!/bin/sh\\\\nsleep infinity\\\\n' > \"\$(command -v greetd)\""
  variant hang-target "printf '#!/bin/sh\\\\nsleep infinity\\\\n' > \"\$(command -v greetd)\""
  variant panic "echo 'kargs = [\"rdinit=/usr/bin/true\"]' > /usr/lib/bootc/kargs.d/90-dev-panic.toml"
  variant emerg "echo 'kargs = [\"rd.systemd.unit=emergency.target\"]' > /usr/lib/bootc/kargs.d/90-dev-emerg.toml"
}
counting_install() { update_install "$CDISK"; }
counting_stage() { # <image> <log> [fresh]: points :latest at <image>, boots the default entry, stages it
  registry_up
  push "$IMAGE:$1" "$REG:latest"
  VARS=$CVARS NET=1 ACTION="$STAGE_ACTION
$ENTRIES_ACTION" boot "$CDISK" "$OUT/$2.log" "${3:-}"
}
counting_fail() { # <image>: stages it from dev-2, then boots it until systemd-boot falls back to dev-2
  counting_stage "dev-$1" "counting-stage-$1"
  VARS=$CVARS TIMEOUT=150m ACTION=$ENTRIES_ACTION boot "$CDISK" "$OUT/counting-$1.log"
}
counting_stage-good() { counting_stage dev-2 counting-stage-good fresh; }
counting_good() { VARS=$CVARS ACTION=$ENTRIES_ACTION boot "$CDISK" "$OUT/counting-good.log"; }
counting_bad() { counting_fail bad; }
# Before switch-root: panics and emergency mode must reboot, so they do not stop QEMU here.
counting_panic() { HALT='Freezing execution|[Ss]ecurity [Vv]iolation|Access [Dd]enied' counting_fail panic; }
counting_emerg() { HALT='Freezing execution|[Ss]ecurity [Vv]iolation|Access [Dd]enied' counting_fail emerg; }
# The image's own timeouts: the check's 2 min, then (with a slow boot here) the target's 5 min.
counting_hang() { SHIPPED_CHECK=1 counting_fail hang; }
# dev-hang-target is dev-hang under another name: `bootc upgrade` stages nothing for an image that
# is already deployed (dev-hang stays the rollback entry after the hang step).
counting_hang-target() { SHIPPED_CHECK=1 SHIPPED_TARGET=1 counting_fail hang-target; }

# Trust policy (#75). cosign as in CI (v3.1.4, legacy signature format, no transparency log).
TDISK=$WORK/trust.raw TVARS=$WORK/trust-vars.fd TKEYS=$WORK/trust-keys
COSIGN_VERSION=v3.1.4 COSIGN_SHA256=ade83b7aac62e131cacfe96d958948b2150cc9efec46a570a2649b8e27dedad2
cosign() {
  local bin=$WORK/cosign-$COSIGN_VERSION
  [ -x "$bin" ] || {
    curl -fsSL -o "$bin.tmp" "https://github.com/sigstore/cosign/releases/download/$COSIGN_VERSION/cosign-linux-arm64"
    echo "$COSIGN_SHA256  $bin.tmp" | sha256sum --check --quiet && chmod +x "$bin.tmp" && mv "$bin.tmp" "$bin"; }
  COSIGN_PASSWORD='' "$bin" "$@"
}
trust_keys() { # VM-only test keys, never committed: good (the image trusts it) and wrong
  mkdir -p "$TKEYS"
  local k
  for k in good wrong; do
    [ -f "$TKEYS/$k.key" ] || (cd "$TKEYS" && cosign generate-key-pair --output-key-prefix "$k" >/dev/null)
  done
}
trust_variant() { # <name> <version> [sign key]: builds trust-<name>, pushes it, signs it for the guest's name
  local name=$1 f=$WORK/Containerfile.trust-$1 digest=$WORK/trust-$1.digest
  # The guest pulls from 10.0.2.2:5000, so the policy scope, registries.d and the key follow it.
  sed -e "/^LABEL org.opencontainers.image.title/i RUN echo IMAGE_VERSION=trust-$name >> /usr/lib/os-release" \
      -e "/^LABEL org.opencontainers.image.title/i RUN sed -i s#ghcr.io/jens-thomae/atos/c1-base#${GUEST_REG}# /usr/share/containers/policy.json /usr/share/containers/registries.d/atos.yaml \&\& echo $(base64 -w0 "$TKEYS/good.pub") | base64 -d > /usr/share/pki/containers/atos-c1-base-test.pub" \
      "$HERE/../../components/c1-base/Containerfile" > "$f"
  grep -q "IMAGE_VERSION=trust-$name" "$f"
  sudo podman build --build-context repo="$HERE/../.." -f "$f" --label "org.opencontainers.image.version=$2" \
    -t "$IMAGE:trust-$name" "$HERE/../../components/c1-base"
  sudo podman push -q --tls-verify=false --digestfile "$digest" "$IMAGE:trust-$name" "docker://$REG:trust-$name"
  [ -z "${3:-}" ] || cosign sign -y --key "$TKEYS/$3.key" --tlog-upload=false --new-bundle-format=false \
    --use-signing-config=false --allow-http-registry --sign-container-identity "$GUEST_REG" "$REG@$(cat "$digest")"
}
trust_images() {
  registry_up
  trust_keys
  trust_variant 1 1.10 good
  trust_variant 2 1.30 good
  trust_variant unsigned 1.30
  trust_variant wrong 1.30 wrong
  trust_variant old 1.0 good
  trust_variant mid 1.20 good
}
trust_install() {
  registry_up
  sudo podman push -q --tls-verify=false "$IMAGE:trust-1" "docker://$REG:latest"
  rm -f "$TDISK" && truncate -s 20G "$TDISK"
  sudo podman run --rm --privileged --pid=host --security-opt label=type:unconfined_t \
    -v /var/lib/containers:/var/lib/containers -v /dev:/dev -v "$WORK:/out" \
    -v "$INSTALL_POLICY:/etc/containers/policy.json:ro" \
    "$IMAGE:trust-1" bootc install to-disk --generic-image --via-loopback \
    --target-imgref "$GUEST_REG:latest" "/out/$(basename "$TDISK")"
}
# Runs in the guest: each refused switch prints bootc's last error line.
# shellcheck disable=SC2016 # expands in the guest
TRUST_ACTION='printf "[[registry]]\nlocation = \"10.0.2.2:5000\"\ninsecure = true\n" > /etc/containers/registries.conf.d/50-atos-dev.conf
until curl -sf http://10.0.2.2:5000/v2/ >/dev/null; do sleep 2; done
for t in unsigned wrong old; do
  if out=$(bootc switch --enforce-container-sigpolicy 10.0.2.2:5000/atos/c1-base:trust-$t 2>&1); then
    echo "ATOS-TRUST $t ACCEPTED"
  else
    echo "ATOS-TRUST $t refused: $(printf "%s" "$out" | tail -n 3 | tr "\n" " ")"
  fi
done
bootc upgrade && echo "ATOS-TRUST latest staged"
# A registry that turns bad after the update was staged. First :latest names trust-mid: newer than
# the booted trust-1, older than the staged trust-2, so refused.
retag() { skopeo copy -q "docker://10.0.2.2:5000/atos/c1-base:$1" docker://10.0.2.2:5000/atos/c1-base:latest || echo "ATOS-TRUST retag failed"; }
retag trust-mid
if out=$(bootc upgrade 2>&1); then echo "ATOS-TRUST mid ACCEPTED"; else echo "ATOS-TRUST mid refused: $(printf "%s" "$out" | tail -n 1)"; fi
# Then the old image, already in the local repository. Refusals must leave the staged trust-2 alone.
retag trust-old
for t in "upgrade" "upgrade" "switch 10.0.2.2:5000/atos/c1-base:trust-old"; do
  if out=$(bootc $t 2>&1); then echo "ATOS-TRUST again $t ACCEPTED"; else echo "ATOS-TRUST again $t refused: $(printf "%s" "$out" | tail -n 1)"; fi
done
echo "ATOS-TRUST staged entries: $(ls /boot/loader/entries.staged 2>/dev/null | tr "\n" " ")"
bootc status'
trust_stage() {
  registry_up
  sudo podman push -q --tls-verify=false "$IMAGE:trust-2" "docker://$REG:latest"
  # Four pulls of a 3 GB image under emulation: more than the default 45 min (2026-11-08).
  VARS=$TVARS NET=1 TIMEOUT=${TIMEOUT:-90m} ACTION=$TRUST_ACTION boot "$TDISK" "$OUT/trust-stage.log" fresh
}
# Local images (#150), in the guest: refused by default; with the developer-mode exception in
# /etc (trust-policy.md, "Local images"), only the fixed reference passes; without it, refused again.
# shellcheck disable=SC2016 # expands in the guest
LOCAL_ACTION='printf "[[registry]]\nlocation = \"10.0.2.2:5000\"\ninsecure = true\n" > /etc/containers/registries.conf.d/50-atos-dev.conf
until curl -sf http://10.0.2.2:5000/v2/ >/dev/null; do sleep 2; done
echo "ATOS-LOCAL /etc policy after install: $(ls /etc/containers/policy.json 2>&1)"
echo "ATOS-LOCAL store: $(podman info --format "{{.Store.GraphDriverName}}@{{.Store.GraphRoot}}")"
skopeo copy -q docker://10.0.2.2:5000/atos/c1-base:trust-2 containers-storage:localhost/atos-dev:current && podman tag localhost/atos-dev:current localhost/other:test && echo "ATOS-LOCAL copied"
switch() { # <label> <local ref>
  if out=$(bootc switch --transport containers-storage "$2" 2>&1); then echo "ATOS-LOCAL $1 $2 ACCEPTED"
  else echo "ATOS-LOCAL $1 $2 refused: $(printf "%s" "$out" | tail -n 2 | tr "\n" " ")"; fi
}
switch default localhost/other:test
switch default localhost/atos-dev:current
# Other users of local storage: build and push override the policy, save does not.
printf "FROM localhost/other:test\nLABEL atos.test=1\n" > /var/tmp/Containerfile.local
podman build -q -f /var/tmp/Containerfile.local -t localhost/built:test /var/tmp >/dev/null && echo "ATOS-LOCAL podman build ok" || echo "ATOS-LOCAL podman build refused"
podman push -q --tls-verify=false localhost/built:test docker://10.0.2.2:5000/atos/local-push:test && echo "ATOS-LOCAL podman push ok" || echo "ATOS-LOCAL podman push refused"
podman save -q -o /var/tmp/built.tar localhost/built:test 2>&1 | tail -n 1 | sed "s/^/ATOS-LOCAL podman save: /"; [ ! -s /var/tmp/built.tar ] || echo "ATOS-LOCAL podman save ok"
# Developer mode on: the image policy plus one scope, written to /etc (which wins over /usr).
sed "s#^\( *\)\"containers-storage\": {#&\n\1    \"[overlay@/var/lib/containers/storage]localhost/atos-dev:current\": [{ \"type\": \"insecureAcceptAnything\" }],#" /usr/share/containers/policy.json > /etc/containers/policy.json
grep -A3 "\"containers-storage\"" /etc/containers/policy.json
switch devmode localhost/other:test
switch devmode localhost/atos-dev:current
echo "ATOS-LOCAL staged entries: $(ls /boot/loader/entries.staged 2>/dev/null | tr "\n" " ")"
# Developer mode off: the file goes, the default applies again.
rm /etc/containers/policy.json
switch off localhost/other:test
if out=$(bootc upgrade --check 2>&1); then echo "ATOS-LOCAL off upgrade --check ACCEPTED"; else echo "ATOS-LOCAL off upgrade --check refused: $(printf "%s" "$out" | tail -n 1)"; fi
bootc status'
# On a copy of the freshly installed disk, so the other steps are unaffected.
trust_local() {
  registry_up
  cp --sparse=always "$TDISK" "$WORK/trust-local.raw"
  VARS=$WORK/trust-local-vars.fd NET=1 TIMEOUT=90m ACTION=$LOCAL_ACTION boot "$WORK/trust-local.raw" "$OUT/trust-local.log" fresh
}
# The other local transports (#185), in the guest. The carried bootc patch 0003 refuses every
# transport but registry and containers-storage before the image is opened. podman gets a tiny image
# (FROM scratch, one file) in each transport and must still load or pull it, as root and rootless.
# One real attempt: trust-2, signed and newer than the booted trust-1, in an OCI directory.
# shellcheck disable=SC2016 # expands in the guest
TRANSPORTS_ACTION='printf "[[registry]]\nlocation = \"10.0.2.2:5000\"\ninsecure = true\n" > /etc/containers/registries.conf.d/50-atos-dev.conf
until curl -sf http://10.0.2.2:5000/v2/ >/dev/null; do sleep 2; done
P=ATOS-TRANSPORT T=/var/tmp/t
echo "$P /etc policy after install: $(ls /etc/containers/policy.json 2>&1)"
ref() { case $1 in oci) echo $T/oci:tiny ;; oci-archive) echo $T/oci.tar ;; docker-archive) echo $T/docker.tar ;; dir) echo $T/dir ;; docker-daemon) echo localhost/tiny:t ;; esac; }
mkdir -p $T
for t in oci oci-archive docker-archive dir; do
  skopeo copy -q docker://10.0.2.2:5000/atos/tiny:t "$t:$(ref $t)" || echo "$P copy to $t FAILED"
done
chmod -R a+rX $T
useradd -m tuser 2>/dev/null; echo "$P tuser subuid entries: $(grep -c ^tuser: /etc/subuid)"
switch() { # <transport> <ref>
  if out=$(bootc switch --transport "$1" "$2" 2>&1); then echo "$P bootc switch $1 $2 ACCEPTED"
  else echo "$P bootc switch $1 $2 refused: $(printf "%s" "$out" | tail -n 1)"; fi
}
for t in oci oci-archive docker-archive dir docker-daemon; do switch $t "$(ref $t)"; done
for t in oci oci-archive docker-archive dir; do
  case $t in *-archive) cmd="podman load -q -i $(ref $t)" ;; *) cmd="podman pull -q $t:$(ref $t)" ;; esac
  for run in "" "runuser -u tuser --"; do
    if out=$(cd / && $run $cmd 2>&1); then echo "$P ${run:+tuser }$cmd: ok"
    else echo "$P ${run:+tuser }$cmd: refused: $(printf "%s" "$out" | tail -n 1)"; fi
  done
done
rm -rf $T
skopeo copy -q docker://10.0.2.2:5000/atos/c1-base:trust-2 oci:/var/tmp/trust-2:current && echo "$P trust-2 copied to oci"
switch oci /var/tmp/trust-2:current
echo "$P staged entries: $(ls /boot/loader/entries.staged 2>/dev/null | tr "\n" " ")"
bootc status'
# On a copy of the freshly installed disk, so the other steps are unaffected.
trust_transports() {
  registry_up
  mkdir -p "$WORK/tiny" && printf 'atos\n' > "$WORK/tiny/tiny.txt"
  printf 'FROM scratch\nCOPY tiny.txt /\n' | sudo podman build -q -t localhost/tiny:t -f - "$WORK/tiny" >/dev/null
  sudo podman push -q --tls-verify=false localhost/tiny:t docker://localhost:5000/atos/tiny:t
  cp --sparse=always "$TDISK" "$WORK/trust-transports.raw"
  VARS=$WORK/trust-transports-vars.fd NET=1 ACTION=$TRANSPORTS_ACTION \
    boot "$WORK/trust-transports.raw" "$OUT/trust-transports.log" fresh
}
trust_apply() { VARS=$TVARS boot "$TDISK" "$OUT/trust-apply.log"; }
trust_previous() { VARS=$TVARS MENU=1 boot "$TDISK" "$OUT/trust-previous.log"; }

# Sourced (spikes/c1-dev-image/run.sh reuses boot() and the registry): stop before the steps.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0
case "${1:-}" in
  build|disk|boot|nvidia) "step_$1" ;;
  tamper) step_tamper "${2:-}" ;;
  all) step_build; step_disk; step_boot; step_tamper ;;
  update) for s in ${2:-images install stage apply previous rollback back}; do "update_$s"; done ;;
  counting) for s in ${2:-images install stage-good good bad hang hang-target panic emerg}; do "counting_$s"; done ;;
  trust) for s in ${2:-images install local transports stage apply previous}; do "trust_$s"; done ;;
  *) sed -n '2,60p' "$0" >&2; exit 2 ;;
esac
