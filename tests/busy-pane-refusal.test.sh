#!/usr/bin/env bash
# E2E: issue #214 - a blind C-c clear-keystroke aborts a crew member's
# in-flight tool call. wm_tmux_pane_ready now returns 6 (busy) for a pane
# that never settles, and _wm_tmux_send_message_locked's busy branch (§3.4)
# suppresses the clear-keystroke rather than refusing the whole send: the
# text and Enter are safe against a genuinely busy pane (they queue behind
# the current turn), only the C-c can abort an in-flight tool call.
#
# Built on tests/composer-confirm-delivery.test.sh's stub shape (a real
# in-place redraw with an independent busy clock and the verified composer
# rules), extended here with a side-channel Ctrl-C marker and a simulated
# in-flight "tool" (a background sleep whose pid the stub tracks) so a test
# can assert the keystroke never arrives and, when it doesn't, that the tool
# would not have been interrupted.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
test_new_home
# Sourced AFTER test_new_home - see the identical comment in
# tests/outbox-abandonment.test.sh for why the order matters here: common.sh
# computes WM_HOME from WINGMAN_HOME at SOURCE time, and case 9 below calls
# wm_outbox_try_redeliver (a WM_HOME-touching helper) directly in this
# process, not only through a crew-say subprocess - sourcing common.sh first
# would freeze WM_HOME at its real, non-isolated default.
. "$TEST_REPO/bin/lib/common.sh"

MARKER="$(wm_mktemp_file)"

dashes() { _n="$1"; _s=""; _i=0; while [ "$_i" -lt "$_n" ]; do _s="${_s}─"; _i=$((_i+1)); done; printf '%s' "$_s"; }

# BUSY_STUB: the composer-confirm-delivery shape (leading-dash-run rules, the
# "❯"+NBSP anchor), extended with:
#   WM_TEST_PRESET   - initial composer content (simulates a composer that
#                      already holds unsubmitted text before this call starts).
#   WM_TEST_TOOL_PIDFILE - if set, a background `sleep 300` is spawned at
#                      startup and its pid written there; a real in-flight
#                      tool call stand-in, killed only if Ctrl-C arrives while
#                      WM_TEST_BUSY=1 (mirroring a real turn-active pane,
#                      where Ctrl-C is a live interrupt, not a composer clear).
#   Every Ctrl-C received is recorded to the marker as "CTRLC", regardless of
#   whether it goes on to kill the tool - so a test can assert on the
#   keystroke arriving at all, not just its simulated side effect.
BUSY_STUB="$(wm_mktemp_dir)/busy-refusal-stub.sh"
cat > "$BUSY_STUB" <<'STUBEOF'
#!/usr/bin/env bash
stty -echo -icanon intr undef min 0 time 3 2>/dev/null
busy="${WM_TEST_BUSY:-0}"
swallow="${WM_TEST_SWALLOW:-0}"
marker="${WM_TEST_MARKER:?WM_TEST_MARKER required}"
buf="${WM_TEST_PRESET:-}"
submitted=0
tick=0

if [ -n "${WM_TEST_TOOL_PIDFILE:-}" ]; then
  sleep 300 &
  echo $! > "$WM_TEST_TOOL_PIDFILE"
fi

dashes() { _n="$1"; _s=""; _i=0; while [ "$_i" -lt "$_n" ]; do _s="${_s}─"; _i=$((_i+1)); done; printf '%s' "$_s"; }
D33="$(dashes 33)"
D80="$(dashes 80)"

draw() {
  printf '\033[2J\033[H'
  _footer=5
  _extra=0
  [ "$busy" = 1 ] && _extra=1
  _pad=$((24 - _footer - _extra))
  _p=0
  while [ "$_p" -lt "$_pad" ]; do printf '\n'; _p=$((_p+1)); done
  if [ "$busy" = 1 ]; then
    tick=$((tick+1))
    printf 'working... tick=%d\n' "$tick"
  fi
  printf '%s window %s\n' "$D33" "$D33"
  printf '\xe2\x9d\xaf\xc2\xa0%s\n' "$buf"
  printf '%s\n' "$D80"
  printf '/rc\n'
  printf 'bypass permissions status'
}

draw

while :; do
  IFS= read -r -n1 -t "${WM_TEST_TICK:-0.3}" ch
  rc=$?
  if [ "$rc" != 0 ]; then
    [ "$busy" = 1 ] && draw
    continue
  fi
  case "$ch" in
    ""|$'\r'|$'\n')
      printf 'ENTER\n' >> "$marker"
      if [ "$swallow" != 1 ]; then
        submitted=$((submitted+1))
        printf 'SUBMITTED:%d:%s\n' "$submitted" "$buf" >> "$marker"
        buf=""
      fi
      draw
      ;;
    $'\003')
      printf 'CTRLC\n' >> "$marker"
      if [ "$busy" = 1 ] && [ -n "${WM_TEST_TOOL_PIDFILE:-}" ] && [ -f "$WM_TEST_TOOL_PIDFILE" ]; then
        kill "$(cat "$WM_TEST_TOOL_PIDFILE")" 2>/dev/null
      fi
      buf=""
      draw
      ;;
    *) buf="$buf$ch"; draw ;;
  esac
done
STUBEOF
chmod +x "$BUSY_STUB"

# DIALOG_BUSY_STUB: a pane that never settles (a ticking line redraws every
# cycle) AND whose tail renders a real permission-dialog shape throughout -
# proves the dialog re-check (§3.4) survives the busy branch rather than
# being skipped just because the pane never settled.
DIALOG_BUSY_STUB="$(wm_mktemp_dir)/busy-dialog-stub.sh"
cat > "$DIALOG_BUSY_STUB" <<'STUBEOF'
#!/usr/bin/env bash
stty -echo -icanon min 0 time 3 2>/dev/null
tick=0
draw() {
  printf '\033[2J\033[H'
  tick=$((tick+1))
  printf 'working... tick=%d\n' "$tick"
  printf 'Do you want to run reboot now?\n'
  printf '\xe2\x9d\xaf 1. Yes\n'
  printf '  2. No, and tell it what to do differently\n'
}
draw
while :; do
  IFS= read -r -n1 -t "${WM_TEST_TICK:-0.2}"
  draw
done
STUBEOF
chmod +x "$DIALOG_BUSY_STUB"

# PLAIN_STUB: tests/submit-delivery.test.sh's own stub, byte-for-byte -
# raw mode, silent while typing, never repaints on its own - the shape that
# routes through the pre-#188 whole-pane-checksum fallback rather than
# composer mode. Extended with the same CTRLC marker logging.
PLAIN_STUB="$(wm_mktemp_dir)/plain-stub.sh"
cat > "$PLAIN_STUB" <<'PLAINEOF'
#!/usr/bin/env bash
stty -echo -icanon intr undef min 1 time 0 2>/dev/null
swallow="${WM_TEST_SWALLOW:-0}"
marker="${WM_TEST_MARKER:?WM_TEST_MARKER required}"
printf 'PROMPT READY\n'
buf=""
while IFS= read -r -n1 ch; do
  case "$ch" in
    ""|$'\r'|$'\n')
      if [ "$swallow" -gt 0 ]; then swallow=$((swallow-1)); continue; fi
      printf 'SUBMITTED:%s\n' "$buf"; buf="" ;;
    $'\003') printf 'CTRLC\n' >> "$marker"; buf="" ;;
    *) buf="$buf$ch" ;;
  esac
done
PLAINEOF
chmod +x "$PLAIN_STUB"

# Fast, deterministic polling, matching composer-confirm-delivery.test.sh's
# own settings: WM_READY_QUIET stays at its 1.5s default, so at
# WM_READY_POLL=0.3 the derived capture count (_pr_need) is 6 - a busy pane
# that repaints every poll (WM_TEST_TICK=0.3, the default) never reaches 6
# consecutive identical captures and reliably returns 6 (busy) inside the
# WM_READY_TRIES=20 budget (6s).
export WM_SUBMIT_DELAY=0.3 WM_READY_POLL=0.3 WM_SUBMIT_POLL=0.4 WM_READY_TRIES=20 WM_SUBMIT_TRIES=8

SESS1="$WM_TMUX_SESSION-bpr-1"
SESS2="$WM_TMUX_SESSION-bpr-2"
SESS3="$WM_TMUX_SESSION-bpr-3"
SESS4="$WM_TMUX_SESSION-bpr-4"
SESS5="$WM_TMUX_SESSION-bpr-5"
SESS6="$WM_TMUX_SESSION-bpr-6"
SESS7="$WM_TMUX_SESSION-bpr-7"
SESS10="$WM_TMUX_SESSION-bpr-10"
SESS11="$WM_TMUX_SESSION-bpr-11"
for s in "$SESS1" "$SESS2" "$SESS3" "$SESS4" "$SESS5" "$SESS6" "$SESS7" "$SESS10" "$SESS11"; do
  wm_track_tmux "$s"
done

# --- case 1: busy pane, composer empty -> delivered, keystroke suppressed ---
: > "$MARKER"
TOOLPID1="$(wm_mktemp_file)"
tmux new-session -d -s "$SESS1" -n box \
  "WM_TEST_BUSY=1 WM_TEST_SWALLOW=0 WM_TEST_MARKER='$MARKER' WM_TEST_TOOL_PIDFILE='$TOOLPID1' bash '$BUSY_STUB'"
sleep 1
wm_tmux_send_message "$SESS1:box" "case1-busy-empty-composer"
rc1=$?
assert_true "case 1: busy+empty composer delivers or queues (rc 0 or 5)" "[ $rc1 -eq 0 ] || [ $rc1 -eq 5 ]"
assert_eq "case 1: the clear-keystroke never reaches the pane" "$(grep -c CTRLC "$MARKER")" "0"
assert_true "case 1: the simulated in-flight tool is still running afterwards" \
  "kill -0 \"\$(cat "$TOOLPID1")\" 2>/dev/null"
kill "$(cat "$TOOLPID1")" 2>/dev/null
tmux kill-session -t "$SESS1" 2>/dev/null

# --- case 2: busy pane, composer already pending -> rc 6, nothing typed ----
: > "$MARKER"
tmux new-session -d -s "$SESS2" -n box \
  "WM_TEST_BUSY=1 WM_TEST_SWALLOW=0 WM_TEST_PRESET='pre-existing-unsubmitted-text' WM_TEST_MARKER='$MARKER' bash '$BUSY_STUB'"
sleep 1
wm_tmux_send_message "$SESS2:box" "case2-should-never-be-typed"
rc2=$?
assert_eq "case 2: busy+pending composer refuses with rc 6" "$rc2" "6"
assert_eq "case 2: no clear-keystroke was sent" "$(grep -c CTRLC "$MARKER")" "0"
assert_eq "case 2: nothing was ever submitted" "$(grep -c SUBMITTED "$MARKER")" "0"
pane2="$(tmux capture-pane -p -t "$SESS2:box")"
assert_contains "case 2: the pre-existing composer text is untouched" "$pane2" "pre-existing-unsubmitted-text"
assert_false "case 2: the new message was never typed into the composer" \
  "printf '%s' \"$pane2\" | grep -q 'case2-should-never-be-typed'"
tmux kill-session -t "$SESS2" 2>/dev/null

# --- case 3: busy pane rendering a dialog shape -> rc 2, not 6 -------------
: > "$MARKER"
tmux new-session -d -s "$SESS3" -n box "WM_TEST_MARKER='$MARKER' bash '$DIALOG_BUSY_STUB'"
sleep 1
wm_tmux_send_message "$SESS3:box" "case3-must-be-refused"
rc3=$?
assert_eq "case 3: a busy dialog-shaped pane still refuses via the dialog check (rc 2, not 6)" "$rc3" "2"
tmux kill-session -t "$SESS3" 2>/dev/null

# --- case 4: idle pane, composer empty -> rc 0, no clear-keystroke ---------
: > "$MARKER"
tmux new-session -d -s "$SESS4" -n box \
  "WM_TEST_BUSY=0 WM_TEST_SWALLOW=0 WM_TEST_MARKER='$MARKER' bash '$BUSY_STUB'"
sleep 1
wm_tmux_send_message "$SESS4:box" "case4-idle-empty"
rc4=$?
assert_eq "case 4: idle+empty composer delivers (rc 0)" "$rc4" "0"
assert_eq "case 4: nothing to clear, so no clear-keystroke is sent" "$(grep -c CTRLC "$MARKER")" "0"
tmux kill-session -t "$SESS4" 2>/dev/null

# --- case 5: idle pane, composer pending -> rc 0, clear-keystroke IS sent --
: > "$MARKER"
tmux new-session -d -s "$SESS5" -n box \
  "WM_TEST_BUSY=0 WM_TEST_SWALLOW=0 WM_TEST_PRESET='stray-leftover-text' WM_TEST_MARKER='$MARKER' bash '$BUSY_STUB'"
sleep 1
wm_tmux_send_message "$SESS5:box" "case5-fresh-message"
rc5=$?
assert_eq "case 5: idle+pending composer still delivers (rc 0)" "$rc5" "0"
assert_true "case 5: the clear-keystroke is sent (something to clear)" "[ $(grep -c CTRLC "$MARKER") -ge 1 ]"
assert_eq "case 5: the delivered message is not concatenated with the pre-existing text" \
  "$(grep -c '^SUBMITTED:1:case5-fresh-message$' "$MARKER")" "1"
tmux kill-session -t "$SESS5" 2>/dev/null

# --- case 6: idle pane, unrecognized composer -> rc 0, clear-keystroke sent
# (today's behaviour for a non-Claude-Code harness, unchanged) ---------------
: > "$MARKER"
tmux new-session -d -s "$SESS6" -n box "WM_TEST_SWALLOW=0 WM_TEST_MARKER='$MARKER' bash '$PLAIN_STUB'"
sleep 1
wm_tmux_send_message "$SESS6:box" "case6-plain-fallback"
rc6=$?
assert_eq "case 6: an unrecognized composer still confirms via the pre-#188 fallback (rc 0)" "$rc6" "0"
assert_true "case 6: the clear-keystroke is still sent for an unrecognized composer" "[ $(grep -c CTRLC "$MARKER") -ge 1 ]"
tmux kill-session -t "$SESS6" 2>/dev/null

# --- case 7: a pane that aliases quiet for a while, then keeps repainting --
# never crosses the full WM_READY_QUIET window, so it is never misread idle -
# the invariant §3.5 depends on. WM_TEST_TICK=1.2s is comfortably under the
# 1.8s (6 x WM_READY_POLL=0.3) actually required to confirm idle here, so the
# longest run of identical captures this can ever produce (~4) still falls
# short of _pr_need (6): the gate must never fire the clear-keystroke off a
# near-miss alias.
: > "$MARKER"
tmux new-session -d -s "$SESS7" -n box \
  "WM_TEST_BUSY=1 WM_TEST_SWALLOW=0 WM_TEST_TICK=1.2 WM_TEST_MARKER='$MARKER' bash '$BUSY_STUB'"
sleep 1
wm_tmux_send_message "$SESS7:box" "case7-near-miss-alias"
rc7=$?
assert_true "case 7: a near-miss alias resolves to busy or a suppressed delivery, never a refusal on the keystroke path" \
  "[ $rc7 -eq 0 ] || [ $rc7 -eq 5 ] || [ $rc7 -eq 6 ]"
assert_eq "case 7: the clear-keystroke never fires off a near-miss alias" "$(grep -c CTRLC "$MARKER")" "0"
tmux kill-session -t "$SESS7" 2>/dev/null

# --- case 8: bin/crew-say against case 2's busy+pending fixture ------------
# A separate "_wm_idle" window keeps the session alive across case 9's
# kill-window/new-window swap below (killing a session's only remaining
# window destroys the session itself).
: > "$MARKER"
wm_state crew-add --id busy2 --type developer --objective x --repo /tmp \
  --window "wm-busy2" --session-id sbusy2 >/dev/null
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_TARGET:" -n wm-busy2 \
  "WM_TEST_BUSY=1 WM_TEST_SWALLOW=0 WM_TEST_PRESET='already-typing' WM_TEST_MARKER='$MARKER' bash '$BUSY_STUB'"
sleep 1
out8="$("$TEST_REPO/bin/crew-say" busy2 "do not lose this mid-turn message" 2>&1)"; rc8=$?
assert_true "case 8: crew-say exits nonzero against a busy pane with a pending composer" "[ $rc8 -ne 0 ]"
assert_contains "case 8: crew-say names the pending composer / mid-turn state" "$out8" "mid-turn"
assert_false "case 8: crew-say never reuses the dialog wording for this refusal" \
  "printf '%s' \"$out8\" | grep -qi 'dialog'"
q8="$(ls "$WINGMAN_HOME/outbox/busy2" 2>/dev/null | grep -v '^sent-' | head -1)"
assert_true "case 8: the message landed in the outbox, not dropped" "[ -n \"$q8\" ]"
assert_contains "case 8: the queued file carries the exact message" \
  "$(cat "$WINGMAN_HOME/outbox/busy2/$q8" 2>/dev/null)" "do not lose this mid-turn message"

# --- case 9: the queued message drains once the pane goes idle -------------
# Kill the busy fixture and replace it with an idle one under the SAME
# window name, then let wm_outbox_try_redeliver take its normal path.
tmux kill-window -t "$WM_TMUX_TARGET:wm-busy2" 2>/dev/null
tmux new-window -d -t "$WM_TMUX_TARGET:" -n wm-busy2 \
  "WM_TEST_BUSY=0 WM_TEST_SWALLOW=0 WM_TEST_MARKER='$MARKER' bash '$BUSY_STUB'"
sleep 1
wm_outbox_try_redeliver busy2 "$(wm_tmux_win_target wm-busy2)" 1
q9="$(ls "$WINGMAN_HOME/outbox/busy2" 2>/dev/null | grep -v '^sent-' | head -1)"
assert_true "case 9: the queued message drained once the pane went idle" "[ -z \"$q9\" ]"
assert_true "case 9: the file was moved to sent-, not deleted" \
  "[ -n \"$(ls "$WINGMAN_HOME/outbox/busy2" 2>/dev/null | grep '^sent-')\" ]"
tmux kill-window -t "$WM_TMUX_TARGET:wm-busy2" 2>/dev/null

# --- case 10: a second mid-turn delivery against the CLI's own post-queue --
# composer state ("Press up to edit queued messages", §1.5/§5.1). Rendered
# here as busy+pending (the composer's own rule shape, holding that exact
# hint text) - one concrete, deterministic reading of "whichever way the
# composer classifies it": recognized-and-pending reads exactly like case 2,
# so the outcome is refuse-and-queue (rc 6), never a keystroke.
: > "$MARKER"
tmux new-session -d -s "$SESS10" -n box \
  "WM_TEST_BUSY=1 WM_TEST_SWALLOW=0 WM_TEST_PRESET='Press up to edit queued messages' WM_TEST_MARKER='$MARKER' bash '$BUSY_STUB'"
sleep 1
wm_tmux_send_message "$SESS10:box" "case10-second-midturn-message"
rc10=$?
assert_true "case 10: the CLI's own post-queue composer state resolves safely (rc 6 here)" "[ $rc10 -eq 6 ]"
assert_eq "case 10: no clear-keystroke fires against the post-queue composer state" "$(grep -c CTRLC "$MARKER")" "0"
tmux kill-session -t "$SESS10" 2>/dev/null

# --- case 11: busy + pending, caller passes WM_CLEAR_KEYS="" (the ----------
# spawn-crew/crew-resume shape, issue #157) -> rc 6, nothing typed. The one
# path row 8 of §3.7 relies on: no existing suite exercised it before this.
: > "$MARKER"
tmux new-session -d -s "$SESS11" -n box \
  "WM_TEST_BUSY=1 WM_TEST_SWALLOW=0 WM_TEST_PRESET='already-composed' WM_TEST_MARKER='$MARKER' bash '$BUSY_STUB'"
sleep 1
WM_CLEAR_KEYS="" wm_tmux_send_message "$SESS11:box" "case11-opening-objective"
rc11=$?
assert_eq "case 11: WM_CLEAR_KEYS=\"\" against a busy+pending pane still refuses with rc 6" "$rc11" "6"
assert_eq "case 11: nothing was typed" "$(grep -c SUBMITTED "$MARKER")" "0"
tmux kill-session -t "$SESS11" 2>/dev/null

tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

test_summary
