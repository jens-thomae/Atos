#!/usr/bin/env bash
# Base image mirror (#117, docs/components/c1-base/base-mirror.md).
# For every components/*/Containerfile with an `ARG BASE=` pin, checks that:
#   - the pin is our mirror, ghcr.io/jens-thomae/atos/fedora-bootc:<version>@sha256:<digest>;
#   - the `# upstream:` line names Fedora's quay.io repository with the same digest;
#   - the mirror holds exactly those bytes (sha256 of the raw index = digest).
# Default: check only (read access). With --copy: a digest the mirror lacks is first copied from upstream
# (needs packages: write), unless Fedora publishes a signature for it, which we cannot verify yet: then it fails.
# Needs skopeo, curl, jq, sha256sum. Test: tools/ci/test-mirror-base.sh
set -euo pipefail
MIRROR=ghcr.io/jens-thomae/atos/fedora-bootc
UPSTREAM=quay.io/fedora/fedora-bootc
copy=false; [ "${1:-}" = --copy ] && copy=true
die() { echo "::error::$*" >&2; exit 1; }
cd "$(git rev-parse --show-toplevel)"
raw=$(mktemp); trap 'rm -f "$raw"' EXIT

for f in components/*/Containerfile; do
  base=$(sed -n 's/^ARG BASE=//p' "$f"); [ -n "$base" ] || continue
  up=$(sed -n 's/^# upstream: //p' "$f")
  d=${base##*@}; tag=${base%@*}; tag=${tag#"$MIRROR:"}
  [[ $d =~ ^sha256:[0-9a-f]{64}$ ]] || die "$f: BASE is not pinned by digest: $base"
  [ "$base" = "$MIRROR:$tag@$d" ] && [[ $tag =~ ^[0-9A-Za-z._-]+$ ]] \
    || die "$f: BASE must be $MIRROR:<version>@<digest>, is $base"
  [[ $up =~ ^"$UPSTREAM"(:[0-9A-Za-z._-]+)?@"$d"$ ]] || die "$f: '# upstream:' must be $UPSTREAM:<tag>@$d, is '$up'"

  if ! skopeo inspect --raw "docker://$MIRROR@$d" > "$raw" 2>/dev/null; then
    $copy || die "$f: $MIRROR@$d is not mirrored yet: run the 'Base image mirror' workflow on this branch"
    # Fedora publishes no signature for these images today (checked 2026-11-08: no cosign .sig tag, no OCI referrers).
    # ponytail: fail closed if one appears; verifying it needs Fedora's key pinned here first (new card).
    api="https://${UPSTREAM%%/*}/v2/${UPSTREAM#*/}"  # quay.io serves public repositories without a token
    sig=$(curl -sS -o /dev/null -w '%{http_code}' \
      -H 'Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json' \
      "$api/manifests/${d/:/-}.sig")
    [ "$sig" = 404 ] || die "$UPSTREAM:${d/:/-}.sig answered HTTP $sig (404 = no cosign signature): verify it before mirroring"
    n=$(curl -fsS -H 'Accept: application/vnd.oci.image.index.v1+json' "$api/referrers/$d" | jq '.manifests | length')
    [ "$n" = 0 ] || die "$UPSTREAM@$d has $n OCI referrers (signatures or attestations?): verify them before mirroring"
    v=$(skopeo --override-os linux --override-arch amd64 inspect \
      --format '{{index .Labels "org.opencontainers.image.version"}}' "docker://$UPSTREAM@$d")
    [ "$v" = "$tag" ] || die "$f: mirror tag $tag does not match the image version $v"
    # --preserve-digests: same index and manifest bytes, so the digest pin still matches.
    skopeo copy -q --all --preserve-digests "docker://$UPSTREAM@$d" "docker://$MIRROR:$tag"
    skopeo inspect --raw "docker://$MIRROR@$d" > "$raw"
    echo "Copied $UPSTREAM@$d to $MIRROR:$tag"
  fi
  [ "sha256:$(sha256sum < "$raw" | cut -d' ' -f1)" = "$d" ] || die "$MIRROR@$d: index bytes do not match the digest"
  echo "ok $f: $MIRROR:$tag@$d (upstream $up)"
done
