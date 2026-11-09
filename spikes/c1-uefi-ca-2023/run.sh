#!/bin/bash
# Card #165: what adds Microsoft UEFI CA 2023 to a B1 db that systemd-boot enrolled
# (docs/components/c1-base/uefi-ca-2023.md). Not part of the image build.
# Runs inside the dev VM, after `tools/dev-vm/sealed.sh build` has made localhost/c1-base:
#   ATOS_VM=atos-c165 tools/dev-vm/vm run spikes/c1-uefi-ca-2023/run.sh [step...]
# Steps, all in order by default:
#   tools     a container FROM the image's base: virt-firmware, sbsigntools, openssl, Fedora's edk2
#             firmware (aarch64 and x86_64 OVMF) and QEMU for both; logs the firmware versions
#   keys      VM-only PK and KEK in ~/sealed/ca2023/keys (never committed) and one db per variant:
#               with2011  TEST db cert + Microsoft Corporation UEFI CA 2011 + Option ROM UEFI CA 2023
#                         (the card's B1 db, without #158's test CA)
#               no2011    TEST db cert + Option ROM UEFI CA 2023 (control)
#               pca2011   TEST db cert + Microsoft Windows Production PCA 2011 (D-014's optional
#                         Windows CA)
#   sdboot    the card's reproduction: Ubuntu AAVMF in setup mode, an ESP with only the image's
#             signed systemd-boot and loader/keys/auto/{PK,KEK,db}.auth; systemd-boot enrols and
#             resets; QEMU stops after the firmware's second pass; db printed with virt-fw-vars -p.
#             No kernel runs. Once per variant
#   fwonly    no systemd-boot either: the same PK/KEK/db written into a variable store with
#             virt-fw-vars (user mode), then the firmware boots an ESP holding only an unsigned
#             EFI binary, which it must refuse (Secure Boot enforced). db printed before and
#             after. Once per firmware (Ubuntu AAVMF, Fedora x86_64 OVMF) and variant; Fedora
#             AAVMF once (its pflash build has no Secure Boot, which the log shows)
#   scan      which firmware images contain the Microsoft 2023 certs in their (LZMA-compressed)
#             firmware volume, and the source of the code that writes them: Ubuntu's edk2 source
#             package for the VM's firmware version, fetched from Launchpad and checked by the
#             sha256 its .dsc lists; and whether upstream edk2 (tianocore, master) has that driver
# Logs: tools/dev-vm/out/sealed/ca2023-*.
set -euo pipefail
SPIKE="$(cd "$(dirname "$0")" && pwd)"
REPO="$SPIKE/../.."
WORK=~/sealed/ca2023 K=~/sealed/ca2023/keys
OUT="$REPO/tools/dev-vm/out/sealed"
IMAGE=localhost/c1-base
BASE=$(sed -n 's/^ARG BASE=//p' "$REPO/components/c1-base/Containerfile")
TOOLS=localhost/ca2023-tools
VARIANTS="with2011 no2011 pca2011"
mkdir -p "$WORK" "$K" "$OUT"
# The VM's own firmware (Ubuntu's qemu-efi-aarch64), as tools/dev-vm/sealed.sh boots it.
tools() { sudo podman run --rm -v "$WORK:/w:z" -v "$REPO:/repo:ro" -v /usr/share/AAVMF:/aavmf:ro "$TOOLS" "$@"; }

step_tools() {
  sudo podman build -t "$TOOLS" -f - "$WORK" <<EOF
FROM $BASE
RUN dnf -y install --setopt=install_weak_deps=False python3-virt-firmware sbsigntools openssl \
      edk2-aarch64 edk2-ovmf qemu-system-aarch64-core qemu-system-x86-core dosfstools mtools xz \
    && dnf clean all
EOF
  {
    echo "== VM (host of QEMU for sdboot/fwonly Ubuntu runs): $(dpkg-query -W qemu-efi-aarch64)"
    tools sh -c 'rpm -q edk2-aarch64 edk2-ovmf python3-virt-firmware qemu-system-aarch64-core qemu-system-x86-core
      ls /usr/share/edk2/aarch64 /usr/share/edk2/ovmf'
  } | tee "$OUT/ca2023-tools.log"
}

step_keys() {
  # shellcheck disable=SC2016 # expands in the container
  tools bash -euc 'cd /w/keys; guid=4a3d6e0b-5f2c-4b7e-9a51-7465737400a7
    for k in PK KEK; do
      [ -f $k.key ] || openssl req -quiet -newkey rsa:2048 -nodes -keyout $k.key -x509 -sha256 -days 3650 \
        -subj "/CN=Atos TEST ca2023 $k (dev VM) - not for release/" -out $k.crt
    done
    MS=/usr/share/virt-sb-certs/microsoft.com
    cp /repo/components/c1-base/secureboot-test/db.crt db-test.crt
    cp $MS/ms-uefi-2011.pem ms-uefi-2011.crt; cp $MS/ms-uefi-rom-2023.pem ms-uefi-rom-2023.crt
    cp $MS/windows-2011.pem ms-pca-2011.crt
    for k in PK KEK db-test ms-uefi-2011 ms-uefi-rom-2023 ms-pca-2011; do
      openssl x509 -in $k.crt -outform DER -out $k.der
      sbsiglist --owner $guid --type x509 --output $k.esl $k.der
      echo "$k: $(openssl x509 -in $k.crt -noout -subject)"
    done
    cat db-test.esl ms-uefi-2011.esl ms-uefi-rom-2023.esl > db-with2011.esl
    cat db-test.esl ms-uefi-rom-2023.esl > db-no2011.esl
    cat db-test.esl ms-pca-2011.esl > db-pca2011.esl
    # Setup mode: the firmware does not check these signatures.
    sbvarsign --key PK.key --cert PK.crt --output PK.auth PK PK.esl
    sbvarsign --key PK.key --cert PK.crt --output KEK.auth KEK KEK.esl
    for v in with2011 no2011 pca2011; do
      sbvarsign --key KEK.key --cert KEK.crt --output db-$v.auth db db-$v.esl
      echo "db-$v.esl: $(stat -c %s db-$v.esl) bytes"
    done' | tee "$OUT/ca2023-keys.log"
}

# Firmware: <name> -> QEMU arguments (code and the vars template). Ubuntu's is the VM's own.
fw_code() {
  case $1 in
    ubuntu-aavmf) echo /aavmf/AAVMF_CODE.secboot.fd ;;
    fedora-aavmf) echo /usr/share/edk2/aarch64/QEMU_EFI-pflash.raw ;;  # one image, Secure Boot built in
    fedora-ovmf)  echo /usr/share/edk2/ovmf/OVMF_CODE.secboot.fd ;;
  esac
}
fw_vars() {
  case $1 in
    ubuntu-aavmf) echo /aavmf/AAVMF_VARS.fd ;;
    fedora-aavmf) echo /usr/share/edk2/aarch64/vars-template-pflash.raw ;;
    fedora-ovmf)  echo /usr/share/edk2/ovmf/OVMF_VARS.fd ;;
  esac
}

# Boots <firmware> with <vars> (in /w) and an optional ESP image, until the firmware has run its
# boot options (or <seconds> pass), then stops QEMU. In the container: QEMU without KVM.
qemu() { # <firmware> <vars> <seconds> <log> [esp image]
  local fw=$1 vars=$2 secs=$3 log=$4 esp=${5:-}
  # shellcheck disable=SC2016 # expands in the container
  tools bash -uc '
    fw=$1 vars=$2 secs=$3 log=$4 esp=$5 code=$6
    disk=(); [ -z "$esp" ] || disk=(-drive if=virtio,format=raw,file=/w/$esp)
    if [ "$fw" = fedora-ovmf ]; then
      # Secure Boot OVMF needs SMM and a secure pflash.
      m=(qemu-system-x86_64 -machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on -cpu max)
    else
      m=(qemu-system-aarch64 -machine virt -cpu max)
    fi
    rm -f /w/$log
    "${m[@]}" -m 2G -display none -nic none -serial file:/w/$log \
      -drive if=pflash,format=raw,readonly=on,file=$code -drive if=pflash,format=raw,file=/w/$vars \
      "${disk[@]}" &
    pid=$!
    # Done once the firmware refuses an unsigned boot option (Secure Boot enforced) or offers its
    # boot manager, or (sdboot) systemd-boot shows its menu after the reset. The variable writes
    # happen earlier, in the DXE phase.
    for _ in $(seq "$secs"); do
      kill -0 $pid 2>/dev/null || break
      grep -saqE "Boot Manager|Shell>|Access Denied|Security Violation|Reboot Into Firmware" /w/$log && { sleep 5; break; }
      sleep 1
    done
    kill $pid 2>/dev/null; wait $pid 2>/dev/null; true' bash "$fw" "$vars" "$secs" "$log" "$esp" "$(fw_code "$fw")"
}

# Prints PK, KEK, db (cert subjects), CustomMode, SecureBootEnable and the updater's version
# variable of a variable store, one line each; "absent" for any that is not there.
print_vars() { # <vars> <label>
  tools sh -c "virt-fw-vars -i /w/$1 -p -v 2>/dev/null" | awk -v l="ATOS-CA $2" '
    /^name=/ { n=$1; sub("name=","",n); show=(n ~ /^(PK|KEK|db|CustomMode|SecureBootEnable|FirmwareSecvarUpdaterVersion)$/)
               if (show) { seen[n]=1; print l " " n ": " $3 } next }
    show && /subject|bool:|dword:/ { sub(/^ */,""); print l "   " n ": " $0 }
    END { split("PK KEK db CustomMode SecureBootEnable FirmwareSecvarUpdaterVersion", a, " ")
          for (i in a) if (!(a[i] in seen)) print l " " a[i] ": absent" }'
}

# The card's reproduction: an ESP with only systemd-boot (the image's, signed with the TEST db key)
# and the key set; Ubuntu AAVMF in setup mode.
step_sdboot() {
  local v img esp=$WORK/esp
  sudo podman create --name ca2023-img "$IMAGE" >/dev/null
  sudo podman cp ca2023-img:/usr/lib/systemd/boot/efi/systemd-bootaa64.efi.signed "$WORK/systemd-bootaa64.efi"
  sudo podman rm ca2023-img >/dev/null
  sudo chown "$(id -u)" "$WORK/systemd-bootaa64.efi"
  for v in $VARIANTS; do
    img=esp-$v.img
    rm -rf "$esp" && mkdir -p "$esp/EFI/BOOT" "$esp/loader/keys/auto"
    cp "$WORK/systemd-bootaa64.efi" "$esp/EFI/BOOT/BOOTAA64.EFI"
    cp "$K/PK.auth" "$K/KEK.auth" "$esp/loader/keys/auto/"
    cp "$K/db-$v.auth" "$esp/loader/keys/auto/db.auth"
    # `if-safe` enrols in a VM (loader.conf(5)), as for sealed images; menu-force keeps systemd-boot
    # in its menu after the reset (no entries here), where QEMU is stopped.
    printf 'timeout menu-force\nsecure-boot-enroll if-safe\n' > "$esp/loader/loader.conf"
    # shellcheck disable=SC2016 # expands in the container
    tools bash -euc 'rm -f /w/$1; truncate -s 64M /w/$1; mkfs.vfat -F 32 /w/$1 >/dev/null; mcopy -s -i /w/$1 /w/esp/* ::/' bash "$img"
    cp /usr/share/AAVMF/AAVMF_VARS.fd "$WORK/sdboot-$v.fd"
    {
      echo "== sdboot $v: Ubuntu AAVMF, setup mode, ESP: $(strings "$WORK/systemd-bootaa64.efi" | grep -m1 -oE 'systemd-boot [0-9][^ ]*' || true) + loader/keys/auto (db-$v)"
      print_vars "sdboot-$v.fd" "sdboot-$v before:"
      # Two passes: the enrolling boot, then the boot after systemd-boot's reset (its menu).
      qemu ubuntu-aavmf "sdboot-$v.fd" 600 "sdboot-$v.serial" "$img"
      tr -d '\r' < "$WORK/sdboot-$v.serial" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' \
        | grep -aoE "UEFI firmware \(version [^ ]*|Enrolling[^.]*|[A-Za-z ]*successfully enrolled[^!]*|Access Denied|Reboot Into Firmware Interface" | uniq | sed 's/^/ATOS-CA serial: /'
      print_vars "sdboot-$v.fd" "sdboot-$v after:"
    } | tee "$OUT/ca2023-sdboot-$v.log"
  done
}

# Firmware only: variables written offline (user mode, Secure Boot on), no systemd-boot and no OS.
# The only disk is an ESP with an unsigned EFI binary at the removable-media path, which the firmware
# must refuse: that shows Secure Boot is enforced in the run. aarch64: the image's unsigned
# systemd-boot; x86_64: Fedora's unsigned EnrollDefaultKeys.efi (never runs).
step_fwonly() {
  local fw v vars
  sudo podman create --name ca2023-img "$IMAGE" >/dev/null
  sudo podman cp ca2023-img:/usr/lib/systemd/boot/efi/systemd-bootaa64.efi "$WORK/unsigned-aa64.efi"
  sudo podman rm ca2023-img >/dev/null
  # shellcheck disable=SC2016 # expands in the container
  tools bash -euc 'cd /w; cp /usr/share/edk2/ovmf/EnrollDefaultKeys.efi unsigned-x64.efi
    for a in aa64 x64; do
      echo "unsigned-$a.efi: $(sbverify --list unsigned-$a.efi 2>&1 | head -1)"
      A=$(echo $a | tr a-z A-Z); rm -f esp-unsigned-$a.img; truncate -s 64M esp-unsigned-$a.img
      mkfs.vfat -F 32 esp-unsigned-$a.img >/dev/null; mmd -i esp-unsigned-$a.img ::/EFI ::/EFI/BOOT
      mcopy -i esp-unsigned-$a.img unsigned-$a.efi ::/EFI/BOOT/BOOT$A.EFI
    done' | tee "$OUT/ca2023-fwonly-esp.log"
  for fw in ubuntu-aavmf fedora-aavmf fedora-ovmf; do
    # Fedora's aarch64 pflash build has no authenticated variables (no Secure Boot): one run shows it.
    for v in $([ "$fw" = fedora-aavmf ] && echo with2011 || echo "$VARIANTS"); do
      vars=fwonly-$fw-$v.fd
      {
        echo "== fwonly $fw $v: $(fw_code "$fw"), PK/KEK/db-$v written with virt-fw-vars, ESP with an unsigned binary only"
        # shellcheck disable=SC2016 # expands in the container
        tools bash -euc 'cd /w; t=$1 out=$2; k=keys; guid=4a3d6e0b-5f2c-4b7e-9a51-7465737400a7
          args=(--set-pk $guid $k/PK.crt --add-kek $guid $k/KEK.crt --secure-boot --no-microsoft)
          case $3 in
            with2011) certs="db-test ms-uefi-2011 ms-uefi-rom-2023" ;;
            no2011)   certs="db-test ms-uefi-rom-2023" ;;
            pca2011)  certs="db-test ms-pca-2011" ;;
          esac
          for c in $certs; do args+=(--add-db $guid $k/$c.crt); done
          virt-fw-vars -i "$t" -o "$out" "${args[@]}" 2>&1 | grep -vE "^INFO" || true' bash "$(fw_vars "$fw")" "$vars" "$v"
        print_vars "$vars" "fwonly-$fw-$v before:"
        a=aa64; [ "$fw" != fedora-ovmf ] || a=x64
        qemu "$fw" "$vars" 900 "fwonly-$fw-$v.serial" "esp-unsigned-$a.img"
        echo "ATOS-CA serial: $(grep -acE . "$WORK/fwonly-$fw-$v.serial") lines; boot option and Secure Boot lines:"
        tr -d '\r' < "$WORK/fwonly-$fw-$v.serial" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -aE 'BdsDxe: (failed|starting|No bootable)|AuthVariableLibInitialize|SecurityStubDxe.efi|3rd party image.*can be loaded' | grep -v 'EFI Internal Shell' | sed 's/^/ATOS-CA serial:   /'
        print_vars "$vars" "fwonly-$fw-$v after:"
      } | tee "$OUT/ca2023-fwonly-$fw-$v.log"
    done
  done
}

# Which firmware images carry the Microsoft 2023 certs, and the source that writes them.
UBUNTU_EDK2=2024.02-2ubuntu0.10
step_scan() {
  local src=$WORK/src lp=https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/edk2/$UBUNTU_EDK2
  {
    echo "== firmware volumes: Microsoft cert subjects found in the raw image or in an LZMA stream"
    # shellcheck disable=SC2016 # expands in the container
    tools python3 -I -c '
import glob, lzma
names = [b"Microsoft Corporation UEFI CA 2011", b"Microsoft UEFI CA 2023", b"Microsoft Option ROM UEFI CA 2023",
         b"Microsoft Windows Production PCA 2011", b"Windows UEFI CA 2023", b"Microsoft Corporation KEK 2K CA 2023"]
files = sorted(glob.glob("/aavmf/AAVMF_CODE*.fd") + glob.glob("/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw")
               + glob.glob("/usr/share/edk2/ovmf/OVMF_CODE*.fd"))
for f in files:
    b = open(f, "rb").read()
    found = set(n for n in names if n in b)
    i = 0
    while (i := b.find(b"\x5d\x00\x00", i)) >= 0:
        try:
            d = lzma.LZMADecompressor(lzma.FORMAT_ALONE).decompress(b[i:i + 16_000_000])
            found |= set(n for n in names if n in d)
        except Exception:
            pass
        i += 1
    print("ATOS-CA scan", f.replace("/aavmf/", "ubuntu:/usr/share/AAVMF/"), "->", ", ".join(sorted(x.decode() for x in found)) or "none")
'
    echo "== Ubuntu edk2 $UBUNTU_EDK2 source (the VM firmware's package)"
    rm -rf "$src" && mkdir -p "$src"
    curl -fsSL -o "$src/edk2.dsc" "$lp/edk2_$UBUNTU_EDK2.dsc"
    curl -fsSL -o "$src/debian.tar.xz" "$lp/edk2_$UBUNTU_EDK2.debian.tar.xz"
    sum=$(awk '/^Checksums-Sha256:/ {s=1; next} s && /debian.tar.xz/ {print $1; exit}' "$src/edk2.dsc")
    echo "$sum  $src/debian.tar.xz" | sha256sum --check
    tar -C "$src" -xJf "$src/debian.tar.xz"
    p=$src/debian/patches/OvmfPkg-FirmwareSecvarUpdater-append-Microsoft-2023-CAs-t.patch
    echo "ATOS-CA source: debian/patches/series line: $(grep -n FirmwareSecvarUpdater "$src/debian/patches/series")"
    echo "ATOS-CA source: changelog: $(grep -m1 -n 'FirmwareSecvarUpdater' "$src/debian/changelog")"
    sed -n '1,5p' "$p" | sed 's/^/ATOS-CA source: patch: /'
    grep -nE 'Update rules:|^- (KEK|db):|Custom Mode|SetupMode != 0|SECVAR_UPDATER_VERSION +[0-9]|CompareMem \(SigData|EFI_VARIABLE_APPEND_WRITE|SetCustomMode \(CUSTOM|ArmVirtQemuFvMain.fdf.inc|OvmfPkgX64.fdf' "$p" \
      | sed 's/^/ATOS-CA source: patch line /'
    local gh=https://raw.githubusercontent.com/tianocore/edk2/master/OvmfPkg f
    for f in FirmwareSecvarUpdater/FirmwareSecvarUpdater.inf EnrollDefaultKeys/EnrollDefaultKeys.inf; do
      echo "ATOS-CA upstream edk2 master OvmfPkg/$f: HTTP $(curl -s -o /dev/null -w '%{http_code}' "$gh/$f")"
    done
  } 2>&1 | tee "$OUT/ca2023-scan.log"
}

[ $# -gt 0 ] || set -- tools keys sdboot fwonly scan
for s in "$@"; do "step_$s"; done
