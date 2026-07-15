#!/usr/bin/env bash
# E2E: wm-state outage-update, the persisted fleet-wide outage-state machine
# (issue #23, item 0). No tmux needed - pure wm_state calls plus direct file
# writes/reads against $WINGMAN_HOME/api-outage-state.json, same fixture/lib.sh
# conventions as tests/group-attention.test.sh (whose exact collapse thresholds
# this reuses).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

state_field() {
  uv run --no-project --quiet python -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get(sys.argv[2]))
' "$WINGMAN_HOME/api-outage-state.json" "$1"
}

# --- a fresh install has no state file: outage-update seeds one as clear -----
test_new_home
out="$(wm_state outage-update --owner "" --signal-working 0 --died "" \
  --mass-min-count 2 --mass-min-ratio 0.5 --quiet-seconds 15)"
assert_eq "no signal on a fresh install prints 'none'" "$out" "none"
assert_true "the state file is created" "[ -f '$WINGMAN_HOME/api-outage-state.json' ]"
assert_eq "the seeded state is clear" "$(state_field state)" "clear"

# --- below-threshold signal never flips clear -> active -----------------------
test_new_home
wm_state crew-add --id a1 --type developer --objective x --repo /tmp --window wm-a1 --session-id sa1 >/dev/null
wm_state crew-add --id a2 --type developer --objective y --repo /tmp --window wm-a2 --session-id sa2 >/dev/null
wm_state crew-add --id a3 --type developer --objective z --repo /tmp --window wm-a3 --session-id sa3 >/dev/null
wm_state crew-add --id a4 --type developer --objective w --repo /tmp --window wm-a4 --session-id sa4 >/dev/null
# 1 signal out of 4 live = ratio 0.25, below the 0.5 default - must stay clear.
out="$(wm_state outage-update --owner "" --signal-working 1 --died "" \
  --mass-min-count 2 --mass-min-ratio 0.5 --quiet-seconds 15)"
assert_eq "a below-ratio signal prints 'none'" "$out" "none"
assert_eq "state stays clear" "$(state_field state)" "clear"

# --- signal crossing BOTH mass-min-count and mass-min-ratio flips clear -> active
test_new_home
wm_state crew-add --id b1 --type developer --objective x --repo /tmp --window wm-b1 --session-id sb1 >/dev/null
wm_state crew-add --id b2 --type developer --objective y --repo /tmp --window wm-b2 --session-id sb2 >/dev/null
# 2 of 2 live = ratio 1.0, count 2 >= min-count 2 - must flip.
out="$(wm_state outage-update --owner "" --signal-working 2 --died "" \
  --mass-min-count 2 --mass-min-ratio 0.5 --quiet-seconds 15)"
assert_eq "a crossing signal prints 'outage-detected'" "$out" "outage-detected"
assert_eq "state flips to active" "$(state_field state)" "active"
assert_eq "signal_count is recorded" "$(state_field signal_count)" "2"

# --- a same-state refresh (still active, still signaling) never re-fires -----
out2="$(wm_state outage-update --owner "" --signal-working 2 --died "" \
  --mass-min-count 2 --mass-min-ratio 0.5 --quiet-seconds 15)"
assert_eq "a continued signal while already active prints 'none'" "$out2" "none"
assert_eq "state stays active" "$(state_field state)" "active"

# --- a died member with death_cause=api-outage contributes to the signal -----
test_new_home
wm_state crew-add --id c1 --type developer --objective x --repo /tmp --window wm-c1 --session-id sc1 >/dev/null
wm_state crew-add --id c2 --type developer --objective y --repo /tmp --window wm-c2 --session-id sc2 >/dev/null
wm_state crew-set --id c1 --status died >/dev/null
uv run --no-project --quiet python -c '
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for r in d:
    if r["id"] == "c1":
        r["death_cause"] = "api-outage"
json.dump(d, open(p, "w"))
' "$WINGMAN_HOME/crew.json"
# signal-working=1 (c2, say) + 1 outage-tagged death (c1) = signal 2.
# denominator = current_live (1, just c2) + died-this-poll (1, c1) = 2 -> ratio 1.0.
out="$(wm_state outage-update --owner "" --signal-working 1 --died "c1" \
  --mass-min-count 2 --mass-min-ratio 0.5 --quiet-seconds 15)"
assert_eq "an outage-tagged death contributes to the signal count" "$out" "outage-detected"

# A death with NO outage tag must not count toward the signal at all.
test_new_home
wm_state crew-add --id d1 --type developer --objective x --repo /tmp --window wm-d1 --session-id sd1 >/dev/null
wm_state crew-add --id d2 --type developer --objective y --repo /tmp --window wm-d2 --session-id sd2 >/dev/null
wm_state crew-set --id d1 --status died >/dev/null
out="$(wm_state outage-update --owner "" --signal-working 0 --died "d1" \
  --mass-min-count 2 --mass-min-ratio 0.5 --quiet-seconds 15)"
assert_eq "a plain (non-outage) death contributes nothing to the signal" "$out" "none"

# --- active -> clear after --quiet-seconds pass with zero fresh signal -------
test_new_home
wm_state crew-add --id e1 --type developer --objective x --repo /tmp --window wm-e1 --session-id se1 >/dev/null
wm_state crew-add --id e2 --type developer --objective y --repo /tmp --window wm-e2 --session-id se2 >/dev/null
wm_state outage-update --owner "" --signal-working 2 --died "" \
  --mass-min-count 2 --mass-min-ratio 0.5 --quiet-seconds 1 >/dev/null
assert_eq "state is active after the crossing signal" "$(state_field state)" "active"
sleep 2
out="$(wm_state outage-update --owner "" --signal-working 0 --died "" \
  --mass-min-count 2 --mass-min-ratio 0.5 --quiet-seconds 1)"
assert_eq "a quiet poll past --quiet-seconds prints 'outage-cleared'" "$out" "outage-cleared"
assert_eq "state flips back to clear" "$(state_field state)" "clear"

# --- a quiet poll BEFORE --quiet-seconds elapses stays active, no re-fire ----
test_new_home
wm_state crew-add --id f1 --type developer --objective x --repo /tmp --window wm-f1 --session-id sf1 >/dev/null
wm_state crew-add --id f2 --type developer --objective y --repo /tmp --window wm-f2 --session-id sf2 >/dev/null
wm_state outage-update --owner "" --signal-working 2 --died "" \
  --mass-min-count 2 --mass-min-ratio 0.5 --quiet-seconds 30 >/dev/null
out="$(wm_state outage-update --owner "" --signal-working 0 --died "" \
  --mass-min-count 2 --mass-min-ratio 0.5 --quiet-seconds 30)"
assert_eq "a quiet poll still within the window prints 'none'" "$out" "none"
assert_eq "state stays active" "$(state_field state)" "active"

# --- --owner scopes current_live to that owner's own team --------------------
# g3 (top-level) is live but must not count toward lead1's own denominator;
# scoped to lead1, only g1/g2 (its own workers) count, so the same 2-signal
# poll collapses under lead1's scope but is diluted under the top-level scope.
test_new_home
wm_state crew-add --id lead1 --type lead --objective L --repo /tmp --window wm-lead1 --session-id sld1 >/dev/null
wm_state crew-add --id g1 --type developer --objective a --repo /tmp --window wm-g1 --session-id sg1 --parent lead1 >/dev/null
wm_state crew-add --id g2 --type developer --objective b --repo /tmp --window wm-g2 --session-id sg2 --parent lead1 >/dev/null
for n in 1 2 3 4 5; do
  wm_state crew-add --id "top$n" --type developer --objective x --repo /tmp --window "wm-top$n" --session-id "st$n" >/dev/null
done
out_scoped="$(wm_state outage-update --owner "lead1" --signal-working 2 --died "" \
  --mass-min-count 2 --mass-min-ratio 0.5 --quiet-seconds 15)"
assert_eq "lead1-scoped denominator collapses its own 2-of-2 signal" "$out_scoped" "outage-detected"

test_summary
