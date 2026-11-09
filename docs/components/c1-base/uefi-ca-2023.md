# Spike: what adds Microsoft UEFI CA 2023 to an enrolled B1 db

Card: #165 · Run: 2026-11-08 in the `atos-c165` dev VM (aarch64), image built from `main` on fedora-bootc 45.20261108.0; every result below comes from one clean run of the committed script · Script: [`spikes/c1-uefi-ca-2023/run.sh`](../../../spikes/c1-uefi-ca-2023/run.sh) · Logs: `tools/dev-vm/out/sealed/ca2023-*`

This spike decides nothing and changes neither D-014 nor the installer's db. Card #158 saw a fifth certificate, **Microsoft UEFI CA 2023**, in db after systemd-boot had enrolled a B1 db of four (TEST db cert, a test CA, Microsoft Corporation UEFI CA 2011, Microsoft Option ROM UEFI CA 2023). Nobody chose that trust anchor, and since #158 every db cert is also a kernel-module trust anchor. This card finds what adds it.

**Keys.** Only TEST keys: the committed TEST db cert (`components/c1-base/secureboot-test/db.crt`) plus a VM-only PK and KEK that `run.sh` generates in `~/sealed/ca2023/keys` and never commits (stand-ins for D-014's per-machine keys; the committed TEST set has no KEK private key). The Microsoft certificates are the public ones that ship with `python3-virt-firmware` (`/usr/share/virt-sb-certs/microsoft.com/`). No release key was used.

## Result in one paragraph

**The VM's firmware adds it, not systemd-boot and not Atos.** The dev VM boots Ubuntu 24.04's `qemu-efi-aarch64` **2024.02-2ubuntu0.10** (`AAVMF_CODE.secboot.fd`). Since that version, Ubuntu's edk2 carries a patch that adds a DXE driver, **FirmwareSecvarUpdater** ([LP #2146560](https://bugs.launchpad.net/ubuntu/+source/edk2/+bug/2146560), patch [`OvmfPkg-FirmwareSecvarUpdater-append-Microsoft-2023-CAs-t.patch`](https://git.launchpad.net/ubuntu/+source/edk2/tree/debian/patches/OvmfPkg-FirmwareSecvarUpdater-append-Microsoft-2023-CAs-t.patch?h=ubuntu/noble-updates)). On the first boot in user mode it enters Custom Mode, which skips the PK/KEK signature check, and appends whichever of **Microsoft UEFI CA 2023 and Option ROM UEFI CA 2023 are missing from db wherever Microsoft Corporation UEFI CA 2011 is in db** (in B1's db the Option ROM CA is already there, so only UEFI CA 2023 is added), **Windows UEFI CA 2023 wherever Windows Production PCA 2011 is**, and **Microsoft KEK 2K CA 2023 to KEK wherever Microsoft KEK CA 2011 is**. Then it records `FirmwareSecvarUpdaterVersion = 1` so that it does not run again until Ubuntu raises that number. The script shows exactly that: with systemd-boot enrolling in setup mode, and also with no systemd-boot and no OS at all, Ubuntu's firmware adds UEFI CA 2023 when the 2011 CA is in db and nothing when it is not. Fedora 45's x86_64 OVMF (`edk2-ovmf-20260812-10.fc45`) adds nothing in the same cases, and its firmware volume contains no Microsoft certificate. The driver is not in upstream edk2 (master). **D-014's "UEFI CA 2023 optional" holds for Atos itself:** nothing Atos ships adds the certificate. What does not hold is the wider claim that, without a Microsoft KEK, nobody outside Atos can change a B1 machine's db: platform firmware can always write db without a key, and in this case a firmware package update does. Real (non-VM) firmware was not tested; agents have no access to the NUC (section 4).

## 1. What was run

`tools/dev-vm/vm run spikes/c1-uefi-ca-2023/run.sh` runs these steps in order, after `tools/dev-vm/sealed.sh build`. QEMU runs inside a tools container `FROM` the image's base, without KVM.

| Step | Does | Result |
| --- | --- | --- |
| `tools` | Tools container: virt-firmware, sbsigntools, Fedora's edk2 firmware for aarch64 and x86_64, QEMU for both | `edk2-aarch64-20260812-10.fc45`, `edk2-ovmf-20260812-10.fc45`, `python3-virt-firmware-26.10-2.fc45`, QEMU 11.1.3. The VM's own firmware: `qemu-efi-aarch64 2024.02-2ubuntu0.10` |
| `keys` | VM-only PK and KEK; three db variants as ESLs and `.auth` files (below) | `with2011` 3998 bytes, `no2011` 2398 bytes, `pca2011` 2438 bytes |
| `sdboot` | The card's reproduction. Ubuntu AAVMF with fresh (setup-mode) variables, and an ESP holding only the image's signed systemd-boot (262.1-1.fc45) and `loader/keys/auto/{PK,KEK,db}.auth`. systemd-boot enrols and resets; QEMU stops when systemd-boot shows its menu after the reset. No kernel runs | Section 2 |
| `fwonly` | No systemd-boot and no OS: the same PK, KEK and db written into the variable store offline with `virt-fw-vars` (user mode, Secure Boot on), then the firmware boots an ESP that holds only an unsigned EFI binary. The firmware must refuse it, which shows Secure Boot was enforced in that run | Section 3 |
| `scan` | Which firmware images carry the Microsoft 2023 certificates in their firmware volume (raw or LZMA-compressed). Fetches Ubuntu's edk2 source package for the VM's version from Launchpad, checks it against the sha256 in its `.dsc`, and prints the patch's rules and the lines that implement them. Checks upstream edk2 master for the driver | Section 3 |

db variants (each also holds the TEST db cert, which signs our systemd-boot and UKI):

| Variant | db |
| --- | --- |
| `with2011` | TEST db + Microsoft Corporation UEFI CA 2011 + Microsoft Option ROM UEFI CA 2023: D-014's B1 db on a machine whose TPM event log shows option ROMs (#158's db without its test CA) |
| `no2011` | TEST db + Option ROM UEFI CA 2023: D-014's default B1 db (control) |
| `pca2011` | TEST db + Microsoft Windows Production PCA 2011: D-014's optional Windows CA, the 2011 one |

## 2. Reproduction with systemd-boot (`sdboot`)

All three runs: `Enrolling secure boot keys from directory: \loader\keys\auto`, `Custom Secure Boot keys successfully enrolled, rebooting the system now`, then the firmware banner again and systemd-boot's menu. Before the boot, the variable store had no PK, KEK or db (setup mode). db after the reset:

| Variant | db enrolled by systemd-boot | db after the reset | `FirmwareSecvarUpdaterVersion` |
| --- | --- | --- | --- |
| `with2011` | TEST db, UEFI CA 2011, Option ROM UEFI CA 2023 (3998 bytes) | the same **+ Microsoft UEFI CA 2023** (5490 bytes) | `0x00000001` |
| `no2011` | TEST db, Option ROM UEFI CA 2023 (2398 bytes) | unchanged (2398 bytes) | `0x00000001` |
| `pca2011` | TEST db, Windows Production PCA 2011 (2438 bytes) | the same **+ Windows UEFI CA 2023** (3936 bytes) | `0x00000001` |

PK and KEK stay the VM-only ones; `CustomMode` is `off` again afterwards. This matches #158's observation, minus its test CA.

## 3. Firmware only, and the source (`fwonly`, `scan`)

**Without systemd-boot and without an OS**, Ubuntu's firmware does the same on its first user-mode boot. In every Ubuntu and Fedora x86_64 run the firmware refused the unsigned binary (`Access Denied`), so Secure Boot was enforced.

| Firmware | `with2011` | `no2011` | `pca2011` |
| --- | --- | --- | --- |
| Ubuntu AAVMF 2024.02-2ubuntu0.10 (the VM's) | **+ Microsoft UEFI CA 2023**, version variable written | unchanged, version variable written | **+ Windows UEFI CA 2023**, version variable written |
| Fedora 45 x86_64 OVMF (`OVMF_CODE.secboot.fd`, edk2-ovmf-20260812-10) | unchanged, no version variable | unchanged | unchanged |
| Fedora 45 AAVMF (`QEMU_EFI-pflash.raw`) | unchanged, but **not a valid test**: this build has no Secure Boot (`AuthVariableLibInitialize() returns Unsupported`, `SecurityStubDxe`, and it started the unsigned binary) | not run | not run |

Fedora ships its aarch64 Secure Boot firmware only for QEMU's host-side variable store (`QEMU_EFI-qemuvars-pflash.qcow2` with `uefi-vars`), which this script does not drive. The `scan` step covers it indirectly: no Fedora firmware image contains a Microsoft certificate.

**Firmware volumes.** `AAVMF_CODE.secboot.fd`, `.ms.fd` and `.snakeoil.fd` (Ubuntu) each contain all six Microsoft certificates the driver needs (UEFI CA 2011 and 2023, Option ROM UEFI CA 2023, Windows Production PCA 2011, Windows UEFI CA 2023, KEK 2K CA 2023) in their LZMA-compressed volume; Ubuntu's `AAVMF_CODE.fd` and `.no-secboot.fd` contain none. No Fedora image (`QEMU_EFI-pflash.raw`, `OVMF_CODE.fd`, `OVMF_CODE.secboot.fd`, `OVMF_CODE.cc.fd`) contains any. That is why #158 found no such strings: they are inside the compressed volume, not in systemd-boot.

**Source.** Ubuntu's edk2 `2024.02-2ubuntu0.10` (sha256 checked against the `.dsc`), `debian/patches/series` line 34, changelog *"Add FirmwareSecvarUpdater for adding Microsoft 2023 CAs to existing VMs (LP: #2146560)"*. The patch (Mate Kukri, Canonical, 26 March 2026) adds `OvmfPkg/FirmwareSecvarUpdater/` to every Secure Boot build, including `ArmVirtQemuFvMain.fdf.inc` (AAVMF) and `OvmfPkgX64.fdf` (OVMF). Its logic, as the script prints it from the patch:

- It does nothing in setup mode (`SetupMode != 0`). So in the B1 flow it runs on the first boot **after** systemd-boot's enrolment and reset.
- It matches certificates byte for byte (`CompareMem (SigData->SignatureData, CertDer, CertSize)`). For each rule whose old certificate is present and one of whose new certificates is missing, it sets `CustomMode` (`SetCustomMode (CUSTOM_SECURE_BOOT_MODE)`) and appends the missing ones with `EFI_VARIABLE_APPEND_WRITE` and an empty signature, which Custom Mode accepts.
- It records `SECVAR_UPDATER_VERSION 1` in `FirmwareSecvarUpdaterVersion` and skips later boots until the version is raised.

Upstream edk2 master has no `OvmfPkg/FirmwareSecvarUpdater` (HTTP 404; `OvmfPkg/EnrollDefaultKeys` as control: 200).

## 4. What this means for D-014

- **No Atos component adds the certificate.** systemd-boot enrols exactly the `.auth` files it is given: in the `no2011` run db after the reset is 2398 bytes, the size of the enrolled ESL list from `keys`. The firmware adds the certificate with no systemd-boot present at all (`fwonly`), and no OS ran in either step. D-014's "Microsoft UEFI CA 2023 optional" therefore holds for what Atos ships, and no spec change is needed for it.
- **Platform firmware can change db without any key.** D-014 says *"no outside party can change a machine's trust"*, and `secure-boot-off-and-on.md` says that on D-014 machines *"there is no Microsoft KEK, so Microsoft cannot change db or dbx"*. Both stay true for Microsoft and for signed variable updates. But firmware code runs before any of that and can write db through Custom Mode or directly, as Ubuntu's VM firmware does here. That is not new (the firmware is trusted by definition, and a firmware update is the platform vendor's), but it is a case where it happens automatically, for a certificate D-014 calls optional. The D-014 write-up now says so in one sentence (below); the spec text itself is unchanged.
- **Where it applies today.** Atos B1 installs in a QEMU/libvirt VM that uses Ubuntu's (or a derivative's) Secure Boot OVMF/AAVMF 2024.02-2ubuntu0.10 or later, **with Microsoft Corporation UEFI CA 2011 or Windows Production PCA 2011 in db**. D-014's default B1 db (`no2011`) is not affected. In the affected case db gains UEFI CA 2023 (or Windows UEFI CA 2023); since #158, the kernel also trusts that certificate for module signatures.
- **PCR7 (not tested).** db is part of what PCR7 measures, and Atos binds the TPM disk slot to PCR7. In the install flow the driver runs on the first user-mode boot, before `atos-tpm-seal` seals, so it should not cause a recovery prompt there. An existing affected VM whose host gets this firmware update (or a later one that raises `SECVAR_UPDATER_VERSION`) gets a new db and so, presumably, a new PCR7 and a recovery key prompt. The `fwonly` runs are that situation for db (a user-mode store that never met the driver gains the certificate on its first boot), but the script measures no PCRs.
- **Real firmware: not tested.** This driver is Ubuntu VM firmware only. Whether some OEM firmware updates append 2023 CAs to an active custom db in a similar way is unknown; nothing found here suggests it. Agents have no access to the NUC (`docs/reference-runner.md`). A check the owner could run on any B1 test machine: enrol with UEFI CA 2011 in db, boot, update the firmware if an update exists, then compare `efi-readvar -v db` (or `mokutil --db`) before and after.

## 5. Proposals and follow-ups (for the owner)

1. **D-014 write-up, one sentence (accepted by the owner 2026-11-08, added under the db table):** *"Firmware can still change db without a key (Custom Mode). Ubuntu's Secure Boot OVMF/AAVMF from 2024.02-2ubuntu0.10 appends Microsoft UEFI CA 2023 when UEFI CA 2011 is in db, and Windows UEFI CA 2023 when Windows Production PCA 2011 is (#165)."* No change to the decision.
2. **Installer (#123) and C10, a possible card:** after enrolment the installer could compare db with what it enrolled and tell the user about any extra certificate. That is a requirement only the owner can set; not filed as a card.
3. **Dev VM tests that compare db exactly:** the `atos-c*` dev VMs all run this firmware. Spikes that put UEFI CA 2011 or PCA 2011 in db (#158) will see the extra certificate; they should not treat it as a bug in our code.

## Reproduce

```bash
ATOS_VM=atos-c165 tools/dev-vm/vm run tools/dev-vm/sealed.sh build
ATOS_VM=atos-c165 tools/dev-vm/vm run spikes/c1-uefi-ca-2023/run.sh
```

About 3 minutes after the build under emulation (2 min 36 s in this run). Work files go to `~/sealed/ca2023/` in the VM, never into the repository; logs to `tools/dev-vm/out/sealed/ca2023-*`. `scan` needs network access to launchpad.net and raw.githubusercontent.com.

## Sources

- Ubuntu edk2 2024.02-2ubuntu0.10: <https://launchpad.net/ubuntu/+source/edk2/2024.02-2ubuntu0.10>
- The patch: <https://git.launchpad.net/ubuntu/+source/edk2/tree/debian/patches/OvmfPkg-FirmwareSecvarUpdater-append-Microsoft-2023-CAs-t.patch?h=ubuntu/noble-updates>
- LP #2146560, "edk2: Introduce FirmwareSecvarUpdater": <https://bugs.launchpad.net/ubuntu/+source/edk2/+bug/2146560>
- Card #158: [module-trust.md](module-trust.md), "Side finding" (`spikes/c1-module-trust/run.sh b1`)
- [D-014 write-up](../../decisions/D-014-signing-keys.md), [secure-boot-off-and-on.md](secure-boot-off-and-on.md)
