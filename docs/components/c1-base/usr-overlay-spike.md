# Spike: `bootc usr-overlay` on our sealed image (D-015)

Card: #99 · Run: 2026-11-08 in the `atos-c100` dev VM (aarch64), on the shipped image from `main` (fedora-bootc 45, our patched bootc 1.17.1) · Script: [`spikes/c1-usr-overlay/run.sh`](../../../spikes/c1-usr-overlay/run.sh)

This spike decides nothing. It checks item 1 of [developer-mode.md §6](developer-mode.md#6-implementation-cards-it-implies): does `bootc usr-overlay` work on our composefs image, does `dnf install` work inside it, and what does a typical tool cost in RAM. **Keys:** only the committed TEST key set that the shipped image enrols itself; nothing is signed and no key was created. Production code is unchanged.

## Result in one paragraph

**Option A works on our sealed image, and `dnf install` works inside it.** On a Secure Boot machine (`Secure Boot: enabled (user)`, `verity=require`), `/usr` is read-only and `dnf install` refuses to run. After `bootc usr-overlay`, `/usr` is a writable overlayfs, and `dnf install` of `strace`, `tmux`, `gdb` and `gcc` succeeded; the tools ran and `gcc` compiled and ran a program. After a reboot nothing of it was left: no files, no packages, and `dnf history` had forgotten the installs too. The RAM cost is about the **installed size of what is added, plus a fixed ~40 MB the first time `rpm` writes** (section 3). The same image ran all of this with the composefs digest still on its command line.

## 1. What was run

`tools/dev-vm/vm run spikes/c1-usr-overlay/run.sh` runs `image install overlay after transient gone` in order. It reuses `boot()` of `tools/dev-vm/sealed.sh`; guest output is on the serial console, lines start with `ATOS-REPORT-USRO`. Logs: `tools/dev-vm/out/sealed/usrov-*.log`. QEMU runs without KVM, so the **times below mean nothing for real hardware**; the VM has 4 GiB of RAM and the guest reaches the Fedora mirrors through user networking.

Every number below is from the logs of one run of `image install overlay after`, except section 5, whose `transient` and `gone` steps were run again alone: the first run passed `--transient` to dnf5 before the subcommand, which dnf5 rejects (the script is fixed; the failing log was overwritten).

## 2. Does it work, and does `dnf install` work inside it

| Check | Result |
| --- | --- |
| `/` | `overlay ro … verity=require`; `/usr` has no mount of its own |
| `touch /usr/…` before | refused: `Read-only file system` |
| `dnf install strace` before | refused by dnf itself: *"this bootc system is configured to be read-only. Pass --transient to perform this operation in a transient overlay which will reset when the system reboots."* (dnf5 5.4.7 has a bootc check) |
| `bootc usr-overlay` | `A read/write overlayfs is now mounted on /usr. All changes there will be discarded on reboot.` |
| `/usr` after | `overlay rw,… lowerdir=…,upperdir=…,workdir=…` (a plain overlay over the composefs `/usr`) |
| `touch /usr/…` after | ok |
| `dnf install` of `strace`, `tmux`, `gdb`, `gcc` (`install_weak_deps=False`, one call each) | all four ok; `rpm -q` finds them; `strace -V`, `gdb --version`, `tmux -V`, `gcc --version` run; `gcc` compiled and ran a C program (exit code 42). Packages 658 → 677 |
| `composefs=` on the command line afterwards | prints the same digest prefix. This only shows the kernel command line did not change; it does not show that the lower layer is untouched (the script did not re-verify it) |

## 3. RAM

The upper layer is in tmpfs. It does not appear as its own mount (`df -t tmpfs` lists the same tmpfs mounts before and after, none grew), so the script measures `Shmem` and `MemAvailable` from `/proc/meminfo` around each install, and the installed size of all packages (`rpm -qa --qf %{SIZE}`).

| Step | Installed size added | `Shmem` added | `MemAvailable` change |
| --- | --- | --- | --- |
| `bootc usr-overlay` itself | 0 | +4.2 MB | −133 MB (3320840 → 3188152 kB; `Shmem` grew only 4 MB, so most of it is not the overlay's own memory: not investigated) |
| `strace` (first install) | 2.7 MB | **+43.6 MB** | −38.7 MB |
| `tmux` | 1.6 MB | +1.7 MB | −3.2 MB |
| `gdb` | 55.6 MB | +55.1 MB | −70.6 MB |
| `gcc` | 170.7 MB | +175.8 MB | −169.4 MB |
| **All four** | **230.6 MB** | **+289 MB** (175.8 → 464.8 MB) | −465 MB since the baseline before the overlay |

Reading (derived from these numbers, not separately measured):

- Each install costs about its **installed size in RAM** (gdb 55.6 vs 55.1, gcc 170.7 vs 175.8, tmux 1.6 vs 1.7).
- The first install costs **~40 MB more** than its size (strace: 2.7 MB installed, 43.6 MB of `Shmem`). The rpm database lives at `/usr/share/rpm` and is 41 MB; the first write to it copies the whole file into the upper layer. This explains the gap but was not checked directly. Later installs do not pay it again.
- Per tool, without the one-off: **tmux ~2 MB, gdb ~55 MB, gcc ~176 MB** (`strace` itself ~3 MB installed). The one-off ~40 MB comes on top of whichever install is first. All four together: ~290 MB. Nothing was done to test what happens at the tmpfs limit.
- **Open:** between creating the overlay and the start of the `strace` install, `Shmem` grew by 8.4 MB (179996 → 188428 kB) with nothing of ours running. Not explained.
- The `dnf` package cache is **not** RAM: `/var/cache` went 72 kB → 88.7 MB on the disk and stays after reboot (`var cache after reboot: 88712 kB`). That is a disk cost of developer mode option A that `bootc usr-overlay`'s description does not mention.

## 4. After a reboot

| Check | Result |
| --- | --- |
| `/usr` marker file, `strace`, `tmux`, `gdb`, `gcc` | all gone (`package … is not installed`); `/usr` is read-only again |
| Markers written to `/etc` and `/var` during the overlay | still there: `/etc` and `/var` were never part of the overlay |
| `dnf history` | after the reboot the list holds only IDs 1 and 2 (the image build); before it, the script's `tail -n 4` of dnf5's newest-first list showed IDs 4 and 3 (by their times `tmux` and `strace`) and cut off the newer IDs for `gdb` and `gcc`, so the log does not show how many entries the overlay held. That the history is gone with the overlay is an inference from where dnf5 keeps it (under `/usr`, not checked); `dnf list --installed strace`: `No matches found` |
| `/var/cache` | unchanged (88.7 MB), see above |

## 5. Other behaviour

- **`bootc usr-overlay --read-only`** works (`/usr` mounts `ro`; writes are refused). It was tried only on a fresh boot, not on an already writable overlay.
- **A second `bootc usr-overlay`** while an overlay is mounted prints `An overlayfs is already mounted on /usr` and succeeds without changing it. After `--read-only` the second call therefore leaves `/usr` read-only: writes still refused.
- **`dnf install --transient`** (no prior `usr-overlay`): `OK`; `strace` runs afterwards (`strace -- version 7.3`). `Shmem` grew by 56 MB (175.8 → 232.0 MB). **dnf leaves `/usr` mounted read-only** (`ro` in the mount options) when it is done. That the overlay then cannot be written to is inferred from `ro`; no write was tried. After the next reboot `strace` is not installed. So dnf's own flag is an alternative entry point to `bootc usr-overlay` that needs no separate step; the card did not ask for it, it is here because dnf's error message points to it.

## 6. What this means for D-015

Option A as D-015 describes it holds on our image: transient, key-free, `/etc` and `/var` untouched, gone after a reboot. Points for the follow-up cards:

1. **Warn about RAM.** The cost is real: gcc is ~176 MB, plus ~40 MB once. The shell's usr-overlay entry (card #105 and the developer-mode UI) should say it, not only "discarded on reboot".
2. **Packages are not persistent, but the dnf cache is.** `/var/cache` grew by ~88 MB on disk in this run (four installs). Not a trust issue; it is the reason a user may see disk use go up after a "transient" session.
3. **Not checked:** x86_64 (this ran on aarch64 only); behaviour at the tmpfs size limit or under memory pressure; SELinux denials during the installs (the guest was `Enforcing`; the log shows no failures, but denials were not searched for); a `systemctl` restart of services after replacing files in `/usr`; an image update (`bootc upgrade`) while an overlay is mounted.

## Sources

- [bootc-usr-overlay(8)](https://bootc.dev/bootc/man/bootc-usr-overlay.8.html), [composefs backend](https://bootc.dev/bootc/bootc-composefs.7.html): as cited in developer-mode.md 2.1; behaviour above comes from the run, not from these pages.
