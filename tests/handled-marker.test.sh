#!/usr/bin/env bash
# E2E: the handled-marker wake-handling model (Fix A / #8). Proves the two-store
# ack/handled split lets a surfaced-but-unhandled event re-block instead of being
# permanently suppressed by a premature ack, without reintroducing the re-fire race
# the fire-time ack exists to prevent; that the Stop hook marks handled EXACTLY the
# per-turn scratch set (so a mid-turn new transition is never dropped); that
# needs-attention's suppress-on selector and --only-acked enumerate the right sets;
# and that the shared stores are flock-serialized so concurrent writers lose no key.
# No real crew/tmux/claude needed.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

STOP_GUARD="$TEST_REPO/hooks/stop-guard.sh"

_py() { uv run --no-project --quiet python "$@"; }
updated_of() { wm_state crew-get --id "$1" | _py -c 'import json,sys; print(json.load(sys.stdin)["updated"])'; }
store_val() { _py -c 'import json,os,sys
p=sys.argv[1]
print(json.load(open(p)).get(sys.argv[2],"") if os.path.exists(p) else "")' "$WINGMAN_HOME/$1" "$2"; }
count_keys() { _py -c 'import json,os,sys
p=sys.argv[1]
print(len(json.load(open(p))) if os.path.exists(p) else 0)' "$WINGMAN_HOME/$1"; }

# --- the core race-free property + the two-pass path --------------------------
# An event first seen by the Stop hook (no watcher ran): pass 1 writes the scratch
# set, acks it, and blocks - but does NOT mark it handled; the acked event is
# suppressed from the watcher re-fire yet still visible to the hook, so it re-blocks
# until pass 2 (stop_hook_active) marks exactly the scratch tuple handled.
test_new_home
wm_state crew-add --id m1 --type developer --objective x --repo /tmp --window wm-m1 --session-id s1 >/dev/null
wm_state crew-set --id m1 --status review --delivery "PR#1" >/dev/null

p1="$(printf '{"stop_hook_active": false}' | bash "$STOP_GUARD")"
assert_contains "pass 1 blocks on the surfaced event" "$p1" '"decision": "block"'
assert_contains "pass 1 demands the roster report" "$p1" "compact roster status"
assert_true  "pass 1 wrote the per-turn scratch set" "test -f '$WINGMAN_HOME/stop-blocked.json'"
assert_true  "pass 1 acked m1" "grep -q m1 '$WINGMAN_HOME/acked.json'"
assert_false "pass 1 did NOT mark m1 handled" "test -f '$WINGMAN_HOME/handled.json' && grep -q m1 '$WINGMAN_HOME/handled.json'"

# The watcher gate (default suppress-on ack) must NOT re-fire the acked event -
# this is the re-fire race the fire-time ack closes, retained here.
assert_eq "an acked event is suppressed from the watcher re-fire" "$(wm_state needs-attention --owner '' --suppress-on ack)" ""
# The Stop-hook gate (suppress-on handled) still SEES it - acked but not handled.
assert_contains "an acked-but-unhandled event stays visible to the hook" "$(wm_state needs-attention --owner '' --suppress-on handled)" "m1"

# A fresh pass with handling still not completed re-blocks (the #8 fix).
pRB="$(printf '{"stop_hook_active": false}' | bash "$STOP_GUARD")"
assert_contains "an unhandled event re-blocks on the next pass" "$pRB" '"decision": "block"'

# Pass 2 (stop_hook_active): mark exactly the scratch tuple handled, delete the
# scratch, allow the stop.
p2="$(printf '{"stop_hook_active": true}' | bash "$STOP_GUARD")"
assert_eq   "pass 2 allows the stop" "$p2" ""
assert_true "pass 2 marked m1 handled" "grep -q m1 '$WINGMAN_HOME/handled.json'"
assert_false "pass 2 deleted the scratch" "test -f '$WINGMAN_HOME/stop-blocked.json'"
assert_eq   "a handled event is quiet to the hook gate" "$(wm_state needs-attention --owner '' --suppress-on handled)" ""

# --- B2: the mid-turn drop is prevented (mark handled the scratch set, not the
# stores) --------------------------------------------------------------------
# An event is blocked in pass 1, then a NEW transition on the SAME member (new
# updated) appears before pass 2. Pass 2 must mark handled ONLY the old tuple; the
# new (id, updated) is a distinct key that is neither acked nor handled and must
# re-surface, not be dropped.
test_new_home
wm_state crew-add --id b1 --type developer --objective y --repo /tmp --window wm-b1 --session-id s2 >/dev/null
wm_state crew-set --id b1 --status review --delivery "PR#2" >/dev/null
u1="$(updated_of b1)"

printf '{"stop_hook_active": false}' | bash "$STOP_GUARD" >/dev/null   # pass 1 captures (b1, u1)
# The scratch is TSV "id<TAB>updated"; confirm it captured b1 at its pass-1 updated.
assert_eq "the scratch captured b1 at its pass-1 updated" "$(awk -F'\t' '$1=="b1"{print $2}' "$WINGMAN_HOME/stop-blocked.json")" "$u1"

# Mid-turn: b1 transitions review -> blocked, minting a new updated u2.
wm_state crew-set --id b1 --status blocked --blocker "need a decision" >/dev/null
u2="$(updated_of b1)"
assert_false "the mid-turn transition minted a new updated" "[ '$u1' = '$u2' ]"

# Pass 2 marks ONLY the old tuple handled.
printf '{"stop_hook_active": true}' | bash "$STOP_GUARD" >/dev/null
assert_eq "pass 2 marked only the OLD tuple (u1) handled" "$(store_val handled.json b1)" "$u1"

# The new (b1, u2) is neither handled nor acked-at-u2 → it re-surfaces (not dropped)
# to both gates, and re-blocks on the next turn.
assert_contains "the mid-turn new transition re-surfaces to the hook gate" "$(wm_state needs-attention --owner '' --suppress-on handled)" "b1"
assert_contains "the mid-turn new transition re-surfaces to the watcher gate" "$(wm_state needs-attention --owner '' --suppress-on ack)" "b1"
p3="$(printf '{"stop_hook_active": false}' | bash "$STOP_GUARD")"
assert_contains "the mid-turn new transition re-blocks the stop" "$p3" '"decision": "block"'

# --- a genuine state change (new updated) is neither acked nor handled ---------
test_new_home
wm_state crew-add --id c1 --type analyst --objective z --repo /tmp --window wm-c1 --session-id s3 >/dev/null
wm_state crew-set --id c1 --status done --summary "done z" >/dev/null
printf '{"stop_hook_active": false}' | bash "$STOP_GUARD" >/dev/null   # ack + block
printf '{"stop_hook_active": true}'  | bash "$STOP_GUARD" >/dev/null   # mark handled
assert_eq "c1 is quiet once fully handled" "$(wm_state needs-attention --owner '' --suppress-on handled)" ""
wm_state crew-set --id c1 --status done --summary "done z again" >/dev/null   # new updated
assert_contains "a new updated re-surfaces to the hook gate" "$(wm_state needs-attention --owner '' --suppress-on handled)" "c1"
assert_contains "a new updated re-surfaces to the watcher gate" "$(wm_state needs-attention --owner '' --suppress-on ack)" "c1"
p4="$(printf '{"stop_hook_active": false}' | bash "$STOP_GUARD")"
assert_contains "a new updated re-blocks the stop" "$p4" '"decision": "block"'

# --- needs-attention --suppress-on handled --only-acked = acked ∩ unhandled ----
test_new_home
wm_state crew-add --id g1 --type developer --objective a --repo /tmp --window wm-g1 --session-id s4 >/dev/null
wm_state crew-add --id g2 --type developer --objective b --repo /tmp --window wm-g2 --session-id s5 >/dev/null
wm_state crew-add --id g3 --type developer --objective c --repo /tmp --window wm-g3 --session-id s6 >/dev/null
wm_state crew-set --id g1 --status done --summary "d1" >/dev/null
wm_state crew-set --id g2 --status done --summary "d2" >/dev/null
wm_state crew-set --id g3 --status done --summary "d3" >/dev/null
for id in g1 g2 g3; do wm_state ack --id "$id" --updated "$(updated_of "$id")" >/dev/null; done
# g1 is also handled → excluded; g3 gets a new updated so its ack is now stale
# (not "currently acked") → excluded by --only-acked; g2 stays acked ∩ unhandled.
wm_state mark-handled --id g1 --updated "$(updated_of g1)" >/dev/null
wm_state crew-set --id g3 --status done --summary "d3 changed" >/dev/null
only="$(wm_state needs-attention --owner '' --suppress-on handled --only-acked)"
assert_contains "acked∩unhandled includes g2" "$only" "g2"
assert_false "acked∩unhandled excludes the handled g1" "printf '%s' \"\$only\" | grep -q g1"
assert_false "acked∩unhandled excludes the not-currently-acked g3" "printf '%s' \"\$only\" | grep -q g3"

# --- concurrency (B2): flock keeps concurrent store writers from losing keys ----
# A watcher fire() and the Stop-hook chain run in separate processes and both mutate
# acked.json; the hook also mutates handled.json. A read-modify-write of the whole
# dict from two processes is last-writer-wins without a lock. Launch many concurrent
# `ack` (fire-style) and `mark-handled` (hook-style) writers with distinct keys and
# assert every key survives - the flock critical section (with_locked) must hold.
test_new_home
N=40
pids=""
i=0
while [ "$i" -lt "$N" ]; do
  wm_state ack          --id "k$i" --updated "u$i" >/dev/null 2>&1 &
  pids="$pids $!"
  wm_state mark-handled --id "h$i" --updated "v$i" >/dev/null 2>&1 &
  pids="$pids $!"
  i=$((i+1))
done
for p in $pids; do wait "$p" 2>/dev/null; done
assert_eq "no acked key lost under concurrent writers"   "$(count_keys acked.json)"   "$N"
assert_eq "no handled key lost under concurrent writers" "$(count_keys handled.json)" "$N"

test_summary
