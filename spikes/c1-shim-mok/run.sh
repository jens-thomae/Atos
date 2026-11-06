#!/bin/bash
# Spike #76 (D-014 fallback B2): Fedora's Microsoft-signed shim -> our TEST-signed systemd-boot
# -> sealed UKI, with the TEST db cert enrolled as a MOK. Not part of the image build.
# Runs inside the dev VM, after `tools/dev-vm/sealed.sh build disk` has made ~/sealed/disk.raw:
#   ATOS_VM=atos-c1 tools/dev-vm/vm run spikes/c1-shim-mok/run.sh <step>
#   fetch      Fedora 45's shim RPMs (dnf checks Fedora's RPM signatures), extracted to ~/shim/x
#   sigs       Authenticode signatures of shimx64/shimaa64/MokManager/fallback
#   disk       copy ~/sealed/disk.raw to ~/shim/shim.raw and put shim in front of systemd-boot
#   direct     baseline: systemd-boot started directly under the Microsoft db (expect: refused)
#   nomok      shim -> systemd-boot with an empty MokList; nobody at the keyboard
#   enroll     the same, but enrol the cert in MokManager ("Enroll key from disk"), then boot on
#   tamper     MOK enrolled, one byte of the UKI's command line changed (expect: refused)
#   x64        shimx64 under OVMF (x86 TCG) with db = UEFI CA 2011 only, then 2023 only
#   all        everything in order
# Firmware: Ubuntu's AAVMF_VARS.ms.fd (Microsoft KEK 2011+2023; db: Windows PCA 2011, UEFI CA 2011,
# UEFI CA 2023, Option ROM UEFI CA 2023, Windows UEFI CA 2023). Logs: ~/shim/out/.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$HERE/../.."
W=~/shim OUT=~/shim/out
X=$W/x/usr/lib/efi/shim/16.1-7/EFI
mkdir -p "$W" "$OUT"
tools() { sudo podman run --rm -v "$W:/w:z" -v "$REPO:/repo:ro" localhost/shim-tools "$@"; }

step_fetch() {
  sudo podman image exists localhost/shim-tools || {
    sudo podman run --name shim-tools-build registry.fedoraproject.org/fedora:45 dnf -y install \
      python3-virt-firmware python3-pefile sbsigntools openssl cpio qemu-system-x86-core edk2-ovmf dosfstools mtools
    sudo podman commit shim-tools-build localhost/shim-tools && sudo podman rm shim-tools-build; }
  tools bash -c 'set -e; rm -rf /w/rpm /w/x; mkdir -p /w/rpm /w/x; cd /w/rpm
    dnf -q download shim-aa64 mokutil systemd-boot-unsigned
    dnf -q download --forcearch=x86_64 shim-x64 systemd-boot-unsigned
    rpm -K *.rpm
    cd /w/x; for r in /w/rpm/*.rpm; do rpm2cpio $r | cpio -idm 2>/dev/null; done
    sha256sum /w/rpm/*.rpm'
}

step_sigs() {
  tools bash -c "cd /w/x/usr/lib/efi/shim/16.1-7/EFI && python3 -I /repo/spikes/c1-shim-mok/sigs.py \
    fedora/shimx64.efi fedora/shimaa64.efi fedora/mmx64.efi fedora/mmaa64.efi BOOT/fbx64.efi BOOT/fbaa64.efi"
}

esp=$W/esp dev=
open_esp() { # <disk>
  dev=$(sudo losetup -fP --show "$1")
  mkdir -p "$esp" && sudo mount "$(sudo blkid -t TYPE=vfat -o device "$dev"p*)" "$esp"
}
close_esp() { sudo umount "$esp" && sudo losetup -d "$dev"; }

step_disk() {
  cp --sparse=always ~/sealed/disk.raw $W/shim.raw
  open_esp $W/shim.raw
  # The removable-media path: firmware -> shim -> grubaa64.efi, shim's default second stage,
  # which here is our signed systemd-boot. MokManager sits next to shim, as shim expects.
  sudo cp "$esp/EFI/systemd/systemd-bootaa64.efi" "$esp/EFI/BOOT/grubaa64.efi"
  sudo cp "$X/fedora/shimaa64.efi" "$esp/EFI/BOOT/BOOTAA64.EFI"
  sudo cp "$X/fedora/mmaa64.efi" "$esp/EFI/BOOT/mmaa64.efi"
  # The cert the user enrols, in DER, as MokManager reads it. Only the public TEST db cert.
  sudo mkdir -p "$esp/EFI/atos"
  sudo openssl x509 -in "$REPO/components/c1-base/secureboot-test/db.crt" -outform DER -out "$esp/EFI/atos/atos-test-db.cer"
  # Not setup mode here, so systemd-boot would not enrol them anyway; removed so nothing touches db.
  sudo rm -rf "$esp/loader/keys"
  sudo find "$esp" -type f -exec sha256sum {} + | sed "s|$esp||"
  close_esp
}

# Same dev-VM-only report and root timeout as tools/dev-vm/sealed.sh, as systemd credentials over SMBIOS.
REPORT_UNIT='[Unit]
Description=Atos shim spike report (dev VM only)
ConditionPathExists=!/etc/initrd-release
After=multi-user.target
[Service]
Type=oneshot
StandardOutput=journal+console
ExecStart=/bin/sh -c "echo ATOS-REPORT-BEGIN; bootctl status --no-pager 2>&1 | head -25; echo; for v in MokListRT MokListTrustedRT SbatLevelRT; do ls /sys/firmware/efi/efivars/$v-* 2>&1; done; echo; grep -h . /proc/keys | grep -iE \"asymmetric\" ; echo; cat /sys/kernel/security/lockdown; cat /proc/cmdline; echo ATOS-REPORT-END"
ExecStartPost=/usr/bin/systemctl poweroff --no-block'
cred() { printf -- '-smbios\0type=11,value=io.systemd.credential.binary:%s=%s\0' "$1" "$(printf '%s' "$2" | base64 -w0)"; }

# qemu_a64 <disk> <vars> <case> <drive.py steps...>: boots with the serial console on a socket that
# drive.py types into; logs to $OUT/<case>.log. QEMU is stopped once drive.py is done.
qemu_a64() {
  local disk=$1 vars=$2 case=$3; shift 3
  local CREDS sock=$W/$case.sock
  mapfile -d '' CREDS < <(
    cred systemd.extra-unit.atos-report.service "$REPORT_UNIT"
    cred systemd.unit-dropin.multi-user.target~atos-report $'[Unit]\nWants=atos-report.service'
    cred 'systemd.unit-dropin.dev-gpt\x2dauto\x2droot.device~timeout' $'[Unit]\nJobRunningTimeoutSec=10min')
  rm -f "$sock"
  echo "== $case"
  timeout 45m qemu-system-aarch64 -machine virt -cpu max -smp 4 -m 4G -display none -nic none \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.secboot.fd \
    -drive if=pflash,format=raw,file="$vars" \
    -drive if=virtio,format=raw,file="$disk" \
    -serial unix:"$sock",server=on,wait=off "${CREDS[@]}" &
  local pid=$! rc=0
  python3 "$HERE/drive.py" "$sock" "$OUT/$case.log" "$@" || rc=$?
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  summary "$OUT/$case.log"
  return $rc
}
summary() {
  tr -d '\r' < "$1" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -aE \
    'shim|Shim|MOK|Mok|[Vv]erification|[Ss]ecurity [Vv]iolation|[Aa]ccess [Dd]enied|Error|Failed to|secureboot:|integrity:|Loaded X.509|Lockdown|ATOS-REPORT|sh\[[0-9]+\]:|lockdown|Booting|Welcome' \
    | cut -c1-200 | uniq | head -80 || true
}
ms_vars() { cp /usr/share/AAVMF/AAVMF_VARS.ms.fd "$1"; }
HALT='Freezing execution|Entering emergency mode|Kernel panic|reboot: Power down|ATOS-REPORT-END'
DOWN='\x1b[B' ENTER='\r'

step_direct() {
  ms_vars $W/vars-direct.fd
  cp --sparse=always ~/sealed/disk.raw $W/direct.raw
  open_esp $W/direct.raw; sudo rm -rf "$esp/loader/keys"; close_esp
  qemu_a64 $W/direct.raw $W/vars-direct.fd direct "e300:Access Denied|[Ss]ecurity [Vv]iolation|systemd-boot" "e20:.*" || true
}

step_nomok() {
  ms_vars $W/vars-nomok.fd
  # Expect: shim's error, a reset, and the same error again (a loop until someone presses a key).
  qemu_a64 $W/shim.raw $W/vars-nomok.fd nomok 'e300:Security Violation' 'e300:UEFI firmware' 'e300:Security Violation'

}

step_enroll() {
  ms_vars $W/vars.fd  # kept: the MOK enrolled here is used by `tamper`
  # What a person does: OK on shim's error, which starts MokManager; any key; "Enroll key from
  # disk"; the ESP; EFI/ (the only folder, apart from loader/); atos/ (5th entry); the .cer;
  # "View key 0" and back; "Continue"; "Yes"; "Reboot". No password: the keystrokes are the consent.
  qemu_a64 $W/shim.raw $W/vars.fd enroll \
    'e300:Security Violation' "s:$ENTER" 'e60:Press any key' "s:$ENTER" \
    'e20:Enroll hash from disk' "s:$DOWN" "s:$ENTER" 'e20:EFI-SYSTEM' "s:$ENTER" \
    'e20:loader/' "s:$ENTER" 'e20:atos/' "s:$DOWN" "s:$DOWN" "s:$DOWN" "s:$DOWN" "s:$ENTER" \
    'e20:atos-test-db.cer' "s:$DOWN" "s:$ENTER" 'e20:View key 0' "s:$ENTER" 'e20:Fingerprint' "s:$ENTER" \
    'e20:Continue' "s:$DOWN" "s:$ENTER" 'e20:Yes' "s:$DOWN" "s:$ENTER" 'e20:Reboot' "s:$ENTER" \
    "until:$HALT"
}

step_tamper() {
  cp --sparse=always $W/shim.raw $W/tamper.raw
  open_esp $W/tamper.raw
  local uki; uki=$(sudo find "$esp/EFI/Linux" -name '*.efi')
  sudo python3 -c 'import sys; p=sys.argv[1]; b=bytearray(open(p,"rb").read()); i=b.find(b"composefs.digest=v1-sha512-12:")+30; b[i]=ord("1") if b[i]==ord("0") else ord("0"); open(p,"wb").write(b)' "$uki"
  close_esp
  cp $W/vars.fd $W/vars-tamper.fd
  qemu_a64 $W/tamper.raw $W/vars-tamper.fd tamper "until:$HALT|[Ss]ecurity [Vv]iolation|Access Denied|Booting|Welcome to" || true
}

# x64: does OVMF accept Fedora's dual-signed shimx64 with only one of the two CAs in db? The ESP holds
# shimx64 + MokManager and, as second stage, Fedora's x64 systemd-boot signed with the TEST db key; the
# TEST cert is put straight into MokList (the MokManager flow itself is tested on aarch64 above), so
# reaching systemd-boot's menu means firmware accepted shim and shim accepted our key.
step_x64() {
  tools bash -c '
    set -e; cd /w; X=/w/x/usr/lib/efi/shim/16.1-7/EFI; K=/repo/components/c1-base/secureboot-test
    rm -rf esp64 && mkdir -p esp64/EFI/BOOT
    cp $X/fedora/shimx64.efi esp64/EFI/BOOT/BOOTX64.EFI; cp $X/fedora/mmx64.efi esp64/EFI/BOOT/
    sbsign --key $K/db.key --cert $K/db.crt --output esp64/EFI/BOOT/grubx64.efi \
      /w/x/usr/lib/systemd/boot/efi/systemd-bootx64.efi 2>&1 | grep -v "^warning: data remaining"
    rm -f esp64.img && mkfs.vfat -C -n ESP64 esp64.img 65536 >/dev/null && mcopy -s -i esp64.img esp64/EFI ::/
    MS=/usr/share/virt-sb-certs/microsoft.com
    # db holds exactly one certificate per case; the control holds only Windows PCA 2011.
    for case in uefi2011:ms-uefi-2011 uefi2023:ms-uefi-2023 windows2011:windows-2011; do
      db=${case%%:*}
      virt-fw-vars -i /usr/share/edk2/ovmf/OVMF_VARS.fd -o vars64-$db.fd --enroll-generate "Atos spike PK (throwaway)" \
        --microsoft-db none --add-db 77fa9abd-0359-4d32-bd60-28f4e78f784b $MS/${case#*:}.pem \
        --microsoft-kek all --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 $K/db.crt --sb 2>/dev/null
      echo "== x64, db $db:"; virt-fw-vars -i vars64-$db.fd -p -v 2>/dev/null | sed -n "/^name=db /,/^name=[^d]/p" | grep subject | sed "s/^ */   db: /"
      timeout 240 qemu-system-x86_64 -machine q35,smm=on -accel tcg -m 1G -display none -nic none -no-reboot \
        -global driver=cfi.pflash01,property=secure,value=on \
        -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.secboot.fd \
        -drive if=pflash,format=raw,unit=1,file=vars64-$db.fd \
        -drive if=virtio,format=raw,file=esp64.img -serial file:/w/out/x64-$db.log >/dev/null 2>&1 || true
      tr -d "\r" < /w/out/x64-$db.log | sed "s/\x1b\[[0-9;?]*[a-zA-Z]/\n/g" \
        | grep -aE "BdsDxe|Access Denied|Verification|Violation|systemd-boot|Boot Menu|Reboot Into|Firmware Setup|No boot" | sort -u | cut -c1-140
    done'
}

case "${1:-}" in
  fetch|sigs|disk|direct|nomok|enroll|tamper|x64) "step_$1" ;;
  # try <drive.py steps...>: shim.raw with fresh Microsoft vars, for finding out what MokManager shows
  try) shift; ms_vars $W/vars-try.fd; qemu_a64 $W/shim.raw $W/vars-try.fd try "$@" || true
    tr -d '\r' < $OUT/try.log | sed 's/\x1b\[[0-9;?]*[a-zA-Z]/\n/g' | grep -av '^[ |/\\-]*$' | tail -60 | cut -c1-160 ;;
  all) for s in fetch sigs disk direct nomok enroll tamper x64; do "step_$s"; done ;;
  *) sed -n '2,16p' "$0" >&2; exit 2 ;;
esac
