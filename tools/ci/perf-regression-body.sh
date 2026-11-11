#!/usr/bin/env bash
# Text of the perf regression issue (perf.yml `compare`, docs/ci.md), on stdout; nothing when nothing regressed.
# Usage: perf-regression-body.sh <dir>
#   <dir>: the `budgets compare` tables of the results files that regressed (exit 1), one <results>.md each.
#   No such table, or no previous nightly (empty PREV_RUN), prints nothing.
# Env: PREV_RUN, PREV_SHA (previous nightly), GITHUB_RUN_ID, GITHUB_SHA (this one), GITHUB_SERVER_URL,
#   GITHUB_REPOSITORY, REGRESSION_THRESHOLD_PERCENT. Needs gh (GH_TOKEN with contents: read) for the commits.
# Test: tools/ci/test-perf-regression-body.sh
set -euo pipefail
dir=${1:?usage: $0 <dir>}
shopt -s nullglob
tables=("$dir"/*.md)
[ -n "${PREV_RUN:-}" ] && [ ${#tables[@]} -gt 0 ] || exit 0
# Everything below lands in an issue: ids and hashes must be what they claim, commit subjects (merged pull request
# titles) keep only plain characters, tables lose Markdown and HTML specials (they hold only numbers and our metric names).
[[ $PREV_RUN =~ ^[0-9]+$ && $GITHUB_RUN_ID =~ ^[0-9]+$ ]] || { echo "bad run id" >&2; exit 1; }
[[ $PREV_SHA =~ ^[0-9a-f]{40}$ && $GITHUB_SHA =~ ^[0-9a-f]{40}$ ]] || { echo "bad commit hash" >&2; exit 1; }
plain() { tr -d '@<>[]`!#*_~\\&'; }  # no `[`, so a `(` cannot start a link target
repo=$GITHUB_SERVER_URL/$GITHUB_REPOSITORY
metrics=$(cat "${tables[@]}" | grep '⚠️' | cut -d'|' -f2 | sed 's/^ *//; s/ *$//' | sort -u | plain | paste -sd, - | sed 's/,/, /g')
commits=$(gh api "repos/$GITHUB_REPOSITORY/compare/$PREV_SHA...$GITHUB_SHA" \
  --jq '.total_commits, (.commits[] | .sha[0:12] + " " + (.commit.message | split("\n")[0]))')
total=$(head -1 <<< "$commits")
[[ $total =~ ^[0-9]+$ ]] || { echo "bad commit count" >&2; exit 1; }
echo "**Regressed:** $metrics"
echo
echo "**Runs compared:** previous nightly [run $PREV_RUN]($repo/actions/runs/$PREV_RUN) (\`${PREV_SHA:0:12}\`)," \
  "this nightly [run $GITHUB_RUN_ID]($repo/actions/runs/$GITHUB_RUN_ID) (\`${GITHUB_SHA:0:12}\`)."
echo
echo "**Commits between them:** $total ([compare]($repo/compare/$PREV_SHA...$GITHUB_SHA))"
echo
# ponytail: the compare API lists at most 250 commits; the compare link has them all.
tail -n +2 <<< "$commits" | while read -r sha subject; do
  [[ $sha =~ ^[0-9a-f]{12}$ ]] || continue
  echo "- $sha $(printf '%s' "$subject" | tr -cd 'A-Za-z0-9 .,:;+=%-' | cut -c1-100)"
done
echo
echo "Threshold: $REGRESSION_THRESHOLD_PERCENT % of each budget (\`REGRESSION_THRESHOLD_PERCENT\` in \`perf.yml\`)."
for t in "${tables[@]}"; do
  echo
  echo "#### \`$(basename "$t" .md | tr -cd 'A-Za-z0-9._-')\`"
  echo
  plain < "$t"
done
echo
echo "A nightly that regresses again comments here. This issue does not close itself: a later nightly without" \
  "regression only means nothing got worse since the night before. The planner files the card and closes this" \
  "issue (docs/planner.md)."
