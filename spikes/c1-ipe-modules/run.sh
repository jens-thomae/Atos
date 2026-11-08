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
#            /usr/lib/modules/<kver>/extra, the signed policy in /usr/lib/atos/ipe and a unit that
#            loads and activates it early in boot; then checks that the policy covers every module
#            file of the built image
#   install  installs localhost/c1-base:ipe to ~/sealed/ipe.raw
#   boot     B1 (D-014): setup-mode enrolment of the committed TEST keys, sealed boot, then the guest
#            checks below (action())
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
mkdir -p "$M" "$K" "$CTX"
tools() { sudo podman run --rm -v "$M:/m:z" -v "$REPO:/repo:ro" "$TOOLS" "$@"; }

# One module per case, named mt_<case>, all signed with the TEST db key:
#   usr usr2 usr3  shipped in the image's /usr/lib/modules/<kver>/extra, as D-017's NVIDIA modules
#                  would be (Atos-signed, not Fedora-signed)
#   var            copied to /var/tmp in the guest
#   etc            copied to /etc in the guest
#   ovl            copied into /usr after `bootc usr-overlay` (#99)
#   initmod        loaded from a buffer with init_module(2), so the kernel sees no file
CASES="usr usr2 usr3 var etc ovl initmod"

step_tools() {
  local kver
  kver=$(sudo podman run --rm "$BASE" ls /usr/lib/modules)
  sudo podman build -t "$TOOLS" -f - "$M" <<EOF
FROM $BASE
RUN dnf -y install --setopt=install_weak_deps=False kernel-devel-$kver gcc make elfutils-libelf-devel \
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
sign() { # <policy text file> <key> <cert> <out.p7b>: PKCS#7 SignedData with the policy inside
  openssl cms -sign -binary -nodetach -noattr -nosmimecap -md sha256 -outform DER \
    -in "$1" -inkey "$2" -signer "$3" -out "$4"
}
step_policy() {
  local mnt
  [ -f "$K/stranger.key" ] || openssl req -quiet -newkey rsa:2048 -nodes -keyout "$K/stranger.key" -x509 -sha256 \
    -days 3650 -subj "/CN=Atos TEST ipe stranger (dev VM) - not for release/" -out "$K/stranger.crt"
  mnt=$(sudo podman image mount "$IMAGE")
  { echo 'policy_name=atos_kmodules policy_version=1.0.0'
    echo '# Spike #169: kernel modules only from fs-verity files whose digest is listed here.'
    echo 'DEFAULT action=ALLOW'
    echo 'DEFAULT op=KMODULE action=DENY'
    digests "$mnt/usr/lib/modules" "$M/ko/mt_usr.ko" "$M/ko/mt_usr2.ko" "$M/ko/mt_usr3.ko" \
      | sed 's/^/op=KMODULE fsverity_digest=/; s/$/ action=ALLOW/'
  } > "$M/kmodules.pol"
  sudo podman image umount "$IMAGE" >/dev/null
  sign "$M/kmodules.pol" "$DB/db.key" "$DB/db.crt" "$CTX/kmodules.p7b"
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
  cp "$M/ko/mt_var.ko" "$M/ko/mt_etc.ko" "$M/ko/mt_ovl.ko" "$M/ko/mt_initmod.ko" "$M/guest/"
  { echo "== kmodules.pol: $(grep -c '^op=KMODULE' "$M/kmodules.pol") rules, $(stat -c %s "$M/kmodules.pol") bytes; signed: $(stat -c %s "$CTX/kmodules.p7b") bytes"
    grep -v '^op=KMODULE' "$M/kmodules.pol"; grep -m2 '^op=KMODULE' "$M/kmodules.pol"
    echo "== mt_usr2.ko: $(digests "$M/ko/mt_usr2.ko")"
    for f in "$M"/guest/*.p7b; do echo "== $(basename "$f"): $(openssl cms -verify -noverify -inform DER -in "$f" 2>/dev/null | head -1), signer: $(openssl cms -cmsout -print -inform DER -in "$f" | sed -n 's/^ *issuer: //p' | head -1)"; done
  } | tee "$OUT/ipe-policy.log"
}

# Loads and activates the policy as soon as securityfs is mounted, before udev and
# systemd-modules-load load anything from /usr. One write: each write() is parsed as one policy.
UNIT='[Unit]
Description=Atos IPE kernel module policy (spike #169, dev VM only)
DefaultDependencies=no
Before=systemd-modules-load.service systemd-udevd.service systemd-udev-trigger.service sysinit.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c "dd if=/usr/lib/atos/ipe/kmodules.p7b of=/sys/kernel/security/ipe/new_policy bs=16M iflag=fullblock status=none && echo 1 > /sys/kernel/security/ipe/policies/atos_kmodules/active"
[Install]
WantedBy=sysinit.target'
step_image() {
  local kver f=$WORK/Containerfile.ipe ctx=$REPO/components/c1-base
  kver=$(sudo podman run --rm "$BASE" ls /usr/lib/modules)
  cp "$M/ko/mt_usr.ko" "$M/ko/mt_usr2.ko" "$M/ko/mt_usr3.ko" "$CTX/"
  printf '%s\n' "$UNIT" > "$CTX/atos-ipe-policy.service"
  sed -e "/^LABEL org.opencontainers.image.title/i COPY --from=ipe mt_usr.ko mt_usr2.ko mt_usr3.ko /usr/lib/modules/$kver/extra/" \
      -e "/^LABEL org.opencontainers.image.title/i COPY --from=ipe kmodules.p7b /usr/lib/atos/ipe/kmodules.p7b" \
      -e "/^LABEL org.opencontainers.image.title/i COPY --from=ipe atos-ipe-policy.service /usr/lib/systemd/system/atos-ipe-policy.service" \
      -e "/^LABEL org.opencontainers.image.title/i RUN depmod $kver \&\& systemctl enable atos-ipe-policy.service" \
      "$ctx/Containerfile" > "$f"
  grep -q atos-ipe-policy "$f"
  sudo podman build --build-context repo="$REPO" --build-context ipe="$CTX" -f "$f" -t "$IMAGE:ipe" "$ctx"
  # The policy has to list every module file the built image ships, or that module can't load.
  local mnt missing
  mnt=$(sudo podman image mount "$IMAGE:ipe")
  missing=$(comm -23 <(digests "$mnt/usr/lib/modules") <(sed -n 's/^op=KMODULE fsverity_digest=\([^ ]*\) .*/\1/p' "$M/kmodules.pol" | sort -u) | wc -l)
  echo "ATOS-IPE image: $(sudo find "$mnt/usr/lib/modules" -type f -name '*.ko*' | wc -l) module files, $missing not in the policy" \
    | tee "$OUT/ipe-image.log"
  sudo podman image umount "$IMAGE:ipe" >/dev/null
  [ "$missing" = 0 ]
}

step_install() {
  rm -f "$DISK" && truncate -s 20G "$DISK"
  sudo podman run --rm --privileged --pid=host --security-opt label=type:unconfined_t \
    -v /var/lib/containers:/var/lib/containers -v /dev:/dev -v "$WORK:/out" \
    "$IMAGE:ipe" bootc install to-disk --generic-image --via-loopback "/out/$(basename "$DISK")"
}

# Guest script, run as root by sealed.sh's report unit. Every result line starts with ATOS-IPE.
# The test files travel inside the script (xz, base64), as the systemd credential carries it.
action() {
  # shellcheck disable=SC2016 # expands in the guest
  printf '%s\n' 'k=$(uname -r); S=/sys/kernel/security/ipe
echo "ATOS-IPE kernel: $k, lockdown: $(cat /sys/kernel/security/lockdown), lsm: $(cat /sys/kernel/security/lsm)"
echo "ATOS-IPE config: $(grep -E "^CONFIG_(SECURITY_IPE|IPE_[A-Z_]+|FS_VERITY[A-Z_]*|DM_VERITY|DM_VERITY_VERIFY_ROOTHASH_SIG)=" /usr/lib/modules/$k/config | tr "\n" " ")"
echo "ATOS-IPE unit: $(systemctl show -P ActiveState,Result atos-ipe-policy.service | tr "\n" " ")$(systemd-analyze blame --no-pager | grep atos-ipe-policy)"
journalctl -b -u atos-ipe-policy.service --no-pager -o cat | sed "s/^/ATOS-IPE unit log: /"
echo "ATOS-IPE policies: $(ls $S/policies | tr "\n" " "), atos_kmodules active=$(cat $S/policies/atos_kmodules/active 2>&1) version=$(cat $S/policies/atos_kmodules/version 2>&1), enforce=$(cat $S/enforce)"
echo "ATOS-IPE modules from /usr at boot: $(lsmod | tail -n +2 | wc -l) loaded; systemd-modules-load: $(systemctl show -P Result systemd-modules-load.service)"
try() { # <case> <command...>: one result line
  local c=$1; shift
  if out=$("$@" 2>&1); then echo "ATOS-IPE load $c: LOADED"; else echo "ATOS-IPE load $c: refused: ${out##*: }"; fi
}
mkdir -p /run/ipe && cd /run/ipe'
  printf 'echo %s | base64 -d | tar -xJ\n' "$(tar -C "$M/guest" -cJ . | base64 -w0)"
  # shellcheck disable=SC2016 # expands in the guest
  printf '%s\n' '# An in-tree Fedora module from /usr that is not loaded yet, through modprobe (as udev would).
for m in dummy veth ifb vcan nlmon; do modinfo -n $m >/dev/null 2>&1 && ! lsmod | grep -q "^$m " && break; done
echo "ATOS-IPE in-tree module: $m = $(modinfo -n $m)"
try usr-intree modprobe $m
t0=$(date +%s%N); try usr insmod /usr/lib/modules/$k/extra/mt_usr.ko; t1=$(date +%s%N)
echo "ATOS-IPE insmod mt_usr under the full policy: $(( (t1 - t0) / 1000000 )) ms"
# Signed copies outside /usr, labelled as module files so SELinux is not what refuses them (#158).
mkdir -p /var/tmp/ipe /etc/atos-ipe && cp mt_var.ko /var/tmp/ipe/ && cp mt_etc.ko /etc/atos-ipe/
cp /usr/lib/modules/$k/extra/mt_usr2.ko /var/tmp/ipe/mt_usr2.ko
chcon -t modules_object_t /var/tmp/ipe/*.ko /etc/atos-ipe/*.ko
try var insmod /var/tmp/ipe/mt_var.ko
try etc insmod /etc/atos-ipe/mt_etc.ko
# The same bytes as a module in /usr (its digest is in the policy), but without fs-verity, then with it.
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
if command -v python3 >/dev/null; then
  try initmod python3 -c "import ctypes, os, sys; b = open(sys.argv[1], \"rb\").read(); l = ctypes.CDLL(None, use_errno=True); nr = {\"aarch64\": 105, \"x86_64\": 175}[os.uname().machine]
r = l.syscall(nr, b, len(b), b\"\")
sys.exit(0) if r == 0 else sys.exit(os.strerror(ctypes.get_errno()))" mt_initmod.ko
else echo "ATOS-IPE load initmod: skipped (no python3)"; fi
# bootc usr-overlay (#99): a writable overlay on /usr, files there have no fs-verity.
if out=$(bootc usr-overlay 2>&1); then
  cp mt_ovl.ko /usr/lib/modules/$k/extra/ && chcon -t modules_object_t /usr/lib/modules/$k/extra/mt_ovl.ko
  try ovl insmod /usr/lib/modules/$k/extra/mt_ovl.ko
else echo "ATOS-IPE usr-overlay: failed: $(printf "%s" "$out" | tail -n 1)"; fi
# What root can do to the policy (CAP_MAC_ADMIN). w writes a file in one write(2), put a value.
w() { if out=$(dd if="$1" of="$2" bs=16M iflag=fullblock status=none 2>&1); then echo ACCEPTED; else echo "refused: ${out##*: }"; fi; }
put() { if out=$( (echo "$1" > "$2") 2>&1); then echo ACCEPTED; else echo "refused: ${out##*: }"; fi; }
echo "ATOS-IPE root: delete the active policy: $(put 1 $S/policies/atos_kmodules/delete)"
echo "ATOS-IPE root: update it to version 0.9.0 (TEST db key): $(w rollback.p7b $S/policies/atos_kmodules/update)"
echo "ATOS-IPE root: new unsigned policy: $(w unsigned.pol $S/new_policy)"
echo "ATOS-IPE root: new policy signed by a key in no keyring: $(w stranger.p7b $S/new_policy)"
echo "ATOS-IPE root: new allow_all_low 0.1.0 (TEST db key): $(w low.p7b $S/new_policy)"
echo "ATOS-IPE root: activate allow_all_low: $(put 1 $S/policies/allow_all_low/active)"
echo "ATOS-IPE policies now: $(ls $S/policies | tr "\n" " "), atos_kmodules active=$(cat $S/policies/atos_kmodules/active)"
# Permissive mode: one write to the enforce node.
echo "ATOS-IPE root: write 0 to enforce: $(put 0 $S/enforce), enforce=$(cat $S/enforce)"
try var-permissive insmod /var/tmp/ipe/mt_var.ko
echo "ATOS-IPE root: write 1 to enforce: $(put 1 $S/enforce), enforce=$(cat $S/enforce)"
try etc-enforcing-again insmod /etc/atos-ipe/mt_etc.ko
# A higher-version allow-all policy signed by a platform-keyring key replaces the active one.
echo "ATOS-IPE root: new allow_all 9.0.0 (TEST db key): $(w high.p7b $S/new_policy), activate: $(put 1 $S/policies/allow_all/active)"
try etc-allow-all insmod /etc/atos-ipe/mt_etc.ko
t0=$(date +%s%N); try usr3 insmod /usr/lib/modules/$k/extra/mt_usr3.ko; t1=$(date +%s%N)
echo "ATOS-IPE insmod mt_usr3 under the allow-all policy: $(( (t1 - t0) / 1000000 )) ms"
journalctl -b --no-pager -o cat | grep -aE "atos-ipe:|ipe_op=|lsm=ipe|AUDIT_IPE|type=14(04|20|21|22)" | sed "s/^/ATOS-IPE log: /" | head -60'
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
