# C1 base image

The Atos base image is a bootc container image (D-008), built from [`components/c1-base/Containerfile`](../../../components/c1-base/Containerfile) by [`.github/workflows/c1-base.yml`](../../../.github/workflows/c1-base.yml).

## Base

| | |
| --- | --- |
| Image | `quay.io/fedora/fedora-bootc:45` |
| Pinned digest | `sha256:c3cccbe8c7263cfc610ca9697cf4e0a34bb5b590b394f413f1c159ef63fb15ac` (multi-arch index) |
| Version label | `45.20261105.0`, kernel `7.2.15-300.fc45` (amd64) |
| Size | 65 layers, about 1.04 GB compressed (amd64) |

The digest changes only through a reviewed change to the `FROM` line. CI builds amd64 only.

## Our layers

1. `systemctl mask rpm-ostree-countme.timer`: turns off Fedora's anonymous countme counter (D-005). CI checks that `systemctl is-enabled` reports `masked`.
2. Label `org.opencontainers.image.title=Atos base`.
3. `bootc container lint`: fails the build on image problems bootc knows about.

`dnf` in the image still has `countme=1` in Fedora's repo files. It sends the counter only when `dnf` runs on the host. Whether to strip it too is D-008 open question 4, for the owner.

## Where it goes

| Event | Result |
| --- | --- |
| Pull request (not docs-only) | Build and countme check. No registry token, no signing key. |
| Merge to `main` (not docs-only) | Build, push `ghcr.io/jens-thomae/atos/c1-base:<commit sha>`, sign, verify, then move `:latest`. |
| Docs-only change (`tools/ci/is-docs-only.sh`) | Skipped. |

**Public pulls (owner step, once).** A package pushed from a private repository starts private. After the first push to `main`, set the package to public: GitHub → Packages → `atos/c1-base` → Package settings → Change visibility → Public. Then pulls need no account (D-005). The REST API cannot change package visibility.

## Signing: CI-held test key

The image is signed with a **test key** held as repository secrets, in cosign's legacy `.sig` format, without a Rekor upload. It is not the release key; that strategy is card #53.

Why not keyless (Sigstore with GitHub's OIDC token):

- **The OS could not check it.** bootc and podman verify through containers/image. Its `sigstoreSigned` policy matches Fulcio certificates only by `subjectEmail`; GitHub Actions certificates carry a URI identity, which no field can match ([containers-policy.json(5)](https://github.com/containers/container-libs/blob/main/image/docs/containers-policy.json.5.md), [container-libs#388](https://github.com/containers/container-libs/issues/388), open on 2026-11-06).
- **cosign v3's default bundle format is not readable by containers/image yet** (same issue). So the workflow signs with `--new-bundle-format=false`.
- Keyless would write the private repository's name, workflow path and commit into the public Rekor log on every merge.

A key signature in the legacy format is the one form both `cosign verify` and the OS's own policy check accept today.

**Secrets and pull requests.** Only the `publish` job, which runs on pushes to `main`, references the secrets and gets `packages: write`. The `build` job has neither. This does not stop someone with write access from changing the workflow on a branch to read the secret: GitHub environments with branch rules are not available to private repositories on the Free plan. Acceptable for a test key; the release key (#53) must not live here.

**Key setup (owner step, once, before the first merge).** The `publish` job fails before pushing anything until this is done:

```bash
GITHUB_TOKEN=$(gh auth token) cosign generate-key-pair github://jens-thomae/Atos
```

This sets the secrets `COSIGN_PRIVATE_KEY`, `COSIGN_PASSWORD` and `COSIGN_PUBLIC_KEY` and writes `cosign.pub`. Commit `cosign.pub` as `components/c1-base/cosign.pub`. To rotate, run it again and commit the new public key; older images then verify only against the old key.

## Verifying the signature

With cosign (v3):

```bash
cosign verify --key components/c1-base/cosign.pub --insecure-ignore-tlog --new-bundle-format=false ghcr.io/jens-thomae/atos/c1-base:latest
```

`--insecure-ignore-tlog` is needed because the test key signs without a transparency log entry.

With podman or bootc, as the OS will check it (for example in the dev VM). `/etc/containers/policy.json`:

```json
{
  "default": [{ "type": "insecureAcceptAnything" }],
  "transports": {
    "docker": {
      "ghcr.io/jens-thomae/atos/c1-base": [
        { "type": "sigstoreSigned", "keyPath": "/etc/pki/containers/atos-c1-base.pub", "signedIdentity": { "type": "matchRepository" } }
      ]
    }
  }
}
```

`/etc/containers/registries.d/atos.yaml`, without which the signature is not looked up:

```yaml
docker:
  ghcr.io/jens-thomae/atos/c1-base:
    use-sigstore-attachments: true
```

Then `podman pull ghcr.io/jens-thomae/atos/c1-base:latest` or `bootc switch --enforce-container-sigpolicy ghcr.io/jens-thomae/atos/c1-base:latest` refuses an unsigned or wrongly signed image. Shipping this policy inside the image belongs to the update-loop and release-key cards.

## Hosted CI minutes (Free plan, docs/ci.md)

GitHub bills each job rounded up to a whole minute.

| Run | Measured | Billed |
| --- | --- | --- |
| Pull request: `changes` + `build` | 7 s + 46 s (pull about 40 s, build and lint 2 s) | 2 min |
| Merge to `main`: `changes` + `publish` | not run yet; estimate: build 1 min, first push of about 1 GB 2–4 min | about 4–6 min first run, then about 2–3 min |
| Docs-only | `changes` only | 1 min |

ghcr.io keeps layers it already has, so after the first push only our small layer is uploaded. The base pull from quay.io (about 1 GB) happens on every run.
