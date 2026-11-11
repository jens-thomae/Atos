#!/usr/bin/env bash
# Run: bash tools/ci/test-perf-regression-body.sh  (stubbed gh; tables recorded from `budgets compare`)
set -eu
d=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir "$t/bin" "$t/regressed" "$t/none"
# The compare API answer after --jq: count, then "<sha12> <subject>". The second subject is hostile.
printf '#!/bin/sh\ncat "%s/compare"\n' "$t" > "$t/bin/gh"
cat > "$t/compare" << 'EOF'
2
aaaaaaaaaaaa T-1: fix (#5)
bbbbbbbbbbbb @owner <img src=x> [x](http://e) `rm -rf ~` $(id)
EOF
chmod +x "$t/bin/gh"
cat > "$t/regressed/budget-test-app.json.md" << 'EOF'
| Metric | Previous nightly | This run | Change | Result |
| --- | --- | --- | --- | --- |
| Cold start to first frame | 100.00 ms | 116.00 ms | +16.00 ms | ⚠️ worse by more than 5 % of budget |
| Idle RSS (5 s after first frame) | 50.00 MB | 10.00 MB | -40.00 MB | ok |
| Idle CPU | 0.10 % | 0.00 % | -0.10 % | ok |
EOF
export GITHUB_RUN_ID=200 GITHUB_SHA=cccccccccccccccccccccccccccccccccccccccc PREV_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=o/r REGRESSION_THRESHOLD_PERCENT=5
run() { PATH="$t/bin:$PATH" bash "$d/perf-regression-body.sh" "$@"; }
fail() { echo "FAIL: $1"; echo "$out"; exit 1; }

out=$(PREV_RUN=100 run "$t/regressed")
grep -qx '\*\*Regressed:\*\* Cold start to first frame' <<< "$out" || fail metric
grep -q 'previous nightly \[run 100\](https://github.com/o/r/actions/runs/100) (`aaaaaaaaaaaa`)' <<< "$out" || fail previous
grep -q 'this nightly \[run 200\](https://github.com/o/r/actions/runs/200)' <<< "$out" || fail current
grep -q '^\*\*Commits between them:\*\* 2 (\[compare\](https://github.com/o/r/compare/a\{40\}\.\.\.c\{40\}))' <<< "$out" || fail commits
grep -qx -- '- aaaaaaaaaaaa T-1: fix 5' <<< "$out" || fail subject
grep -qx -- '- bbbbbbbbbbbb owner img src=x xhttp:e rm -rf  id' <<< "$out" || fail "hostile subject"
grep -qx '| Cold start to first frame | 100.00 ms | 116.00 ms | +16.00 ms | ⚠️ worse by more than 5 % of budget |' <<< "$out" || fail table
grep -qx '#### `budget-test-app.json`' <<< "$out" || fail heading
# No regression (compare wrote no table), no previous nightly: nothing, so no issue is written.
[ -z "$(PREV_RUN=100 run "$t/none")" ] || fail "no regression"
[ -z "$(PREV_RUN='' run "$t/regressed")" ] || fail "no previous nightly"
# Hashes and ids are checked, not trusted.
PREV_RUN='1;x' run "$t/regressed" > /dev/null 2>&1 && fail "bad run id accepted"
PREV_SHA='$(x)' PREV_RUN=100 run "$t/regressed" > /dev/null 2>&1 && fail "bad hash accepted"
echo ok
