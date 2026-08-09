#!/usr/bin/env bash
# E2E: issue #188 - wm_tmux_send_message must confirm a submit on the
# composer's OWN content going empty, not on any whole-pane byte change. On a
# BUSY target (a Claude Code pane mid-turn, repainting on its own clock - the
# elapsed-time line, streaming tokens) the whole pane changes on the very
# first poll after Enter regardless of whether Enter itself registered, so
# tests/submit-delivery.test.sh's plain stub (silent while typing, never
# redraws on its own) cannot reproduce the false-positive this file exists to
# close - it never repaints unprompted. The composer stub below does: a real
# in-place screen redraw (clear+home, like the actual CLI's own TUI), the
# verified shape from bin/lib/common.sh's wm_composer_text_in doc comment
# (leading-dash-run rules, an embedded label on the top one, the "❯"+NBSP
# anchor, no vertical border glyphs), with an independent busy/repaint clock
# and an optional Enter-swallow, so both the detector and the confirm loop's
# sticky-busy behavior get exercised against the real detector, not a proxy.
#
# issue #281: a case's final rc alone is not proof it exercised composer
# mode - cases 1, 2, 4, and 5 assert an rc that the pre-#188
# whole-pane-checksum fallback can also produce, so a regression that
# silently stopped composer mode from engaging in the stub would not fail
# any of those cases on rc alone. Cases 1-5 each also assert
# wm_composer_text_in recognized the final capture (case 3's rc 5 already
# implies this; asserted anyway for explicit, mechanically-checked
# symmetry), closing that gap directly rather than only inferring it from a
# byte comparison done once, by hand.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$TEST_REPO/bin/lib/common.sh"
test_new_home

MARKER="$(wm_mktemp_file)"

# The composer stub was extracted to tests/fixtures/composer-stub.sh (issue
# #236) so other E2E suites can drive the same real composer shape.
STUB="$TEST_REPO/tests/fixtures/composer-stub.sh"

# tests/submit-delivery.test.sh's own stub, byte-for-byte: raw mode, silent
# while typing (never redraws), so it can never repaint unprompted - the
# shape that proves the OPPOSITE side of #188's fix, that a target whose
# capture never shows composer rules at all still falls through to the
# pre-existing whole-pane-checksum behavior, unchanged.
PLAIN_STUB="$(wm_mktemp_dir)/plain-stub.sh"
cat > "$PLAIN_STUB" <<'PLAINEOF'
#!/usr/bin/env bash
stty -echo -icanon intr undef min 1 time 0 2>/dev/null
swallow="${WM_TEST_SWALLOW:-0}"
printf 'PROMPT READY\n'
buf=""
while IFS= read -r -n1 ch; do
  case "$ch" in
    ""|$'\r'|$'\n')
      if [ "$swallow" -gt 0 ]; then swallow=$((swallow-1)); continue; fi
      printf 'SUBMITTED:%s\n' "$buf"; buf="" ;;
    $'\003') buf="" ;;
    *) buf="$buf$ch" ;;
  esac
done
PLAINEOF
chmod +x "$PLAIN_STUB"

# Fast, deterministic polling. WM_SUBMIT_DELAY is nonzero here (unlike
# submit-delivery.test.sh's 0) because the composer stub above visibly
# redraws on every keystroke (a real composer's live echo) - some settle
# time must elapse after typing so the "composed" snapshot this whole
# detector keys off of captures the fully-typed state, not an in-flight
# partial one; 0.3s is generous margin for a `send-keys -l` burst a raw-mode
# read loop drains in microseconds.
export WM_SUBMIT_DELAY=0.3 WM_READY_POLL=0.3 WM_SUBMIT_POLL=0.4 WM_READY_TRIES=20 WM_SUBMIT_TRIES=8

# Each case below gets its OWN session name (never a shared/reused one, even
# across a kill+recreate cycle): tmux's own teardown of a killed session is
# not synchronous with the kill-session call returning, so a same-named
# recreate immediately after can race a still-dying server-side session
# object - observed directly while developing this file as a multi-minute
# stall inside a later case's send-lock wait. A distinct name per case
# removes that race outright rather than adding a settle sleep to paper over
# it. Every name is still derived from $WM_TMUX_SESSION, satisfying
# tests/run.sh's static invariant check.
SESS1="$WM_TMUX_SESSION-composer-1"
SESS2="$WM_TMUX_SESSION-composer-2"
SESS3="$WM_TMUX_SESSION-composer-3"
SESS4="$WM_TMUX_SESSION-composer-4"
SESS5="$WM_TMUX_SESSION-composer-5"
SESS6A="$WM_TMUX_SESSION-composer-6a"
SESS6B="$WM_TMUX_SESSION-composer-6b"
SESS6C="$WM_TMUX_SESSION-composer-6c"
wm_track_tmux "$SESS1"
wm_track_tmux "$SESS2"
wm_track_tmux "$SESS3"
wm_track_tmux "$SESS4"
wm_track_tmux "$SESS5"
wm_track_tmux "$SESS6A"
wm_track_tmux "$SESS6B"
wm_track_tmux "$SESS6C"

# --- case 1: idle pane, confirmed delivery (BUSY=0 SWALLOW=0) -----------------
# Existing behavior preserved: rc 0, exactly one submit.
: > "$MARKER"
tmux new-session -d -s "$SESS1" -n box "WM_TEST_BUSY=0 WM_TEST_SWALLOW=0 WM_TEST_MARKER='$MARKER' bash '$STUB'"
sleep 1
wm_tmux_send_message "$SESS1:box" "hello-idle-confirmed"
rc1=$?
assert_eq "idle confirmed delivery returns rc 0" "$rc1" "0"
assert_eq "exactly one submit registered" "$(grep -c SUBMITTED "$MARKER")" "1"
_c1_pane="$(wm_tmux_pane_text "$SESS1:box")"
wm_composer_text_in "$_c1_pane" >/dev/null; _c1_rc=$?
assert_eq "idle confirmed delivery recognized composer mode, not a coincidental fallback rc (issue #281)" \
  "$_c1_rc" "0"
_c1_region="$(wm_composer_text_in "$_c1_pane")"
assert_true "idle confirmed delivery's composer reads empty post-submit" \
  "wm_composer_is_empty \"$_c1_region\""
tmux kill-session -t "$SESS1" 2>/dev/null

# --- case 2: busy pane, Enter registered (BUSY=1 SWALLOW=0) -------------------
# The composer goes empty even though the rest of the pane also keeps
# changing every poll (the independent tick): rc 0, resolved on the poll
# where the composer clears, not the full try budget.
: > "$MARKER"
tmux new-session -d -s "$SESS2" -n box "WM_TEST_BUSY=1 WM_TEST_SWALLOW=0 WM_TEST_MARKER='$MARKER' bash '$STUB'"
sleep 1
wm_tmux_send_message "$SESS2:box" "hello-busy-registered"
rc2=$?
assert_eq "busy pane with a registered Enter returns rc 0" "$rc2" "0"
assert_eq "resolved on the poll the composer cleared, not the full try budget (Enter sent once)" \
  "$(grep -c ENTER "$MARKER")" "1"
_c2_pane="$(wm_tmux_pane_text "$SESS2:box")"
wm_composer_text_in "$_c2_pane" >/dev/null; _c2_rc=$?
assert_eq "busy registered delivery recognized composer mode, not a coincidental fallback rc (issue #281)" \
  "$_c2_rc" "0"
_c2_region="$(wm_composer_text_in "$_c2_pane")"
assert_true "busy registered delivery's composer reads empty post-submit" \
  "wm_composer_is_empty \"$_c2_region\""
tmux kill-session -t "$SESS2" 2>/dev/null

# --- case 3: busy pane, Enter swallowed/queued (BUSY=1 SWALLOW=1) -------------
# Must NOT return 0: rc 5, composer still pending. Enter sent at most once -
# a deterministic guarantee now that sticky-busy (Approach step 3) lands.
# WM_TEST_TICK=1.0 (slower than WM_SUBMIT_POLL=0.4) forces some polls to
# coincidentally read byte-identical to their predecessor (the same ~1Hz
# tick vs sub-second poll aliasing review round 1 derived analytically),
# specifically to prove stickiness holds through that coincidence rather
# than only through a stub that never aliases.
: > "$MARKER"
tmux new-session -d -s "$SESS3" -n box \
  "WM_TEST_BUSY=1 WM_TEST_SWALLOW=1 WM_TEST_MARKER='$MARKER' WM_TEST_TICK=1.0 bash '$STUB'"
sleep 1
wm_tmux_send_message "$SESS3:box" "do-not-lose-me"
rc3=$?
assert_eq "busy pane with a queued/unregistered Enter returns rc 5" "$rc3" "5"
assert_eq "Enter is sent at most once (sticky-busy survives an aliased poll)" \
  "$(grep -c ENTER "$MARKER")" "1"
assert_eq "nothing was ever actually submitted" "$(grep -c SUBMITTED "$MARKER")" "0"
_c3_pane="$(wm_tmux_pane_text "$SESS3:box")"
wm_composer_text_in "$_c3_pane" >/dev/null; _c3_rc=$?
assert_eq "busy swallowed delivery recognized composer mode, not a coincidental fallback rc (issue #281)" \
  "$_c3_rc" "0"
_c3_region="$(wm_composer_text_in "$_c3_pane")"
assert_false "busy swallowed delivery's composer still holds the unsubmitted text" \
  "wm_composer_is_empty \"$_c3_region\""
tmux kill-session -t "$SESS3" 2>/dev/null

# --- case 4: idle pane, genuine swallow (BUSY=0 SWALLOW=1) --------------------
# The rc 3 path still works: composer never goes empty, pane otherwise never
# changes either, rc 3 after exhausting WM_SUBMIT_TRIES, and - unlike case 3
# - Enter WAS retried up to the try budget, preserving today's
# startup-swallow recovery behavior for a genuinely idle target.
: > "$MARKER"
tmux new-session -d -s "$SESS4" -n box "WM_TEST_BUSY=0 WM_TEST_SWALLOW=1 WM_TEST_MARKER='$MARKER' bash '$STUB'"
sleep 1
wm_tmux_send_message "$SESS4:box" "idle-genuine-swallow"
rc4=$?
assert_eq "idle genuine swallow returns rc 3" "$rc4" "3"
assert_eq "Enter retried up to the full try budget (1 initial + WM_SUBMIT_TRIES retries)" \
  "$(grep -c ENTER "$MARKER")" "9"
_c4_pane="$(wm_tmux_pane_text "$SESS4:box")"
wm_composer_text_in "$_c4_pane" >/dev/null; _c4_rc=$?
assert_eq "idle genuine swallow recognized composer mode, not a coincidental fallback rc (issue #281)" \
  "$_c4_rc" "0"
_c4_region="$(wm_composer_text_in "$_c4_pane")"
assert_false "idle genuine swallow's composer still holds the unsubmitted text" \
  "wm_composer_is_empty \"$_c4_region\""
tmux kill-session -t "$SESS4" 2>/dev/null

# --- case 5: a wrapping message still confirms --------------------------------
# The shape of crew-say's standard pointer (bin/crew-say:73) against an
# 80-column pane: long enough to wrap across composer rows. Empty/pending
# classification never needs to find $_text verbatim anywhere, so this
# confirms exactly like case 1 - the case the original string-match design
# (review round 1's M2) would silently have failed.
: > "$MARKER"
tmux new-session -d -s "$SESS5" -n box "WM_TEST_BUSY=0 WM_TEST_SWALLOW=0 WM_TEST_MARKER='$MARKER' bash '$STUB'"
sleep 1
WRAP_MSG="Message from wingman: read $WINGMAN_HOME/say/some-id-1234567890-99999.md and act on it now - it is a direct message to you, not background material."
wm_tmux_send_message "$SESS5:box" "$WRAP_MSG"
rc5=$?
assert_eq "a ~150-char message that wraps across composer rows still confirms (rc 0)" "$rc5" "0"
_c5_pane="$(wm_tmux_pane_text "$SESS5:box")"
wm_composer_text_in "$_c5_pane" >/dev/null; _c5_rc=$?
assert_eq "wrapping message recognized composer mode, not a coincidental fallback rc (issue #281)" \
  "$_c5_rc" "0"
_c5_region="$(wm_composer_text_in "$_c5_pane")"
assert_true "wrapping message's composer reads empty post-submit" \
  "wm_composer_is_empty \"$_c5_region\""
tmux kill-session -t "$SESS5" 2>/dev/null

# --- case 6: unrecognized composer routes to the pre-#188 fallback ------------
# Positive proof, not merely "the old suite stays green": wm_composer_text_in
# itself returns not-recognized against the plain stub's capture, AND the
# whole-pane-checksum fallback still resolves it correctly on both ends (rc 0
# on a registered submit, rc 3 on exhaustion).
tmux new-session -d -s "$SESS6A" -n box "WM_TEST_SWALLOW=0 bash '$PLAIN_STUB'"
sleep 1
tmux send-keys -t "$SESS6A:box" -l "probe-text"
sleep 0.3
plain_pane="$(wm_tmux_pane_text "$SESS6A:box")"
# Asserts the exact documented rc (1), not merely "nonzero" - a bare `if
# wm_composer_text_in ...; then fail; else ok; fi` would pass vacuously for
# ANY nonzero exit, including the function not existing at all (a future
# rename/typo would print "command not found", exit 127, and still read as
# "correctly not recognized").
wm_composer_text_in "$plain_pane" >/dev/null; _c6a_rc=$?
assert_eq "wm_composer_text_in returns not-recognized (1) for the plain, non-boxed stub's capture" "$_c6a_rc" "1"
tmux kill-session -t "$SESS6A" 2>/dev/null

tmux new-session -d -s "$SESS6B" -n box "WM_TEST_SWALLOW=0 bash '$PLAIN_STUB'"
sleep 1
wm_tmux_send_message "$SESS6B:box" "fallback-registered"
rc6a=$?
assert_eq "fallback mode still confirms a registered submit (rc 0)" "$rc6a" "0"
tmux kill-session -t "$SESS6B" 2>/dev/null

tmux new-session -d -s "$SESS6C" -n box "WM_TEST_SWALLOW=99 bash '$PLAIN_STUB'"
sleep 1
wm_tmux_send_message "$SESS6C:box" "fallback-exhausted"
rc6b=$?
assert_eq "fallback mode returns rc 3 on exhaustion - rc 5 is only reachable via composer mode" "$rc6b" "3"
tmux kill-session -t "$SESS6C" 2>/dev/null

# --- case 7: crew-say caller-level regression against case 3's stub ----------
# Approach step 5's "queue on rc 5 exactly as on rc 2/3/4" design: crew-say
# exits nonzero, the message IS queued under outbox/<id>/, and the failure
# message is legible about the pane being busy/unconfirmed.
wm_state crew-add --id busy1 --type developer --objective x --repo /tmp \
  --window "wm-busy1" --session-id sbusy1 >/dev/null
tmux new-session -d -s "$WM_TMUX_SESSION" -n wm-busy1 \
  "WM_TEST_BUSY=1 WM_TEST_SWALLOW=1 WM_TEST_MARKER='$MARKER' bash '$STUB'"
sleep 1
out7="$("$TEST_REPO/bin/crew-say" busy1 "do not lose this busy message" 2>&1)"; rc7=$?
assert_true "crew-say exits nonzero against a busy, unconfirmed pane" "[ $rc7 -ne 0 ]"
assert_contains "crew-say's failure message is legible about the pane being busy" "$out7" "busy"
assert_contains "crew-say never claims delivery" "$out7" "unconfirmed"
_q7="$(ls "$WINGMAN_HOME/outbox/busy1" 2>/dev/null | grep -v '^sent-' | head -1)"
assert_true "the message landed in the outbox, not dropped" "[ -n \"$_q7\" ]"
assert_contains "the queued file carries the exact message" \
  "$(cat "$WINGMAN_HOME/outbox/busy1/$_q7" 2>/dev/null)" "do not lose this busy message"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

test_summary
