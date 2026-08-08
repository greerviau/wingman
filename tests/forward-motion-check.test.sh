#!/usr/bin/env bash
# E2E: structural forward-motion / logical-stall detection (issue #199, Gap
# B). A lead whose watcher is live and cycling normally, with N workers
# permanently parked and no reviewer ever spawned (or any other roster shape
# that never changes), produces zero attention events forever through the
# only channel that can wake anyone - the existing liveness stall-check never
# nominates it either, since a lead correctly running its own watch-fleet
# loop always shows a live process tree. wm_state forward-motion-check closes
# this: a WORKING candidate with at least one active report flips directly to
# 'stalled' once its own roster-shape signature (its own summary/blocker/
# artifact/delivery, plus every active report's own status/summary/blocker/
# artifact/delivery/announced) has
# shown no change for --window-secs - resetting the clock the instant
# anything about that shape genuinely moves. Modeled directly on
# tests/review-resurface.test.sh's structure and helpers. No real
# tmux/claude/forge needed.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

wm_py() { uv run --no-project --quiet python "$@"; }

# issue #235: the provenance _impose_stall records on every forward-motion flip.
stall_field() {
  wm_py -c '
import json, sys
d = json.load(open(sys.argv[1])).get("stall") or {}
v = d.get(sys.argv[2])
print(v if v is not None else "")
' "$WINGMAN_HOME/crew/$1.json" "$2"
}

updated_of() {
  wm_py -c 'import json,sys; print(json.load(open(sys.argv[1]))["updated"])' \
    "$WINGMAN_HOME/crew/$1.json"
}

# issue #244: forward-motion.json's per-candidate anchor "since" stamp.
anchor_since() {
  wm_py -c '
import json, sys, os
p = sys.argv[1]
d = json.load(open(p)) if os.path.exists(p) else {}
print((d.get(sys.argv[2]) or {}).get("since", ""))
' "$WINGMAN_HOME/forward-motion.json" "$1"
}

spawn_bg() { "$@" & wm_track "$!"; }

# --- 1. baseline fire: a lead + 3 developers all review, no reviewer --------
test_new_home
wm_state crew-add --id lead1 --type developer --objective x --repo /tmp --window wm-lead1 --session-id s1 >/dev/null
wm_state crew-set --id lead1 --status working --summary "leading the effort" >/dev/null
for n in 1 2 3; do
  wm_state crew-add --id dev$n --type developer --objective x --repo /tmp --window wm-dev$n --session-id s-dev$n --parent lead1 >/dev/null
  wm_state crew-set --id dev$n --status review --summary "PR up" --delivery "https://gh/pr/$n" >/dev/null
done

wm_state forward-motion-check --owner "" --window-secs 2 >/dev/null
sleep 2.5
out1="$(wm_state forward-motion-check --owner "" --window-secs 2)"
assert_contains "the lead flips to stalled" "$out1" "stalled lead1"
status1="$(wm_state crew-get --id lead1 | uv run --no-project --quiet python -c "import json,sys; print(json.load(sys.stdin)['status'])")"
assert_eq "the roster record itself reflects the flip" "$status1" "stalled"
reason1="$(wm_state crew-get --id lead1 | uv run --no-project --quiet python -c "import json,sys; print(json.load(sys.stdin)['summary'])")"
assert_contains "the reason mentions the active report count" "$reason1" "3 active report(s)"
assert_contains "the reason points at crew-takeover" "$reason1" "bin/crew-takeover lead1"
assert_contains "the reason points at crew-say for a nudge" "$reason1" "bin/crew-say lead1"
assert_contains "the reason preserves the lead's own last summary" "$reason1" "(last summary: leading the effort)"

# issue #235: the flip records provenance for cmd_stall_recheck to re-run
# this SAME detector's own evidence later - source/since/prev_status/
# prev_summary/children_sig (the reports-only hash, so a later recheck can
# tell "at least one report has since changed state" without needing the
# candidate's own summary/blocker/artifact/delivery, which cannot move while
# latched stalled).
assert_eq "stall.source records 'forward-motion'" "$(stall_field lead1 source)" "forward-motion"
assert_eq "stall.prev_status records the pre-flip status" "$(stall_field lead1 prev_status)" "working"
assert_eq "stall.prev_summary records the pre-flip summary, untruncated" \
  "$(stall_field lead1 prev_summary)" "leading the effort"
assert_eq "stall.prev_blocker is null - there was no blocker" "$(stall_field lead1 prev_blocker)" ""
assert_eq "stall.since matches the record's own updated stamp" \
  "$(stall_field lead1 since)" "$(updated_of lead1)"
children_sig1="$(stall_field lead1 children_sig)"
assert_eq "stall.children_sig is a sha256 hex digest (64 hex chars)" \
  "$(printf '%s' "$children_sig1" | grep -cE '^[0-9a-f]{64}$')" "1"

# --- 2. silent before the window elapses -------------------------------------
test_new_home
wm_state crew-add --id lead2 --type developer --objective x --repo /tmp --window wm-lead2 --session-id s2 >/dev/null
wm_state crew-set --id lead2 --status working --summary "leading" >/dev/null
wm_state crew-add --id dev2a --type developer --objective x --repo /tmp --window wm-dev2a --session-id s-dev2a --parent lead2 >/dev/null
wm_state crew-set --id dev2a --status review --summary "PR up" --delivery "https://gh/pr/2a" >/dev/null

out2a="$(wm_state forward-motion-check --owner "" --window-secs 3)"
assert_eq "silent on the very first check (anchor just established)" "$out2a" ""
sleep 2
out2b="$(wm_state forward-motion-check --owner "" --window-secs 3)"
assert_eq "silent just under the window" "$out2b" ""
status2="$(wm_state crew-get --id lead2 | uv run --no-project --quiet python -c "import json,sys; print(json.load(sys.stdin)['status'])")"
assert_eq "lead2 is still working, not stalled" "$status2" "working"

# --- 3. a child's status change resets the anchor ----------------------------
test_new_home
wm_state crew-add --id lead3 --type developer --objective x --repo /tmp --window wm-lead3 --session-id s3 >/dev/null
wm_state crew-set --id lead3 --status working --summary "leading" >/dev/null
wm_state crew-add --id dev3 --type developer --objective x --repo /tmp --window wm-dev3 --session-id s-dev3 --parent lead3 >/dev/null
wm_state crew-set --id dev3 --status review --summary "PR up" --delivery "https://gh/pr/3" >/dev/null

wm_state forward-motion-check --owner "" --window-secs 4 >/dev/null
sleep 2
wm_state forward-motion-check --owner "" --window-secs 4 >/dev/null   # still mid-window, anchor untouched

wm_state crew-set --id dev3 --status blocked --blocker "need a call" >/dev/null
out3a="$(wm_state forward-motion-check --owner "" --window-secs 4)"
assert_eq "the child's status change resets the anchor: no flip yet" "$out3a" ""

# A generous 2.2s later is well PAST the ORIGINAL anchor's window (t0+4 would
# have elapsed by now) but well UNDER a fresh 4s window from the reset point -
# proving the reset genuinely happened, not merely that not enough total time
# has passed.
sleep 2.2
out3b="$(wm_state forward-motion-check --owner "" --window-secs 4)"
assert_eq "still no flip - a FRESH window is required from the reset point" "$out3b" ""

sleep 2.3
out3c="$(wm_state forward-motion-check --owner "" --window-secs 4)"
assert_contains "the fresh window from the reset point eventually elapses and flips" "$out3c" "stalled lead3"

# --- 4. a new child appearing resets the anchor ------------------------------
test_new_home
wm_state crew-add --id lead4 --type developer --objective x --repo /tmp --window wm-lead4 --session-id s4 >/dev/null
wm_state crew-set --id lead4 --status working --summary "leading" >/dev/null
wm_state crew-add --id dev4 --type developer --objective x --repo /tmp --window wm-dev4 --session-id s-dev4 --parent lead4 >/dev/null
wm_state crew-set --id dev4 --status review --summary "PR up" --delivery "https://gh/pr/4" >/dev/null

wm_state forward-motion-check --owner "" --window-secs 3 >/dev/null
sleep 2
# A reviewer finally gets spawned - the direct regression case for "a review
# worker with no reviewer sibling."
wm_state crew-add --id rev4 --type reviewer --objective x --repo /tmp --window wm-rev4 --session-id s-rev4 --parent lead4 >/dev/null
out4="$(wm_state forward-motion-check --owner "" --window-secs 3)"
assert_eq "a new child appearing resets the anchor: no flip" "$out4" ""
sleep 1.5
out4b="$(wm_state forward-motion-check --owner "" --window-secs 3)"
assert_eq "still no flip shortly after (fresh window required from the reset point)" "$out4b" ""

# --- 5. the lead's own summary change resets the anchor ----------------------
test_new_home
wm_state crew-add --id lead5 --type developer --objective x --repo /tmp --window wm-lead5 --session-id s5 >/dev/null
wm_state crew-set --id lead5 --status working --summary "leading" >/dev/null
wm_state crew-add --id dev5 --type developer --objective x --repo /tmp --window wm-dev5 --session-id s-dev5 --parent lead5 >/dev/null
wm_state crew-set --id dev5 --status review --summary "PR up" --delivery "https://gh/pr/5" >/dev/null

wm_state forward-motion-check --owner "" --window-secs 3 >/dev/null
sleep 2
wm_state crew-set --id lead5 --status working --summary "still leading, checked CI" >/dev/null
out5="$(wm_state forward-motion-check --owner "" --window-secs 3)"
assert_eq "the lead's own summary change resets the anchor: no flip" "$out5" ""
sleep 1.5
out5b="$(wm_state forward-motion-check --owner "" --window-secs 3)"
assert_eq "still no flip shortly after (fresh window required from the reset point)" "$out5b" ""

# --- 6. no false positive on a plain worker with no reports of its own ------
test_new_home
wm_state crew-add --id solo6 --type developer --objective x --repo /tmp --window wm-solo6 --session-id s6 >/dev/null
wm_state crew-set --id solo6 --status working --summary "coding away" >/dev/null

wm_state forward-motion-check --owner "" --window-secs 2 >/dev/null
sleep 2.5
out6="$(wm_state forward-motion-check --owner "" --window-secs 2)"
assert_eq "a worker with no reports of its own is never a candidate" "$out6" ""
status6="$(wm_state crew-get --id solo6 | uv run --no-project --quiet python -c "import json,sys; print(json.load(sys.stdin)['status'])")"
assert_eq "solo6 stays working - only the liveness stall-check can ever flip it" "$status6" "working"

# --- 7. resume-then-re-stall does not thrash ---------------------------------
test_new_home
wm_state crew-add --id lead7 --type developer --objective x --repo /tmp --window wm-lead7 --session-id s7 >/dev/null
wm_state crew-set --id lead7 --status working --summary "leading" >/dev/null
wm_state crew-add --id dev7 --type developer --objective x --repo /tmp --window wm-dev7 --session-id s-dev7 --parent lead7 >/dev/null
wm_state crew-set --id dev7 --status review --summary "PR up" --delivery "https://gh/pr/7" >/dev/null

wm_state forward-motion-check --owner "" --window-secs 2 >/dev/null
sleep 2.5
out7a="$(wm_state forward-motion-check --owner "" --window-secs 2)"
assert_contains "the initial stall flip fires" "$out7a" "stalled lead7"

# A genuine transition out of stalled (bumps announced, per the status contract).
wm_state crew-set --id lead7 --status working --summary "resumed" >/dev/null

# Immediately re-check on the SAME cycle - the episode_announced anchor key
# must prevent an instant re-flip, even though the roster shape (lead7's own
# summary/blocker/artifact/delivery, dev7's status/summary/blocker/artifact/
# delivery/announced) is otherwise
# identical to what it was right before the flip.
out7b="$(wm_state forward-motion-check --owner "" --window-secs 2)"
assert_eq "an immediate re-check after resume does not re-flip" "$out7b" ""
status7a="$(wm_state crew-get --id lead7 | uv run --no-project --quiet python -c "import json,sys; print(json.load(sys.stdin)['status'])")"
assert_eq "lead7 is genuinely back to working, not re-stalled" "$status7a" "working"

# A second immediate re-check (no time elapsed) must also not thrash.
out7c="$(wm_state forward-motion-check --owner "" --window-secs 2)"
assert_eq "a second immediate re-check still does not re-flip" "$out7c" ""

# But it is not permanently suppressed either: once a FULL fresh window
# elapses with no further change, it flips again.
sleep 2.5
out7d="$(wm_state forward-motion-check --owner "" --window-secs 2)"
assert_contains "a fresh full window after the resume flips again" "$out7d" "stalled lead7"

# --- 8. once stalled, the candidate is never renominated (a state, not a repeating reminder) ---
# Unlike cmd_review_resurface_check (which emits a repeating reminder NOTE
# every window while the underlying status stays 'review'), this check flips
# STATUS directly - once 'stalled', status != 'working', so the candidate is
# no longer eligible at all, and no further mutation happens until a
# human/owner explicitly resumes it. Confirmed above at the tail of case 7
# (out7a fires once; nothing re-fires or re-writes until the explicit resume),
# and directly here: further checks against an untouched stalled record never
# print anything and never touch its stored anchor entry again.
test_new_home
wm_state crew-add --id lead8 --type developer --objective x --repo /tmp --window wm-lead8 --session-id s8 >/dev/null
wm_state crew-set --id lead8 --status working --summary "leading" >/dev/null
wm_state crew-add --id dev8 --type developer --objective x --repo /tmp --window wm-dev8 --session-id s-dev8 --parent lead8 >/dev/null
wm_state crew-set --id dev8 --status review --summary "PR up" --delivery "https://gh/pr/8" >/dev/null

wm_state forward-motion-check --owner "" --window-secs 2 >/dev/null
sleep 2.5
out8a="$(wm_state forward-motion-check --owner "" --window-secs 2)"
assert_contains "the flip fires once" "$out8a" "stalled lead8"

sleep 2.5
out8b="$(wm_state forward-motion-check --owner "" --window-secs 2)"
assert_eq "a stalled candidate is never renominated - no repeat firing" "$out8b" ""
out8c="$(wm_state forward-motion-check --owner "" --window-secs 2)"
assert_eq "still silent on yet another cycle" "$out8c" ""
status8="$(wm_state crew-get --id lead8 | uv run --no-project --quiet python -c "import json,sys; print(json.load(sys.stdin)['status'])")"
assert_eq "lead8 stays stalled until explicitly resumed" "$status8" "stalled"

# ============================================================================
# issue #244: flip-time liveness probe. A candidate whose elapsed time
# reaches --window-secs gets one more chance before flipping: its `working`
# children's pane pids (fed via --pane-pids-stdin, one 'wm-<id> <pid>' line
# per line, mirroring bin/watch-fleet's own tmux list-panes -s snapshot) are
# probed for genuine CPU spend via _probe_cpu_delta - deliberately branch (b)
# only, never _probe_execution's branch (a), so a child merely parked on its
# own idle armed watcher (which always has a late-started descendant) cannot
# read "alive" for free and permanently suppress the detector. Every case
# below reuses spawn_bg/wm_track from tests/lead-liveness-exemption.test.sh.
#
# A genuine CPU-spinning loop (`while :; do :; done`), not the fork/sleep
# spawn-loop shape section 2's manual reproduction uses, stands in for "a
# continuously busy process tree" in the cases below that need one: `ps -o
# time=` only has whole-second resolution, and empirically the fork/sleep
# shape's cumulative cputime never crosses a full second within any
# test-affordable --probe-gap (confirmed directly against _probe_cpu_delta
# while drafting this coverage) - only a genuinely CPU-bound tree exercises
# this branch deterministically, within a short gap, on real hardware.
#
# Cases 9-11 (the ones that need an independent TRUE reprieve reading) use
# --probe-gap 3, not 1: at gap=1 the spin loop must cross a whole-second
# `ps -o time=` boundary inside a 1-second window, which under the same
# tests/run.sh contention that motivated the spin-loop choice above
# (nproc-wide parallelism, and this very file holding two dedicated spin
# loops) measurably fails often enough to flake - gap=3 was measured clean
# across every contention level tested. Cases 12-14 never reach
# _probe_cpu_delta at all (a non-working child, an unresolvable pid, and no
# --pane-pids-stdin respectively), so their --probe-gap 1 is inert and left
# alone.
# ============================================================================

# --- 9. the core fix: a busy working child reprieves the candidate -----------
test_new_home
wm_state crew-add --id lead9 --type developer --objective x --repo /tmp --window wm-lead9 --session-id s9 >/dev/null
wm_state crew-set --id lead9 --status working --summary "leading" >/dev/null
wm_state crew-add --id dev9 --type developer --objective x --repo /tmp --window wm-dev9 --session-id s-dev9 --parent lead9 >/dev/null
wm_state crew-set --id dev9 --status working --summary "coding away" >/dev/null

spawn_bg sh -c 'while :; do :; done'
dev9_pid=$!

printf 'wm-dev9 %s\n' "$dev9_pid" \
  | wm_state forward-motion-check --owner "" --window-secs 2 --probe-gap 3 --cpu-eps 0.01 --pane-pids-stdin >/dev/null
since9a="$(anchor_since lead9)"

sleep 2.5
out9a="$(printf 'wm-dev9 %s\n' "$dev9_pid" \
  | wm_state forward-motion-check --owner "" --window-secs 2 --probe-gap 3 --cpu-eps 0.01 --pane-pids-stdin)"
assert_eq "a busy working child reprieves the candidate: no flip" "$out9a" ""
since9b="$(anchor_since lead9)"
if [ "$since9b" != "$since9a" ]; then ok "the anchor's since visibly advances on reprieve"; else fail "the anchor's since visibly advances on reprieve"; fi
status9a="$(wm_state crew-get --id lead9 | uv run --no-project --quiet python -c "import json,sys; print(json.load(sys.stdin)['status'])")"
assert_eq "lead9 is still working" "$status9a" "working"

sleep 2.5
out9b="$(printf 'wm-dev9 %s\n' "$dev9_pid" \
  | wm_state forward-motion-check --owner "" --window-secs 2 --probe-gap 3 --cpu-eps 0.01 --pane-pids-stdin)"
assert_eq "reprieved again on the next window: still no flip" "$out9b" ""
since9c="$(anchor_since lead9)"
if [ "$since9c" != "$since9b" ]; then ok "the anchor's since advances again on the next reprieve"; else fail "the anchor's since advances again on the next reprieve"; fi

kill "$dev9_pid" 2>/dev/null
wait "$dev9_pid" 2>/dev/null

# --- 10. MF2/MF-A regression guard: an idle armed-watcher child must NOT
# reprieve. Branch (a) alone would read this tree "alive" (a late-started
# descendant); _probe_cpu_delta's CPU-delta sample must not, and the
# candidate must still flip on schedule. This is the control that
# distinguishes this design from a draft that called _probe_execution
# (branch (a) OR (b)) instead of _probe_cpu_delta directly - branch (a)
# would have short-circuited on this exact fixture.
test_new_home
wm_state crew-add --id lead10 --type developer --objective x --repo /tmp --window wm-lead10 --session-id s10 >/dev/null
wm_state crew-set --id lead10 --status working --summary "leading" >/dev/null
wm_state crew-add --id dev10 --type developer --objective x --repo /tmp --window wm-dev10 --session-id s-dev10 --parent lead10 >/dev/null
wm_state crew-set --id dev10 --status working --summary "waiting on its own armed watcher" >/dev/null

spawn_bg sh -c 'sleep 4; sleep 600 & wait'
dev10_pid=$!
sleep 5   # let the late child exist and lag the root well past any root-grace

printf 'wm-dev10 %s\n' "$dev10_pid" \
  | wm_state forward-motion-check --owner "" --window-secs 2 --probe-gap 3 --cpu-eps 0.01 --pane-pids-stdin >/dev/null
sleep 2.5
out10="$(printf 'wm-dev10 %s\n' "$dev10_pid" \
  | wm_state forward-motion-check --owner "" --window-secs 2 --probe-gap 3 --cpu-eps 0.01 --pane-pids-stdin)"
assert_contains "an idle armed-watcher child does not reprieve: candidate still flips" "$out10" "stalled lead10"

# --- 11. withdraw liveness: a reprieve self-heals rather than permanently
# suppressing the candidate. The SAME pid is busy through the first reprieve,
# then genuinely idle (frozen via SIGSTOP - no descendant, no further CPU,
# but still a live, resolvable pid) with no reported-state change either: the
# very next full window from the last reprieve eventually flips. SIGSTOP,
# not a bounded `timeout`+exit, so the CPU-accumulating pid never dies mid-
# probe: _probe_cpu_delta only counts a pid present in BOTH samples, so a
# child that finishes/dies between the two samples loses credit for whatever
# it spent right before dying - freezing it in place instead avoids that
# entirely and isolates the one thing this case actually tests.
test_new_home
wm_state crew-add --id lead11 --type developer --objective x --repo /tmp --window wm-lead11 --session-id s11 >/dev/null
wm_state crew-set --id lead11 --status working --summary "leading" >/dev/null
wm_state crew-add --id dev11 --type developer --objective x --repo /tmp --window wm-dev11 --session-id s-dev11 --parent lead11 >/dev/null
wm_state crew-set --id dev11 --status working --summary "coding away" >/dev/null

spawn_bg sh -c 'while :; do :; done'
dev11_pid=$!

printf 'wm-dev11 %s\n' "$dev11_pid" \
  | wm_state forward-motion-check --owner "" --window-secs 2 --probe-gap 3 --cpu-eps 0.01 --pane-pids-stdin >/dev/null
sleep 2.5   # elapsed >= window(2); probe samples while dev11 is still genuinely spinning
out11a="$(printf 'wm-dev11 %s\n' "$dev11_pid" \
  | wm_state forward-motion-check --owner "" --window-secs 2 --probe-gap 3 --cpu-eps 0.01 --pane-pids-stdin)"
assert_eq "reprieved once while busy: no flip" "$out11a" ""
status11a="$(wm_state crew-get --id lead11 | uv run --no-project --quiet python -c "import json,sys; print(json.load(sys.stdin)['status'])")"
assert_eq "lead11 is still working after the reprieve" "$status11a" "working"

kill -STOP "$dev11_pid" 2>/dev/null   # freeze: same pid, genuinely idle from here on

sleep 4   # well past a fresh window(2) from the reset
out11b="$(printf 'wm-dev11 %s\n' "$dev11_pid" \
  | wm_state forward-motion-check --owner "" --window-secs 2 --probe-gap 3 --cpu-eps 0.01 --pane-pids-stdin)"
assert_contains "frozen (genuinely idle) on the next full window: the reprieve self-heals and it flips" "$out11b" "stalled lead11"

kill -CONT "$dev11_pid" 2>/dev/null
kill "$dev11_pid" 2>/dev/null
wait "$dev11_pid" 2>/dev/null

# --- 12. working-only scoping: a non-working child's busy pane is never
# probed. A candidate whose only child is parked in `review` with a busy
# process tree at that child's resolved pane pid still flips - a non-
# `working` report is never probed regardless of what its pane shows
# (matching NF5's own point about a `review` member parked on a live
# pr-watch otherwise always reading busy).
test_new_home
wm_state crew-add --id lead12 --type developer --objective x --repo /tmp --window wm-lead12 --session-id s12 >/dev/null
wm_state crew-set --id lead12 --status working --summary "leading" >/dev/null
wm_state crew-add --id dev12 --type developer --objective x --repo /tmp --window wm-dev12 --session-id s-dev12 --parent lead12 >/dev/null
wm_state crew-set --id dev12 --status review --summary "PR up" --delivery "https://gh/pr/12" >/dev/null

spawn_bg sh -c 'while :; do :; done'
dev12_pid=$!

printf 'wm-dev12 %s\n' "$dev12_pid" \
  | wm_state forward-motion-check --owner "" --window-secs 2 --probe-gap 1 --cpu-eps 0.01 --pane-pids-stdin >/dev/null
sleep 2.5
out12="$(printf 'wm-dev12 %s\n' "$dev12_pid" \
  | wm_state forward-motion-check --owner "" --window-secs 2 --probe-gap 1 --cpu-eps 0.01 --pane-pids-stdin)"
assert_contains "a review-parked child's busy pane is ignored: the candidate still flips" "$out12" "stalled lead12"

kill "$dev12_pid" 2>/dev/null
wait "$dev12_pid" 2>/dev/null

# --- 13. unresolvable pid: fail-open toward flipping. --pane-pids-stdin
# supplied but with no line for the candidate's child id: the candidate
# flips as if no liveness data existed at all, matching _probe_cpu_delta's
# own "tree cannot be read" fail-open contract.
test_new_home
wm_state crew-add --id lead13 --type developer --objective x --repo /tmp --window wm-lead13 --session-id s13 >/dev/null
wm_state crew-set --id lead13 --status working --summary "leading" >/dev/null
wm_state crew-add --id dev13 --type developer --objective x --repo /tmp --window wm-dev13 --session-id s-dev13 --parent lead13 >/dev/null
wm_state crew-set --id dev13 --status working --summary "coding away" >/dev/null

printf 'wm-someone-else 99999\n' \
  | wm_state forward-motion-check --owner "" --window-secs 2 --probe-gap 1 --cpu-eps 0.01 --pane-pids-stdin >/dev/null
sleep 2.5
out13="$(printf 'wm-someone-else 99999\n' \
  | wm_state forward-motion-check --owner "" --window-secs 2 --probe-gap 1 --cpu-eps 0.01 --pane-pids-stdin)"
assert_contains "no pane-pid line for the candidate's child: fails open and flips" "$out13" "stalled lead13"

# --- 14. no --pane-pids-stdin at all: identical to today's behavior, zero
# probing attempted (the regression floor, made explicit as its own
# assertion rather than only inferred from the untouched cases 1-8 above).
test_new_home
wm_state crew-add --id lead14 --type developer --objective x --repo /tmp --window wm-lead14 --session-id s14 >/dev/null
wm_state crew-set --id lead14 --status working --summary "leading" >/dev/null
wm_state crew-add --id dev14 --type developer --objective x --repo /tmp --window wm-dev14 --session-id s-dev14 --parent lead14 >/dev/null
wm_state crew-set --id dev14 --status working --summary "coding away" >/dev/null

spawn_bg sh -c 'while :; do :; done'
dev14_pid=$!

wm_state forward-motion-check --owner "" --window-secs 2 >/dev/null
sleep 2.5
out14="$(wm_state forward-motion-check --owner "" --window-secs 2)"
assert_contains "no --pane-pids-stdin: no probing attempted, flips exactly as before" "$out14" "stalled lead14"

kill "$dev14_pid" 2>/dev/null
wait "$dev14_pid" 2>/dev/null

# ============================================================================
# issue #305: a delegate's own record CONTENT (summary/blocker/artifact/
# delivery), not just its status or `announced` alone, counts as forward
# motion for the owning lead - closing the false-positive stall flips issue
# #305 reports (root cause shared with issue #264: a working child's
# `announced` freezes on its first-ever crew-set call, so _child_tuples's
# old `announced-or-updated` fallback never reached `updated` again for a
# child that stays `working` the whole time). `announced` is kept ALONGSIDE
# the content fields, not replaced by them - see case 18: a blocked/done
# event always advances `announced` regardless of content (cmd_crew_set), so
# a delegate that round-trips through an identical-looking re-block still
# needs `announced` to register as motion.
# ============================================================================

# --- 15. a working child's genuinely new summary resets the anchor ----------
# dev15 gets TWO working-status crew-set calls before the anchor is even
# established, so its `announced` is already frozen (seeded on the first
# call) well before forward-motion-check ever runs - the exact shape #264
# describes, and the shape a real developer mid-implementation produces.
test_new_home
wm_state crew-add --id lead15 --type developer --objective x --repo /tmp --window wm-lead15 --session-id s15 >/dev/null
wm_state crew-set --id lead15 --status working --summary "leading" >/dev/null
wm_state crew-add --id dev15 --type developer --objective x --repo /tmp --window wm-dev15 --session-id s-dev15 --parent lead15 >/dev/null
wm_state crew-set --id dev15 --status working --summary "coding v1" >/dev/null
wm_state crew-set --id dev15 --status working --summary "coding v1, still working" >/dev/null

wm_state forward-motion-check --owner "" --window-secs 5 >/dev/null
sleep 3
# Genuine new progress, still `working` the whole time.
wm_state crew-set --id dev15 --status working --summary "coding v2 - implemented the parser" >/dev/null
out15a="$(wm_state forward-motion-check --owner "" --window-secs 5)"
assert_eq "a working child's genuinely new summary resets the anchor: no flip" "$out15a" ""
sleep 2.5
out15b="$(wm_state forward-motion-check --owner "" --window-secs 5)"
assert_eq "still no flip shortly after (fresh window required from the reset point)" "$out15b" ""
status15="$(wm_state crew-get --id lead15 | uv run --no-project --quiet python -c "import json,sys; print(json.load(sys.stdin)['status'])")"
assert_eq "lead15 is still working" "$status15" "working"

# --- 16. a genuinely wedged lead with idle delegates still flips (issue #305
# regression guard: a delegate's repeated BYTE-IDENTICAL re-report - no real
# content change, same summary text every time - must not be mistaken for
# forward motion, preserving the original anti-spam intent). -----------------
test_new_home
wm_state crew-add --id lead16 --type developer --objective x --repo /tmp --window wm-lead16 --session-id s16 >/dev/null
wm_state crew-set --id lead16 --status working --summary "leading" >/dev/null
wm_state crew-add --id dev16 --type developer --objective x --repo /tmp --window wm-dev16 --session-id s-dev16 --parent lead16 >/dev/null
wm_state crew-set --id dev16 --status working --summary "coding away" >/dev/null

wm_state forward-motion-check --owner "" --window-secs 2 >/dev/null
sleep 1
# A no-op re-report: identical status AND identical summary text - not
# genuine progress, must not reset the anchor.
wm_state crew-set --id dev16 --status working --summary "coding away" >/dev/null
sleep 1.5
out16="$(wm_state forward-motion-check --owner "" --window-secs 2)"
assert_contains "a byte-identical re-report is not forward motion: the lead still flips" "$out16" "stalled lead16"

# --- 17. a working delegate that stops reporting entirely still flips the
# lead. -----------------------------------------------------------------------
test_new_home
wm_state crew-add --id lead17 --type developer --objective x --repo /tmp --window wm-lead17 --session-id s17 >/dev/null
wm_state crew-set --id lead17 --status working --summary "leading" >/dev/null
wm_state crew-add --id dev17 --type developer --objective x --repo /tmp --window wm-dev17 --session-id s-dev17 --parent lead17 >/dev/null
wm_state crew-set --id dev17 --status working --summary "coding away" >/dev/null

wm_state forward-motion-check --owner "" --window-secs 2 >/dev/null
# dev17 never calls crew-set again.
sleep 2.5
out17="$(wm_state forward-motion-check --owner "" --window-secs 2)"
assert_contains "a delegate that stops reporting entirely still lets the lead flip" "$out17" "stalled lead17"

# --- 18. a blocked delegate that round-trips through working and back to an
# IDENTICAL-looking blocked state (same summary, same blocker - a dev blocked
# twice on the same denial) still resets the anchor, because cmd_crew_set
# always advances `announced` on a blocked/done call regardless of content.
# (A content-only tuple with no `announced` false-flips here.) --------------
test_new_home
wm_state crew-add --id leadB --type developer --objective x --repo /tmp --window wm-leadB --session-id sB >/dev/null
wm_state crew-set --id leadB --status working --summary "leading" >/dev/null
wm_state crew-add --id devB --type developer --objective x --repo /tmp --window wm-devB --session-id s-devB --parent leadB >/dev/null
wm_state crew-set --id devB --status blocked --summary "hit a permission wall" --blocker "need X approved" >/dev/null

wm_state forward-motion-check --owner "" --window-secs 5 >/dev/null
sleep 2
# devB acts on the lead's crew-say answer, then hits the SAME wall again -
# byte-identical summary AND blocker on the re-block.
wm_state crew-set --id devB --status working --summary "retrying after the answer" >/dev/null
wm_state crew-set --id devB --status blocked --summary "hit a permission wall" --blocker "need X approved" >/dev/null
out18a="$(wm_state forward-motion-check --owner "" --window-secs 5)"
assert_eq "an identical-looking re-block still resets the anchor: no flip" "$out18a" ""
sleep 3.5
out18b="$(wm_state forward-motion-check --owner "" --window-secs 5)"
assert_eq "still no flip shortly after (fresh window required from the reset point)" "$out18b" ""
statusB="$(wm_state crew-get --id leadB | uv run --no-project --quiet python -c "import json,sys; print(json.load(sys.stdin)['status'])")"
assert_eq "leadB is still working" "$statusB" "working"

test_summary
