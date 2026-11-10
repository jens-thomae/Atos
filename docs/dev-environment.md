# Dev environment: Linux VM on macOS

Most Atos code needs Wayland, AT-SPI or systemd and does not build or run on macOS. On the owner's Mac (Apple M1 Max) it builds and runs its headless tests in a Linux VM defined in `tools/dev-vm/` (card #16).

## Use

One-time host setup: `brew install lima` (Lima 2.x).

```sh
tools/dev-vm/vm up                         # create or start the VM; installs Rust and cargo-nextest
tools/dev-vm/vm run cargo nextest run      # any command, in the same directory inside the VM
tools/dev-vm/vm smoke                      # headless Wayland screenshot + AT-SPI tree check
limactl shell atos                         # interactive shell
limactl stop atos / limactl delete atos    # stop, or throw it away
```

- Measured on the M1 Max (2026-11-03): first `vm up` from scratch 1 min 27 s (including the ~600 MB image download); restart of a stopped VM 11 s.
- The main checkout (including `.claude/worktrees/*`) is mounted read-write at the same path as on the host, so `vm run` works from any directory inside it.
- Build output goes to `~/target/<checkout path>` on the VM disk (`CARGO_TARGET_DIR`), not to the shared `target/`: Linux and macOS artifacts must not mix, and the shared folder is slow for builds.
- The Rust toolchain comes from `rust-toolchain.toml`; `cargo-nextest` is the version pinned in `.github/workflows/ci.yml` (`vm up` fails if they drift apart).
- The VM is Ubuntu 24.04 to match the CI runner. It is a dev tool only, not a choice of base distribution (D-008), and may change after D-008.
- The mount is set when the VM is created. After moving the checkout: `limactl delete atos && tools/dev-vm/vm up`.
- `tools/dev-vm/sealed.sh` builds the sealed base image, installs it and boots it with Secure Boot under QEMU inside the VM, then runs a tamper check (#54). It needs the HWE kernel and is best run in its own instance; see [`docs/components/c1-base/`](components/c1-base/README.md#rebuild-and-boot-it-in-the-dev-vm).
- `ATOS_VM=atos-check tools/dev-vm/vm up` creates a separate instance, for example to test a change to `atos.yaml` without touching `atos`. Delete it afterwards with `limactl delete -f atos-check`.

## Disk space

Every checkout (main and each `.claude/worktrees/*`) builds into its own `~/target/<checkout path>`, 8–10 GB each. Two rules keep several parallel sessions from filling the disk (#213):

- Before every `vm run` and `vm up`, `tools/dev-vm/gc.sh` deletes the cache of any checkout that no longer exists. Caches of existing checkouts are never touched.
- The same script warns when less than 5 GB is free and lists the largest caches. Then delete caches of finished checkouts: `limactl shell atos -- rm -rf ~/target/<checkout path>`.
- New VMs get a 100 GiB disk (`atos.yaml`; it is sparse, so the Mac only uses what the VM writes). The size applies only when the VM is created. A VM made earlier keeps 50 GiB; to get 100 GiB, stop all sessions that use it, then `limactl delete atos && tools/dev-vm/vm up`. This loses its build caches.

A shared target dir was rejected: parallel builds would block on cargo's lock, and workspace crates rebuild per path anyway.

## Pinned inputs

Everything `vm up` downloads is pinned and checked, except apt packages:

- Ubuntu cloud image: dated `release-YYYYMMDD` URL plus sha256 digest in `atos.yaml`, with no fallback. Ubuntu removes dated images after some months; bumping the URL and digest (from that release's `SHA256SUMS`) is then a deliberate edit, followed by a fresh VM.
- `rustup-init`: version and sha256 in `atos.yaml`; rustup self-update is disabled. The toolchain it installs is checked by rustup against the signed channel manifest.
- `cargo-nextest`: version and sha256 in `tools/dev-vm/vm`.
- apt packages are not pinned. They come from the Ubuntu archive, which apt verifies by signature; acceptable for a dev VM.

## Security

- Only the main checkout is mounted, read-write. That includes `.git/`: code running in the VM can write `.git/hooks/*` or `.git/config`, which then run on the host at the next git command. The VM is not a sandbox; do not run untrusted code in it.
- No ports are forwarded from the VM to the host; SSH agent and X11 forwarding are off.

## Smoke check

`tools/dev-vm/smoke.sh` runs inside the VM, in its own D-Bus session:

1. Starts weston with its headless backend and the pixman software renderer, runs `weston-simple-shm` and `zenity` as Wayland clients, and saves a screenshot with `weston-screenshooter`.
2. Lists the AT-SPI accessibility tree of the running `zenity` window and checks that its label is in it.

Output goes to `tools/dev-vm/out/` (ignored by git): `screenshot.png`, `atspi-tree.txt`, `weston.log`.

## Tool choice

The tool must be scriptable from the command line so agents can use it without a GUI.

| Candidate | Create from CLI | Run a command inside | Repo mount | Licence |
| --- | --- | --- | --- | --- |
| **Lima** (chosen) | Yes, from a YAML file in the repo (`limactl start`) | `limactl shell <vm> -- <cmd>` | virtiofs via Apple Virtualization (vz), read-write | Apache-2.0, CNCF project |
| OrbStack | Yes (`orb create`) | `orb run` | Whole home folder, automatic | Proprietary; paid licence for commercial use |
| UTM | No: `utmctl` starts and stops existing VMs, creation is GUI or AppleScript | `utmctl exec`, needs the QEMU guest agent | Manual setup per VM | Apache-2.0 |

Lima is the only candidate where the whole VM (image, resources, packages, mount) is one reviewed file in the repo and every step is a CLI command. UTM is already installed on the owner's Mac but cannot create a VM without the GUI.

## Limits

- **Not for budgets.** The VM is aarch64 on Apple silicon, virtualised; the reference hardware is an x86_64 Intel NUC 11 (Celeron N5105, card #17). Performance numbers from the VM never count toward the §7 budgets. Budgets are measured in CI and on the reference hardware.
- No x86_64 emulation.
- Rendering is software only (pixman); no GPU.
- Headless only: no window on the Mac.
