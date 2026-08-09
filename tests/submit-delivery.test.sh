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
# (Robustness audit finding 4; redesigned around a kernel flock() - issue
# #302, replacing the earlier mkdir+pid-stamp reclaim scheme of issue
# #298/#301.) A held lock makes a second sender wait; one held past
# WM_SEND_LOCK_WAIT makes it give up with rc 4 and send NOTHING. Release is
# now kernel-guaranteed rather than inferred: the flock frees the instant
# every fd on it closes, by ANY means, including an uncatchable kill -KILL -
# so there is no separate age-based/identity-verified reclaim path left to
# test; a genuinely held lock either releases (because its holder is
# genuinely gone) or it does not (because its holder is genuinely still
# running), with nothing in between for a predicate to get wrong.
tmux new-session -d -s "$SESS" -n box "WM_TEST_SWALLOW=0 bash '$STUB'"
sleep 0.5
# wm_tmux_send_message keys its lock off common.sh's $WM_HOME, which was
# snapshotted from $WINGMAN_HOME when common.sh was sourced above - BEFORE
# test_new_home re-pointed $WINGMAN_HOME at this test's isolated home. Realign
# the in-shell variable so the lock file path below matches what the helper
# actually opens, and so nothing here touches a real ~/.wingman.
WM_HOME="$WINGMAN_HOME"
_lockfile="$WM_HOME/send-$(printf '%s' "$SESS:box" | tr -c 'A-Za-z0-9._-' '_').flock"

# A real holder process: a standalone script that sources common.sh and
# calls wm_tmux_send_lock directly (so the fd is genuinely held in ITS OWN
# process, not a subshell of this test - the same precondition every real
# caller must meet). This is the only way to construct a genuinely held
# flock for testing; the old mkdir-based "pre-hold a bare directory" trick
# has no equivalent under this design; a bare `mkdir` no longer means
# anything.
_holder="$(wm_mktemp_dir)/holder.sh"
cat > "$_holder" <<HOLDEREOF
#!/usr/bin/env bash
set -u
. "$TEST_REPO/bin/lib/common.sh"
wm_tmux_send_lock "$SESS:box" || exit 9
echo "HOLDING \$\$"
while :; do sleep 0.05; done
HOLDEREOF
chmod +x "$_holder"

"$_holder" >"$WINGMAN_HOME/holder1.out" 2>&1 &
_holder1_shell_pid=$!
wm_track "$_holder1_shell_pid"
_h1_i=0
while [ "$_h1_i" -lt 50 ]; do
  grep -q "^HOLDING " "$WINGMAN_HOME/holder1.out" 2>/dev/null && break
  sleep 0.1; _h1_i=$((_h1_i+1))
done
_holder1_pid="$(awk '{print $2}' "$WINGMAN_HOME/holder1.out")"
assert_true "the holder process genuinely acquired the lock" "[ -n '$_holder1_pid' ]"

out_lock="$(WM_SEND_LOCK_WAIT=2 wm_tmux_send_message "$SESS:box" "should-not-send" 2>&1)"
lock_rc=$?
assert_eq "a contended send lock makes the sender give up with rc 4" "$lock_rc" "4"
assert_contains "the refusal names the held-by-another-delivery reason" "$out_lock" "held by another delivery"
pane_lock="$(wm_tmux capture-pane -p -t "$SESS:box")"
assert_not_contains "nothing was typed while the lock was held" "$pane_lock" "should-not-send"

# Release on a plain kill -KILL - uncatchable by any trap, so no cleanup
# code in the holder ever runs. This is the one guarantee the mkdir+pid-stamp
# scheme could never fully offer (a contender there still depended on
# noticing death via its own polling and ps-based heuristics); the kernel
# here releases the flock at the instant the holder's fd closes.
kill -KILL "$_holder1_pid" 2>/dev/null
SECONDS=0
wm_tmux_send_message "$SESS:box" "after-sigkill-release"
sigkill_rc=$?
sigkill_elapsed=$SECONDS
assert_eq "the lock releases after the holder is SIGKILLed" "$sigkill_rc" "0"
assert_true "the SIGKILL release is prompt, not a many-second wait" "[ $sigkill_elapsed -lt 10 ]"
pane_sigkill="$(wm_tmux capture-pane -p -t "$SESS:box")"
assert_contains "the message submitted after the SIGKILL release" "$pane_sigkill" "SUBMITTED:after-sigkill-release"
assert_true "the lock FILE itself is never removed by unlock - only the fd closes" "[ -e '$_lockfile' ]"
wait "$_holder1_shell_pid" 2>/dev/null

# Release on a graceful exit (no trap - default SIGTERM handling): the same
# guarantee via the ordinary path, checked from a second, independent
# holder process and confirmed on a REAL send path (through
# wm_tmux_send_message, not an isolated lock/unlock pair) - this is what
# would catch an inherited-fd leak from a child spawned inside the locked
# body, since a leaked fd would keep the flock held despite the holder
# itself having exited.
"$_holder" >"$WINGMAN_HOME/holder2.out" 2>&1 &
_holder2_shell_pid=$!
wm_track "$_holder2_shell_pid"
_h2_i=0
while [ "$_h2_i" -lt 50 ]; do
  grep -q "^HOLDING " "$WINGMAN_HOME/holder2.out" 2>/dev/null && break
  sleep 0.1; _h2_i=$((_h2_i+1))
done
_holder2_pid="$(awk '{print $2}' "$WINGMAN_HOME/holder2.out")"
assert_true "the second holder process genuinely acquired the lock" "[ -n '$_holder2_pid' ]"
kill -TERM "$_holder2_pid" 2>/dev/null
SECONDS=0
wm_tmux_send_message "$SESS:box" "after-graceful-release"
graceful_rc=$?
graceful_elapsed=$SECONDS
assert_eq "the lock releases after the holder exits gracefully" "$graceful_rc" "0"
assert_true "the graceful release is prompt" "[ $graceful_elapsed -lt 10 ]"
pane_graceful="$(wm_tmux capture-pane -p -t "$SESS:box")"
assert_contains "the message submitted after the graceful release" "$pane_graceful" "SUBMITTED:after-graceful-release"
wait "$_holder2_shell_pid" 2>/dev/null

tmux kill-session -t "$SESS" 2>/dev/null

# --- the reentrant-acquisition guard (issue #302) ------------------------
# No call site is meant to ever hold two targets' locks at once; a future
# violation must be refused loudly (rc 8) rather than silently reassigning
# the reserved fd out from under the first acquire. Called directly in this
# shell (never a subshell) so the fd genuinely lands here.
tmux new-session -d -s "$SESS" -n box "WM_TEST_SWALLOW=0 bash '$STUB'"
sleep 0.5
first_acquire_rc=0
wm_tmux_send_lock "$SESS:box" || first_acquire_rc=$?
assert_eq "the first acquisition in this shell succeeds" "$first_acquire_rc" "0"
second_acquire_rc=0
wm_tmux_send_lock "$SESS:other-box" || second_acquire_rc=$?
assert_eq "a reentrant acquisition while fd 200 is already held refuses with rc 8" "$second_acquire_rc" "8"
wm_tmux_send_unlock "$SESS:box"
# A subsequent, non-reentrant acquisition succeeds normally once the first
# is released, proving the guard is a targeted refusal, not a permanently
# wedged fd.
third_acquire_rc=0
wm_tmux_send_lock "$SESS:other-box" || third_acquire_rc=$?
assert_eq "acquisition succeeds again once the first lock is released" "$third_acquire_rc" "0"
wm_tmux_send_unlock "$SESS:other-box"
tmux kill-session -t "$SESS" 2>/dev/null

# --- the flock helper's own hard-failure path (issue #302) ----------------
# A distinct outcome from ordinary contention (rc 4): if the helper itself
# cannot run (a broken 'uv'/python/fcntl toolchain), the caller must be told
# that plainly (rc 7) rather than reading it as "someone else is holding the
# pane, retry shortly" - the two warrant very different operator responses.
# Simulated by pointing WM_UV at a command that always fails, standing in
# for a genuinely broken toolchain without needing to actually break uv.
tmux new-session -d -s "$SESS" -n box "WM_TEST_SWALLOW=0 bash '$STUB'"
sleep 0.5
out_helper_fail="$(WM_UV=false wm_tmux_send_message "$SESS:box" "should-not-send-helper-fail" 2>&1)"
helper_fail_rc=$?
assert_eq "a broken lock helper returns rc 7, not rc 4" "$helper_fail_rc" "7"
assert_contains "the refusal names it as a helper failure, not contention" "$out_helper_fail" "helper failed unexpectedly"
assert_not_contains "the helper-failure refusal does NOT claim ordinary contention" "$out_helper_fail" "held by another delivery"
pane_helper_fail="$(wm_tmux capture-pane -p -t "$SESS:box")"
assert_not_contains "nothing was typed when the helper itself failed" "$pane_helper_fail" "should-not-send-helper-fail"
tmux kill-session -t "$SESS" 2>/dev/null

test_summary
