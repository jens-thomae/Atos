# NVIDIA driver in the image

Card: #162 · Decision: D-017 · Write-up: [nvidia-graphics.md](../../decisions/nvidia-graphics.md) · Pins: [`components/c1-base/nvidia/UPSTREAM`](../../../components/c1-base/nvidia/UPSTREAM)

Every Atos image carries NVIDIA's open kernel modules, built by us from source and signed with our Secure Boot key, and NVIDIA's proprietary userspace and GSP firmware, unmodified. Turing and newer NVIDIA GPUs use them. Older NVIDIA GPUs use nouveau with NVK. Machines without an NVIDIA GPU load neither.

## What is in the image

| Part | Where from | Version |
| --- | --- | --- |
| `nvidia.ko`, `nvidia-modeset.ko`, `nvidia-drm.ko`, `nvidia-uvm.ko` in `/usr/lib/modules/<kver>/extra/nvidia/` | Built in the Containerfile's `nvidia` stage from [NVIDIA/open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules), tag and commit pinned | 615.78.08 |
| GL, EGL, GBM, Vulkan, VDPAU (`xorg-x11-drv-nvidia-libs`) | RPM Fusion nonfree, Fedora 45 | 615.78.08-1.fc45 |
| CUDA, NVENC/NVDEC, NVML, OpenCL (`xorg-x11-drv-nvidia-cuda-libs`), `nvidia-smi` (`xorg-x11-drv-nvidia-cuda`) | RPM Fusion nonfree | the same |
| GSP firmware, udev rules, application profiles, licence (`xorg-x11-drv-nvidia`) | RPM Fusion nonfree | the same |
| Suspend and resume services (`xorg-x11-drv-nvidia-power`) | RPM Fusion nonfree | the same |
| `nvidia-modprobe`, `nvidia-persistenced` | RPM Fusion nonfree, built from NVIDIA's open-source repositories | the same |
| NVK (`mesa-vulkan-drivers`) | Fedora | Fedora 45's Mesa |

Not shipped: `nvidia-peermem` (GPUDirect RDMA only), `nvidia-settings` (an X11 GTK tool), the 32-bit (i686) libraries, `akmod-nvidia`. `nvidia-powerd` (Dynamic Boost, laptops) is installed but disabled. RPM Fusion's `70-nvidia.preset` enables it on every machine, both through the package's install scriptlet and when systemd applies presets on first boot. The first VM boot showed it starting. The Containerfile disables it, and our [`60-atos-nvidia.preset`](../../../components/c1-base/usr/lib/systemd/system-preset/60-atos-nvidia.preset) sorts first, so first boot leaves it off. CI checks that it is disabled. Steam and other Flatpak apps get NVIDIA's userspace from Flathub's matching `org.freedesktop.Platform.GL.nvidia` extension, not from the image.

### Package source: RPM Fusion nonfree

The card left the choice between RPM Fusion and NVIDIA's own Fedora repository (write-up §4.4). **RPM Fusion**, because:

- On 2026-11-08 it is the only source with Fedora 45 driver packages. [NVIDIA's fedora45 directory](https://developer.download.nvidia.com/compute/cuda/repos/fedora45/x86_64/) still holds no driver packages.
- Its packages are byte-identical to NVIDIA's. Checked on 2026-11-08: every file RPM Fusion ships that also exists in NVIDIA's own installer (`NVIDIA-Linux-{x86_64,aarch64}-615.78.08.run`, sha256 matching NVIDIA's published `.sha256sum`), compared by sha256. Identical: all libraries, the GSP firmware, `nvidia-smi`, `nvidia-cuda-mps-*`, `nvidia-debugdump`, `nvidia-ngx-updater`, `nvidia-powerd` and the LICENSE (63 files on x86_64, 55 on aarch64). Different: the man pages (recompressed), `nvidia-bug-report.sh` and `nvidia-networking-bug-report.py` (shell and Python scripts RPM Fusion patches), and `nvidia-modprobe` and `nvidia-persistenced`, which RPM Fusion builds from NVIDIA's open-source code. Its spec sets `__strip /bin/true` and installs NVIDIA's files with `install -p` ([spec](https://github.com/rpmfusion/xorg-x11-drv-nvidia/blob/master/xorg-x11-drv-nvidia.spec)).
- The packages are signed. The key is committed as [`RPM-GPG-KEY-rpmfusion-nonfree-fedora-2020`](../../../components/c1-base/nvidia/RPM-GPG-KEY-rpmfusion-nonfree-fedora-2020), fingerprint `79BD B88F 9BBF 7391 0FD4 095B 6A2A F961 9484 3C65`, the one [rpmfusion.org/keys](https://rpmfusion.org/keys) lists for nonfree Fedora 33 to 46.

The build uses the frozen `releases/45` tree and installs exact version-releases, so a build never picks up a newer driver by surprise. The repository is used only during the build (`--repofrompath`). No repository file ends up in the image.

RPM Fusion's packages require `nvidia-kmod` (a module package; our modules replace it) and `nvidia-settings` (left out), so dnf cannot install them. The Containerfile downloads the seven packages and checks their signatures. dnf then installs what they need from Fedora, and `rpm --nodeps` installs the seven. The build fails if any requirement other than those two stays open. grubby is left out on purpose: `xorg-x11-drv-nvidia`'s post-install scriptlet uses it to add `rd.driver.blacklist=nouveau,nova_core modprobe.blacklist=nouveau,nova_core` to GRUB entries. We boot a UKI, and a single image must keep nouveau for older GPUs. Without grubby the scriptlet does nothing.

**aarch64:** RPM Fusion's aarch64 `xorg-x11-drv-nvidia-libs` requires `libnvidia-rmapi-tegra.so`, which no RPM Fusion package provides. NVIDIA ships it in its `.run` installer. The aarch64 build allows that one extra open requirement. CI and release images are amd64 only and aarch64 is the dev VM, so this affects no user. NVIDIA graphics on aarch64 is not supported until that is fixed (#175).

## How the modules are built and signed

The `nvidia` stage (not shipped) starts from the same base image, so it has the exact kernel the image boots:

1. Installs `kernel-devel-<kver>` for exactly the base image's kernel. A kernel that has left Fedora's update repositories still resolves through `fedora-updates-archive`, which the base image ships.
2. Clones the pinned tag and fails unless `HEAD` is the pinned commit and `version.mk` says the pinned version.
3. `make modules`, then for each module: strip debug information, sign with the kernel's `scripts/sign-file` (SHA-512), and fail unless its vermagic starts with the image's kernel version. `nvidia.ko`'s version must equal the pin.

`base` then installs the RPM Fusion packages pinned to the same version and fails unless `rpm -q xorg-x11-drv-nvidia` reports it. So a module built from a different driver version than the userspace, or for a different kernel, cannot reach the image.

**Which key signs.** CI signs with the committed TEST db key, the same key that signs the UKI and systemd-boot. Under D-014 the release key never comes near CI. A release build signs the modules with the release key wherever it signs the UKI, in the owner's local build. That release-build path does not exist yet for the UKI either (#53). When it does, it must replace `/keys/` in the `nvidia` stage as well as in `tools`. Four more signatures per kernel or driver update. The release key verifies modules on B1 and B2 machines (#158, [module-trust.md](module-trust.md)).

## Driver selection in one image

Both drivers' module aliases match every NVIDIA display controller, so on a machine with an NVIDIA GPU udev asks kmod to load both. [`usr/lib/modprobe.d/atos-nvidia.conf`](../../../components/c1-base/usr/lib/modprobe.d/atos-nvidia.conf) makes the order fixed:

```
softdep nouveau pre: nvidia-drm
```

Whenever nouveau is about to load, kmod first loads `nvidia-drm`, which pulls in `nvidia-modeset` and `nvidia`. NVIDIA's open driver probes every NVIDIA GPU and binds those it supports: Turing (GTX 16, RTX 20) and newer. It refuses older GPUs unless `NVreg_OpenRmEnableUnsupportedGpus` is set, which we do not set. Then nouveau loads and binds only GPUs that are still free.

| Machine | Result |
| --- | --- |
| No NVIDIA GPU | No NVIDIA PCI device, so no alias matches: neither driver loads. Mesa as before. |
| Turing or newer | `nvidia`, `nvidia-modeset`, `nvidia-drm` (and `nvidia-uvm`, RPM Fusion's softdep) bind the GPU. nouveau loads and finds nothing to bind. |
| Maxwell, Pascal, Volta, Kepler | `nvidia.ko` finds no supported GPU and its init fails (`No such device`). nouveau binds the GPU, and NVK and Mesa render. |
| Both kinds | Each GPU gets its own driver as above. |

Neither driver is in the initramfs ([`40-atos-nvidia.conf`](../../../components/c1-base/usr/lib/dracut/dracut.conf.d/40-atos-nvidia.conf), checked when the `kernel` stage builds it). In the initrd nouveau would bind a Turing GPU before NVIDIA's driver is available, and the NVIDIA modules would make the UKI change with every driver update. Until the real root is up, simpledrm drives the screen on the firmware's framebuffer. `nvidia-drm fbdev=1` lets `nvidia-drm` take over from simpledrm cleanly, as NVIDIA's README asks. The disk-unlock prompt runs on simpledrm. The base image had no nouveau in its initramfs before this change either (checked on aarch64).

### How it fails safe

kmod ignores a softdep that fails to load. So whatever goes wrong with NVIDIA's driver, nouveau still loads afterwards:

- **The kernel refuses `nvidia.ko`** (signature rejected, wrong kernel): nouveau and NVK drive the GPU.
- **`nvidia.ko` loads but fails on the GPU** (GSP firmware error, probe failure): the GPU is left unbound and nouveau binds it.
- **`nvidia.ko` binds the GPU but misbehaves later** (hangs, black screen after resume): no automatic fallback. The user can force nouveau with a line in `/etc` (writable on a sealed image), then reboot:

  ```sh
  echo 'install nvidia /bin/false' | sudo tee /etc/modprobe.d/atos-no-nvidia.conf
  ```

  Removing the file switches back. The kernel command line is inside the signed UKI, so `modprobe.blacklist=` at the boot menu is not an option.

RPM Fusion's own `nvidia-fallback.service` stays inert: its condition is RPM Fusion's `rd.driver.blacklist=nouveau` kernel argument, which we do not set.

## Configuration

| Setting | Where | Why |
| --- | --- | --- |
| `options nvidia-drm modeset=1 fbdev=1` | `atos-nvidia.conf` | KMS for the compositor, and replacing simpledrm (NVIDIA README, wayland-issues) |
| `options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_TemporaryFilePath=/var/tmp` | `atos-nvidia.conf` | Video memory survives suspend; saved to disk, not tmpfs (NVIDIA README, powermanagement) |
| `nvidia-suspend`, `nvidia-resume`, `nvidia-hibernate`, `nvidia-suspend-then-hibernate` enabled | Containerfile | Needed with `PreserveVideoMemoryAllocations=1`. On a machine without NVIDIA, `nvidia-sleep.sh` finds no `/proc/driver/nvidia/suspend` and does nothing |
| NGX updater off | nothing to configure | `allow_ngx_updater` defaults to false when no config file sets it (NVIDIA README, ngx). No file in the image sets it; CI checks that. A user can still opt in through `~/.config/nvidia-ngx-conf.json` (§2.6, D-005: off by default) |

## Licence

- **NVIDIA's userspace and GSP firmware:** the NVIDIA Driver License Agreement, installed as `/usr/share/licenses/xorg-x11-drv-nvidia/LICENSE` (and again for `-cuda`). It is byte-identical to the `LICENSE` in NVIDIA's 615.78.08 installer.
- **The GSP firmware specifically (write-up §3.2 left this unconfirmed):** `nvidia-kmod-common`, the package that carries the firmware in NVIDIA's own repository, **has no licence file**. Its only licence statement is the RPM header tag `License: NVIDIA License` (checked in `nvidia-kmod-common-620.70.06-1.fc44.noarch.rpm`, sha256 `bd00fd01…5d6d567d`, 2026-11-08). The licence that covers the firmware is therefore the one NVIDIA ships with the same files in its installer: the NVIDIA Driver License Agreement. Its clause 2.1 names firmware explicitly: *"You may only use firmware in NVIDIA Platforms"*. In the image, the firmware (`/usr/lib/firmware/nvidia/615.78.08/`) comes in `xorg-x11-drv-nvidia`, whose licence file is that agreement.
- **Open kernel modules:** MIT/GPL-2.0 (`COPYING` in the source). The exact source the modules are built from is in the published source bundle as `open-gpu-kernel-modules-<tag>.tar.gz` ([README § Corresponding source](README.md#corresponding-source-gpl-d-013-85)).
- **Showing the licence** in the installer and in Settings → About (D-017) is for C11 and C8: #172 and #173.

## CI checks

[`components/c1-base/nvidia/check.sh`](../../../components/c1-base/nvidia/check.sh) runs on every pull request build and before every publish:

1. The image has exactly the four modules. Each is signed by the TEST db key (`modinfo -F signer`) and has the image's vermagic. `nvidia.ko`'s version equals the pin, and so does the userspace.
2. NVIDIA's files are unmodified. The script downloads the seven pinned packages, checks their signatures, and runs `rpm -Vp` against the image: digest, size, mode and owner of every packaged file. Documentation is not installed (`nodocs`) and is skipped.
3. The licence is installed, no file turns on the NGX updater, NVK's ICD is present.
4. The driver-selection softdep, the module options and the suspend services are in place, and `nvidia-powerd` is disabled.

The initramfs check runs when the image is built.

**Dev VM, Secure Boot on:** `tools/dev-vm/sealed.sh nvidia` boots the installed image with the TEST keys enrolled and loads `nvidia-drm` (results below).

## Results

Dev VM `atos-c1` (aarch64, QEMU without KVM, AAVMF Secure Boot firmware), 2026-11-08, image built from this branch: base fedora-bootc 45.20261108.0, kernel 7.2.15-300.fc45, driver 615.78.08.

**Build and CI checks.** The image builds. `nvidia/check.sh` passes:

```
ok: 4 modules signed by the TEST db key, vermagic 7.2.15-300.fc45.aarch64, driver 615.78.08 = userspace
ok: 204 packaged paths match the signed RPM Fusion packages
ok: NVIDIA licence installed, NGX updater not turned on, NVK present
ok: driver selection, module options and suspend services; nvidia-powerd off
```

A copy with one byte appended to `libnvidia-glcore.so.615.78.08` fails it (`S.5…… /usr/lib64/libnvidia-glcore.so.615.78.08`). `check-seal.sh` passes.

**Secure Boot load** (`sealed.sh disk`, then `sealed.sh nvidia`; run on the build before the `nvidia-powerd` fix, which does not touch the modules). The TEST keys were enrolled in setup mode and the sealed UKI booted to `graphical.target` with lockdown `[integrity]`:

| Check | Result |
| --- | --- |
| NVIDIA or nouveau modules loaded at boot (no NVIDIA GPU in the VM) | none |
| `modinfo -F signer` of all four | `Atos TEST db - not for release, do not trust` |
| `modprobe nvidia-drm` | `could not insert 'nvidia_drm': No such device` |
| Kernel log | `nvidia: loading out-of-tree module taints kernel.`, `NVRM: No NVIDIA GPU found.` |

The kernel checks the signature before a module's init runs, and `nvidia.ko`'s init ran and reported that it found no GPU. So under Secure Boot with lockdown, the kernel accepted the module signed with the db key. A rejected signature would have stopped at `Key was rejected by service` (#158 showed that path).

**Image size** (aarch64, compressed layer sizes in the VM's registry, as measured for #111):

| | Before (`main` at e846e3a) | After |
| --- | --- | --- |
| Compressed | 80 layers, 1390.2 MB | 81 layers, 1877.0 MB (**+486.8 MB**, one layer) |
| Uncompressed | 2.84 GB | 4.06 GB (+1.21 GB) |

Installed size by package: `xorg-x11-drv-nvidia-cuda-libs` 497 MB, `-libs` 306 MB, `xorg-x11-drv-nvidia` (GSP firmware, profiles) 186 MB, `mesa-vulkan-drivers` (NVK and the other Mesa Vulkan drivers) 131 MB, `-cuda` 8 MB, `-power` 5 MB, the four modules 28 MB. The UKI does not change, because no NVIDIA module is in the initramfs. **Updates:** the publish job builds every image from scratch (no layer cache, #86), so the NVIDIA layer gets a new digest in every published image. Clients then download it again with each update, as they already do the 221 MB session package layer. Splitting the layer would not help until builds are reproducible. amd64 sizes were not measured. The amd64 packages are of similar size, and the write-up estimated 300–450 MB compressed.

**Not covered here:** a real NVIDIA GPU (rendering, suspend, monitors): the smoke test below. amd64 and real firmware: CI builds and checks amd64, but nothing boots it with Secure Boot.

## Smoke test on the owner's RTX 4070 Ti (per release)

D-017: a kernel or driver update ships only after this passes on the owner's machine. Install or `bootc switch` to the candidate image with Secure Boot on, then:

1. **Boot to the desktop.** `bootctl status | grep 'Secure Boot'` shows `enabled (user)`.
2. **The right driver is bound.** `lsmod | grep -E '^(nvidia|nouveau)'` lists `nvidia_drm`, `nvidia_modeset`, `nvidia_uvm`, `nvidia`, and `nouveau` with use count 0. `cat /proc/driver/nvidia/version` shows `Open Kernel Module` and the pinned version. `journalctl -k -b | grep -iE 'NVRM|nvidia'` has no errors or `taint` warnings other than the out-of-tree note.
3. **Options are applied.** `cat /sys/module/nvidia_drm/parameters/{modeset,fbdev}` prints `Y` twice. `grep -E 'PreserveVideoMemoryAllocations|TemporaryFilePath' /proc/driver/nvidia/params` shows `1` and `"/var/tmp"`. `ls /sys/class/drm/` has no simpledrm card left.
4. **`nvidia-smi`** shows the RTX 4070 Ti, driver 615.78.08 and a sensible temperature and power draw at idle.
5. **Budgets.** `budgets <app> --cpu-window full` (docs/budgets.md); record the numbers on the release card. They are manual until #67 provides test hardware.
6. **Two monitors.** Connect both; both show the desktop at their native mode and refresh rate; drag a window across.
7. **Suspend and resume.** `systemctl suspend`, wake with a key: the desktop returns on both monitors, with no black screen or corruption (cosmic-comp #2955). `journalctl -b -u nvidia-suspend -u nvidia-resume` shows both ran.
8. **A Vulkan game** (Steam Flatpak, a Proton title) runs. Its GPU process appears in `nvidia-smi`.
9. **Fallback.** `echo 'install nvidia /bin/false' | sudo tee /etc/modprobe.d/atos-no-nvidia.conf`, reboot: the desktop comes up on nouveau (`lsmod` shows `nouveau` in use, no `nvidia`). Remove the file and reboot: back on NVIDIA.
10. **NGX updater off.** `ls ~/.config/nvidia-ngx-conf.json /usr/share/nvidia/nvidia-ngx-conf.json` finds nothing.

A failure in steps 1–4, 6, 7 or 9 holds the update. Record the result on the release card.
