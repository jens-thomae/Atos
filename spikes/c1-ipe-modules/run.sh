#!/bin/bash
# Card #169: can an IPE policy restrict kernel module loads on the sealed image to files from the
# fs-verity-protected composefs /usr? (docs/components/c1-base/ipe-modules.md). Not part of the
# image build. Runs inside the dev VM, after `tools/dev-vm/sealed.sh build` has made localhost/c1-base:
#   ATOS_VM=atos-c169 tools/dev-vm/vm run spikes/c1-ipe-modules/run.sh [step...]
# Reuses boot() and the paths of tools/dev-vm/sealed.sh. Steps, all in order by default:
#   tools    a container FROM the image's base (same kernel) with kernel-devel for that kernel
#   modules  builds the test modules (CASES) for the image's kernel, all signed with the committed
#            TEST db key, which is in db on B1: the signature check passes for every one of them
#   policy   the IPE policy: one `op=KMODULE fsverity_digest=sha512:<digest> action=ALLOW` rule per
#            module file in the image's /usr (and the three usr test modules), DEFAULT op=KMODULE
#            action=DENY, signed with the TEST db key; plus the policies the guest tries as root
#   image    localhost/c1-base:ipe = the shipped Containerfile plus the usr test modules in
#            /usr/lib/modules/<kver>/extra, the signed policy in /usr/lib/atos/ipe and an initrd
#            unit that loads and activates it (UNIT); then checks that the policy covers every
#            module file of the built image
#   install  installs localhost/c1-base:ipe to ~/sealed/ipe.raw
#   boot     B1 (D-014): setup-mode enrolment of the committed TEST keys, sealed boot, then the guest
#            checks below (action(), ROOT): module loads, then what root can do to the policy
# Keys: the committed TEST db key (in db, so in the kernel's platform keyring) signs the modules and
# the policies; `stranger`, a VM-only self-signed key in no keyring, signs one policy.
# Logs: tools/dev-vm/out/sealed/ipe-*.
set -euo pipefail
SPIKE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null # boot, WORK, OUT, IMAGE come from sealed.sh
source "$SPIKE/../../tools/dev-vm/sealed.sh"
REPO="$SPIKE/../.."
M=$WORK/ipe K=$WORK/ipe/keys CTX=$WORK/ipe/ctx
DISK=$WORK/ipe.raw VARS_IPE=$WORK/ipe-vars.fd
BASE=$(sed -n 's/^ARG BASE=//p' "$REPO/components/c1-base/Containerfile")
DB=$REPO/components/c1-base/secureboot-test
TOOLS=localhost/ipe-tools
KVER=$(sudo podman run --rm "$BASE" ls /usr/lib/modules)
mkdir -p "$M" "$K" "$CTX"
tools() { sudo podman run --rm -v "$M:/m:z" -v "$REPO:/repo:ro" "$TOOLS" "$@"; }

# One module per case, named mt_<case>, all signed with the TEST db key:
#   usr usr2 usr3  shipped in the image's /usr/lib/modules/<kver>/extra, as D-017's NVIDIA modules
#                  would be (Atos-signed, not Fedora-signed)
#   var var2       copied to /var/tmp in the guest
#   etc            copied to /etc in the guest
#   ovl            copied into /usr after `bootc usr-overlay` (#99)
#   initmod        loaded from a buffer with init_module(2), so the kernel sees no file
CASES="usr usr2 usr3 var var2 etc ovl initmod"

step_tools() {
  sudo podman build -t "$TOOLS" -f - "$M" <<EOF
FROM $BASE
RUN dnf -y install --setopt=install_weak_deps=False kernel-devel-$KVER gcc make elfutils-libelf-devel \
    && rpm -q kernel-core kernel-devel
EOF
}

step_modules() {
  local c src=$M/src
  rm -rf "$src" && mkdir -p "$src"
  for c in $CASES; do
    printf '#include <linux/module.h>\nstatic int __init atos_ipe_init(void) { pr_info("atos-ipe: %%s loaded\\n", KBUILD_MODNAME); return 0; }\nstatic void __exit atos_ipe_exit(void) {}\nmodule_init(atos_ipe_init);\nmodule_exit(atos_ipe_exit);\nMODULE_LICENSE("GPL");\nMODULE_DESCRIPTION("Atos IPE module test (dev VM only)");\n' > "$src/mt_$c.c"
  done
  echo "obj-m := $(for c in $CASES; do printf 'mt_%s.o ' "$c"; done)" > "$src/Makefile"
  # shellcheck disable=SC2016 # expands in the container
  tools bash -euc 'kver=$(ls /usr/src/kernels); cd /m/src
    make -s -C /usr/src/kernels/$kver M=/m/src modules
    for m in *.ko; do strip --strip-debug $m; /usr/src/kernels/$kver/scripts/sign-file sha512 /repo/components/c1-base/secureboot-test/db.key /repo/components/c1-base/secureboot-test/db.crt $m; done
    echo "== kernel $kver"; for m in *.ko; do printf "%s %s bytes, signer: %s\n" $m $(stat -c %s $m) "$(modinfo -F signer $m)"; done
    rm -rf /m/ko && mkdir -p /m/ko && cp *.ko /m/ko/' | tee "$OUT/ipe-modules.log"
}

# fs-verity digests as composefs enables them: SHA-512, 4 KiB blocks (sealed.sh, rewrite()).
digests() { # <dir>...: one sha512 digest per module file (.ko, .ko.xz, ...), sorted, unique
  sudo find "$@" -type f -name '*.ko*' -print0 | sudo xargs -0 fsverity digest --hash-alg=sha512 --block-size=4096 \
    | awk '{print $1}' | sort -u
}
policy() { # <module dirs or files>...: the policy text, plus the three usr test modules
  echo 'policy_name=atos_kmodules policy_version=1.0.0'
  echo '# Spike #169: kernel modules only from fs-verity files whose digest is listed here.'
  echo 'DEFAULT action=ALLOW'
  echo 'DEFAULT op=KMODULE action=DENY'
  digests "$@" "$M/ko/mt_usr.ko" "$M/ko/mt_usr2.ko" "$M/ko/mt_usr3.ko" | sed 's/^/op=KMODULE fsverity_digest=/; s/$/ action=ALLOW/'
}
sign() { # <policy text file> <key> <cert> <out.p7b>: PKCS#7 SignedData with the policy inside
  openssl cms -sign -binary -nodetach -noattr -nosmimecap -md sha256 -outform DER \
    -in "$1" -inkey "$2" -signer "$3" -out "$4"
}
step_policy() {
  local mnt
  [ -f "$K/stranger.key" ] || openssl req -quiet -newkey rsa:2048 -nodes -keyout "$K/stranger.key" -x509 -sha256 \
    -days 3650 -subj "/CN=Atos TEST ipe stranger (dev VM) - not for release/" -out "$K/stranger.crt"
  mnt=$(sudo podman image mount "$IMAGE")
  # The full policy: every module file in the image. The kernel's ASN.1 decoder refuses a PKCS#7
  # message over 65535 bytes (lib/asn1_decoder.c), and IPE takes the policy only with its text
  # inside the PKCS#7, so this one cannot be loaded (EMSGSIZE in the second run of this script).
  policy "$mnt/usr/lib/modules" > "$M/kmodules-full.pol"
  sign "$M/kmodules-full.pol" "$DB/db.key" "$DB/db.crt" "$M/kmodules-full.p7b"
  # The policy the image ships: a subset that fits, enough for this VM to boot (virtio, DRM,
  # hw_random, file systems, crypto, lib, block, md) plus the dummy driver the guest loads.
  local d=$mnt/usr/lib/modules/$KVER/kernel
  policy "$d"/{drivers/virtio,drivers/gpu/drm,drivers/char/hw_random,fs,crypto,lib,drivers/block,drivers/md} \
    "$d/drivers/net/dummy.ko.xz" > "$M/kmodules.pol"
  sudo podman image umount "$IMAGE" >/dev/null
  sign "$M/kmodules.pol" "$DB/db.key" "$DB/db.crt" "$CTX/kmodules.p7b"
  [ "$(stat -c %s "$CTX/kmodules.p7b")" -le 65535 ]
  # What root tries in the guest. allow_all_low has a lower version than the active policy.
  printf 'policy_name=atos_kmodules policy_version=0.9.0\nDEFAULT action=ALLOW\n' > "$M/rollback.pol"
  printf 'policy_name=allow_all_low policy_version=0.1.0\nDEFAULT action=ALLOW\n' > "$M/low.pol"
  printf 'policy_name=allow_all policy_version=9.0.0\nDEFAULT action=ALLOW\n' > "$M/high.pol"
  printf 'policy_name=stranger_all policy_version=9.0.0\nDEFAULT action=ALLOW\n' > "$M/stranger.pol"
  rm -rf "$M/guest" && mkdir -p "$M/guest"
  sign "$M/rollback.pol" "$DB/db.key" "$DB/db.crt" "$M/guest/rollback.p7b"
  sign "$M/low.pol" "$DB/db.key" "$DB/db.crt" "$M/guest/low.p7b"
  sign "$M/high.pol" "$DB/db.key" "$DB/db.crt" "$M/guest/high.p7b"
  sign "$M/stranger.pol" "$K/stranger.key" "$K/stranger.crt" "$M/guest/stranger.p7b"
  cp "$M/stranger.pol" "$M/guest/unsigned.pol"
  cp "$M/ko/mt_var.ko" "$M/ko/mt_var2.ko" "$M/ko/mt_etc.ko" "$M/ko/mt_ovl.ko" "$M/ko/mt_initmod.ko" "$M/guest/"
  { echo "== kmodules-full.pol (every module file in the image): $(grep -c '^op=KMODULE' "$M/kmodules-full.pol") rules, $(stat -c %s "$M/kmodules-full.pol") bytes; signed: $(stat -c %s "$M/kmodules-full.p7b") bytes"
    echo "== kmodules.pol (shipped subset): $(grep -c '^op=KMODULE' "$M/kmodules.pol") rules, $(stat -c %s "$M/kmodules.pol") bytes; signed: $(stat -c %s "$CTX/kmodules.p7b") bytes"
    grep -v '^op=KMODULE' "$M/kmodules.pol"; grep -m2 '^op=KMODULE' "$M/kmodules.pol"
    echo "== mt_usr2.ko: $(digests "$M/ko/mt_usr2.ko")"
    for f in "$M"/guest/*.p7b; do echo "== $(basename "$f"): $(openssl cms -verify -noverify -inform DER -in "$f" 2>/dev/null | head -1), signer: $(openssl cms -cmsout -print -inform DER -in "$f" | sed -n 's/^ *issuer: //p' | head -1)"; done
  } | tee "$OUT/ipe-policy.log"
}

# Loads and activates the policy in the initrd, which the signed UKI carries: late (the root file
# system is mounted, so the initrd's own module loads are done), before switch-root, and before
# SELinux has a policy (systemd loads it after switch-root; Fedora's policy gives no service domain
# CAP_MAC_ADMIN, which every write to IPE's securityfs nodes needs: a first run of this script loaded
# the policy from a unit after switch-root and got EPERM, avc denied mac_admin for initrc_t).
# One write: each write(2) is parsed as one policy.
# shellcheck disable=SC2016 # systemd and sh expand it
UNIT='[Unit]
Description=Atos IPE kernel module policy (spike #169, dev VM only)
DefaultDependencies=no
ConditionPathExists=/etc/initrd-release
After=initrd-fs.target
Before=initrd.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c "t0=$$(date +%%s%%N); dd if=/usr/lib/atos/ipe/kmodules.p7b of=/sys/kernel/security/ipe/new_policy bs=16M iflag=fullblock status=none && echo 1 > /sys/kernel/security/ipe/policies/atos_kmodules/active && echo atos-ipe-policy: loaded and active in $$(( ($$(date +%%s%%N) - t0) / 1000 )) us"'
DRACUT='install_items+=" /usr/lib/atos/ipe/kmodules.p7b /usr/lib/systemd/system/atos-ipe-policy.service /usr/lib/systemd/system/initrd.target.wants/atos-ipe-policy.service /usr/bin/dd /usr/bin/date "'
step_image() {
  local f=$WORK/Containerfile.ipe ctx=$REPO/components/c1-base
  cp "$M/ko/mt_usr.ko" "$M/ko/mt_usr2.ko" "$M/ko/mt_usr3.ko" "$CTX/"
  printf '%s\n' "$UNIT" > "$CTX/atos-ipe-policy.service"
  printf '%s\n' "$DRACUT" > "$CTX/90-atos-ipe.conf"
  sed -e "/^LABEL org.opencontainers.image.title/i COPY --from=ipe mt_usr.ko mt_usr2.ko mt_usr3.ko /usr/lib/modules/$KVER/extra/" \
      -e "/^LABEL org.opencontainers.image.title/i COPY --from=ipe kmodules.p7b /usr/lib/atos/ipe/kmodules.p7b" \
      -e "/^LABEL org.opencontainers.image.title/i COPY --from=ipe atos-ipe-policy.service /usr/lib/systemd/system/atos-ipe-policy.service" \
      -e "/^LABEL org.opencontainers.image.title/i COPY --from=ipe 90-atos-ipe.conf /usr/lib/dracut/dracut.conf.d/90-atos-ipe.conf" \
      -e "/^LABEL org.opencontainers.image.title/i RUN depmod $KVER \&\& mkdir -p /usr/lib/systemd/system/initrd.target.wants \&\& ln -s ../atos-ipe-policy.service /usr/lib/systemd/system/initrd.target.wants/" \
      -e "s#^    && lsinitrd \"/usr/lib/modules/\$kver/initramfs.img\" | grep -q 'emergency.service.d/10-atos-boot-counting.conf' \\\\#&\n    \&\& lsinitrd \"/usr/lib/modules/\$kver/initramfs.img\" | grep -E 'atos-ipe|kmodules' \\\\#" \
      "$ctx/Containerfile" > "$f"
  grep -q 'grep -E .atos-ipe' "$f"
  sudo podman build --build-context repo="$REPO" --build-context ipe="$CTX" -f "$f" -t "$IMAGE:ipe" "$ctx" 2>&1 \
    | tee "$OUT/ipe-image-build.log" | grep -E 'atos-ipe|kmodules|Error|error:' || true
  # Every module file the built image ships that the policy does not list cannot load.
  local mnt missing
  mnt=$(sudo podman image mount "$IMAGE:ipe")
  missing=$(comm -23 <(digests "$mnt/usr/lib/modules") <(sed -n 's/^op=KMODULE fsverity_digest=\([^ ]*\) .*/\1/p' "$M/kmodules.pol" | sort -u) | wc -l)
  echo "ATOS-IPE image: $(sudo find "$mnt/usr/lib/modules" -type f -name '*.ko*' | wc -l) module files, $missing not in the policy" \
    | tee "$OUT/ipe-image.log"
  sudo podman image umount "$IMAGE:ipe" >/dev/null
}

step_install() {
  rm -f "$DISK" && truncate -s 20G "$DISK"
  sudo podman run --rm --privileged --pid=host --security-opt label=type:unconfined_t \
    -v /var/lib/containers:/var/lib/containers -v /dev:/dev -v "$WORK:/out" \
    "$IMAGE:ipe" bootc install to-disk --generic-image --via-loopback "/out/$(basename "$DISK")"
}

# Runs as root in unconfined_t, the domain a root login gets. Every result line starts with ATOS-IPE.
# shellcheck disable=SC2016 # expands in the guest
ROOT='k=$(uname -r); S=/sys/kernel/security/ipe; cd /run/ipe
echo "ATOS-IPE root context: $(id -Z), SELinux $(getenforce), policies: $(ls $S/policies | tr "\n" " "), atos_kmodules active=$(cat $S/policies/atos_kmodules/active 2>&1) version=$(cat $S/policies/atos_kmodules/version 2>&1), enforce=$(cat $S/enforce)"
try() { # <case> <command...>: one result line
  local c=$1; shift
  if out=$("$@" 2>&1); then echo "ATOS-IPE load $c: LOADED"; else echo "ATOS-IPE load $c: refused: ${out##*: }"; fi
}
# w writes a file in one write(2), put writes a value.
w() { if out=$(dd if="$1" of="$2" bs=16M iflag=fullblock status=none 2>&1); then echo ACCEPTED; else echo "refused: ${out##*: }"; fi; }
put() { if out=$( (echo "$1" > "$2") 2>&1); then echo ACCEPTED; else echo "refused: ${out##*: }"; fi; }
# 1. Module loads under the policy. An in-tree Fedora module from /usr that is not loaded yet,
# through modprobe (as udev would load it).
for m in dummy veth ifb vcan nlmon; do modinfo -n $m >/dev/null 2>&1 && ! lsmod | grep -q "^$m " && break; done
echo "ATOS-IPE in-tree module: $m = $(modinfo -n $m)"
try usr-intree modprobe $m
t0=$(date +%s%N); try usr insmod /usr/lib/modules/$k/extra/mt_usr.ko; t1=$(date +%s%N)
echo "ATOS-IPE insmod mt_usr under the full policy: $(( (t1 - t0) / 1000000 )) ms"
# Signed copies outside /usr, labelled as module files so SELinux is not what refuses them (#158).
mkdir -p /var/tmp/ipe /etc/atos-ipe && cp mt_var.ko mt_var2.ko /var/tmp/ipe/ && cp mt_etc.ko /etc/atos-ipe/
cp /usr/lib/modules/$k/extra/mt_usr2.ko /var/tmp/ipe/mt_usr2.ko
chcon -t modules_object_t /var/tmp/ipe/*.ko /etc/atos-ipe/*.ko
try var insmod /var/tmp/ipe/mt_var.ko
try etc insmod /etc/atos-ipe/mt_etc.ko
# The same bytes as a module in /usr (its digest is in the policy), without fs-verity, then with it.
try usr2-copy insmod /var/tmp/ipe/mt_usr2.ko
# The image has no fsverity-utils: FS_IOC_ENABLE_VERITY (SHA-512, 4 KiB, as composefs) and
# FS_IOC_MEASURE_VERITY from Python.
V="import fcntl, os, struct, sys
f = os.open(sys.argv[2], os.O_RDONLY)
if sys.argv[1] == \"enable\":
    fcntl.ioctl(f, 0x40806685, struct.pack(\"=IIIIQIIQ88x\", 1, 2, 4096, 0, 0, 0, 0, 0))
b = bytearray(struct.pack(\"=HH\", 0, 64) + bytes(64))
fcntl.ioctl(f, 0xc0046686, b)
alg, n = struct.unpack(\"=HH\", b[:4]); print({1: \"sha256\", 2: \"sha512\"}[alg] + \":\" + b[4:4 + n].hex())"
echo "ATOS-IPE fs-verity of mt_usr2.ko in /usr: $(python3 -c "$V" measure /usr/lib/modules/$k/extra/mt_usr2.ko 2>&1 | tail -n 1 | cut -c1-40)"
echo "ATOS-IPE fs-verity of its /var copy, enabled: $(python3 -c "$V" enable /var/tmp/ipe/mt_usr2.ko 2>&1 | tail -n 1 | cut -c1-40)"
try usr2-copy-verity insmod /var/tmp/ipe/mt_usr2.ko
# init_module(2): the module from a buffer, no file for IPE to look at.
try initmod python3 -c "import ctypes, os, sys; b = open(sys.argv[1], \"rb\").read(); l = ctypes.CDLL(None, use_errno=True); nr = {\"aarch64\": 105, \"x86_64\": 175}[os.uname().machine]
r = l.syscall(nr, b, len(b), b\"\")
sys.exit(0) if r == 0 else sys.exit(os.strerror(ctypes.get_errno()))" mt_initmod.ko
# bootc usr-overlay (#99): a writable overlay on /usr; files written there have no fs-verity.
if out=$(bootc usr-overlay 2>&1); then
  cp mt_ovl.ko /usr/lib/modules/$k/extra/ && chcon -t modules_object_t /usr/lib/modules/$k/extra/mt_ovl.ko
  try ovl insmod /usr/lib/modules/$k/extra/mt_ovl.ko
else echo "ATOS-IPE usr-overlay: failed: $(printf "%s" "$out" | tail -n 1)"; fi
# 2. Root against the policy, SELinux enforcing: every IPE write needs CAP_MAC_ADMIN.
echo "ATOS-IPE root, SELinux enforcing: write 0 to enforce: $(put 0 $S/enforce); delete the policy: $(put 1 $S/policies/atos_kmodules/delete); new allow_all 9.0.0 (TEST db key): $(w high.p7b $S/new_policy)"
# 3. setenforce 0 first (SELinux permissive), then IPE'"'"'s own checks.
echo "ATOS-IPE root: setenforce 0: $(setenforce 0 2>&1 && echo ACCEPTED), SELinux $(getenforce)"
echo "ATOS-IPE root, SELinux permissive: delete the active policy: $(put 1 $S/policies/atos_kmodules/delete)"
echo "ATOS-IPE root, SELinux permissive: update it to version 0.9.0 (TEST db key): $(w rollback.p7b $S/policies/atos_kmodules/update)"
echo "ATOS-IPE root, SELinux permissive: new unsigned policy: $(w unsigned.pol $S/new_policy)"
echo "ATOS-IPE root, SELinux permissive: new policy signed by a key in no keyring: $(w stranger.p7b $S/new_policy)"
echo "ATOS-IPE root, SELinux permissive: new allow_all_low 0.1.0 (TEST db key): $(w low.p7b $S/new_policy), activate it: $(put 1 $S/policies/allow_all_low/active)"
echo "ATOS-IPE root, SELinux permissive: write 0 to enforce: $(put 0 $S/enforce), enforce=$(cat $S/enforce)"
try var-ipe-permissive insmod /var/tmp/ipe/mt_var.ko
echo "ATOS-IPE root: write 1 to enforce: $(put 1 $S/enforce), enforce=$(cat $S/enforce); setenforce 1: $(setenforce 1 2>&1 && echo ACCEPTED), SELinux $(getenforce)"
try var2-enforcing-again insmod /var/tmp/ipe/mt_var2.ko
# 4. secure_mode_policyload on: no setenforce, load_policy or setsebool until the next boot.
echo "ATOS-IPE root: setsebool secure_mode_policyload on: $(setsebool secure_mode_policyload on 2>&1 && echo ACCEPTED), now $(getsebool secure_mode_policyload)"
echo "ATOS-IPE root, secure_mode_policyload: setenforce 0: $(setenforce 0 2>&1 && echo ACCEPTED), SELinux $(getenforce)"
echo "ATOS-IPE root, secure_mode_policyload: write 0 to enforce: $(put 0 $S/enforce)"
# A helper the kernel starts itself (core_pattern pipe): it runs in kernel_t, which has mac_admin.
# It replaces the active policy with allow_all 9.0.0, signed with the TEST db key (in .platform).
printf "#!/bin/sh\n{ id -Z; dd if=/run/ipe/high.p7b of=$S/new_policy bs=16M iflag=fullblock status=none && echo 1 > $S/policies/allow_all/active && echo replaced; } > /run/ipe/helper.out 2>&1\n" > helper.sh
chmod +x helper.sh
old=$(cat /proc/sys/kernel/core_pattern)
echo "ATOS-IPE root, secure_mode_policyload: core_pattern=|/run/ipe/helper.sh: $(put "|/run/ipe/helper.sh" /proc/sys/kernel/core_pattern)"
(ulimit -c unlimited; sh -c "kill -SEGV \$\$") 2>/dev/null
for i in $(seq 30); do [ -s helper.out ] && break; sleep 1; done
echo "$old" > /proc/sys/kernel/core_pattern
echo "ATOS-IPE helper: $(tr "\n" " " < helper.out 2>&1)"
echo "ATOS-IPE policies now: $(ls $S/policies | tr "\n" " "), allow_all active=$(cat $S/policies/allow_all/active 2>&1), atos_kmodules active=$(cat $S/policies/atos_kmodules/active)"
try etc-after-helper insmod /etc/atos-ipe/mt_etc.ko
t0=$(date +%s%N); try usr3 insmod /usr/lib/modules/$k/extra/mt_usr3.ko; t1=$(date +%s%N)
echo "ATOS-IPE insmod mt_usr3 under the allow-all policy: $(( (t1 - t0) / 1000000 )) ms"'

# Guest script, run by sealed.sh's report unit (initrc_t): boot facts, then ROOT as unconfined_t.
# The test files travel inside the script (xz, base64), as the systemd credential carries it.
action() {
  # shellcheck disable=SC2016 # expands in the guest
  printf '%s\n' 'k=$(uname -r)
echo "ATOS-IPE kernel: $k, lockdown: $(cat /sys/kernel/security/lockdown), lsm: $(cat /sys/kernel/security/lsm)"
echo "ATOS-IPE config: $(grep -E "^CONFIG_(SECURITY_IPE|IPE_[A-Z_]+|FS_VERITY[A-Z_]*|DM_VERITY|DM_VERITY_VERIFY_ROOTHASH_SIG|SECURITY_SELINUX_DEVELOP)=" /usr/lib/modules/$k/config | tr "\n" " ")"
journalctl -b --no-pager -o cat -u atos-ipe-policy.service | sed "s/^/ATOS-IPE initrd unit: /"
echo "ATOS-IPE modules loaded at boot: $(lsmod | tail -n +2 | wc -l): $(lsmod | tail -n +2 | cut -d" " -f1 | sort | tr "\n" " ")"
echo "ATOS-IPE refused by IPE before the checks: $(journalctl -b -k --no-pager -o cat | grep -a "ipe_op=KMODULE" | grep -ao "path=[^ ]*" | sort -u | tr "\n" " ")"
echo "ATOS-IPE failed units: $(systemctl --failed --no-legend --plain | cut -d" " -f1 | tr "\n" " ")"
mkdir -p /run/ipe && cd /run/ipe'
  printf 'echo %s | base64 -d | tar -xJ\n' "$(tar -C "$M/guest" -cJ . | base64 -w0)"
  printf 'echo %s | base64 -d > /run/ipe/root.sh\n' "$(printf '%s\n' "$ROOT" | base64 -w0)"
  # shellcheck disable=SC2016 # expands in the guest
  printf '%s\n' 'systemd-run --wait --pipe --quiet -p SELinuxContext=unconfined_u:unconfined_r:unconfined_t:s0 /bin/sh /run/ipe/root.sh
journalctl -b --no-pager -o cat | grep -aE "atos-ipe:|atos-ipe-policy|ipe_op=|lsm=ipe|type=14(04|20|21|22)|avc: .*(mac_admin|setenforce|module_load|setbool|kernel_t)|[Cc]ore dump|helper.sh" | grep -v "sh\[" | sed "s/^/ATOS-IPE log: /" | head -80'
}

# The report runs the action with `sh -x`: its trace lines (`sh[pid]: + ...`) are left out.
summary() {
  tr -d '\r' < "$1" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -avE 'sh\[[0-9]+\]: \+' \
    | grep -aoE 'ATOS-IPE .*|Secure Boot: .*|Startup finished.*|Verification failed.*|Access Denied.*' | uniq
}
step_boot() {
  ACTION=$(action) VARS=$VARS_IPE boot "$DISK" "$OUT/ipe-boot.log" fresh >/dev/null
  summary "$OUT/ipe-boot.log" | tee "$OUT/ipe-boot.txt"
}

[ $# -gt 0 ] || set -- tools modules policy image install boot
for s in "$@"; do "step_$s"; done
