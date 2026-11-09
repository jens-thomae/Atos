# IPE: kernel modules only from verified /usr (spike)

Card: #169 · Runs: 2026-11-08 in the `atos-c169` dev VM (aarch64, QEMU without KVM), image built from `main` at `e846e3a` plus this card's script (fedora-bootc 45.20261108.0, kernel **7.2.15-300.fc45**) · Script: [`spikes/c1-ipe-modules/run.sh`](../../../spikes/c1-ipe-modules/run.sh) · Logs: `tools/dev-vm/out/sealed/ipe-*` in the VM checkout (not committed)

This card decides nothing. It checks whether an IPE (Integrity Policy Enforcement) policy can stop a root user from loading kernel modules that are correctly signed (by any cert in the platform keyring, [module-trust.md](module-trust.md)) but are not files of our fs-verity-protected composefs `/usr`. Only the committed TEST db key and VM-only test keys were used.

## Result in one paragraph

**The mechanism works on our image, but Fedora's kernel can't carry the policy we would need, and root can still switch IPE off.** IPE matches composefs files by their fs-verity digest: under a policy listing module digests, modules from `/usr` load (an in-tree `.ko.xz` through `modprobe`, and an Atos-signed module as D-017's NVIDIA modules would be), while the same TEST-signed modules from `/var`, `/etc`, a `bootc usr-overlay` and an `init_module(2)` buffer are refused. Three findings stop it from being shippable as it is: (1) **size**: IPE takes a policy only as a signed PKCS#7 with the text inside, and the kernel's ASN.1 decoder refuses messages over 65,535 bytes, so a policy fits about 350 SHA-512 digests. The image ships **5,592** module files (Fedora's 5,589 plus our three test modules); the full policy is 985 KB and the kernel refused it (`EMSGSIZE`). Fedora's kernel has no other property that would cover `/usr` as a whole (no boot policy compiled in, no `fsverity_signature`). (2) **root**: every write to IPE needs `CAP_MAC_ADMIN`, which Fedora's SELinux policy gives no service and no login domain, but root can `setenforce 0` and then switch IPE to permissive with one write. `secure_mode_policyload` blocks `setenforce`, but root can still start a relabelled copy of `bash` in `install_t` with `runcon`, which holds `mac_admin`, and switch IPE off from there: the TEST-signed module from `/etc` then loaded. (3) **who can sign a policy**: policies are verified against the same keyrings as modules, platform keyring included, so the same keys that can sign a module can sign a replacement policy. **Recommendation: don't pursue IPE on Fedora's kernel; keep D-014 option (a).** Details in section 7.

## 1. What Fedora's kernel has (criterion 1)

From the booted image's `/usr/lib/modules/7.2.15-300.fc45.aarch64/config` (log line `ATOS-IPE config`), and the same in f45 dist-git for aarch64 and x86_64 ([aarch64](https://src.fedoraproject.org/rpms/kernel/raw/f45/f/kernel-aarch64-fedora.config), [x86_64](https://src.fedoraproject.org/rpms/kernel/raw/f45/f/kernel-x86_64-fedora.config), linux 7.3.3):

| Option | Value | Means |
| --- | --- | --- |
| `CONFIG_SECURITY_IPE` | `y`; `ipe` in the active LSM list | IPE is built in and running, with no policy until one is loaded |
| `CONFIG_IPE_BOOT_POLICY` | `""` | No policy compiled in: until userspace loads one, IPE allows everything |
| `CONFIG_IPE_PROP_FS_VERITY` | `y` | `fsverity_digest=sha512:<hex>`: a file with exactly this fs-verity digest |
| `CONFIG_IPE_PROP_FS_VERITY_BUILTIN_SIG` | not set (`CONFIG_FS_VERITY_BUILTIN_SIGNATURES` not set) | No `fsverity_signature` property: no "any file whose fs-verity digest is signed by key X" |
| `CONFIG_IPE_PROP_DM_VERITY`, `_SIGNATURE` | `y` | `dmverity_roothash`, `dmverity_signature`: only for files on a dm-verity device, which composefs is not |
| `boot_verified` | always there | Files from the initramfs: gone after switch-root |
| `CONFIG_IPE_POLICY_SIG_SECONDARY_KEYRING`, `_PLATFORM_KEYRING` | `y`, `y` | A policy is accepted if signed under the builtin, secondary **or platform** keyring |
| `CONFIG_SECURITY_SELINUX_DEVELOP` | `y` | Root can switch SELinux to permissive at runtime (unless the policy forbids it) |

So the only property that can describe a composefs `/usr` file is `fsverity_digest`, one rule per file. Upstream behaviour used below, from the kernel docs and source ([admin guide](https://docs.kernel.org/admin-guide/LSM/ipe.html), [`security/ipe/`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/security/ipe)):

- The `KMODULE` operation covers `finit_module` (file read hook, with the file) and `init_module` (load-data hook, no file, so no property matches and the default decides).
- The file's properties come from `d_real_inode()` (`security/ipe/eval.c`), which for an overlayfs file is the backing data file. On composefs that is the object in `/sysroot/composefs/objects` that carries the fs-verity digest, which section 3 confirms.
- Rules are kept per operation and evaluated top to bottom (`ipe_evaluate_event()`); a `KMODULE` rule list costs nothing on `exec` or `mmap`.
- Policies are written to `securityfs` (`/sys/kernel/security/ipe/new_policy`) as PKCS#7 with the policy text inside. Each write needs `CAP_MAC_ADMIN` (`security/ipe/fs.c`), so does `enforce` (permissive mode). The active policy can't be deleted, an update must have a higher version, and a policy can only be activated if its version is at least the active one's.
- `pkcs7_parse_message()` runs the ASN.1 decoder on the whole message, and [`asn1_ber_decoder()`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/lib/asn1_decoder.c) returns `-EMSGSIZE` above 65,535 bytes.

## 2. What was run

`ATOS_VM=atos-c169 tools/dev-vm/vm run spikes/c1-ipe-modules/run.sh` (script header for details):

| Step | Does |
| --- | --- |
| `tools`, `modules` | A container `FROM` the image's base with `kernel-devel` for its kernel; eight trivial test modules (`mt_*`), all signed with the committed TEST db key, which is in db on B1, so every one passes the signature check |
| `policy` | fs-verity digests (SHA-512, 4 KiB blocks, as composefs enables them) of the image's module files with `fsverity digest`. One `op=KMODULE fsverity_digest=… action=ALLOW` rule each, `DEFAULT op=KMODULE action=DENY`, `DEFAULT action=ALLOW` for everything else; signed with the TEST db key (`openssl cms -nodetach -noattr`). Built twice: **full** (every module file) and the **shipped subset** that fits (below). Plus four policies root tries in the guest |
| `image` | `localhost/c1-base:ipe`: the shipped Containerfile plus three test modules in `/usr/lib/modules/<kver>/extra`, the signed policy in `/usr/lib/atos/ipe/`, and an initrd unit that writes it to `securityfs` and activates it. The initrd is rebuilt in the image's `kernel` stage, so the policy and unit are inside the signed UKI |
| `install`, `boot` | `bootc install to-disk`, then a sealed B1 boot (setup-mode enrolment of the TEST keys, Secure Boot on). The guest prints the boot facts, then runs the checks as root in `unconfined_t` (the domain a root login gets) via `systemd-run -p SELinuxContext=…` |

Five runs, each from a commit of the script on this branch. Runs 1, 2 and 4 each found a problem and led to the next commit; run 5 is the full result, and run 3 gave the same results for every step it shared with it:

| Run | Policy delivery | Outcome |
| --- | --- | --- |
| 1 | A unit after switch-root | Every IPE write refused: `avc: denied { mac_admin } … scontext=system_u:system_r:initrc_t`. No policy loaded; all modules below loaded (the no-policy control) |
| 2 | Initrd, full policy: 5,592 rules, 985,680 bytes signed | `dd: error writing '/sys/kernel/security/ipe/new_policy': Message too long`, audit `errno=-90` (`EMSGSIZE`) |
| 3 | Initrd, shipped subset | Policy active; module loads and root checks as in sections 3 and 4, without `runcon` |
| 4 | As run 3, plus `runcon` with the shell copy in `/run` | `runcon` refused for every combination (`Permission denied`; audit: `avc: denied { nosuid_transition }`, `/run` is mounted `nosuid`) |
| 5 | As run 4, shell copy in `/etc` and `/var/tmp` (`rw,nodev`, no `nosuid`) | **The result below** |

The shipped subset is the 204 module files under `drivers/virtio`, `drivers/gpu/drm` (top level, `virtio`, `display`), `drivers/char/hw_random`, `fs`, `crypto`, `lib`, `drivers/block`, plus `drivers/net/dummy.ko.xz` and the three test modules: 36,087 bytes of text, **37,386 bytes signed**. That is enough for this VM to boot. A rule with a SHA-512 digest is about 178 bytes, so the 65,535-byte limit leaves room for about 350 rules after the signature.

## 3. Module loads under the policy (run 5)

Boot: the initrd unit logged `atos-ipe-policy: loaded and active in 296739 us` (runs 3 and 4: 310474 and 278384 us), and IPE audited the load and activation (`type=1422 … policy_name="atos_kmodules" policy_version=1.0.0 … res=1`, `type=1421 … new_active_pol_name="atos_kmodules"`). SELinux enforcing, lockdown `integrity`, Secure Boot on.

| Case | File | Result | Audit / note |
| --- | --- | --- | --- |
| `usr-intree` | `modprobe dummy`: Fedora's `/usr/lib/modules/…/kernel/drivers/net/dummy.ko.xz` (compressed) | **loaded** | So kmod passed the file to the kernel: a buffer load is refused (`initmod`) |
| `usr` | `insmod` of Atos-signed `mt_usr.ko` in `/usr/lib/modules/…/extra` | **loaded** | D-017's NVIDIA modules would sit here |
| `var` | `mt_var.ko` in `/var/tmp`, labelled `modules_object_t` | refused (`EACCES`) | `ipe_op=KMODULE ipe_hook=KERNEL_READ … rule="DEFAULT op=KMODULE action=DENY"` |
| `etc` | `mt_etc.ko` in `/etc` | refused | same |
| `usr2-copy` | Byte-identical copy of `/usr`'s `mt_usr2.ko` in `/var/tmp` (its digest is in the policy), no fs-verity | refused | same: the digest must come from fs-verity, not the content |
| `usr2-copy-verity` | Same copy after `FS_IOC_ENABLE_VERITY` (SHA-512, 4 KiB): digest `sha512:f3a75e05…` = the policy's | **loaded** | Only content already allowed; root gains nothing |
| `initmod` | `init_module(2)` from a buffer | refused | `ipe_hook=KERNEL_LOAD … path=?` |
| `ovl` | `bootc usr-overlay`, then `mt_ovl.ko` copied into `/usr/lib/modules/…/extra` | refused | `dev="overlay"`: the overlay's upper layer has no fs-verity |
| boot-time loads not in the subset | `vsock`, `hv_vmbus`, `cppc_cpufreq`, `rfkill` (requested by systemd, udev and `modprobe` during boot) | refused | Every module file not in the policy is refused, from `/usr` too |

Userspace can't measure composefs files: `FS_IOC_MEASURE_VERITY` on `/usr/lib/modules/…/mt_usr2.ko` gives `Inappropriate ioctl` (overlayfs does not pass it through). IPE still matches them, since it looks at the backing file.

## 4. Can root change or remove the policy (criterion 2)

All as root in `unconfined_t`, with the policy active, in this order (run 5):

| Step | Result |
| --- | --- |
| SELinux enforcing: write 0 to `enforce`, delete the policy, load a new TEST-signed `allow_all` 9.0.0 | all refused, `Operation not permitted`: `avc: denied { mac_admin } … unconfined_t` |
| `setenforce 0` | **accepted** (SELinux permissive) |
| Then: delete the active policy | refused, `Operation not permitted` (IPE: active policy) |
| Update it to version 0.9.0 (TEST db key) | refused, `Stale file handle` (`ESTALE`: rollback protection) |
| New unsigned policy | refused, `Bad message` |
| New policy signed by a key in no keyring | refused, `Required key not available` |
| New `allow_all_low` 0.1.0, signed with the TEST db key | **loaded**; activating it refused, `Invalid argument` (lower version than the active one) |
| Write 0 to `enforce` | **accepted**, `enforce=0`; `mt_var` from `/var` then **loads** (audited with `enforcing=0`) |
| Write 1 to `enforce`, `setenforce 1` | accepted; `mt_var2` from `/var` refused again |
| `setsebool secure_mode_policyload on` (runtime) | accepted |
| Then `setenforce 0` | refused: `avc: denied { setenforce }` |
| Then write 0 to `enforce` | refused (`mac_admin`) |
| A `core_pattern` pipe helper (the kernel starts it in `kernel_t`, which has `mac_admin`), script in `/run` | did not run: `avc: denied { execute_no_trans } … scontext=…kernel_t tcontext=…var_run_t`. A `bin_t` file would run in `kernel_generic_helper_t` (policy: `type_transition kernel_t bin_t:process kernel_generic_helper_t`, read by hand with `sesearch`), which has no `mac_admin` |
| `cp /usr/bin/bash /etc/atos-ipe/sh-ctr`, `chcon -t container_var_lib_t` it, `runcon -r unconfined_r -t install_t /etc/atos-ipe/sh-ctr -c 'echo 0 > /sys/kernel/security/ipe/enforce'` | **accepted**: the shell ran as `unconfined_u:unconfined_r:install_t:s0`, `enforce=0`; `mt_etc` from `/etc` then **loaded** |

Which SELinux domains have `mac_admin` in Fedora's targeted policy (`sesearch -A -c capability2 -p mac_admin`, run by hand on the image's `policy.35`, not by the script): `install_t`, `kernel_t`, `livecd_t`, `setfiles_mac_t`. None is a service or login domain, which is why the direct writes got `EPERM`. But the same policy has `allow unconfined_t domain:process transition`, and those domains accept `container_var_lib_t` files as entry points (from the `unconfined_domain_type` attribute), a label root may put on any file. `secure_mode_policyload` covers only `setenforce`, `load_policy` and `setsebool`, so it does not stop this. The last two lines of the guest's results (`mt_usr3` "under the allow-all policy") ran with IPE in permissive mode after `runcon`; the `allow_all` policy was never activated, since the helper did not run.

What root can't do at runtime, by the kernel's design: change the kernel command line (`ipe.enforce=0` would start IPE in permissive mode, but it is in the signed UKI) or load a policy signed by a key outside the builtin, secondary and platform keyrings.

What it would take to make the policy root-proof, none of it tested:

- **Keep root out of `mac_admin` and out of SELinux policy changes.** `secure_mode_policyload` set early in every boot from a unit in `/usr`, plus an SELinux policy change that stops `unconfined_t` from entering `install_t`, `livecd_t`, `setfiles_mac_t` and any other domain with `mac_admin` (run 5 shows the `runcon` path; whether others remain is not known). That means changing Fedora's targeted policy for the root login, which also changes what root can do everywhere else. The SELinux policy store and booleans live in `/etc`, which root can change for the next boot without touching the boot chain, so the policy would have to come from `/usr` alone.
- **A kernel that does not let root turn IPE off:** a compiled-in boot policy and no permissive switch. That is our own kernel build, a §3 non-goal.

## 5. Delivery on a sealed image, and what it breaks (criterion 3)

**Delivery as tested.** The signed policy file sits in `/usr/lib/atos/ipe/`, so it is part of the sealed composefs digest, and a dracut config copies it and the unit into the initramfs, which is inside the signed UKI. The unit runs late in the initrd (`After=initrd-fs.target`, `Before=initrd.target`), before switch-root. At that point SELinux has no policy yet (systemd loads it after switch-root), so the write needs no `mac_admin` domain. Before the unit runs, IPE has no policy and allows everything: the initrd's own module loads come from the signed UKI. Since Fedora's kernel has no boot policy (`CONFIG_IPE_BOOT_POLICY=""`), this window can't be closed without our own kernel. A policy can't be put on the kernel command line.

**Policy per image.** The digests change with every kernel and every module, so the policy is built with the image and signed with the release key (D-014's offline token) at each release. A developer image (D-015) would need a policy signed with the developer key; the developer key is in db, so IPE accepts it.

**What it breaks:**

| | Effect |
| --- | --- |
| **The size limit** | A general-purpose image can't list its modules. Fedora's kernel ships 5,589 module files on aarch64; about 350 fit. Any module not listed is refused from `/usr` too (runs 3–5: `vsock`, `hv_vmbus`, `cppc_cpufreq`, `rfkill`), so hardware support breaks. Splitting the list into several policies does not help: only one policy is active at a time |
| D-017's NVIDIA modules | Work, if listed: they ship in `/usr` (the `usr` case) |
| DKMS / akmods | Already impossible on the sealed image (`/usr` is read-only). With IPE, a module built and signed locally is refused wherever it is placed |
| Developer mode (D-015), `bootc usr-overlay` (#99) | Modules copied into the overlay are refused (`ovl` case). Developer images work only with a policy signed by the developer key that lists their modules |
| Root's own debugging (`insmod` of a test module) | Refused unless the module is in the image's policy |

## 6. Cost (criterion 4)

- **Boot:** loading and activating the 37 KB policy took **280–310 ms** in the initrd (runs 3–5), measured by the unit itself. The VM runs QEMU without KVM, so this is an emulated upper bound, not a §7 number; the boot-to-desktop budget (≤ 10 s on the NUC) would need a measurement there. Time grows with the policy, which the size limit caps at about 64 KB.
- **Runtime:** `insmod` of a test module from `/usr` took 472 ms under the 204-rule policy and 347 ms later in the same boot with IPE permissive (run 5 log; run 3: 603 and 410 ms). One sample each under emulation: noise, not a measurement. By the code, IPE evaluates `KMODULE` rules only on module loads, as a list walk with one digest comparison per rule; `exec` and `mmap` hooks find no rules and take the global default. No §7 runtime budget (input, frames, idle CPU, RAM) is touched by module loads.

## 7. Recommendation for the owner

**Do not ship an IPE module policy on Fedora's kernel.** Keep D-014 option (a), which the owner already chose: record that db certs are kernel-module trust anchors.

Reasons:

1. The policy we need doesn't fit. The 64 KiB PKCS#7 limit allows about 350 digests against 5,589 module files, and Fedora's kernel has no property that covers composefs `/usr` as a whole. A hand-picked list breaks hardware support, which C1's "supports normal laptops and desktops broadly" rules out.
2. It is not root-proof on Fedora's SELinux policy: `setenforce 0` turns it off in two commands, and with `secure_mode_policyload` on, a relabelled shell started in `install_t` does the same in three. Root-proofing needs SELinux policy work whose result is not known, kept in `/usr`.
3. It does not shrink the set of key holders: an IPE policy is accepted under the same keyrings as a module, platform keyring included. Someone who can sign a module for our kernel can sign an allow-all policy with a higher version.

The mechanism itself worked as hoped: composefs `/usr` files are recognised by their fs-verity digest, and signed modules from anywhere else are refused. It would become useful if the kernel offered `fsverity_signature` (`CONFIG_FS_VERITY_BUILTIN_SIGNATURES`) or a compiled-in boot policy. Both are Fedora kernel config choices, outside our control without our own kernel (§3 non-goal), so this is not proposed as a follow-up card.

## What is not covered

- **x86_64 and real hardware.** Run on aarch64 under emulation. The IPE code is architecture-independent; the module count differs.
- **B2 (shim).** Not booted; the policy check is the same, only the keyrings differ (more keys can sign a policy).
- **§7 boot cost on the NUC.** See section 6.
- **A root-proof SELinux configuration.** Only `secure_mode_policyload`, one `core_pattern` helper and `runcon` were tried; section 4 lists what else it would take.
- **Firmware loads** (`op=FIRMWARE`, e.g. NVIDIA's GSP firmware in `/usr/lib/firmware`): the same mechanism and the same size limit; not tested.

## Reproduce

```bash
ATOS_VM=atos-c169 tools/dev-vm/vm run tools/dev-vm/sealed.sh build
ATOS_VM=atos-c169 tools/dev-vm/vm run spikes/c1-ipe-modules/run.sh
```

Work files go to `~/sealed/ipe/` in the VM, never into the repository. A full run takes about 35 minutes under emulation (image build mostly cached, boot about 9 minutes).
