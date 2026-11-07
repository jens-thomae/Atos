# C11 installer

The installer ISO puts the sealed Atos image (C1) on an empty disk, **encrypted by default**, with no account and no network (D-005). Card #66. Secure Boot key enrolment at install (D-014 B1/B2/C) is card #123; the signed PCR11 policy is card #122.

## What is where

| Path | What |
| --- | --- |
| [`components/c11-installer/Containerfile`](../../../components/c11-installer/Containerfile) | The live installer system: `fedora-bootc` (same pinned base as c1-base), the live-boot dracut module, Fedora's shim and GRUB for the media, and `atos-install`, started on tty1 |
| [`atos-install/`](../../../components/c11-installer/atos-install/) | The installer, a text-mode Rust binary (std only, no dependencies). It drives standard tools: `sfdisk`, `cryptsetup`, `systemd-cryptenroll`, `mkfs`, `podman` and `bootc install to-filesystem` |
| [`firstboot/`](../../../components/c11-installer/firstboot/) | `atos-tpm-seal`, the first-boot unit that binds the disk to Secure Boot (below) |
| [`build-iso.sh`](../../../components/c11-installer/build-iso.sh) | Builds the installer image, then the ISO with image-builder's `generic-iso` type (pinned by digest), with the c1-base image as offline payload |
| [`vm-test.sh`](../../../components/c11-installer/vm-test.sh) | The end-to-end test in the dev VM (below) |
| [`.github/workflows/c11-installer.yml`](../../../.github/workflows/c11-installer.yml) | CI: builds the amd64 ISO and checks its contents |

## Why this approach

- **image-builder `generic-iso`, not bootc-image-builder `anaconda-iso`.** osbuild calls `anaconda-iso` legacy and recommends `generic-iso` for new work. Anaconda also cannot do the D-014 enrolment steps (#123), and it brings Fedora's GUI and branding.
- **Our own text-mode installer.** Owner answer on #66. A graphical installer needs installer screens in the design system; text mode needs no tokens. The binary is small, so #123 and the developer key enrolment (#101) can share code with it.
- **Fedora's shim and GRUB boot the media only.** That is the only way installer media starts with Secure Boot on stock firmware before any Atos key is enrolled. The installed system boots systemd-boot and the sealed UKI exactly as c1-base builds them (#54). Nothing from the media's boot chain is copied to the disk.
- **`bootc install to-filesystem` over our own partitions, not `to-disk --block-setup tpm2-luks`.** The latter binds the TPM at install time, before Secure Boot keys are enrolled, so its PCR7 would be wrong (D-014 §8 item 5). Doing the partitioning ourselves also gives the layout below.
- **The image is unchanged.** The payload is the c1-base image as published, so the installed system is the same signed image that CI checks.

## Disk layout and unlock

GPT with two partitions:

1. ESP, 1 GiB, FAT32: systemd-boot and the sealed UKIs, as `bootc install` writes them.
2. Root, LUKS2, typed as the **discoverable root partition** for the architecture ([UAPI Discoverable Partitions](https://uapi-group.org/specifications/specs/discoverable_partitions_specification/)), holding ext4 with fs-verity (sealed composefs needs fs-verity).

The sealed UKI's kernel command line is fixed and has no `root=`. In the initrd, `systemd-gpt-auto-generator` finds the root partition by its type and unlocks it with `tpm2-device=auto`. Fedora's initrd already has `systemd-cryptsetup`, the TPM2 token plugin and gpt-auto (checked with `lsinitrd` on fedora-bootc 45), so **no change to the c1-base image was needed.**

### Keyslots

| When | Slots |
| --- | --- |
| During the install | A random key in tmpfs (slot 0), used only by the installer and wiped before it exits |
| After the install | **Recovery key** (shown once, the user writes it down) and a **TPM2 slot bound to no PCRs** |
| After first boot | Recovery key and a **TPM2 slot bound to PCR7** (plus PCR14 on shim+MOK machines, D-016) |

**Why the no-PCR TPM2 slot.** Owner answer Q2 on #66: the installer leaves a temporary slot, and a first-boot unit replaces it with the real binding and wipes it. The answer said "empty keyslot". A no-PCR TPM2 slot does the same job and is stronger. gpt-auto unlocks the root with `tpm2-device=auto` and never tries an empty passphrase, so an empty slot would stop at a prompt on first boot. A TPM2 slot unlocks without a prompt, and it is bound to this machine's TPM, so the disk alone does not open. *Flagged for the owner on the PR.*

**Why first boot, not the installer.** Enrolling Secure Boot keys changes PCR7. The final value exists only on the first boot with Secure Boot on (D-014 §8 item 5: seal after enrolment).

### `atos-tpm-seal` (first boot)

A oneshot unit in the deployment's `/etc` (outside the sealed `/usr`, so the image stays unchanged). It:

1. **Fails closed.** It goes on only if `SecureBoot` = 1 and `SetupMode` = 0. Otherwise it keeps the no-PCR slot, writes a warning to the console and `/run/issue.d/`, and tries again on the next boot.
2. Picks PCR7, or PCR7+14 when shim's MOK variables are present (D-016).
3. Runs `systemd-cryptenroll --unlock-tpm2-device=auto --tpm2-device=auto --tpm2-pcrs=7[+14] --wipe-slot=tpm2`. The new slot is never wiped; the install-time TPM2 slot is.
4. Deletes itself.

**PCR7 and updates.** PCR7 records the Secure Boot state and the certificate that verified each boot binary, not the binaries' hashes. A `bootc upgrade` to a new UKI signed by the same key therefore unlocks without a prompt. A UKI signed by any other authority does not (for example a chain signed by a Microsoft CA that #123 may put in db). Nor does a change to db, KEK or PK, or Secure Boot turned off. Then the user types the recovery key.

**What PCR7 alone does not stop.** Any UKI signed by the same key unlocks the disk. That includes older signed UKIs and, in the dev VM, anything signed with the public TEST key. Phase binding (unlock only in the initrd) is also missing. Both come with the signed PCR11 policy (#122): once the UKI carries `.pcrsig`, `atos-tpm-seal` adds `--tpm2-public-key` with `--tpm2-public-key-pcrs=11`.

## Known gaps, accepted for Phase 1

- **Silent unlock plus autologin** (owner answer Q4 on #66). The disk unlocks silently through the TPM (D-015), and the image logs the passwordless `atos` user straight into a session (C1, greetd). **A stolen laptop therefore boots into a session; the encryption protects only a disk taken out of the machine,** or one moved to another machine or booted another way. User accounts and login come with the first-run flow (Phase 3).
- **The window before first boot** (owner answer Q2). Between the end of the install and the first boot, the disk unlocks with this machine's TPM and no PCR check. Anyone with the machine in that window can boot something else and read or change `/etc` and `/var`, which are outside the seal. The window ends with the first boot, which normally follows the install directly.
- **No TPM.** The installer needs a TPM 2.0 (`systemd-cryptenroll --tpm2-device=auto` fails without one). A passphrase path is not part of this card.
- **The installer media trusts Fedora's shim and Microsoft's UEFI CA** while it runs. That does not carry over to the installed system.

## Test in the dev VM

Use your own Lima instance; the boots load the VM for minutes:

```bash
ATOS_VM=atos-c11 tools/dev-vm/vm up
limactl shell atos-c11 -- sudo apt-get install -y linux-generic-hwe-24.04 swtpm swtpm-tools
limactl restart atos-c11
ATOS_VM=atos-c11 tools/dev-vm/vm run components/c11-installer/vm-test.sh all
```

The HWE kernel is needed because `bootc install` mounts EROFS from a file (Linux 6.12 or newer; see the C1 README). QEMU runs aarch64 without KVM, with AAVMF Secure Boot firmware and an `swtpm` TPM 2.0. The unattended run and the report are passed in as systemd credentials over SMBIOS, so the ISO and the image carry no test hook.

RESULTS_PLACEHOLDER
