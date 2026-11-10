#!/usr/bin/env bash
# Run: bash tools/ci/test-nightly-issue.sh  (stubbed gh, DRY_RUN)
set -eu
d=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir "$t/bin"; printf '#!/bin/sh\ncat "$STUB_ISSUES"\n' > "$t/bin/gh"; chmod +x "$t/bin/gh"
# A look-alike title must not count as the tracking issue.
printf '[{"number":7,"title":"Nightly image build failed twice"}]' > "$t/none"
printf '[{"number":3,"title":"Other"},{"number":9,"title":"Nightly image build failed"}]' > "$t/open"
run() { STUB_ISSUES=$t/$1 PATH="$t/bin:$PATH" DRY_RUN=true bash "$d/nightly-issue.sh" "$2" https://run/1; }
run none failure | grep -q '^gh issue create --title Nightly image build failed --body .*https://run/1' || { echo "FAIL open"; exit 1; }
[ "$(run open failure)" = 'gh issue comment 9 --body Failed again: https://run/1' ] || { echo "FAIL comment"; exit 1; }
[ "$(run open success)" = 'gh issue close 9 --comment Green again: https://run/1' ] || { echo "FAIL close"; exit 1; }
[ -z "$(run none success)" ] || { echo "FAIL success without issue"; exit 1; }
run open cancelled 2> /dev/null && { echo "FAIL: cancelled accepted"; exit 1; }
echo ok
