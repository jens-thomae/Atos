#!/usr/bin/env bash
# Weekly upstream check for atos-comp (C2, D-007): opens issues, never merges anything.
# Env: FORK_TAG overrides the fork point parsed from the C2 README (the tests set it); DRY_RUN=true prints instead of opening; UPSTREAM, SINCE_DAYS, FALLBACK_DAYS override defaults.
# Needs git, gh (GH_TOKEN with issues:write) and jq. Upstream is read anonymously (plain git clone).
set -euo pipefail
UPSTREAM=${UPSTREAM:-https://github.com/pop-os/cosmic-comp}
DRY_RUN=${DRY_RUN:-false}
SINCE_DAYS=${SINCE_DAYS:-8}        # weekly run + 1 day slack; duplicates are caught by the title check
FALLBACK_DAYS=${FALLBACK_DAYS:-90} # owner decision on #57: master merge after 3 months without a tag
KEYWORDS='security|CVE|overflow|use-after|unsound|crash'
root=$(cd "$(dirname "$0")/../.." && pwd)

fork=${FORK_TAG:-$(grep -oE '\| Tag \| `epoch-[0-9.]+`' "$root/docs/components/c2-compositor/README.md" \
  | grep -oE 'epoch-[0-9.]+' | head -n1 || true)}
[ -n "$fork" ] || { echo "no fork-point tag found in the C2 README" >&2; exit 1; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
git clone -q --bare --filter=blob:none "$UPSTREAM" "$work/up"
issues=$(gh issue list --state all --label c2-compositor --limit 1000 --json title,createdAt)

# open <title> <body> <dedup-window-days, 0 = any age>
open() {
  local cut=0
  [ "$3" -eq 0 ] || cut=$(( $(date +%s) - $3 * 86400 ))
  if [ -n "$(jq -r --arg t "$1" --argjson c "$cut" \
      '.[] | select(.title==$t and (.createdAt|fromdateiso8601) >= $c) | .title' <<<"$issues")" ]; then
    echo "exists: $1"; return
  fi
  if [ "$DRY_RUN" = true ]; then echo "would open: $1"; return; fi
  gh issue create --label c2-compositor --title "$1" --body "$2"
}

git="git -C $work/up"

# 1. Epoch tags newer than our fork point.
tags=$($git for-each-ref --format='%(refname:short)' 'refs/tags/epoch-*' | grep -E '^epoch-[0-9.]+$' | sort -V || true)
for t in $tags; do
  [ "$t" != "$fork" ] && [ "$(printf '%s\n%s\n' "$fork" "$t" | sort -V | tail -n1)" = "$t" ] || continue
  open "C2: merge $t" "Upstream tagged \`$t\` (<$UPSTREAM/releases/tag/$t>). Merge within two weeks of the tag: docs/components/c2-compositor/upstream.md. Opened by the upstream-watch workflow." 0
done

# 2. Newest tag older than FALLBACK_DAYS: one master merge per window.
newest=$(printf '%s\n' "$tags" | tail -n1)
if [ -n "$newest" ]; then
  age=$(( $(date +%s) - $($git for-each-ref --format='%(creatordate:unix)' "refs/tags/$newest") ))
  if [ "$age" -gt $(( FALLBACK_DAYS * 86400 )) ]; then
    open "C2: merge master (fallback)" "The newest Epoch tag (\`$newest\`) is older than $FALLBACK_DAYS days. Do one merge against upstream \`master\` to bound drift: docs/components/c2-compositor/upstream.md. Opened by the upstream-watch workflow." "$FALLBACK_DAYS"
  fi
fi

# 3. Recent master commits mentioning security keywords (false positives are expected: read, then close).
$git log --since="$SINCE_DAYS days ago" -i -E --grep="$KEYWORDS" --format='%H %s' HEAD | while read -r sha subject; do
  open "C2: cherry-pick upstream fix ${sha:0:8}" "Upstream commit <$UPSTREAM/commit/$sha> matched the security keywords (subject as code, so it pings nobody):

    $subject

Read it. If it is a reachable security fix, cherry-pick it (upstream.md, Security watch); otherwise close this card as not applicable. Opened by the upstream-watch workflow." 0
done
