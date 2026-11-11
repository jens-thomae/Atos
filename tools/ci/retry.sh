#!/usr/bin/env bash
# Runs a command again after a failure, for network steps on CI runners (#246).
#   tools/ci/retry.sh <command> [args...]
# RETRY_ATTEMPTS (default 3) tries in all; RETRY_DELAY (default 15) seconds before the second try, doubling after.
# Exits with the last try's status, so a real error still fails. Never wrap a step that publishes, signs or tags.
# Test: tools/ci/test-retry.sh
set -u
n=${RETRY_ATTEMPTS:-3} delay=${RETRY_DELAY:-15} i=1
while :; do
  "$@" && exit 0
  rc=$?
  [ "$i" -ge "$n" ] && { echo "::error::failed $n times (exit $rc): $*" >&2; exit "$rc"; }
  echo "::warning::try $i of $n failed (exit $rc), again in ${delay}s: $*" >&2
  sleep "$delay"
  i=$((i + 1)) delay=$((delay * 2))
done
