#!/bin/bash
# First boot after install (#66, owner answer Q2): bind the root's LUKS2 volume to the TPM with
# PCR7 (Secure Boot state and the authority that signed the boot chain), plus PCR14 when booted
# through shim and MOK (D-016), then wipe the install-time slot. The installer bound that slot to
# this machine's TPM with no PCRs, so the disk unlocks without a prompt until this has run.
# Fails closed: unless Secure Boot is on and the firmware is out of setup mode, the volume keeps
# the install-time slot and nothing is sealed to a PCR7 that is about to change.
# Installed into the deployment's /etc by atos-install; removes itself after it succeeds.
set -euo pipefail

EFI=/sys/firmware/efi/efivars
GLOBAL=8be4df61-93ca-11d2-aa0d-00e098032b8c
# A UEFI variable's value starts after 4 bytes of attributes.
efi_byte() { [ -r "$EFI/$1-$GLOBAL" ] && od -An -tu1 -j4 -N1 "$EFI/$1-$GLOBAL" | tr -d ' '; }

warn() {
  echo "atos-tpm-seal: $*" >&2
  # Shown at the console login too, until sealing succeeds.
  printf 'Disk encryption is not yet bound to Secure Boot: %s\n' "$*" > /run/issue.d/50-atos-tpm-seal.issue
  # The interface to the shell (C3, #138): this file exists while the no-PCR slot is kept. /run is
  # empty at every boot, so it is gone once the seal has run (this script then never runs again).
  printf '%s\n' "$*" > /run/atos/disk-unsealed
  exit 0
}
mkdir -p /run/issue.d /run/atos
chmod 755 /run/atos

# greetd autologin hides the console and /run/issue.d; the shell shows /run/atos/disk-unsealed.
[ "$(efi_byte SecureBoot)" = 1 ] || warn "Secure Boot is off. Anyone who can boot this machine, from any OS or USB stick, can read the disk without a password."
[ "$(efi_byte SetupMode)" = 0 ] || warn "the firmware is in setup mode. Anyone who can boot this machine, from any OS or USB stick, can read the disk without a password."

dev=$(readlink -f /dev/disk/by-designator/root-luks)
pcrs=7
# shim exposes its MOK lists here (D-016: B2 machines also bind PCR14).
[ ! -d /sys/firmware/efi/mok-variables ] || pcrs=7+14

# The new slot is never wiped by --wipe-slot; the install-time TPM2 slot is.
systemd-cryptenroll --unlock-tpm2-device=auto --tpm2-device=auto --tpm2-pcrs="$pcrs" \
  --wipe-slot=tpm2 "$dev"
rm -f /run/atos/disk-unsealed /run/issue.d/50-atos-tpm-seal.issue
echo "atos-tpm-seal: $dev bound to the TPM with PCR $pcrs"

rm -f /etc/systemd/system/multi-user.target.wants/atos-tpm-seal.service \
  /etc/systemd/system/atos-tpm-seal.service /etc/atos/atos-tpm-seal.sh
