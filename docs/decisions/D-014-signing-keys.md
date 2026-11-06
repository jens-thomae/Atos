# D-014: Secure Boot and image-signing key management

Card: #53 · Written: 2026-11-06, revised after review the same day · Status of D-014: **not yet in the log**. The owner adds it (proposed text in [section 7](#7-proposed-decisions-log-entry)). This write-up ends in a recommendation ([section 5](#5-recommendation-for-the-owner-to-decide)) and decides nothing. Nothing was built or signed for it.

Every upstream fact links to its source. All links were opened on 2026-11-06. **Not checked** means I found no source either way. **Uncertain** marks a claim from a secondary source, or one I could not confirm upstream.

## 1. Context

### 1.1 What D-014 decides

D-008 (Decided) chose bootc on Fedora with **sealed composefs images**, UKI and systemd-boot. Sealed means the expected composefs root digest sits inside a UKI that is *"signed for Secure Boot"*, and an upgrade must *"sign the new UKI with a key the existing machine trusts"* ([bootc composefs](https://bootc.dev/bootc/bootc-composefs.7.html)). D-008 §6 question 2 left open **how a user's laptop comes to trust our key**. D-014 answers that, plus how we hold and use every signing key:

1. **Trust path:** a Microsoft-signed Atos shim via shim-review, or user key enrolment at install (C11), or something between.
2. **Keys:** which keys exist, their type, where each is stored, who can use it, rotation and revocation, and what CI may hold.
3. **Threat model** for the release pipeline.

Later cards depend on it: #54 (sealed UKI with a test key), #66 (installer with FDE), #68 (developer mode under sealing). Card #50 (PR #70) signs CI images with a CI-held **test key pair**. That stays a test signature whatever is decided here.

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
- The 2023 set separates third-party bootloaders (UEFI CA 2023) from third-party **option ROMs** (**Microsoft Option ROM UEFI CA 2023**), an optional certificate ([Microsoft Tech Community](https://techcommunity.microsoft.com/t5/hardware-dev-center/signing-with-the-new-2023-microsoft-uefi-certificates-what/ba-p/4455787), [ASUS](https://www.asus.com/support/faq/1056827/)). The 2011 set had **no** such split. Option ROMs on cards in the field today are signed by the **Microsoft Corporation UEFI CA 2011** ([sbctl FAQ](https://github.com/Foxboron/sbctl/wiki/FAQ)), the same CA that signed every 2011-era shim. Signing with it ended in June 2026, but existing signatures stay valid. So trusting today's option ROMs by CA means trusting every 2011-signed Linux boot chain.

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
| Microsoft Option ROM UEFI CA 2023 | Option ROMs signed under the 2023 set; trusts no bootloaders |
| Option ROMs signed under 2011: see the choice below | Most GPUs and storage controllers in the field today |
| Microsoft UEFI CA 2023 | **Optional, user's choice.** Boots other Linux live media signed under 2023 |
| Microsoft Windows Production CA 2011 / Windows UEFI CA 2023 | **Optional, user's choice**, for dual boot |

**Option ROMs signed under 2011.** There is no narrow CA for them, so the installer must pick one of three:

1. **Trust Microsoft Corporation UEFI CA 2011** in db. Safe for hardware, and the choice sbctl calls *"the safe option"* ([sbctl FAQ](https://github.com/Foxboron/sbctl/wiki/FAQ)). But every 2011-signed Linux boot chain then boots too, including ones revoked only by SBAT.
2. **Enrol the option ROM hashes** recorded in the TPM event log into db (`sbctl enroll-keys --tpm-eventlog`, marked *"experimental"* in [sbctl(8)](https://github.com/Foxboron/sbctl/blob/master/docs/sbctl.8.txt)). Narrow trust, but a GPU firmware update or a new card no longer validates, which can leave the machine without graphics until keys are reset.
3. **Trust neither** and accept the soft-brick risk on hardware that loads option ROMs.

The installer can check the TPM event log for `BOOT_SERVICES_DRIVER` entries ([sbctl FAQ](https://github.com/Foxboron/sbctl/wiki/FAQ)). If there are none, which is likely on laptops with only an integrated GPU (**not checked**), none of the three is needed. If there are some, I recommend choice 1 as the default, with choice 2 offered as an advanced option (**question 5**). With choice 1, the protection for the user's data against a foreign boot chain is the TPM-bound disk key, not db (see [section 6](#6-threat-model)).

Assessment:

- **Works on firmware without the 2023 CA**, because trust no longer depends on Microsoft's signature on our boot chain. B1 removes the gap entirely; B2 removes it only while Fedora's shim still carries a 2011 signature.
- **The trust root is the machine's own, not a vendor's.** In B1 the installer generates a **per-machine PK and KEK** on the machine, and no copy leaves it. That matches "fully owned by its user" and D-005, but it does not take Atos out of the picture. The KEK private key has to stay on the machine (root-only) so updates can rotate our db cert and apply dbx revocations (4.3). A signed Atos update runs as root, so **whoever holds the Atos release image key can change that machine's db and dbx**. That is no different from any OS whose updates run as root, but the honest claim is "no outside party can change it without an Atos update", not "Atos cannot change it".
- **Discard the PK private key after enrolment.** Keep only the KEK. Root malware then cannot re-own the firmware (replace PK). It can still write db with the KEK, but any db change alters PCR7, so the TPM no longer releases the disk key and the user is asked for the recovery key. The user can always reset keys in the firmware setup and re-enrol.
- **Costs:** a firmware step the user must do by hand in B1 (setup mode is vendor-specific, and a few firmwares hide it), which threatens the 10-minute install and needs clear C11 guidance. B2's MokManager screen is a blue firmware-style UI we cannot style.
- **No review, no account, no Microsoft dependency** for our own releases.
- **dbx and Microsoft's KEK, a trade-off for the owner (question 4).** Microsoft's dbx updates via LVFS are signed by Microsoft's KEK. A KEK entry authorises writes to **db as well as dbx**, so there are only two choices:
  - **(a) Keep Microsoft's KEK CA 2023** next to the per-machine KEK. Microsoft's dbx updates keep applying unchanged, but **Microsoft can also append to db** on that machine, so Microsoft keeps a say in what it trusts.
  - **(b) Leave Microsoft's KEK out.** Only the per-machine KEK can change db and dbx. **Atos must then ship dbx updates itself**: an update carries Microsoft's published revocation list, and a local tool signs it with the per-machine KEK and writes dbx. That is ongoing work for us, and a machine that stops updating also stops getting revocations.

  I recommend **(b)**. It is the only choice consistent with reason 2 in [section 5](#5-recommendation-for-the-owner-to-decide), and dbx changes are rare enough to ride along with normal updates. Writing dbx through the per-machine KEK: **not checked** on real firmware.

### 3.3 Option C: no Secure Boot trust (sealed but unverified)

A sealed UKI also boots with Secure Boot off. fs-verity still runs, but *"nothing validates that root digest itself"*, so local code could replace the UKI ([sealed images](https://bootc.dev/bootc/building/bootc-sealed-images.7.html)). Not an option on its own, but it is the **fallback** for users who decline both A and B: §2 priority 6 says warn, not block. C11 shows a warning and lets them continue.

### 3.4 Comparison

| | A: Atos shim | B1: full enrolment | B2: MOK via Fedora shim |
| --- | --- | --- | --- |
| Firmware with UEFI CA 2023 | Boots, no user step | Boots after setup-mode step | Boots after MokManager step |
| Firmware **without** UEFI CA 2023 | **Does not boot** | Boots | Boots only while Fedora's shim is dual-signed (**not checked**) |
| User step at install | None | Enter setup mode in firmware | Confirm MOK password after reboot |
| Brick risk | None | Option ROMs, unless the 2011 UEFI CA or their hashes are in db (3.2) | None |
| Who can change what the machine trusts | Microsoft (db/dbx via its KEK), us (vendor cert in our shim) | The machine's own KEK, used only by Atos updates (so: the Atos release key holder); plus Microsoft if its KEK is kept (question 4) | Microsoft and the OEM (firmware KEK), Fedora (shim vendor cert), us via MOK |
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
| **Per-machine PK** (option B1) | X.509 + RSA-2048, generated by the installer | KEK enrolment, once | Private key **discarded** right after enrolment (3.2) | Nobody after install |
| **Per-machine KEK** (option B1) | X.509 + RSA-2048, generated by the installer | db/dbx updates on that machine only | On the machine, root-only, on the encrypted root | Root: in practice, Atos updates and the user |
| **Developer key** (#68) | X.509 + RSA-2048, generated when the user turns developer mode on | Locally built UKIs on that machine | On the machine, root-only | The user |
| **Test image key** | cosign key pair (as PR #70 implements) | CI images on every merge (#50) | GitHub Actions secret | Only the `main` publish job references it, but **any writer to any branch can read it**, agent sessions included. Private repositories on the Free plan get no environment branch rules (PR #70 README) |
| **Test Secure Boot key** | X.509 + RSA-2048 | Test UKIs for the dev VM and NUC (#54) | Committed to the repo **or** a CI secret, labelled TEST in its subject | Anyone; it is public by design |
| **Kernel module key** | Fedora's | Fedora kernel modules | Fedora's build system (ephemeral per build) | Not ours; we ship Fedora's signed kernel unchanged |

RSA-2048 for db certs: Microsoft's own UEFI CAs use RSA-2048, and some firmware handles larger keys poorly (**uncertain**, folklore I could not confirm upstream). shim-review requires RSA-4096 only for certs embedded in a shim.

Rules that hold for all keys:

- **Test keys never appear in a release db or release trust policy.** A test-signed UKI must not boot on a release-enrolled machine, and a test-signed image must not pass a release client's `policy.json`.
- **Release private keys never touch CI or the NUC runner.** Signing is a manual step by the owner per release, which suits a release cadence measured in weeks. What gets signed must be tied to a reviewed `main` commit; see the "compromised CI build" row in [section 6](#6-threat-model).

### 4.2 Image signing on the client

bootc pulls through containers/image and honours `/etc/containers` ([bootc registries](https://bootc.dev/bootc/bootc-registries-and-offline.7.html)). `policy.json` supports `sigstoreSigned` with a fixed key (`keyPath`/`keyPaths`), with Fulcio keyless identities (then a Rekor public key is *"mandatory"*), or with a private PKI ([containers-policy.json(5)](https://github.com/containers/container-libs/blob/main/image/docs/containers-policy.json.5.md)). The registry needs `use-sigstore-attachments` in registries.d. bootc's `--enforce-container-sigpolicy` is *"the inverse of the previous `--target-no-signature-verification`"* ([bootc-switch(8)](https://bootc.dev/bootc/man/bootc-switch.8.html)): with it, the switch is checked against that policy.

Recommendation inside any option: release images ship `policy.json` with `sigstoreSigned` and **`keyPaths`** listing the current and next release image public keys. Two keys allow rotation without a flag day. Verification is offline and calls no one (D-005).

**What the OS can verify today** ([container-libs#388](https://github.com/containers/container-libs/issues/388), open on 2026-11-06; confirmed in PR #70):

- **GitHub keyless signatures: not at all.** The `fulcio` policy matches only `subjectEmail`, while GitHub Actions certificates carry a URI identity, and there is no URI field. Keyless can be checked with `cosign verify`, never by bootc or podman. So keyless is out for releases **and** for test images that the dev VM or NUC should verify with the OS's own policy.
- **cosign v3's default bundle format: not readable.** Every signature the OS should check must be made with `--new-bundle-format=false` (legacy `.sig` attachment), as PR #70 does.
- **Rekor upload: not needed** when clients verify with `keyPaths`. Release signing uses `--tlog-upload=false`, so nothing about our private repository goes into a public log, and verification needs no network (D-005).

Note: cosign signatures carry only the repository, so `signedIdentity` can only match the repository, which *"does not guard against tag substitution"* ([containers-policy.json(5)](https://github.com/containers/container-libs/blob/main/image/docs/containers-policy.json.5.md)). An attacker could serve an older, validly signed image under the current tag. Mitigation in section 6.

### 4.3 Rotation and revocation

| Key | Planned rotation | If compromised |
| --- | --- | --- |
| Release image key | Every 2 years. The next key's public half ships in `keyPaths` one release ahead | Ship an update signed with the old key that removes it from `keyPaths` (only works if the attacker has not already pushed a malicious update); publish an advisory; users who updated from a malicious image must reinstall |
| Release Secure Boot key | Every 2–3 years. Add the new cert to db one release ahead, then sign with it | Option A: Microsoft/SBAT revocation of our shim, new review. Option B1: an update appends the old cert's hash to **dbx** via the per-machine KEK. B2: remove it from MOK (needs MokManager confirmation) |
| Per-machine KEK | Never, unless the user asks | Machine-local. The user resets keys in firmware and re-runs enrolment |
| Developer key | When developer mode is turned off: removed from db and deleted | Same as above |
| Test keys | Whenever convenient | Not a security event, by design |

Two keys for one owner is a bus-factor risk: if both tokens are lost, no update can be signed for existing machines, and users must reinstall. Keep a sealed paper or offline backup of each release key (**question 3**).

## 5. Recommendation (for the owner to decide)

**Option B (user key enrolment at install), with B1 as the default path and B2 as a fallback if the spike confirms it. Do not apply for shim-review in v1.**

Why:

1. **It boots on more laptops today.** Option A cannot boot on firmware without UEFI CA 2023, and that set does not shrink for unsupported models. B1 works on all of them.
2. **The machine owns its trust root** (§2, C10, priority 6). With a per-machine KEK and Microsoft's KEK left out (3.2, choice b), no outside party can change what the machine trusts. Atos still can, through a signed update running as root, so the release image key is effectively the key to every machine's Secure Boot trust and is protected accordingly (4.1). With option A, Microsoft's signature is the reason the machine trusts us, and Microsoft's KEK can change db at any time.
3. **No external dependency.** No legal entity, EV cert, Microsoft account, months of review or ongoing SBAT obligations, and no D-007 question.
4. **Same keys we need anyway.** Developer mode (#68) needs a per-machine enrolled key under either option. B1 makes that the same mechanism, not a second one.
5. **Cost is one firmware step.** The installer must explain setup mode per vendor. That is real friction (priority 3, familiar), so C11 must design it carefully and keep option C (warn, continue without Secure Boot trust) available.

When option A would be the better call: if the target list (§3, certified hardware) turns out to be mostly recent machines with UEFI CA 2023 already in db, and the setup-mode step proves too hard in C11 user tests. A can be added later beside B, since it needs no change to the image signing side.

## 6. Threat model

| Threat | What an attacker gets without mitigation | Mitigation |
| --- | --- | --- |
| **Stolen CI secret** | If CI held release keys: a validly signed malicious OS update for every user | Release keys never live in CI (4.1). CI holds only the test key pair, and **any writer to any branch can read it**, agent sessions included (no environment branch rules on the Free plan). That is accepted because no release machine trusts it: test keys are absent from release `policy.json` and db. A stolen test key means rotating it, with no advisory. The same writers can also use the workflow's `packages: write` token to push to our registry; see the next two rows |
| **Malicious PR** | Code running in CI with secrets; code on the NUC runner; malicious code merged and later signed | Fork-PR workflows are disabled and the repo is private. PR builds never sign or push (#50). PR jobs get no secrets and `permissions: {}` by default (already in `perf.yml`, `d006-measure.yml`). The NUC runs only label-gated jobs on same-repo branches. Every PR needs a reviewer agent and, for security-relevant code, the owner (CLAUDE.md). None of this stops a writer from changing a workflow on a branch, so it does not protect the test key or the push token (row above) |
| **Compromised CI build** (merged workflow change, compromised action, or a stolen push token replacing an image) | The owner reviews **source**, then signs a **binary** CI built. A modified image under a digest the owner then signs gets a valid release signature. **This is the weakest link if release images come from CI** | Tie the signed digest to a reviewed `main` commit. GitHub artifact attestations would do this, but they need Enterprise Cloud for private repositories ([GitHub docs](https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds)), so they are out on our plan. Remaining options, for the owner (question 6): **(a)** the owner builds release images locally from the reviewed tag and signs what they built, so CI is never in the release path; **(b)** the owner rebuilds locally and signs CI's digest only if it matches, which needs reproducible image builds (**not checked** for our Containerfile). I recommend (a) for v1 |
| **Compromised registry** (ghcr.io account or GitHub) | Serve modified images; serve an **older** signed image (rollback) or withhold updates (freeze) | Clients verify the release signature with `sigstoreSigned` + `keyPaths` and `--enforce-container-sigpolicy`, so modified images are refused. Rollback/freeze: signatures do not cover tags, so add a signed version floor: the client refuses to **pull** any image whose signed version label is lower than the booted one, and the UI shows the age of the last update. The floor applies to registry pulls only. It must not block C1's "Previous version" boot entry, which by design boots an older, validly signed UKI; Secure Boot has no anti-rollback, so this is consistent. Design in a C1 card (**not checked** whether bootc has this built in) |
| **Stolen release token** (extra) | Same as stolen CI secret, for releases | PIN on the token, offline storage, rotation plan (4.3) with the next key pre-shipped |
| **Local root / evil maid** (extra) | Replace the UKI or enrol keys | Secure Boot rejects an unsigned UKI. Root can write db with the per-machine KEK, but not replace PK (discarded, 3.2). Changing db or MOK changes PCR7 / PCR14, so a TPM-bound LUKS key is not released and the user is asked for the recovery key. While a Microsoft UEFI CA is in db (the 2011 CA for option ROMs, 3.2 choice 1, or the 2023 CA if the user chose it), any Linux chain signed by it still boots, so the disk key binding, not db, protects the data. C11 should bind LUKS to PCR7 plus a signed PCR11 policy (systemd-measure); design in #66 |

## 7. Proposed decisions-log entry

For the owner to add if accepted (agents do not edit `docs/spec.md`):

> D-014 | Secure Boot trust by key enrolment at install: per-machine PK (discarded after enrolment) and KEK, no Microsoft KEK, Atos ships dbx updates; db holds the Atos release cert and the Microsoft Option ROM UEFI CA 2023, plus the Microsoft UEFI CA 2011 only where the TPM event log shows option ROMs; Microsoft UEFI and Windows CAs optional. No shim-review in v1. Release image and Secure Boot keys live on offline hardware tokens held by the owner, who builds release images locally from a reviewed tag; CI holds only test keys; clients enforce `sigstoreSigned` with pinned keys (legacy signature format) | Proposed | Boots on firmware without UEFI CA 2023; no outside party can change a machine's trust (Atos can, through signed updates); no Microsoft or review dependency. See `docs/decisions/D-014-signing-keys.md`

## 8. Phase 1 work this implies

If option B is decided:

1. **#54 (existing):** sealed UKI signed with the **test** Secure Boot key boots in the dev VM; systemd-boot `if-safe` auto-enrols the test key in the VM. No change in scope.
2. **New C1 card, spike:** B2 path: does Fedora's shim start systemd-boot and verify our UKI via MOK, and is Fedora's current shim dual-signed? Result picks B2 as fallback or drops it.
3. **New C1 card:** release procedure doc and script, run on the owner's machine (question 6, option a). Order matters, because injecting the UKI changes the image digest:
   1. Build the image from the reviewed release tag, with an **unsigned** sealed UKI.
   2. Sign the UKI with the release Secure Boot key on the token ([external signing](https://bootc.dev/bootc/building/bootc-sealed-images.7.html); upstream calls this workflow *"planned for streamlining"*).
   3. Inject the signed UKI into the final image. This produces the **final digest**.
   4. Push, then sign that final digest: `cosign sign --key pkcs11:… --new-bundle-format=false --tlog-upload=false <image>@<final digest>` (4.2).
   5. Verify with the shipped `policy.json` (podman or bootc), not only with `cosign verify`, before moving the release tag.
4. **New C1 card:** client trust policy: `policy.json` with `sigstoreSigned` + `keyPaths`, registries.d `use-sigstore-attachments`, `--enforce-container-sigpolicy`, and a signed version floor against rollback that applies to registry pulls only, never to the "Previous version" boot entry.
5. **#66 (existing), extended:** installer generates per-machine PK/KEK, guides the user through setup mode, checks the TPM event log for option ROMs (3.2), enrols PK/KEK/db, **discards the PK private key**, then seals LUKS to the TPM **after** enrolment (PCR7 changes on enrolment). Falls back to option C with a warning.
6. **#68 (existing):** developer mode generates a per-machine developer db key, using the same enrolment code.
7. **New C1 card:** key rotation and dbx update path via the per-machine KEK: an update carries Microsoft's published dbx list and a local tool signs and writes it (3.2, choice b), plus the next-key pre-ship.

Buying hardware tokens is out of scope for this card (owner's task).

## 9. Open questions

1. **D-007 and shim-review.** Does filing a shim-review application count as an "upstream contribution"? Only matters if option A is chosen now or later.
2. **Legal entity.** Is there one that could pass shim-review's legitimacy check and get an EV cert? Only matters for option A.
3. **Key backup.** Is a second token in a separate location enough, or does the owner want a paper/offline backup or a second key holder?
4. **Microsoft's KEK (3.2).** (a) Keep it: Microsoft's dbx updates apply as-is, but Microsoft can also change db. (b) Leave it out: only the machine's KEK changes db/dbx, and Atos ships dbx updates itself. Recommended: (b).
5. **Option ROMs signed under 2011 (3.2).** Where the TPM event log shows option ROMs: trust the Microsoft UEFI CA 2011 (safe for hardware, but every 2011-signed Linux chain boots), enrol the measured hashes (narrow, experimental, breaks on GPU firmware updates), or accept the brick risk. Recommended: CA 2011 by default, hashes as an advanced option.
6. **Where release images are built (section 6).** (a) The owner builds locally from the reviewed tag; (b) the owner rebuilds and signs CI's digest only if it matches (needs reproducible builds). Artifact attestations are not available on our plan. Recommended: (a).
7. **Default db contents.** Should the installer include Microsoft's UEFI CA 2023 (other Linux live media boot) and the Windows CAs by default, or ask? Including them is more familiar; leaving them out is safer.
8. **Test Secure Boot key in the repo or in a CI secret?** Committing it is simpler and honest about it being public; a secret keeps it out of casual reach. Either way it is readable by every writer (section 6).

## Sources

- shim-review requirements and CA 2023 rule: <https://github.com/rhboot/shim-review>
- CA expiry and db updates: <https://lwn.net/Articles/1079808/>, <https://www.redhat.com/en/blog/expiration-secure-boot-signing-certificates-2026>
- Option ROM CA split and 2011-signed option ROMs: <https://techcommunity.microsoft.com/t5/hardware-dev-center/signing-with-the-new-2023-microsoft-uefi-certificates-what/ba-p/4455787>, <https://www.asus.com/support/faq/1056827/>, <https://github.com/Foxboron/sbctl/wiki/FAQ>, <https://github.com/Foxboron/sbctl/blob/master/docs/sbctl.8.txt>
- bootc sealing and signing: <https://bootc.dev/bootc/bootc-composefs.7.html>, <https://bootc.dev/bootc/building/bootc-sealed-images.7.html>, <https://bootc.dev/bootc/bootc-registries-and-offline.7.html>, <https://bootc.dev/bootc/man/bootc-switch.8.html>
- systemd-boot key enrolment: <https://www.freedesktop.org/software/systemd/man/latest/loader.conf.html>
- Image signing: <https://docs.sigstore.dev/cosign/signing/overview/>, <https://docs.sigstore.dev/cosign/signing/signing_with_containers/>, <https://github.com/containers/container-libs/blob/main/image/docs/containers-policy.json.5.md>, <https://github.com/containers/container-libs/issues/388>
- Build provenance on private repositories: <https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds>
