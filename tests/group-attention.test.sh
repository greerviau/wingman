#!/usr/bin/env bash
# E2E: wm-state group-attention, the pure display filter that collapses a
# fleet-wide correlated batch (mass death, correlated API outage) into one
# synthetic row. No tmux needed - it reads a TSV from stdin and the live roster
# from wm-state's own state home, exactly as bin/watch-fleet's fire() calls it.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# --- a single died row passes through unchanged (below --mass-min-count) -----
test_new_home
wm_state crew-add --id a1 --type developer --objective x --repo /tmp --window wm-a1 --session-id sa1 >/dev/null
wm_state crew-add --id a2 --type developer --objective y --repo /tmp --window wm-a2 --session-id sa2 >/dev/null
wm_state crew-set --id a1 --status died >/dev/null
input="$(printf 'a1\tdied\tX\tsome note')"
out="$(printf '%s\n' "$input" | wm_state group-attention --owner "")"
assert_eq "a single died row passes through byte-identical" "$out" "$input"

# --- N >= min-count, N/total >= min-ratio died rows collapse -----------------
# b1, b2 die; b3 (working) and c1 (blocked) stay live. Denominator = 2 (still
# live) + 2 (died in this batch) = 4; ratio = 2/4 = 0.5, exactly at the default
# threshold, so this must collapse.
test_new_home
wm_state crew-add --id b1 --type developer --objective a --repo /tmp --window wm-b1 --session-id sb1 >/dev/null
wm_state crew-add --id b2 --type developer --objective b --repo /tmp --window wm-b2 --session-id sb2 >/dev/null
wm_state crew-add --id b3 --type developer --objective c --repo /tmp --window wm-b3 --session-id sb3 >/dev/null
wm_state crew-add --id c1 --type developer --objective d --repo /tmp --window wm-c1 --session-id sc1 >/dev/null
wm_state crew-set --id b1 --status died >/dev/null
wm_state crew-set --id b2 --status died >/dev/null
wm_state crew-set --id c1 --status blocked --blocker "need a decision" >/dev/null
input="$(printf 'b1\tdied\tX\t\nb2\tdied\tX\t\nc1\tblocked\tX\tneed a decision')"
out="$(printf '%s\n' "$input" | wm_state group-attention --owner "")"
assert_contains "an at-threshold death batch collapses" "$out" "correlated:mass-death"
assert_contains "the collapsed row names b1" "$out" "b1"
assert_contains "the collapsed row names b2" "$out" "b2"
assert_false "b1 no longer appears as its own row" "printf '%s\n' \"$out\" | grep -q '^b1	'"
assert_false "b2 no longer appears as its own row" "printf '%s\n' \"$out\" | grep -q '^b2	'"
assert_contains "an unrelated status in the same batch is untouched" "$out" "c1	blocked	X	need a decision"

# --- below-ratio death batch stays ungrouped despite count >= min-count ------
test_new_home
wm_state crew-add --id f1 --type developer --objective a --repo /tmp --window wm-f1 --session-id sf1 >/dev/null
wm_state crew-add --id f2 --type developer --objective b --repo /tmp --window wm-f2 --session-id sf2 >/dev/null
for n in 1 2 3 4 5 6 7 8; do
  wm_state crew-add --id "fl$n" --type developer --objective c --repo /tmp --window "wm-fl$n" --session-id "sfl$n" >/dev/null
done
wm_state crew-set --id f1 --status died >/dev/null
wm_state crew-set --id f2 --status died >/dev/null
input="$(printf 'f1\tdied\tX\t\nf2\tdied\tX\t')"
out="$(printf '%s\n' "$input" | wm_state group-attention --owner "")"
assert_false "a below-ratio batch is never collapsed" "printf '%s\n' \"$out\" | grep -q correlated:mass-death"
assert_contains "f1 stays an individual row" "$out" "f1"
assert_contains "f2 stays an individual row" "$out" "f2"

# --- stalled rows with an api-error: note collapse; a plain stall never does -
# s1, s2 are stalled with an api-error: note; s3 is stalled with a plain reason
# and must never be swept in even though it shares the same status. s4 (working)
# is the only non-stalled live member. Denominator = current live count (all of
# s1..s4, since `stalled` is still LIVE_STATES) = 4; ratio = 2/4 = 0.5.
test_new_home
wm_state crew-add --id s1 --type developer --objective a --repo /tmp --window wm-s1 --session-id ss1 >/dev/null
wm_state crew-add --id s2 --type developer --objective b --repo /tmp --window wm-s2 --session-id ss2 >/dev/null
wm_state crew-add --id s3 --type developer --objective c --repo /tmp --window wm-s3 --session-id ss3 >/dev/null
wm_state crew-add --id s4 --type developer --objective d --repo /tmp --window wm-s4 --session-id ss4 >/dev/null
wm_state crew-set --id s1 --status stalled --summary "api-error: rate limit, retrying" >/dev/null
wm_state crew-set --id s2 --status stalled --summary "api-error: connection reset" >/dev/null
wm_state crew-set --id s3 --status stalled --summary "no pane output, status update, running child process, or CPU activity" >/dev/null
input="$(printf 's1\tstalled\tX\tapi-error: rate limit, retrying\ns2\tstalled\tX\tapi-error: connection reset\ns3\tstalled\tX\tno pane output, status update, running child process, or CPU activity')"
out="$(printf '%s\n' "$input" | wm_state group-attention --owner "")"
assert_contains "an at-threshold API-error batch collapses" "$out" "correlated:api-outage"
assert_contains "the collapsed row names s1" "$out" "s1"
assert_contains "the collapsed row names s2" "$out" "s2"
assert_false "s1 no longer appears as its own row" "printf '%s\n' \"$out\" | grep -q '^s1	'"
assert_false "s2 no longer appears as its own row" "printf '%s\n' \"$out\" | grep -q '^s2	'"
assert_contains "a plain (non-api-error) stall is never swept into the group" "$out" "s3	stalled	X	no pane output"

# --- --owner scopes the ratio denominator correctly ---------------------------
# w1, w2 (under lead1) die; w3 (under lead1) stays working. Five unrelated
# top-level members (plus lead1 itself) are also live. Scoped to lead1, the
# denominator is 1 (w3) + 2 (died) = 3, so the batch collapses; scoped to the
# top level, the same batch is diluted by the unrelated top-level population and
# must NOT collapse.
test_new_home
wm_state crew-add --id lead1 --type lead --objective L --repo /tmp --window wm-lead1 --session-id sd1 >/dev/null
wm_state crew-add --id w1 --type developer --objective a --repo /tmp --window wm-w1 --session-id sd2 --parent lead1 >/dev/null
wm_state crew-add --id w2 --type developer --objective b --repo /tmp --window wm-w2 --session-id sd3 --parent lead1 >/dev/null
wm_state crew-add --id w3 --type developer --objective c --repo /tmp --window wm-w3 --session-id sd4 --parent lead1 >/dev/null
for n in 1 2 3 4 5; do
  wm_state crew-add --id "top$n" --type developer --objective x --repo /tmp --window "wm-top$n" --session-id "st$n" >/dev/null
done
wm_state crew-set --id w1 --status died >/dev/null
wm_state crew-set --id w2 --status died >/dev/null
input="$(printf 'w1\tdied\tX\t\nw2\tdied\tX\t')"
out_scoped="$(printf '%s\n' "$input" | wm_state group-attention --owner lead1)"
assert_contains "lead1-scoped denominator collapses its own 2-of-3 death batch" "$out_scoped" "correlated:mass-death"
out_unscoped="$(printf '%s\n' "$input" | wm_state group-attention --owner "")"
assert_false "the same batch under the wrong owner scope is diluted below threshold" \
  "printf '%s\n' \"$out_unscoped\" | grep -q correlated:mass-death"

# --- the grouped output parses cleanly as fire() expects ----------------------
test_new_home
wm_state crew-add --id e1 --type developer --objective x --repo /tmp --window wm-e1 --session-id se1 >/dev/null
wm_state crew-add --id e2 --type developer --objective y --repo /tmp --window wm-e2 --session-id se2 >/dev/null
wm_state crew-set --id e1 --status died >/dev/null
wm_state crew-set --id e2 --status died >/dev/null
input="$(printf 'e1\tdied\tX\t\ne2\tdied\tX\t')"
out="$(printf '%s\n' "$input" | wm_state group-attention --owner "")"
parsed="$(printf '%s\n' "$out" | while IFS=$'\t' read -r id st upd note; do
  [ -n "$id" ] && [ -n "$st" ] && [ -n "$upd" ] && echo "ok:$id:$st"
done)"
assert_contains "the grouped row parses as id/status/updated/note" "$parsed" "ok:correlated:mass-death:died"

# --- a died batch tagged death_cause=api-outage collapses into
# correlated:api-outage-death, never correlated:mass-death (issue #23) -------
# g1, g2 die with death_cause=api-outage; g3 (working) is the only other live
# member. Denominator = 1 (g3) + 2 (died) = 3; ratio = 2/3 >= 0.5, count 2 >= 2.
tag_death_cause() {
  # tag_death_cause <crew.json path> <id> [<id2> ...]
  _tdc_path="$1"; shift
  uv run --no-project --quiet python -c '
import json, sys
path, ids = sys.argv[1], sys.argv[2:]
d = json.load(open(path))
for r in d:
    if r.get("id") in ids:
        r["death_cause"] = "api-outage"
json.dump(d, open(path, "w"))
' "$_tdc_path" "$@"
}

test_new_home
wm_state crew-add --id g1 --type developer --objective a --repo /tmp --window wm-g1 --session-id sg1 >/dev/null
wm_state crew-add --id g2 --type developer --objective b --repo /tmp --window wm-g2 --session-id sg2 >/dev/null
wm_state crew-add --id g3 --type developer --objective c --repo /tmp --window wm-g3 --session-id sg3 >/dev/null
wm_state crew-set --id g1 --status died >/dev/null
wm_state crew-set --id g2 --status died >/dev/null
tag_death_cause "$WINGMAN_HOME/crew.json" g1 g2
input="$(printf 'g1\tdied\tX\t\ng2\tdied\tX\t')"
out="$(printf '%s\n' "$input" | wm_state group-attention --owner "")"
assert_contains "an outage-tagged death batch collapses into api-outage-death" "$out" "correlated:api-outage-death"
assert_false "it never collapses into plain mass-death" "printf '%s\n' \"$out\" | grep -q correlated:mass-death"
assert_contains "the synthetic note says do NOT resume yet" "$out" "Do NOT resume yet"
assert_contains "the synthetic note points at the pre-authorized auto-recovery" "$out" "issue #23"
assert_contains "the collapsed row names g1" "$out" "g1"
assert_contains "the collapsed row names g2" "$out" "g2"

# --- a mixed-cause batch partitions and evaluates each subgroup independently
# h1, h2 die with death_cause=api-outage (2 of them); h3, h4 die with no
# cause tag (a plain crash, 2 of them); h5 stays working (the only other live
# member). Denominator = 1 (h5) + 4 (died) = 5 for BOTH subsets.
# outage subset: 2/5 = 0.4, BELOW the 0.5 default ratio - stays ungrouped.
# crash subset:  2/5 = 0.4, BELOW the 0.5 default ratio - stays ungrouped too.
# (Proves partitioning happens before the threshold check: neither subset is
# padded by the other's count to cross the ratio it could not clear alone.)
test_new_home
wm_state crew-add --id h1 --type developer --objective a --repo /tmp --window wm-h1 --session-id sh1 >/dev/null
wm_state crew-add --id h2 --type developer --objective b --repo /tmp --window wm-h2 --session-id sh2 >/dev/null
wm_state crew-add --id h3 --type developer --objective c --repo /tmp --window wm-h3 --session-id sh3 >/dev/null
wm_state crew-add --id h4 --type developer --objective d --repo /tmp --window wm-h4 --session-id sh4 >/dev/null
wm_state crew-add --id h5 --type developer --objective e --repo /tmp --window wm-h5 --session-id sh5 >/dev/null
for i in h1 h2 h3 h4; do wm_state crew-set --id "$i" --status died >/dev/null; done
tag_death_cause "$WINGMAN_HOME/crew.json" h1 h2
input="$(printf 'h1\tdied\tX\t\nh2\tdied\tX\t\nh3\tdied\tX\t\nh4\tdied\tX\t')"
out="$(printf '%s\n' "$input" | wm_state group-attention --owner "")"
assert_false "the outage subset alone is below ratio, stays ungrouped" "printf '%s\n' \"$out\" | grep -q correlated:api-outage-death"
assert_false "the crash subset alone is below ratio, stays ungrouped" "printf '%s\n' \"$out\" | grep -q correlated:mass-death"
assert_contains "h1 stays an individual row" "$out" "h1"
assert_contains "h2 stays an individual row" "$out" "h2"
assert_contains "h3 stays an individual row" "$out" "h3"
assert_contains "h4 stays an individual row" "$out" "h4"

# A mixed batch where ONLY the outage subset clears threshold: i1..i4 die
# tagged api-outage (4 of them); i5 dies untagged (1, alone, never collapses on
# its own); i6 stays working. Denominator = 1 (i6) + 5 (died) = 6.
# outage subset: 4/6 = 0.667 >= 0.5, count 4 >= 2 - COLLAPSES.
# crash subset:  1/6 = 0.167, count 1 < 2 - never collapses regardless of ratio.
test_new_home
for n in 1 2 3 4; do
  wm_state crew-add --id "i$n" --type developer --objective "o$n" --repo /tmp --window "wm-i$n" --session-id "si$n" >/dev/null
done
wm_state crew-add --id i5 --type developer --objective o5 --repo /tmp --window wm-i5 --session-id si5 >/dev/null
wm_state crew-add --id i6 --type developer --objective o6 --repo /tmp --window wm-i6 --session-id si6 >/dev/null
for n in 1 2 3 4 5; do wm_state crew-set --id "i$n" --status died >/dev/null; done
tag_death_cause "$WINGMAN_HOME/crew.json" i1 i2 i3 i4
input="$(printf 'i1\tdied\tX\t\ni2\tdied\tX\t\ni3\tdied\tX\t\ni4\tdied\tX\t\ni5\tdied\tX\t')"
out="$(printf '%s\n' "$input" | wm_state group-attention --owner "")"
assert_contains "the outage subset (4 of 4 outage-tagged) collapses on its own" "$out" "correlated:api-outage-death"
assert_contains "the collapsed row names all four outage-tagged ids" "$out" "i1"
assert_false "the untagged minority (i5) is never absorbed into the outage-death bucket" \
  "printf '%s\n' \"$out\" | grep -A0 correlated:api-outage-death | grep -q i5"
assert_contains "the untagged minority (i5) still passes through as its own row" "$out" "i5	died	X	"
assert_false "the untagged minority never collapses into mass-death either (count < min-count)" \
  "printf '%s\n' \"$out\" | grep -q correlated:mass-death"

# --- stale Remote Control caveat on a single died row (issue #96) -------------
# cmd_needs_attention (not group-attention) appends the caveat, so these cases
# drive `wm_state needs-attention` directly rather than feeding a synthetic TSV.
test_new_home
wm_state crew-add --id j1 --type developer --objective a --repo /tmp --window wm-j1 --session-id sj1 --remote-control >/dev/null
wm_state crew-set --id j1 --status died >/dev/null
na_out="$(wm_state needs-attention --owner "")"
assert_contains "a died member with remote_control=true carries the stale-RC caveat" "$na_out" "Remote Control may still show 'wm-j1' as connected"
assert_contains "the caveat tells the reader to disregard it" "$na_out" "disregard it"

test_new_home
wm_state crew-add --id j2 --type developer --objective a --repo /tmp --window wm-j2 --session-id sj2 >/dev/null
wm_state crew-set --id j2 --status died >/dev/null
na_out2="$(wm_state needs-attention --owner "")"
assert_false "a died member with remote_control=false (the crew-add default) carries no caveat" \
  "printf '%s\n' \"$na_out2\" | grep -q 'Remote Control may still show'"

# A legacy record predating this field entirely (both keys absent, not merely
# false) reads as true by default - the caveat still appears.
strip_remote_control() {
  # strip_remote_control <crew.json path> <id>
  uv run --no-project --quiet python -c '
import json, sys
path, rid = sys.argv[1], sys.argv[2]
d = json.load(open(path))
for r in d:
    if r.get("id") == rid:
        r.pop("remote_control", None)
        r.pop("remote_control_connected", None)
json.dump(d, open(path, "w"))
' "$1" "$2"
}
test_new_home
wm_state crew-add --id j3 --type developer --objective a --repo /tmp --window wm-j3 --session-id sj3 >/dev/null
strip_remote_control "$WINGMAN_HOME/crew.json" j3
wm_state crew-set --id j3 --status died >/dev/null
na_out3="$(wm_state needs-attention --owner "")"
assert_contains "a legacy record with both RC fields entirely absent still gets the caveat (absent reads as true)" \
  "$na_out3" "Remote Control may still show 'wm-j3' as connected"

# --- stale Remote Control caveat on a mass-death synthetic note (issue #96) ---
# Reruns the g1/g2 outage-death batch above with remote_control=true tagged on
# one member, confirming cmd_group_attention's own synthetic note also carries
# a caveat (a mass-death batch is exactly the host/tmux-crash scenario issue
# #96 was originally reported from).
tag_remote_control() {
  # tag_remote_control <crew.json path> <id> [<id2> ...]
  _trc_path="$1"; shift
  uv run --no-project --quiet python -c '
import json, sys
path, ids = sys.argv[1], sys.argv[2:]
d = json.load(open(path))
for r in d:
    if r.get("id") in ids:
        r["remote_control"] = True
json.dump(d, open(path, "w"))
' "$_trc_path" "$@"
}

test_new_home
wm_state crew-add --id k1 --type developer --objective a --repo /tmp --window wm-k1 --session-id sk1 >/dev/null
wm_state crew-add --id k2 --type developer --objective b --repo /tmp --window wm-k2 --session-id sk2 >/dev/null
wm_state crew-add --id k3 --type developer --objective c --repo /tmp --window wm-k3 --session-id sk3 >/dev/null
wm_state crew-set --id k1 --status died >/dev/null
wm_state crew-set --id k2 --status died >/dev/null
tag_remote_control "$WINGMAN_HOME/crew.json" k1
input="$(printf 'k1\tdied\tX\t\nk2\tdied\tX\t')"
out="$(printf '%s\n' "$input" | wm_state group-attention --owner "")"
assert_contains "the mass-death batch collapses" "$out" "correlated:mass-death"
assert_contains "the synthetic note carries the stale-RC batch caveat when any member had remote_control=true" \
  "$out" "may also still show as connected in Remote Control"

test_new_home
wm_state crew-add --id l1 --type developer --objective a --repo /tmp --window wm-l1 --session-id sl1 >/dev/null
wm_state crew-add --id l2 --type developer --objective b --repo /tmp --window wm-l2 --session-id sl2 >/dev/null
wm_state crew-add --id l3 --type developer --objective c --repo /tmp --window wm-l3 --session-id sl3 >/dev/null
wm_state crew-set --id l1 --status died >/dev/null
wm_state crew-set --id l2 --status died >/dev/null
input="$(printf 'l1\tdied\tX\t\nl2\tdied\tX\t')"
out="$(printf '%s\n' "$input" | wm_state group-attention --owner "")"
assert_contains "the mass-death batch collapses" "$out" "correlated:mass-death"
assert_false "no batch caveat when no member in the batch had remote_control=true (the crew-add default)" \
  "printf '%s\n' \"$out\" | grep -q 'may also still show as connected'"

test_summary
