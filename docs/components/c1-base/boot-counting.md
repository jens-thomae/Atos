# Automatic rollback: boot counting (C1, #56)

The §7 Stability budget asks for an automatic rollback to the previous image after a failed update. bootc's composefs backend writes systemd-boot entries without boot counting ([boot failure detection](https://bootc.dev/bootc/bootc-boot-failure-detection.7.html): *"does not configure boot entry counting"*). D-008 closes the gap with a patch we carry (D-007: nothing goes upstream).

## How it works

1. `bootc upgrade` stages a new image. The patched bootc names the new image's entry `bootc_<os>-<version>-1+3.conf`. The entry for the running image stays `…-0.conf`, with no counter. A first install gets no counter, because nothing exists to fall back to.
2. On each boot of a counted entry, systemd-boot renames it first (`+3` → `+2-1` → `+1-2` → `+0-3`) and tells the OS through the `LoaderBootCountPath` EFI variable ([automatic boot assessment](https://systemd.io/AUTOMATIC_BOOT_ASSESSMENT/)).
3. In the OS, `systemd-bless-boot-generator` sees the variable and pulls in `systemd-bless-boot.service`, which requires `boot-complete.target`. Our health check, `atos-session-check.service`, is `RequiredBy=boot-complete.target`.
4. **Good boot:** the check passes, `boot-complete.target` is reached, and `systemd-bless-boot` renames the entry to `…-1.conf`. From then on, it is an ordinary entry.
5. **Bad boot:** the check fails and reboots (`FailureAction=reboot`). A boot that hangs before the check decides is rebooted by `JobTimeoutSec=5min` / `JobTimeoutAction=reboot` on `boot-complete.target`. After three failed tries, the entry reads `+0-3`. systemd-boot sorts entries with no tries left last, so the previous image boots, with no user action.

None of this runs on a boot without a counter: the check and the timeout hang off `boot-complete.target`, which only `systemd-bless-boot` pulls in.

## What "good" means

**A boot is good when the desktop session runs:** `atos-comp` (C2) runs as `atos`, its Wayland socket exists, and it is still running 10 s later ([`session-check`](../../../components/c1-base/usr/libexec/atos/session-check)). The check fails as soon as greetd falls back to its text login, which means the session ended. It also fails after 2 minutes (`TimeoutStartSec=2min`).

Why this definition:

- **It is what the user needs from a boot.** Atos is a desktop OS. An image that boots but shows no desktop is unusable for someone who has no terminal (C1: *"no terminal needed"*). Reaching `multi-user.target` would pass such an image.
- **It covers the failures an update can cause.** Kernel, initrd, root mount, systemd units, Mesa, the compositor and greetd are all on the path to a running session. If any of them breaks, the session does not come up.
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

## Shown in the dev VM

See the results section below.
