#!/bin/bash
# Installer test in the dev VM (#66). Runs inside the VM, in its own Lima instance:
#   ATOS_VM=atos-c11 tools/dev-vm/vm run components/c11-installer/vm-test.sh <step>
# Steps (`all` runs them in this order):
#   images   builds c1-base dev-1 (as in the repo) and dev-2 (plus IMAGE_VERSION=dev-2, VM-only),
#            pushes both to a registry in this VM; :latest points at dev-1
#   iso      builds the installer image and the ISO with dev-1 as offline payload
#   install  boots the ISO under QEMU (AAVMF Secure Boot firmware in setup mode, swtpm TPM 2.0)
#            and installs to an empty 20 GB disk, unattended; prints the time it took
#   boot     first boot of the installed disk: systemd-boot enrols the TEST keys and resets, the
#            sealed UKI boots with Secure Boot on, atos-tpm-seal binds the LUKS volume to PCR7
#   reboot   boots again: the disk unlocks through the PCR7-bound TPM slot, no prompt
#   stage    points :latest at dev-2, boots with networking, runs `bootc upgrade`
#   apply    boots the default entry: dev-2, still unlocked by the TPM
#   nosb     boots the same disk and TPM with Secure Boot off: PCR7 differs, so the TPM keeps the
#            key and the boot stops at the passphrase prompt
# Set BASE=<image@digest> to build c1-base on another base (passed as --build-arg).
# Disks live on the VM disk in ~/c11; logs go to components/c11-installer/out/.
# QEMU runs without KVM (Apple M1 has no nested virtualisation): every boot takes minutes.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$HERE/../.."
WORK=~/c11
OUT="$HERE/out"
IMAGE=localhost/c1-base
REG=localhost:5000/atos/c1-base
GUEST_REG=10.0.2.2:5000/atos/c1-base
ISO=$WORK/install.iso DISK=$WORK/disk.raw VARS=$WORK/vars.fd TPM=$WORK/tpm
mkdir -p "$WORK" "$OUT"
build_arg=()
[ -z "${BASE:-}" ] || build_arg=(--build-arg "BASE=$BASE")
# The image the installed system tracks; CI sets it to the published image.
TARGET_IMGREF=${TARGET_IMGREF:-$GUEST_REG:latest}

# The dev VM is aarch64 under emulation; CI is x86_64 with KVM.
case "$(uname -m)" in
  aarch64)
    QEMU=(qemu-system-aarch64 -machine virt) F=/usr/share/AAVMF
    CODE_SB=$F/AAVMF_CODE.secboot.fd CODE_NOSB=$F/AAVMF_CODE.no-secboot.fd VARS0=$F/AAVMF_VARS.fd
    TPMDEV=tpm-tis-device SERIAL=ttyAMA0 ;;
  x86_64)
    # shellcheck disable=SC2054 # commas are QEMU option syntax
    QEMU=(qemu-system-x86_64 -machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on) F=/usr/share/OVMF
    CODE_SB=$F/OVMF_CODE_4M.secboot.fd CODE_NOSB=$F/OVMF_CODE_4M.fd VARS0=$F/OVMF_VARS_4M.fd
    TPMDEV=tpm-tis SERIAL=ttyS0 ;;
  *) echo "unsupported architecture" >&2; exit 1 ;;
esac
if [ -w /dev/kvm ]; then QEMU+=(-accel kvm -cpu host); else QEMU+=(-cpu max); fi

# One systemd credential, passed over SMBIOS: cred <name> <content>
cred() { printf -- '-smbios\0type=11,value=io.systemd.credential.binary:%s=%s\0' "$1" "$(printf '%s' "$2" | base64 -w0)"; }

# Runs once startup has finished, prints what the test checks, runs the optional atos.action
# credential, then powers off. VM-only: nothing of this is in the images.
# shellcheck disable=SC2016 # expands in the guest
REPORT_UNIT='[Unit]
Description=Atos installer test report (dev VM only)
ConditionPathExists=!/etc/initrd-release
After=multi-user.target atos-tpm-seal.service
[Service]
Type=exec
ImportCredential=atos.*
StandardOutput=journal+console
ExecStart=/bin/sh -c "systemctl is-system-running --wait >/dev/null; echo ATOS-REPORT-BEGIN; bootctl status --no-pager 2>&1 | grep -E \"Secure Boot|Setup Mode\"; systemctl status --no-pager atos-tpm-seal.service | head -5; d=$$(readlink -f /dev/disk/by-designator/root-luks); echo LUKS $$d; systemd-cryptenroll $$d; lsblk -o NAME,TYPE,FSTYPE,MOUNTPOINTS; bootc status | grep -E \"image:|version|booted|staged|rollback\"; grep -s IMAGE_VERSION /usr/lib/os-release; systemd-analyze; [ ! -f $$CREDENTIALS_DIRECTORY/atos.action ] || sh -x $$CREDENTIALS_DIRECTORY/atos.action; echo ATOS-REPORT-END; systemctl poweroff --no-block"'

# The unattended install: what a user does on tty1, minus the questions.
INSTALL_UNIT="[Unit]
Description=Atos unattended install (dev VM only)
After=multi-user.target
[Service]
Type=exec
# The kernel console is tty1 (last console= in iso.yaml); the serial port is the test's log.
StandardOutput=tty
StandardError=tty
TTYPath=/dev/$SERIAL
ExecStart=/bin/sh -c 'atos-install --disk /dev/vda --yes --target-imgref $TARGET_IMGREF && echo ATOS-INSTALL-OK || echo ATOS-INSTALL-FAILED; systemctl poweroff --no-block'"

swtpm_up() {
  mkdir -p "$TPM"
  swtpm socket --tpm2 --tpmstate dir="$TPM" --ctrl type=unixio,path="$WORK/swtpm.sock" \
    --flags startup-clear --daemon --pid file="$WORK/swtpm.pid"
}

# qemu_run <log> <extra qemu args...>; env CODE=<firmware code> (default: Secure Boot capable).
qemu_run() {
  local log=$1; shift
  swtpm_up
  rm -f "$log"
  echo "QEMU, serial log: $log"
  # shellcheck disable=SC2054 # commas are QEMU option syntax
  timeout 60m "${QEMU[@]}" -smp 4 -m 4G -display none \
    -drive if=pflash,format=raw,readonly=on,file="${CODE:-$CODE_SB}" \
    -drive if=pflash,format=raw,file="$VARS" \
    -chardev socket,id=chrtpm,path="$WORK/swtpm.sock" -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device "$TPMDEV",tpmdev=tpm0 \
    -drive if=none,id=hd,format=raw,file="$DISK" -device virtio-blk-pci,drive=hd,bootindex=1 \
    -serial file:"$log" "$@" &
  # bootindex on the disk: the install leaves the EFI Shell ahead of the disk in BootOrder (the CD
  # was first), and newly found boot options are appended after it. QEMU's bootindex reorders it.
  local pid=$!
  local halt='Shell> |Freezing execution|Entering emergency mode|Kernel panic|Access [Dd]enied|ATOS-INSTALL-FAILED|[Pp]assphrase for|recovery key for'
  while kill -0 "$pid" 2>/dev/null; do
    grep -av 'EFI Internal Shell' "$log" 2>/dev/null | grep -aqE "$halt" && kill "$pid"
    sleep 5
  done
  wait "$pid" || true
  tr -d '\r' < "$log" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -av 'EFI Internal Shell' \
    | grep -aE "atos-install|atos-tpm-seal|ATOS-|Secure Boot|Setup Mode|SLOT|^ *[0-9]+ (recovery|tpm2|password)|LUKS|crypt|booted|staged|IMAGE_VERSION|Startup finished|recovery key|Installing|Partitioning|Encrypting|installed on|$halt" || true
}

# boot <log>: boots the installed disk with the report unit (env ACTION, NET=1).
boot() {
  local log=$1 creds nic=(-nic none)
  mapfile -d '' creds < <(
    cred systemd.extra-unit.atos-report.service "$REPORT_UNIT"
    cred systemd.unit-dropin.multi-user.target~atos-report $'[Unit]\nWants=atos-report.service'
    # Without KVM, udev in the initrd needs longer than the default 45 s to find the root.
    cred 'systemd.unit-dropin.dev-gpt\x2dauto\x2droot\x2dluks.device~timeout' $'[Unit]\nJobRunningTimeoutSec=10min'
    cred 'systemd.unit-dropin.dev-gpt\x2dauto\x2droot.device~timeout' $'[Unit]\nJobRunningTimeoutSec=10min'
    [ -z "${ACTION:-}" ] || cred atos.action "$ACTION")
  # shellcheck disable=SC2054
  [ -z "${NET:-}" ] || nic=(-netdev user,id=n0 -device virtio-net-pci,netdev=n0,romfile=)
  qemu_run "$log" "${nic[@]}" "${creds[@]}"
}

registry_up() { # CNCF distribution (registry:2), pinned by digest, as tools/dev-vm/sealed.sh
  sudo podman container exists atos-c11-registry || sudo podman create --name atos-c11-registry -p 5000:5000 \
    docker.io/library/registry:2@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373 >/dev/null
  sudo podman start atos-c11-registry >/dev/null
}
push() { sudo podman push -q --tls-verify=false "$1" "docker://$2"; }

step_images() {
  local ctx="$REPO/components/c1-base"
  registry_up
  sudo podman build "${build_arg[@]}" --build-context repo="$REPO" -t "$IMAGE:dev-1" "$ctx"
  # dev-2 differs by one os-release line inside the sealed digest (the Containerfile copy is VM-only).
  sed '/^LABEL org.opencontainers.image.title/i RUN echo IMAGE_VERSION=dev-2 >> /usr/lib/os-release' \
    "$ctx/Containerfile" > "$WORK/Containerfile.dev-2"
  grep -q IMAGE_VERSION=dev-2 "$WORK/Containerfile.dev-2"
  sudo podman build "${build_arg[@]}" --build-context repo="$REPO" -f "$WORK/Containerfile.dev-2" -t "$IMAGE:dev-2" "$ctx"
  push "$IMAGE:dev-1" "$REG:dev-1"
  push "$IMAGE:dev-2" "$REG:dev-2"
  push "$IMAGE:dev-1" "$REG:latest"
}

step_iso() {
  # The payload is stored in the ISO under the reference the installed system tracks.
  sudo podman tag "$IMAGE:dev-1" "$GUEST_REG:latest"
  PAYLOAD="$GUEST_REG:latest" OUTDIR="$WORK" BASE="${BASE:-}" "$HERE/build-iso.sh"
}

step_install() {
  rm -f "$DISK" "$VARS" && truncate -s 20G "$DISK"
  rm -rf "$TPM"
  # Fresh firmware variables: setup mode, as on a machine prepared for key enrolment.
  cp "$VARS0" "$VARS"
  local creds t0
  mapfile -d '' creds < <(
    cred systemd.extra-unit.atos-install-test.service "$INSTALL_UNIT"
    cred systemd.unit-dropin.multi-user.target~atos-install-test $'[Unit]\nWants=atos-install-test.service'
    # The interactive installer on tty1 stays off in the unattended run.
    cred systemd.unit-dropin.atos-installer.service~test $'[Unit]\nConditionPathExists=/nonexistent'
    # Nor the serial getty: it hangs up the serial tty this unit writes to, killing the installer.
    cred "systemd.unit-dropin.serial-getty@$SERIAL.service~test" $'[Unit]\nConditionPathExists=/nonexistent')
  t0=$(date +%s)
  # shellcheck disable=SC2054
  qemu_run "$OUT/install.log" -nic none \
    -device virtio-scsi-pci,id=scsi0 -drive if=none,id=cd,format=raw,media=cdrom,readonly=on,file="$ISO" \
    -device scsi-cd,drive=cd,bootindex=0 "${creds[@]}"
  grep -aq ATOS-INSTALL-OK "$OUT/install.log"
  echo "ATOS-INSTALL-TIME qemu_start_to_poweroff=$(( $(date +%s) - t0 ))s"
}

step_boot() { boot "$OUT/boot.log"; }
step_reboot() { boot "$OUT/reboot.log"; }
STAGE_ACTION='printf "[[registry]]\nlocation = \"10.0.2.2:5000\"\ninsecure = true\n" > /etc/containers/registries.conf.d/50-atos-dev.conf
until curl -sf http://10.0.2.2:5000/v2/ >/dev/null; do sleep 2; done
bootc upgrade && bootc status | grep -E "staged|booted|image:"'
step_stage() { registry_up; push "$IMAGE:dev-2" "$REG:latest"; NET=1 ACTION=$STAGE_ACTION boot "$OUT/stage.log"; }
step_apply() { boot "$OUT/apply.log"; }
step_nosb() {
  cp "$VARS" "$WORK/vars-nosb.fd"
  local VARS=$WORK/vars-nosb.fd
  CODE=$CODE_NOSB boot "$OUT/nosb.log"
}

case "${1:-}" in
  images|iso|install|boot|reboot|stage|apply|nosb) "step_$1" ;;
  all) for s in images iso install boot reboot stage apply nosb; do "step_$s"; done ;;
  *) sed -n '2,21p' "$0" >&2; exit 2 ;;
esac
