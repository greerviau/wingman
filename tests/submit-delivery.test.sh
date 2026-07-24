#!/usr/bin/env bash
# E2E: robust message delivery (bin/lib/common.sh wm_tmux_send_message), the path
# both spawn-crew (opening objective) and crew-say/crew-ask use. Proves delivery
# waits for the TUI to settle, then confirms the submit actually registered and
# re-presses Enter when the first one is swallowed during startup - the failure
# that left a freshly spawned crew member's objective sitting unsent in the input
# box. Also proves the delivery-safety gap is closed: a target pane that is
# byte-stable but showing a permission/confirmation dialog (not a chat input) is
# refused rather than typed/Entered into, since a frozen dialog is exactly as
# stable as an idle chat prompt and blind Enters land as "accept" on it.
#
# Drives a real tmux pane running a stub that faithfully emulates a TUI input box:
# it puts the terminal in raw mode (no echo) so the pane changes only when the
# stub itself draws, accumulates typed characters silently (the "composed" state),
# and eats the first WM_TEST_SWALLOW submits before echoing SUBMITTED on a real one.
# The dialog case below drives a second stub that instead emulates a real
# confirmation dialog, where every keystroke only ever accepts its highlighted
# option.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
# The tmux/send helpers under test live in common.sh, not lib.sh. Call
# test_new_home immediately after sourcing it (before this file mints
# anything of its own) so $WM_TMUX_SESSION carries this run's token before
# common.sh's own WM_TMUX_SESSION="${WM_TMUX_SESSION:-wingman}" default could
# otherwise take effect, and so SESS below can be derived from it.
. "$TEST_REPO/bin/lib/common.sh"
test_new_home

STUB="$(wm_mktemp_dir)/tui-stub.sh"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
# Raw mode: the terminal never echoes, so the pane advances only when this stub
# prints. Characters accumulate silently in an "input box" buffer that survives a
# swallowed Enter, exactly as a real TUI holds unsent text across a startup race.
# "intr undef" keeps a raw Ctrl-C byte flowing to this loop as ordinary input
# instead of raising SIGINT against the stub itself (plain "-isig" alone was not
# enough to suppress it under tmux in testing), matching a real composer that
# treats Ctrl-C as "clear the box" rather than killing the process.
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
STUBEOF
chmod +x "$STUB"

# Fast, deterministic polling so the suite stays quick.
export WM_SUBMIT_DELAY=0 WM_READY_POLL=0.3 WM_SUBMIT_POLL=0.4 WM_READY_TRIES=20 WM_SUBMIT_TRIES=8

SESS="$WM_TMUX_SESSION-submit"
wm_track_tmux "$SESS"

# --- a swallowed first Enter is recovered by the confirm-and-retry loop -------
tmux new-session -d -s "$SESS" -n box "WM_TEST_SWALLOW=1 bash '$STUB'"
wm_tmux_send_message "$SESS:box" "hello-objective"
pane="$(wm_tmux capture-pane -p -t "$SESS:box")"
assert_contains "message submits despite a swallowed first Enter" "$pane" "SUBMITTED:hello-objective"
tmux kill-session -t "$SESS" 2>/dev/null

# --- the happy path (nothing swallowed) submits on the first Enter ------------
tmux new-session -d -s "$SESS" -n box "WM_TEST_SWALLOW=0 bash '$STUB'"
wm_tmux_send_message "$SESS:box" "ready-objective"
pane2="$(wm_tmux capture-pane -p -t "$SESS:box")"
assert_contains "message submits on a ready session" "$pane2" "SUBMITTED:ready-objective"
# Exactly one submission - the retry never double-submits a message that already took.
count="$(printf '%s\n' "$pane2" | grep -c 'SUBMITTED:')"
assert_eq "a successful submit is not repeated" "$count" "1"
tmux kill-session -t "$SESS" 2>/dev/null

# --- pre-existing unsubmitted text in the composer is cleared, not appended ---
# The composer can already hold unsubmitted text (e.g. left over from a direct
# Remote Control interaction, or any other stray typing) before
# wm_tmux_send_message ever runs. Without a defensive clear, the -l keystroke
# below would land after that stray text and submit one concatenated, garbled
# message instead of replacing it (issue #157's secondary observation).
tmux new-session -d -s "$SESS" -n box "WM_TEST_SWALLOW=0 bash '$STUB'"
sleep 0.5
tmux send-keys -t "$SESS:box" -l "pre-existing stray text"
sleep 0.3
wm_tmux_send_message "$SESS:box" "fresh-objective"
pane3="$(wm_tmux capture-pane -p -t "$SESS:box")"
assert_contains "the new message submits cleanly" "$pane3" "SUBMITTED:fresh-objective"
assert_not_contains "the stray pre-existing text is not concatenated into the submit" "$pane3" "pre-existing stray textfresh-objective"
count3="$(printf '%s\n' "$pane3" | grep -c 'SUBMITTED:')"
assert_eq "exactly one submission" "$count3" "1"
tmux kill-session -t "$SESS" 2>/dev/null

# --- a target pane showing a permission/confirmation dialog is refused --------
# The near-miss this whole detector exists for: a "do not reboot" crew-say landed
# as an accepted reboot confirmation instead of reaching the chat input, because
# a frozen dialog is just as byte-stable as an idle chat prompt. This stub emulates
# that dialog faithfully - raw mode, and ANY keystroke (including our typed message
# and Enter) only ever "accepts" the highlighted option; nothing is ever treated as
# chat text. wm_tmux_send_message must detect the dialog shape and refuse (return
# 2) rather than type into it and press Enter.
DIALOG_STUB="$(wm_mktemp_dir)/dialog-stub.sh"
cat > "$DIALOG_STUB" <<'DIALOGEOF'
#!/usr/bin/env bash
stty -echo -icanon min 1 time 0 2>/dev/null
printf 'Do you want to run reboot now?\n'
printf '\xe2\x9d\xaf 1. Yes\n'
printf '  2. No, and tell it what to do differently\n'
while IFS= read -r -n1 ch; do
  case "$ch" in
    ""|$'\r'|$'\n') printf 'ACCEPTED_OPTION:1\n' ;;
    *) : ;;  # any other keystroke (typed message chars) is swallowed by the dialog
  esac
done
DIALOGEOF
chmod +x "$DIALOG_STUB"

tmux new-session -d -s "$SESS" -n box "bash '$DIALOG_STUB'"
sleep 1
wm_tmux_send_message "$SESS:box" "do not reboot"
dialog_rc=$?
assert_eq "delivery into a dialog-shaped pane is refused" "$dialog_rc" "2"
dialog_pane="$(wm_tmux capture-pane -p -t "$SESS:box")"
accepted_count="$(printf '%s\n' "$dialog_pane" | grep -c 'ACCEPTED_OPTION')"
assert_eq "the dialog's default option was never accepted by our Enter" "$accepted_count" "0"
typed_count="$(printf '%s\n' "$dialog_pane" | grep -c 'do not reboot')"
assert_eq "the message text never landed in the pane" "$typed_count" "0"
tmux kill-session -t "$SESS" 2>/dev/null

# --- an exhausted, never-confirmed submit returns 3, not 0 --------------------
# A stub that swallows EVERY Enter: the text types, Enter never registers, the
# pane never advances past its composed snapshot. Previously this best-effort
# path returned 0, indistinguishable from a confirmed delivery, so callers
# reported "delivered" for a submit that probably never landed (robustness
# audit finding 7).
tmux new-session -d -s "$SESS" -n box "WM_TEST_SWALLOW=99 bash '$STUB'"
wm_tmux_send_message "$SESS:box" "never-confirms"
unconfirmed_rc=$?
assert_eq "an exhausted unconfirmed submit returns 3" "$unconfirmed_rc" "3"
tmux kill-session -t "$SESS" 2>/dev/null

# --- deliveries to one pane are serialized by a per-pane send lock ------------
# (Robustness audit finding 4.) A held lock makes a second sender wait; one
# held past WM_SEND_LOCK_WAIT makes it give up with rc 4 and send NOTHING; a
# stale lock (older than WM_SEND_LOCK_STALE - a crashed holder) is reclaimed
# and delivery proceeds.
tmux new-session -d -s "$SESS" -n box "WM_TEST_SWALLOW=0 bash '$STUB'"
sleep 0.5
# wm_tmux_send_message keys its lock off common.sh's $WM_HOME, which was
# snapshotted from $WINGMAN_HOME when common.sh was sourced above - BEFORE
# test_new_home re-pointed $WINGMAN_HOME at this test's isolated home. Realign
# the in-shell variable so the lock we pre-create is the one the helper sees,
# and so nothing here touches a real ~/.wingman.
WM_HOME="$WINGMAN_HOME"
_lock="$WM_HOME/send-$(printf '%s' "$SESS:box" | tr -c 'A-Za-z0-9._-' '_').lock"
mkdir -p "$_lock"   # a live holder's lock, fresh mtime
out_lock="$(WM_SEND_LOCK_WAIT=2 wm_tmux_send_message "$SESS:box" "should-not-send" 2>&1)"
lock_rc=$?
assert_eq "a contended send lock makes the sender give up with rc 4" "$lock_rc" "4"
pane_lock="$(wm_tmux capture-pane -p -t "$SESS:box")"
assert_not_contains "nothing was typed while the lock was held" "$pane_lock" "should-not-send"

# Stale-holder reclaim: age the same lock past WM_SEND_LOCK_STALE and the next
# delivery reclaims it and goes through.
wm_age_path "$_lock" 300
WM_SEND_LOCK_STALE=120 wm_tmux_send_message "$SESS:box" "after-reclaim"
reclaim_rc=$?
assert_eq "a stale lock is reclaimed and delivery proceeds" "$reclaim_rc" "0"
pane_reclaim="$(wm_tmux capture-pane -p -t "$SESS:box")"
assert_contains "the message submitted after the reclaim" "$pane_reclaim" "SUBMITTED:after-reclaim"
assert_true "the lock is released after delivery" "[ ! -d '$_lock' ]"
tmux kill-session -t "$SESS" 2>/dev/null

test_summary
