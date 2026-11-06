# Spike: Fedora shim + MOK for our UKI (D-014 fallback B2)

Card: #76 · Run: 2026-11-06 in the `atos-c1` dev VM · Script: [`spikes/c1-shim-mok/run.sh`](../../../spikes/c1-shim-mok/run.sh)

This spike decides nothing. It checks whether D-014's fallback B2 works: firmware with Microsoft keys runs Fedora's Microsoft-signed shim, and shim then trusts our systemd-boot and sealed UKI because the user enrolled our cert as a MOK. Only the committed **TEST** db key and cert were used. The production image build (`components/c1-base/Containerfile`, `c1-base.yml`) is unchanged.

## Result in one paragraph

**B2 works.** On aarch64 (AAVMF with the Microsoft KEK and db, no Atos cert in db), Fedora 45's `shimaa64.efi` started our TEST-signed systemd-boot once the TEST cert was enrolled through MokManager. systemd-boot verified the sealed UKI through shim, and the image booted with `Secure Boot: enabled (user)`. A UKI with one changed byte was refused. Fedora's current **x86_64 shim is dual-signed** (UEFI CA 2011 and UEFI CA 2023). In OVMF it booted with either CA alone in db. The **aarch64 shim is 2023-only**. Recommendation: keep B2 as the fallback, with the limits and follow-ups in [section 6](#6-recommendation).

## 1. What was tested

| Case | Firmware db | Boot chain | Result |
| --- | --- | --- | --- |
| `direct` (baseline) | Microsoft (5 certs, below) | firmware → our systemd-boot | **Refused by firmware**: `failed to load Boot0001 … Access Denied` |
| `nomok` | Microsoft | firmware → shim → our systemd-boot, MokList empty | **Refused by shim**: `Verification failed: (0x1A) Security Violation`. With nobody at the keyboard, the machine resets and shows the error again |
| `enroll` | Microsoft | the same; the user enrols `EFI/atos/atos-test-db.cer` in MokManager, reboots | **Boots** to the sealed image: `Secure Boot: enabled (user)`, systemd-boot 262.1, the sealed `composefs.digest=` command line |
| `tamper` | Microsoft, TEST cert in MokList | the same, one digit of `composefs.digest=` in the UKI changed | **Refused**: shim's verifier prints `Verification failed: Security Policy Violation`; systemd-boot: `Error loading EFI binary \EFI\Linux\bootc\bootc_composefs-….efi` |
| `x64`, db = UEFI CA 2011 only | OVMF x86_64 (TCG), throwaway PK, Microsoft KEKs | firmware → `shimx64.efi` → our x64 systemd-boot (TEST-signed), TEST cert in MokList | **Boots** to systemd-boot's menu |
| `x64`, db = UEFI CA 2023 only | the same | the same | **Boots** to systemd-boot's menu |
| `x64`, db = Windows PCA 2011 only (control) | the same | the same | **Refused by firmware**: `Access Denied -- rejected probably by Secure Boot` |

The aarch64 firmware is Ubuntu's `AAVMF_CODE.secboot.fd` with `AAVMF_VARS.ms.fd` (edk2 2024.02-2ubuntu0.10). Its db holds Microsoft Windows Production PCA 2011, Microsoft Corporation UEFI CA 2011, Microsoft UEFI CA 2023, Microsoft Option ROM UEFI CA 2023 and Windows UEFI CA 2023. The kernel log lists these, and no Atos cert. The KEKs are Microsoft KEK CA 2011 and KEK 2K CA 2023. The x64 cases use Fedora 45's `edk2-ovmf` with varstores built by `virt-fw-vars`. Each db was printed back before the boot. Note: `virt-fw-vars --microsoft-db uefi11` enrols **both** UEFI CAs, so the script builds each db from a single cert instead.

The x64 cases put the TEST cert straight into MokList with `virt-fw-vars --add-mok`. They test the firmware's signature check of the dual-signed shim and shim's MOK check on x86_64, not the MokManager screens, which the aarch64 case covers. The x64 cases do not boot a sealed x64 image: the dev VM has no amd64 image, and an x86 Linux boot under TCG on an M1 takes too long.

## 2. Is Fedora's current shim dual-signed?

Fedora 45's repositories carry **shim 16.1-7** (`shim-x64-16.1-7.x86_64`, `shim-aa64-16.1-7.aarch64`). Both were downloaded with `dnf download`, and `rpm -K` checked them against Fedora's key. Their Authenticode certificate tables, read with [`sigs.py`](../../../spikes/c1-shim-mok/sigs.py) (every `WIN_CERTIFICATE` entry, issuer chain via `openssl pkcs7`):

| Binary | sha256 | Signatures, in table order |
| --- | --- | --- |
| `shimx64.efi` | `351e131d…f1ad3` | 1. Microsoft Corporation UEFI CA 2011 (root: Third Party Marketplace Root) · 2. Microsoft UEFI CA 2023 (root: Microsoft RSA Devices Root CA 2021) |
| `shimaa64.efi` | `24320d31…15c19` | Microsoft UEFI CA 2023 only |
| `mmx64.efi`, `mmaa64.efi`, `fbaa64.efi` (MokManager, fallback) | | Fedora Secure Boot CA 20200709 (`fedoraca`), i.e. shim's built-in vendor cert |

So **x86_64: dual-signed, aarch64: 2023 only**. This matches Fedora's changelog: 16.1-6 (2026-02-06) *"x86_64: add signature from Microsoft UEFI CA 2023 signer"*, and 16.1-7 (2026-03-31) *"Aarch64: rebuild for correct signatures on fb/mm"* ([Fedora packages, shim-x64 F45](https://packages.fedoraproject.org/pkgs/shim/shim-x64/fedora-45.html)). AlmaLinux reports the same split for the shim it shares with RHEL: aarch64 2023-only, x86_64 dual-signed ([AlmaLinux, 2026-07-14](https://almalinux.org/blog/2026-07-14-secure-boot-2023-certificates/)). The two signatures are separate `WIN_CERTIFICATE` entries, not a nested signature.

Caveats:

- **Firmware that reads only the first signature.** A Ubuntu bug on dual-signed shims quotes NSA guidance: *"Most UEFI implementations only read one/the first signature in a binary"* ([Launchpad bug 1895817 via the foundations-bugs list](https://lists.snapcraft.io/archives/foundations-bugs/2020-October/434032.html)). edk2 checks every entry (both x64 cases boot). On real firmware, Fedora's order (2011 first) means a 2011-only machine is fine even if it reads only the first entry, while a 2023-only machine that reads only the first entry would refuse it. Not tested on real hardware.
- **Not every release is dual-signed.** Fedora 44 users found a 16.1-5 shim with only the 2011 signature on their systems ([Fedora discussion](https://discussion.fedoraproject.org/t/updating-the-shim-package-in-fedora-44-16-1-8/194569)). Microsoft can no longer sign with the 2011 CA, which expired in June 2026 (see D-014 §2), so **any future shim build is 2023-only**. 16.1-7 keeps booting 2011-only firmware only as long as we ship that exact build and nobody revokes it (SBAT or dbx).

## 3. Steps that worked

ESP layout on the installed sealed disk (the `disk` step):

```
EFI/BOOT/BOOTAA64.EFI   Fedora shimaa64.efi (removable-media path, started by firmware)
EFI/BOOT/mmaa64.efi     Fedora MokManager, next to shim
EFI/BOOT/grubaa64.efi   our TEST-signed systemd-boot, under shim's default second-stage name
EFI/atos/atos-test-db.cer  TEST db cert in DER, for MokManager
EFI/Linux/bootc/…efi    the sealed UKI, TEST-signed (unchanged from #54)
loader/                 systemd-boot config and bootc's entry; loader/keys/ removed
```

Enrolment at first boot, with no OS running yet (the `enroll` step; [`drive.py`](../../../spikes/c1-shim-mok/drive.py) types the keys over the serial console):

1. shim cannot verify `grubaa64.efi` and shows `Verification failed: (0x1A) Security Violation`. **OK**.
2. On that error, shim starts MokManager (shim's `init_grub()`: on `EFI_SECURITY_VIOLATION`/`EFI_ACCESS_DENIED` it runs `MOK_MANAGER`, then retries the second stage, [shim.c](https://github.com/rhboot/shim/blob/main/shim.c)). *"Press any key to perform MOK management"*, a 10 s countdown. **Any key**.
3. **Enroll key from disk** → volume `EFI-SYSTEM` → `EFI/` → `atos/` → `atos-test-db.cer`.
4. **View key 0** shows serial, issuer, subject (`CN=Atos TEST db - not for release, do not trust`), validity and the SHA-1 fingerprint `6A 32 28 02 … E0 48`. **Continue** → *"Enroll the key(s)?"* **Yes** → **Reboot**.
5. After the reboot, shim starts systemd-boot, which boots the UKI. No further prompt.

Enrolling from disk asks for **no password**. The keystrokes at the console are the only consent (step 4 is the user's one chance to compare the fingerprint). The `mokutil --import` flow, where a running OS queues the key and MokManager asks for a one-time password, was **not tested**: nothing that could run mokutil boots before the key is enrolled, and the sealed image has no `mokutil`. It matters for key rotation (section 5).

Booted system (report unit, `enroll` case): `MokListRT`, `MokListTrustedRT` and `SbatLevelRT` exist. The kernel loads `Atos TEST db …` and Fedora's `fedoraca` from `MokListRT`. It also loads the five Microsoft db certs into the platform keyring and runs in lockdown mode `integrity`.

## 4. What each step trusts

| Step | Verifies | Trusted signers |
| --- | --- | --- |
| Firmware → shim | Authenticode signature on `shimaa64.efi`/`shimx64.efi` against db, dbx | Whoever holds a key in KEK/db: Microsoft and the OEM. On real machines, the Microsoft UEFI CA |
| shim → systemd-boot | Signature against db, MokList, shim's vendor cert; refused if in dbx or MokListX; SBAT entries (`systemd-boot,1`, `systemd-boot.fedora,1`) checked against `SbatLevel` | **Microsoft** (via db), **Fedora** (vendor cert `fedoraca`, built into shim), **Atos** (MOK) |
| systemd-boot → UKI | systemd-boot asks firmware to load the UKI. Shim's verifier (systemd-boot's "Retain SHIM protocols") accepts the MOK-signed UKI, which firmware alone would refuse (`tamper` shows the check is real). SBAT: `systemd-stub,1`, `kernel.fedora,1`, `uki,1` | The same three as above |
| UKI → kernel, initrd, command line | Covered by the UKI's signature (one PE file). The command line carries the composefs digest | – |
| Kernel → `/usr` | composefs digest and fs-verity, as in #54 | – |
| Kernel → modules, kexec | Lockdown `integrity`. Modules need a key in the builtin, secondary or `.machine` keyring. MOK certs go to `.machine` only if they are CA certs (below). In this run, the TEST cert and `fedoraca` landed in `.platform` (kexec only), and `.machine` stayed empty | Modules: Fedora's kernel key, plus any **CA** cert in MOK. kexec: db and MOK certs (`.platform`) |

What this means, compared with B1:

- **The machine trusts more than Atos.** Any boot chain signed by Microsoft's UEFI CA (any distribution's shim) or by Fedora's CA (Fedora's GRUB and kernels) boots on a B2 machine. That is no worse than the same laptop before Atos (Microsoft's UEFI CA was already in db), but it is the opposite of B1's "no outside party can change a machine's trust". The sealed image is still protected, because none of those chains carries our composefs digest. But booting another signed chain and reading the disk is possible unless the disk key is bound to the measured chain. **D-014's TPM binding (PCR7 + signed PCR11, #66) is what protects data under B2.** Per shim's [README.tpm](https://github.com/rhboot/shim/blob/main/README.tpm), the certificate that verified each image is logged to **PCR7**: a MOK match as `MokListRT`, shim's vendor cert as `Shim`, a db match as `db`. So a Fedora- or other-distro chain gives a different PCR7 from the Atos chain. Not measured here (the dev VM has no TPM).
- **A MOK CA cert becomes a kernel-module trust anchor.** The `enrolled` boot shows `MokListTrustedRT` set to 1 (`06 00 00 00 01`: attributes, then the value), so shim asks the kernel to trust MOK certs. Yet `/proc/keys` shows `.machine: empty` and `.platform: 7`, which is the five db certs plus `fedoraca` plus the Atos TEST cert. The reason is Fedora's kernel config, `CONFIG_INTEGRITY_CA_MACHINE_KEYRING=y` and `_MAX=y`. With those, only MOK certs with the CA bit **and** keyCertSign usage, and without digitalSignature, go into `.machine`. All other MOK certs go to `.platform`, which is not trusted for modules ([security/integrity/Kconfig](https://github.com/torvalds/linux/blob/master/security/integrity/Kconfig)). The TEST cert has `CA:TRUE` but no key-usage extension, so it does not qualify. This cuts both ways:
  - The Atos UKI-signing cert must **not** carry keyCertSign without digitalSignature. If it did, it would load into `.machine`, and modules signed with the release key would load on B2 machines.
  - Anyone who enrols a cert that qualifies, at the console or through a root-queued `mokutil --import` (see "Root on the running system" below), gets a trust anchor for **kernel modules**. Root could then load its own signed kernel code and keep it across boots through `/etc` and `/var`, which are outside the composefs seal. B1 does not have this: db certs go only to `.platform`.
  - The mitigation to evaluate: `mokutil --untrust-mok`, which clears `MokListTrusted` (after a MokManager confirmation). The kernel then puts no MOK cert into `.machine`. Not tested.
- **Physical presence enrols any key.** Anyone at the keyboard when a refused image boots can enrol their own cert from a USB stick, without a password. Per README.tpm, `MokList` itself is extended into **PCR14**, not PCR7. PCR7 records only the cert that matched. So after an extra key is enrolled, the **genuine Atos chain still produces the same PCR7**, and only PCR14 changes. A disk key bound to PCR7 alone is still released. It is withheld only once the attacker's own image boots (PCR7 then records the attacker's cert) or if the binding includes PCR14. Not measured here.
- **Root on the running system can queue a key change.** `MokList` has the attributes boot-services and non-volatile but not runtime ([MokVars.txt](https://github.com/rhboot/shim/blob/main/MokVars.txt)), so a root process cannot write it. That is what makes the MOK model hold at all. Root *can* write the request variables `MokNew`/`MokAuth` (`mokutil --import`) or `MokSB` (`mokutil --disable-validation`) with a password it chooses. One confirmation at MokManager on the next boot, from a user persuaded to type that password, completes it. `--disable-validation` sets `MokSBState`, and shim then stops verifying what it starts, while firmware still reports Secure Boot as on. Per README.tpm, `MokSBState` is extended into **PCR7 and PCR14** when set, so a PCR7-bound disk key is not released afterwards. That is not measured here, and it does not stop the machine from booting unverified code.
- **Fedora's shim is now in our boot chain.** It is updated and revoked on Fedora's and Microsoft's schedule. A shim SBAT or dbx revocation stops B2 machines from booting until we ship a newer shim. A newer shim is 2023-only on both architectures.

## 5. Open points for a real implementation (not done here)

- **The image would have to ship shim again.** The sealed image removes `shim-*` (#54, D-014) and installs only systemd-boot. B2 needs the shim and MokManager binaries on the ESP, pinned by build (16.1-7 for the 2011 x64 signature), and an update path for them. bootupd, which normally does that, is also removed. This is a production image change, so it gets its own card.
- **Second-stage name.** Here systemd-boot was copied to `grubaa64.efi`, shim's default. shim can also take its second stage from its load options. That would allow a boot entry `\EFI\atos\shimx64.efi` with `\EFI\systemd\systemd-bootx64.efi` as the argument, or fallback `fbx64.efi` with a `BOOTX64.CSV` that creates one. Neither was tested. `bootctl update` and bootc's ESP updates write `systemd-boot*.efi` under its own name, so the copy under the shim name has to be updated too (**not checked**).
- **Key rotation under B2** needs the new cert in MOK before the first UKI signed with it. That means `mokutil --import` from the running system (mokutil is not in the image) plus a MokManager confirmation with a password at the next boot. Revoking the old cert also needs MokManager (`mokutil --delete`). Not tested.
- **Installer UX.** The first boot of the installer media already needs the MokManager steps (section 3), because the installer is signed with our key too. These are blue, unstyled firmware screens with a file browser. About 15 keypresses, with the cert two folders deep on the ESP. C11 would need a printed or on-screen guide.
- **Real hardware.** Everything here is edk2. Multi-signature handling, MokManager's console output and the TPM measurements need a run on the NUC or a laptop with a stock Microsoft db.
- **aarch64** has no 2011 path at all: its shim is 2023-only.
- **SBAT.** Our systemd-boot is Fedora's binary and carries `systemd-boot.fedora,1`, so an SBAT revocation aimed at Fedora's build would also hit ours. A production B2 build should add an Atos SBAT component. Shim updates also raise `SbatLevel`, which can revoke other boot loaders on dual-boot machines.

## 6. Recommendation

**B2 conflicts with the Decided D-014 entry.** The D-014 write-up (§5) proposed B2 as a fallback, but the Decided log entry does not mention it. It says "no Microsoft KEK", with the rationale that "no outside party can change a machine's trust". A B2 machine keeps the firmware's Microsoft KEK and db and adds Fedora's vendor cert (section 4). So keeping B2 needs the **owner to amend D-014**, not only to confirm the write-up. A *Proposed* amendment is on card #76.

If the owner amends it: keep **B2 as the fallback** for machines where B1's setup-mode step is impractical. The technical question the card asked is answered: Fedora's shim starts systemd-boot, and systemd-boot verifies our UKI through an enrolled MOK. The owner should weigh three limits before relying on it:

1. Its trust set is Microsoft + Fedora + Atos, plus whatever the user or a persuaded user confirms in MokManager. On B2 machines, data protection depends on the TPM binding from #66, not on db, and that binding may need PCR14. A MOK **CA** cert becomes a kernel-module trust anchor unless `MokListTrusted` is turned off. Root can queue `--disable-validation` (`MokSBState`), which needs one user confirmation (section 4).
2. "Boots on firmware without UEFI CA 2023" holds only on x86_64, and only while we pin the dual-signed shim 16.1-7 and it is not revoked. The next Fedora shim will be 2023-only. On such firmware, B1 is the lasting answer.
3. It brings shim, MokManager and their update and revocation tracking back into the image, which #54 removed.

Suggested follow-up cards, if the owner keeps B2: (a) C1: ship pinned Fedora shim + MokManager on the ESP for B2 installs, and keep the shim-named systemd-boot updated with bootc; (b) C1: test B2 on the NUC with a TPM: what PCR7 and PCR14 record for MOK-verified images, an extra enrolled key and `MokSBState`, and whether #66 must also bind PCR14 on B2 machines; (c) C11: B2 enrolment screens and guide; (d) C1: key rotation under B2 (`mokutil` in the image or an alternative).

## Reproduce

In the dev VM, after `tools/dev-vm/sealed.sh build disk` has produced `~/sealed/disk.raw`:

```bash
ATOS_VM=atos-c1 tools/dev-vm/vm run spikes/c1-shim-mok/run.sh all
```

The steps are `fetch sigs disk direct nomok enroll enrolled tamper x64`; each can run alone. Work files and serial logs go to `~/shim/` in the VM, never into the repository. A full run takes about 25 minutes on the M1 Max (the `enroll` boot alone is about 8 minutes under emulation). The tools run in a Fedora 45 container (`localhost/shim-tools`: virt-firmware, pefile, sbsigntools, qemu-system-x86, edk2-ovmf), built from Fedora's repositories on first use.
