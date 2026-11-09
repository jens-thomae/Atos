# Which certificates the kernel accepts for module signatures

Card: #158 · Run: 2026-11-08 in the `atos-c1` dev VM (aarch64), image built from `main` at `fe96c2a` plus this card's script commit (fedora-bootc 45.20261108.0, kernel **7.2.15-300.fc45**). Every result below comes from one run of the committed script · Script: [`spikes/c1-module-trust/run.sh`](../../../spikes/c1-module-trust/run.sh)

This card decides nothing. It checks, on a booted sealed image with Secure Boot on, which certificates Fedora's kernel accepts for kernel module signatures, for both trust set-ups: B1 (D-014, our keys enrolled in db) and B2 (D-016, Fedora's shim with the Atos cert as a MOK). It answers the question [nvidia-graphics.md §4.2](../../decisions/nvidia-graphics.md#42-secure-boot-module-signing-under-d-014-and-d-016) raised from reading the kernel code. Only the committed TEST db key and VM-only test keys were used.

## Result in one paragraph

**Every certificate in the kernel's platform keyring is a trust anchor for kernel modules, and the kernel checks neither key usage nor extended key usage.** The platform keyring holds every certificate in the firmware's db and, under B2, every MOK that does not go to the machine keyring, plus shim's built-in Fedora CA (`fedoraca`). On B1, a module signed with the db key that signs our UKI loads. So does a module signed directly by a CA cert in db that lacks `digitalSignature`, and a module signed by a leaf certificate that cert issued, even when the leaf allows only `keyEncipherment` and TLS server authentication. On B2 with `MokListTrusted` off (`MokListTrustedRT` absent), a module signed by a **non-CA** MOK loads. So `MokListTrusted` off does not stop MOK-signed modules. The controls behave: an unsigned module, a module signed by an unknown key and a modified signed module are all refused. **What this means:** Microsoft (the UEFI and Option ROM CAs in db) and, on B2, Fedora/Red Hat (`fedoraca`) and the machine's OEM (its db certs) hold keys our kernel accepts for kernel code. [shim-mok-spike.md](shim-mok-spike.md) said the opposite. It is corrected in the same pull request.

## 1. Why the platform keyring counts

Mainline verifies a module signature against the secondary keyring, which links the builtin keyring. Fedora's kernel adds one fallback in `mod_verify_sig()` (kernel/module/signing.c, from Fedora's `patch-*-redhat.patch`, kernel-ark commit *"KEYS: Make use of platform keyring for module signature verify"*):

```c
if (ret == -ENOKEY && IS_ENABLED(CONFIG_INTEGRITY_PLATFORM_KEYRING)) {
	ret = verify_pkcs7_signature(mod, modlen, mod + modlen, sig_len,
			VERIFY_USE_PLATFORM_KEYRING,
			VERIFYING_MODULE_SIGNATURE,
			NULL, NULL);
}
```

`CONFIG_INTEGRITY_PLATFORM_KEYRING=y` in Fedora's aarch64 and x86_64 configs ([f45 dist-git](https://src.fedoraproject.org/rpms/kernel/raw/f45/f/kernel-aarch64-fedora.config)). The quote is from the f45 branch (linux 7.3.3). Upstream `pkcs7_trust.c` has no key-usage or EKU check on the chain ([source](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/crypto/asymmetric_keys/pkcs7_trust.c)), which section 3 confirms. The image runs 7.2.15-300.fc45, the kernel in the pinned base image, and the run below shows the same behaviour there. `CONFIG_MODULE_SIG_FORCE` is not set; signature enforcement comes from lockdown, which Secure Boot switches on (`integrity` in both runs).

## 2. What was run

`tools/dev-vm/vm run spikes/c1-module-trust/run.sh` runs these steps (header of the script for details):

| Step | Does |
| --- | --- |
| `tools` | A container `FROM` the image's base, so the kernel matches: `kernel-devel-7.2.15-300.fc45`, gcc, openssl, sbsigntools, virt-firmware. Fedora's `shim-aa64-16.1-7` comes from the base image itself |
| `keys` | VM-only keys, never committed (below), and a db with four certs for B1 |
| `modules` | Builds one trivial module per case for the image's kernel and signs it (table in section 3) |
| `install` | `bootc install to-disk` of `localhost/c1-base`, then two disks: B1 with the VM's PK, KEK and db on the ESP for systemd-boot to enrol; B2 with shim as `BOOTAA64.EFI`, our signed systemd-boot as `grubaa64.efi` and no key set |
| `b1` | Fresh firmware variables (setup mode): systemd-boot enrols PK, KEK and db, resets, boots the sealed UKI. In the guest: keyrings, then `insmod` of every module |
| `b2` | Ubuntu's `AAVMF_VARS.ms.fd` (Microsoft KEK 2011 + 2023; db: Windows PCA 2011, UEFI CA 2011, UEFI CA 2023, Option ROM UEFI CA 2023, Windows UEFI CA 2023). `MokList` = TEST db cert (so the UKI boots) + the non-CA `mok` cert, written with `virt-fw-vars --add-mok`. `MokListTrusted` is created as a boot-services variable, which is what `mokutil --untrust-mok` leaves after MokManager confirms it: shim (mok.c, `MOK_VARIABLE_INVERSE`) then does **not** create `MokListTrustedRT`. Same guest script |

The guest script copies the modules to `/run/mt` and labels them `modules_object_t`. Without the label, SELinux (enforcing) refuses every `insmod` from `/run` (`avc: denied { module_load }`) before the signature is checked, which a first run showed. SELinux stays enforcing.

Keys (RSA-2048):

| Key | Certificate | Where |
| --- | --- | --- |
| TEST db (committed) | `CN=Atos TEST db …`, CA:TRUE, no key usage | db on B1, MokList on B2. Signs the UKI |
| `ca` | Self-signed, CA:TRUE, keyUsage `keyCertSign, cRLSign` only, no EKU. Shaped like a third-party CA in db | db on B1 |
| `leaf-cs` | Issued by `ca`: CA:FALSE, `digitalSignature`, EKU `codeSigning` | No keyring |
| `leaf-tls` | Issued by `ca`: CA:FALSE, `keyEncipherment` only, EKU `serverAuth` | No keyring |
| `mok` | Self-signed, CA:FALSE, `digitalSignature`, EKU `codeSigning` | MokList on B2 |
| `stranger` | Self-signed | Nowhere |
| `PK`, `KEK` | Stand-ins for D-014's per-machine keys | B1 |

## 3. Results

Keyrings as the guest lists them (`/proc/keys`, `keyctl list`):

| | B1 | B2 |
| --- | --- | --- |
| `.builtin_trusted_keys` | Fedora kernel signing key, Fedora IMA CA | the same |
| `.machine` | empty | empty |
| `.platform` | TEST db, `ca`, Microsoft Corporation UEFI CA 2011, Microsoft Option ROM UEFI CA 2023, Microsoft UEFI CA 2023 (5) | Windows Production PCA 2011, Microsoft Corporation UEFI CA 2011, Microsoft UEFI CA 2023, Option ROM UEFI CA 2023, Windows UEFI CA 2023, `fedoraca` (Red Hat, Inc.), TEST db, `mok` (8) |
| `MokListRT` / `MokListTrustedRT` | absent / absent | present / **absent** (trust off) |
| Lockdown, SELinux | `integrity`, enforcing | the same |

`insmod` per module (`Key was rejected by service` is `EKEYREJECTED`):

| Module | Signed by | B1 | B2 |
| --- | --- | --- | --- |
| `unsigned` | nothing (control) | refused | refused |
| `stranger` | `stranger`, in no keyring (control) | refused | refused |
| `db` | TEST db key (`sign-file`) | **loaded** | **loaded** |
| `db_tamper` | as `db`, then one byte of the module changed (control) | refused | refused |
| `db_attrs` | TEST db key, PKCS#7 with signed attributes | refused | refused |
| `ca` | `ca` key directly (`sign-file`): a CA cert without `digitalSignature` | **loaded** | refused (not in B2's keyrings) |
| `leaf_cs` | `leaf-cs`, its cert inside the PKCS#7 (chains to `ca`) | **loaded** | refused (`ca` not in B2's keyrings) |
| `leaf_tls` | `leaf-tls` (`keyEncipherment`, EKU `serverAuth`), cert inside the PKCS#7 | **loaded** | refused (`ca` not in B2's keyrings) |
| `mok` | `mok` (`sign-file`): a non-CA MOK | refused (not enrolled) | **loaded** |

Kernel log lines for the loads: `atos-modtrust: mt_db loaded` and so on, after `mt_db: loading out-of-tree module taints kernel.`

What the table shows:

- **B1 (acceptance criterion 1):** a module signed only by the db cert loads. The Atos release db key therefore signs modules on B1 machines with no further enrolment, which is what D-017's signing path needs.
- **B2 (criterion 1):** a module signed by a non-CA MOK loads with `MokListTrusted` off. The switch decides only whether CA MOKs go to `.machine`; the others go to `.platform` either way, and `.platform` verifies modules.
- **Key usage and EKU (criterion 2):** not checked. A CA cert with only `keyCertSign` verifies a module signed by its own key (`ca`), and a leaf it issued verifies a module even with the wrong key usage and a TLS-only EKU (`leaf_tls`), as long as the leaf cert is inside the signature. So for a CA cert in db, *anything signed by a key it certified* is a valid module signature. The Microsoft CAs in db and `fedoraca` are such CA certs.
- **Content, not just the key:** the tampered module is refused, so the signature covers the module.
- **Signed attributes:** a PKCS#7 signature with signed attributes (contentType, messageDigest) is refused even with the db key: the kernel logs `PKCS7: Invalid module sig (has authattrs)`. Authenticode signatures always carry signed attributes (section 4).

## 4. Who can sign kernel code that loads on an Atos machine

| Set-up | Certificates in `.platform` | Who holds a key that chains to them |
| --- | --- | --- |
| B1 (D-014) | Atos release cert; Microsoft Option ROM UEFI CA 2023; Microsoft UEFI CA 2011 where the TPM log shows option ROMs; optional Microsoft UEFI CA 2023 and Windows CAs; the developer cert while developer mode is on (D-015) | Atos (release key, offline token); **Microsoft** (the CAs and every key they certify); the user (developer key) |
| B2 (D-016) | Everything in the firmware's db (Microsoft's CAs and usually OEM certs); every MOK while `MokListTrusted` is off, the non-CA ones while it is on; shim's vendor cert `fedoraca` | Atos (MOK); **Microsoft**; **the OEM**; **Fedora/Red Hat** (`fedoraca` and the keys it certified); anyone who gets a cert into MokList |

The builtin keyring adds Fedora's per-build kernel signing key on both, as before.

Limits on what that means in practice, **not tested** here:

- A module has to be built for the exact running kernel (vermagic and symbol versions); forcing a load strips the signature. A foreign signed module is only useful against the kernel it was built for.
- Microsoft and Fedora sign UEFI binaries with Authenticode. For modules the kernel accepts only `pkcs7-data` signatures without signed attributes ([`pkcs7_verify()`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/crypto/asymmetric_keys/pkcs7_verify.c); the `db_attrs` case shows the second check), while Authenticode signs `SpcIndirectDataContent` with signed attributes. So a signed shim, GRUB or kernel image cannot be reused as a module signature. Someone with one of those keys would have to sign a module on purpose (or by mistake). Whether any such module exists is not known.

Why it matters even so: **loading a module does not change PCR7 or PCR11**. A disk key bound to the measured boot chain (#66) is released as usual when the genuine Atos chain boots and root then loads a module signed under one of those keys. Lockdown is meant to keep root from getting its own code into the running kernel without changing the boot chain. With the platform keyring trusted, that holds only as long as nobody who holds one of the keys above signs a module that does harm. On B1, root also holds the per-machine KEK: it can append its own cert to db, and after the next boot load its own signed modules. A db change alters PCR7, so this is the "local root" row of D-014's threat model with one more outcome, not a new path past the TPM binding.

## 5. What is not covered

- **x86_64 and real firmware.** The run is aarch64 under edk2. The kernel code path is architecture-independent; the keyring contents depend on the firmware's db.
- **`MokListTrusted` on** under B2: spike #76 already showed non-CA MOKs going to `.platform` with it on, which this card's result makes a module trust anchor too.
- **A real Microsoft- or Fedora-signed module.** We hold no such key; the `ca`/`leaf_*` cases stand in for one.
- **IPE.** Fedora's kernel has `CONFIG_SECURITY_IPE=y` (`ipe` is in `CONFIG_LSM`). An IPE policy that allows module loads only from fs-verity-protected files (our composefs `/usr`) could stop modules from `/var` or `/etc` whatever their signature. Not checked; see the proposal on card #158.

## Side finding: an extra Microsoft cert in db

On B1, systemd-boot enrolled a db with four certs (TEST db, `ca`, Microsoft Corporation UEFI CA 2011, Option ROM UEFI CA 2023; `keys` concatenates exactly those four ESLs). After the boot, the firmware's db held a fifth: **Microsoft UEFI CA 2023**, and the kernel loaded it into `.platform`. A db with only the TEST cert (`sealed.sh boot`) gets no extra cert: checked by hand on that VM's earlier variable files, not by the script. systemd-boot 262's binary has no strings that suggest it adds certs, so the likely source is the VM's firmware (Ubuntu's AAVMF `2024.02-2ubuntu0.10`), not confirmed. D-014 makes UEFI CA 2023 optional on B1, so if real firmware does the same, B1 machines that need UEFI CA 2011 for option ROMs would get UEFI CA 2023 too. Filed as #165.

## Reproduce

```bash
ATOS_VM=atos-c1 tools/dev-vm/vm run tools/dev-vm/sealed.sh build
ATOS_VM=atos-c1 tools/dev-vm/vm run spikes/c1-module-trust/run.sh
```

Work files go to `~/sealed/modtrust/` in the VM, never into the repository; logs and summaries to `tools/dev-vm/out/sealed/modtrust-*`. `install` plus `b1` take about 14 minutes under emulation, `b2` about 14 more.
