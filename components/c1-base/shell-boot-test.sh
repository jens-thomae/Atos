#!/bin/bash
# Boots the built image and checks the shell (#186): installs it with `bootc install to-disk` (as
# tools/dev-vm/sealed.sh `disk`), boots it under QEMU/KVM with OVMF Secure Boot (the TEST keys are
# enrolled from outside, as components/c11-installer/vm-test.sh `enrol` does) and a virtio GPU, and
# lets a one-off systemd unit (a credential: the image carries no test hook) check, after the host
# logged in at greetd's prompt on tty1 (#187: no autologin; `atos` gets a test password through
# systemd-sysusers' first-boot credential, typed through the QEMU monitor), as the logged-in session: the dock draws its first frame, the launcher opens when the host presses the shortcut
# (Super, sent through the QEMU monitor), a killed shell comes back while atos-comp keeps running, and the
# shell's RSS and the idle desktop's RAM are within §7, and Wi-Fi and Bluetooth are wired (#231). QEMU's screendump keeps a picture of the
# dock and of the open launcher; the picture is checked too (the dock's strip is not the plain
# background, the open launcher darkens the screen).
# Usage: shell-boot-test.sh <image in the user's podman storage> <output dir>   (needs sudo, qemu, OVMF, swtpm-less)
# Needs: qemu-system-x86, ovmf, python3-virt-firmware (virt-fw-vars), socat, imagemagick.
set -euo pipefail
IMAGE=$1; OUT=$(mkdir -p "$2" && realpath "$2")
HERE="$(cd "$(dirname "$0")" && pwd)"
W=$(mktemp -d); trap 'sudo rm -rf "$W"' EXIT
F=/usr/share/OVMF
# The test user's password on this throwaway disk (#187).
PW='atos shell test 1'

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
# #195 evidence: count page-flip (vblank) events and the scanout flushes sent to QEMU per CRTC, from boot on.
T=/sys/kernel/tracing
{ echo 16384 >$T/buffer_size_kb; for e in drm/drm_vblank_event_queued drm/drm_vblank_event_delivered virtio_gpu/virtio_gpu_cmd_queue; do echo 1 >$T/events/$e/enable; done; } 2>/dev/null || echo "DIAG tracing unavailable"
# diag <tag>: DRM devices, connectors, planes, flip counts and atos-comp'"'"'s threads, on the serial log only (DIAG <tag> lines).
diag() {
  { ls -l /sys/class/drm; for c in /sys/class/drm/card*-*; do echo "$c $(cat $c/status) $(cat $c/enabled) $(head -1 $c/modes)"; done
    for f in /sys/kernel/debug/dri/*/state; do echo "== $f"; grep -E "plane\[|crtc\[|fb=|crtc-pos|active|enable" $f; done
    awk "/drm_vblank_event|virtio_gpu_cmd_queue/ { e = \$5; for (i = 6; i <= NF; i++) if (\$i ~ /^(crtc|type)=/) e = e \" \" \$i; n[e]++ } END { for (k in n) print \"count\", n[k], k }" $T/trace
    c=$(pgrep -u atos -x atos-comp | head -1)
    for t in /proc/$c/task/*; do echo "thread $(cat $t/comm) $(cut -d" " -f3 $t/stat) wchan=$(cat $t/wchan)"; sed "s/^/  /" $t/stack; done
  } 2>&1 | sed "s/^/DIAG $1 /"
}
# No autologin (#187): the host types user and password at the prompt once it is up.
wait_for "pgrep -x agreety >/dev/null" && echo ATOS-LOGIN-READY || { echo ATOS-CHECK-FAIL no login prompt; systemctl poweroff --no-block; exit 0; }
# What the login left behind (#187), for a failed login: no password text, only its status.
login_diag() { passwd -S atos; loginctl list-sessions --no-legend; systemctl show -p ImportCredential systemd-sysusers.service; journalctl -b -o cat --no-pager -u greetd -u systemd-sysusers -t agreety -t greetd | tail -30; }
wait_for "[ \$(log | grep -c BUDGET_FIRST_FRAME) -ge 1 ]" || { log | tail -20; login_diag 2>&1 | sed "s/^/ATOS-DIAG /"; echo ATOS-CHECK-FAIL no dock frame; systemctl poweroff --no-block; exit 0; }
# Login to desktop: from the compositor process start to the shell'"'"'s first frame (VM, KVM: indicative, §7 is reference hardware).
comp=$(pgrep -u atos -x atos-comp | head -1)
t0=$(awk "{ printf \"%.2f\", \$22 / 100 }" /proc/$comp/stat)
t1=$(journalctl -b -t atos-shell -o short-monotonic --no-pager | grep -m1 BUDGET_FIRST_FRAME | sed "s/^\[ *\([0-9.]*\)\].*/\1/")
echo "ATOS-DOCK-UP uptime=$(cut -d. -f1 /proc/uptime)s"
diag dock
echo "ATOS-LOGIN-TO-DESKTOP-S $(awk "BEGIN { printf \"%.1f\", $t1 - $t0 }")"
# Idle: startup finished, then 60 s more, so first-boot work is over (§7 "after login").
systemctl is-system-running --wait >/dev/null 2>&1
sleep 60
# Idle numbers, §7: the shell is 300 MB of the 800 MB idle desktop (D-006). The gate is the PSS sum below; the rest is for reference.
echo "ATOS-SHELL-RSS-KB $(ps -u atos -o rss=,comm= | awk "\$2 == \"atos-shell\" { print \$1 }")"
echo "ATOS-USED-MB $(awk "/MemTotal/ { t = \$2 } /MemAvailable/ { a = \$2 } END { print int((t - a) / 1024) }" /proc/meminfo)"
echo "ATOS-MEM $(grep -E "^(MemTotal|MemFree|MemAvailable|Buffers|Cached|Shmem|Slab|SUnreclaim|AnonPages|KernelStack|PageTables):" /proc/meminfo | tr -s " " | tr "\n" ";")"
ps -eo rss,comm --sort=-rss | head -15 | sed "s/^/ATOS-PS /"
# PSS (shared pages divided among their users) per process, summed, plus unreclaimable slab: what the running
# processes and the kernel hold, without the page cache MemAvailable only half discounts. Breakdown, not a gate.
for d in /proc/[0-9]*; do
  p=$(awk "/^Pss:/ { print \$2 }" $d/smaps_rollup 2>/dev/null); [ -n "$p" ] && echo "$p $(cat $d/comm)"
done | sort -rn | awk "{ t += \$1; n[\$2] += \$1; if (\$2 == \"atos-shell\") sh = \$1 } END { for (k in n) if (n[k] > 20000) print \"ATOS-PSS-PROC\", n[k], k; print \"ATOS-PSS-TOTAL-KB\", t; print \"ATOS-PSS-SHELL-KB\", sh }"
echo "ATOS-SUNRECLAIM-KB $(awk "/^SUnreclaim:/ { print \$2 }" /proc/meminfo)"
# The shortcut itself: the host presses Super through the QEMU monitor (atos-comp'"'"'s default binding), which runs
# `atos-shell --launcher` from atos-comp. Nothing here calls the shell.
# (QEMU sends the key to every keyboard: the default PS/2 one is the only one, a second device would toggle twice.)
diag press
echo ATOS-PRESS-SUPER
wl=$(basename "$(ls -t $rt/wayland-[0-9] | head -1)")
if wait_for "log | grep -q ^LAUNCHER_OPEN_MS"; then echo ATOS-LAUNCHER-OPEN; else echo ATOS-CHECK-FAIL launcher did not open; fi
sleep 25   # the host retries the launcher screendump for up to 20 s of this (#192)
diag launcher
runuser -u atos -- env XDG_RUNTIME_DIR=$rt WAYLAND_DISPLAY=$wl atos-shell --launcher   # closes it
sleep 1
# A crashing shell: the session stays, the shell returns.
pkill -KILL -u atos -x atos-shell
if wait_for "[ \$(log | grep -c BUDGET_FIRST_FRAME) -ge 2 ]"; then echo ATOS-SHELL-RESTARTED; else echo ATOS-CHECK-FAIL shell not restarted; fi
pgrep -u atos -x atos-comp >/dev/null && echo ATOS-COMP-STILL-RUNNING
# Wi-Fi and Bluetooth (#231), after the idle numbers: the VM has no radio, so only the software side. NetworkManager
# loaded its Wi-Fi plugin, bluetoothd runs without an adapter and bluetoothctl talks to it, and none of
# NetworkManager, iwd and bluetoothd listens on a socket.
echo "ATOS-IWD $(systemctl is-active iwd.service)"
journalctl -b -u NetworkManager -o cat --no-pager | grep -q "Loaded device plugin: NMWifiFactory" \
  && echo ATOS-NM-WIFI-PLUGIN || echo ATOS-CHECK-FAIL NetworkManager did not load its Wi-Fi plugin
systemctl start bluetooth.service && timeout 10 bluetoothctl list >/dev/null \
  && echo ATOS-BLUETOOTHCTL-OK || echo ATOS-CHECK-FAIL bluetoothctl cannot talk to bluetoothd
l=$(ss -Hltunp | grep -E "\"(NetworkManager|iwd|bluetoothd)\"" || true)
[ -z "$l" ] && echo ATOS-WIRELESS-NO-LISTENERS || echo "ATOS-CHECK-FAIL listening: $l"
journalctl -b _COMM=atos-comp -o short-monotonic --no-pager | sed "s/^/DIAG comp-log /"
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
  cred atos.check "$CHECK"
  # The locked image user gets this password when systemd-sysusers creates it on first boot (#187).
  # Fedora's systemd-sysusers.service imports only root's password credentials, hence the drop-in.
  cred systemd.unit-dropin.systemd-sysusers.service~test $'[Service]\nImportCredential=passwd.plaintext-password.atos'
  cred passwd.plaintext-password.atos "$PW")

if [ -w /dev/kvm ]; then acc=(-accel kvm -cpu host) tmo=15m; else acc=(-cpu max) tmo=60m; fi
rm -f "$W/mon.sock"
echo "booting the installed disk"
# shellcheck disable=SC2054 # commas are QEMU option syntax
timeout "$tmo" qemu-system-x86_64 -machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on \
  "${acc[@]}" -smp 4 -m 4G -display none -vga none -device virtio-gpu-pci -nic none \
  -drive if=pflash,format=raw,readonly=on,file=$F/OVMF_CODE_4M.secboot.fd -drive if=pflash,format=raw,file="$W/vars.fd" \
  -drive if=virtio,format=raw,file="$W/disk.raw" \
  -monitor unix:"$W/mon.sock",server=on,wait=off -serial file:"$OUT/boot.log" "${creds[@]}" &
pid=$!
# type_keys <text>: types it and Enter through the monitor (US layout; letters, digits, space).
type_keys() {
  local s=$1 c i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in [a-z0-9]) mon "sendkey $c" ;; ' ') mon "sendkey spc" ;; *) echo "type_keys: no key for '$c'" >&2; return 1 ;; esac
    sleep 0.1
  done
  mon "sendkey ret"
}
shots=(); halt='Freezing execution|Entering emergency mode|Kernel panic|[Ss]ecurity [Vv]iolation|ATOS-CHECK-FAIL'
mon() { echo "$1" | socat - UNIX-CONNECT:"$W/mon.sock" >/dev/null; }
# #195: one display head (-vga none). With QEMU's default VGA next to the virtio GPU the kernel numbers the two
# connectors in probe order, so the head under the pointer (where the launcher opens) was not always the one screendump read.
shot() { mon "screendump $W/$1.ppm"; shots+=("$1"); }
# #192: the launcher's frame is not always on QEMU's screen 3 s after the marker (a screendump still showed the dock).
# Retry until the picture differs from the dock's as the final check demands, for 20 s; if it never does the check fails as before.
launcher_shot() {
  sleep 3
  for t in $(seq 20); do
    mon "screendump $W/launcher.ppm"; sleep 1   # the monitor replies before the file is complete
    python3 -I "$HERE/shot-diff.py" "$W/dock.ppm" "$W/launcher.ppm" >/dev/null 2>&1 && { echo "launcher frame on screen after $((t + 3)) s"; shots+=(launcher); return; }
  done
  echo "launcher frame never changed the screen in 23 s"
  # Evidence only, never a pass: does a pointer move make the stale screen flush? (stale screendump vs. compositor not drawing)
  mon "mouse_move 5 5"; sleep 2; mon "screendump $W/nudged.ppm"; sleep 1
  python3 -I "$HERE/shot-diff.py" "$W/dock.ppm" "$W/nudged.ppm" 2>&1 | sed 's/^/after a pointer move: /' || true
  shots+=(launcher)
}
pressed='' typed=''
while kill -0 "$pid" 2>/dev/null; do
  [ -f "$OUT/boot.log" ] || { sleep 1; continue; }
  l=$(tr -d '\r' <"$OUT/boot.log" | grep -a ATOS- || true)
  [ -n "$typed" ] || { grep -q ATOS-LOGIN-READY <<<"$l" && { type_keys atos; sleep 2; type_keys "$PW"; typed=1; sleep 3; shot login; }; }
  [ -n "$pressed" ] || { grep -q ATOS-PRESS-SUPER <<<"$l" && { mon "sendkey meta_l"; pressed=1; }; }
  [[ " ${shots[*]} " == *" dock "* ]] || { grep -q ATOS-DOCK-UP <<<"$l" && { sleep 3; shot dock; }; }
  [[ " ${shots[*]} " == *" launcher "* ]] || { grep -q ATOS-LAUNCHER-OPEN <<<"$l" && launcher_shot; }
  grep -aqE "$halt" "$OUT/boot.log" && { kill "$pid"; break; }
  sleep 1
done
wait "$pid" || true
tr -d '\r' <"$OUT/boot.log" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -aE 'ATOS-|Secure Boot|session-check|boot is (good|bad)' || true

for s in login dock launcher nudged; do [ -f "$W/$s.ppm" ] && convert "$W/$s.ppm" "$OUT/$s.png"; done
fail() { echo "::error::$*"; exit 1; }
for m in ATOS-DOCK-UP ATOS-LAUNCHER-OPEN ATOS-SHELL-RESTARTED ATOS-COMP-STILL-RUNNING \
         ATOS-NM-WIFI-PLUGIN ATOS-BLUETOOTHCTL-OK ATOS-WIRELESS-NO-LISTENERS; do
  grep -aq "$m" "$OUT/boot.log" || fail "$m missing from the serial log"
done
grep -aqE 'ATOS-CHECK-FAIL' "$OUT/boot.log" && fail "guest check failed"
rss=$(tr -d '\r' <"$OUT/boot.log" | sed -n 's/^ATOS-SHELL-RSS-KB \([0-9]*\).*/\1/p' | head -1)
used=$(tr -d '\r' <"$OUT/boot.log" | sed -n 's/^ATOS-USED-MB \([0-9]*\).*/\1/p' | head -1)
login=$(tr -d '\r' <"$OUT/boot.log" | sed -n 's/^ATOS-LOGIN-TO-DESKTOP-S \([0-9.]*\).*/\1/p' | head -1)
echo "login to desktop ${login:?} s in the VM (KVM, llvmpipe; indicative, §7's 10 s is reference hardware)"
pss=$(tr -d '\r' <"$OUT/boot.log" | sed -n 's/^ATOS-PSS-TOTAL-KB \([0-9]*\).*/\1/p' | head -1)
slab=$(tr -d '\r' <"$OUT/boot.log" | sed -n 's/^ATOS-SUNRECLAIM-KB \([0-9]*\).*/\1/p' | head -1)
# Gate (owner decision on #186, docs/budgets.md): PSS of all processes + unreclaimable slab, decimal MB.
idle=$(( (${pss:?} + ${slab:?}) * 1024 / 1000000 ))
echo "idle desktop RAM ${idle} MB (PSS ${pss} kB + SUnreclaim ${slab} kB; budget 800); for reference MemTotal-MemAvailable ${used:?} MB"
echo "shell RSS ${rss:?} KB (share 307200)"
[ "$rss" -le 307200 ] || fail "shell RSS over its 300 MB share"
[ "$idle" -le 800 ] || fail "idle desktop RAM $idle MB over 800 MB"
# Pixels: the screen is not one colour (dock), and the open launcher changes the picture a lot (scrim).
python3 -I "$HERE/shot-diff.py" "$W/dock.ppm" "$W/launcher.ppm"
