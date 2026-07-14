#!/usr/bin/env bash
# E2E: issue #80 - write_json's shared "<path>.tmp" temp filename raced when two
# concurrent writers targeted the same JSON file (crew.json under many concurrent
# crew-set/reconcile calls), so the losing writer's os.replace hit FileNotFoundError
# and crashed - or, worse, both writers landed a torn write at the destination.
# Proves: many concurrent writers to the SAME shared file never crash, never exit
# non-zero, and never lose a write, by driving wm-state the same way a busy fleet
# does - through crew-add/crew-set/reconcile, not by calling write_json directly.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

test_new_home
N=30
i=0
while [ "$i" -lt "$N" ]; do
  wm_state crew-add --id "r$i" --type developer --objective "o$i" \
    --repo /tmp --window "wm-r$i" --session-id "s$i" >/dev/null
  i=$((i+1))
done

# Fire N concurrent crew-set calls (one per member, so each mutates a distinct
# crew/<id>.json but all of them also read-modify-write the SHARED crew.json),
# plus several concurrent reconcile calls (bin/crew-list's own path) racing
# against all of them - the exact shape reported live in issue #80. Each child
# records its own exit code alongside its stderr, so a silent non-zero exit
# can't slip past a check that only greps stderr for the one known traceback.
pids=""
errlogs=""
i=0
while [ "$i" -lt "$N" ]; do
  errlog="$WINGMAN_HOME/set-$i.err"
  rclog="$WINGMAN_HOME/set-$i.rc"
  errlogs="$errlogs $errlog:$rclog"
  ( wm_state crew-set --id "r$i" --status working --summary "s$i" >/dev/null 2>"$errlog"
    echo $? >"$rclog" ) &
  pids="$pids $!"
  i=$((i+1))
done
j=0
while [ "$j" -lt 6 ]; do
  errlog="$WINGMAN_HOME/reconcile-$j.err"
  rclog="$WINGMAN_HOME/reconcile-$j.rc"
  errlogs="$errlogs $errlog:$rclog"
  windows="$(i=0; while [ "$i" -lt "$N" ]; do printf 'wm-r%s,' "$i"; i=$((i+1)); done)"
  ( wm_state reconcile --windows "${windows%,}" --owner "" >/dev/null 2>"$errlog"
    echo $? >"$rclog" ) &
  pids="$pids $!"
  j=$((j+1))
done
for p in $pids; do wait "$p" 2>/dev/null; done

# No writer crashed with the reported traceback, and every writer exited 0.
for pair in $errlogs; do
  errlog="${pair%%:*}"; rclog="${pair##*:}"
  assert_false "no FileNotFoundError from $(basename "$errlog")" "grep -q FileNotFoundError '$errlog'"
  assert_eq "$(basename "$errlog") is empty (no traceback)" "$(cat "$errlog")" ""
  assert_eq "$(basename "$rclog") exited 0" "$(cat "$rclog")" "0"
done

# crew.json is valid JSON and still has all N members - the JSON view, not the
# human-readable render (render_roster_text indents every line with leading
# spaces before the bracketed type, so no line starts with the bare id).
assert_true "crew.json parses as valid JSON after the race" \
  "uv run --no-project --quiet python3 -c \"import json; json.load(open('$WINGMAN_HOME/crew.json'))\""
count="$(wm_state crew-list --owner '' --json | grep -c '"id"')"
assert_eq "all $N members are still present in the roster" "$count" "$N"

# No leaked mkstemp temp file survives a clean run (guards the tradeoff noted in
# "Fix approach" - a killed writer can leak one, but a normal exit must not).
leaked="$(find "$WINGMAN_HOME" -name '*.tmp.*' 2>/dev/null)"
assert_eq "no *.tmp.* files survive the race" "$leaked" ""

test_summary
