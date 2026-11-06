# D-014: Secure Boot and image-signing key management

Card: #53 · Written: 2026-11-06 · Status of D-014: **not yet in the log**. The owner adds it (proposed text in [section 7](#7-proposed-decisions-log-entry)). This write-up ends in a recommendation ([section 5](#5-recommendation-for-the-owner-to-decide)) and decides nothing. Nothing was built or signed for it.

Every upstream fact links to its source. All links were opened on 2026-11-06. **Not checked** means I found no source either way. **Uncertain** marks a claim from a secondary source, or one I could not confirm upstream.

## 1. Context

### 1.1 What D-014 decides

D-008 (Decided) chose bootc on Fedora with **sealed composefs images**, UKI and systemd-boot. Sealed means the expected composefs root digest sits inside a UKI that is *"signed for Secure Boot"*, and an upgrade must *"sign the new UKI with a key the existing machine trusts"* ([bootc composefs](https://bootc.dev/bootc/bootc-composefs.7.html)). D-008 §6 question 2 left open **how a user's laptop comes to trust our key**. D-014 answers that, plus how we hold and use every signing key:

1. **Trust path:** a Microsoft-signed Atos shim via shim-review, or user key enrolment at install (C11), or something between.
2. **Keys:** which keys exist, their type, where each is stored, who can use it, rotation and revocation, and what CI may hold.
3. **Threat model** for the release pipeline.

Later cards depend on it: #54 (sealed UKI with a test key), #66 (installer with FDE), #68 (developer mode under sealing). Card #50 already signs CI images with a test or keyless key; that stays a test signature whatever is decided here.

### 1.2 Requirements and constraints

- **C1** Read-only, signed image; "Previous version" always bootable; FDE on by default; developer mode behind a dismissible warning.
- **C10** No telemetry; the user sees and controls what is trusted.
- **C11** Install in under 10 minutes, encryption on, no account.
- **§2 priority 6** Users can change anything. The OS warns but does not block.
- **D-005** No account, no telemetry. Verification on the user's machine must not call home.
- **D-007** No upstream contributions. Relevant because shim-review is an application filed as an issue in an upstream repository (see [3.1](#31-option-a-microsoft-signed-atos-shim-via-shim-review)).
- **Repository facts:** private repo, fork-PR workflows disabled, GitHub Free plan (`docs/ci.md`), self-hosted NUC runner that must never run untrusted code.

### 1.3 How Secure Boot trust works (short)

Firmware holds four variables: **PK** (platform owner, usually the OEM), **KEK** (may change db and dbx; usually Microsoft's), **db** (allowed signers or hashes) and **dbx** (revoked). On almost every PC, db holds Microsoft's Windows CA and Microsoft's third-party CA, which signs Linux shims. shim then trusts its own embedded **vendor certificate** plus the user-managed **MOK** list. Anything signed by a cert in db, or by shim's vendor cert or MOK when started through shim, boots.

## 2. The Microsoft CA rotation (what changed in 2026)

- The **Microsoft Corporation UEFI CA 2011** (the one that signs Linux shims) expired on 26/27 June 2026. Its replacement, **Microsoft UEFI CA 2023**, *"does not expire until 2038"* ([LWN](https://lwn.net/Articles/1079808/)).
- shim-review: since 27 June 2026, *"shims can only be signed by the Microsoft UEFI CA 2023"* ([shim-review](https://github.com/rhboot/shim-review)).
- From October 2025 to June 2026 Microsoft signed shims with both keys. A machine boots as long as either CA is in db ([Red Hat](https://www.redhat.com/en/blog/expiration-secure-boot-signing-certificates-2026)). Existing installs keep booting; a **new** 2023-only shim fails on firmware whose db lacks the 2023 CA ([LWN](https://lwn.net/Articles/1079808/)).
- db updates come from hardware vendors, reach Linux through fwupd/LVFS, and **change PCR7** (so TPM-sealed disk keys must be resealed). Some HP and Fujitsu models cannot receive db updates ([Red Hat](https://www.redhat.com/en/blog/expiration-secure-boot-signing-certificates-2026)). Forced db updates have left some machines unbootable ([LWN](https://lwn.net/Articles/1079808/)).
- The 2023 set separates third-party bootloaders (UEFI CA 2023) from third-party **option ROMs** (Option ROM UEFI CA 2023), so a db can trust GPU and storage option ROMs without trusting every Microsoft-signed bootloader (**uncertain**: secondary sources only, [Ubuntu](https://discourse.ubuntu.com/t/microsoft-uefi-ca-rotation-what-it-means-for-ubuntu-users-and-vendors/82652), [Microsoft Tech Community](https://techcommunity.microsoft.com/t5/hardware-dev-center/signing-with-the-new-2023-microsoft-uefi-certificates-what/ba-p/4455787)).

Consequence for Atos: **any new shim we get signed is 2023-only**. Laptops that never received the 2023 db update cannot boot it. That gap does not shrink with time for machines whose vendors stopped shipping firmware.

## 3. Options

### 3.1 Option A: Microsoft-signed Atos shim via shim-review

Chain: firmware db (MS UEFI CA 2023) → **Atos shim** (embeds the Atos vendor cert) → systemd-boot signed by Atos → sealed UKI signed by Atos.

What shim-review asks ([shim-review](https://github.com/rhboot/shim-review)):

- Proof the organisation is legitimate (company register entry or the EV certificate used with Microsoft), two security contacts with PGP keys, verified by encrypted challenge.
- A reproducible build from the shim 16.1 tarball via a Dockerfile; SBAT entries for shim and every binary it starts; NX status; kernel lockdown enforced under Secure Boot; how kernel modules are signed.
- A description of key protection (HSMs, smart cards, air-gapped vaults are given as examples). Newly embedded certs must be **RSA ≥ 4096**.
- Reviewers know GRUB2 and **systemd-boot**, so our chain is in scope. Review can take *"2-3 months"*, then Microsoft signs.

Assessment:

- **Works out of the box** on every machine whose db has the 2023 CA, with no setup mode and no user step. Best for "install in under 10 minutes".
- **Fails** on firmware without the 2023 CA. Those users must update firmware, enrol our key anyway (option B), or turn Secure Boot off.
- **Ongoing obligations:** SBAT generations, revocation when a boot-chain bug is found, a fresh review for every new shim, and an HSM-held vendor key. That is an operational cost for a one-person project.
- **D-007 / accounts:** it needs a filed issue in `rhboot/shim-review`, an organisation that can prove legitimacy, and a Microsoft Partner Center account with an EV code-signing cert. Whether this counts as an upstream contribution under D-007 is the owner's call (**question 1**). It costs money (EV cert) and time; amounts **not checked**.
- **Trust is Microsoft's:** the user's machine trusts Atos only because Microsoft signed our shim. That fits "familiar" but not "fully owned by its user".

### 3.2 Option B: Atos keys enrolled on the machine at install (C11)

The installer puts the firmware into a state where **the user's machine trusts the Atos release key directly in db**. Two ways:

- **B1, full enrolment (setup mode).** The user switches the firmware to setup mode (clears PK) once. The installer writes PK, KEK and db. systemd-boot can do this from the ESP: `secure-boot-enroll` with `if-safe` (default; auto only inside a VM), `manual` or `force`, keys in `/loader/keys/<name>/{PK,KEK,db}.auth`. Upstream warns it *"might soft-brick your device if used improperly"*, especially because of **option ROMs** (GPU, storage) signed by Microsoft, and calls keeping the Microsoft certs *"highly recommended on real hardware"* ([loader.conf](https://www.freedesktop.org/software/systemd/man/latest/loader.conf.html)).
- **B2, MOK enrolment through a distribution shim.** Keep the firmware untouched. Boot Fedora's Microsoft-signed shim and enrol the Atos cert into MOK (`mokutil --import`, confirmed with a one-time password in MokManager after reboot). shim then trusts our systemd-boot and UKI. No setup mode, Microsoft keys untouched, no option-ROM risk. Open details, all **not checked**: whether Fedora's current shim is dual-signed (it would then also boot on 2011-only firmware until Fedora ships a 2023-only respin); how to make shim start systemd-boot instead of its default `grubx64.efi`; whether systemd-boot verifies the UKI through shim's protocol in our setup. This needs a spike.

What the db contains in B1 (proposal):

| db entry | Why |
| --- | --- |
| Atos release Secure Boot cert | Our systemd-boot and sealed UKIs |
| Microsoft Option ROM UEFI CA 2023 (and 2011) | GPU and storage option ROMs keep working (avoids the soft-brick warning) |
| Microsoft UEFI CA 2023/2011 | **Optional, user's choice.** Needed to boot other Linux live media; leaving it out means only Atos and Windows (if chosen) boot |
| Microsoft Windows Production CA 2011/2023 | **Optional, user's choice**, for dual boot |

Assessment:

- **Works on firmware without the 2023 CA**, because trust no longer depends on Microsoft's signature on our boot chain. B1 removes the gap entirely; B2 removes it only while Fedora's shim still carries a 2011 signature.
- **The user owns the trust root.** In B1 the installer generates a **per-machine PK and KEK** on the machine. Atos never holds any user's PK or KEK, so we cannot change what a user's machine trusts. That matches "fully owned by its user" and D-005.
- **Costs:** a firmware step the user must do by hand in B1 (setup mode is vendor-specific, and a few firmwares hide it), which threatens the 10-minute install and needs clear C11 guidance. B2's MokManager screen is a blue firmware-style UI we cannot style.
- **No review, no account, no Microsoft dependency** for our own releases.
- **dbx:** Microsoft's dbx updates via LVFS are signed by Microsoft's KEK. If B1 replaces KEK with only the user's KEK, those revocations no longer apply. The installer should **append** Microsoft's KEK CA 2023 alongside the user's KEK, so vendor revocations keep working (**not checked** on real firmware).

### 3.3 Option C: no Secure Boot trust (sealed but unverified)

A sealed UKI also boots with Secure Boot off. fs-verity still runs, but *"nothing validates that root digest itself"*, so local code could replace the UKI ([sealed images](https://bootc.dev/bootc/building/bootc-sealed-images.7.html)). Not an option on its own, but it is the **fallback** for users who decline both A and B: §2 priority 6 says warn, not block. C11 shows a warning and lets them continue.

### 3.4 Comparison

| | A: Atos shim | B1: full enrolment | B2: MOK via Fedora shim |
| --- | --- | --- | --- |
| Firmware with UEFI CA 2023 | Boots, no user step | Boots after setup-mode step | Boots after MokManager step |
| Firmware **without** UEFI CA 2023 | **Does not boot** | Boots | Boots only while Fedora's shim is dual-signed (**not checked**) |
| User step at install | None | Enter setup mode in firmware | Confirm MOK password after reboot |
| Brick risk | None | Option ROMs if Microsoft certs dropped; mitigated by keeping Option ROM CA | None |
| Who controls the trust root | Microsoft, then us | **User** (per-machine PK/KEK) | Microsoft + Fedora + us via MOK |
| External dependency | shim-review, Microsoft, EV cert, legal entity | None | Fedora's shim packaging |
| Ongoing ops | Reviews, SBAT, HSM vendor key | Our db key rotation | Track Fedora's shim; SBAT revocations of it |
| Fits D-007 | Owner's call (question 1) | Yes | Yes |
| Time to first real-hardware boot | Months | Phase 1 | Phase 1 after spike |

## 4. Keys

### 4.1 Key inventory

| Key | Type | Signs | Stored | Who can use it |
| --- | --- | --- | --- | --- |
| **Release image key** | cosign key pair, ECDSA P-256 | Release OCI images, by digest | Hardware token (YubiKey or similar, via cosign PKCS#11), offline; one backup token in a separate safe place | Owner only, at release time |
| **Release Secure Boot key (db)** | X.509 + RSA-2048 (RSA-4096 if option A, as shim-review requires) | systemd-boot and sealed UKIs | Hardware token, offline, same handling as above | Owner only |
| **Per-machine PK and KEK** (option B1) | X.509 + RSA-2048, generated by the installer | db/dbx updates on that machine only | On the machine, root-only, on the encrypted root | The user (via root) |
| **Developer key** (#68) | X.509 + RSA-2048, generated when the user turns developer mode on | Locally built UKIs on that machine | On the machine, root-only | The user |
| **Test image key** | cosign keyless (GitHub OIDC) or a test key pair | CI images on every merge (#50) | Keyless: none stored. Key pair: GitHub Actions secret | CI on `main` only |
| **Test Secure Boot key** | X.509 + RSA-2048 | Test UKIs for the dev VM and NUC (#54) | Committed to the repo **or** a CI secret, labelled TEST in its subject | Anyone; it is public by design |
| **Kernel module key** | Fedora's | Fedora kernel modules | Fedora's build system (ephemeral per build) | Not ours; we ship Fedora's signed kernel unchanged |

RSA-2048 for db certs: Microsoft's own UEFI CAs use RSA-2048, and some firmware handles larger keys poorly (**uncertain**, folklore I could not confirm upstream). shim-review requires RSA-4096 only for certs embedded in a shim.

Rules that hold for all keys:

- **Test keys never appear in a release db or release trust policy.** A test-signed UKI must not boot on a release-enrolled machine, and a test-signed image must not pass a release client's `policy.json`.
- **Release private keys never touch CI or the NUC runner.** CI builds; the owner signs the digest locally. That is a manual step per release, which suits a release cadence measured in weeks.

### 4.2 Image signing on the client

bootc pulls through containers/image and honours `/etc/containers` ([bootc registries](https://bootc.dev/bootc/bootc-registries-and-offline.7.html)). `policy.json` supports `sigstoreSigned` with a fixed key (`keyPath`/`keyPaths`), with Fulcio keyless identities (then a Rekor public key is *"mandatory"*), or with a private PKI ([containers-policy.json](https://github.com/containers/image/blob/main/docs/containers-policy.json.5.md)). The registry needs `use-sigstore-attachments` in registries.d. `bootc switch --enforce-container-sigpolicy` refuses to switch unless the default policy requires signatures ([bootc-switch](https://cgwalters.github.io/bootc/man/bootc-switch.html)).

Recommendation inside any option: release images ship `policy.json` with `sigstoreSigned` and **`keyPaths`** listing the current and next release image public keys. Two keys allow rotation without a flag day. Verification is offline and calls no one (D-005).

Why not keyless for releases: keyless records each signing in Sigstore's public Rekor log ([sigstore](https://docs.sigstore.dev/cosign/signing/overview/)), and the Fulcio certificate carries the workflow identity, so our private repository's name and workflow paths become public (**uncertain** in detail; the overview does not list the fields). It also means anyone who can run a workflow on `main` can produce a valid release signature. Keyless is fine for **test** images (#50).

Note: cosign signatures carry only the repository, so `signedIdentity` can only match the repository, which *"does not guard against tag substitution"* ([containers-policy.json](https://github.com/containers/image/blob/main/docs/containers-policy.json.5.md)). An attacker could serve an older, validly signed image under the current tag. Mitigation in section 6.

### 4.3 Rotation and revocation

| Key | Planned rotation | If compromised |
| --- | --- | --- |
| Release image key | Every 2 years. The next key's public half ships in `keyPaths` one release ahead | Ship an update signed with the old key that removes it from `keyPaths` (only works if the attacker has not already pushed a malicious update); publish an advisory; users who updated from a malicious image must reinstall |
| Release Secure Boot key | Every 2–3 years. Add the new cert to db one release ahead, then sign with it | Option A: Microsoft/SBAT revocation of our shim, new review. Option B1: an update appends the old cert's hash to **dbx** via the per-machine KEK. B2: remove it from MOK (needs MokManager confirmation) |
| Per-machine PK/KEK | Never, unless the user asks | Machine-local. The user resets keys in firmware and re-runs enrolment |
| Developer key | When developer mode is turned off: removed from db and deleted | Same as above |
| Test keys | Whenever convenient | Not a security event, by design |

Two keys for one owner is a bus-factor risk: if both tokens are lost, no update can be signed for existing machines, and users must reinstall. Keep a sealed paper or offline backup of each release key (**question 3**).

## 5. Recommendation (for the owner to decide)

**Option B (user key enrolment at install), with B1 as the default path and B2 as a fallback if the spike confirms it. Do not apply for shim-review in v1.**

Why:

1. **It boots on more laptops today.** Option A cannot boot on firmware without UEFI CA 2023, and that set does not shrink for unsupported models. B1 works on all of them.
2. **The user owns the trust root** (§2, C10, priority 6). A per-machine PK/KEK means neither Atos nor Microsoft can change what that machine trusts. With option A, Microsoft's signature is the reason the machine trusts us.
3. **No external dependency.** No legal entity, EV cert, Microsoft account, months of review or ongoing SBAT obligations, and no D-007 question.
4. **Same keys we need anyway.** Developer mode (#68) needs a per-machine enrolled key under either option. B1 makes that the same mechanism, not a second one.
5. **Cost is one firmware step.** The installer must explain setup mode per vendor. That is real friction (priority 3, familiar), so C11 must design it carefully and keep option C (warn, continue without Secure Boot trust) available.

When option A would be the better call: if the target list (§3, certified hardware) turns out to be mostly recent machines with UEFI CA 2023 already in db, and the setup-mode step proves too hard in C11 user tests. A can be added later beside B, since it needs no change to the image signing side.

## 6. Threat model

| Threat | What an attacker gets without mitigation | Mitigation |
| --- | --- | --- |
| **Stolen CI secret** | If CI held release keys: a validly signed malicious OS update for every user | Release keys never live in CI (4.1). CI holds only test keys or uses keyless. A stolen test key signs images no release machine accepts, because test keys are absent from release `policy.json` and db. Rotate the test key; no advisory needed |
| **Malicious PR** | Code running in CI with secrets; code on the NUC runner; malicious code merged and later signed | Fork-PR workflows are disabled and the repo is private. PR builds never sign or push (#50). PR jobs get no secrets and `permissions: {}` by default (already in `perf.yml`, `d006-measure.yml`). The NUC runs only label-gated jobs on same-repo branches. Every PR needs a reviewer agent and, for security-relevant code, the owner (CLAUDE.md). The owner signs a **digest** after reviewing what went into it, so a merged-but-unreviewed change does not get a release signature automatically |
| **Compromised registry** (ghcr.io account or GitHub) | Serve modified images; serve an **older** signed image (rollback) or withhold updates (freeze) | Clients verify the release signature with `sigstoreSigned` + `keyPaths` and `--enforce-container-sigpolicy`, so modified images are refused. Rollback/freeze: signatures do not cover tags, so add a signed version floor: the client refuses any image whose signed version label is lower than the booted one, and the UI shows the age of the last update. Design in a C1 card (**not checked** whether bootc has this built in) |
| **Stolen release token** (extra) | Same as stolen CI secret, for releases | PIN on the token, offline storage, rotation plan (4.3) with the next key pre-shipped |
| **Local root / evil maid** (extra) | Replace the UKI or enrol keys | Secure Boot rejects an unsigned UKI. Replacing db or MOK changes PCR7 / PCR14, so a TPM-bound LUKS key is not released and the user is asked for the recovery key. Note that while Microsoft's UEFI CA is in db, any Microsoft-signed Linux chain still boots, so the disk key binding, not db, protects the data. C11 should bind LUKS to PCR7 plus a signed PCR11 policy (systemd-measure); design in #66 |

## 7. Proposed decisions-log entry

For the owner to add if accepted (agents do not edit `docs/spec.md`):

> D-014 | Secure Boot trust by user key enrolment at install (per-machine PK/KEK; Atos release cert and Microsoft Option ROM CA in db; Microsoft UEFI and Windows CAs optional); no shim-review in v1. Release image and Secure Boot keys live on offline hardware tokens held by the owner; CI holds only test keys or signs keyless; clients enforce `sigstoreSigned` with pinned keys | Proposed | Boots on firmware without UEFI CA 2023, the user owns the trust root, no Microsoft or review dependency. See `docs/decisions/D-014-signing-keys.md`

## 8. Phase 1 work this implies

If option B is decided:

1. **#54 (existing):** sealed UKI signed with the **test** Secure Boot key boots in the dev VM; systemd-boot `if-safe` auto-enrols the test key in the VM. No change in scope.
2. **New C1 card, spike:** B2 path: does Fedora's shim start systemd-boot and verify our UKI via MOK, and is Fedora's current shim dual-signed? Result picks B2 as fallback or drops it.
3. **New C1 card:** release signing procedure doc and script: CI publishes a digest; the owner verifies and signs with `cosign sign --key pkcs11:…` and signs the UKI with the token; the signed UKI is injected into the final image ([external signing](https://bootc.dev/bootc/building/bootc-sealed-images.7.html), upstream calls this workflow *"planned for streamlining"*).
4. **New C1 card:** client trust policy: `policy.json` with `sigstoreSigned` + `keyPaths`, registries.d `use-sigstore-attachments`, `--enforce-container-sigpolicy`, and a signed version floor against rollback.
5. **#66 (existing), extended:** installer generates per-machine PK/KEK, guides the user through setup mode, enrols PK/KEK (+ Microsoft KEK CA 2023)/db, then seals LUKS to the TPM **after** enrolment (PCR7 changes on enrolment). Falls back to option C with a warning.
6. **#68 (existing):** developer mode generates a per-machine developer db key, using the same enrolment code.
7. **New C1 card:** key rotation and dbx update path via the per-machine KEK, including the next-key pre-ship.

Buying hardware tokens is out of scope for this card (owner's task).

## 9. Open questions

1. **D-007 and shim-review.** Does filing a shim-review application count as an "upstream contribution"? Only matters if option A is chosen now or later.
2. **Legal entity.** Is there one that could pass shim-review's legitimacy check and get an EV cert? Only matters for option A.
3. **Key backup.** Is a second token in a separate location enough, or does the owner want a paper/offline backup or a second key holder?
4. **Default db contents.** Should the installer include Microsoft's UEFI CA (other Linux live media boot) and Windows CA by default, or ask? Including them is more familiar; leaving them out is safer.
5. **Test Secure Boot key in the repo or in a CI secret?** Committing it is simpler and honest about it being public; a secret keeps it out of casual reach.

## Sources

- shim-review requirements and CA 2023 rule: <https://github.com/rhboot/shim-review>
- CA expiry and db updates: <https://lwn.net/Articles/1079808/>, <https://www.redhat.com/en/blog/expiration-secure-boot-signing-certificates-2026>
- Option ROM CA split (secondary): <https://discourse.ubuntu.com/t/microsoft-uefi-ca-rotation-what-it-means-for-ubuntu-users-and-vendors/82652>, <https://techcommunity.microsoft.com/t5/hardware-dev-center/signing-with-the-new-2023-microsoft-uefi-certificates-what/ba-p/4455787>
- bootc sealing and signing: <https://bootc.dev/bootc/bootc-composefs.7.html>, <https://bootc.dev/bootc/building/bootc-sealed-images.7.html>, <https://bootc.dev/bootc/bootc-registries-and-offline.7.html>, <https://cgwalters.github.io/bootc/man/bootc-switch.html>
- systemd-boot key enrolment: <https://www.freedesktop.org/software/systemd/man/latest/loader.conf.html>
- Image signing: <https://docs.sigstore.dev/cosign/signing/overview/>, <https://docs.sigstore.dev/cosign/signing/signing_with_containers/>, <https://github.com/containers/image/blob/main/docs/containers-policy.json.5.md>
