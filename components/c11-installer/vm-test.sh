#!/bin/bash
# Installer test in the dev VM (#66). Runs inside the VM, in its own Lima instance:
#   ATOS_VM=atos-c11 tools/dev-vm/vm run components/c11-installer/vm-test.sh <step>
# Steps (`all` runs them in this order):
#   images   builds c1-base dev-1 (as in the repo) and dev-2 (plus IMAGE_VERSION=dev-2, VM-only),
#            pushes both to a registry in this VM; :latest points at dev-1
#   iso      builds the installer image and the ISO with dev-1 as offline payload
#   install  boots the unmodified ISO under QEMU (Secure Boot firmware in setup mode, swtpm TPM 2.0)
#            and installs to an empty 20 GB disk through the interactive installer on tty1, as a
#            person does (#220): a test unit copies the screen to the serial log, and the host types
#            each answer on the VM's keyboard when its question shows. Prints the time it took. The
#            payload must be the installer's default reference (CI's is); see `unattended`
#   unattended  not in CI: the same install with `atos-install --yes --target-imgref` in a test
#            unit and the installer unit off; the dev VM's payload is a local registry reference
#   enrol    not in `all`: enrols the TEST keys into the firmware variables (x86_64 CI, where
#            OVMF refuses systemd-boot's own enrolment); needs virt-fw-vars
#   boot     first boot of the installed disk: systemd-boot enrols the TEST keys and resets, the
#            sealed UKI boots with Secure Boot on, atos-tpm-seal binds the LUKS volume to PCR7
#   reboot   boots again: the disk unlocks through the PCR7-bound TPM slot, no prompt
#   stage    points :latest at dev-2, boots with networking, runs `bootc upgrade`
#   apply    boots the default entry: dev-2, still unlocked by the TPM
#   nosb     boots the same disk and TPM with Secure Boot off: PCR7 differs, so the TPM keeps the
#            key and the boot stops at the recovery key prompt
# Set BASE=<image@digest> to build c1-base on another base (passed as --build-arg).
# Disks live on the VM disk in ~/c11; logs go to components/c11-installer/out/.
# Without KVM (Apple M1 has no nested virtualisation) every boot takes minutes; CI has KVM.
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
# The administrator password the unattended install types (#187); a test value for a throwaway disk.
# Spaces and a colon check that it reaches chpasswd unchanged.
TEST_PASSWORD='Atos test: 1'
# The QEMU monitor, for typing at the login prompt (#187).

# The dev VM is aarch64 under emulation; CI is x86_64 with KVM.
case "$(uname -m)" in
  aarch64)
    QEMU=(qemu-system-aarch64 -machine virt) F=/usr/share/AAVMF
    CODE_SB=$F/AAVMF_CODE.secboot.fd CODE_NOSB=$F/AAVMF_CODE.no-secboot.fd VARS0=$F/AAVMF_VARS.fd
    # virt has no keyboard; the login (#187) types on this one. q35 has PS/2, and QEMU sends a key to
    # every keyboard, so x86_64 gets no second one (it would type each key twice).
    TPMDEV=tpm-tis-device SERIAL=ttyAMA0 KBD=(-device qemu-xhci -device usb-kbd) ;;
  x86_64)
    # shellcheck disable=SC2054 # commas are QEMU option syntax
    QEMU=(qemu-system-x86_64 -machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on) F=/usr/share/OVMF
    CODE_SB=$F/OVMF_CODE_4M.secboot.fd CODE_NOSB=$F/OVMF_CODE_4M.fd VARS0=$F/OVMF_VARS_4M.fd
    TPMDEV=tpm-tis SERIAL=ttyS0 KBD=() ;;
  *) echo "unsupported architecture" >&2; exit 1 ;;
esac
# Per QEMU run; with KVM a prompt hidden on tty0 then fails in minutes, not after an hour.
if [ -w /dev/kvm ]; then QEMU+=(-accel kvm -cpu host) TMO=15m; else QEMU+=(-cpu max) TMO=60m; fi

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
# The serial port, not the console: on x86_64 the kernel console is tty0 (the UKI has no console=).
StandardOutput=tty
StandardError=tty
TTYPath=/dev/'"$SERIAL"'
# Through cat, so systemd tools see no terminal (no size queries or resets); sleep 1 lets the
# serial port drain before poweroff (a report once lost its last lines).
ExecStart=/bin/sh -c "{ systemctl is-system-running --wait >/dev/null; echo ATOS-REPORT-BEGIN; bootctl status --no-pager 2>&1 | grep -E \"Secure Boot|Setup Mode\"; systemctl status --no-pager atos-tpm-seal.service | head -3; journalctl -b -o cat --no-pager -u atos-tpm-seal.service | grep atos-tpm-seal; d=$$(readlink -f /dev/disk/by-designator/root-luks); echo LUKS $$d; systemd-cryptenroll $$d; lsblk -o NAME,TYPE,FSTYPE,MOUNTPOINTS; bootc status | grep -E \"image:|version|booted|staged|rollback\"; grep -s IMAGE_VERSION /usr/lib/os-release; systemd-analyze; sh $$CREDENTIALS_DIRECTORY/atos.check; [ ! -f $$CREDENTIALS_DIRECTORY/atos.action ] || sh -x $$CREDENTIALS_DIRECTORY/atos.action; echo ATOS-REPORT-END; } 2>&1 | cat; sleep 1; systemctl poweroff --no-block"'

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
ExecStart=/bin/sh -c '{ echo \"$TEST_PASSWORD\"; echo \"$TEST_PASSWORD\"; } | atos-install --disk /dev/vda --yes --target-imgref $TARGET_IMGREF && echo ATOS-INSTALL-OK || echo ATOS-INSTALL-FAILED; systemctl poweroff --no-block'"

# The interactive install (#220): the ISO runs unchanged. This test-only unit copies what tty1 shows
# (/dev/vcs1, the console's text) to the serial log whenever it changes, prefixed ATOS-SCREEN, and
# the installer unit's and logind's journal with it; the host reads the questions from there.
# shellcheck disable=SC2016 # expands in the guest
SCREEN_SCRIPT='exec > /dev/'"$SERIAL"' 2>&1
journalctl -fb -o short-monotonic | grep --line-buffered -aiE "atos-installer|getty|autovt|vconsole|logind|tty1|plymouth|drm|fbcon|console" | sed "s/^/ATOS-JOURNAL /" &
cols=$(od -An -tu1 -j1 -N1 /dev/vcsa1 | tr -d " "); echo "ATOS-SCREEN-START cols=${cols:=80}"
old= same=0
while :; do
  s=$(fold -w "$cols" /dev/vcs1 | sed "s/ *$//" | grep -v "^$")
  if [ "$s" = "$old" ]; then same=$((same + 1)); else same=0; fi
  [ "$same" -gt 0 ] || { echo ATOS-SCREEN-BEGIN; printf "%s\n" "$s" | sed "s/^/ATOS-SCREEN /"; old=$s; }
  # No change for 30 s: what the installer is waiting on, for debugging a stuck test.
  [ "$same" -ne 30 ] || { echo ATOS-STALL; ps -o pid,pgid,tpgid,stat,wchan:24,args -t tty1; stty -a < /dev/tty1 | head -4
    for p in $(pgrep -t tty1); do echo "stack $p"; cat /proc/$p/stack; done
    systemctl show atos-installer.service -p ActiveState,Result,ExecMainCode,ExecMainStatus,NRestarts
    systemctl list-units --all --no-legend "getty@*" "autovt@*"; } 2>&1 | sed "s/^/ATOS-STALL /"
  sleep 1
done'
# shellcheck disable=SC2016 # expands in systemd
SCREEN_UNIT='[Unit]
Description=Atos installer test: tty1 to the serial log (test only)
[Service]
Type=exec
ImportCredential=atos.*
ExecStart=/bin/sh -c "exec sh $$CREDENTIALS_DIRECTORY/atos.screen"'
# The questions atos-install asks on tty1, in order, and what a person answers (#220).
QUESTIONS=('Install Atos on disk number:' 'Type "erase" to continue:' 'Password for the administrator account'
  'Type the password again:' 'written the recovery key down' 'Press Enter to restart')
asked=0
# answer_installer <log>: types the answer to the next question once the screen shows it.
answer_installer() {
  local a
  [ "$asked" -lt ${#QUESTIONS[@]} ] && grep -aqF "${QUESTIONS[asked]}" "$1" || return 0
  case $asked in
    0) a=$(tr -d '\r' < "$1" | grep -aoE '[0-9]+\) /dev/vda ' | tail -n 1 || true); a=${a%%)*} ;; # the empty disk's number
    1) a=erase ;;
    2 | 3) a=$TEST_PASSWORD ;;
    *) a= ;; # Enter
  esac
  type_keys "$a"
  asked=$((asked + 1))
  echo "answered question $asked of ${#QUESTIONS[@]} on tty1"
}

swtpm_up() {
  mkdir -p "$TPM"
  swtpm socket --tpm2 --tpmstate dir="$TPM" --ctrl type=unixio,path="$WORK/swtpm.sock" \
    --flags startup-clear --daemon --pid file="$WORK/swtpm.pid"
}

# mon <command>: one QEMU monitor command, one connection (as in c1-base's shell-boot-test.sh; a
# single long-lived connection lost the typing, run 42681998225).
mon() { echo "$1" | socat - UNIX-CONNECT:"$WORK/mon.sock" >> "$OUT/mon.log"; }
# type_keys <text>: types <text> and Enter on the guest's keyboard through the QEMU monitor.
type_keys() {
  local s=$1 c k i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      [a-z0-9]) k=$c ;;
      [A-Z]) k=shift-${c,,} ;;
      ' ') k=spc ;;
      :) k=shift-semicolon ;;
      *) echo "type_keys: no key for '$c'" >&2; return 1 ;;
    esac
    mon "sendkey $k"
    sleep 0.2 # each key is held 100 ms; do not let QEMU's key queue fill up
  done
  mon "sendkey ret"
}

# The login on tty1 (#187): what a user types at greetd's prompt, once the report says it is up.
login_tty1() {
  type_keys atos
  sleep 2
  type_keys "$TEST_PASSWORD"
  echo "login typed on tty1"
}

# qemu_run <log> <extra qemu args...>; env CODE=<firmware code> (default: Secure Boot capable).
qemu_run() {
  local log=$1; shift
  swtpm_up
  rm -f "$log"
  echo "QEMU, serial log: $log"
  # shellcheck disable=SC2054 # commas are QEMU option syntax
  timeout "$TMO" "${QEMU[@]}" -smp 4 -m 4G -display none \
    -drive if=pflash,format=raw,readonly=on,file="${CODE:-$CODE_SB}" \
    -drive if=pflash,format=raw,file="$VARS" \
    -chardev socket,id=chrtpm,path="$WORK/swtpm.sock" -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device "$TPMDEV",tpmdev=tpm0 \
    -drive if=none,id=hd,format=raw,file="$DISK" -device virtio-blk-pci,drive=hd,bootindex=1 \
    -monitor unix:"$WORK/mon.sock",server=on,wait=off "${KBD[@]}" \
    -serial file:"$log" "$@" &
  # bootindex on the disk: the install leaves the EFI Shell ahead of the disk in BootOrder (the CD
  # was first), and newly found boot options are appended after it. QEMU's bootindex reorders it.
  local pid=$! typed=
  local halt='Shell> |Freezing execution|Entering emergency mode|Kernel panic|Access [Dd]enied|ATOS-INSTALL-FAILED|Press Enter to try again|Started (kmsconvt|autovt|getty)@tty1|[Pp]assphrase for|recovery key for'
  while kill -0 "$pid" 2>/dev/null; do
    m=$(tr -d '\r' < "$log" 2>/dev/null | grep -av 'EFI Internal Shell' | grep -aE -m1 "$halt" || true)
    [ -z "$m" ] || { echo "HALT on: $m"; kill "$pid"; break; }
    if [ -z "$typed" ] && grep -aq ATOS-LOGIN-READY "$log"; then login_tty1 && typed=1; fi
    [ -z "${INTERACTIVE:-}" ] || answer_installer "$log"
    sleep "${POLL:-5}"
  done
  wait "$pid" || true
  tr -d '\r' < "$log" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -av 'EFI Internal Shell' \
    | grep -aE "atos-install|atos-tpm-seal|ATOS-|Secure Boot|Setup Mode|SLOT|^ *[0-9]+ (recovery|tpm2|password)|LUKS|crypt|booted|staged|IMAGE_VERSION|uid=|Startup finished|recovery key|Installing|Partitioning|Encrypting|installed on|$halt" || true
}

# The administrator account and the apps setup (#187), checked on every boot. sudo checks the
# password through PAM (pam_unix, unix_chkpwd: shadow labels matter under enforcing SELinux).
# shellcheck disable=SC2016 # expands in the guest
ADMIN_CHECK='pw=$(cat "$CREDENTIALS_DIRECTORY/atos.test-password")
dmesg -n 1 # kernel audit lines on the serial console split the markers (run 42687015461)
# No autologin (#187): greetd waits at its prompt; the host types user and password on tty1. First,
# before runuser below opens sessions of its own. s: the user'"'"'s logind sessions on tty1.
s() { loginctl list-sessions --no-legend | grep -E " atos .*tty1"; }
s >/dev/null && echo ATOS-LOGIN-AUTOLOGIN-FOUND
# The boot health check (rule A1) once, before anyone has typed: it must call the waiting prompt good.
r=$(timeout 120 /usr/libexec/atos/session-check 2>&1) && echo "ATOS-SESSION-CHECK-OK $r" || echo "ATOS-SESSION-CHECK-FAIL $r"
pgrep -x agreety >/dev/null && echo ATOS-LOGIN-READY
i=0; until s >/dev/null || [ $i -ge 120 ]; do sleep 1; i=$((i + 1)); done
s && echo ATOS-LOGIN-OK
sleep 5; pgrep -u atos -x atos-comp >/dev/null && echo ATOS-LOGIN-COMPOSITOR-RUNS
id atos
ls -Z /etc/passwd /etc/group /etc/shadow /etc/gshadow
grep -q "^atos:[$]y[$]" /etc/shadow && echo ATOS-ADMIN-PASSWORD-YESCRYPT
printf "%s\n" "$pw" | runuser -u atos -- sudo -S -k -p "" true && echo ATOS-ADMIN-SUDO-OK
printf "wrong\n" | runuser -u atos -- sudo -S -k -p "" true 2>/dev/null || echo ATOS-ADMIN-SUDO-WRONG-REFUSED
flatpak remotes --system --columns=name,url 2>&1 | sed "s/^/ATOS-FLATPAK-REMOTE /"
echo "ATOS-FLATPAK-OS-INFO $(flatpak config --system --get report-os-info 2>&1)"
grep -q "^Exec=xterm" /usr/share/applications/xterm.desktop && echo ATOS-TERMINAL-ENTRY'

# boot <log>: boots the installed disk with the report unit (env ACTION, NET=1).
boot() {
  local log=$1 creds nic=(-nic none)
  mapfile -d '' creds < <(
    cred systemd.extra-unit.atos-report.service "$REPORT_UNIT"
    cred systemd.unit-dropin.multi-user.target~atos-report $'[Unit]\nWants=atos-report.service'
    # The serial getty also starts here and hangs up the serial tty the report writes to.
    cred "systemd.unit-dropin.serial-getty@$SERIAL.service~test" $'[Unit]\nConditionPathExists=/nonexistent'
    # Without KVM, udev in the initrd needs longer than the default 45 s to find the root.
    cred 'systemd.unit-dropin.dev-gpt\x2dauto\x2droot\x2dluks.device~timeout' $'[Unit]\nJobRunningTimeoutSec=10min'
    cred 'systemd.unit-dropin.dev-gpt\x2dauto\x2droot.device~timeout' $'[Unit]\nJobRunningTimeoutSec=10min'
    cred atos.check "$ADMIN_CHECK"
    cred atos.test-password "$TEST_PASSWORD"
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

# An empty disk, a new TPM and fresh firmware variables: setup mode, as on a machine prepared for key
# enrolment.
fresh_machine() {
  rm -f "$DISK" "$VARS" && truncate -s 20G "$DISK"
  rm -rf "$TPM"
  cp "$VARS0" "$VARS"
}
# shellcheck disable=SC2054 # commas are QEMU option syntax
CDROM=(-device virtio-scsi-pci,id=scsi0 -drive if=none,id=cd,format=raw,media=cdrom,readonly=on,file="$ISO"
  -device scsi-cd,drive=cd,bootindex=0)

step_install() {
  # atos-install has no question for the image: it installs its built-in default (#220).
  local default=ghcr.io/jens-thomae/atos/c1-base:latest creds t0
  [ "$TARGET_IMGREF" = "$default" ] || { echo "install: the payload must be $default; use unattended" >&2; exit 1; }
  fresh_machine
  mapfile -d '' creds < <(
    cred systemd.extra-unit.atos-screen.service "$SCREEN_UNIT"
    cred systemd.unit-dropin.multi-user.target~atos-screen $'[Unit]\nWants=atos-screen.service'
    cred atos.screen "$SCREEN_SCRIPT"
    # The serial getty hangs up the serial tty the screen unit writes to.
    cred "systemd.unit-dropin.serial-getty@$SERIAL.service~test" $'[Unit]\nConditionPathExists=/nonexistent')
  t0=$(date +%s)
  # -no-reboot: the restart the user confirms ends QEMU, and so does any restart before it.
  INTERACTIVE=1 POLL=1 qemu_run "$OUT/install.log" -no-reboot -nic none "${CDROM[@]}" "${creds[@]}"
  local t=$(($(date +%s) - t0))
  [ "$asked" -eq ${#QUESTIONS[@]} ] || { echo "install: QEMU ended after $asked of ${#QUESTIONS[@]} answers" >&2; exit 1; }
  grep -aq 'ATOS-SCREEN Atos is installed on /dev/vda' "$OUT/install.log"
  grep -aq 'reboot: Restarting system' "$OUT/install.log"
  ! grep -aqF "$TEST_PASSWORD" "$OUT/install.log" || { echo "the password is in the install log" >&2; exit 1; }
  echo "ATOS-INSTALL-TIME qemu_start_to_poweroff=${t}s"
}

step_unattended() {
  fresh_machine
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
  qemu_run "$OUT/install.log" -nic none "${CDROM[@]}" "${creds[@]}"
  grep -aq ATOS-INSTALL-OK "$OUT/install.log"
  grep -aq 'Password for the administrator account' "$OUT/install.log"
  ! grep -aqF "$TEST_PASSWORD" "$OUT/install.log" || { echo "the password is in the install log" >&2; exit 1; }
  echo "ATOS-INSTALL-TIME qemu_start_to_poweroff=$(( $(date +%s) - t0 ))s"
}

# x86_64 OVMF rejects systemd-boot's PK write from loader/keys/auto ("Security violation"; AAVMF
# accepts it), so CI enrols the TEST keys into the variables from outside, as a vendor tool would.
# Needs virt-fw-vars (python3-virt-firmware). The certificates come out of the committed .auth files.
step_enrol() {
  local k=$WORK/keys G=4a3d6e0b-5f2c-4b7e-9a51-7465737400a7 # owner GUID, secureboot-test/generate.sh
  mkdir -p "$k"
  python3 -I - "$REPO/components/c1-base/secureboot-test" "$k" <<'EOF'
import ssl, struct, sys
src, out = sys.argv[1:]
for k in ("PK", "KEK", "db"):
    b = open(f"{src}/{k}.auth", "rb").read()
    esl = 16 + struct.unpack_from("<I", b, 16)[0]  # after EFI_TIME and WIN_CERTIFICATE
    hsize, ssize = struct.unpack_from("<II", b, esl + 20)
    der = b[esl + 28 + hsize + 16 : esl + 28 + hsize + ssize]  # skip header and owner GUID
    open(f"{out}/{k}.pem", "w").write(ssl.DER_cert_to_PEM_cert(der))
EOF
  virt-fw-vars --input "$VARS" --output "$VARS.new" --set-pk "$G" "$k/PK.pem" \
    --add-kek "$G" "$k/KEK.pem" --add-db "$G" "$k/db.pem" --secure-boot
  mv "$VARS.new" "$VARS"
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
  images|iso|install|unattended|enrol|boot|reboot|stage|apply|nosb) "step_$1" ;;
  # The dev VM's payload is a local registry reference, which the interactive path cannot name.
  all) for s in images iso unattended boot reboot stage apply nosb; do "step_$s"; done ;;
  *) sed -n '2,26p' "$0" >&2; exit 2 ;;
esac
