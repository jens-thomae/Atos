#!/bin/bash
# Boots the built image and checks the shell (#186): installs it with `bootc install to-disk` (as
# tools/dev-vm/sealed.sh `disk`), boots it under QEMU/KVM with OVMF Secure Boot (the TEST keys are
# enrolled from outside, as components/c11-installer/vm-test.sh `enrol` does) and a virtio GPU, and
# lets a one-off systemd unit (a credential: the image carries no test hook) check, as the logged-in
# session: the dock draws its first frame, the launcher opens when the host presses the shortcut
# (Super, sent through the QEMU monitor), a killed shell comes back while atos-comp keeps running, and the
# shell's RSS and the idle desktop's RAM are within §7. QEMU's screendump keeps a picture of the
# dock and of the open launcher; the picture is checked too (the dock's strip is not the plain
# background, the open launcher darkens the screen).
# Usage: shell-boot-test.sh <image in the user's podman storage> <output dir>   (needs sudo, qemu, OVMF, swtpm-less)
# Needs: qemu-system-x86, ovmf, python3-virt-firmware (virt-fw-vars), socat, imagemagick.
set -euo pipefail
IMAGE=$1; OUT=$(mkdir -p "$2" && realpath "$2")
HERE="$(cd "$(dirname "$0")" && pwd)"
W=$(mktemp -d); trap 'sudo rm -rf "$W"' EXIT
F=/usr/share/OVMF

# Root's storage: through a compressed OCI layout, like a registry pull (c11-installer.yml, #180).
podman push -q "$IMAGE" "oci:$W/oci:latest"
ref=localhost/atos-shell-boot:latest
sudo podman tag "$(sudo podman pull -q "oci:$W/oci:latest")" "$ref"
rm -rf "$W/oci"; podman rmi -f "$IMAGE" >/dev/null || true

truncate -s 20G "$W/disk.raw"
# The image's policy refuses local images (#150); the install container alone gets the install-only policy (#176).
sudo podman run --rm --privileged --pid=host --security-opt label=type:unconfined_t \
  -v /var/lib/containers:/var/lib/containers -v /dev:/dev -v "$W:/out" \
  -v "$HERE/../c11-installer/install-policy.json:/etc/containers/policy.json:ro" \
  "$ref" bootc install to-disk --generic-image --via-loopback /out/disk.raw
sudo chown "$USER" "$W/disk.raw"
sudo podman rmi -f "$ref" >/dev/null

# TEST keys into the firmware variables (x86_64 OVMF refuses systemd-boot's own PK write).
cp $F/OVMF_VARS_4M.fd "$W/vars.fd"
python3 -I - "$HERE/secureboot-test" "$W" <<'PY'
import ssl, struct, sys
src, out = sys.argv[1:]
for k in ("PK", "KEK", "db"):
    b = open(f"{src}/{k}.auth", "rb").read()
    esl = 16 + struct.unpack_from("<I", b, 16)[0]
    hsize, ssize = struct.unpack_from("<II", b, esl + 20)
    open(f"{out}/{k}.pem", "w").write(ssl.DER_cert_to_PEM_cert(b[esl + 28 + hsize + 16 : esl + 28 + hsize + ssize]))
PY
G=4a3d6e0b-5f2c-4b7e-9a51-7465737400a7  # owner GUID, secureboot-test/generate.sh
virt-fw-vars --input "$W/vars.fd" --output "$W/vars.new" --set-pk "$G" "$W/PK.pem" \
  --add-kek "$G" "$W/KEK.pem" --add-db "$G" "$W/db.pem" --secure-boot
mv "$W/vars.new" "$W/vars.fd"

# Runs in the guest once the session is up. Markers on the serial port tell the host when to take
# a screenshot; the sleeps after them give it time.
# shellcheck disable=SC2016 # expands in the guest
CHECK='
uid=$(id -u atos); rt=/run/user/$uid
log() { journalctl -b -t atos-shell -o cat --no-pager; }
wait_for() { for _ in $(seq 240); do eval "$1" && return 0; sleep 0.5; done; return 1; }   # 2 min
wait_for "[ \$(log | grep -c BUDGET_FIRST_FRAME) -ge 1 ]" || { echo ATOS-CHECK-FAIL no dock frame; log | tail -20; systemctl poweroff --no-block; exit 0; }
# Login to desktop: from the compositor process start to the shell'"'"'s first frame (VM, KVM: indicative, §7 is reference hardware).
comp=$(pgrep -u atos -x atos-comp | head -1)
t0=$(awk "{ printf \"%.2f\", \$22 / 100 }" /proc/$comp/stat)
t1=$(journalctl -b -t atos-shell -o short-monotonic --no-pager | grep -m1 BUDGET_FIRST_FRAME | sed "s/^\[ *\([0-9.]*\)\].*/\1/")
echo "ATOS-DOCK-UP uptime=$(cut -d. -f1 /proc/uptime)s"
echo "ATOS-LOGIN-TO-DESKTOP-S $(awk "BEGIN { printf \"%.1f\", $t1 - $t0 }")"
# Idle: startup finished, then 60 s more, so first-boot work is over (§7 "after login").
systemctl is-system-running --wait >/dev/null 2>&1
sleep 60
# Idle numbers, §7: the shell is 300 MB of the 800 MB idle desktop (D-006). Breakdown for the owner.
echo "ATOS-SHELL-RSS-KB $(ps -u atos -o rss=,comm= | awk "\$2 == \"atos-shell\" { print \$1 }")"
echo "ATOS-USED-MB $(awk "/MemTotal/ { t = \$2 } /MemAvailable/ { a = \$2 } END { print int((t - a) / 1024) }" /proc/meminfo)"
echo "ATOS-MEM $(grep -E "^(MemTotal|MemFree|MemAvailable|Buffers|Cached|Shmem|Slab|SUnreclaim|AnonPages|KernelStack|PageTables):" /proc/meminfo | tr -s " " | tr "\n" ";")"
ps -eo rss,comm --sort=-rss | head -15 | sed "s/^/ATOS-PS /"
# The shortcut itself: the host presses Super through the QEMU monitor (atos-comp'"'"'s default binding), which runs
# `atos-shell --launcher` from atos-comp. Nothing here calls the shell.
echo ATOS-PRESS-SUPER
wl=$(basename "$(ls -t $rt/wayland-[0-9] | head -1)")
if wait_for "log | grep -q ^LAUNCHER_OPEN_MS"; then echo ATOS-LAUNCHER-OPEN; else echo ATOS-CHECK-FAIL launcher did not open; fi
sleep 8
runuser -u atos -- env XDG_RUNTIME_DIR=$rt WAYLAND_DISPLAY=$wl atos-shell --launcher   # closes it
sleep 1
# A crashing shell: the session stays, the shell returns.
pkill -KILL -u atos -x atos-shell
if wait_for "[ \$(log | grep -c BUDGET_FIRST_FRAME) -ge 2 ]"; then echo ATOS-SHELL-RESTARTED; else echo ATOS-CHECK-FAIL shell not restarted; fi
pgrep -u atos -x atos-comp >/dev/null && echo ATOS-COMP-STILL-RUNNING
sleep 6
systemctl poweroff --no-block'
# shellcheck disable=SC2016 # systemd expands it
UNIT='[Unit]
Description=Atos shell check (CI only)
ConditionPathExists=!/etc/initrd-release
After=multi-user.target atos-session-check.service
[Service]
Type=exec
ImportCredential=atos.*
# The serial port, not the console: on x86_64 the kernel console is tty0 (the UKI has no console=).
StandardOutput=tty
StandardError=tty
TTYPath=/dev/ttyS0
ExecStart=/bin/sh ${CREDENTIALS_DIRECTORY}/atos.check'
cred() { printf -- '-smbios\0type=11,value=io.systemd.credential.binary:%s=%s\0' "$1" "$(printf '%s' "$2" | base64 -w0)"; }
mapfile -d '' creds < <(
  cred systemd.extra-unit.atos-shell-check.service "$UNIT"
  cred systemd.unit-dropin.multi-user.target~atos-shell-check $'[Unit]\nWants=atos-shell-check.service'
  # The serial getty would hang up the tty the unit writes to.
  cred 'systemd.unit-dropin.serial-getty@ttyS0.service~test' $'[Unit]\nConditionPathExists=/nonexistent'
  cred atos.check "$CHECK")

if [ -w /dev/kvm ]; then acc=(-accel kvm -cpu host) tmo=15m; else acc=(-cpu max) tmo=60m; fi
rm -f "$W/mon.sock"
echo "booting the installed disk"
# shellcheck disable=SC2054 # commas are QEMU option syntax
timeout "$tmo" qemu-system-x86_64 -machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on \
  "${acc[@]}" -smp 4 -m 4G -display none -device virtio-gpu-pci -device virtio-keyboard-pci -nic none \
  -drive if=pflash,format=raw,readonly=on,file=$F/OVMF_CODE_4M.secboot.fd -drive if=pflash,format=raw,file="$W/vars.fd" \
  -drive if=virtio,format=raw,file="$W/disk.raw" \
  -monitor unix:"$W/mon.sock",server=on,wait=off -serial file:"$OUT/boot.log" "${creds[@]}" &
pid=$!
shots=(); halt='Freezing execution|Entering emergency mode|Kernel panic|[Ss]ecurity [Vv]iolation|ATOS-CHECK-FAIL'
mon() { echo "$1" | socat - UNIX-CONNECT:"$W/mon.sock" >/dev/null; }
shot() { mon "screendump $W/$1.ppm"; shots+=("$1"); }
pressed=
while kill -0 "$pid" 2>/dev/null; do
  [ -f "$OUT/boot.log" ] || { sleep 1; continue; }
  l=$(tr -d '\r' <"$OUT/boot.log" | grep -a ATOS- || true)
  [ -n "$pressed" ] || { grep -q ATOS-PRESS-SUPER <<<"$l" && { mon "sendkey meta_l"; pressed=1; }; }
  [[ " ${shots[*]} " == *" dock "* ]] || { grep -q ATOS-DOCK-UP <<<"$l" && { sleep 3; shot dock; }; }
  [[ " ${shots[*]} " == *" launcher "* ]] || { grep -q ATOS-LAUNCHER-OPEN <<<"$l" && { sleep 3; shot launcher; }; }
  grep -aqE "$halt" "$OUT/boot.log" && { kill "$pid"; break; }
  sleep 1
done
wait "$pid" || true
tr -d '\r' <"$OUT/boot.log" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -aE 'ATOS-|Secure Boot|session-check|boot is (good|bad)' || true

for s in dock launcher; do [ -f "$W/$s.ppm" ] && convert "$W/$s.ppm" "$OUT/$s.png"; done
fail() { echo "::error::$*"; exit 1; }
for m in ATOS-DOCK-UP ATOS-LAUNCHER-OPEN ATOS-SHELL-RESTARTED ATOS-COMP-STILL-RUNNING; do
  grep -aq "$m" "$OUT/boot.log" || fail "$m missing from the serial log"
done
grep -aqE 'ATOS-CHECK-FAIL' "$OUT/boot.log" && fail "guest check failed"
rss=$(tr -d '\r' <"$OUT/boot.log" | sed -n 's/^ATOS-SHELL-RSS-KB \([0-9]*\).*/\1/p' | head -1)
used=$(tr -d '\r' <"$OUT/boot.log" | sed -n 's/^ATOS-USED-MB \([0-9]*\).*/\1/p' | head -1)
login=$(tr -d '\r' <"$OUT/boot.log" | sed -n 's/^ATOS-LOGIN-TO-DESKTOP-S \([0-9.]*\).*/\1/p' | head -1)
echo "login to desktop ${login:?} s in the VM (KVM, llvmpipe; indicative, §7's 10 s is reference hardware)"
echo "shell RSS ${rss:?} KB (share 307200), used RAM ${used:?} MB (idle desktop budget 800)"
[ "$rss" -le 307200 ] || fail "shell RSS over its 300 MB share"
[ "$used" -le 800 ] || fail "idle desktop over 800 MB"
# Pixels: the screen is not one colour (dock), and the open launcher changes the picture a lot (scrim).
python3 -I - "$W/dock.ppm" "$W/launcher.ppm" <<'PY'
import sys
def ppm(p):
    d = open(p, "rb").read(); parts = d.split(b"\n", 3)
    assert parts[0] == b"P6"; w, h = map(int, parts[1].split()); return w, h, parts[3]
w, h, a = ppm(sys.argv[1]); _, _, b = ppm(sys.argv[2])
row = lambda px, y: px[y * w * 3:(y + 1) * w * 3]
bg = row(a, 2)[:3]                                   # top-left corner: the desktop background
strip = sum(row(a, y)[i:i + 3] != bg for y in range(int(h * .85), h) for i in range(0, w * 3, 3))
diff = sum(a[i] != b[i] for i in range(0, len(a), 97)) / (len(a) / 97)
print(f"dock strip: {strip} px off the background; launcher changed {diff:.0%} of the samples")
assert strip > 500, "no dock in the bottom strip"
assert diff > .3, "the launcher did not change the screen"
PY
