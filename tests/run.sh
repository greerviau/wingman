#!/usr/bin/env bash
# Run every tests/*.test.sh and roll up the result. bash-3.2-safe.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
fails=0
for t in "$HERE"/*.test.sh; do
  [ -f "$t" ] || continue
  printf '\n=== %s ===\n' "$(basename "$t")"
  bash "$t" || fails=$((fails+1))
done
printf '\n============================\n'
if [ "$fails" -eq 0 ]; then printf 'ALL SUITES PASSED\n'; else printf '%d SUITE(S) FAILED\n' "$fails"; fi
exit "$fails"
