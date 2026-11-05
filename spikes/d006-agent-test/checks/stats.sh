#!/bin/bash
n=$1; cd ~/agent-test/$n
echo builds: $(grep -c "^=== " build.log); grep "^=== " build.log | tr "\n" ";"; echo
echo errors:; grep -E "^error(\[E[0-9]+\])?:" build.log | sort | uniq -c
echo "diff +/-:"; diff -ru orig app | grep -E "^[+-][^+-]" | cut -c1 | sort | uniq -c
