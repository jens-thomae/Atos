# Client trust policy

Card #75 (D-014, threat model rows *Compromised registry* and *Stolen CI secret*). An installed Atos system pulls only images of `ghcr.io/jens-thomae/atos/c1-base` that are signed with the key its image pins, and never stages an image whose signed version is lower than the booted one. The "Previous version" boot entry is not affected.

## Files in the image

All of them are in `/usr`, so they are inside the sealed composefs digest. Fedora 45 already keeps its policy in `/usr/share/containers/`; nothing is in `/etc`.

| File (source in `components/c1-base/`) | Does |
| --- | --- |
| [`usr/share/containers/policy.json`](../../../components/c1-base/usr/share/containers/policy.json) | Fedora's policy plus one scope: `docker` → `ghcr.io/jens-thomae/atos/c1-base` requires `sigstoreSigned` with `keyPaths` and `signedIdentity: matchRepository` |
| `/usr/share/pki/containers/atos-c1-base-test.pub` | The **TEST** cosign public key, copied from [`cosign.pub`](../../../components/c1-base/cosign.pub) by the [`Containerfile`](../../../components/c1-base/Containerfile) (one file, so it cannot drift from the key CI signs with) |
| [`usr/share/containers/registries.d/atos.yaml`](../../../components/c1-base/usr/share/containers/registries.d/atos.yaml) | `use-sigstore-attachments: true` for the Atos image; without it the signature is not looked up |
| [`usr/lib/bootc/install/85-atos-sigpolicy.toml`](../../../components/c1-base/usr/lib/bootc/install/85-atos-sigpolicy.toml) | `enforce-container-sigpolicy = true`: `bootc install` behaves as if `--enforce-container-sigpolicy` were passed |
| [`third_party/bootc/patches/0002-…`](../../../third_party/bootc/patches/) | The version floor (below) |

The lookup order is `containers-policy.json(5)`'s: `$HOME/.config/containers/policy.json`, then `/etc/containers/policy.json`, then `/usr/share/containers/policy.json`. An administrator can still override the policy by writing `/etc/containers/policy.json` (ownership, §2 priority 6); that is a root action and outside this card's threat model.

**Other images.** The default stays Fedora's `insecureAcceptAnything`, so `podman pull` and `bootc switch` to other images keep working. The policy protects the image the system tracks, which is what a compromised registry would target.

## How bootc applies it

`--enforce-container-sigpolicy` is an ostree-backend concept: it records `ostree-image-signed:` in the deployment's origin and refuses a policy whose default is `insecureAcceptAnything`. **Our backend is composefs (D-008), and there bootc 1.17.1 does not use it**: it accepts the flag, but always writes `ostree-unverified-image:` into the origin (upstream `TODO` in `bootc_composefs/state.rs`) and never passes `--insecure-policy` to skopeo. So on composefs the policy is enforced on **every** pull, with or without the flag, by `skopeo experimental-image-proxy` reading `policy.json` (checked in source: `bootc_composefs/repo.rs`, `status.rs`; shown in the VM below). The install config and the flag in the demo are kept so that the setting is already right if bootc starts honouring it on composefs.

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

**The patch** (rebased with the other carried patch on each bootc bump, using the routine in [boot-counting.md](boot-counting.md); `0002-composefs-refuse-to-stage-an-image-older-than-the-bo.patch`, about 70 lines with its test) adds one check to `do_upgrade` in `bootc_composefs/update.rs`, which both `bootc upgrade` and `bootc switch` go through, as does Fedora's enabled `bootc-fetch-apply-updates.timer`:

1. After the pull, it reads the version label of the pulled image from the local composefs repository: `org.opencontainers.image.version`, else `version` (ostree-ext's `version_for_config`, the label `bootc status` knows).
2. It reads the booted image's label the same way.
3. It refuses to stage if the new version is lower, comparing dot-separated integers component by component (`45.2` < `45.10`).

| Booted label | New label | Result |
| --- | --- | --- |
| numeric | numeric, equal or higher | staged |
| numeric | numeric, lower | **refused** |
| numeric | missing or not numeric | **refused** (cannot show it is newer) |
| missing or not numeric | anything | staged (no floor) |

**Why the label is signed.** The cosign signature covers the manifest digest; the manifest names the config by digest; labels live in the config. The check runs on the image as pulled, after skopeo verified its signature, not on a separate manifest fetch, so the registry cannot swap the image between check and stage.

**What it does not touch.** The check is only in the pull path. Existing boot entries, `bootc rollback` and the systemd-boot menu do not pass through it, so the "Previous version" entry (an older, validly signed UKI) always boots. Secure Boot has no anti-rollback either (D-014 §6), so the two are consistent.

**Limits.**

- The refusal comes after the download, before staging: an attacker serving an old image costs the client one download, and nothing is staged. A check before the download would need a second manifest fetch, which the registry could answer differently, so the authoritative check stays after the pull.
- A frozen registry (no new images at all) is not detected; D-014's other half, showing the age of the last update in the UI, belongs to C3/C8.
- There is no override for a deliberate downgrade. The user can boot the previous version from the menu; a downgrade to an image older than both deployments is refused. Question for the owner on #75.

**The version label.** The `publish` job of [`c1-base.yml`](../../../.github/workflows/c1-base.yml) sets `org.opencontainers.image.version` to the commit time in UTC, `YYYYMMDD.HHMMSS` (for example `20261107.203512`). It is set with `--label` on the build, like `org.atos.source`, so the Containerfile is unchanged. Without it, every image would carry Fedora's base label (`45.20261107.0`), which only changes with a base bump. Commit time grows with each merge to `main`, and `:latest` only moves forward along `main` already (README, *Where it goes*). `20261107.x` compares higher than Fedora's `45.x`, so systems installed from older images take the first labelled update. Release images must use labels that compare higher than every CI image a release machine could have booted; the release procedure card decides the format.

## Dev VM demo

[`tools/dev-vm/sealed.sh trust`](../../../tools/dev-vm/sealed.sh), on its own disk and VM instance:

```bash
ATOS_VM=atos-c75 tools/dev-vm/vm run tools/dev-vm/sealed.sh trust
```

The images are the shipped Containerfile plus two VM-only lines, from a copy in `~/sealed`: the policy scope and registries.d entry point at the VM registry (`10.0.2.2:5000/atos/c1-base`), and the pinned key is a cosign key generated in the VM (`~/sealed/trust-keys/good.pub`, never committed, like every key here a test key). A second key, `wrong`, signs one image. Signing uses cosign v3.1.4 with CI's flags (legacy format, no transparency log), and `--sign-container-identity` so the signature names the registry as the guest sees it.

Results (M1 Max, aarch64 under QEMU emulation, 2026-11-07; logs in `tools/dev-vm/out/sealed/trust-*.log`, filtered):

| Step | Result |
| --- | --- |
| `install` | `bootc install to-disk` from trust-1 works with the install config; it prints *Installing image: ostree-image-signed:docker://10.0.2.2:5000/atos/c1-base:latest* |
| `stage`: unsigned | refused before any layer download: *OpenImage: A signature was required, but no signature exists* |
| `stage`: wrong key | refused before any layer download: *cryptographic signature verification failed: invalid signature when validating ASN.1 encoded signature* |
| `stage`: old (1.0, signed with the right key) | refused after the download, nothing staged: *Refusing image version 1.0: lower than the booted version 1.1 (signed version floor)* |
| `stage`: `bootc upgrade` to `:latest` = trust-2 (1.2, signed) | staged (`ATOS-TRUST latest staged`) |
| `apply` | `ATOS-BOOT image=trust-2`, with the boot counter of #56 (`bootc_fedora-45-1+2-1.conf`); `rollback:` trust-1 |
| `previous` | boot menu, second entry: `ATOS-BOOT image=trust-1`. The older image boots; the floor does not apply to boot entries |

The three refusals came from plain `bootc switch` calls, which run the same `do_upgrade` path as `bootc upgrade`.

**`bootc status` shows Fedora's version.** It printed `version: 45.20261107.0` for every image: composefs status reads the **manifest annotation** `org.opencontainers.image.version`, which the images inherit from the base, not the config label the floor uses. Display only; the floor read 1.0 and 1.1 correctly. Setting the annotation as well in CI is a possible follow-up (not done here, not tested).
