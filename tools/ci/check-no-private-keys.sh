#!/usr/bin/env bash
# Fails if any file at HEAD of the current git repo holds a private key block, except the TEST db key (D-014: public).
# The pattern is written so this file does not match itself ([-]{5} is not five dashes in the source).
set -u
leaked=$(git grep -lE 'PRIVATE KEY[-]{5}' HEAD -- . ':!components/c1-base/secureboot-test/db.key' || true)
[ -z "$leaked" ] || { echo "::error::private key material in the source tree: $leaked"; exit 1; }
