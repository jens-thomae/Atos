#!/usr/bin/env bash
# Tracking issue for the nightly image build (c1-base.yml `nightly-report`, docs/ci.md).
# Usage: nightly-issue.sh success|failure <run-url>
#   failure: comment on the open "Nightly image build failed" issue, or open it.
#   success: close that issue, if one is open.
# Needs gh (GH_TOKEN with issues: write, GH_REPO) and jq. DRY_RUN=true prints the writes instead.
# Test: tools/ci/test-nightly-issue.sh
set -euo pipefail
TITLE="Nightly image build failed"
result=${1:-} url=${2:-}
case "$result" in success|failure) ;; *) echo "usage: $0 success|failure <run-url>" >&2; exit 2 ;; esac
[ -n "$url" ] || { echo "usage: $0 success|failure <run-url>" >&2; exit 2; }
w() { if [ "${DRY_RUN:-false}" = true ]; then echo "$*"; else "$@"; fi; }
n=$(gh issue list --state open --limit 500 --json number,title | jq -r --arg t "$TITLE" 'map(select(.title == $t))[0].number // empty')
if [ "$result" = failure ]; then
  if [ -n "$n" ]; then
    w gh issue comment "$n" --body "Failed again: $url"
  else
    w gh issue create --title "$TITLE" --body "The nightly build and boot test of \`main\` failed: $url

This issue gets a comment on every further failure and closes itself on the next green nightly run (docs/ci.md)."
  fi
elif [ -n "$n" ]; then
  w gh issue close "$n" --comment "Green again: $url"
fi
