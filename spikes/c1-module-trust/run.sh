#!/bin/bash
# Card #158: which certificates does Fedora's kernel accept for kernel module signatures on an Atos
# machine? (docs/components/c1-base/module-trust.md). Not part of the image build.
# Runs inside the dev VM, after `tools/dev-vm/sealed.sh build` has made localhost/c1-base:
#   ATOS_VM=atos-c1 tools/dev-vm/vm run spikes/c1-module-trust/run.sh [step...]
# Reuses boot() and the paths of tools/dev-vm/sealed.sh. Steps, all in order by default:
#   tools    a container FROM the image's base (same kernel): kernel-devel for that kernel, openssl,
#            sbsigntools, virt-firmware; Fedora's shim comes from the base image itself
#   keys     VM-only keys in ~/sealed/modtrust/keys, never committed (below)
#   modules  builds one test module per case for the image's kernel and signs it (CASES below)
#   install  installs the image to ~/sealed/modtrust.raw (B1) and makes a B2 copy of it
#   b1       B1 (D-014): setup-mode enrolment of PK, KEK and db = TEST db cert + test CA + Microsoft
#            UEFI CA 2011 + Microsoft Option ROM UEFI CA 2023; boots sealed, tries every module
#   b2       B2 (D-016): firmware with Microsoft KEK/db, Fedora shim -> our systemd-boot; MokList =
#            TEST db cert (so the UKI boots) + the non-CA `mok` cert; MokListTrusted off (the
#            variable present, as `mokutil --untrust-mok` leaves it); tries every module
# Keys (all VM-only, RSA-2048, except the committed TEST db key):
#   PK, KEK   stand-ins for D-014's per-machine keys (the committed TEST set has no KEK private key)
#   ca        CA:TRUE, keyUsage keyCertSign+cRLSign only (no digitalSignature), no EKU: shaped like
#             a third-party CA in db. In db on B1
#   leaf-cs   issued by ca: CA:FALSE, digitalSignature, EKU codeSigning. In no keyring
#   leaf-tls  issued by ca: CA:FALSE, keyEncipherment only, EKU serverAuth. In no keyring
#   mok       self-signed, CA:FALSE, digitalSignature, EKU codeSigning. In MokList on B2 only
#   stranger  self-signed, in no keyring and no firmware variable
# Logs: tools/dev-vm/out/sealed/modtrust-*.
set -euo pipefail
SPIKE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null # boot, WORK, OUT, IMAGE come from sealed.sh
source "$SPIKE/../../tools/dev-vm/sealed.sh"
REPO="$SPIKE/../.."
M=$WORK/modtrust K=$WORK/modtrust/keys
B1DISK=$WORK/modtrust.raw B1VARS=$WORK/modtrust-vars.fd
B2DISK=$WORK/modtrust-b2.raw B2VARS=$WORK/modtrust-b2-vars.fd
BASE=$(sed -n 's/^ARG BASE=//p' "$REPO/components/c1-base/Containerfile")
TOOLS=localhost/modtrust-tools
mkdir -p "$M" "$K"
tools() { sudo podman run --rm -v "$M:/m:z" -v "$REPO:/repo:ro" "$TOOLS" "$@"; }

# One module per case, named mt_<case>; how each is signed:
#   unsigned    not signed (control: lockdown must refuse it)
#   stranger    sign-file, stranger key (control: a key in no keyring)
#   db          sign-file, committed TEST db key (the cert that signs our UKI; in db on B1, MOK on B2)
#   db_tamper   as db, then one byte of the module changed (control: the signature covers the code)
#   db_attrs    TEST db key, PKCS#7 with signed attributes (contentType, signingTime, messageDigest),
#               as Authenticode signatures have them
#   ca          sign-file, ca key (a CA cert without digitalSignature signs directly)
#   leaf_cs     leaf-cs key, its cert inside the PKCS#7 (chain to ca)
#   leaf_tls    leaf-tls key, its cert inside the PKCS#7 (chain to ca; wrong key usage and EKU)
#   mok         sign-file, mok key
CASES="unsigned stranger db db_tamper db_attrs ca leaf_cs leaf_tls mok"

step_tools() {
  local kver
  kver=$(sudo podman run --rm "$BASE" ls /usr/lib/modules)
  sudo podman build -t "$TOOLS" -f - "$M" <<EOF
FROM $BASE
RUN dnf -y install --setopt=install_weak_deps=False kernel-devel-$kver gcc make elfutils-libelf-devel \
      openssl sbsigntools python3-virt-firmware \
    && rpm -q kernel-core kernel-devel shim-aa64
EOF
}

# x509v3 extensions per key, for openssl -extfile.
ext() {
  case $1 in
    ca) echo 'basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash' ;;
    leaf-cs|mok) echo 'basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=codeSigning
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer' ;;
    leaf-tls) echo 'basicConstraints=critical,CA:FALSE
keyUsage=critical,keyEncipherment
extendedKeyUsage=serverAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer' ;;
    *) echo 'basicConstraints=critical,CA:TRUE
subjectKeyIdentifier=hash' ;;
  esac
}
step_keys() {
  [ -f "$K/db.auth" ] && return 0
  local k guid=4a3d6e0b-5f2c-4b7e-9a51-7465737400a7
  for k in PK KEK ca leaf-cs leaf-tls mok stranger; do ext "$k" > "$K/$k.ext"; done
  # shellcheck disable=SC2016 # expands in the container
  tools bash -euc 'cd /m/keys; guid=$1
    for k in PK KEK ca mok stranger; do
      openssl req -quiet -newkey rsa:2048 -nodes -keyout $k.key -x509 -sha256 -days 3650 \
        -subj "/CN=Atos TEST modtrust $k (dev VM) - not for release/" \
        -config <(printf "[req]\ndistinguished_name=dn\n[dn]\n[v3]\n"; cat $k.ext) -extensions v3 -out $k.crt
    done
    for k in leaf-cs leaf-tls; do
      openssl req -quiet -newkey rsa:2048 -nodes -keyout $k.key -subj "/CN=Atos TEST modtrust $k (dev VM) - not for release/" -out $k.csr
      openssl x509 -req -in $k.csr -CA ca.crt -CAkey ca.key -CAcreateserial -sha256 -days 3650 -extfile $k.ext -out $k.crt 2>/dev/null
    done
    for k in PK KEK ca mok stranger leaf-cs leaf-tls; do echo "== $k"; openssl x509 -in $k.crt -noout -subject -issuer -ext basicConstraints,keyUsage,extendedKeyUsage; done
    MS=/usr/share/virt-sb-certs/microsoft.com
    openssl x509 -in /repo/components/c1-base/secureboot-test/db.crt -outform DER -out db-test.der
    for k in PK KEK ca; do openssl x509 -in $k.crt -outform DER -out $k.der; done
    openssl x509 -in $MS/ms-uefi-2011.pem -outform DER -out ms-uefi-2011.der
    openssl x509 -in $MS/ms-uefi-rom-2023.pem -outform DER -out ms-uefi-rom-2023.der
    for k in PK KEK db-test ca ms-uefi-2011 ms-uefi-rom-2023; do sbsiglist --owner $guid --type x509 --output $k.esl $k.der; done
    cat db-test.esl ca.esl ms-uefi-2011.esl ms-uefi-rom-2023.esl > db.esl
    # Setup mode: the firmware does not check these signatures.
    sbvarsign --key PK.key --cert PK.crt --output PK.auth PK PK.esl
    sbvarsign --key PK.key --cert PK.crt --output KEK.auth KEK KEK.esl
    sbvarsign --key KEK.key --cert KEK.crt --output db.auth db db.esl' bash "$guid" | tee "$OUT/modtrust-keys.log"
}

# Appends a PKCS#7 module signature (<sig.der>) to <module>, as sign-file does: the signature,
# struct module_signature (id_type 2 = PKCS#7, sig_len big-endian) and the magic string.
APPEND='import struct, sys
mod, sig = sys.argv[1], open(sys.argv[2], "rb").read()
with open(mod, "ab") as f:
    f.write(sig + struct.pack(">BBBBB3xI", 0, 0, 2, 0, 0, len(sig)) + b"~Module signature appended~\n")'
step_modules() {
  local c src=$M/src
  rm -rf "$src" && mkdir -p "$src"
  for c in $CASES; do
    printf '#include <linux/module.h>\nstatic int __init atos_mt_init(void) { pr_info("atos-modtrust: %%s loaded\\n", KBUILD_MODNAME); return 0; }\nstatic void __exit atos_mt_exit(void) {}\nmodule_init(atos_mt_init);\nmodule_exit(atos_mt_exit);\nMODULE_LICENSE("GPL");\nMODULE_DESCRIPTION("Atos module trust test (dev VM only)");\n' > "$src/mt_$c.c"
  done
  echo "obj-m := $(for c in $CASES; do printf 'mt_%s.o ' "$c"; done)" > "$src/Makefile"
  # shellcheck disable=SC2016 # expands in the container
  tools bash -euc 'kver=$(ls /usr/src/kernels); cd /m/src
    make -s -C /usr/src/kernels/$kver M=/m/src modules
    SF="/usr/src/kernels/$kver/scripts/sign-file sha512" K=/m/keys DB=/repo/components/c1-base/secureboot-test
    for m in *.ko; do strip --strip-debug $m; done
    $SF $K/stranger.key $K/stranger.crt mt_stranger.ko
    $SF $DB/db.key $DB/db.crt mt_db.ko
    $SF $DB/db.key $DB/db.crt mt_db_tamper.ko
    # One byte of the module code (inside the signed part) changed: the "atos-modtrust" string.
    python3 -c "import sys; p=sys.argv[1]; b=bytearray(open(p,\"rb\").read()); i=b.find(b\"atos-modtrust\"); b[i]^=1; open(p,\"wb\").write(b)" mt_db_tamper.ko
    $SF $K/ca.key $K/ca.crt mt_ca.ko
    $SF $K/mok.key $K/mok.crt mt_mok.ko
    # openssl cms: detached, id-data, signer cert included (sign-file leaves certs out).
    openssl cms -sign -binary -noattr -nosmimecap -md sha512 -outform DER -in mt_leaf_cs.ko -signer $K/leaf-cs.crt -inkey $K/leaf-cs.key -out leaf_cs.p7
    openssl cms -sign -binary -noattr -nosmimecap -md sha512 -outform DER -in mt_leaf_tls.ko -signer $K/leaf-tls.crt -inkey $K/leaf-tls.key -out leaf_tls.p7
    openssl cms -sign -binary -nocerts -nosmimecap -md sha512 -outform DER -in mt_db_attrs.ko -signer $DB/db.crt -inkey $DB/db.key -out db_attrs.p7
    python3 -c "$1" mt_leaf_cs.ko leaf_cs.p7; python3 -c "$1" mt_leaf_tls.ko leaf_tls.p7; python3 -c "$1" mt_db_attrs.ko db_attrs.p7
    for p in leaf_cs leaf_tls db_attrs; do echo "== $p.p7"; openssl cms -cmsout -print -inform DER -in $p.p7 | grep -E "eContentType|subject:|signedAttrs:|object: (contentType|messageDigest)" | sed "s/^ */  /"; done
    echo "== kernel $kver"; for m in *.ko; do printf "%s %s bytes, signer: %s\n" $m $(stat -c %s $m) "$(modinfo -F signer $m)"; done
    mkdir -p /m/ko && cp *.ko /m/ko/' bash "$APPEND" | tee "$OUT/modtrust-modules.log"
}

# shellcheck disable=SC2154 # esp, dev: from sealed.sh
step_install() {
  rm -f "$B1DISK" && truncate -s 20G "$B1DISK"
  sudo podman run --rm --privileged --pid=host --security-opt label=type:unconfined_t \
    -v /var/lib/containers:/var/lib/containers -v /dev:/dev -v "$WORK:/out" \
    "$IMAGE" bootc install to-disk --generic-image --via-loopback "/out/$(basename "$B1DISK")"
  cp --sparse=always "$B1DISK" "$B2DISK"
  # B1: the VM's PK and KEK, and the db above, instead of the committed set.
  dev=$(sudo losetup -fP --show "$B1DISK")
  mkdir -p "$esp" && sudo mount "${dev}p1" "$esp"
  sudo cp "$K/PK.auth" "$K/KEK.auth" "$K/db.auth" "$esp/loader/keys/auto/"
  sudo umount "$esp" && sudo losetup -d "$dev"
  # B2, as in spike #76: firmware -> shim (removable-media path) -> grubaa64.efi = our signed
  # systemd-boot. No key set on the ESP: nothing enrols, the firmware keeps its Microsoft keys.
  dev=$(sudo losetup -fP --show "$B2DISK")
  sudo mount "${dev}p1" "$esp"
  local shim=/usr/lib/efi/shim/16.1-7/EFI/fedora
  sudo cp "$esp/EFI/systemd/systemd-bootaa64.efi" "$esp/EFI/BOOT/grubaa64.efi"
  sudo podman run --rm -v "$esp:/esp" "$TOOLS" sh -c "cp $shim/shimaa64.efi /esp/EFI/BOOT/BOOTAA64.EFI && cp $shim/mmaa64.efi /esp/EFI/BOOT/"
  sudo rm -rf "$esp/loader/keys"
  sudo umount "$esp" && sudo losetup -d "$dev"
}

# Guest script: keyrings and their keys, lockdown, MOK variables, then insmod of every module.
# The modules travel inside the script (xz, base64), as the systemd credential carries it.
action() {
  # shellcheck disable=SC2016 # expands in the guest
  printf '%s\n' 'echo "ATOS-MT kernel: $(uname -r), lockdown: $(cat /sys/kernel/security/lockdown)"
for v in MokListRT MokListTrustedRT; do f=$(ls /sys/firmware/efi/efivars/$v-* 2>/dev/null); echo "ATOS-MT $v: ${f:+present $(od -An -tx1 "$f" | tr -s " ")}${f:-absent}"; done
for r in .builtin_trusted_keys .secondary_trusted_keys .machine .platform; do
  id=$(awk -v r="$r:" "\$9 == r {print \$1}" /proc/keys)
  echo "ATOS-MT keyring $r: $(grep -E " keyring +$r:" /proc/keys | sed "s/.*$r: //")"
  [ -z "$id" ] || keyctl list 0x$id 2>&1 | sed -n "s/^ *[0-9]*: [^ ]* *[0-9]* *[0-9]* asymmetric: /ATOS-MT   $r: /p"
done
mkdir -p /run/mt && cd /run/mt'
  printf 'echo %s | base64 -d | tar -xJ\n' "$(tar -C "$M/ko" -cJ . | base64 -w0)"
  # SELinux (enforcing) lets kmod_t load only module files: label them as /usr/lib/modules is.
  # shellcheck disable=SC2016 # expands in the guest
  echo 'chcon -t modules_object_t ./*.ko && echo "ATOS-MT selinux: $(getenforce), modules labelled $(stat -c %C mt_db.ko)"'
  # shellcheck disable=SC2016 # expands in the guest
  printf '%s\n' "for c in $CASES; do" '  if out=$(insmod ./mt_$c.ko 2>&1); then echo "ATOS-MT module $c: LOADED"; else echo "ATOS-MT module $c: refused: ${out##*: }"; fi
done
journalctl -k -b --no-pager -o cat | grep -E "atos-modtrust|mt_[a-z_]+:|PKCS7|X.509|Lockdown|[Mm]odule.*(sig|verif)|Loaded X.509|Loading X.509|integrity:" | sed "s/^/ATOS-MT kernel: /"'
}

# The report runs the action with `sh -x`: its trace lines (`sh[pid]: + ...`) are left out.
summary() {
  tr -d '\r' < "$1" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -avE 'sh\[[0-9]+\]: \+' \
    | grep -aoE 'ATOS-MT .*|Secure Boot: .*|Verification failed.*|Access Denied.*' | uniq
}
step_b1() {
  ACTION=$(action) VARS=$B1VARS boot "$B1DISK" "$OUT/modtrust-b1.log" fresh >/dev/null
  { summary "$OUT/modtrust-b1.log"; fw_db "$B1VARS"; } | tee "$OUT/modtrust-b1.txt"
}
# The db the firmware holds after the boot, read from its variable store.
fw_db() {
  sudo podman run --rm -v "$WORK:/w:z" "$TOOLS" sh -c "virt-fw-vars -i /w/$(basename "$1") -p -v 2>/dev/null" \
    | sed -n '/^name=db /,/^name=/p' | sed -n 's/^ *subject /ATOS-MT firmware db after boot: /p'
}
step_b2() {
  # Ubuntu's AAVMF_VARS.ms.fd: Microsoft KEK 2011+2023; db: Windows PCA 2011, UEFI CA 2011,
  # UEFI CA 2023, Option ROM UEFI CA 2023, Windows UEFI CA 2023 (spike #76).
  local guid=605dab50-e046-4300-abb6-3dd810dd8b23
  cp /usr/share/AAVMF/AAVMF_VARS.ms.fd "$B2VARS"
  sudo podman run --rm -v "$WORK:/w:z" -v "$REPO:/repo:ro" "$TOOLS" sh -c "
    virt-fw-vars --inplace /w/$(basename "$B2VARS") --add-mok $guid /repo/components/c1-base/secureboot-test/db.crt \
      --add-mok $guid /w/modtrust/keys/mok.crt --set-true MokListTrusted 2>&1 | grep -v '^INFO' || true
    virt-fw-vars -i /w/$(basename "$B2VARS") -p 2>/dev/null | grep -E '^name=(MokList|MokListTrusted|db|KEK) ' -A20 | grep -E '^name=|subject|CN=' | cut -c1-120" \
    | tee "$OUT/modtrust-b2-vars.txt"
  ACTION=$(action) VARS=$B2VARS boot "$B2DISK" "$OUT/modtrust-b2.log" >/dev/null
  { summary "$OUT/modtrust-b2.log"; fw_db "$B2VARS"; } | tee "$OUT/modtrust-b2.txt"
}

[ $# -gt 0 ] || set -- tools keys modules install b1 b2
for s in "$@"; do "step_$s"; done
