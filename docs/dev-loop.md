# Dev loop: a shell change on a real screen

Card: #201. Tool: [`tools/dev-push/push`](../tools/dev-push/push). Use it to see a change to the shell (C3) or its `.slint` files on an installed Atos machine without building an image. It is a developer tool for the owner's test PC, not part of the image.

## Set-up (owner, once)

The steps are in the **Owner set-up** comment on #201. Agents never run them, never see a password and never read the private key. In short:

- a dedicated ed25519 key on the Mac and a `Host` alias for the PC in `~/.ssh/config` (`push` accepts nothing else as a host);
- the public key in `/var/home/atos/.ssh/authorized_keys` with `restrict`;
- `/etc/ssh/sshd_config.d/10-atos-dev.conf`: keys only, no root, only `atos`. The image ships sshd enabled and accepting passwords (#242), so this drop-in is what makes it key-only.

**Once per boot, at the PC** (D-015: making `/usr` writable needs the admin password every time):

```sh
sudo bootc usr-overlay
sudo chown atos /usr/bin/atos-shell /usr/bin/atos-comp
sudo dnf install -y grim     # only for `push screenshot`
```

`findmnt /usr` shows `overlay` with `rw,…upperdir=…` while it is on. A reboot removes all three.

## Push a change

```sh
tools/dev-push/push atos-pc            # the shell
tools/dev-push/push atos-pc --comp     # the shell and atos-comp
tools/dev-push/push screenshot atos-pc shot.png
```

What `push` does:

1. Checks that `atos-pc` is a `Host` line in `~/.ssh/config`. It runs ssh with `BatchMode=yes` and password logins off, so it can never ask for a password.
2. On the PC, refuses (exit 3) unless `/usr` is a writable `bootc usr-overlay`, before anything is copied.
3. Sends the working tree (uncommitted edits included, ignored files left out) as a tar stream to `/var/home/atos/.cache/atos-dev-push/src`. Only the shell's inputs go: `components/c3-shell`, `components/c4-toolkit`, the Slint pin and patch queue, `rust-toolchain.toml`, the Containerfile and this tool, plus `components/c2-compositor` with `--comp`. File times are kept, so cargo rebuilds only what changed.
4. Builds on the PC with rootless podman, in a builder made from the image build's own `shell` (or `comp`) stage of [`components/c1-base/Containerfile`](../components/c1-base/Containerfile): the same pinned base, dnf packages and rustup, cut off before the stage copies any source. The toolchain, crates and `target/` stay in podman volumes and the cache directory. The Slint fork is fetched again only when its pin or patch queue changes. **Difference from the image:** the build is a plain release build with incremental compilation, without the image's thin LTO, to keep the warm build short.
5. Stops the running shell, copies the new binary over `/usr/bin/atos-shell` in the overlay (owner and mode stay) and waits until the session's restart loop (`atos-session`) has started it and the journal shows its first frame (`BUDGET_FIRST_FRAME`).
6. With `--comp` it also replaces `atos-comp`. That ends the session (it is the session), and greetd asks for the login, because Atos has no autologin (#187).

[`tools/dev-push/test.sh`](../tools/dev-push/test.sh) (run in `ci.yml`) checks the overlay guard, the alias check and that the builder takes the image's stage without any source. `push` never calls `sudo` or `bootc`, writes nothing in `/etc`, and writes in `/usr` only the two binaries. The overlay lives in RAM and is gone after a reboot. The installed image is untouched.

`push screenshot` runs `grim` on the PC against atos-comp's screen-capture protocol (ext-image-copy-capture, offered to unsandboxed clients) and writes the PNG on the Mac. Agents use it to check a visual change themselves.

## Times

From the command to the new shell on screen, 4K monitor, RTX 4070 Ti PC:

| | Measured |
| --- | --- |
| Cold (first push after set-up: base image, packages, toolchain, Slint, full build) | not yet: PC not reachable when the tool was written |
| Warm (one `.slint` or `.rs` change) | not yet |

Estimates on #201: cold 6–10 min, warm 20–60 s.

## Slint live preview

Question on #201: does Slint's live preview (reloading `.slint` files in the running shell) work with our pinned fork and our own platform backend?

LIVE_PREVIEW_ANSWER

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

A reboot ends the overlay. To remove SSH access for good, see step 7 of the owner set-up on #201: delete the drop-in **and** disable sshd, because without the drop-in the image default (password logins) is back.
