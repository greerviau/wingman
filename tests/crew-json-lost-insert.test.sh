#!/usr/bin/env bash
# E2E: issue #93 - crew-add's roster read-modify-write (load_roster -> append ->
# write_json(crew.json)) was not atomic as a unit, and neither were the identical
# load-mutate-write cycles in crew-set/reconcile/standdown/prune/stall-check. If any
# of those five reads the roster a moment before a concurrent crew-add appends and
# writes, and writes back after, that write-back silently drops the just-appended
# member - a live crew/<id>.json status file with no backing roster record at all,
# invisible to crew-list/the watcher/crew-standdown, and (unlike crew-set's own
# staleness on an EXISTING record) this loss never self-heals.
# Proves: N concurrent crew-add calls (new ids) racing M concurrent crew-set calls
# (against pre-seeded existing ids) plus concurrent reconcile calls never lose a
# newly-added roster record - every crew-add'd id is present in crew.json after the
# race settles.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

test_new_home

# Pre-seed M existing members that the concurrent crew-set calls will target -
# these already exist before the race starts, so their crew-set calls are pure
# roster read-modify-writes contending with the concurrent crew-add appends.
M=5
i=0
while [ "$i" -lt "$M" ]; do
  wm_state crew-add --id "s$i" --type developer --objective "seed$i" \
    --repo /tmp --window "wm-s$i" --session-id "seed-sess$i" >/dev/null
  i=$((i+1))
done

# N new ids that crew-add will insert concurrently with the M crew-set calls and a
# few reconcile calls - the issue's own measured ratio (10 adds vs. 5 sets), for
# headroom against the reported loss.
N=10

pids=""
errlogs=""

i=0
while [ "$i" -lt "$N" ]; do
  errlog="$WINGMAN_HOME/add-$i.err"
  rclog="$WINGMAN_HOME/add-$i.rc"
  errlogs="$errlogs $errlog:$rclog"
  ( wm_state crew-add --id "n$i" --type developer --objective "new$i" \
      --repo /tmp --window "wm-n$i" --session-id "new-sess$i" >/dev/null 2>"$errlog"
    echo $? >"$rclog" ) &
  pids="$pids $!"
  i=$((i+1))
done

i=0
while [ "$i" -lt "$M" ]; do
  errlog="$WINGMAN_HOME/set-$i.err"
  rclog="$WINGMAN_HOME/set-$i.rc"
  errlogs="$errlogs $errlog:$rclog"
  ( wm_state crew-set --id "s$i" --status working --summary "racing$i" >/dev/null 2>"$errlog"
    echo $? >"$rclog" ) &
  pids="$pids $!"
  i=$((i+1))
done

j=0
while [ "$j" -lt 3 ]; do
  errlog="$WINGMAN_HOME/reconcile-$j.err"
  rclog="$WINGMAN_HOME/reconcile-$j.rc"
  errlogs="$errlogs $errlog:$rclog"
  windows="$(k=0; while [ "$k" -lt "$M" ]; do printf 'wm-s%s,' "$k"; k=$((k+1)); done
             k=0; while [ "$k" -lt "$N" ]; do printf 'wm-n%s,' "$k"; k=$((k+1)); done)"
  ( wm_state reconcile --windows "${windows%,}" --owner "" >/dev/null 2>"$errlog"
    echo $? >"$rclog" ) &
  pids="$pids $!"
  j=$((j+1))
done

for p in $pids; do wait "$p" 2>/dev/null; done

# Every child exited 0 with empty stderr - no traceback, no silent failure.
for pair in $errlogs; do
  errlog="${pair%%:*}"; rclog="${pair##*:}"
  assert_eq "$(basename "$errlog") is empty (no traceback)" "$(cat "$errlog")" ""
  assert_eq "$(basename "$rclog") exited 0" "$(cat "$rclog")" "0"
done

# crew.json still parses as valid JSON after the race.
assert_true "crew.json parses as valid JSON after the race" \
  "uv run --no-project --quiet python3 -c \"import json; json.load(open('$WINGMAN_HOME/crew.json'))\""

# The direct regression assertion: every crew-add'd id (n0..n$((N-1))) is present in
# the roster, alongside the M pre-seeded ids - nothing dropped by a concurrent
# crew-set/reconcile write-back racing the inserts.
missing=""
i=0
while [ "$i" -lt "$N" ]; do
  if ! wm_state crew-get --id "n$i" >/dev/null 2>&1; then
    missing="$missing n$i"
  fi
  i=$((i+1))
done
assert_eq "no concurrently-added member is missing from the roster" "$missing" ""

count="$(wm_state crew-list --owner '' --json | grep -c '"id"')"
assert_eq "roster has all $((M+N)) members (M pre-seeded + N concurrently added)" "$count" "$((M+N))"

test_summary
