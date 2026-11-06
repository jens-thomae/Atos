# D-008: base image technology and base distribution

Card: #4 · Written: 2026-11-06 · Status of D-008: **Open**. This write-up ends in a recommendation for the owner ([section 4](#4-recommendation-for-the-owner-to-decide)). It decides nothing. No image was built for it.

Every statement about bootc, systemd-sysupdate, mkosi or a distribution links to the upstream page it comes from. All links were opened on 2026-11-06. **Not checked** means I found no source either way. **Uncertain** marks a claim from a secondary source, or one I could not confirm upstream.

## 1. Context

### 1.1 What D-008 decides

D-008 (spec §5) is the last Phase 0 gate decision (§8). It picks:

1. **The image technology** behind C1: bootc or systemd-sysupdate (the card's two options).
2. **The base distribution** whose packages go into the image.

D-002 (Decided) already fixes the model: an image-based OS with signed images, atomic updates and rollback. D-008 only chooses how to build it.

### 1.2 Requirements this write-up measures against

From §6 C1:

- **R1** Read-only, signed system image; user data and apps live outside it.
- **R2** Updates download and stage in the background, and apply on the next restart.
- **R3** The last known-good image can always be booted from a "Previous version" boot entry, without a terminal.
- **R4** Full-disk encryption on by default at install.
- **R5** A developer mode with a writable overlay or package layering, behind a dismissible warning.

From §7:

- **B1** Boot to a usable desktop on the reference hardware in ≤ 10 s.
- **B2** A failed update rolls back to the previous image automatically.

### 1.3 Constraints from other decisions

- **D-005** No telemetry, no account. Updates must not phone home or need a login.
- **D-006** Slint with the GPU renderer by default, so **Mesa and kernel freshness matter**: new laptop GPUs need recent drivers.
- **D-007** We fork cosmic-comp and make **no upstream contributions**. Any gap in the image tooling becomes a patch we carry, and that counts as our cost.
- **D-013** Our source is MIT OR Apache-2.0. The base distribution's packages must be redistributable in a public image.
- **Target hardware** is normal laptops and desktops rendered on the GPU. The Intel NUC (Celeron N5105) is only the budget reference and a CI runner.

## 2. Options

### 2.1 bootc

[bootc](https://bootc.dev/bootc/) delivers the OS as an OCI (container) image. The image contains the kernel. On the machine, systemd runs as PID 1 as usual, not in a container. The [README](https://github.com/bootc-dev/bootc) says *"The CLI and API are considered stable"*. bootc is a CNCF Sandbox project. Latest release: [v1.17.4](https://github.com/bootc-dev/bootc/releases), 2026-11-04.

- **Two storage backends** ([composefs page](https://bootc.dev/bootc/bootc-composefs.7.html)). ostree is the default. composefs is *"stable; upgrades and core functionality is supported"*. composefs is required for **sealed images**: fs-verity is enforced, and the expected root digest sits in a UKI signed for Secure Boot. UKIs work with systemd-boot.
- **Updates** ([bootc-upgrade(8)](https://bootc.dev/bootc/man/bootc-upgrade.8.html)). `bootc upgrade` downloads and stages the new image *"A/B style"*, without touching the running system. The staged image applies at shutdown. `--download-only` and `--check` exist. Downloads are per OCI layer, so an unchanged layer is not fetched again.
- **Rollback** ([bootc-rollback(8)](https://bootc.dev/bootc/man/bootc-rollback.8.html)) reorders the boot entries so that the previous deployment boots next.
- **Building images** uses a `Containerfile` and any OCI build tool (podman, buildah). [bootc-image-builder](https://github.com/osbuild/bootc-image-builder) turns the container into disk images and ISOs.
- **Base images.** The Fedora/CentOS bootc images are *"the most closely aligned upstream project"* ([base images page](https://bootc.dev/bootc/bootc-base-images.7.html)). bootc is not tied to Fedora, but Debian, Ubuntu and Arch images exist only as community experiments (section 3.4).

### 2.2 systemd-sysupdate (with mkosi)

[systemd-sysupdate](https://www.freedesktop.org/software/systemd/man/latest/systemd-sysupdate.html) is part of systemd (v262.2, [2026-11-05](https://github.com/systemd/systemd/releases)). It updates partitions or files A/B style. The current version keeps running while the next one downloads into a free slot.

- **Transfers** are configured in [sysupdate.d(5)](https://www.freedesktop.org/software/systemd/man/latest/sysupdate.d.html). The usual layout has a dm-verity-protected `/usr` partition plus a UKI per version. The server publishes `SHA256SUMS` and a detached `SHA256SUMS.gpg`. Payloads are *"unconditionally checked"* against the manifest. `InstancesMax=` sets how many versions are kept.
- **Boot counting** is built in. Target names can carry `@l`/`@d` (tries left and tries done), and systemd-boot then does [automatic boot assessment](https://systemd.io/AUTOMATIC_BOOT_ASSESSMENT/).
- **Building images** uses [mkosi](https://github.com/systemd/mkosi) (v27.1, 2026-09-28). mkosi builds from Fedora, Debian, Ubuntu, Arch, openSUSE, CentOS, Rocky and Alma packages. It produces UKIs, verity partitions and Secure Boot signatures, and it has a `sysupdate` verb.
- **Stability: experimental again.** The man page says *"This component is experimental and subject to change at any given moment without notice."* systemd [NEWS](https://github.com/systemd/systemd/blob/main/NEWS) shows the churn:
  - v261 declared it no longer experimental.
  - v262 moved the binary back to libexecdir *"as more breaking changes are forthcoming"*, and changed the JSON key `name` to `id`.
  - v262 also announced that the `systemd-sysupdated` D-Bus API (the one GUI updaters use) will be **removed in v263**, in favour of Varlink.
  - KDE Linux reported that v260 took sysupdate out of the API stability guarantee and broke its GUI updater ([March 2026 report](https://pointieststick.com/2026/03/)).
- **Downloads are whole images.** Delta updates exist only as an experimental, opt-in add-on in KDE Linux ([April 2026 report](https://pointieststick.com/2026/05/02/this-month-in-kde-linux-april-2026/)), not in systemd itself.

## 3. Comparison

### 3.1 C1 requirements

| | bootc | systemd-sysupdate + mkosi |
| --- | --- | --- |
| **R1** signed read-only image | **Meets.** Sealed composefs images: fs-verity root, digest in a Secure-Boot-signed UKI ([composefs](https://bootc.dev/bootc/bootc-composefs.7.html)). Transport signatures with OCI signing tools; we did not check the details. `/etc` and `/var` stay writable, and user data lives in `/var/home`. | **Meets.** dm-verity `/usr` with the root hash in a signed UKI; downloads verified with OpenPGP ([sysupdate.d](https://www.freedesktop.org/software/systemd/man/latest/sysupdate.d.html)). User data on its own partition. |
| **R2** background staging, applied on restart | **Meets.** `bootc upgrade` stages and applies at shutdown ([bootc-upgrade](https://bootc.dev/bootc/man/bootc-upgrade.8.html)); there is a timer for automatic updates ([bootc-rollback](https://bootc.dev/bootc/man/bootc-rollback.8.html) names `bootc-fetch-apply-updates.timer`). Layer-level downloads. | **Meets.** `systemd-sysupdate-update.timer` downloads into the free slot; the new UKI boots on restart. Whole-image downloads. The GUI-facing API is being replaced in v263. |
| **R3** "Previous version" boot entry, no terminal | **Partly.** The previous deployment stays as a boot entry, but bootc keeps one booted and one rollback deployment, not more. Showing it as "Previous version" in the boot menu, and a GUI rollback action, are our work. | **Partly.** Older UKIs stay as systemd-boot entries (`InstancesMax=`; KDE Linux keeps 3–4, [background](https://linux.kde.org/docs/background)). Naming and a GUI action are our work. |
| **R4** full-disk encryption by default | **Meets at install.** `bootc install to-disk --block-setup tpm2-luks` ([install-to-disk](https://bootc.dev/bootc/man/bootc-install-to-disk.8.html)). Combining it with sealed composefs and systemd-boot: **not checked**. OS and user data share one encrypted root. | **Meets by design.** systemd-repart can create TPM2-bound LUKS partitions at first boot. GNOME OS designs it this way, but has not shipped it by default with Secure Boot (**uncertain**, [discussion](https://discourse.gnome.org/t/why-did-gnome-os-choose-systemd-sysupdate-over-bootc/24642)). |
| **R5** developer mode | **Partly.** `bootc usr-overlay` gives a writable `/usr`, but it is transient: *"discarded on reboot"* and held in RAM ([usr-overlay](https://bootc.dev/bootc/man/bootc-usr-overlay.8.html)). Persistent changes: build a derived image locally (`FROM` our image) and switch to it. A **sealed** system only boots UKIs signed by a key it trusts, so that path needs a developer key. Design work. | **Partly to meets.** `systemd-sysext --mutable=yes` (since v256) gives a persistent writable overlay on `/usr` ([systemd-sysext](https://www.freedesktop.org/software/systemd/man/latest/systemd-sysext.html)). There is no package layering; extensions are images. |

### 3.2 §7 budgets

| | bootc | systemd-sysupdate + mkosi |
| --- | --- | --- |
| **B1** boot ≤ 10 s | **Not measured, by anyone I found.** The boot path is ordinary systemd. composefs adds an fs-verity check on mount. Staging runs at shutdown, so it adds to shutdown time, not boot time. | **Not measured, by anyone I found.** systemd-boot + UKI + dm-verity, which is the shortest standard path; verity checks blocks on demand. |
| **B2** automatic rollback | **Gap on the backend R1 needs.** The ostree backend can use boot entry counting. The composefs backend *"does not configure boot entry counting, this is likely to be added in the future"* ([boot failure detection](https://bootc.dev/bootc/bootc-boot-failure-detection.7.html)). Greenboot's rollback helper reads a GRUB counter. So sealed images have **no automatic rollback today**: we wait, or carry a patch (D-007). | **Meets by design.** `TriesLeft=` in the transfer, then systemd-boot counts tries and falls back to the older entry; `systemd-bless-boot` marks a good boot once `boot-complete.target` is reached ([boot assessment](https://systemd.io/AUTOMATIC_BOOT_ASSESSMENT/)). Our health checks hook into `boot-complete.target`. |

B1 cannot be judged from documents. Both options use the same kernel, initrd and systemd. The difference is a verity check, which should be small. **This needs measuring on the NUC in Phase 1**, whichever option is picked.

### 3.3 Who ships it in production

| Technology | Shipping | Status |
| --- | --- | --- |
| bootc | [Red Hat Enterprise Linux image mode](https://www.redhat.com/en/blog/image-mode-for-red-hat-enterprise-linux-generally-available) | GA since 2025-05-20, supported on RHEL 9.6 and 10+ |
| bootc | [Universal Blue](https://universal-blue.org/) (Bazzite, Bluefin, Aurora): desktops | Production. The project reports over 110,000 weekly active users ([forum, 2026](https://universal-blue.discourse.group/t/bazzites-biggest-update-deck-44-has-launched-happy-birthday-to-universal-blue/12373); the project's own figure, from Fedora countme) |
| bootc | CIQ (Rocky Linux from CIQ), AlmaLinux Atomic SIG, HeliumOS, ALT Atomic, Caligra, Luft (Fedora, sealed composefs UKIs, systemd-boot) | Listed in [ADOPTERS.md](https://github.com/bootc-dev/bootc/blob/main/ADOPTERS.md); maturity not checked per project |
| bootc (via ostree) | [Fedora Atomic Desktops](https://fedoraproject.org/atomic-desktops/), Endless OS, Playtron GameOS, Apertis | ostree today; Fedora's move to bootc is in progress with no date ([Fedora 44 notes](https://tim.siosm.fr/blog/2026/04/28/fedora-atomic-desktops-44/), [roadmap #26](https://forge.fedoraproject.org/atomic-desktops/tracker/issues/26)) |
| systemd-sysupdate | [KDE Linux](https://invent.kde.org/kde-linux/kde-linux) (Arch packages, mkosi, EROFS `/usr`, systemd-boot) | "Testing Edition": *"usable for adventurous people with backups, but not yet for regular people"*; beta in progress |
| systemd-sysupdate | [GNOME OS](https://codethink.co.uk/articles/2024/GNOME-OS-systemd-sysupdate) | Nightly and preview images for testing GNOME; not a general-purpose release |
| systemd-sysupdate | [ParticleOS](https://github.com/systemd/particleos) (systemd's own, mkosi) | Experimental, no releases; you build and sign your own image |

**I found no general-purpose desktop that ships systemd-sysupdate to regular users.** bootc ships at scale, both commercially and on desktops.

### 3.4 Base distribution

Versions are from [Repology](https://repology.org/project/mesa/versions) ([kernel](https://repology.org/project/linux/versions)) on 2026-11-06. Repology does not list Fedora 45 yet. Fedora 45 was declared GO for 3 November 2026 ([Phoronix](https://phoronix.com/news/Fedora-45-Ships-Next-Week); **uncertain** whether it has shipped).

| | Fedora | Debian | Arch-based | CentOS Stream 10 | From upstream (own packages) |
| --- | --- | --- | --- | --- | --- |
| Update cadence | New release every ~6 months; each supported ~13 months | Stable every ~2 years | Rolling, no releases | Continuous, tracks the next RHEL minor | Ours |
| Mesa (stable) | 26.2.6 (F44) | 25.0.7 (13), 26.1.6 in backports | 26.2.6 | 26.1.1 | Ours to track |
| Kernel (stable) | 7.2.15 (F44; Fedora moves kernels forward within a release) | 6.12 LTS (13), 7.2 in backports | 7.2.14 | 6.12 plus backports | Ours to track |
| Fit with D-006 (fresh GPU stack) | Good | Weak on stable; backports are a second channel we would track | Good | Kernel weak for new laptops | Whatever we pay for |
| Flatpak (D-003) | First-class, preinstalled on Fedora desktops | Packaged | Packaged | Packaged | Ours to build |
| Signing infrastructure | Signed packages; Fedora's shim and kernel are Secure Boot signed | Signed packages; signed shim and kernel | Signed packages; **no** signed shim or kernel from Arch | Signed packages; signed shim and kernel | None; all ours |
| bootc support | **First-class**: official `fedora-bootc` base images; most adopters | Community experiments only. Frostyard reports *"showstopper bugs"* ([status](https://frostyard.github.io/docs/status/)) | Community experiment ([arch-bootc](https://github.com/ahmedadan/arch-bootc)) | Official `centos-bootc` images | n/a |
| sysupdate / mkosi support | mkosi supports it | mkosi supports it | mkosi supports it; KDE Linux uses it | mkosi supports it | mkosi |
| Redistributable (D-013) | Yes | Yes | Yes | Yes | Yes |

Notes:

- **Secure Boot is our own cost on every base.** A sealed image means a UKI that **we** sign, so our key must be trusted on the user's machine, either through a Microsoft-signed Atos shim or by enrolling our key. The distribution's signed shim does not cover our UKI. Getting a shim signed means going through [shim-review](https://github.com/rhboot/shim-review). Since 27 June 2026, Microsoft signs only with its UEFI CA 2023.
- **RHEL** itself is ruled out: Red Hat's image mode documentation states that rhel-bootc images and images built on them fall under the RHEL EULA and may not be publicly redistributed ([RHEL 10 image mode docs](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems/introducing-image-mode-for-rhel); **uncertain**: the page refused automated access, so this comes from a search-result excerpt of it).
- **Building from upstream** means owning a package build farm and a security response for every package. That is a distribution's worth of work, and it does not fit §3's "integrator" stance.
- **D-005 on Fedora:** Fedora's image tools send an anonymous `countme` counter with repository metadata requests (`rpm-ostree-countme.timer`, [docs](https://coreos.github.io/rpm-ostree/countme/)). It is anonymous, but it is still a call home that is on by default. Our image must mask the timer, and we should check that `bootc` and any `dnf` in the image send nothing.

## 4. Recommendation (for the owner to decide)

**Flag for the owner: this is a recommendation, not a decision.**

**bootc on Fedora, using sealed composefs images, UKIs and systemd-boot. Automatic rollback (B2) is a known gap that we close ourselves, or that upstream closes before Phase 4.**

Why, in the §2 priority order:

1. **Stability.** bootc's CLI and API are declared stable, and it ships to over 100,000 desktop users and to RHEL customers. systemd-sysupdate has been marked experimental again as of v262, its GUI-facing D-Bus API goes away in v263, and its only desktop users are pre-beta. With no upstream contributions (D-007), every breaking change in sysupdate is adaptation work we carry.
2. **Fresh GPU stack (D-006).** Fedora stable carries the same Mesa as Arch (26.2.6) and current kernels, with a six-month release rhythm and Bodhi testing before updates land. Debian stable is a year behind on Mesa. Arch is just as fresh but has no release staging and no signed shim.
3. **Update size on laptops.** bootc downloads only changed layers. sysupdate downloads the whole image unless we build our own delta system.
4. **Tooling.** Containerfiles build on our existing GitHub Actions runners with podman, and `fedora-bootc` is the best-supported base image.

What it costs, and the risk:

- **B2 is not met on sealed images today.** The composefs backend has no boot counting yet. Options, cheapest first:
  - (a) Wait. Upstream says it is *"likely to be added"*. B2 only blocks a release (Phase 4), not Phase 1.
  - (b) Carry a patch that adds systemd-boot `+tries` counting to bootc's composefs UKI entries. That is the same mechanism sysupdate uses.
  - (c) Start Phase 1 on the ostree backend, which has entry counting, and move to sealed composefs later. This gives up R1's boot-time sealing until then.

  **The size of patch (b) is not known.**
- **R5 under sealing.** A persistent developer mode needs locally built images to boot. That means a developer signing key enrolled on that machine, or the machine dropping out of sealed mode. The design is a Phase 1 or Phase 2 card.
- **Fedora's countme** must be off in our image (D-005).
- **Our own Secure Boot chain** (shim-review or key enrolment) is needed with either option.

**When to pick the alternative instead** (systemd-sysupdate + mkosi, still on Fedora packages): if the owner values B2 and R5 working out of the box above upstream maturity. In that case, budget for:

- tracking sysupdate's API until it stabilises (v263+);
- our own update UI on Varlink;
- full-image downloads, or our own delta scheme.

Fedora stays the recommended base for either technology. mkosi supports it fully.

## 5. Consequences

If the recommendation is accepted:

- **D-008** becomes "bootc on Fedora: sealed composefs images with UKI and systemd-boot; Fedora as base distribution."
- **Build tooling it implies:**
  - podman/buildah with a `Containerfile` `FROM quay.io/fedora/fedora-bootc:<release>`;
  - a container registry (for example ghcr.io; public pulls need no account, which fits D-005);
  - OCI image signing;
  - `bootc container ukify` for sealed UKIs;
  - bootc-image-builder for disk images and the installer ISO (the ISO's design is C11, out of scope here).
- **What Phase 1 builds first** (cards for the planner, not created here):
  1. A minimal `Containerfile` on `fedora-bootc` that adds our cosmic-comp fork build and masks `countme`. CI builds it on every merge, signs it and pushes it.
  2. A sealed UKI signed with a **test** Secure Boot key. It boots in the dev VM ([dev-environment](../dev-environment.md)).
  3. The update loop in the VM: `bootc upgrade`, restart, `bootc rollback`. Record how long staging and booting take.
  4. A boot-time (B1) measurement on the NUC, added to the budget harness.
  5. A spike on composefs boot counting (option a, b or c above), with an effort estimate for B2.
- **New cards outside C1:** Secure Boot key management and shim-review (C10 or C1, owner's call); a "Previous version" label and a GUI rollback action (C3 or C8).
- **Docs:** `docs/components/c1-base/` records the base image tag, our image layers and every patch we carry.

If systemd-sysupdate is chosen instead, the build is mkosi, and Phase 1 starts with: an mkosi config on Fedora packages; a `sysupdate.d` transfer set (verity `/usr` and UKI with `TriesLeft=`); and a static update server with signed `SHA256SUMS`.

## 6. Open questions

For the owner:

1. **Reference hardware for Phase 1.** The Phase 1 gate is "boots and updates on the reference hardware". The NUC runs Ubuntu as our CI runner. Installing Atos on it would remove the runner. Should there be a second disk, a second NUC, or a schedule for taking the runner offline?
2. **Secure Boot strategy.** Do we apply for a Microsoft-signed Atos shim through shim-review, or have users enrol our key at install (C11)? This affects R1 on real laptops.
3. **B2 path.** If bootc is picked: wait for upstream, carry a boot-counting patch, or start on the ostree backend? (Section 4.)
4. **How "default" countme is treated.** Is masking Fedora's anonymous `countme` enough for D-005, or should the build also strip it from repository configs?
5. **Update channel and rhythm.** Do we follow each Fedora release within weeks, or lag by one? Not asked by the card, but it decides how long each Fedora release supports us.

## Sources

All opened on 2026-11-06.

- bootc: [docs](https://bootc.dev/bootc/), [README](https://github.com/bootc-dev/bootc), [ADOPTERS.md](https://github.com/bootc-dev/bootc/blob/main/ADOPTERS.md), [releases](https://github.com/bootc-dev/bootc/releases), [composefs backend](https://bootc.dev/bootc/bootc-composefs.7.html), [bootc-upgrade(8)](https://bootc.dev/bootc/man/bootc-upgrade.8.html), [bootc-rollback(8)](https://bootc.dev/bootc/man/bootc-rollback.8.html), [bootc-usr-overlay(8)](https://bootc.dev/bootc/man/bootc-usr-overlay.8.html), [bootc-install-to-disk(8)](https://bootc.dev/bootc/man/bootc-install-to-disk.8.html), [boot failure detection](https://bootc.dev/bootc/bootc-boot-failure-detection.7.html), [base images](https://bootc.dev/bootc/bootc-base-images.7.html), [bootc-image-builder](https://github.com/osbuild/bootc-image-builder)
- systemd: [systemd-sysupdate(8)](https://www.freedesktop.org/software/systemd/man/latest/systemd-sysupdate.html), [sysupdate.d(5)](https://www.freedesktop.org/software/systemd/man/latest/sysupdate.d.html), [systemd-sysext(8)](https://www.freedesktop.org/software/systemd/man/latest/systemd-sysext.html), [automatic boot assessment](https://systemd.io/AUTOMATIC_BOOT_ASSESSMENT/), [NEWS](https://github.com/systemd/systemd/blob/main/NEWS) (v261–v263 sections), [releases](https://github.com/systemd/systemd/releases), [mkosi](https://github.com/systemd/mkosi), [ParticleOS](https://github.com/systemd/particleos)
- Users: [RHEL image mode GA](https://www.redhat.com/en/blog/image-mode-for-red-hat-enterprise-linux-generally-available), [Universal Blue forum](https://universal-blue.discourse.group/t/bazzites-biggest-update-deck-44-has-launched-happy-birthday-to-universal-blue/12373), [Fedora Atomic Desktops 44](https://tim.siosm.fr/blog/2026/04/28/fedora-atomic-desktops-44/), [KDE Linux](https://invent.kde.org/kde-linux/kde-linux), [KDE Linux background](https://linux.kde.org/docs/background), [KDE Linux March 2026](https://pointieststick.com/2026/03/), [KDE Linux April 2026](https://pointieststick.com/2026/05/02/this-month-in-kde-linux-april-2026/), [GNOME OS + sysupdate](https://codethink.co.uk/articles/2024/GNOME-OS-systemd-sysupdate), [GNOME Discourse: sysupdate over bootc](https://discourse.gnome.org/t/why-did-gnome-os-choose-systemd-sysupdate-over-bootc/24642), [Frostyard status](https://frostyard.github.io/docs/status/), [arch-bootc](https://github.com/ahmedadan/arch-bootc)
- Distributions: [Repology Mesa](https://repology.org/project/mesa/versions), [Repology Linux](https://repology.org/project/linux/versions), [Fedora 45 release (Phoronix)](https://phoronix.com/news/Fedora-45-Ships-Next-Week), [shim-review](https://github.com/rhboot/shim-review), [rpm-ostree countme](https://coreos.github.io/rpm-ostree/countme/)
