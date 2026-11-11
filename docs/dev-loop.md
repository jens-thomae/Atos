# Dev loop: a shell change on a real screen

Card: #201. Tool: [`tools/dev-push/push`](../tools/dev-push/push). Use it to see a change to the shell (C3) or its `.slint` files on an installed Atos machine without building an image. It is a developer tool for the owner's test PC, not part of the image.

## Set-up (owner, once)

The steps are in the **Owner set-up (final)** comment on #201. Agents never run them, never see a password and never read the private key. In short:

- a dedicated ed25519 key on the Mac and a `Host` alias for the PC in `~/.ssh/config` (`push` accepts nothing else as a host);
- the public key in `/var/home/atos/.ssh/authorized_keys` with `restrict`. `restrict` turns off terminals for this key, so `ssh atos-pc` without a command gives **no interactive shell** (no prompt); `ssh atos-pc '<command>'` works, and that is all `push` needs. For a shell, use the PC's own console;
- `/etc/ssh/sshd_config.d/10-atos-dev.conf`: keys only, no root, only `atos`, and only from the home network: `AddressFamily inet` (sshd does not listen on IPv6, where a global address would reach it from the internet; IPv4 is behind the router's NAT) and `AllowUsers atos@<network>`. The image ships sshd enabled, accepting passwords on every address, with no firewall (#242), so this drop-in is what makes it key-only and LAN-only.

  **`<network>` is the whole home network, never one address.** Take the PC's IPv4 address from `ip -brief addr` and replace its last number with `*`: PC `192.168.178.20/24` gives `AllowUsers atos@192.168.178.*`. A single address (the router's, or the PC's own) locks the Mac out. If the mask is not `/24`, write the network in CIDR form instead, e.g. `atos@10.0.0.0/16`.

  **Apply it with the PC's local terminal open**, and close that terminal only after the Mac has logged in with the new settings:

  ```sh
  sudo sshd -t                      # must print nothing; otherwise fix the file first
  sudo systemctl restart sshd       # a running SSH session stays; only new logins use the new file
  ss -tln | grep ':22 '             # expect only 0.0.0.0:22, no [::]:22
  ```

  Then on the Mac: `ssh -o BatchMode=yes atos-pc 'echo key login works'`. If that fails, the local terminal can still undo it: `sudo rm /etc/ssh/sshd_config.d/10-atos-dev.conf && sudo systemctl restart sshd`, fix the file, try again. Writing the file alone changes nothing until sshd restarts.

**Once per boot, at the PC** (D-015: making `/usr` writable needs the admin password every time). A reboot removes all of it; the SSH set-up and the build cache stay.

```sh
sudo bootc usr-overlay                                   # writable /usr overlay, in RAM
sudo chown atos /usr/bin/atos-shell /usr/bin/atos-comp   # push swaps them without sudo
sudo dnf install -y grim                                 # optional: only for `push screenshot`
```

Check, before pushing:

```sh
findmnt -no FSTYPE,OPTIONS /usr | cut -c1-20               # expect: overlay rw,...
stat -c '%U %n' /usr/bin/atos-shell /usr/bin/atos-comp     # expect: atos, twice
```

`push` refuses (exit 3) if the overlay is off or the shell binary is not writable. It needs no compiler on the PC: it builds in a container.

## Push a change

```sh
tools/dev-push/push atos-pc            # the shell
tools/dev-push/push atos-pc --comp     # the shell and atos-comp
tools/dev-push/push atos-pc --live     # a live-preview shell; see "Slint live preview" below
tools/dev-push/push screenshot atos-pc shot.png
```

What `push` does:

1. Checks that `atos-pc` is a `Host` line in `~/.ssh/config`. It runs ssh with `BatchMode=yes` and password logins off, so it can never ask for a password.
2. On the PC, refuses (exit 3) unless `/usr` is a writable `bootc usr-overlay`, before anything is copied.
3. Sends the working tree (uncommitted edits included, ignored files left out) as a tar stream to the PC, which unpacks it next to its copy in `/var/home/atos/.cache/atos-dev-push/src` and rewrites only the files that differ, in place. Unchanged files keep their times, so cargo rebuilds only what changed. Only the shell's inputs go: `components/c3-shell`, `components/c4-toolkit`, the Slint pin and patch queue, `rust-toolchain.toml`, the Containerfile and this tool, plus `components/c2-compositor` with `--comp`. Files deleted on the Mac stay in the PC's copy; delete that directory if it matters.
4. Builds on the PC with rootless podman (risks: below), in a builder (built once per recipe, see below) made from the image build's own `shell` (or `comp`) stage of [`components/c1-base/Containerfile`](../components/c1-base/Containerfile): the same pinned base, dnf packages and rustup, cut off before the stage copies any source. The toolchain, crates and `target/` stay in podman volumes and the cache directory, across reboots (see "Turning it off"). The Slint fork is fetched again only when its pin or patch queue changes. **Difference from the image:** the build is a plain release build with incremental compilation, without the image's thin LTO, to keep the warm build short.
5. Stops the running shell, copies the new binary over `/usr/bin/atos-shell` in the overlay (owner and mode stay) and waits until the session's restart loop (`atos-session`) has started it and the journal shows its first frame (`BUDGET_FIRST_FRAME`).
6. With `--comp` it also replaces `atos-comp`. That ends the session (it is the session), and greetd asks for the login, because Atos has no autologin (#187).

[`tools/dev-push/test.sh`](../tools/dev-push/test.sh) (run in `ci.yml`) checks the overlay guard, the alias check and that the builder takes the image's stage without any source. Where podman is installed (CI), it also builds and runs a builder twice, and again after a recipe change, under the image's own container policy.

**The image's container policy** (`/usr/share/containers/policy.json`) rejects every image from local storage (`containers-storage:`, #150). `podman build` copies the cached image from local storage when every step of a build is cached, so a second identical build fails with `Source image rejected … is rejected by policy` (exit 125; the first warm push on the PC did, #201). So `push` tags the builder with a hash of its recipe and skips `podman build` while that image exists. A changed recipe builds with `--layers=false` (no layer cache) and removes the older builder. `podman run` of a local image is not checked against the policy. `push` changes no policy file. `push` never calls `sudo` or `bootc`, writes nothing in `/etc`, and writes in `/usr` only the two binaries. The overlay lives in RAM and is gone after a reboot. The installed image is untouched.

`push screenshot` runs `grim` on the PC against atos-comp's screen-capture protocol (ext-image-copy-capture, offered to unsandboxed clients) and writes the PNG on the Mac. Agents use it to check a visual change themselves. **The capture is silent:** atos-comp has no privacy indicator yet (spec §6 C3; card #244), so nothing on the PC's screen shows that a screenshot was taken. Only processes of the `atos` user reach the protocol (the Wayland socket is in `/run/user/<uid>`), which over SSH means whoever holds the key, from the home network. Tested on the PC (2026-11-11): grim 1.5.0 (Fedora 45) captures atos-comp's screen, a 3840 × 2160 PNG in about a second. Screenshots show the owner's screen: agents look at them and do not publish them.

## Risks of building on the PC

The owner accepts these by running the set-up:

- **Third-party code runs on the PC with network access:** crate build scripts and proc macros from crates.io and git, the Slint fork fetch from GitHub, and `dnf` in the builder stage. It runs inside rootless podman as `atos`, so it can reach what `atos` can: the network, and the source and target directories mounted into it. The same code runs in CI and in the image build; here it runs on the owner's machine.
- **SELinux:** the builder's bind mounts use `:z` (shared container label), so the containers stay confined. `:Z` would give each run its own category and relabel the whole `target/` (about 10 GB) every time. On the PC the first `:z` relabel worked (the cold push, 2026-11-11).
- **`chown` of the two binaries:** for the rest of that boot, every process running as `atos` can replace `atos-shell` and `atos-comp`, not only `push`. Today that gives `atos` nothing new: both run as `atos`, and the login prompt is `agreety` on tty1, not drawn by them. **It stops being true once the shell draws the admin prompt or the lock screen** (D-015 makes the admin prompt shell-owned): then a process as `atos` could swap in a shell that captures the admin password. Re-check this before using `push` on a build where the shell draws either.
- **Silent screenshots**, see above (#244).

## Times

From the command to the new shell on screen (owner's PC: RTX 4070 Ti, 4K monitor):

PC: in all = from the command on the Mac to the new shell's first frame (`push: N s in all`); build = the PC's build step. Measured 2026-11-11 over the home network.

| | On the PC: in all (build) | PC side in the dev VM (aarch64, 4 vCPU, no session) |
| --- | --- | --- |
| Cold (first push: base image pull, packages, toolchain, Slint, full build) | 146 s (143 s) | 272 s build |
| Builder recipe changed (builder rebuilt without layer cache, `target/` warm) | 43 s (41 s) | – |
| Warm, nothing changed | 3 s (0 s) | 1 s build |
| Warm, comment added to one `.rs` file | 5 s (1 s) | 5 s build |
| Warm, one `.slint` value changed (plain shell) | 13–21 s (4–5 s) | – |
| First `--live` push (live build, toolchain warm) | 48 s (45 s) | 138 s build |
| `--live`, only `.slint` changed | 0 s (no build; the shell reloads by itself) | 0 s; the reload took under 4 s in `live-preview-test.sh` |
| `--live`, one `.rs` file changed | 6 s (3 s) | – |

The gap between build and in all is mostly the shell's restart: the session loop waits 1 s, but doubles the wait up to 30 s while the shell keeps dying within 30 s of starting, so pushes in quick succession wait longer (the 13–21 s row came right after five pushes). The 40 s frame wait covers that. The VM column ran `push --on-pc` with a writable stand-in for `/usr/bin/atos-shell`, without a session.

## Slint live preview

Question on #201: does Slint's live preview (reloading `.slint` files in the running shell) work with our pinned fork and our own platform backend?

**Yes, with one limit.** Tested by [`tools/dev-push/live-preview-test.sh`](../tools/dev-push/live-preview-test.sh) in the dev VM (2026-11-11): it builds atos-shell with `SLINT_LIVE_PREVIEW=1` and Slint's `live-preview` feature from our fork (1.18.1 + patch queue), runs it on our own platform in headless sway, edits `ui/dock.slint` and checks the screen with `grim`:

| Edit | Result |
| --- | --- |
| New file renamed over `dock.slint` (how most editors, `sed -i` and `tar` save) | not reloaded within 8 s, in two runs |
| `dock.slint` written in place | reloaded within 4 s: the shell logs `Reloaded component Dock/Launcher/ControlCentre`, and the dock turns red |

Our platform needs nothing extra: the live component runs on the event-loop proxy our platform already has (`invoke_from_event_loop`), and the reloaded components reuse their windows, so the layer surfaces stay. The limit is Slint's file watcher (`notify`, one watch per file): a file swapped by rename is not seen. Not investigated further; `push --live` works around it.

**`push atos-pc --live`** builds that live-preview shell on the PC, from the PC's copy of the source at the path the binary then watches, and swaps it in. After that, a push that changes only `.slint` files builds nothing: the PC rewrites the changed files in place and the running shell reloads them (a few seconds). A push that changes anything else builds a new live shell. Edits on the Mac can be saved any way, because the PC writes the files itself. A plain `push` puts the normal shell back.

Use `--live` for tuning only: the live shell carries the Slint compiler and interpreter, so it is bigger and slower to start than the real one, and memory or start-up numbers taken from it say nothing about the §7 budgets. Rust code that sets properties or callbacks keeps working across reloads (Slint sets them again on the new instance).

## Screenshot references after a token change

A change to `docs/design/tokens.json` (then `cargo run -p tokens`) changes every screenshot that shows the changed values. Regenerate all references in the dev VM, then review the PNG diffs in the PR:

```sh
tools/dev-vm/vm run tools/slint-fork/slint-fork.sh setup
cd components/c4-toolkit/test-harness && ../../../tools/dev-vm/vm run env UPDATE_SCREENSHOTS=1 cargo nextest run --config ../../../third_party/slint/patch.toml
cd ../../c3-shell && ../../tools/dev-vm/vm run env UPDATE_SCREENSHOTS=1 cargo nextest run --config ../../third_party/slint/patch.toml
git status --short -- '*.png'
```

Those two crates hold every screenshot test today (`UPDATE_SCREENSHOTS` appears nowhere else). If CI then shows a diff that the VM does not, regenerate from CI's `actual.png` ([screenshot-tests.md](components/c4-toolkit/screenshot-tests.md)).

## Turning it off

A reboot ends the overlay: the swapped binaries, the `chown` and grim are gone. **These stay in `/var/home/atos` across reboots** (about 10 GB with the target directory and toolchain):

- `~/.cache/atos-dev-push` (`src`, `in`, `target`, stamps);
- the podman images `localhost/atos-dev-push-shell:<hash>` and `…-comp:<hash>`, and the pulled base image;
- the podman volumes `atos-dev-push-rustup`, `atos-dev-push-registry` and `atos-dev-push-git`.

To remove them, at the PC as `atos`:

```sh
rm -rf ~/.cache/atos-dev-push
podman rmi --ignore $(podman images -q --filter 'reference=localhost/atos-dev-push-*')
podman rmi --ignore $(podman images -q --filter reference=ghcr.io/jens-thomae/atos/fedora-bootc)   # the base, pulled by digest
podman volume rm --force atos-dev-push-rustup atos-dev-push-registry atos-dev-push-git
```

To remove SSH access for good, see step 7 of the owner set-up on #201: delete the drop-in **and** disable sshd, because without the drop-in the image default (password logins) is back.
