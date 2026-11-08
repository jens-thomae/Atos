#!/bin/bash
# Spike #100: a locally sealed developer image, signed with a developer key enrolled next to the
# TEST db (docs/components/c1-base/dev-image-spike.md). Not part of the image build.
# Runs inside the dev VM: tools/dev-vm/vm run spikes/c1-dev-image/run.sh [step...]
# Reuses boot(), the registry and the paths of tools/dev-vm/sealed.sh. Own disk ~/sealed/devimage.raw.
# VM-only keys in ~/sealed/dev-keys, never committed: PK and KEK stand in for the per-machine keys of
# D-014 (the committed TEST set has no KEK private key, so it cannot append to db); `dev` is the
# developer key. db starts with the committed TEST db cert only. Steps, all in order by default:
#   images    builds the release image (labelled 20261108.0) and, timed, the developer image FROM it
#             (Containerfile here), signed with the developer key
#   install   installs the release image; systemd-boot will enrol the VM's PK/KEK and that db
#   switch    boots release, copies the developer image into the guest's containers-storage and runs
#             `bootc switch --transport containers-storage localhost/atos-dev:current`
#   refused   boots the default entry (the developer UKI): the firmware must refuse it
#   enrol     picks the release entry from the menu and appends the developer cert to db with the
#             KEK, from the running system (no firmware step)
#   boot      boots the default entry: the developer image, with Secure Boot on
#   tpm       ukify, sbsign, systemd-sbsign and systemd-measure with a TPM-resident key (tpm.sh)
# Logs: tools/dev-vm/out/sealed/devimage-*.
set -euo pipefail
SPIKE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null # boot, registry_up, push, WORK, OUT, IMAGE, REG, esp come from sealed.sh
source "$SPIKE/../../tools/dev-vm/sealed.sh"
REPO="$SPIKE/../.."

DDISK=$WORK/devimage.raw DVARS=$WORK/devimage-vars.fd DKEYS=$WORK/dev-keys
RELEASE=$IMAGE:devrel DEVIMG=localhost/atos-dev:current
EFI_DB=/sys/firmware/efi/efivars/db-d719b2cb-3d3a-4596-a3bc-dad00e67656f
TEST_DB_CRT=$REPO/components/c1-base/secureboot-test/db.crt

keys() (
  mkdir -p "$DKEYS" && cd "$DKEYS"
  local k guid=4a3d6e0b-5f2c-4b7e-9a51-7465737400a7
  if [ ! -f KEK.auth ]; then
    for k in PK KEK dev; do
      openssl req -quiet -newkey rsa:2048 -nodes -keyout "$k.key" -new -x509 -sha256 -days 3650 \
        -subj "/CN=Atos TEST $k (dev VM) - not for release/" -out "$k.crt"
      openssl x509 -outform DER -in "$k.crt" -out "$k.der"
    done
    openssl x509 -outform DER -in "$TEST_DB_CRT" -out db.der
    for k in PK KEK db dev; do sbsiglist --owner "$guid" --type x509 --output "$k.esl" "$k.der"; done
    # Setup mode: the firmware does not check these signatures.
    sbvarsign --key PK.key --cert PK.crt --output PK.auth PK PK.esl
    sbvarsign --key PK.key --cert PK.crt --output KEK.auth KEK KEK.esl
    sbvarsign --key KEK.key --cert KEK.crt --output db.auth db db.esl
  fi
  # What turning developer mode on does (D-015): write the developer cert into db with the KEK, from
  # the running system, in user mode. Three candidates, tried in this order by `enrol`; each .var
  # has the 4-byte attributes in front, ready for efivarfs in one write():
  #   sbvarsign-append  sbvarsign (sbsigntools), APPEND_WRITE
  #   efitools-append   sign-efi-sig-list -a (efitools), APPEND_WRITE
  #   efitools-full     sign-efi-sig-list, a full write of db = TEST db cert + developer cert
  sbvarsign --key KEK.key --cert KEK.crt --include-attrs --output sbvarsign-append.var \
    --attr NON_VOLATILE,BOOTSERVICE_ACCESS,RUNTIME_ACCESS,TIME_BASED_AUTHENTICATED_WRITE_ACCESS,APPEND_WRITE db dev.esl
  command -v sign-efi-sig-list >/dev/null || sudo apt-get install -y -q efitools >/dev/null
  sign-efi-sig-list -a -k KEK.key -c KEK.crt db dev.esl efitools-append.auth >/dev/null
  cat db.esl dev.esl > db-dev.esl
  sign-efi-sig-list -k KEK.key -c KEK.crt db db-dev.esl efitools-full.auth >/dev/null
  # NV|BS|RT|TIME_BASED_AUTHENTICATED_WRITE (0x27), plus APPEND_WRITE (0x40) for the append.
  { printf '\x67\x00\x00\x00'; cat efitools-append.auth; } > efitools-append.var
  { printf '\x27\x00\x00\x00'; cat efitools-full.auth; } > efitools-full.var
)
build_dev() { # <tag> [podman build args...]: the developer image FROM $RELEASE
  local tag=$1; shift
  sudo podman build --build-context repo="$REPO" --build-arg RELEASE="$RELEASE" \
    --secret id=devkey,src="$DKEYS/dev.key" --secret id=devcrt,src="$DKEYS/dev.crt" \
    -f "$SPIKE/Containerfile" -t "$tag" "$@" "$SPIKE"
}
dev_images() {
  keys
  # The release image as sealed.sh builds it, plus a version label, so the version floor (#75) is in play.
  sudo podman build --build-context repo="$REPO" --label org.opencontainers.image.version=20261108.0 \
    -t "$RELEASE" "$REPO/components/c1-base"
  local t0 t1 t2
  t0=$(date +%s); build_dev "$DEVIMG" --no-cache
  t1=$(date +%s); build_dev "$DEVIMG-rebuild" --build-arg DEV_MARKER=devimage-rebuild
  t2=$(date +%s)
  { echo "dev VM: $(nproc) vCPU, $(free -g | awk '/Mem:/{print $2}') GiB, $(uname -m), $(date -u +%F)"
    echo "cold build (--no-cache, FROM a local release image): $((t1 - t0)) s"
    echo "rebuild (developer layer changed, kernel stage cached): $((t2 - t1)) s"
    sudo podman image inspect --format '{{.Size}} bytes, version label {{index .Labels "org.opencontainers.image.version"}}' "$DEVIMG"
  } | tee "$OUT/devimage-build-time.txt"
  # The developer UKI must verify with the developer cert, and not with the release db cert.
  local uki=$WORK/dev-uki.efi
  sudo podman run --rm "$DEVIMG" sh -c 'cat /boot/EFI/Linux/*.efi' | cat > "$uki"
  sbverify --cert "$DKEYS/dev.crt" "$uki"
  if sbverify --cert "$TEST_DB_CRT" "$uki" 2>/dev/null; then
    echo "developer UKI verifies with the release db cert" >&2; exit 1; fi
  registry_up
  push "$DEVIMG" "$REG:devimage"
}
# shellcheck disable=SC2154 # esp: from sealed.sh
dev_install() {
  rm -f "$DDISK" && truncate -s 20G "$DDISK"
  sudo podman run --rm --privileged --pid=host --security-opt label=type:unconfined_t \
    -v /var/lib/containers:/var/lib/containers -v /dev:/dev -v "$WORK:/out" \
    "$RELEASE" bootc install to-disk --generic-image --via-loopback "/out/$(basename "$DDISK")"
  # Swap the committed key set systemd-boot enrols for the VM's own (same db cert, own PK and KEK).
  dev=$(sudo losetup -fP --show "$DDISK")
  mkdir -p "$esp" && sudo mount "$(sudo blkid -t TYPE=vfat -o device "$dev"p*)" "$esp"
  sudo ls -l "$esp/loader/keys/auto"
  sudo cp "$DKEYS/PK.auth" "$DKEYS/KEK.auth" "$DKEYS/db.auth" "$esp/loader/keys/auto/"
  sudo umount "$esp" && sudo losetup -d "$dev"
}
# Guest scripts. DB prints the db certs by name.
# shellcheck disable=SC2016 # expands in the guest
DB='for v in PK-8be4df61-93ca-11d2-aa0d-00e098032b8c KEK-8be4df61-93ca-11d2-aa0d-00e098032b8c db-d719b2cb-3d3a-4596-a3bc-dad00e67656f; do
  echo "ATOS-DEV ${v%%-*}: $(grep -ao "Atos TEST [A-Za-z ()-]*" /sys/firmware/efi/efivars/$v | sort -u | tr "\n" ";")"; done'

# shellcheck disable=SC2016 # expands in the guest
SWITCH_ACTION="$DB"'
printf "[[registry]]\nlocation = \"10.0.2.2:5000\"\ninsecure = true\n" > /etc/containers/registries.conf.d/50-atos-dev.conf
until curl -sf http://10.0.2.2:5000/v2/ >/dev/null; do sleep 2; done
# Stand-in for a build in the guest: the image lands in its containers-storage.
skopeo copy -q docker://10.0.2.2:5000/atos/c1-base:devimage containers-storage:localhost/atos-dev:current && echo "ATOS-DEV copied"
if out=$(bootc switch --transport containers-storage localhost/atos-dev:current 2>&1); then echo "ATOS-DEV switch staged"
else echo "ATOS-DEV switch refused: $(printf "%s" "$out" | tail -n 3 | tr "\n" " ")"; fi
bootc status'
dev_switch() { registry_up; VARS=$DVARS NET=1 ACTION=$SWITCH_ACTION boot "$DDISK" "$OUT/devimage-switch.log" fresh; }
dev_refused() { VARS=$DVARS boot "$DDISK" "$OUT/devimage-refused.log"; }
dev_enrol() { # tries each candidate until db holds the developer cert
  keys
  local action c
  action="$DB
echo ATOS-DEV lockdown: \$(cat /sys/kernel/security/lockdown 2>&1), selinux: \$(getenforce)
chattr -i $EFI_DB"
  for c in sbvarsign-append efitools-append efitools-full; do
    action+="
grep -aq 'Atos TEST dev' $EFI_DB || { echo $(base64 -w0 "$DKEYS/$c.var") | base64 -d > /run/$c.var
  dd if=/run/$c.var of=$EFI_DB bs=64k conv=notrunc status=none && echo 'ATOS-DEV $c ok' || echo 'ATOS-DEV $c refused'; }"
  done
  action+="
journalctl -b -k --no-pager | grep -iE 'efivar|avc.*efi' | tail -n 5 | sed 's/^/ATOS-DEV kernel: /'
$DB"
  VARS=$DVARS MENU=1 ACTION=$action boot "$DDISK" "$OUT/devimage-enrol.log"
}
# shellcheck disable=SC2016 # expands in the guest
BOOT_ACTION="$DB"'
command -v strace >/dev/null && echo "ATOS-DEV strace present (developer layer)"
bootc upgrade --check 2>&1 | tail -n 3 | sed "s/^/ATOS-DEV upgrade --check: /"'
# Fallback while the runtime write above is refused (see the spike report): db = TEST db cert +
# developer cert, enrolled by systemd-boot in setup mode (fresh firmware variables). The developer
# entry's boot counter is re-armed (`+3`, as after `bootc switch`), so it is the default entry again.
dev_enrol_setup() {
  keys
  dev=$(sudo losetup -fP --show "$DDISK")
  mkdir -p "$esp" && sudo mount "$(sudo blkid -t TYPE=vfat -o device "$dev"p*)" "$esp"
  sudo cp "$DKEYS/efitools-full.auth" "$esp/loader/keys/auto/db.auth"
  sudo sh -c 'for f in "$1"/loader/entries/*+*.conf; do [ -e "$f" ] && mv -v "$f" "${f%%+*}+3.conf"; done; true' sh "$esp"
  sudo umount "$esp" && sudo losetup -d "$dev"
  VARS=$DVARS ACTION=$BOOT_ACTION boot "$DDISK" "$OUT/devimage-enrol-setup.log" fresh
}
dev_boot() { VARS=$DVARS ACTION=$BOOT_ACTION boot "$DDISK" "$OUT/devimage-boot.log"; }
dev_tpm() {
  sudo podman run --rm -v "$SPIKE:/w:ro" "$(sed -n 's/^ARG BASE=//p' "$REPO/components/c1-base/Containerfile")" \
    bash /w/tpm.sh 2>&1 | grep -v '^swtpm: Warning' | tee "$OUT/devimage-tpm.log"
}

[ $# -gt 0 ] || set -- images install switch refused enrol enrol-setup boot tpm
for s in "$@"; do "dev_${s//-/_}"; done
