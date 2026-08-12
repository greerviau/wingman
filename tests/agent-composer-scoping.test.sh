#!/usr/bin/env bash
# E2E regression: issue #25 stage 4 review finding (PR #348 MF1). Before this
# fix, no wm_tmux_send_message caller threaded the target's own resolved
# agent name through as $3, so EVERY pane - including a non-claude one - was
# classified with claude's ambient WM_COMPOSER_RULE_RE/WM_COMPOSER_ANCHOR
# regardless of which adapter was actually resolved for that crew member.
# pi's own composer rule character happens to byte-match claude's
# WM_COMPOSER_RULE_RE (both use U+2500), so composer mode engaged against a
# pi pane, but pi's content row never matches claude's "❯"+NBSP anchor (pi
# has no such glyph), so wm_composer_is_empty never reported empty and every
# delivery would sit unconfirmed until the confirm loop exhausted - the
# "endlessly re-sent" failure the review reproduced against a captured pi
# pane.
#
# This file proves both directions with the SAME pi-shaped stub
# (tests/fixtures/composer-stub-pi.sh - both its rule character and its
# genuinely-blank emptied content row were hands-on captured against a real,
# live pi v0.84.1 pane, including a real submit that registered locally with
# no provider configured, not inferred from source):
#   - WITHOUT the agent name threaded (the pre-fix caller shape, exercised
#     directly here since every real caller is now fixed) still reproduces
#     the bug: composer mode engages via claude's ambient rule/anchor and the
#     delivery times out unconfirmed even though the submit genuinely
#     registered.
#   - WITH "pi" threaded as $3, the per-adapter swap in wm_tmux_send_message
#     resolves pi's descriptor and finds its REAL, live-verified values now
#     (WM_AGENT_COMPOSER_RULE_RE reusing the shared rule pattern,
#     WM_AGENT_COMPOSER_ANCHOR_EMPTY=1 declaring the true empty-composer
#     signature as the literal empty string) - so this is no longer merely
#     the whole-pane-checksum degradation path engaging: composer mode
#     itself correctly engages and confirms on the composer region actually
#     going empty, the same real mechanism claude's own pane uses.
#
# Also proves the real callers (crew-say, spawn-crew's opening objective,
# crew-resume's relaunch nudge, watch-fleet's stall nudge, wm_outbox_try_
# redeliver) now actually supply this, via wm_crew_agent_name.
#
# Round-2 review addendum (PR #348): the original version of this file had
# two must-fix gaps the reviewer found by mutation testing - reverting the
# fix under test and confirming the suite still passed 14/14 either way.
# Both are closed here the same way, verified with the identical technique
# before this file was finalized:
#   - Case B alone (a clean, non-busy submit) cannot distinguish a genuine
#     composer-region confirm from the pre-existing whole-pane-checksum
#     fallback - both return rc 0, since ANY registered submit changes the
#     pane. The busy/swallow cases below close this: only a real
#     composer-region check can correctly refuse to confirm a message that
#     never actually cleared, on a pane that is independently repainting for
#     an unrelated reason (issue #188's own original motivation).
#   - The "opening objective landed in the pane" check alone cannot prove
#     spawn-crew's own $3 threading specifically, since the stub writes its
#     SUBMITTED marker independent of what wm_tmux_send_message's own return
#     code ends up being. Reading spawn-crew's own confirm-or-queue outcome
#     (its stderr warning and outbox side effect) closes this instead.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$TEST_REPO/bin/lib/common.sh"
. "$TEST_REPO/bin/lib/agent.sh"
test_new_home

STUB="$TEST_REPO/tests/fixtures/composer-stub-pi.sh"
export WM_SUBMIT_DELAY=0.3 WM_READY_POLL=0.3 WM_SUBMIT_POLL=0.4 WM_READY_TRIES=20 WM_SUBMIT_TRIES=5

# --- wm_crew_agent_name itself -------------------------------------------
add_crew_record() {
  if [ -n "${2:-}" ]; then
    wm_state crew-add --id "$1" --type developer --objective x --repo /tmp --window "wm-$1" --session-id "s-$1" --agent "$2" >/dev/null
  else
    wm_state crew-add --id "$1" --type developer --objective x --repo /tmp --window "wm-$1" --session-id "s-$1" >/dev/null
  fi
}
add_crew_record agent-lookup-pi pi
add_crew_record agent-lookup-claude claude
add_crew_record agent-lookup-default
assert_eq "wm_crew_agent_name returns the recorded pi agent" "$(wm_crew_agent_name agent-lookup-pi)" "pi"
assert_eq "wm_crew_agent_name returns the recorded claude agent" "$(wm_crew_agent_name agent-lookup-claude)" "claude"
assert_eq "wm_crew_agent_name defaults to claude when the field is absent" "$(wm_crew_agent_name agent-lookup-default)" "claude"
assert_eq "wm_crew_agent_name defaults to claude for an unknown id" "$(wm_crew_agent_name no-such-crew-member-xyz)" "claude"

# --- case A: pre-fix caller shape (no agent threaded) still misclassifies ----
SESS_A="$WM_TMUX_SESSION-composer-scope-a"
wm_track_tmux "$SESS_A"
MARKER_A="$(wm_mktemp_file)"
: > "$MARKER_A"
tmux new-session -d -s "$SESS_A" -n box "WM_TEST_MARKER='$MARKER_A' bash '$STUB'"
sleep 1
wm_tmux_send_message "$SESS_A:box" "hello-pi-unthreaded"
rc_a=$?
assert_eq "unthreaded call against a pi-shaped pane submits the text" "$(grep -c SUBMITTED "$MARKER_A")" "1"
# rc 5, not rc 3: composer mode engages (claude's ambient rule/anchor match
# far enough to recognize a region), the pane visibly changes the instant
# Enter clears the composer (tripping the confirm loop's sticky-busy flag on
# its very first poll), but wm_composer_is_empty never reports true - pi's
# emptied content row is "", never claude's "❯"+NBSP - so the loop exhausts
# without ever confirming, landing on the busy variant of "unconfirmed."
assert_true "but never confirms - composer mode engaged via claude's ambient anchor, which pi's content row never matches (rc 5, unconfirmed-and-busy)" "[ '$rc_a' -eq 5 ]"

# --- direct mechanism check: pi's real anchor is recognized as empty --------
# Timing-independent, ahead of the live tmux case below: proves the schema
# addition itself (WM_AGENT_COMPOSER_ANCHOR_EMPTY) does what it claims,
# rather than relying solely on an rc that a busy/checksum path could also
# produce. Not subshelled - assert_eq/assert_true's pass/fail counters are
# plain globals (tests/lib.sh) that a subshell would silently fail to
# propagate back - so WM_COMPOSER_ANCHOR is saved/restored by hand instead.
_saved_composer_anchor="$WM_COMPOSER_ANCHOR"
wm_agent_resolve pi
assert_eq "pi's descriptor declares its real, live-verified empty anchor" "$WM_AGENT_COMPOSER_ANCHOR_EMPTY" "1"
WM_COMPOSER_ANCHOR="$WM_AGENT_COMPOSER_ANCHOR"
assert_true "wm_composer_is_empty recognizes pi's genuinely-blank emptied composer row" "wm_composer_is_empty ''"
WM_COMPOSER_ANCHOR="$_saved_composer_anchor"

# --- adjacent-rule-lines edge case (round-2 review nice-to-have) -------------
# Two rule lines with NO content line between them at all must read as "not
# recognized" (rc 1), never as "recognized, empty region" (rc 0 printing
# nothing) - the two cases used to be conflated (bin/lib/common.sh's old
# `[ start -le end ] && print; return 0` unconditionally returned 0). This
# is a real behavior change on that degenerate render for EVERY adapter,
# claude included (round-3 review: the busy-pane refusal, rc 6, no longer
# fires and composer mode no longer engages there either) - not merely a
# claude-specific no-op, even though that render has never actually been
# observed for claude, whose composer always carries its own anchor row
# between the rules. What the fix is actually FOR: pi's own anchor is now
# genuinely the empty string, so this same degenerate render would
# otherwise byte-match it and produce a false "confirmed" without ever
# having inspected a real content line. Not observed against a real pi pane
# either (hardening, not a reproduced failure) - this is a direct, timing-
# independent check of the fixed function itself.
_rule_line="$(_x=0; while [ "$_x" -lt "$WM_COMPOSER_RULE_MIN" ]; do printf '%s' "$WM_COMPOSER_RULE_CHAR"; _x=$((_x+1)); done)"
_adjacent_pane="$(printf 'some preceding transcript line\n%s\n%s\n' "$_rule_line" "$_rule_line")"
_adjacent_out="$(wm_composer_text_in "$_adjacent_pane")"
_adjacent_rc=$?
assert_eq "adjacent rule lines (no content line between them) are 'not recognized', not 'recognized empty'" "$_adjacent_rc" "1"
assert_eq "...and nothing is printed either way" "$_adjacent_out" ""

# --- case B: "pi" threaded as $3 engages REAL composer-mode confirm ---------
SESS_B="$WM_TMUX_SESSION-composer-scope-b"
wm_track_tmux "$SESS_B"
MARKER_B="$(wm_mktemp_file)"
: > "$MARKER_B"
tmux new-session -d -s "$SESS_B" -n box "WM_TEST_MARKER='$MARKER_B' bash '$STUB'"
sleep 1
wm_tmux_send_message "$SESS_B:box" "hello-pi-threaded" "pi"
rc_b=$?
assert_eq "threaded call against the identical pi-shaped pane also submits the text" "$(grep -c SUBMITTED "$MARKER_B")" "1"
assert_eq "and confirms immediately - composer mode now genuinely recognizes pi's own empty anchor (rc 0)" "$rc_b" "0"

# --- cases D and E: the discriminator round-2 review demanded -----------------
# On a genuine, non-busy submit (case B above), a real composer-region
# confirm and the pre-existing whole-pane-checksum fallback both return rc 0
# against this stub - a clean submit always changes SOME pane byte, so rc
# alone can't tell them apart (round-2 review, verified by reverting
# WM_AGENT_COMPOSER_ANCHOR_EMPTY's consumption and observing this file still
# passed 14/14). The two mechanisms only diverge on a BUSY pane whose
# composer never actually clears: the checksum fallback sees ANY pane change
# (an independent busy-tick line, here) and confirms regardless, while a
# real composer-region check must keep reading the composer's own extracted
# content as still-pending and refuse to confirm - this is issue #188's own
# original motivation for composer mode existing at all, now proven for
# pi's own anchor specifically rather than merely inferred from claude's.
SESS_D="$WM_TMUX_SESSION-composer-scope-c1"
wm_track_tmux "$SESS_D"
MARKER_D="$(wm_mktemp_file)"
: > "$MARKER_D"
tmux new-session -d -s "$SESS_D" -n box "WM_TEST_MARKER='$MARKER_D' WM_TEST_BUSY=1 WM_TEST_SWALLOW=1 WM_TEST_TICK=1.0 bash '$STUB'"
sleep 1
wm_tmux_send_message "$SESS_D:box" "hello-pi-busy-swallowed" "pi"
rc_d=$?
assert_eq "a busy, swallowing pi pane never actually submits" "$(grep -c SUBMITTED "$MARKER_D")" "0"
assert_true "and the REAL composer-region check (pi's live-verified anchor) correctly never confirms it either, despite the pane visibly repainting on its own busy clock (rc 5, never rc 0)" "[ '$rc_d' -eq 5 ]"

# The SAME busy/swallowing pane, but with composer mode forced OFF
# (WM_COMPOSER_TAIL=0 - exactly what the per-adapter swap's "not yet
# characterized" branch sets, i.e. what pi's descriptor did before this
# stage's live anchor capture) - this is the whole-pane-checksum fallback
# path in isolation, proving it WOULD have falsely confirmed the identical
# never-submitted message, which is exactly why closing the anchor gap for
# real (rather than leaving the fallback as pi's permanent answer) is a
# genuine correctness improvement, not merely a nice-to-have.
SESS_E="$WM_TMUX_SESSION-composer-scope-c2"
wm_track_tmux "$SESS_E"
MARKER_E="$(wm_mktemp_file)"
: > "$MARKER_E"
tmux new-session -d -s "$SESS_E" -n box "WM_TEST_MARKER='$MARKER_E' WM_TEST_BUSY=1 WM_TEST_SWALLOW=1 WM_TEST_TICK=1.0 bash '$STUB'"
sleep 1
_saved_tail="$WM_COMPOSER_TAIL"
WM_COMPOSER_TAIL=0
wm_tmux_send_message "$SESS_E:box" "hello-pi-busy-swallowed-fallback-only"
rc_e=$?
WM_COMPOSER_TAIL="$_saved_tail"
assert_eq "the identical busy, swallowing pane still never actually submits" "$(grep -c SUBMITTED "$MARKER_E")" "0"
assert_true "but the whole-pane-checksum fallback alone (composer mode forced off) falsely confirms it anyway, on the busy tick alone (rc 0) - the exact false positive closing the anchor gap prevents" "[ '$rc_e' -eq 0 ]"

# --- real callers now supply the agent name end-to-end -----------------------
# crew-say: spawn a stub-agent pi crew member for real, then confirm crew-say's
# own send resolves and threads "pi" (observable the same way case B is: a
# pi-shaped pane confirms on the first poll instead of exhausting to rc 3).
WS="$(wm_mktemp_dir)/workspace"
mkdir -p "$WS/repoA"
git -C "$WS/repoA" init -q
cat > "$WS/pi-stub.sh" <<STUBEOF
#!/usr/bin/env bash
WM_TEST_MARKER="$WS/pi-crew.marker" exec bash "$STUB"
STUBEOF
chmod +x "$WS/pi-stub.sh"
: > "$WS/pi-crew.marker"

export WM_AGENT_BIN_OVERRIDE="$WS/pi-stub.sh" WM_SPAWN_DELAY=0 WM_SUBMIT_DELAY=0.3 WM_READY_TRIES=20 WM_READY_POLL=0.3 \
  WM_SUBMIT_POLL=0.4 WM_SUBMIT_TRIES=5
wm_trust_repo "$WS/repoA"
SPAWN_STDERR="$(wm_mktemp_file)"
pid="$("$TEST_REPO/bin/spawn-crew" --type software-analyst --repo "$WS/repoA" --agent pi --objective "composer scoping crew-say check" 2>"$SPAWN_STDERR" | tail -1)"
assert_true "a pi-adapter spawn (stubbed binary) succeeds" "[ -n '$pid' ]"
# The opening objective landing in the pane (round-2 review, MF2): the
# keystrokes reach the pane on BOTH a threaded and an unthreaded send
# (SUBMITTED alone proves nothing about which anchor confirmed it - the
# stub writes it the instant it sees Enter, independent of what
# wm_tmux_send_message's own return code ends up being), so this alone was
# never a real guard on spawn-crew:595's own threading. What IS a real
# guard: spawn-crew's own confirm-or-queue branch reads that return code
# directly - if $AGENT were dropped from that call, composer mode would
# still engage (claude's ambient rule matches pi's rule character by the
# same coincidence as case A above) but never confirm via claude's wrong
# anchor, landing spawn-crew on its own "NOT confirmed delivered" warning
# and outbox-queue path. Asserting neither fired is what actually depends
# on $AGENT reaching that call.
assert_true "the opening objective landed in the pane" "grep -q 'SUBMITTED:1:' '$WS/pi-crew.marker'"
assert_not_contains "and spawn-crew's own confirm check (which depends on \$AGENT reaching wm_tmux_send_message) never falls back to its NOT-confirmed warning" \
  "$(cat "$SPAWN_STDERR")" "NOT confirmed delivered"
assert_eq "...nor does it fall back to queuing the objective for watcher retry" \
  "$(ls "$WINGMAN_HOME/outbox/$pid" 2>/dev/null | grep -c .)" "0"

: > "$WS/pi-crew.marker"
"$TEST_REPO/bin/crew-say" "$pid" "follow-up via crew-say" >/dev/null 2>&1
say_rc=$?
assert_eq "crew-say against the live pi crew member exits 0 (confirmed delivery, not queued)" "$say_rc" "0"
assert_true "and the pi-shaped pane actually received it" "grep -q 'SUBMITTED:.*follow-up via crew-say' '$WS/pi-crew.marker'"

test_summary
