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

test_summary
