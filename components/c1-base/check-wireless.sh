#!/bin/bash
# Checks Wi-Fi and Bluetooth in a built c1-base image (#231; docs/components/c1-base/README.md, "Wi-Fi and Bluetooth"):
# 1. NetworkManager's Wi-Fi plugin, iwd, bluez and wireless-regdb are installed, wpa_supplicant is not;
# 2. NetworkManager uses iwd and has no connectivity check (D-005); iwd leaves addresses and DNS to NetworkManager;
# 3. bluez pairs only through an agent and never re-pairs silently;
# 4. NetworkManager, iwd and bluetooth are enabled, ead (iwd's Ethernet 802.1X daemon) is not; their state dirs are 0700;
# 5. the regulatory database and Intel, Realtek, MediaTek, Qualcomm and Broadcom Wi-Fi/Bluetooth firmware are present.
# What runs (plugin loaded, no listening sockets) is checked by shell-boot-test.sh in the booted image.
# Rootless podman is enough. Usage: check-wireless.sh <image>
set -euo pipefail
podman run --rm "$1" bash -euo pipefail -c '
fail() { echo "FAIL: $*" >&2; exit 1; }
rpm -q NetworkManager-wifi iwd bluez wireless-regdb iwlwifi-mvm-firmware iwlwifi-mld-firmware iwlbluetooth-firmware \
  iwlwifi-dvm-firmware brcmfmac-firmware realtek-firmware mt7xxx-firmware atheros-firmware >/dev/null || fail "package missing"
! rpm -q wpa_supplicant >/dev/null || fail "wpa_supplicant installed next to iwd"
echo "ok: NetworkManager-wifi, iwd, bluez, wireless-regdb and firmware installed; no wpa_supplicant"

# Effective value of <key> in [<section>] of NetworkManager'"'"'s merged configuration (commented lines are defaults).
nmconf() { NetworkManager --print-config | awk -v s="[$1]" -v k="$2" "/^\[/ { in_s = (\$0 == s) } in_s && index(\$0, k \"=\") == 1 { v = substr(\$0, length(k) + 2) } END { print v }"; }
[ "$(nmconf device wifi.backend)" = iwd ] || fail "NetworkManager wifi.backend is \"$(nmconf device wifi.backend)\", not iwd"
[ "$(nmconf connectivity enabled)" = false ] || fail "NetworkManager connectivity check not turned off"
! grep -rsqiE "^[[:space:]]*EnableNetworkConfiguration[[:space:]]*=[[:space:]]*true" /etc/iwd /usr/lib/iwd || fail "iwd configures the network itself"
echo "ok: NetworkManager uses iwd, connectivity check off, iwd network configuration off (default)"
echo "info: Fedora connectivity URL package: $(rpm -q NetworkManager-config-connectivity-fedora || true) (overridden by 90-atos.conf)"

! grep -qiE "^[[:space:]]*AlwaysPairable[[:space:]]*=[[:space:]]*true" /etc/bluetooth/main.conf || fail "bluez pairs without an agent"
! grep -qiE "^[[:space:]]*JustWorksRepairing[[:space:]]*=[[:space:]]*always" /etc/bluetooth/main.conf || fail "bluez re-pairs Just Works devices"
! grep -qiE "^[[:space:]]*DiscoverableTimeout[[:space:]]*=[[:space:]]*0" /etc/bluetooth/main.conf || fail "bluez stays discoverable forever once switched on"
echo "ok: bluez defaults: no pairing without an agent, no silent re-pairing, discoverable only on request and for a limited time"

for s in NetworkManager iwd bluetooth; do [ "$(systemctl is-enabled "$s.service")" = enabled ] || fail "$s.service not enabled"; done
[ "$(systemctl is-enabled ead.service || true)" = disabled ] || fail "ead.service not disabled"
echo "ok: NetworkManager, iwd and bluetooth enabled; ead disabled"

# Known networks and pairings are secrets: tmpfiles.d creates (and at every boot re-applies) these modes.
for d in iwd ead bluetooth; do
  grep -qxE "d /var/lib/$d 0700 root root - -" /usr/lib/tmpfiles.d/atos-wireless.conf || fail "/var/lib/$d not 0700 in tmpfiles.d"
done
echo "ok: /var/lib/iwd, /var/lib/ead and /var/lib/bluetooth are 0700"

fw=/usr/lib/firmware
for f in regulatory.db regulatory.db.p7s "iwlwifi-*" "intel/ibt-*" "rtw89/rtw8852b_fw*" "rtl_bt/rtl8852bu_fw*" \
         "mediatek/WIFI_RAM_CODE_*" "ath11k/*" "qca/*" "brcm/brcmfmac*"; do
  compgen -G "$fw/$f" >/dev/null || fail "no firmware $fw/$f"
done
echo "ok: regulatory database; Intel, Realtek, MediaTek, Qualcomm and Broadcom Wi-Fi/Bluetooth firmware"
'
