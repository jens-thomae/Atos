# Turning Secure Boot off and on

User guide for card #107 (D-014, D-015). It describes what the installer and `atos-tpm-seal` do **today** (card #66, [installer docs](../c11-installer/README.md)). Where behaviour is not built yet, the text says so.

Atos does not offer a switch for this. Secure Boot is a firmware setting, and Atos discards the Platform Key after enrolment (D-014), so the OS cannot change it. Turning it off is your choice in the firmware setup (D-015). This is "option C" in [developer-mode.md](developer-mode.md) §2.3. If you want your own builds, developer mode (D-015) keeps Secure Boot on and is the better route.

## What turning it off means

- **Anything boots on the machine:** another OS, a USB stick, a modified Atos image. The sealed image still boots, but nothing authenticates its root digest any more, so anyone who can write to the ESP or the disk can replace the system.
- **The disk is no longer protected against someone who boots something else on this machine.** The disk is encrypted (LUKS2, TPM2 slot, recovery key). The TPM slot is bound to PCR7, which records the Secure Boot state. What happens next depends on where you are:

| Your state | Secure Boot off | Effect on the disk |
| --- | --- | --- |
| **Sealed already** (first boot with Secure Boot on has run; slot bound to PCR7, or PCR7+14 on shim+MOK machines) | Turned off later | PCR7 changes, the TPM refuses to release the key, and the initrd asks for the **recovery key**. Atos stays protected: nobody else can read the disk without it. |
| **Never sealed** (Secure Boot has been off since install, which is every install on real hardware until key enrolment at install, #123, lands) | Stays off | `atos-tpm-seal` fails closed and **never seals**. The install-time TPM2 slot, bound to **no PCRs**, stays. The disk opens without a prompt for **any OS booted on that machine**, including a live USB stick. It is protected only when taken out of the machine. |

- **Warnings are easy to miss.** On a never-sealed machine, the warning goes only to the boot console and `/run/issue.d/`. The image's autologin hides both, and there is no warning in the session yet.
- **Release updates keep working** (`bootc upgrade`, same signature policy), but with Secure Boot off the policy no longer protects the boot chain: anyone with root, or physical access, can change what boots.
- **A TPM is still required.** The installer needs TPM 2.0; there is no passphrase-only path yet.

## Before you turn it off

1. **Write down the recovery key** from the install, or check you still have it. On a sealed machine you will be asked for it on the next boot. If you lost it, turning Secure Boot off locks you out of the disk.
2. Know that your firmware may reset or clear its keys when you toggle some settings ("restore factory keys", "reset to setup mode"). Do not do that: it changes db, KEK and PK, and the Atos keys cannot yet be re-enrolled from the OS (see below).

## Turning it off

1. Reboot into the firmware setup (key varies by vendor, often F2, Del or Esc).
2. Find the Secure Boot setting (often under Boot, Security or Authentication) and set it to **Disabled**. Do not choose "Delete keys" or "Reset to setup mode"; plain Disabled keeps the keys in place.
3. Save and boot Atos.
4. On a sealed machine, enter the recovery key when asked. The disk then opens for this boot only. Nothing is rewritten, and the slot stays bound to PCR7.

## Turning it back on

1. Enable Secure Boot in the firmware setup. Keep the same keys (do not reset them).
2. Boot Atos.

Which case you land in:

- **Sealed before, keys unchanged:** PCR7 returns to the sealed value, so the TPM unlocks the disk with no prompt, as before. Nothing to re-enrol.
- **Sealed before, but db, KEK, PK or the signing authority changed in between** (a firmware reset, a Microsoft dbx or db update, a different signing key): PCR7 is different. The initrd asks for the recovery key, and the disk is not sealed to the new value. `atos-tpm-seal` has already removed itself, so it will **not** rebind automatically. Today, rebinding is manual, as root, and type the recovery key when it asks for a passphrase:

  ```bash
  systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 --wipe-slot=tpm2 \
    /dev/disk/by-designator/root-luks
  ```

  This is the call `atos-tpm-seal` makes, except that it unlocks with the recovery key instead of the old TPM slot (add `+14` on shim+MOK machines, D-016). Only do this with Secure Boot on and out of setup mode, or you seal to a PCR7 that is about to change. If the Atos keys are no longer in db, there is no supported way to restore them yet: key enrolment at install (#123) is not done, and the installer's re-run path does not exist. Reinstalling is the fallback.
- **Never sealed:** if Secure Boot was off since install, and the firmware db now trusts the Atos signing key, the first boot with Secure Boot on (and not in setup mode) lets `atos-tpm-seal` bind the disk to PCR7 and wipe the no-PCR slot, which ends the exposed window. On stock firmware with only Microsoft keys, the Atos-signed boot chain does not start with Secure Boot on until #123 lands, so there is nothing to turn back on to yet.

## Do not "fix" the prompt by removing PCR7

When the recovery key prompt annoys you, it is tempting to bind the TPM slot to no PCRs, or to PCR11 alone. A no-PCR slot is exactly the exposed state above. Binding to PCR11 alone is meaningful only for Atos-signed UKIs (the signed PCR11 policy is card #122, not built) and protects nothing for a self-built UKI. Leave PCR7 in place and type the recovery key, or turn Secure Boot back on.

## Dual-boot and other operating systems

Other OSes boot freely with Secure Boot off, and on a never-sealed machine they can read the Atos disk through the TPM, as above. Dual-boot support is not covered by this guide.

## Not covered here

- Developer mode (D-015) enrols its own key and keeps Secure Boot on: [developer-mode.md](developer-mode.md).
- Machines using shim and MOK (D-016): [shim-mok-spike.md](shim-mok-spike.md). PCR14 is also bound; the same rules apply.
