# Client trust policy

Card #75 (D-014, threat model rows *Compromised registry* and *Stolen CI secret*). An installed Atos system pulls only images of `ghcr.io/jens-thomae/atos/c1-base` that are signed with the key its image pins, and never stages an image whose signed version is lower than the booted one or the one already staged. The "Previous version" boot entry is not affected.

## Files in the image

All of them are in `/usr`, so they are inside the sealed composefs digest. Fedora 45 already keeps its policy in `/usr/share/containers/`; nothing is in `/etc`.

| File (source in `components/c1-base/`) | Does |
| --- | --- |
| [`usr/share/containers/policy.json`](../../../components/c1-base/usr/share/containers/policy.json) | Fedora's policy plus one scope: `docker` → `ghcr.io/jens-thomae/atos/c1-base` requires `sigstoreSigned` with `keyPaths` and `signedIdentity: matchRepository`; `containers-storage` → `""` is `reject` (#150, [below](#local-images-containers-storage)) |
| `/usr/share/pki/containers/atos-c1-base-test.pub` | The **TEST** cosign public key, copied from [`cosign.pub`](../../../components/c1-base/cosign.pub) by the [`Containerfile`](../../../components/c1-base/Containerfile) (one file, so it cannot drift from the key CI signs with) |
| [`usr/share/containers/registries.d/atos.yaml`](../../../components/c1-base/usr/share/containers/registries.d/atos.yaml) | `use-sigstore-attachments: true` for the Atos image; without it the signature is not looked up |
| [`usr/lib/bootc/install/85-atos-sigpolicy.toml`](../../../components/c1-base/usr/lib/bootc/install/85-atos-sigpolicy.toml) | `enforce-container-sigpolicy = true`: `bootc install` behaves as if `--enforce-container-sigpolicy` were passed |
| [`third_party/bootc/patches/0002-…`](../../../third_party/bootc/patches/) | The version floor (below) |

The lookup order is `containers-policy.json(5)`'s: `$HOME/.config/containers/policy.json`, then `/etc/containers/policy.json`, then `/usr/share/containers/policy.json`. An administrator can still override the policy by writing `/etc/containers/policy.json` (ownership, §2 priority 6); that is a root action and outside this card's threat model.

**Other images.** The signature policy's default stays Fedora's `insecureAcceptAnything`, so `podman pull` of other images keeps working, and the signature check protects only the image the system tracks, which is what a compromised registry would target. **The version floor does not look at the repository**, though: it applies to every `bootc upgrade` and `bootc switch` target. Once an image with an Atos label (`20261107.x`) is booted, `bootc switch` to stock `fedora-bootc:45` (`45.x`) or to any image without a numeric label is refused.

## How bootc applies it

`--enforce-container-sigpolicy` is an ostree-backend concept: it records `ostree-image-signed:` in the deployment's origin and refuses a policy whose default is `insecureAcceptAnything`. **Our backend is composefs (D-008), and there bootc 1.17.1 does not use it**: it accepts the flag, but always writes `ostree-unverified-image:` into the origin (upstream `TODO` in `bootc_composefs/state.rs`) and never passes `--insecure-policy` to skopeo. So on composefs the policy is enforced on **every** pull, with or without the flag, by `skopeo experimental-image-proxy` reading `policy.json` (checked in source: `bootc_composefs/repo.rs`, `status.rs`; shown in the VM below). The install config and the flag in the demo are kept so that the setting is already right if bootc starts honouring it on composefs.

## Local images (`containers-storage`)

Card #150 (D-015: local images are allowed in the trust policy only while developer mode is on). The policy's `containers-storage` transport has one scope, `""` → `reject`, so `bootc switch --transport containers-storage <any local image>` is refused before anything is copied, on every machine. Secure Boot already refused such an image's UKI on a machine without developer mode ([dev-image-spike.md §5](dev-image-spike.md#5-other-findings-for-the-follow-up-cards)); the policy now refuses it one step earlier, as D-015 says.

**Where bootc checks it** (bootc 1.17.1 and composefs-rs v0.9.2, the pinned versions; shown in the VM below). Every composefs `bootc switch` and `bootc upgrade` first opens the target through `skopeo experimental-image-proxy` to read its manifest and config (`is_image_pulled` → `get_container_manifest_and_config`), without `--insecure-policy`. The proxy checks `policy.json` at `OpenImage` for every transport, so a local target is refused there, before either pull path. The default (direct) pull opens it through the proxy again. The opt-in unified path (`--unified-storage-exp`, or when the image is already in bootc's own storage) copies with `podman image push`, which ignores the policy for local storage, and then imports without skopeo; it only runs after that first check.

**Other users of local storage.** The policy applies to every program that copies **from** local storage, not only bootc. podman and buildah override it for `podman build` and `podman push`, so those keep working. `podman save`, `podman image scp` and `podman manifest push` of a local image are refused (see the VM results). Rootless podman reads `~/.config/containers/policy.json` first, so a user can restore them for their own storage without root. Pulling into local storage, `podman run` and Flatpak are not affected.

### Allowing the developer reference (for #102 and #104)

D-015 allows **one fixed reference** while developer mode is on. For the transport, a policy scope names the store as well as the image: `[driver@graph-root]image` (`containers-policy.json(5)`). On Atos, root's store is `overlay@/var/lib/containers/storage`, so the scope for `containers-storage:localhost/atos-dev:current` is:

```json
"containers-storage": {
    "[overlay@/var/lib/containers/storage]localhost/atos-dev:current": [{ "type": "insecureAcceptAnything" }],
    "": [{ "type": "reject" }]
}
```

- **`insecureAcceptAnything`** because a local build carries no container signature. What protects it is the developer key on its UKI and the authenticated build (D-015), not the policy.
- **Where.** `/usr` is sealed, and the policy is one file with no drop-ins: the first of `$HOME/.config/containers/policy.json`, `/etc/containers/policy.json`, `/usr/share/containers/policy.json` wins outright. So turning developer mode on writes `/etc/containers/policy.json` as a **copy of `/usr/share/containers/policy.json` plus that one scope**, root-owned, mode 0644, and turning it off deletes the file. The VM test does exactly this.
- **Keep the copy current.** While the file exists, it hides any newer `/usr` policy, including a key rotation (Key rotation, below): the rebuild service's verified pulls would use the copy's old `keyPaths`. One way, for #102/#104 to decide (not decided or built here): regenerate the copy from the booted `/usr` policy on every boot while developer mode is on.
- **Leaving.** developer-mode.md 2.2 step 1 removes the exception first. Without the file, `bootc upgrade` on a machine that follows the local reference is refused at the same check, so nothing new is staged from local storage.

**Installing reads a local image too.** `bootc install`, run as `podman run <image> bootc install …`, opens its own image from local storage (by image ID) under the policy **inside that image**, so the reject refuses it: *Running image containers-storage:[overlay@/var/lib/containers/storage+…]@e27bb63f… is rejected by policy*. A scope cannot tell that read apart from a `bootc switch` to the same store by ID. So every install path gives the install container alone a policy with the `containers-storage` rule accepted (`-v <file>:/etc/containers/policy.json:ro`). The installed system does not get that file (`/etc/containers/policy.json` is absent after install, VM below). `tools/dev-vm/sealed.sh` does this for its three installs; the installer (#66, `atos-install`) and `spikes/c1-dev-image/run.sh` do not yet (open question on #150).

**Other stores.** A reference that names another store (`containers-storage:[vfs@/some/root]image`) falls under `""` and is refused; only the exact scope above is allowed. An administrator can still write any policy to `/etc` (above); that is a root action.

### VM results

The whole `trust` suite was re-run on this branch: the #75 results below are unchanged (every refusal with the same message, trust-2 applied, trust-1 boots from the menu). The `stage` step now needs more than the default 45 min here, so it gets 90.

`tools/dev-vm/sealed.sh trust local`, on a copy of the freshly installed trust-1 disk (the `trust` setup, Dev VM demo below), 2026-11-08, M1 Max, aarch64 under QEMU emulation. Log: `tools/dev-vm/out/sealed/trust-local.log`. trust-2 is copied into root's local storage as `localhost/atos-dev:current` and tagged `localhost/other:test`.

| Check | Result |
| --- | --- |
| `/etc/containers/policy.json` after install with the override | absent |
| Root's store | `overlay@/var/lib/containers/storage` |
| `bootc switch --transport containers-storage localhost/other:test` | refused: *Checking if image localhost/other:test is pulled: … OpenImage: Running image containers-storage:[overlay@/var/lib/containers/storage+…]localhost/other:test is rejected by policy* |
| the same for `localhost/atos-dev:current` | refused, the same message |
| `podman build` `FROM` a local image | works |
| `podman push` of a local image to a registry | works |
| `podman save` of a local image | refused: *Source image rejected: … is rejected by policy* |
| Developer-mode file in `/etc`: `localhost/other:test` | refused |
| Developer-mode file in `/etc`: `localhost/atos-dev:current` | **staged** (`bootc_fedora-45-1+3.conf`) |
| File removed: `bootc switch … localhost/other:test` | refused |
| File removed: `bootc upgrade --check` (spec now names the staged local reference) | refused: *Upgrading composefs: Checking if image localhost/atos-dev:current is pulled: … rejected by policy* |

## Release key slot

D-014: release images are built and signed by the owner with the release key on a hardware token; CI holds only the test key, and **no release machine trusts the test key**. The slot is `keyPaths`:

| Image | `keyPaths` |
| --- | --- |
| CI and dev builds (now) | `["/usr/share/pki/containers/atos-c1-base-test.pub"]` |
| Release builds (release procedure card, D-014 §8 item 3) | `["/usr/share/pki/containers/atos-c1-base-release.pub"]`, and the test key file is not in the image |

The release procedure swaps the key file and the path; this card adds no release key. A missing key file would make every pull fail, so the release key path is not listed before the key exists.

### Key rotation

A system trusts only the keys in the image it booted. To rotate a key, first ship an image whose `keyPaths` lists the old and the new key, sign it with the old key, and only then sign with the new key alone. Images signed only with the new key are refused by systems that have not taken that bridging update. D-014 §8 item 7 (key rotation card) owns the procedure.

## Signed version floor

**Built in?** No. bootc 1.17.1 (the version fedora-bootc 45 ships) and bootc `main` (checked 2026-11-07) have no downgrade check for image pulls; ostree's timestamp check (`rpm-ostree --allow-downgrade`) does not apply to container images; and upstream's post-pull hook ([bootc#640](https://github.com/bootc-dev/bootc/issues/640)) is still open. So the floor is a second carried bootc patch, like boot counting (#56, D-007/D-008).

**The patch** (rebased with the other carried patch on each bootc bump, using the routine in [boot-counting.md](boot-counting.md); `0002-composefs-refuse-to-stage-an-image-older-than-the-bo.patch`, about 90 lines with its test) adds one check to bootc's composefs `bootc upgrade` and `bootc switch` (which Fedora's enabled `bootc-fetch-apply-updates.timer` also runs). The check always runs before anything on disk changes. If the target is already in the local composefs repository, it runs before `validate_update`, because that step removes staged boot entries; otherwise a refused image, cached by an earlier attempt, could un-stage a pending good update. Otherwise it runs in `do_upgrade` after the pull, before staging:

1. It reads the target image's version label from its config (the pulled one in the local repository, or the signature-checked config of a cached one): `org.opencontainers.image.version`, else `version` (ostree-ext's `version_for_config`).
2. It reads the labels of the booted image and, if an update is staged, of the staged image. **The floor is the higher of the two** (owner decision on #133): with v3 booted and v5 staged, a signed v4 would otherwise replace the update the client already accepted.
3. It refuses to stage if the new version is lower than either, comparing dot-separated integers component by component (`45.2` < `45.10`, and `1.20` > `1.3`).

The table applies to each of the booted and staged labels:

| Floor label (booted or staged) | New label | Result |
| --- | --- | --- |
| numeric | numeric, equal or higher | staged |
| numeric | numeric, lower | **refused** |
| numeric | missing or not numeric | **refused** (cannot show it is newer) |
| missing or not numeric | anything | staged (no floor) |

**Why the label is signed.** The cosign signature covers the manifest digest; the manifest names the config by digest; labels live in the config. The check runs on the image as pulled, after skopeo verified its signature, not on a separate manifest fetch, so the registry cannot swap the image between check and stage.

**What it does not touch.** The check is only in the pull path. Existing boot entries, `bootc rollback` and the systemd-boot menu do not pass through it, so the "Previous version" entry (an older, validly signed UKI) always boots. Secure Boot has no anti-rollback either (D-014 §6), so the two are consistent.

**Limits.**

- For an image that is not cached yet, the refusal comes after the download, before staging: an attacker serving an old image costs the client one download, and nothing changes on disk apart from the cached image. A check before the download would need a second manifest fetch, which the registry could answer differently, so the authoritative check stays after the pull.
- A frozen registry (no new images at all) is not detected; D-014's other half, showing the age of the last update in the UI, belongs to C3/C8.
- There is no override for a deliberate downgrade. The user can boot the previous version from the menu; a downgrade below the booted or staged version is refused. Question for the owner on #75.

**The version label.** The `publish` job of [`c1-base.yml`](../../../.github/workflows/c1-base.yml) sets `org.opencontainers.image.version` to the commit time in UTC, `YYYYMMDD.HHMMSS` (for example `20261107.203512`). It is set with `--label` on the build, like `org.atos.source`, so the Containerfile is unchanged. Without it, every image would carry Fedora's base label (`45.20261107.0`), which only changes with a base bump. Commit time grows with each merge to `main`, and `:latest` only moves forward along `main` already (README, *Where it goes*). `20261107.x` compares higher than Fedora's `45.x`, so systems installed from older images take the first labelled update. Release images must use labels that compare higher than every CI image a release machine could have booted; the release procedure card decides the format.

## Dev VM demo

[`tools/dev-vm/sealed.sh trust`](../../../tools/dev-vm/sealed.sh), on its own disk and VM instance:

```bash
ATOS_VM=atos-c75 tools/dev-vm/vm run tools/dev-vm/sealed.sh trust
```

The images are the shipped Containerfile plus two VM-only lines, from a copy in `~/sealed`: the policy scope and registries.d entry point at the VM registry (`10.0.2.2:5000/atos/c1-base`), and the pinned key is a cosign key generated in the VM (`~/sealed/trust-keys/good.pub`, never committed, like every key here a test key). A second key, `wrong`, signs one image. Signing uses cosign v3.1.4 with CI's flags (legacy format, no transparency log), and `--sign-container-identity` so the signature names the registry as the guest sees it.

Results (M1 Max, aarch64 under QEMU emulation, 2026-11-08, after the review fixes; logs in `tools/dev-vm/out/sealed/trust-*.log`, filtered):

| Step | Result |
| --- | --- |
| `install` | `bootc install to-disk` from trust-1 works with the install config; it prints *Installing image: ostree-image-signed:docker://10.0.2.2:5000/atos/c1-base:latest* |
| `stage`: unsigned | refused before any layer download: *OpenImage: A signature was required, but no signature exists* |
| `stage`: wrong key | refused before any layer download: *cryptographic signature verification failed: invalid signature when validating ASN.1 encoded signature* |
| `stage`: old (1.0, signed with the right key), `bootc switch` | refused after the download, nothing staged: *Refusing image version 1.0: lower than the booted version 1.10 (signed version floor)* |
| `stage`: `bootc upgrade` to `:latest` = trust-2 (1.30, signed) | staged (`ATOS-TRUST latest staged`) |
| `stage`: `:latest` → trust-mid (1.20: above booted 1.10, below staged 1.30), `bootc upgrade` | refused: *Refusing image version 1.20: lower than the staged version 1.30* |
| `stage`: `:latest` → trust-old, `bootc upgrade` twice, then `bootc switch` to it | all three refused. The first went through the pull (the earlier copy had been garbage-collected when trust-2 was staged); the second and the switch found it cached and were refused before `validate_update` (no *Performing Upgrade Operation* in their messages) |
| `stage`: staged entries afterwards | `entries.staged`: `bootc_fedora-45-0.conf bootc_fedora-45-1+3.conf`; trust-2 is still staged |
| `apply` | `ATOS-BOOT image=trust-2`, with the boot counter of #56 (`bootc_fedora-45-1+2-1.conf`); `rollback:` trust-1. The refusals left the staged update intact |
| `previous` | boot menu, second entry: `ATOS-BOOT image=trust-1`. The older image boots; the floor does not apply to boot entries |

The patch's unit tests (`version_floor`, `version_floor_booted_and_staged`) ran in the image build: 3 passed, with boot counting's.

**`bootc status` shows Fedora's version.** It printed `version: 45.20261107.0` for every image: composefs status reads the **manifest annotation** `org.opencontainers.image.version`, which the images inherit from the base, not the config label the floor uses. Display only; the floor reads the config labels correctly (see the refusal messages). Setting the annotation as well in CI is a possible follow-up (not done here, not tested).
