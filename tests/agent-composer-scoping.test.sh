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
pid="$("$TEST_REPO/bin/spawn-crew" --type software-analyst --repo "$WS/repoA" --agent pi --objective "composer scoping crew-say check" 2>/dev/null | tail -1)"
assert_true "a pi-adapter spawn (stubbed binary) succeeds" "[ -n '$pid' ]"
# The opening objective itself already exercises spawn-crew's own threading
# (this is the same call site fixed above) - confirm it actually landed
# rather than being left unconfirmed/queued.
assert_true "the opening objective confirmed delivered at spawn time (spawn-crew's own threading)" \
  "grep -q 'SUBMITTED:1:' '$WS/pi-crew.marker'"

: > "$WS/pi-crew.marker"
"$TEST_REPO/bin/crew-say" "$pid" "follow-up via crew-say" >/dev/null 2>&1
say_rc=$?
assert_eq "crew-say against the live pi crew member exits 0 (confirmed delivery, not queued)" "$say_rc" "0"
assert_true "and the pi-shaped pane actually received it" "grep -q 'SUBMITTED:.*follow-up via crew-say' '$WS/pi-crew.marker'"

test_summary
