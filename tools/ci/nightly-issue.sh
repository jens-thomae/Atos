#!/usr/bin/env bash
# Tracking issue for a nightly run (docs/ci.md): the image build (c1-base.yml `nightly-report`) and,
# with TITLE and BODY_FILE, perf regressions (perf.yml `regression-report`, failure only).
# Usage: nightly-issue.sh success|failure <run-url>
#   failure: comment on the open issue titled $TITLE that github-actions[bot] opened, or open one.
#   success: close that issue, if one is open.
# TITLE defaults to "Nightly image build failed". BODY_FILE, if set, is the text of the new issue or comment.
# Needs gh (GH_TOKEN with issues: write, GH_REPO) and jq. DRY_RUN=true prints the writes instead.
# Test: tools/ci/test-nightly-issue.sh
set -euo pipefail
TITLE=${TITLE:-Nightly image build failed}
result=${1:-} url=${2:-}
case "$result" in success|failure) ;; *) echo "usage: $0 success|failure <run-url>" >&2; exit 2 ;; esac
[ -n "$url" ] || { echo "usage: $0 success|failure <run-url>" >&2; exit 2; }
w() { if [ "${DRY_RUN:-false}" = true ]; then echo "$*"; else "$@"; fi; }
# Only an issue this repository's workflows opened (github-actions[bot]): the repo is public, so anyone can open one
# with the same title. A token from another repository cannot open issues here. (`gh issue list --author app/...`
# mangles the login, so the author is checked in jq.)
n=$(gh issue list --state open --limit 500 --json number,title,author |
  jq -r --arg t "$TITLE" 'map(select(.title == $t and .author.login == "app/github-actions" and .author.is_bot))[0].number // empty')
if [ "$result" = failure ]; then
  if [ -n "${BODY_FILE:-}" ]; then
    if [ -n "$n" ]; then w gh issue comment "$n" --body-file "$BODY_FILE"; else w gh issue create --title "$TITLE" --body-file "$BODY_FILE"; fi
  elif [ -n "$n" ]; then
    w gh issue comment "$n" --body "Failed again: $url"
  else
    w gh issue create --title "$TITLE" --body "The nightly build and boot test of \`main\` failed: $url

This issue gets a comment on every further failure and closes itself on the next green nightly run (docs/ci.md)."
  fi
elif [ -n "$n" ]; then
  w gh issue close "$n" --comment "Green again: $url"
fi
