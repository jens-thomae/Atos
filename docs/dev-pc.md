# Build host: the Atos test PC

Card: #273 (spike, security lane). Tool: [`tools/dev-pc/pc`](../tools/dev-pc/pc). Sessions build and test on the owner's test PC (x86_64, Ryzen 7 7700, 16 threads, 30 GB RAM, RTX 4070 Ti, about 830 GB free) over SSH; the Mac stays the cockpit. The owner allowed full access on 2026-11-11 (card #273); what that needs in practice is below, as options. Nothing here is applied yet beyond the existing SSH set-up from #201.

## Use

```sh
tools/dev-pc/pc run cargo nextest run --config ../../third_party/slint/patch.toml   # in the build container
tools/dev-pc/pc host podman build --build-context repo=. -t localhost/atos-build-c1 components/c1-base   # on the PC itself
```

Same interface as `tools/dev-vm/vm run`: the command runs in the same directory of the PC's copy of this checkout. Every call first sends the working tree (uncommitted edits included, ignored files left out) as a tar stream, the way `tools/dev-push/push` does, and rewrites only the files that differ, so cargo rebuilds only what changed. Files deleted here stay in the PC's copy (`pc host rm …` removes one). The PC host is `$ATOS_PC`, default `atos-pc`, which must be a `Host` alias in `~/.ssh/config` (#201). `pc` runs ssh with `BatchMode`, so it never asks for a password, and it never calls `sudo`.

- **`pc run`** runs in a fresh `podman run --rm` container of dev-push's builder image: the image build's own `comp` stage of [`components/c1-base/Containerfile`](../components/c1-base/Containerfile) under `components/c2-compositor`, its `shell` stage everywhere else (the same pinned base, dnf packages and rustup, cut off before the stage copies any source; built once per recipe, tagged with its hash). `cargo-nextest` at `ci.yml`'s pin and checksum is mounted in. Build output goes to one `CARGO_TARGET_DIR` per checkout. Debug builds, as in CI.
- **`pc host`** runs on the PC as `atos`, with `PATH=/usr/bin:/usr/sbin` (not the owner's Homebrew or `~/.cargo`). For rootless `podman build` of the image and for QEMU.
- [`tools/dev-pc/test.sh`](../tools/dev-pc/test.sh) (in `ci.yml`) checks the stage choice, the checkout-name check and that a command reaches the PC word for word. The host alias check and the builder under the image's container policy are dev-push's, tested by `tools/dev-push/test.sh`.

**Recommended over the app's SSH session target.** That target runs Claude Code itself on the PC, which needs Claude Code and its login (a credential) stored there, plus the repository and its git credentials for commits. `pc` keeps every credential, the git checkout and the session on the Mac and sends only the source tree; the PC only builds. The SSH target would be worth a second look only if the owner wants sessions that live on the PC.

### Where things live on the PC

All in `/var/home/atos`, which is outside the image, so it survives reboots, `bootc upgrade` and `bootc rollback`:

| What | Where |
| --- | --- |
| Source copy and build output, per checkout | `~/atos-build/<checkout>/{src,in,target}` (`<checkout>` is the worktree's directory name); 15 GB after C2, C3 and their tests |
| `cargo-nextest` | `~/atos-build/bin/` |
| Builder images (shared with `push`) | `localhost/atos-dev-push-{shell,comp}:<recipe hash>`, about 3–4 GB each |
| Toolchain, crates, git deps (shared with `push`) | podman volumes `atos-dev-push-rustup`, `-registry`, `-git` |

Nothing runs between calls: no long-lived container, no user service, no lingering. A "persistent container" is not needed; persistence is the image, the volumes and the target directory, and a container lives for one command.

**The image's container policy** (`/usr/share/containers/policy.json`) rejects images from local storage (`containers-storage:`, #150). `pc` uses dev-push's way around it unchanged: the builder is built with `--layers=false` only when its recipe hash is new, and run with `podman run` (not checked against the policy). No policy file is changed, and no `--signature-policy` is passed.

## Times

Measured 2026-11-11 on the PC, from the Mac (`time tools/dev-pc/pc run …`, so sync and container start are included; about 1–2 s). "Cold" means an empty target directory with the builder image, toolchain and crate downloads already warm from dev-push; the first-ever cold run adds the builder (dev-push measured 143 s for base pull, packages, toolchain and a full shell build).

| Step | PC cold | PC warm | CI (hosted, latest green run) | Mac dev VM (aarch64, 4 vCPU) |
| --- | --- | --- | --- | --- |
| C2 `cargo build --workspace --locked` | 55 s | 1 s no change; 6 s one `.rs` file | – | – |
| C2 build + test + clippy (the `c2-compositor.yml` steps) | 88 s | 15 s one `.rs` file | 110 s job (rust-cache warm) | – |
| Slint fork setup | 5 s | – | – | – |
| C3 fmt + clippy + nextest (70 tests) | 52 s | 3 s one `.rs` file; 2 s no change | 451 s `build` job (also release builds) | – |
| C3 release build (dev-push, plain release) | 143 s incl. builder | 1 s one `.rs` file | – | 272 s |
| Full `c1-base` image build (`podman build`, rootless) | 687 s (base image already pulled) | rejected after 13 s when nothing changed (below); 126 s after one C3 `.rs` change (only the shell stage and the stages after it) | 986 s (with registry layer cache) | not measured (no x86_64) |
| Shell boot test (`shell-boot-test.sh`) | cannot run as `atos` (below) | – | 275 s | minutes per boot without KVM |
| Installer test (ISO 653 s + install and two boots 339 s) | cannot run as `atos` (below) | – | 992 s | without KVM: minutes per boot |

The Mac dev VM column is empty where it was not measured this time: the VM is shared by parallel sessions and its disk filled twice on 2026-11-11; its earlier numbers are in [dev-loop.md](dev-loop.md#times).

Three numbers matter: a C3 lint-and-test round from cold is about **52 s** on the PC against **7.5 min** in CI; a warm round is **2–3 s**; the image build takes **11.5 min** cold, rootless (CI: 16 min).

**The image build and the container policy.** `pc host podman build … components/c1-base` builds the whole image rootless, as CI does (11 stages; the nvidia modules and both release builds included). Rebuilding with nothing changed fails after 13 s with `Source image rejected: Running image containers-storage:…` (exit 125): every step is cached, so podman copies the cached image out of local storage, which the image's policy rejects (#150, the same as dev-push's builder, #201). There is nothing to rebuild in that case anyway; any changed input leaves the last step uncached and the build passes. `--layers=false` also avoids it, at the cost of a cold build every time. `check-seal.sh` needs `sbverify` (sbsigntools), which the installed image does not have (#249); run it in CI, or in a container that installs it.

## KVM and the boot tests

- `/dev/kvm` is `crw-rw-rw-` on the installed image: usable without root. Nested virtualisation is on (`kvm_amd nested=1`).
- QEMU works in a rootless container: `qemu-system-x86-core`, `edk2-ovmf` and `swtpm` from Fedora 45 in the base image, `podman run --device /dev/kvm`, OVMF boots under KVM (39 s including the package install). Nested KVM also works: a Fedora Cloud 43 VM under rootless QEMU/KVM in a container on the PC booted in 10 s, ran its check as root (uid 0) and saw `/dev/kvm` and the `svm` CPU flag inside, so a VM on the PC can run the KVM tests with root of its own.
- `bootc install to-disk` from rootless podman stops with `/proc/1 is owned by 65534, not zero; this command must be run in the root user namespace (e.g. not rootless podman)` (tried on the PC with the image built above).
- **What stops both tests as `atos` is root, not KVM:**
  - `shell-boot-test.sh` makes its disk with `sudo podman run --privileged … bootc install to-disk --via-loopback`: loop devices (`/dev/loop-control` is `root:disk 0660`) and mounts need real root; rootless podman cannot give them. It also `sudo podman pull`s into root's storage.
  - `vm-test.sh` (installer) builds the images and the ISO with `sudo podman build` and `build-iso.sh`'s `sudo podman run --privileged` (image builder, loop mounts), and runs its registry in root's podman. The boots themselves (QEMU, OVMF, swtpm) need no root.
- Two ways to run them on the PC, for the owner (below): root for `atos`, or a VM on the PC in which the tests get root.

## What "full access" needs (options for the owner)

Today's key is `restrict`ed: any command runs as `atos`, with no terminal and no forwarding. **That already is full access to the `atos` account**: `pc` and everything measured above work with it. What `restrict` blocks is a terminal (pty) and port, agent and X11 forwarding.

| Option | Owner runs (at the PC, once) | Gives | Exposes |
| --- | --- | --- | --- |
| **A. Keep the restricted key** (recommended) | nothing | C2, C3, tests, rootless image builds, QEMU/KVM | the `atos` account: its files (including the owner's own in `/var/home/atos`), its screen (`push screenshot`), the network as `atos` |
| B. Unrestricted key | in `~/.ssh/authorized_keys`, delete `restrict,` before the key | an interactive shell; port forwarding. `restrict,pty` instead gives only the shell and keeps forwarding off | as A, plus forwarding: the PC becomes a relay from the Mac to anything it reaches |
| C. Root for the boot tests, in a VM on the PC | nothing on the host: a follow-up card builds a rootless x86_64 VM (Fedora Cloud under QEMU/KVM, like `tools/dev-vm`) with nested KVM, where the tests run with `sudo` | shell boot test and installer test locally, with root only inside a throwaway VM | as A; the VM's root cannot touch the PC's disk or trust |
| D. Passwordless root for `atos` | `echo 'atos ALL=(ALL) NOPASSWD: ALL' \| sudo tee /etc/sudoers.d/90-atos-agents && sudo chmod 440 /etc/sudoers.d/90-atos-agents && sudo visudo -c` | the tests as written; `bootc usr-overlay` without the owner at the PC | everything: any process as `atos` (crate build scripts included) becomes root; it can `bootc switch` to any image, change the trust policy, unseal the disk key from the TPM and read every file. Undo: `sudo rm /etc/sudoers.d/90-atos-agents` |

A narrow sudoers rule (only `podman`, only `bootc usr-overlay`) is no real limit: `sudo podman run --privileged -v /:/host` is root. So D is all or nothing.

**Recommendation: A now, C as the next card, not D.** A covers the daily work. C gets the KVM tests onto the PC without root on the host, and keeps the disk-wiping steps inside a VM (guard rail 3). D would also skip D-015's "admin password every time" for `usr-overlay` on this machine; that is the owner's call for a test PC, but it turns every crate build script into root. Agents never see or type a password in any option.

## When Atos on the PC changes

| Event | Running work | What stays | Resume |
| --- | --- | --- | --- |
| Reboot (or `bootc upgrade` then reboot) | the SSH session and its container end; `pc` exits non-zero | all of `/var/home/atos`: source copy, target dirs, images, volumes. dev-push's `usr-overlay` and its two swapped binaries are gone | run the same `pc` command again; cargo continues incrementally |
| `bootc upgrade` staged, not yet rebooted | nothing changes | everything | – |
| Rollback (`bootc rollback`, or the previous boot entry) | as a reboot | as a reboot: `/var` is shared by both deployments | as a reboot. If the older image has an older podman, run `podman system migrate` once with `pc host` |
| A new base or recipe in `Containerfile` | – | the old builder until the next call | the next call builds the new builder (about 40 s) and removes the old one |
| Atos broken (no boot, no network) | – | the disk, untouched | the owner picks the previous entry in systemd-boot (with boot counting, #56, a failed boot falls back on its own); until then sessions use the Mac dev VM and CI, as before #273 |
| PC off or asleep | `ssh` fails at once (`BatchMode`) | everything | as above |

A killed command leaves no state behind but a partial target directory, which cargo handles. Nothing on the PC is the only copy of anything: the source is on the Mac, results go to the session's terminal.

## Guard rails (planner's proposal on #273, builder's view)

1. **The PC is never a GitHub Actions runner for this public repository.** Agree: a fork PR could run its code on the owner's home network. `pc` needs no runner; CI stays on GitHub.
2. **No GitHub credential with more than this repository's scope on it.** Agree, and tighten it: **no credential at all.** `pc` sends source as a tar stream; commits, pushes and PRs stay on the Mac (`gh` and git credentials in the Mac's keychain). The PC pulls only public things: the base image, Fedora packages, crates, the Slint fork, nextest.
3. **Disk-wiping tests only in VMs on the PC.** Agree. The boot tests' `sudo podman run --privileged -v /dev:/dev` is the step that could reach the PC's own disk; in option C it runs inside a VM.
4. **No scanning or connecting to other devices on the home network; backup drive unplugged when not needed.** Agree. Note that build scripts in containers have network access as `atos` and are not technically kept off the LAN; keeping the key `restrict`ed at least stops forwarding through the PC.
5. **One owner of pushes to the running session.** Agree. `pc` never writes `/usr`, never touches the session or the screen; only `push` does.

Added:

6. **Nothing left running.** `pc` runs one container per command with `--rm`; no services, timers or lingering for agents. A session that starts something long on the PC stops it before it ends.
7. **Stay out of the owner's files.** Agents write only under `~/atos-build`, `~/.cache/atos-dev-push` and podman objects named `atos-build-*` or `atos-dev-push-*`; `pc` resets `PATH` so the owner's Homebrew and `~/.cargo` are not used.
8. **CI and the NUC stay the gate.** The PC's results are for fast feedback; CI decides, and §7 numbers come only from the NUC.

## Clean up

At the PC as `atos`, or from the Mac with `ssh atos-pc '…'`:

```sh
rm -rf ~/atos-build                 # all checkouts' copies and targets, nextest
rm -rf ~/atos-build/<checkout>      # or only one finished checkout
podman rmi --ignore localhost/atos-build-c1 && podman image prune -f   # an image build and its layer cache
```

The builder images and `atos-dev-push-*` volumes are shared with `push`; [dev-loop.md](dev-loop.md#turning-it-off) removes them.
