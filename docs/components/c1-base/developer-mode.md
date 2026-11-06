# C1: developer mode under sealed images

Card: #68 · Written: 2026-11-06 · Status: **design write-up; every choice here is _Proposed_.** The owner decides. Nothing was built or booted for it.

Upstream facts link to their source. All links were opened on 2026-11-06. **Not checked** means I found no source either way.

## 1. What developer mode has to do

§6 C1: *"A developer mode allows a writable overlay or package layering, behind a dismissible warning."* §2 priority 6: users can change anything; the OS warns but does not block. The background for this card adds the concrete needs: change `/usr`, boot your own builds, and run unsandboxed tools (D-012 Q-E), without weakening the security model for anyone who has not turned developer mode on.

Decided constraints this design must not contradict:

- **D-008.** bootc on Fedora, sealed composefs, UKI, systemd-boot. The composefs root digest sits in the UKI command line, and Secure Boot authenticates the UKI.
- **D-014.** A per-machine PK (discarded after enrolment) and KEK. No Microsoft KEK. The KEK private key stays on the machine, root-only, so updates can change db and dbx. D-014 §4.2 already lists a **developer key** (RSA-2048, generated when developer mode is turned on, signs locally built UKIs on that machine, root-only, removed from db and deleted when developer mode is turned off). Clients enforce `sigstoreSigned` with pinned release keys. LUKS is to be bound to PCR7 plus a signed PCR11 policy (design in #66).
- **D-012.** Assistants are sandboxed Flatpaks behind a broker. Unsandboxed same-UID code is outside the model, because it can edit the log and the grants. Q-E asked whether developer mode may allow an unsandboxed assistant behind a warning, and the owner's D-012 rationale says it may.

### 1.1 What the seal protects today

To judge what developer mode weakens, first the baseline (from D-014 §6 and the tamper checks in [README](README.md#tamper-check)):

| Protection | Stops | Does not stop |
| --- | --- | --- |
| **Secure Boot** (db holds the Atos release cert) | Booting a UKI or systemd-boot that Atos did not sign | Root at runtime: it holds the per-machine KEK and can add its own db key. That changes PCR7 |
| **Seal** (composefs digest in the signed UKI, fs-verity) | Offline changes to `/usr`, and changes that persist across reboots | Root at runtime changing the *running* system (mount namespaces, `/etc`, `/var`) until the next reboot |
| **TPM-bound disk key** (PCR7 + signed PCR11, #66) | A foreign boot chain or a changed db getting the disk key without the recovery key | Code that boots through an Atos-signed UKI |
| **Signature policy** (`policy.json`, `sigstoreSigned`, #75) | `bootc upgrade`/`switch` pulling an image that Atos did not sign | Anything already root |
| **Assistant sandbox** (D-012) | Assistants acting outside the broker | Unsandboxed code running as the user |

The key property: **a runtime root compromise does not survive a reboot silently.** It either loses its changes (seal) or changes PCR7 and trips the recovery-key prompt (TPM). Each option below is judged by how much of that property it gives up.

## 2. Options

The card names three. Each section ends with what it does to the five protections in 1.1, to automatic updates, and how to leave.

### 2.1 Option A: `bootc usr-overlay` (transient writable `/usr`)

[bootc-usr-overlay(8)](https://bootc.dev/bootc/man/bootc-usr-overlay.8.html): *"Adds a transient overlayfs on `/usr` that will be discarded on reboot."* The upper layer is a tmpfs, so written data lives in RAM. `/etc` and `/var` are unaffected. A `--read-only` option exists. The [composefs backend page](https://bootc.dev/bootc/bootc-composefs.7.html) lists `usr-overlay` among the supported commands. Whether `dnf install` works inside it on our image: **not checked**.

- **Secure Boot:** unchanged. No key, no db change.
- **Seal:** unchanged on disk. For the current boot, `/usr` no longer matches the digest, but only root can turn the overlay on, and root can already change the running system. Nothing persists, so the property in 1.1 holds.
- **TPM:** unchanged.
- **Signature policy:** unchanged.
- **Assistant sandbox:** unchanged. Flatpaks do not see the host `/usr`.
- **Automatic updates:** unchanged. A staged update applies on the next reboot, and the overlay is discarded by the same reboot.
- **How to leave:** reboot.
- **Limits:** not persistent, so it does not meet "package layering" or "boot your own builds". RAM-backed, so large installs cost memory. It suits "try a patched binary" or "install a debug tool for this session".

### 2.2 Option B: local images signed with a per-machine developer key

The developer writes a `Containerfile` `FROM` the booted Atos release image, builds it with podman, and boots it. A sealed machine boots only a UKI signed by a key in db, so developer mode enrols a **developer key** into db with the per-machine KEK, as D-014 §4.2 already plans. Flow:

1. **Turn on.** Generate the developer key on the machine (RSA-2048 X.509, like D-014's other db keys). Append its cert to db with the per-machine KEK. No firmware step: the KEK is enough to append to db. **PCR7 changes**, so the TPM disk key must be resealed before the reboot (section 2.2.1).
2. **Build.** `podman build` the developer's `Containerfile`. The base must be the Atos release image, verified against the release `policy.json`. Then seal it the way our [Containerfile](../../../components/c1-base/Containerfile) does (split kernel, `bootc container ukify`), but sign with the developer key. Upstream says *"it is not yet streamlined to regenerate the UKI locally"* ([sealed images](https://bootc.dev/bootc/building/bootc-sealed-images.7.html)). We would carry a small build wrapper; its size is **not checked**.
3. **Switch.** `bootc switch --transport containers-storage <local ref>` ([bootc-switch(8)](https://bootc.dev/bootc/man/bootc-switch.8.html)), then reboot. The local image is not signed by Atos, so the client trust policy (#75) needs an exception for that local reference (section 2.2.2).

What it weakens:

- **Secure Boot:** db now trusts a second key, and its private key is on the machine. Anything that can use that key can sign a UKI that boots **without changing PCR7**. That is the real difference from the baseline: today root malware can also add a db key with the KEK, but the PCR7 change trips the recovery-key prompt. With the developer key already enrolled, a malicious UKI signed with it boots with no PCR7 change. The scope is that one machine only: the key never leaves it, and a UKI signed on one machine does not boot on another.
- **Seal:** still enforced; the seal now covers the developer's image. But whoever can use the developer key can seal any image. So in developer mode, **a runtime root compromise can make itself persistent.** That is the main cost of option B.
- **TPM:** see 2.2.1. Either the disk unlocks silently for developer-signed UKIs (so a persistent compromise also gets the disk key), or developer-signed boots ask for a PIN or the recovery key.
- **Signature policy:** a scoped exception for local images. Registry pulls stay `sigstoreSigned`. The version floor (#75) applies to registry pulls only, so local images are not affected by it.
- **Assistant sandbox:** unchanged by the image path itself. But signing and switching must not be reachable without the user's own authentication, or an unsandboxed process (Q-E) could install a persistent image. See section 3.
- **Automatic updates:** after `bootc switch` to a local reference, `bootc upgrade` follows that reference, so **release updates stop reaching the machine.** Developer mode needs a rebuild service: when a new signed release image appears, pull it (verified), rebuild the developer's `Containerfile` on it, sign, stage. If the build fails, keep the current image and tell the user. Without this, a developer machine stops getting security fixes.
- **Rollback:** the composefs backend keeps exactly two deployments ([composefs](https://bootc.dev/bootc/bootc-composefs.7.html)). After the first switch, "Previous version" is the last release image, which is a good way out. After the second local build, both entries are developer images. Staging replaces the non-booted entry, and the booted one has just booted, so with boot counting (#56) a broken new build falls back to the current one. A build that boots but breaks the session still leaves the user on two developer images. The way out is leaving developer mode (below) from a terminal, or the installer's recovery.
- **How to leave** (order matters):
  1. `bootc switch` back to the release image in the registry, verified with the release policy and version floor. Reboot into it.
  2. Once a release UKI has booted: rewrite db **without** the developer cert, using the KEK (a full write, not an append). Optionally add the cert's hash to dbx; free dbx space in firmware is limited, so this is a question (Q5).
  3. Delete the developer key, remove the TPM token for developer UKIs and the policy exception. Reseal the disk key for the new PCR7.
  4. Remove developer UKIs left on the ESP.

  After step 2, nothing signed with the developer key boots any more, even if the key was copied while developer mode was on. That makes leaving effective against a past compromise of the developer key, **but not against a past root compromise**: root also held the KEK in that period and could have enrolled a key of its own. That case already exists without developer mode, and the PCR7 check is what catches it.

#### 2.2.1 Disk unlock for developer-signed UKIs

D-014 plans LUKS bound to PCR7 plus a PCR11 policy signed by Atos (`systemd-measure`, [systemd-measure(1)](https://www.freedesktop.org/software/systemd/man/latest/systemd-measure.html)). A developer UKI is not signed by the Atos PCR key, so it would not unlock the disk. Choices:

- **(i) Silent.** Developer UKIs carry a developer PCR-signing key (the same developer key or a second one), and developer mode adds a second TPM2 LUKS token bound to it (`systemd-cryptenroll --tpm2-public-key=`). Developer boots unlock like release boots. The cost: a persistent compromise (2.2) also gets the disk key.
- **(ii) TPM2 + PIN.** The same, but the token needs a PIN (`--tpm2-with-pin`). A thief with the laptop cannot boot a developer UKI to the disk. Root malware with a persistent UKI still gets the PIN the next time the user types it. The cost: a PIN at every developer boot.
- **(iii) Recovery key.** No token for developer UKIs. Every developer boot asks for the recovery key. Safest, and unusable for daily work.

**Proposed: (i) as the default, (ii) as an option.** Developer mode is chosen by a developer for their own machine, and (ii) protects only against a theft that already needs the laptop out of the user's hands in developer mode. That is Q3 for the owner.

#### 2.2.2 Where the developer key lives

- **Root-only file** on the encrypted root, as D-014 §4.2 says. Simple. Any root process can copy it.
- **TPM-resident key** (non-exportable), used through a PKCS#11 or OpenSSL provider when signing. Root can still *use* it while it has root, but cannot copy it away. Whether `ukify` and `sbsign` sign through such a provider on Fedora 45: **not checked**.

**Proposed:** TPM-resident if the spike shows the signing tools support it, otherwise the root-only file. Either way, only a polkit-guarded helper signs, and only after the user authenticates (section 3).

#### 2.2.3 If D-014 falls back to MOK or to no Secure Boot trust

- **D-014 B2 (MOK through Fedora's shim, spike #76):** the developer cert goes into MOK instead of db. `mokutil --import` needs a MokManager confirmation at the next boot, which is physical presence: root malware cannot enrol it unattended. Leaving removes it from MOK, again with MokManager. Otherwise the same.
- **D-014 option C (no Secure Boot trust):** the machine is already in the state of option C below; developer mode needs no key.

### 2.3 Option C: leaving sealed mode

Sealing cannot be turned off from inside the OS. A sealed UKI still boots with Secure Boot off; fs-verity still runs, but *"nothing validates that root digest itself, meaning any locally running code can replace the UKI"* ([sealed images](https://bootc.dev/bootc/building/bootc-sealed-images.7.html)). An unsigned UKI built with `ukify` (or one built with `--allow-missing-verity`, [composefs](https://bootc.dev/bootc/bootc-composefs.7.html)) then boots. Moving to the ostree backend needs a reinstall ([composefs](https://bootc.dev/bootc/bootc-composefs.7.html)). So in practice "leaving sealed mode" means **turning Secure Boot off in the firmware.** The OS cannot do that (the PK is discarded, and Secure Boot state is a firmware setting), so this is the user's own firmware step. It is D-014's option C applied after install.

- **Secure Boot:** off. Any boot chain boots: other operating systems, an attacker's USB stick, a modified UKI.
- **Seal:** fs-verity still runs, but the digest is no longer authenticated. Offline attackers and runtime root can both replace the UKI and so the whole system.
- **TPM:** PCR7 changes when Secure Boot is turned off, so the PCR7-bound disk key is not released. The user must enter the recovery key or re-enrol the TPM without PCR7. Re-enrolling on PCR11 alone is possible only for Atos-signed UKIs; any self-built UKI ends up at the recovery key or at a binding that protects nothing.
- **Signature policy:** still applies to registry pulls, but anyone with root can change what boots, so it no longer protects the boot chain.
- **Assistant sandbox:** unchanged directly. The same section 3 concerns apply, without a key to guard.
- **Automatic updates:** release updates keep working while the machine tracks the release image. Self-built images need the same rebuild loop as option B.
- **How to leave:** turn Secure Boot back on in the firmware, boot the release image, re-enrol the TPM. If db was cleared or reset meanwhile, rerun the installer's key enrolment (#66).

It weakens the most and gives the least help: the machine loses protection against offline attackers too, not only against runtime root. It can't be removed (priority 6: the firmware belongs to the user), but it should not be the developer path we offer.

### 2.4 Not compared

`systemd-sysext --mutable=yes` gives a persistent writable overlay on `/usr` ([systemd-sysext(8)](https://www.freedesktop.org/software/systemd/man/latest/systemd-sysext.html)). On a sealed system, an unsigned mutable extension is again a persistent change to `/usr` that nothing authenticates, and signed extensions need a key just like option B. The card does not ask for it, so it is noted, not designed.

## 3. Developer mode and the assistant sandbox (D-012 Q-E)

The owner's D-012 rationale allows an unsandboxed assistant in developer mode behind a warning. Combined with option B, that creates a path to watch:

- An unsandboxed assistant runs as the user, outside the broker (D-012 §5). If it can make the signing helper sign, or call `bootc switch`, without the user, it can install a **persistent, Secure-Boot-valid image**, which turns a misbehaving assistant into a persistent root compromise.
- **Proposed rule:** the developer-key signing helper, `bootc switch` and turning developer mode on or off are polkit actions with `auth_admin` (no `auth_admin_keep`), so the user authenticates for every build that gets signed. The prompt is drawn by the shell's polkit agent. Sandboxed assistants cannot answer it: their only path is the broker, and D-012 makes confirmations shell-owned. An unsandboxed process running as the user is the weak point: whether it can type into that prompt through a compositor input-emulation protocol (virtual keyboard, libei) that `atos-comp` exposes, or through `/dev/uinput`: **not checked**. The implementation card must test it, and the compositor must not offer input emulation to the polkit prompt.
- **Proposed:** "Allow unsandboxed assistants" is a **separate switch** inside developer mode, with its own warning. Turning on developer mode for builds should not quietly widen what assistants can do. The stop switch can freeze an unsandboxed assistant only if it is started in its own systemd scope, and a process running as the user can move itself out of that scope, so the stop switch for it is best effort. The warning should say so. C12 owns the details.

## 4. What each option does, side by side

| | A: `usr-overlay` | B: developer key | C: Secure Boot off |
| --- | --- | --- | --- |
| Persistent changes to `/usr` | No (RAM, lost on reboot) | Yes (own images) | Yes |
| Package layering / own builds | Session only | Yes | Yes |
| Secure Boot trust | Unchanged | db trusts one more key, private key on the machine | Off: anything boots |
| Seal | Unchanged on disk | Enforced, but anything holding the developer key can seal | Not authenticated |
| Runtime root compromise survives a reboot silently | No | **Yes** (signs with the developer key) | **Yes** |
| Offline attacker can change the system | No | No | **Yes** |
| TPM disk key | Unchanged | Extra token for developer UKIs (2.2.1) | PCR7 changes: recovery key or weaker binding |
| Signature policy for registry pulls | Unchanged | Unchanged, plus a scoped exception for local images | Unchanged, but no longer protects boot |
| Automatic updates | Unchanged | Stop unless the rebuild service runs | Release images: unchanged; own images: as B |
| Firmware step | None | None (KEK append) | Yes, by the user |
| How to leave | Reboot | Switch to release, boot it, remove key from db, delete key, reseal | Re-enable Secure Boot in firmware, re-enrol TPM |
| Upstream gaps | `dnf` inside it not checked | Local UKI regeneration not streamlined upstream; TPM-resident signing not checked | None |

## 5. Recommendation (Proposed, for the owner to decide)

**Flag for the owner: this is a recommendation, not a decision.**

**Developer mode is option B: a per-machine developer key enrolled in db with the per-machine KEK, for booting locally built images. Option A (`bootc usr-overlay`) is available inside developer mode as the quick, key-free way to try something for one boot. Option C is documented, not offered as a switch.**

Why:

1. **It is the only option that meets C1's "package layering" without giving up protection against offline attackers.** A is safe but transient; C gives up everything, for every attacker.
2. **It is the mechanism D-014 already planned** (developer key in §4.2, card 6 in its consequences), using the same enrolment code as the installer (#66). No firmware step, so turning it on is one switch and a password, as priority 6 asks.
3. **Its cost is limited and can be undone.** The weakening is one machine's key, chosen by its owner. Leaving removes the key from db, so nothing signed with it boots afterwards.
4. **A comes free.** It needs nothing but a polkit-guarded button, and it covers the most common need (try a patched binary) without any key.

What the owner accepts with it:

- **In developer mode, a runtime root compromise can persist across reboots silently** by signing with the developer key. That is the honest summary for the warning text. Proposed warning, for the C8 design: *"Developer mode lets this computer start system images you build. Anything that gains administrator access while it is on can change the system permanently. Turn it off when you no longer need it."*
- **Release updates continue only through the rebuild service.** Until that card is done, developer mode stops updates and must say so.
- **Developer-signed boots unlock the disk silently** under the proposed default (2.2.1 (i)).

### 5.1 Proposed decisions-log entry

For the owner to add if accepted (ID assigned by the owner):

> Developer mode (C1): turning it on enrols a per-machine developer db key with the per-machine KEK; locally built images FROM the verified release image are sealed and signed with it and booted with `bootc switch`; a rebuild service keeps them on current releases; `bootc usr-overlay` is available for transient changes; signing, switching and toggling developer mode need admin authentication every time; turning it off boots the release image and then removes the key from db. Unsandboxed assistants (D-012) are a separate switch inside developer mode. Turning Secure Boot off is the user's firmware choice and is documented, not offered | Proposed | Only option that allows persistent own builds while keeping offline protection; reuses D-014's enrolment; one-machine, reversible weakening. See `docs/components/c1-base/developer-mode.md`

## 6. Implementation cards it implies

For the planner; not created here. Dependencies in brackets.

1. **C1 spike: `bootc usr-overlay` on our sealed image.** In the dev VM: does it work on composefs, does `dnf install` work inside it, how much RAM a typical tool costs. [#55]
2. **C1 spike: locally sealed and signed image.** In the dev VM with the test keys: build `FROM` the release image, split kernel, `bootc container ukify` signed with a second (developer) key enrolled next to the test db, `bootc switch --transport containers-storage`, boot. Measure the build time. Check whether `ukify`/`sbsign` can sign with a TPM-resident key (2.2.2). [#54]
3. **C1: developer key enrolment and removal.** Generate the key, append to db with the per-machine KEK, reseal LUKS (PCR7 changed), add the TPM2 token for developer UKIs (2.2.1); the reverse on turning off, in the order of 2.2. Shares code with the installer's enrolment. [#66, the D-014 key-rotation/dbx card]
4. **C1: developer build tool and polkit actions.** `Containerfile` FROM the booted release (verified), seal, sign through a helper behind polkit `auth_admin`, scoped policy exception for local references, `bootc switch`. Includes the test for section 3's "no unattended signing". [#75, cards 2 and 3]
5. **C1: rebuild service for developer images.** On a new signed release, rebuild, sign, stage; on failure, keep the current image and notify. [card 4, #55]
6. **C1: leave developer mode.** End-to-end test in the dev VM: switch to release, boot, db rewritten, key deleted, a developer-signed UKI no longer boots. [cards 3 and 4]
7. **C8 (with C3): developer mode switch, warning and indicator.** The switch, the warning (dismissible, §2 priority 6), a status indicator while it is on, boot entries labelled as developer builds. Design system values only. [card 3]
8. **C12: unsandboxed assistants switch** inside developer mode, only if the owner confirms section 3. [D-012]
9. **Docs:** user guide for turning Secure Boot off (option C) and back on, with its consequences. [#66]

## 7. Questions for the owner

1. **Accept option B, with A inside it, and C as documentation only?** (Section 5.)
2. **Rebuild service:** rebuild and stage automatically when a release lands (proposed, matches C1's background updates), or only notify?
3. **Disk unlock for developer-signed boots:** silent (proposed), TPM2 + PIN, or recovery key? (2.2.1.)
4. **Unsandboxed assistants:** a separate switch inside developer mode (proposed), or implied by developer mode? (Section 3.)
5. **On leaving:** also add the developer cert's hash to dbx, at the cost of firmware dbx space, or only remove it from db (proposed)?
6. **Warning text and whether the indicator can be hidden:** priority 6 says warnings can be turned off. Proposed: the turn-on warning is dismissible as usual; the boot entry label stays, because it is the only sign at boot that a non-Atos image is running.

## Sources

All opened on 2026-11-06.

- bootc: [bootc-usr-overlay(8)](https://bootc.dev/bootc/man/bootc-usr-overlay.8.html), [composefs backend](https://bootc.dev/bootc/bootc-composefs.7.html), [sealed images](https://bootc.dev/bootc/building/bootc-sealed-images.7.html), [bootc-switch(8)](https://bootc.dev/bootc/man/bootc-switch.8.html)
- systemd: [systemd-measure(1)](https://www.freedesktop.org/software/systemd/man/latest/systemd-measure.html), [systemd-sysext(8)](https://www.freedesktop.org/software/systemd/man/latest/systemd-sysext.html)
- Project: [D-008](../../decisions/D-008-base-image.md), [D-012](../../decisions/D-012-assistant-safety.md), [D-014](../../decisions/D-014-signing-keys.md), [C1 README](README.md)
