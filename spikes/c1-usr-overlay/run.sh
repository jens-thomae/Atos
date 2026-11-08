#!/bin/bash
# Spike #99: `bootc usr-overlay` on our sealed composefs image (docs/components/c1-base/usr-overlay-spike.md).
# Not part of the image build. Runs inside the dev VM: tools/dev-vm/vm run spikes/c1-usr-overlay/run.sh [step...]
# Reuses boot() and the paths of tools/dev-vm/sealed.sh. Own disk ~/sealed/usrov.raw. TEST keys only:
# the shipped image enrols the committed TEST key set; nothing is signed here.
#   image     builds the shipped image (components/c1-base) as localhost/c1-base
#   install   bootc install to-disk of it, into a fresh disk
#   overlay   boots it (Secure Boot, TEST keys, user networking) and, in the guest: baseline, a refused
#             write to /usr, `bootc usr-overlay`, the mount it makes, `dnf install` of a few tools with
#             the RAM each one costs, and markers in /usr, /etc and /var
#   after     boots again, firmware variables kept: what survived the reboot, then `--read-only` and a
#             second `bootc usr-overlay` call
#   transient boots again: `dnf --transient install` without a prior `bootc usr-overlay`
#   gone      boots again: was the --transient change discarded?
# Guest lines start with ATOS-REPORT-USRO. Logs: tools/dev-vm/out/sealed/usrov-*.
set -euo pipefail
SPIKE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null # boot, IMAGE, WORK, OUT, step_build come from sealed.sh
source "$SPIKE/../../tools/dev-vm/sealed.sh"
DISK=$WORK/usrov.raw VARS_FILE=$WORK/usrov-vars.fd
TOOLS="strace tmux gdb gcc"  # small, small, large, largest: what a developer reaches for first

# Runs in the guest as root, under `sh -x`. P prefixes every result line.
# shellcheck disable=SC2016 # expands in the guest
OVERLAY_ACTION='P=ATOS-REPORT-USRO
mem() { awk "/^(MemTotal|MemAvailable|Shmem):/{printf \"%s%s \",\$1,\$2}" /proc/meminfo; }
# Installed size of all packages, kB: what a step adds to /usr (the upper layer lives in tmpfs, in RAM).
rpmkb() { rpm -qa --qf "%{SIZE}\n" | awk "{s+=\$1} END {print int(s/1024)}"; }
tmpfs() { df -k --output=target,size,used -t tmpfs | tr "\n" "|"; }
echo "$P bootc: $(bootc --version | tr "\n" " ")"
echo "$P dnf: $(rpm -q dnf5 dnf 2>&1 | tr "\n" " ") selinux=$(getenforce)"
echo "$P / : $(findmnt -no FSTYPE,OPTIONS / | cut -c1-200)"
echo "$P /usr before: $(findmnt -no TARGET,FSTYPE,OPTIONS /usr || echo "no separate mount")"
echo "$P rpm packages before: $(rpm -qa | wc -l); rpmdb at: $(readlink -f /usr/lib/sysimage/rpm 2>&1)"
if touch /usr/atos-usro-marker 2>/run/e; then echo "$P write to /usr before: ALLOWED"; else echo "$P write to /usr before: refused: $(cat /run/e)"; fi
if out=$(dnf -y -q install strace 2>&1); then echo "$P dnf install before overlay: OK"; else echo "$P dnf install before overlay: FAILED: $(printf "%s" "$out" | tail -n 3 | tr "\n" " ")"; fi
echo "$P mem baseline: $(mem); rpmdb: $(du -sk /usr/share/rpm | cut -f1) kB; installed size $(rpmkb) kB; tmpfs: $(tmpfs)"
echo "$P var cache before: $(du -sk /var/cache 2>/dev/null | cut -f1) kB"
if out=$(bootc usr-overlay 2>&1); then echo "$P usr-overlay: OK: $out"; else echo "$P usr-overlay: FAILED: $out"; fi
echo "$P /usr after: $(findmnt -no TARGET,FSTYPE,OPTIONS /usr | cut -c1-400)"
echo "$P tmpfs mounts after overlay: $(tmpfs)"
echo "$P mem after overlay: $(mem)"
mkdir -p /etc/atos-usro-etc /var/atos-usro-var
if touch /usr/atos-usro-marker 2>/run/e; then echo "$P write to /usr after: ok"; else echo "$P write to /usr after: refused: $(cat /run/e)"; fi
echo "$P bootc status: $(bootc status --json | tr -d " \n" | cut -c1-300)"
for t in '"$TOOLS"'; do
  m0=$(mem); u0=$(rpmkb); t0=$(date +%s)
  if dnf -y -q install --setopt=install_weak_deps=False $t >/run/dnf-$t.log 2>&1; then rc=ok; else rc=FAILED; fi
  t1=$(date +%s); m1=$(mem); u1=$(rpmkb)
  echo "$P dnf install $t: $rc in $((t1 - t0)) s; installed size $u0 -> $u1 kB; mem before: $m0; mem after: $m1"
  [ "$rc" = ok ] || tail -n 5 /run/dnf-$t.log | sed "s/^/$P dnf log: /"
  echo "$P rpm -q $t: $(rpm -q $t 2>&1 | tr "\n" " ")"
done
echo "$P tools run: $(strace -V | head -n 1); $(gcc --version | head -n 1); $(gdb --version | head -n 1); $(tmux -V)"
printf "int main(void){return 42;}" > /run/t.c && gcc -o /run/t /run/t.c && { /run/t; echo "$P gcc compiled and ran a program, exit code $?"; }
echo "$P rpm packages after: $(rpm -qa | wc -l)"
echo "$P var cache after: $(du -sk /var/cache 2>/dev/null | cut -f1) kB"
echo "$P rpmdb: $(du -sk /usr/share/rpm | cut -f1) kB; tmpfs mounts at the end: $(tmpfs)"
echo "$P mem final: $(mem)"
echo "$P dnf history: $(dnf history list 2>&1 | tail -n 4 | tr "\n" "|")"
echo "$P composefs still verified: $(cat /proc/cmdline | grep -o "composefs=[^ ]*" | cut -c1-40)"'

# shellcheck disable=SC2016
AFTER_ACTION='P=ATOS-REPORT-USRO
echo "$P /usr after reboot: $(findmnt -no TARGET,FSTYPE /usr)"
echo "$P /usr marker: $(ls /usr/atos-usro-marker 2>&1 | tail -n 1)"
for t in '"$TOOLS"'; do echo "$P rpm -q $t: $(rpm -q $t 2>&1 | tr "\n" " ")"; done
echo "$P /etc and /var markers: $(ls -d /etc/atos-usro-etc /var/atos-usro-var 2>&1 | tr "\n" " ")"
echo "$P dnf history after reboot: $(dnf history list 2>&1 | tail -n 4 | tr "\n" "|")"
echo "$P dnf thinks strace is installed: $(dnf list --installed strace 2>&1 | tail -n 1)"
echo "$P var cache after reboot: $(du -sk /var/cache 2>/dev/null | cut -f1) kB"
if out=$(bootc usr-overlay --read-only 2>&1); then echo "$P usr-overlay --read-only: OK: $out"; else echo "$P usr-overlay --read-only: FAILED: $out"; fi
echo "$P /usr read-only: $(findmnt -no OPTIONS /usr | cut -c1-300)"
if touch /usr/atos-usro-marker 2>/run/e; then echo "$P write in --read-only overlay: ALLOWED"; else echo "$P write in --read-only overlay: refused: $(cat /run/e)"; fi
if out=$(bootc usr-overlay 2>&1); then echo "$P second usr-overlay: OK: $out"; else echo "$P second usr-overlay: FAILED: $out"; fi
if touch /usr/atos-usro-marker 2>/run/e; then echo "$P write after second call: ok"; else echo "$P write after second call: refused: $(cat /run/e)"; fi
rm -rf /etc/atos-usro-etc /var/atos-usro-var'

# shellcheck disable=SC2016
TRANSIENT_ACTION='P=ATOS-REPORT-USRO
mem() { awk "/^(MemAvailable|Shmem):/{printf \"%s%s \",\$1,\$2}" /proc/meminfo; }
echo "$P /usr before: $(findmnt -no TARGET,FSTYPE /usr || echo "no separate mount"); mem: $(mem)"
if out=$(dnf -y -q --transient install strace 2>&1); then echo "$P dnf --transient install strace: OK"; else echo "$P dnf --transient install strace: FAILED: $(printf "%s" "$out" | tail -n 3 | tr "\n" " ")"; fi
echo "$P /usr after: $(findmnt -no TARGET,FSTYPE,OPTIONS /usr | cut -c1-200); mem: $(mem)"
echo "$P strace: $(strace -V 2>&1 | head -n 1)"'
# shellcheck disable=SC2016
AFTER2_ACTION='P=ATOS-REPORT-USRO
echo "$P after the --transient boot: /usr mount: $(findmnt -no TARGET,FSTYPE /usr); strace: $(rpm -q strace 2>&1)"'

usro_image() { step_build; }
usro_install() {
  rm -f "$DISK" && truncate -s 20G "$DISK"
  sudo podman run --rm --privileged --pid=host --security-opt label=type:unconfined_t \
    -v /var/lib/containers:/var/lib/containers -v /dev:/dev -v "$WORK:/out" \
    "$IMAGE" bootc install to-disk --generic-image --via-loopback "/out/$(basename "$DISK")"
}
usro_overlay() { VARS=$VARS_FILE NET=1 TIMEOUT=120m ACTION=$OVERLAY_ACTION boot "$DISK" "$OUT/usrov-overlay.log" fresh; }
usro_after() { VARS=$VARS_FILE NET=1 ACTION=$AFTER_ACTION boot "$DISK" "$OUT/usrov-after.log"; }
usro_transient() { VARS=$VARS_FILE NET=1 TIMEOUT=120m ACTION=$TRANSIENT_ACTION boot "$DISK" "$OUT/usrov-transient.log"; }
usro_gone() { VARS=$VARS_FILE ACTION=$AFTER2_ACTION boot "$DISK" "$OUT/usrov-gone.log"; }

[ $# -gt 0 ] || set -- image install overlay after transient gone
for s in "$@"; do "usro_$s"; done
