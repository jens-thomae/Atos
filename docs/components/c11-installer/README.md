# C11 installer

The installer ISO puts the sealed Atos image (C1) on an empty disk, **encrypted by default**, with no online account and no network (D-005). Card #66; the administrator password is #187. Secure Boot key enrolment at install (D-014 B1/B2/C) is card #123; the signed PCR11 policy is card #122.

## What is where

| Path | What |
| --- | --- |
| [`components/c11-installer/Containerfile`](../../../components/c11-installer/Containerfile) | The live installer system: `fedora-bootc` (same pinned base as c1-base), the live-boot dracut module, Fedora's shim and GRUB for the media, and `atos-install`, started on tty1 |
| [`atos-install/`](../../../components/c11-installer/atos-install/) | The installer, a text-mode Rust binary (std only, no dependencies). It drives standard tools: `sfdisk`, `cryptsetup`, `systemd-cryptenroll`, `mkfs`, `podman` and `bootc install to-filesystem` |
| [`install-policy.json`](../../../components/c11-installer/install-policy.json) | The install-only trust policy (#176, below), at `/usr/share/atos-install/` on the ISO |
| [`firstboot/`](../../../components/c11-installer/firstboot/) | `atos-tpm-seal`, the first-boot unit that binds the disk to Secure Boot (below) |
| [`build-iso.sh`](../../../components/c11-installer/build-iso.sh) | Builds the installer image, then the ISO with image-builder's `generic-iso` type (pinned by digest), with the c1-base image as offline payload |
| [`vm-test.sh`](../../../components/c11-installer/vm-test.sh) | The end-to-end test in the dev VM (below) |
| [`atos-installer.service`](../../../components/c11-installer/atos-installer.service) | Starts `atos-install` on tty1 of the live system (below) |
| [`.github/workflows/c11-installer.yml`](../../../.github/workflows/c11-installer.yml) | CI: builds the amd64 ISO, checks its contents, then installs it under KVM through the interactive installer and boots it twice; on `main` it uploads the tested ISO (below) |

User page: [installing from a USB stick](../../user/install-from-usb.md).

## How the installer starts and when it restarts (#220)

The live system boots to `multi-user.target`. `atos-installer.service` (`Type=idle`, enabled in the image; the getty on tty1 is disabled and conflicts with it) runs `atos-install` on tty1 with the terminal as its input and output. It first checks for a TPM 2.0 (below), then asks for the disk, the word `erase` and the password twice, installs, shows the recovery key and waits for Enter, then reports the time and waits for Enter again.

- **Only `atos-install` restarts the machine**, with `systemctl reboot`, after the install has finished and the user pressed Enter at "Press Enter to restart". The unit itself never restarts anything.
- **After a failure** it shows the error and asks "Press Enter to try again, or type "shell" for a shell". A retry first undoes what the failed attempt left mounted or open (the target mounts, its `/var/tmp` bind mount, the LUKS mapping, the install-time key file), then starts again with the TPM check and the disk question. The shell is a root `bash` on the live system; `exit` returns to the installer. Anyone at the keyboard of a machine booted from the media already has that much control.
- **Without input** (the terminal went away) it stops instead of reading empty answers, so it cannot retry or restart in a loop.
- `--yes` (the dev VM's unattended step) asks nothing but the password and never restarts or retries.

**The TPM check (#222).** Before the disk question (also with `--yes`) `atos-install` checks for the TPM 2.0 that the enrolment, `systemd-cryptenroll --tpm2-device=auto`, will use. `auto` takes the only TPM 2.0 resource manager (`/dev/tpmrm*`) and refuses when there is none or more than one, so the check asks the same tool: `systemd-cryptenroll --tpm2-device=list` must show exactly one `/dev/tpmrm*`, and the kernel must report a TPM with `tpm_version_major` 2 in `/sys/class/tpm/tpm*`. The kernel's answer also tells a TPM 1.2 (it has `tpm0` but no resource manager) apart from none at all. Otherwise the installer says what is missing, that nothing was changed on any disk, and how to turn the TPM on in the firmware setup (TPM, fTPM, PTT or Security Device), then shows the usual retry or shell prompt. Until #222 the enrolment failed only after the disk had been erased and a recovery key shown. The check does not prove that the TPM will answer: a TPM that is listed but broken still fails at the enrolment, after the erase. There is no way to install without a TPM (Known gaps).

**Why (#220).** Until #220 the unit had `ExecStartPost=-/usr/bin/systemctl reboot`. For `Type=idle` (as for `simple`) `ExecStartPost=` runs as soon as the main process has *started*, not after it exits, so every live boot restarted about 11 s in, in a loop, before the installer could ask anything. CI did not see it: its test turned the unit off and ran its own unattended unit. Reproduced under KVM with the unchanged ISO on PR #221's first run.

**Nothing else on tty1 (#220).** With the restart gone, the first interactive KVM runs found a second problem: on Fedora 45 the console on tty1 is **kmscon**. `kmsconvt@tty1.service` starts with `getty.target`, and logind starts `autovt@tty1.service` (kmscon again) at seat start if tty1 is not yet held open; the installer (`Type=idle`) opens it late. kmscon draws its own terminal on the display and reads the keyboard itself, so the installer kept running on tty1 where nothing showed it and no key reached it: the typed disk number never arrived (kernel stack: `n_tty_read`). In another run the installer was stopped outright. The installer image therefore masks `kmsconvt@tty1.service` and `autovt@tty1.service` beside disabling `getty@tty1.service`. The other VTs keep their consoles. The test fails at once if kmscon, autovt or a getty starts on tty1.

## How the installer is tested

`vm-test.sh install` (CI, `c11-installer.yml`) boots the **unchanged** ISO under QEMU with `-no-reboot`, so any restart ends QEMU. Two things are passed in as systemd credentials over SMBIOS, neither of which touches the installer unit: a test-only unit that copies the text of tty1 (`/dev/vcs1`) to the serial log whenever it changes (lines prefixed `ATOS-SCREEN`), with the installer's and logind's journal, and a drop-in that keeps the serial getty off the serial port. The host watches the serial log and, when each question shows on the screen, types the answer on the VM's keyboard through the QEMU monitor (`sendkey`, as `c1-base/shell-boot-test.sh` types the login): the number of the empty disk, `erase`, the password twice, Enter after the recovery key, Enter to restart. The test fails unless all six answers were typed, the screen says the install finished, the kernel then restarted, and the password appears nowhere in the log (it is not echoed). A failure prompt on the screen stops the test at once. When the screen has not changed for 30 s, the test unit logs what is on tty1, what the installer is waiting on (process state and kernel stack) and the installer unit's state (`ATOS-STALL`); the QEMU monitor's replies go to `out/mon.log`. Keys are typed 0.2 s apart. The installed disk then goes through `enrol`, `boot` and `reboot` as below, and only then does a push to `main` upload the ISO.

Before that install, `vm-test.sh notpm` (#222) boots the same ISO on an empty 20 GB disk with **no TPM device** and types nothing. It fails unless tty1 shows the no-TPM message with the firmware hint and the retry prompt, the disk question never shows, QEMU (`-no-reboot`) is still running 60 s after the prompt (no restart or power-off line in the log), and the disk is still 20 GB of zeros afterwards. It is part of the same CI step as the install, so the ISO is uploaded only if both pass. A TPM 1.2 cannot be tested this way (QEMU emulates only 2.0); that case is covered by the unit tests on captured outputs.

The interactive path installs the installer's built-in image reference (`ghcr.io/jens-thomae/atos/c1-base:latest`), which is CI's payload. The dev VM's payload is a local registry reference, so `vm-test.sh all` there uses `unattended`: `atos-install --yes --target-imgref …` in a test unit, with the installer unit turned off.

## Getting the ISO (#202)

After the KVM test passes on `main`, `c11-installer.yml` uploads the ISO it just tested as the artifact `atos-install-TEST-<commit>`: the ISO, its `.sha256` file and `README-TEST-BUILD.txt`. Find it under the run's **Artifacts** in the Actions tab (download needs a GitHub login; it comes as a zip of about 2.1 GB). Check it with `sha256sum -c atos-install-TEST-*.iso.sha256`. Artifacts expire after 14 days.

**It is a test build, never a release.** It is signed with test keys (D-014). The Secure Boot test db private key is public: it is committed in the repository ([`secureboot-test/`](../../../components/c1-base/secureboot-test/)), so anyone can sign boot code that a machine with these keys enrolled will boot. The cosign test key that signs the image, and that the installed system's trust policy accepts for updates, is a CI secret that any writer to the repository can read. A test build therefore gives no Secure Boot or signature assurance against anyone: install it only on a test machine you are willing to wipe, never on one you care about. No release machine trusts these keys. Release builds come from the owner's offline keys (#77).

The workflow runs only when installer files change, so a new ISO appears on `main` only after a C11 change. For a fresh ISO with the current `c1-base:latest`, run it by hand on `main` (about 15 minutes):

```bash
gh workflow run c11-installer.yml --ref main
```

A manual run with `c1-base-ref` set, and every pull request run, uploads nothing.

## Why this approach

- **image-builder `generic-iso`, not bootc-image-builder `anaconda-iso`.** osbuild calls `anaconda-iso` legacy and recommends `generic-iso` for new work. Anaconda also cannot do the D-014 enrolment steps (#123), and it brings Fedora's GUI and branding.
- **Our own text-mode installer.** Owner answer on #66. A graphical installer needs installer screens in the design system; text mode needs no tokens. The binary is small, so #123 and the developer key enrolment (#101) can share code with it.
- **Fedora's shim and GRUB boot the media only.** That is the only way installer media starts with Secure Boot on stock firmware before any Atos key is enrolled. The installed system boots systemd-boot and the sealed UKI exactly as c1-base builds them (#54). Nothing from the media's boot chain is copied to the disk.
- **`bootc install to-filesystem` over our own partitions, not `to-disk --block-setup tpm2-luks`.** The latter binds the TPM at install time, before Secure Boot keys are enrolled, so its PCR7 would be wrong (D-014 §8 item 5). Doing the partitioning ourselves also gives the layout below.
- **The image is unchanged.** The payload is the c1-base image as published, so the installed system is the same signed image that CI checks.

## Trust policy during the install (#176)

The image's trust policy rejects local `containers-storage` images (#150, [trust-policy.md](../c1-base/trust-policy.md)). `bootc install` runs inside the image and reads that same image from local storage (by image ID), so under the image's own policy it would refuse itself. A policy scope cannot tell that read apart from `bootc switch --transport containers-storage`, so the image policy cannot allow one and refuse the other (owner option A on #150).

`atos-install` therefore bind-mounts `install-policy.json` read-only at `/etc/containers/policy.json` **in the install container only**. It rejects everything by default and accepts only `containers-storage` images in `[overlay@/var/lib/containers/storage]`: inside the container that is the ISO's read-only payload store, which holds only the image being installed. Nothing is loosened compared to before #150: the install source was never checked by policy (Fedora's default was `insecureAcceptAnything`), and installing reads the image from the ISO, not from a registry.

The installed system gets **no** `/etc/containers/policy.json`, so the image's `/usr/share/containers/policy.json` applies from the first boot. `bootc install` deploys the image's own `/etc`, not the container's; `atos-install` checks this after the install and fails if the file is there. The #100 dev-image spike (`spikes/c1-dev-image/run.sh`) uses the same file for its `bootc install`.

**Results** (`c11-installer.yml`, KVM, 8 November 2026): with the published `c1-base:latest` the install took 105 s and both boots passed (Secure Boot on, sealed to PCR 7, TPM unlock). With a payload built from #150's branch (`containers-storage` → `reject` in the image policy; run by hand with the `c1-base-ref` input), 110 s, same boots. Some runs of both stopped at `no space left on device` in the live system's `/var/tmp` while bootc copied the image, after the policy had accepted it (#180).

To test an unpublished c1-base: run the workflow by hand with `c1-base-ref` set to a branch, tag or commit. It builds that ref rootless as `c1-base.yml` does (a rootful build's UKI digest did not match its image) and checks the seal before building the ISO.

## Administrator account (#187)

Owner decision on #187 (2026-11-09): the installer asks for a password and makes the session user an administrator. After the disk question and the `erase` confirmation, `atos-install` asks for the password twice (not echoed; empty or mismatched entries are asked again, three tries). The rest of the install runs unattended.

- **Which user.** `atos`, the user greetd logs in (c1-base `session/usr/lib/sysusers.d/atos.conf`). No user name is asked: the card asks for a password only, and the session, its home and greetd all name `atos`.
- **How.** After `bootc install`, `useradd --prefix` adds `atos` (UID 1000, `/var/home/atos`, `/bin/bash`, supplementary group `wheel`) to the deployment's `/etc` (`state/deploy/<id>/etc`), and `chpasswd --prefix` sets the password. chpasswd hashes it as the image's `login.defs` says: yescrypt. The installer reads the labels of the files before (`shadow_t`, `passwd_file_t`) and sets them again with `chcon` on the replaced files and their backups. Not `setfiles` with the deployment's file contexts: the live system's kernel policy has no Flatpak module and rejects the whole file (seen in the KVM run). On first boot sysusers.d finds `atos` and leaves it; tmpfiles.d creates the home directory.
- **What `wheel` gives.** Fedora's defaults: `sudo` (`%wheel ALL=(ALL) ALL`, password asked) and polkit administrator (`unix-group:wheel`), which is also D-015's admin authentication. No `NOPASSWD`.
- **The password is never logged or stored in plain text.** It is read from standard input into memory, written only to chpasswd's standard input, and overwritten after use (best effort: `read_line` may leave copies in freed memory). It is never on a command line, in a file or on the console. The KVM test fails if the test password appears in the install log.
- **Without a terminal** (the KVM test) the two lines are read from standard input as they come, so `--yes` still reads the password; end of input fails the install before the disk is touched.
- **Changing it later:** `passwd` in a terminal.
- **Logging in.** There is no autologin (owner decision A on #187): every boot stops at greetd's login prompt on tty1, where the user types `atos` and this password (c1-base README, "Session"). The KVM test logs in that way, typing on the VM's keyboard through the QEMU monitor once the report says the prompt is up, and checks that a logind session for `atos` on tty1 starts.

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

1. **Fails closed.** It goes on only if `SecureBoot` = 1 and `SetupMode` = 0. Otherwise it keeps the no-PCR slot, writes a warning to the console and `/run/issue.d/` ("anyone who can boot this machine … can read the disk without a password"), and tries again on the next boot. **On a machine that never boots with Secure Boot on, it never seals, and the no-PCR slot stays** (Known gaps).
   **Interface to the shell (#138).** While it keeps the no-PCR slot it writes the reason to `/run/atos/disk-unsealed` (world-readable, one line, for people; consumers test only that the file exists). `/run` is empty at every boot and the unit never runs again after a successful seal, so the file's presence means "the disk still unlocks without a PCR check". It is also removed on success within the same boot. The shell never runs `cryptsetup`.
2. Picks PCR7, or PCR7+14 when shim's MOK variables are present (D-016).
3. Runs `systemd-cryptenroll --unlock-tpm2-device=auto --tpm2-device=auto --tpm2-pcrs=7[+14] --wipe-slot=tpm2`. The new slot is never wiped; the install-time TPM2 slot is.
4. Deletes itself.

**PCR7 and updates.** PCR7 records the Secure Boot state and the certificate that verified each boot binary, not the binaries' hashes. A `bootc upgrade` to a new UKI signed by the same key therefore unlocks without a prompt. A UKI signed by any other authority does not (for example a chain signed by a Microsoft CA that #123 may put in db). Nor does a change to db, KEK or PK, or Secure Boot turned off. Then the user types the recovery key.

**What PCR7 alone does not stop.** Any UKI signed by the same key unlocks the disk. That includes older signed UKIs and, in the dev VM, anything signed with the public TEST key. Phase binding (unlock only in the initrd) is also missing. Both come with the signed PCR11 policy (#122): once the UKI carries `.pcrsig`, `atos-tpm-seal` adds `--tpm2-public-key` with `--tpm2-public-key-pcrs=11`.

## Known gaps, accepted for Phase 1

- **Silent unlock, then a password login** (#187, owner decision A; until then autologin, Q4 on #66). The disk unlocks silently through the TPM (D-015) and the machine boots to greetd's login prompt on tty1. **A stolen laptop therefore stops at the login: the session and the user's files need the password.** What the TPM binding alone still allows is in "What PCR7 alone does not stop" above: any UKI signed by the same key unlocks the disk, so someone with that UKI can read and change `/etc` and `/var` without the password, until the signed PCR11 policy (#122). The prompt is text until a graphical greeter exists (C3/C11).
- **The window before the seal** (owner answer Q2). Until `atos-tpm-seal` has run, the disk unlocks with this machine's TPM and no PCR check. Anyone with the machine in that window can boot something else (a live USB with `systemd-cryptsetup … tpm2-device=auto` is enough) and read or change `/etc` and `/var`, which are outside the seal. With Secure Boot on, the window ends with the first boot, which normally follows the install directly.
- **Without Secure Boot the window never ends** (owner decision on #66, option A: keep the no-PCR slot while Secure Boot is off; not protected against booting another OS until #123). The seal needs Secure Boot on and the firmware out of setup mode. Until key enrolment at install (#123) lands, Atos keys are on no real machine: stock firmware with Microsoft keys won't start the Atos-signed UKI, so Secure Boot has to be off. **Every install on real hardware therefore stays in this state: the disk opens without a prompt for any OS booted on that machine, and is protected only when taken out of it.** The warning goes to the boot console and `/run/issue.d/`, which greetd's login prompt does not show (`agreety` prints only `/etc/issue`), and to the graphical session through `/run/atos/disk-unsealed` (below; the C3 shell shows a notice, #138). The dev VM (systemd-boot enrols the TEST keys in setup mode) and CI do seal.
- **No TPM.** The installer needs a TPM 2.0 and says so before it touches any disk (#222). There is no way to install without one: a passphrase-only path needs an owner decision.
- **The installer media trusts Fedora's shim and Microsoft's UEFI CA** while it runs. That does not carry over to the installed system.

## Test in the dev VM

Use your own Lima instance; the boots load the VM for minutes:

```bash
ATOS_VM=atos-c11 tools/dev-vm/vm up
limactl shell atos-c11 -- sudo apt-get install -y linux-generic-hwe-24.04 swtpm swtpm-tools
limactl restart atos-c11
ATOS_VM=atos-c11 tools/dev-vm/vm run components/c11-installer/vm-test.sh all
```

The HWE kernel is needed because `bootc install` mounts EROFS from a file (Linux 6.12 or newer; see the C1 README). On the M1 dev VM, QEMU runs aarch64 without KVM (x86_64 with KVM where `/dev/kvm` exists, as in CI), with AAVMF Secure Boot firmware and an `swtpm` TPM 2.0. The test units (the screen copy, the unattended install, the report) are passed in as systemd credentials over SMBIOS, so the ISO and the image carry no test hook.

### Results

Dev VM (`atos-c11`, aarch64, QEMU **without KVM**, AAVMF Secure Boot, swtpm), 7 November 2026:

| Step | Result |
| --- | --- |
| `install` | Installed to an empty 20 GB disk. The installer reported 1,797 s (2,187 s from QEMU start to power-off). TCG emulation is far slower than hardware, so this says nothing about the §7 budget; see the KVM number below |
| `boot` (first) | Secure Boot enabled (user mode, keys enrolled by systemd-boot from `loader/keys/auto`). `atos-tpm-seal`: `/dev/vda2 bound to the TPM with PCR 7`. Keyslots afterwards: `0 tpm2`, `1 recovery`; the unit has removed itself |
| `reboot` | Unlocked by the TPM with no prompt; booted to the report |
| `stage`, `apply` | `bootc upgrade` staged dev-2; the next boot unlocked with no prompt and runs `IMAGE_VERSION=dev-2` (same signing key, so PCR7 is unchanged) |
| `nosb` | Same disk with Secure Boot off: PCR7 differs, the TPM refuses, and the initrd asks for the recovery key |

Repeated after main gained boot counting (#126: `panic=10`, emergency drop-ins, rebuilt initramfs): images rebuilt, `install` (installer 2,311 s under TCG), first `boot` (`bound to the TPM with PCR 7`) and `reboot` (TPM unlock, no prompt) all pass.

No step asks for an online account or a network (D-005); the VM has no network during the install.

**CI on x86_64** (`c11-installer.yml`): Ubuntu's OVMF refuses systemd-boot's enrolment of the TEST keys from `loader/keys/auto` (`Failed to write PK secure boot variable: Security violation`; AAVMF accepts the same files). CI therefore enrols them into the firmware variables after the install with `virt-fw-vars` (`vm-test.sh enrol`), then checks that the first boot runs with Secure Boot on and seals to PCR 7, and that the second unlocks without a prompt. Auto-enrolment by systemd-boot is covered only by the aarch64 dev VM. Real x86 firmware may refuse it the same way; key enrolment at install (#123) has to handle that.

**Install time under KVM** (CI, `c11-installer.yml`, GitHub's amd64 runner, 4 vCPU, payload on the ISO): **105 s** from QEMU start to power-off, live boot included; the installer itself reports 82 s. Budget (§7): 600 s; the job fails above it. Through the interactive installer (#220, run 43022379810, 11 November 2026): **144 s** from QEMU start to the restart, typing included; the installer reports 117 s.

Not yet measured: install time on real hardware, and x86_64 hardware with shim+MOK (PCR 7+14).
