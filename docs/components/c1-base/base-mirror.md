# Base image mirror

Card: #117. Fedora's quay.io repository garbage-collects old digests of `fedora-bootc:45`. That broke every c1-base build twice (#116, #148), because the Containerfile pins the base by digest. Atos therefore builds from its own copy of each pinned digest.

| | |
| --- | --- |
| Mirror | `ghcr.io/jens-thomae/atos/fedora-bootc` (owner OK for ghcr.io, 2026-11-08) |
| Tags | the image's version label, for example `45.20261108.0`. Builds pin the digest; the tag is for people and keeps the version from counting as "untagged" |
| Upstream | `quay.io/fedora/fedora-bootc`, Fedora's official repository |
| Copied by | [`.github/workflows/base-mirror.yml`](../../../.github/workflows/base-mirror.yml), on every branch push that changes a Containerfile (and by hand), running [`tools/ci/mirror-base.sh --copy`](../../../tools/ci/mirror-base.sh) |
| Checked by | the c1-base PR build (`mirror-base.sh` without `--copy`); the script's own test, [`tools/ci/test-mirror-base.sh`](../../../tools/ci/test-mirror-base.sh), runs in `ci.yml` |

## How a pin looks

Every Containerfile that builds on fedora-bootc (`components/c1-base`, `components/c11-installer`) has the same two lines:

```dockerfile
# upstream: quay.io/fedora/fedora-bootc:45@sha256:<digest>
ARG BASE=ghcr.io/jens-thomae/atos/fedora-bootc:<version>@sha256:<digest>
```

The `# upstream:` line is the audit record: it says which Fedora reference the mirrored digest was copied from, and it is the copy source. `mirror-base.sh` fails if the two digests differ, if `BASE` is not the mirror, or if the mirror does not hold exactly those bytes (sha256 of the raw index must equal the digest).

## The copy

`skopeo copy --all --preserve-digests` copies the multi-arch index, every per-architecture manifest and every layer unchanged, so the digest stays the same and the pin still matches. skopeo checks every blob against its digest while copying. Before copying, the script also checks that the tag in `BASE` equals the image's `org.opencontainers.image.version` label (amd64), so the tag cannot name the wrong release.

**Signatures.** Fedora publishes no signature for `quay.io/fedora/fedora-bootc` today: no cosign `.sig` tag and no OCI referrers (checked for the current pin on 2026-11-08; #118 found the same for the previous one). Trust in the content is therefore trust in Fedora's quay.io repository at the time of the bump, as before this card; the mirror only stops it from disappearing. If either a `.sig` tag or a referrer appears, the copy **fails** instead of skipping it: verifying it needs Fedora's public key pinned in this repository first, which would be a new card.

**Permissions.** Only the `base-mirror.yml` job has `packages: write`, and its `GITHUB_TOKEN` gets nothing else (`contents: read` for the checkout). It handles no secret besides that token. Pull request builds and `publish` only read the mirror. As with the layer cache, `packages: write` is not a boundary against people with push access: they can run any workflow on their branch, which is also why the copy may run on branch pushes: a push needs write access, so forks never get the token, and their pull requests only read. The digest check is what protects builds: a tag pushed to the mirror from a branch cannot change what a reviewed digest pin pulls.

## Bumping the base

1. Pick the new digest of `quay.io/fedora/fedora-bootc:45` (multi-arch index) and its version label, as in #118 and #149.
2. Change both lines in both Containerfiles.
3. Push the branch. The push starts `base-mirror.yml`, which copies the new digest; the c1-base PR build waits up to 10 minutes for it ("not mirrored yet" means it gave up: check the mirror run, then re-run the build). By hand: `gh workflow run base-mirror.yml --ref <branch>`.
4. The rest of the bump routine stays as it was (the bootc patch routine in [boot-counting.md](boot-counting.md#rebase-effort)).

## Retention

**Mirrored versions are never deleted automatically.** ghcr.io has no automatic expiry, and no workflow in this repository deletes package versions. A version of `atos/fedora-bootc` may be deleted only by hand, and only when no supported published Atos image was built from it.

To find which base a published image was built from: its `org.atos.source` label names the commit (`ghcr.io/jens-thomae/atos/c1-base:<sha>-source`), and that commit's `components/c1-base/Containerfile` has the `BASE` and `# upstream:` lines.

The spec does not yet define how long a published image is supported, so for now **every mirrored version is kept**. About 1 GB compressed per bump, shared layers counted once.

## Public pulls

The package was created by the first mirror run (2026-11-08, [run 42493833871](https://github.com/jens-thomae/Atos/actions/runs/42493833871)) and is public: an anonymous pull of the pinned digest succeeds, so local builds and the c11-installer build (which logs out of ghcr.io before building) need no account (D-005).
