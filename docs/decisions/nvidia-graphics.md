# How Atos supports NVIDIA graphics (decision write-up)

Card: #153 · Written: 2026-11-08 · **Decided as D-017 on 2026-11-08** (card #161): the owner chose a single image for everyone over the variant recommended below. This write-up ends in a recommendation for the owner ([section 5](#5-recommendation-for-the-owner-to-decide)). It decides nothing. No image was built and no NVIDIA hardware was used for it.

Every statement about a driver, package, licence or kernel links the upstream page or file it comes from. All of them were opened on 2026-11-08. **Read in code** means I read the source but did not run it. **Not checked** means I found no source either way. **Unconfirmed** marks a claim from a secondary source, or one I could not confirm upstream.

## 1. Context

### 1.1 What the owner asked

- The owner has an NVIDIA machine and requires good NVIDIA support (card #153, 2026-11-08).
- The owner prefers **NVIDIA's proprietary driver**, because it works best on Linux. If the licence forbids shipping it in the image, it should be offered as a separate install after setup (planner's comment on #153).
- Intel and AMD are out of scope: Mesa in Fedora covers them.

### 1.2 Constraints from other decisions

- **D-005** No telemetry, no call home.
- **D-006** Slint with the GPU renderer. The shell links Slint with `renderer-femtovg` ([`components/c3-shell/Cargo.toml`](../../components/c3-shell/Cargo.toml)), which draws with OpenGL ES.
- **D-007** Our cosmic-comp fork is C2. No upstream contributions: every fix is a patch we carry.
- **D-008** Sealed composefs image on `fedora-bootc:45`. The kernel and initramfs are inside the signed UKI; `/usr` is verified by the composefs digest. There is no package layering on a sealed image, and no compiler at runtime.
- **D-013** Our source is MIT OR Apache-2.0. Third-party parts of the image carry their own licence and must be redistributable in a public image.
- **D-014 / D-016** Secure Boot with the Atos release cert in db (B1), or as a non-CA MOK under Fedora's shim with `MokListTrusted` off (B2). Release keys are on offline hardware tokens; the owner builds release images locally; CI holds only test keys. D-014 records the kernel module key as *"Fedora's … ephemeral per build"* ([D-014 write-up](D-014-signing-keys.md)), so we cannot sign anything with it.
- **§3** v1 certifies a short hardware list and documents the rest as best effort.
- **§7** Budgets are measured on the NUC (Intel graphics). No budget is measured on NVIDIA today.

## 2. The three options

### 2.1 Option A: the open Mesa stack (nouveau + NVK, Zink for OpenGL)

What Fedora ships by default.

- **Kernel:** nouveau (GPL, in the Fedora kernel).
- **Vulkan:** NVK. *"NVK currently supports Kepler (GeForce 600 and 700 series) and later GPUs"* and *"is a conformant Vulkan 1.4 implementation for all officially supported GPUs"*; it needs Linux 6.6 or newer ([NVK docs](https://docs.mesa3d.org/drivers/nvk.html)).
- **OpenGL:** on Turing and newer, Mesa uses Zink on NVK by default (same page). That default arrived in Mesa 25.1.0: *"load zink as the GL driver for turing and above"* ([25.1.0 release notes](https://docs.mesa3d.org/relnotes/25.1.0.html)).
- **Pre-Turing performance:** the nouveau feature matrix lists power management as WIP for Maxwell and TODO for Pascal ([FeatureMatrix](https://nouveau.freedesktop.org/FeatureMatrix.html)). Without reclocking, these GPUs run at boot clocks. The usual reason given, NVIDIA-signed firmware, comes only from secondary sources (**unconfirmed**).
- **Nova**, the new Rust kernel driver, *"intends to supersede the nouveau driver"* for GSP-based GPUs ([kernel docs](https://docs.kernel.org/gpu/nova/index.html)). No source says it is usable for display or rendering yet (**unconfirmed**).
- **No CUDA**, no DLSS.
- **Our image today:** the [Containerfile](../../components/c1-base/Containerfile) installs `mesa-dri-drivers` but not the Vulkan drivers, so NVK is not in the image. What an NVIDIA GPU gets on Atos today is **not checked**.

### 2.2 Option B: NVIDIA's open kernel modules + NVIDIA's proprietary userspace

What the owner prefers ("the proprietary driver"). Since R560, this is what NVIDIA itself installs by default on GPUs that support it.

- **Current driver:** 620.70.06, tagged *"Latest"* on 5 November in [open-gpu-kernel-modules releases](https://github.com/NVIDIA/open-gpu-kernel-modules/releases). Other live branches in the [download tree](https://download.nvidia.com/XFree86/Linux-x86_64/): 615, 610, 595, 580. Which one NVIDIA labels Production Branch is **not checked**.
- **GPUs:** the open modules *"can be used on any Turing or later GPU"* and must run with GSP firmware ([repository README](https://github.com/NVIDIA/open-gpu-kernel-modules)). The 620 README: *"We recommend the use of open kernel modules on all GPUs that support it"*, and *"Blackwell and later are only supported by the open kernel modules"* ([kernel_open](https://download.nvidia.com/XFree86/Linux-x86_64/620.70.06/README/kernel_open.html)).
- **Default since R560:** [NVIDIA blog, 2024-07-17](https://developer.nvidia.com/blog/nvidia-transitions-fully-towards-open-source-gpu-kernel-modules/).
- **The closed kernel module** in 620 supports *"Turing, Ampere, Ada, and Hopper"* only (same README page). The README lists what each flavour has over the other ([kernel_open](https://download.nvidia.com/XFree86/Linux-x86_64/620.70.06/README/kernel_open.html)). Only the open flavour has five compute features (Confidential Computing, GPUDirect Storage, HMM, CPU affinity for GPU fault handlers, DMABUF for CUDA allocations). The closed flavour's advantages exist only *"with GSP firmware mode disabled"*: faster GPU initialization, shorter S3, S4 and RTD3 enter and exit latencies, marginally lower power in some scenarios, and more than the Video Memory Off flavour of RTD3 on Turing. Whether those differences matter on a desktop is **not checked**. This write-up does not consider the closed flavour for Turing+, because the open flavour is NVIDIA's recommendation and Blackwell's only option.
- **Userspace** (OpenGL/EGL, Vulkan, CUDA, NVENC/NVDEC, GBM) is closed and the same for both module flavours.
- **CUDA and gaming:** full CUDA, DLSS through NGX. NGX's updater downloads model updates, but `allow_ngx_updater` is *"defaulting to false"* ([README ngx.html](https://download.nvidia.com/XFree86/Linux-x86_64/620.70.06/README/ngx.html), also in the package). It must stay off (D-005).

### 2.3 Option C: a mix by GPU generation

Older GPUs cannot use the open modules, and 620 dropped them from the closed module too:

- **Maxwell, Pascal, Volta** (GTX 900, GTX 10, TITAN V) appear only under the 580.xx list in the 620 [supported chips](https://download.nvidia.com/XFree86/Linux-x86_64/620.70.06/README/supportedchips.html) page: *"These GPUs will continue to be maintained through the special legacy NVIDIA GPU driver releases."* So they need the **580xx legacy branch with the closed kernel module**. How long NVIDIA maintains 580 is **unconfirmed** (secondary sources only).
- **Kepler and older:** 470xx/390xx legacy branches, which RPM Fusion still builds, or nouveau. This write-up treats them as nouveau-only.
- **Turing and newer:** Option B.

A mix means one of: separate images per driver branch, or one image carrying several userspace branches. RPM Fusion packages the 580xx userspace as a separate package set (`xorg-x11-drv-nvidia-580xx`, [f45 tree](https://download1.rpmfusion.org/nonfree/fedora/releases/45/Everything/x86_64/os/Packages/x/)). Whether it installs next to the 615/620 userspace is **not checked**; I assume it does not, since both provide the same libraries.

## 3. Comparison

### 3.1 GPUs, compositor, toolkit and features

| | A: nouveau + NVK | B: NVIDIA open modules + proprietary userspace | C: B for Turing+, 580xx closed for Maxwell–Volta |
| --- | --- | --- | --- |
| GPU generations | Kepler and later ([NVK](https://docs.mesa3d.org/drivers/nvk.html)); slow before Turing (no reclocking) | Turing and later, incl. Blackwell | Maxwell and later |
| Wayland, our cosmic-comp fork | Mesa GBM/EGL, the path smithay is built on | *"The NVIDIA driver includes a GBM backend"* for GBM-based compositors; it needs DRM KMS, Mesa 21.2+ `libgbm` and egl-wayland 1.1.8+ ([gbm](https://download.nvidia.com/XFree86/Linux-x86_64/620.70.06/README/gbm.html)). Explicit sync (DRM syncobj timelines) is supported and needs kernel 6.8+ ([wayland-issues](https://download.nvidia.com/XFree86/Linux-x86_64/620.70.06/README/wayland-issues.html)); Fedora 45 has 7.3.3. Version history, from secondary sources only: GBM since [495.44](https://www.gamingonlinux.com/2021/10/nvidia-49544-stable-driver-is-out-for-linux-adds-in-gbm-api-support), `linux-drm-syncobj-v1` since [555.42.02](https://gamingonlinux.com/2024/05/nvidia-555-42-02-beta-driver-out-bringing-wayland-explicit-sync). Smithay [implements](https://raw.githubusercontent.com/Smithay/smithay/master/src/wayland/drm_syncobj/mod.rs) syncobj, and our fork has `src/wayland/handlers/drm_syncobj.rs` | Same as B; 580 also has GBM and explicit sync (both predate it) |
| Known compositor issues | **Not checked** | Upstream cosmic-comp, open: VRAM grows on NVIDIA because framebuffers are deleted on the wrong GL context ([#3037](https://github.com/pop-os/cosmic-comp/issues/3037)); black screen after S3 resume, RTX 3080 ([#2955](https://github.com/pop-os/cosmic-comp/issues/2955)). NVIDIA README: `nvidia-drm` needs `fbdev=1` or simpledrm may stay, causing *"black screen, corruption, or flickering"*; `COLOR_ENCODING`/`COLOR_RANGE` plane properties are unsupported ([wayland-issues](https://download.nvidia.com/XFree86/Linux-x86_64/620.70.06/README/wayland-issues.html)). Whether our fork still has #3037 is **not checked** | Same as B, plus untested legacy branch |
| Slint GPU renderer (FemtoVG, GL ES) | GL through Zink on NVK (Turing+) or nouveau GL. **Not checked** | GL through NVIDIA's EGL. Two NVIDIA Slint issues, both closed and both on other renderers: Skia on GNOME ([#4828](https://github.com/slint-ui/slint/issues/4828)) and wgpu ([#9941](https://github.com/slint-ui/slint/issues/9941)). None found for FemtoVG. **Not tested** | Same as B |
| Suspend/resume | **Not checked** | Needs `NVreg_PreserveVideoMemoryAllocations=1` plus `nvidia-suspend`, `nvidia-hibernate` and `nvidia-resume` services ([powermanagement](https://download.nvidia.com/XFree86/Linux-x86_64/620.70.06/README/powermanagement.html)); S0ix supported. See #2955 above | Same as B |
| Multi-monitor | **Not checked** | Upstream issue: capturing an output on a second NVIDIA GPU fails ([#2954](https://github.com/pop-os/cosmic-comp/issues/2954)). Single-GPU multi-monitor: **not checked** | Same as B |
| Hybrid laptops (iGPU + NVIDIA dGPU) | Mesa PRIME, **not checked** | cosmic-comp picks the render GPU from `COSMIC_RENDER_DEVICE`, else the GPU driving the built-in display ([kms/mod.rs](https://raw.githubusercontent.com/pop-os/cosmic-comp/master/src/backend/kms/mod.rs); same code in our fork, `src/backend/kms/mod.rs:245`). Open: lag with the external monitor on the dGPU ([#3016](https://github.com/pop-os/cosmic-comp/issues/3016)). PRIME offload for apps is documented with `__NV_PRIME_RENDER_OFFLOAD=1`, for X.Org only ([primerenderoffload](https://download.nvidia.com/XFree86/Linux-x86_64/620.70.06/README/primerenderoffload.html)); Wayland: **unconfirmed**. NVIDIA: *"no established public API"* for compositors to power off video memory via RTD3 ([wayland-issues](https://download.nvidia.com/XFree86/Linux-x86_64/620.70.06/README/wayland-issues.html)) | Same as B |
| CUDA | No | Yes | Yes |
| Gaming | Vulkan 1.4; no DLSS | Full, DLSS | Full on Turing+; 580 on older |

### 3.2 Licence and redistribution in a public image (D-013)

I read the licence files from the current packages, not from memory:

- **NVIDIA userspace and GSP firmware:** `/usr/share/licenses/nvidia-driver/LICENSE` from `nvidia-driver-620.70.06-1.fc44.x86_64.rpm` in [NVIDIA's Fedora 44 repo](https://developer.download.nvidia.com/compute/cuda/repos/fedora44/x86_64/) (SHA-256 `eb5dcd32…7525ab25c`). Title *"NVIDIA Driver License Agreement"*, version *"(v. February 25, 2025)"*, the same version as [nvidia.com/drivers/nvidia-license](https://www.nvidia.com/en-us/drivers/nvidia-license/). The GSP firmware ships as `/usr/lib/firmware/nvidia/620.70.06/gsp_*.bin` in `nvidia-kmod-common` (header read, payload not downloaded). That the GSP firmware falls under this same agreement is **unconfirmed**: I did not read a licence file from `nvidia-kmod-common`. The agreement's 2.1 speaks of *"firmware"*, which suggests it covers firmware shipped with the driver.
- **NVIDIA open kernel modules:** `COPYING` from `kmod-nvidia-open-dkms-620.70.06-1.fc44.noarch.rpm`, same repo. Files are MIT; *"when linked together to form a Linux kernel module, the resulting Linux kernel module is dual licensed as MIT/GPLv2."* Same text in the [repository](https://raw.githubusercontent.com/NVIDIA/open-gpu-kernel-modules/main/COPYING).

What the NVIDIA Driver License Agreement allows and requires, by clause:

| Clause | Text (abridged) | What it means for Atos |
| --- | --- | --- |
| 1.1(d) | May *"Distribute the SOFTWARE provided for use with operating system kernels"* under an OSI-approved licence, provided *"the binary files thereof are not modified in any way"* (uncompressing excepted) and *"this Agreement is provided to each SOFTWARE recipient"* | **Shipping the unmodified driver in a public Linux image is allowed.** We must ship the licence text with it. Whether a file in `/usr/share/licenses` counts as "provided", or the installer must show it, is a question for a lawyer |
| 1.1(b) | May modify *"any portion of the SOFTWARE delivered by NVIDIA in source code format"* | The source parts (the closed module's kernel-interface layer) may be patched |
| 2.3 | May not modify the binary form | Repackaging is fine; changing binaries is not |
| 2.8 | GeForce software *"is licensed for use only on GeForce or Titan hardware products you own"*, not datacenter | My reading: it binds the user, not us; worth one line in our licence notice. Not legal advice |
| 2.9 | May not cause the software to become subject to an open-source licence | Relevant only to the closed kernel module (below) |
| 2.11 | Indemnify NVIDIA for claims *"arising out of or related to products or services that have been developed with or use the SOFTWARE"* | **A distributor obligation the owner should weigh.** Not legal advice |
| 1.1, 7 | Licence is *"revocable"* and ends on breach; *"Your prior distributions … are not affected"* | A breach would stop future releases, not past ones |
| 13 | Data collection applies *"on a Windows operating system"* | Nothing for Linux; NGX updater is off by default (section 2.2) |

Per option:

| | Licence | Public image |
| --- | --- | --- |
| A | Mesa MIT; nouveau GPL-2.0; NVIDIA GSP firmware for nouveau comes from Fedora's firmware packages (their licence text **not read** today) | Yes. Fedora already redistributes all of it |
| B, kernel | Open modules MIT/GPL-2.0 (read above). We may build, patch, sign and ship prebuilt modules | Yes |
| B, userspace + GSP firmware | NVIDIA Driver License Agreement | Yes, unmodified, with the licence text, subject to 2.11 |
| C, 580xx closed module | Same NVIDIA licence, but the built `nvidia.ko` links NVIDIA's binary object into a module for a GPL kernel, and we would append our signature to it | **Unclear.** Two open questions for a lawyer: does a prebuilt closed module conflict with the kernel's GPL or with clause 2.9, and is a signed `.ko` a "modified" binary under 2.3? Precedents exist: Ubuntu ships prebuilt closed and open modules as [`linux-modules-nvidia-580`](https://packages.ubuntu.com/search?keywords=linux-modules-nvidia-580&searchon=names&suite=all&section=all) and `-open`, and RPM Fusion ships prebuilt `kmod-nvidia` for RHEL ([Howto/NVIDIA](https://rpmfusion.org/Howto/NVIDIA)). Pop!_OS publishes a separate NVIDIA ISO ([System76](https://system76.com/support/articles/install-pop/)), with the driver preinstalled (**unconfirmed** which module flavour) |

**So the owner's fallback ("install it after setup") is not forced by the licence** for Turing and newer. It may still be the better product choice; see 4.1.

## 4. Image fit

### 4.1 How the driver gets into a sealed image

A sealed bootc image cannot install packages or build modules at runtime: `/usr` is verified by the composefs digest in the signed UKI, and the image has no compiler. So both "in the image" and "after setup" mean **an image we build and sign**:

- **Single image:** every Atos image carries the NVIDIA userspace and modules. Users without NVIDIA download them too.
- **NVIDIA variant image** (`atos-nvidia`): the same Containerfile with one more stage. The installer (C11) picks it when it detects an NVIDIA GPU; a user who adds an NVIDIA card later switches to it with `bootc switch` (from Settings, C8). This is what "install after setup" becomes on a sealed system. Universal Blue builds per-driver images the same way, from separate akmods images built for each kernel flavour ([ublue-os/akmods](https://github.com/ublue-os/akmods)); Pop!_OS has its NVIDIA ISO.
- **Runtime build (akmods)**, as RPM Fusion does on ordinary Fedora and on OSTree with a *"special 'Hack'"* for Secure Boot ([Howto/NVIDIA](https://rpmfusion.org/Howto/NVIDIA)), does not work on a sealed image. Developer mode (D-015) could rebuild locally, but that is not a product path.
- **systemd-sysext** extension images are another theoretical way to add `/usr` content. How a signed sysext fits our sealed setup is **not checked**; I do not recommend it without a spike.

The [Fedora bootc NVIDIA proof of concept](https://github.com/coreos/fedora-bootc-nvidia) builds the open modules with DKMS against the image's kernel. It is marked *"Work In Progress"*, and its [forum thread](https://discussion.fedoraproject.org/t/enabling-gpus-on-fedora-with-image-mode-fedora-bootc/170247) says Secure Boot fails because the modules are self-signed.

Build sketch for the variant (not built, for sizing the work only):

1. A non-shipped stage `FROM base` installs `kernel-devel` for exactly `$(ls /usr/lib/modules)` and builds the open modules from NVIDIA's source tag that matches the userspace version (the module and userspace versions must match exactly). Building from the MIT/GPL source, not from a vendor's prebuilt module, lets us carry our own patches when a new Fedora kernel breaks the build (D-007 style).
2. The stage signs each `.ko` with `scripts/sign-file` from `kernel-devel` (test key in CI, release key in the owner's local release build), and only the signed `.ko` files are copied into the image. `sign-file` reads `pkcs11:` key URIs through OpenSSL's PKCS#11 provider or engine ([sign-file.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/scripts/sign-file.c)). Whether that works with the owner's release token (D-014: a YubiKey or similar) and Fedora's `kernel-devel` build of `sign-file` is **not checked**. The open driver builds four modules (`nvidia`, `nvidia-modeset`, `nvidia-drm`, `nvidia-uvm`, per its [README](https://github.com/NVIDIA/open-gpu-kernel-modules); `nvidia-peermem` is only for GPUDirect RDMA and need not ship). So the owner's offline signing grows by four signatures per kernel bump or driver update.
3. The userspace comes from a package repository (4.4) into its own layer. The NVIDIA licence goes into `/usr/share/licenses`.
4. `nouveau` and `nova_core` are blocked in the variant (RPM Fusion's OSTree recipe blocks both: `rd.driver.blacklist=nouveau,nova_core`, [Howto/NVIDIA](https://rpmfusion.org/Howto/NVIDIA)). In a sealed UKI the kernel command line is baked in, so a `modprobe.d` file is the simpler place. In a **single** image this is harder: nouveau must still bind GPUs the NVIDIA driver does not support, which needs udev logic we do not have. That is one more reason for the variant.
5. `nvidia-drm.modeset=1 fbdev=1` and `NVreg_PreserveVideoMemoryAllocations=1` in `modprobe.d`, and the suspend services enabled.
6. The NVIDIA modules stay **out of the initramfs**, so the UKI does not grow. Until `nvidia-drm` loads, simpledrm drives the screen; that is the case the README's `fbdev=1` note covers. Plymouth and early-boot visuals with this setup are **not checked**.

### 4.2 Secure Boot: module signing under D-014 and D-016

Fedora's kernel enforces signed modules under Secure Boot. The question is which keys it accepts. I checked the Fedora 45 kernel itself: dist-git branch `f45` builds `linux-7.3.3` ([sources](https://src.fedoraproject.org/rpms/kernel/raw/f45/f/sources)).

- **Lockdown:** `CONFIG_LOCK_DOWN_IN_EFI_SECURE_BOOT=y` in both the [x86_64](https://src.fedoraproject.org/rpms/kernel/raw/f45/f/kernel-x86_64-fedora.config) and [aarch64](https://src.fedoraproject.org/rpms/kernel/raw/f45/f/kernel-aarch64-fedora.config) configs. Fedora's patch calls `security_lock_kernel_down("EFI Secure Boot mode", LOCKDOWN_INTEGRITY_MAX)` ([patch-7.3-redhat.patch](https://src.fedoraproject.org/rpms/kernel/raw/f45/f/patch-7.3-redhat.patch)). Under lockdown, unsigned modules are refused.
- **Which keys verify a module:** mainline checks only the secondary keyring ([kernel/module/signing.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/kernel/module/signing.c)). **Fedora's kernel adds a fallback to the platform keyring** when that fails with `-ENOKEY` (same patch file; kernel-ark commit *"KEYS: Make use of platform keyring for module signature verify"*, [kernel-ark signing.c](https://gitlab.com/cki-project/kernel-ark/-/raw/os-build/kernel/module/signing.c)). `CONFIG_INTEGRITY_PLATFORM_KEYRING=y` in both configs. The platform keyring holds the UEFI db certs ([load_uefi.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/security/integrity/platform_certs/load_uefi.c)) and, under Secure Boot, the non-CA MOK certs (the #76 spike saw the Atos TEST cert land there, [shim-mok-spike.md](../components/c1-base/shim-mok-spike.md)).

So, **read in code, not booted** (booted since, and confirmed for B1 and B2, by #158: [module-trust.md](../components/c1-base/module-trust.md)):

- **B1 (D-014):** a module signed with the Atos release key, whose cert is in db, loads on Fedora's stock kernel. No kernel rebuild and no new key in the kernel.
- **B2 (D-016):** the Atos cert is a non-CA MOK, which goes to the platform keyring, so the same signed module loads there too. `MokListTrusted` off does not change this, because that switch governs the machine keyring, not the platform keyring.
- **Developer mode (D-015):** the developer db key would also verify modules, so a developer image can carry its own modules.

Two consequences for the owner:

1. **Signing moves into the release build.** Every NVIDIA variant release needs its modules signed with the release key, on the owner's offline token, next to the UKI: four signatures per kernel bump or driver update (4.1 step 2). A separate module-signing cert in db would **not** be a weaker key. Anything in db is also a firmware boot trust anchor: the firmware starts any EFI binary or UKI that cert signs. So a "module-only" key could sign a boot chain, and it would need the same offline handling as the release key. Adding it through the per-machine KEK also changes **PCR7** on every machine, so the TPM stops releasing the disk key: users get the recovery-key prompt and must rebind (see [secure-boot-off-and-on.md](../components/c1-base/secure-boot-off-and-on.md), #107). The choice is between one key and two keys of equal power, not between a powerful key and a limited one.
2. **A security finding outside this card.** [shim-mok-spike.md](../components/c1-base/shim-mok-spike.md) says the platform keyring *"is not trusted for modules"*. Reading Fedora's kernel code, it is: every db cert (on B1 that includes the Microsoft Option ROM CA, D-014) and every MOK can verify kernel modules. Under the fallback, a module whose PKCS#7 signature chains to one of the Microsoft CAs in B1's db (Option ROM UEFI CA 2023, and UEFI CA 2011 where present) would verify too: a Microsoft-held key, and theoretical. Filed as #158, which checks all of this on a booted kernel; this write-up does not repeat those checks.

### 4.3 Image size

The current image is 2.84 GB uncompressed and 1390 MB compressed (aarch64 dev VM, [c1-base README](../components/c1-base/README.md#image-and-update-size-111)).

Compressed RPM sizes from the [RPM Fusion Fedora 44 updates tree](https://download1.rpmfusion.org/nonfree/fedora/updates/44/x86_64/), driver 615.78.08 (the Fedora 45 tree carries the same version; I did not list its sizes):

| Package | Compressed | Needed for |
| --- | --- | --- |
| `xorg-x11-drv-nvidia` | 133 MB | the driver |
| `xorg-x11-drv-nvidia-libs` | 100 MB | GL/Vulkan libraries |
| `xorg-x11-drv-nvidia-cuda-libs` (x86_64 / i686) | 92 / 75 MB | CUDA; i686 for 32-bit games (Steam runs as a Flatpak, so whether we need i686 in the image is **not checked**) |
| `xorg-x11-drv-nvidia-kmodsrc` | 90 MB | build stage only, not shipped |
| GSP firmware (`nvidia-kmod-common` in NVIDIA's repo) | 64 MB | Turing+ |

So the variant adds roughly **300 to 450 MB compressed**, depending on CUDA and 32-bit. Installed size is **not measured**. Updates: bootc fetches only changed layers, so the userspace layers download again only when the driver version changes. The module layer changes with every kernel bump and should be small (**not measured**). The UKI does not change size if the modules stay out of the initramfs.

### 4.4 Package source and kernel lockstep

| | RPM Fusion nonfree | NVIDIA's Fedora repository |
| --- | --- | --- |
| Fedora 45 today | `xorg-x11-drv-nvidia` and `akmod-nvidia` 615.78.08, plus `-580xx` 580.196.07 ([f45 tree](https://download1.rpmfusion.org/nonfree/fedora/releases/45/Everything/x86_64/os/Packages/x/)) | The [fedora45 directory](https://developer.download.nvidia.com/compute/cuda/repos/fedora45/x86_64/) exists but holds no driver packages yet (DCGM only, 2026-11-07) |
| Latest version | Spec at 620.70.06 ([nvidia-kmod.spec](https://raw.githubusercontent.com/rpmfusion/nvidia-kmod/master/nvidia-kmod.spec)); Fedora 45 builds at 615 | 620.70.06 for Fedora 44 ([fedora44](https://developer.download.nvidia.com/compute/cuda/repos/fedora44/x86_64/)) |
| Legacy branches | 580xx, 470xx, 390xx | No 580 packages in the fedora44 directory |
| Module | `akmod-nvidia` builds both flavours and picks open by default on Turing+ ([Howto/NVIDIA](https://rpmfusion.org/Howto/NVIDIA)) | DKMS (`kmod-nvidia-open-dkms`), per [NVIDIA's Fedora guide](https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/fedora.html) |
| Who maintains it | Community | NVIDIA |

Either way we would build the module ourselves (4.1) and use the repository only for userspace.

**Lockstep with Fedora kernels.** A module works only with the exact kernel it was built for. Because the image pins the base image by digest and builds the module against that image's kernel, a mismatched module cannot ship: the build fails instead. The real risk is the other direction. A new Fedora kernel can break the NVIDIA build until NVIDIA or we patch it. Then the NVIDIA variant has to hold the base bump, while the other images move on. That needs a rule (open question 6).

## 5. Recommendation (for the owner to decide)

**Flag for the owner: this is a recommendation, not a decision.**

1. **Turing and newer (GTX 16, RTX 20 and later, incl. Blackwell): Option B, shipped as an NVIDIA variant image.** NVIDIA's open kernel modules, built from source in our Containerfile and signed with the Atos release key, plus NVIDIA's proprietary userspace from RPM Fusion. The installer picks the variant on NVIDIA hardware; Settings offers the switch later. The NVIDIA licence allows shipping the unmodified driver, so no post-setup download from NVIDIA is needed.
2. **Maxwell, Pascal and Volta: Option A (nouveau + NVK) as best effort**, documented as slow. Not the 580xx closed module, until the owner has a legal answer on prebuilt closed modules and knows how long NVIDIA keeps 580 alive.
3. **Every image gets NVK** (Mesa's Vulkan drivers), so an NVIDIA GPU still gets a working desktop without the variant, and the variant has a fallback if its module fails to load. Whether the base image gets Mesa's Vulkan drivers for AMD and Intel as well is not this card's decision.
4. **A kernel bump never ships in the NVIDIA variant until its module builds and the owner's machine passes the smoke test** (section 6).

Why, in the §2 priority order:

- **Performance and stability:** NVIDIA's userspace is the only path with full performance, CUDA and DLSS on current GPUs. The open modules are what NVIDIA recommends and the only option for Blackwell. Building them from MIT/GPL source means a kernel break is a patch we can carry, not a wait for a vendor.
- **Ownership (§2.6):** no download from NVIDIA after setup, no NVIDIA account.
- **Trust, conditional on #158:** module signing works with D-014 and D-016 without a kernel rebuild and with no trust anchor *beyond the ones #158 found* (4.2). But the recommended signing path **relies on** the behaviour #158 is investigating: Fedora's kernel trusts every db cert and every non-CA MOK for modules, which also means D-016's `MokListTrusted` off does not stop MOK-signed modules. If the owner decides to close that path, only two routes remain: a CA MOK in `.machine`, which D-016 forbids, or a kernel built with our key built in, which is no longer Fedora's stock kernel. The recommendation is therefore conditional on #158's outcome (open question 9).
- **Why a variant, not one image:** AMD and Intel users do not download 300–450 MB they never use; nouveau stays available for GPUs the NVIDIA driver does not support; and a broken NVIDIA build can hold back only the variant. The cost: two images per release for the owner to build, sign and test.

**When to pick the alternatives instead:**

- **One image for everyone,** if the owner values one image over download size. Then budget for the nouveau/nvidia selection logic (4.1 step 4), and for every kernel bump waiting on NVIDIA.
- **580xx variant for Maxwell–Volta,** if the owner's own GPU is in that range, or legal advice clears prebuilt closed modules.
- **Option A only,** if the owner does not accept the NVIDIA licence (2.11 indemnity, non-free code in a public image).

## 6. How we test it without owning every GPU

What CI can cover (hosted runners have no GPU; the NUC has Intel graphics):

- **Build:** the variant builds; each `.ko` has the expected signer (`modinfo -F signer`) and a vermagic equal to the image's kernel; the module and userspace versions match; the licence file is present; `allow_ngx_updater` is not enabled.
- **Trust chain:** boot the variant in the dev VM with Secure Boot and the TEST keys, then `modprobe nvidia`. Without a GPU the module cannot bind, but the signature check runs first: a "key rejected" error would mean a broken chain, "no device" would mean it passed. Whether `nvidia.ko` fails cleanly with no GPU is **not checked**. Which certs the kernel trusts in general is #158's job; this check only confirms that our variant's modules load under our own chain.
- **No regression for others:** the existing budget jobs keep running on the NUC with the non-NVIDIA image.

What CI cannot cover: rendering, frame pacing, the §7 budgets on NVIDIA, suspend/resume, multi-monitor, hybrid laptops, games and CUDA. These need real hardware:

- **The owner's NVIDIA machine** is the reference for now. A per-release smoke test: boot to the desktop, budgets tool with `--cpu-window full`, two monitors, suspend and resume, a Vulkan game, `nvidia-smi`. The GPU model decides whether it covers Option B at all (open question 1).
- **Test hardware card #67:** a Turing-or-newer desktop card in a test box, and an Intel + NVIDIA hybrid laptop, would cover most users. A pre-Turing card only if the owner picks the 580xx path.
- **§7 gap:** budgets are release blockers, yet no NVIDIA budget is measured automatically. Until #67 provides hardware, NVIDIA budget results are manual.

## 7. Open questions for the owner

1. **Which GPU is in your NVIDIA machine?** Turing or newer, or older? Desktop or hybrid laptop?
2. **Variant image or one image** for everyone (5)?
3. **Pre-Turing:** nouveau + NVK best effort, or a 580xx variant with the closed module?
4. **NVIDIA licence:** do you accept the distributor terms, including indemnification (clause 2.11), and non-free code in the public NVIDIA image? Do you want legal review of how the licence must be "provided" (1.1(d)) and, if 580xx is wanted, of prebuilt closed modules?
5. **Package source:** RPM Fusion (Fedora 45 builds and legacy branches today) or NVIDIA's repository (no Fedora 45 driver packages yet)?
6. **Kernel hold rule:** may the NVIDIA variant lag the other images on a kernel bump, and for how long?
7. **Module signing key:** sign modules with the release key itself, or add a second db cert of equal power (a firmware boot trust anchor too, and a PCR7 change with a recovery-key prompt on every machine when it is added)?
8. **Decision ID:** D-017, or another?
9. **#158 dependency:** if #158 confirms that every db cert and non-CA MOK can verify modules, do you keep that behaviour (the recommended signing path needs it), or close it, which leaves a CA MOK (against D-016) or our own kernel build?

## Sources

All opened on 2026-11-08.

- NVIDIA driver: [unix drivers](https://www.nvidia.com/en-us/drivers/unix/), [download tree](https://download.nvidia.com/XFree86/Linux-x86_64/), README 620.70.06: [kernel_open](https://download.nvidia.com/XFree86/Linux-x86_64/620.70.06/README/kernel_open.html), [supportedchips](https://download.nvidia.com/XFree86/Linux-x86_64/620.70.06/README/supportedchips.html), [wayland-issues](https://download.nvidia.com/XFree86/Linux-x86_64/620.70.06/README/wayland-issues.html), [powermanagement](https://download.nvidia.com/XFree86/Linux-x86_64/620.70.06/README/powermanagement.html), [primerenderoffload](https://download.nvidia.com/XFree86/Linux-x86_64/620.70.06/README/primerenderoffload.html), [gbm](https://download.nvidia.com/XFree86/Linux-x86_64/620.70.06/README/gbm.html), [ngx](https://download.nvidia.com/XFree86/Linux-x86_64/620.70.06/README/ngx.html); [licence page](https://www.nvidia.com/en-us/drivers/nvidia-license/); [open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules), [its releases](https://github.com/NVIDIA/open-gpu-kernel-modules/releases), [COPYING](https://raw.githubusercontent.com/NVIDIA/open-gpu-kernel-modules/main/COPYING); [R560 blog](https://developer.nvidia.com/blog/nvidia-transitions-fully-towards-open-source-gpu-kernel-modules/); [Fedora driver guide](https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/fedora.html)
- Packages read: `nvidia-driver-620.70.06-1.fc44.x86_64.rpm` (LICENSE, ngx.html, file list), `kmod-nvidia-open-dkms-620.70.06-1.fc44.noarch.rpm` (COPYING), header of `nvidia-kmod-common-620.70.06-1.fc44.noarch.rpm`, from [NVIDIA fedora44](https://developer.download.nvidia.com/compute/cuda/repos/fedora44/x86_64/); [NVIDIA fedora45](https://developer.download.nvidia.com/compute/cuda/repos/fedora45/x86_64/)
- RPM Fusion: [Howto/NVIDIA](https://rpmfusion.org/Howto/NVIDIA), [Howto/Secure Boot](https://rpmfusion.org/Howto/Secure%20Boot), [nvidia-kmod.spec](https://raw.githubusercontent.com/rpmfusion/nvidia-kmod/master/nvidia-kmod.spec), [f44 updates](https://download1.rpmfusion.org/nonfree/fedora/updates/44/x86_64/), [f45 releases](https://download1.rpmfusion.org/nonfree/fedora/releases/45/Everything/x86_64/os/Packages/x/)
- Fedora kernel: [f45 sources](https://src.fedoraproject.org/rpms/kernel/raw/f45/f/sources), [patch-7.3-redhat.patch](https://src.fedoraproject.org/rpms/kernel/raw/f45/f/patch-7.3-redhat.patch), [x86_64 config](https://src.fedoraproject.org/rpms/kernel/raw/f45/f/kernel-x86_64-fedora.config), [aarch64 config](https://src.fedoraproject.org/rpms/kernel/raw/f45/f/kernel-aarch64-fedora.config), [kernel-ark signing.c](https://gitlab.com/cki-project/kernel-ark/-/raw/os-build/kernel/module/signing.c); mainline [signing.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/kernel/module/signing.c), [load_uefi.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/security/integrity/platform_certs/load_uefi.c); [Nova docs](https://docs.kernel.org/gpu/nova/index.html)
- Mesa and nouveau: [NVK](https://docs.mesa3d.org/drivers/nvk.html), [Mesa 25.1.0 notes](https://docs.mesa3d.org/relnotes/25.1.0.html), [nouveau feature matrix](https://nouveau.freedesktop.org/FeatureMatrix.html)
- Compositor and toolkit: [smithay drm_syncobj](https://raw.githubusercontent.com/Smithay/smithay/master/src/wayland/drm_syncobj/mod.rs), [cosmic-comp kms/mod.rs](https://raw.githubusercontent.com/pop-os/cosmic-comp/master/src/backend/kms/mod.rs), cosmic-comp issues [#3037](https://github.com/pop-os/cosmic-comp/issues/3037), [#3016](https://github.com/pop-os/cosmic-comp/issues/3016), [#2955](https://github.com/pop-os/cosmic-comp/issues/2955), [#2954](https://github.com/pop-os/cosmic-comp/issues/2954); Slint [#4828](https://github.com/slint-ui/slint/issues/4828), [#9941](https://github.com/slint-ui/slint/issues/9941)
- Others shipping NVIDIA: [ublue-os/akmods](https://github.com/ublue-os/akmods), [fedora-bootc-nvidia](https://github.com/coreos/fedora-bootc-nvidia), [Fedora discussion](https://discussion.fedoraproject.org/t/enabling-gpus-on-fedora-with-image-mode-fedora-bootc/170247), [Pop!_OS install](https://system76.com/support/articles/install-pop/), [Ubuntu linux-modules-nvidia-580](https://packages.ubuntu.com/search?keywords=linux-modules-nvidia-580&searchon=names&suite=all&section=all)
- Secondary (version history only): [GBM in 495.44](https://www.gamingonlinux.com/2021/10/nvidia-49544-stable-driver-is-out-for-linux-adds-in-gbm-api-support), [explicit sync in 555.42.02](https://gamingonlinux.com/2024/05/nvidia-555-42-02-beta-driver-out-bringing-wayland-explicit-sync)
