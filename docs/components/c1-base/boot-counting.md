# Automatic rollback: boot counting (C1, #56)

The §7 Stability budget asks for an automatic rollback to the previous image after a failed update. bootc's composefs backend writes systemd-boot entries without boot counting ([boot failure detection](https://bootc.dev/bootc/bootc-boot-failure-detection.7.html): *"does not configure boot entry counting"*). D-008 closes the gap with a patch we carry (D-007: nothing goes upstream).

## How it works

1. `bootc upgrade` stages a new image. The patched bootc names the new image's entry `bootc_<os>-<version>-1+3.conf`. The entry for the running image stays `…-0.conf`, with no counter. A first install gets no counter, because nothing exists to fall back to.
2. On each boot of a counted entry, systemd-boot renames it first (`+3` → `+2-1` → `+1-2` → `+0-3`) and tells the OS through the `LoaderBootCountPath` EFI variable ([automatic boot assessment](https://systemd.io/AUTOMATIC_BOOT_ASSESSMENT/)).
3. In the OS, `systemd-bless-boot-generator` sees the variable and pulls in `systemd-bless-boot.service`, which requires `boot-complete.target`. Our health check, `atos-session-check.service`, is `RequiredBy=boot-complete.target`.
4. **Good boot:** the check passes, `boot-complete.target` is reached, and `systemd-bless-boot` renames the entry to `…-1.conf`. From then on, it is an ordinary entry.
5. **Bad boot:** every way a counted boot can fail ends in a reboot, and each reboot uses up one try:
   - **The session does not come up:** the check fails and reboots (`FailureAction=reboot`). This is a clean reboot, so a stop job that hangs can delay it by up to systemd's own shutdown timeouts.
   - **The boot hangs after switch-root** before the check decides: `JobTimeoutSec=5min` / `JobTimeoutAction=reboot` on `boot-complete.target`.
   - **The kernel panics:** the karg `panic=10` ([`kargs.d/20-atos-panic.toml`](../../../components/c1-base/usr/lib/bootc/kargs.d/20-atos-panic.toml)) reboots 10 s later. Like every karg, it is sealed into the signed UKI.
   - **The initrd (or the booted system) enters emergency mode,** for example because the composefs digest does not match: drop-ins for `emergency.service` and `dracut-emergency.service` run [`counted-boot-failed`](../../../components/c1-base/usr/libexec/atos/counted-boot-failed) first. On a counted boot (systemd-boot set `LoaderBootCountPath`), it reboots instead of starting the shell. The image rebuilds its initramfs with Fedora's dracut config plus [`40-atos-boot-counting.conf`](../../../components/c1-base/usr/lib/dracut/dracut.conf.d/40-atos-boot-counting.conf), which adds the drop-ins and the script.

   After three failed tries, the entry reads `+0-3`. systemd-boot sorts entries with no tries left last, so the previous image boots, with no user action.

A boot without a counter runs none of the counting logic: the check and the timeout hang off `boot-complete.target`, which only `systemd-bless-boot` pulls in, and `counted-boot-failed` exits at once, so emergency mode starts its shell as before. The tamper cases in the [C1 README](README.md) still stop at the emergency shell, and an image that is broken with nothing to fall back to does not reboot in a loop. The one exception is `panic=10`. The kernel cannot tell a counted boot from an uncounted one, so a panic on an uncounted boot reboots again and again instead of hanging. Both leave the machine unusable; a loop at least retries a fault that does not happen every time. This is flagged for the owner.

## What "good" means

**A boot is good when the desktop session runs:** `atos-comp` (C2) runs as `atos`, its Wayland socket exists, and it is still running 10 s later ([`session-check`](../../../components/c1-base/usr/libexec/atos/session-check)). The check fails as soon as greetd falls back to its text login, which means the session ended. It also fails after 2 minutes (`TimeoutStartSec=2min`).

Why this definition:

- **It is what the user needs from a boot.** Atos is a desktop OS. An image that boots but shows no desktop is unusable for someone who has no terminal (C1: *"no terminal needed"*). Reaching `multi-user.target` would pass such an image.
- **It covers the failures an update can cause.** Kernel, initrd, root mount, systemd units, Mesa, the compositor and greetd are all on the path to a running session. If any of them breaks, the session does not come up. The check itself runs only in the booted system. Failures before that are caught as described in step 5: by `panic=10`, by the emergency drop-ins, or by the `boot-complete.target` timeout.
- **It is not "no failed units".** systemd ships `systemd-boot-check-no-failures.service`, but it would roll back an image because of an unrelated unit, such as a network wait. That rejects updates that work for the user.
- **The 10 s wait** catches a compositor that crashes right after it starts. The **2-minute limit** is 12 times the 10 s boot budget (§7). Neither value is in the spec; both are flagged on the card.

When C3 (shell) exists, the check should also wait for the shell's first frame. That is a later card.

## The patch

[`third_party/bootc/patches/0001-composefs-boot-counting-for-staged-systemd-boot-UKI-.patch`](../../../third_party/bootc/patches/0001-composefs-boot-counting-for-staged-systemd-boot-UKI-.patch), against the upstream tag pinned in [`third_party/bootc/UPSTREAM`](../../../third_party/bootc/UPSTREAM) (v1.17.1, the version fedora-bootc 45 ships). The `bootc` stage of the [`Containerfile`](../../../components/c1-base/Containerfile) clones that tag, checks the commit, applies the patches, builds `bootc` with Fedora's `cargo` (as Fedora's own package does), runs the patch's unit test, and replaces `/usr/bin/bootc` in `base`. `bootc install`, `bootc upgrade` and `bootc status` all run the image's own `bootc`, so they all use the patched one. The initrd's `bootc-initramfs-setup` is not changed.

| | |
| --- | --- |
| Size | 2 files, 38 lines added, 6 removed (about 15 lines of logic, the rest is comments and a unit test) |
| `boot.rs` | `write_systemd_uki_config`: when it writes the staged entries for an upgrade, the new entry gets `+3` (`BOOT_COUNT_TRIES`) before `.conf` |
| `status.rs` | Sorting for systemd-boot puts entries with no tries left (`+0`, `+0-N`) last, as systemd-boot does. Without this, after a rollback, `bootc status` would call the failed image the default and report a queued rollback |

**Same build as Fedora's.** Fedora's [`bootc.spec`](https://src.fedoraproject.org/rpms/bootc/blob/f45/f/bootc.spec) builds all binaries with `cargo build --release --bins` from the release tarball, carries no downstream patches, and on Fedora enables no extra features (`rhsm` and `rhel9` are RHEL only). We build only `--bin bootc` from the same tag with default features and the same `Cargo.lock`. Only `/usr/bin/bootc` changes. The rest of the RPM, including `/usr/lib/bootc/initramfs-setup` and the units, stays Fedora's, at the same version (the base ships `bootc-1.17.1-1.fc45`). The f45 branch already packages 1.17.4, so the next base bump needs the rebase routine below.

The patch's unit test covers `boot_count_exhausted`. The `+3` naming is covered by the VM demo (`entries.staged` in `counting-stage-*.log`), because `write_systemd_uki_config` needs a real ESP.

**CI cost:** the `bootc` stage roughly doubles the c1-base build on the hosted runner (34 min 27 s against 17 to 19 min before; run 42388085955). The layer cache in #124 should take most of it back, because the stage only changes when `third_party/bootc` changes.

Not patched, on purpose:

- **Type 1 entries (non-UKI) and GRUB.** Atos boots UKIs with systemd-boot only (D-008).
- **`bootc rollback`.** It rewrites both entries without counters. A manual rollback is a user's choice, so it is not counted. After an automatic rollback, `bootc rollback` makes the failed image the default again, without a counter.

## Rebase effort

| Target | Result (2026-11-07) |
| --- | --- |
| v1.17.4 (newest tag) | `git apply` fails on context; `git apply -3` (3-way) applies both files cleanly |
| upstream `main` (00574d53, 2026-11-06) | Same: applies with 3-way merge, no conflicts |

Expected effort per bootc bump: minutes when only context moves (re-export the patch with `git format-patch`). The patch touches two functions. A real rework is needed only if upstream changes how composefs entries are named or sorted.

**Routine** for a new fedora-bootc base:

1. Check the base's bootc version: `podman run --rm <base> rpm -q bootc`.
2. If upstream bootc now configures boot counting for composefs UKI entries, **drop the patch**: remove the `bootc` stage and its `COPY` from the Containerfile, delete `third_party/bootc/`, and update this page. Upstream tracks it in its boot failure detection docs (*"likely to be added in the future"*).
3. Otherwise, set `tag` and `commit` in `third_party/bootc/UPSTREAM` to the version the base ships, apply the patch with `git am -3`, fix any conflicts, regenerate it with `git format-patch -1`, and rerun `tools/dev-vm/sealed.sh counting`.

## SELinux: one added rule

`systemd-bless-boot` runs as `init_t`. Fedora's policy does not let it rename files on the ESP (`dosfs_t`), so the first good boot in the VM failed to drop the counter:

```
avc:  denied  { rename } for  comm="systemd-bless-b" name="bootc_fedora-45-1+2-1.conf" scontext=system_u:system_r:init_t:s0 tcontext=system_u:object_r:dosfs_t:s0 tclass=file
```

The image installs [`atos-bless-boot.cil`](../../../components/c1-base/usr/share/atos/selinux/atos-bless-boot.cil) with `semodule -i`. It adds exactly that permission, `allow init_t dosfs_t (file (rename))`, and nothing more. With it, the good boot is marked good. This is security-relevant (policy), so it is flagged for the owner.

## Shown in the dev VM (2026-11-07)

`tools/dev-vm/sealed.sh counting` ([`sealed.sh`](../../../tools/dev-vm/sealed.sh)) uses its own disk, `~/sealed/counting.raw`, and the dev registry from the update loop (#55). Images: **dev-1** (as shipped), **dev-2** (adds `IMAGE_VERSION=dev-2`), and **dev-bad**, which is dev-2 with `IMAGE_VERSION=dev-bad` and `/usr/bin/atos-comp` pointing at `false`. dev-bad boots, but its session never comes up, as when an update ships a compositor that crashes. The variants are built from copies of the Containerfile in `~/sealed`; the shipped one does not change.

The VM passes longer timeouts as systemd credentials (`TimeoutStartSec=20min` for the check, `JobTimeoutSec=40min` for `boot-complete.target`), because boots under CPU emulation take minutes. A VM-only unit prints `ATOS-BOOT image=… counter=…` on every boot, read from `LoaderBootCountPath`. QEMU now has a `virtio-gpu-pci` device, so `atos-comp` has a DRM device. Filtered serial logs:

**Good update (dev-1 → dev-2).** `bootc upgrade` writes the dev-2 entry with a counter. dev-2 boots counted, the check passes, and `systemd-bless-boot` drops the counter:

```
counting-good.log
[  389.859960] sh[1741]: ATOS-BOOT image=dev-2 counter=\loader\entries\bootc_fedora-45-1+2-1.conf
[  435.144611] session-check[1839]: session up: boot is good
[  OK  ] Finished systemd-bless-boot.service - Mark the Current Boot Loader Entry as Good.
           id: bootc_fedora-45-1.conf      (bootctl list after the boot: no counter)
```

**Failed update (dev-2 → dev-bad).** Staged from dev-2:

```
counting-stage-bad.log (ls /boot/loader/entries.staged after bootc upgrade)
[  465.390544] sh[1215]: bootc_fedora-45-0.conf
[  465.399990] sh[1215]: bootc_fedora-45-1+3.conf
```

One QEMU run, no input: three tries of dev-bad, each ended by the check, then dev-2:

```
counting-bad.log
[  389.406911] sh[1737]: ATOS-BOOT image=dev-bad counter=\loader\entries\bootc_fedora-45-1+2-1.conf
[  438.899084] session-check[1837]: session ended: boot is bad
[FAILED] Failed to start atos-session-check.service - Atos boot health check: the desktop session runs.
[  463.846848] reboot: Restarting system
[  212.415433] sh[744]: ATOS-BOOT image=dev-bad counter=\loader\entries\bootc_fedora-45-1+1-2.conf
[  267.233110] session-check[874]: session ended: boot is bad
[  290.935068] reboot: Restarting system
[  206.823814] sh[742]: ATOS-BOOT image=dev-bad counter=\loader\entries\bootc_fedora-45-1+0-3.conf
[  258.944650] session-check[869]: session ended: boot is bad
[  285.725235] reboot: Restarting system
[  220.227695] sh[741]: ATOS-BOOT image=dev-2 counter=none
[  252.340991] sh[924]: IMAGE_VERSION=dev-2
       source: /boot//loader/entries/bootc_fedora-45-0.conf
       source: /boot//loader/entries/bootc_fedora-45-1+0-3.conf
        tries: 0 left; 3 done
```

After the rollback, `bootc status` (patched) reports `booted:` dev-2 (verity `fe5f2b05…`), `rollback:` dev-bad (`bb77df68…`) and `rollbackQueued: false`. Without the `status.rs` part of the patch, it would list the failed image first.

Time from the first boot of dev-bad to the dev-2 desktop: about 22 minutes (three tries of 4.8 to 7.7 minutes, then the fallback boot). That is CPU emulation, not the NUC. On real hardware, each try lasts the boot (§7: 10 s) plus however long the session takes to fail. The longest case is a hang, at 5 minutes per try.

**Failures before and after switch-root (review of #126, 2026-11-07).** Each image is staged from dev-2, then booted in one QEMU run with no input, until systemd-boot falls back. These boots use the image's own timeouts where noted. Filtered:

```
counting-panic.log (dev-panic: rdinit=/usr/bin/true, so init exits in the initrd)
[   18.491633] Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000000
[   18.601781] Rebooting in 10 seconds..
[   18.775361] Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000000
[   18.884812] Rebooting in 10 seconds..
[   18.484094] Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000000
[   18.557740] Rebooting in 10 seconds..
[  181.564882] sh[746]: ATOS-BOOT image=dev-2 counter=none
       source: /boot//loader/entries/bootc_fedora-45-1+0-3.conf
        tries: 0 left; 3 done
```

```
counting-emerg.log (dev-emerg: rd.systemd.unit=emergency.target, the initrd's emergency mode)
[   35.190561] systemd[1]: Reached target emergency.target - Emergency Mode.
atos: counted boot failed, rebooting to count the try
[   43.578690] reboot: Restarting system
atos: counted boot failed, rebooting to count the try
[   49.921120] reboot: Restarting system
atos: counted boot failed, rebooting to count the try
[   52.450952] reboot: Restarting system
[  189.735999] sh[741]: ATOS-BOOT image=dev-2 counter=none
       source: /boot//loader/entries/bootc_fedora-45-1+0-3.conf
        tries: 0 left; 3 done
```

```
counting-hang.log (dev-hang: atos-comp runs but never opens its socket; the check's shipped 2 min)
[  371.296323] sh[1738]: ATOS-BOOT image=dev-hang counter=\loader\entries\bootc_fedora-45-1+2-1.conf
[FAILED] Failed to start atos-session-check.service - Atos boot health check: the desktop session runs.
[  524.628432] reboot: Restarting system
[  222.077988] sh[743]: ATOS-BOOT image=dev-hang counter=\loader\entries\bootc_fedora-45-1+1-2.conf
[  513.629756] reboot: Restarting system
[  225.308142] sh[743]: ATOS-BOOT image=dev-hang counter=\loader\entries\bootc_fedora-45-1+0-3.conf
[  523.165114] reboot: Restarting system
[  236.469522] sh[742]: ATOS-BOOT image=dev-2 counter=none
        tries: 0 left; 3 done
```

```
counting-hang-target.log (dev-hang under another name; both shipped timeouts: here the boot is slow,
so boot-complete.target's 5 min fires before the check's 2 min)
[  372.212349] sh[1738]: ATOS-BOOT image=dev-hang-target counter=\loader\entries\bootc_fedora-45-1+2-1.conf
[ TIME ] Timed out starting boot-complete.target - Boot Completion Check.
[  !!  ] Rebooting: job timed out
[  447.901581] reboot: Restarting system
[  195.075639] sh[744]: ATOS-BOOT image=dev-hang-target counter=\loader\entries\bootc_fedora-45-1+1-2.conf
[  357.370548] reboot: Restarting system
[  208.132795] sh[743]: ATOS-BOOT image=dev-hang-target counter=\loader\entries\bootc_fedora-45-1+0-3.conf
[  366.209096] reboot: Restarting system
[  227.731560] sh[743]: ATOS-BOOT image=dev-2 counter=none
        tries: 0 left; 3 done
```

**A boot without a counter still stops at the emergency shell.** The `erofs` tamper case (`sealed.sh tamper erofs`, a fresh install, no counter) with these images:

```
tamper-erofs.log
[   94.863710] initramfs-setup[504]:     5: fs-verity content mismatch
[  OK  ] Started emergency.service - Emergency Shell.
Entering emergency mode. Exit the shell to continue.
```

No `counted boot failed` and no reboot, as before.

One finding on the side: `bootc upgrade` stages nothing for an image that is already deployed. After a rollback, the failed image stays the rollback entry, and pushing it again reports `No changes`, so a failed image is not retried until a new one is published.

Logs: `tools/dev-vm/out/sealed/counting-{stage-good,good,stage-bad,bad,panic,emerg,hang,hang-target}.log` and `tamper-erofs.log`.

## Limits

- **A kernel that hangs without panicking, or an initrd that hangs without reaching emergency mode, still needs a power cycle.** Each power cycle counts a try. Covering it needs a hardware watchdog or `softlockup_panic`/`hung_task_panic`. That is [#128](https://github.com/jens-thomae/Atos/issues/128).
- **A failed bless reverts a good update without telling anyone.** If `systemd-bless-boot` fails, the entry keeps counting down on each good boot, and systemd-boot falls back after three of them. The SELinux module and the compiled policy live in `/etc/selinux`, and bootc merges `/etc` three ways on an update, as ostree does. If the machine's policy was modified locally, the local files win and an image's new module does not arrive. A full ESP is another way the bless can fail. [#127](https://github.com/jens-thomae/Atos/issues/127) tracks detecting it.
- **The check knows only the compositor.** It should also wait for the shell (C3) once the shell exists.
- **A failed entry stays on the ESP as `+0-3`** until the next `bootc upgrade` replaces it. systemd-boot keeps it last, and the boot menu still lists it.
