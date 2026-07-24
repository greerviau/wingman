#!/usr/bin/env bash
# E2E: crew-say and crew-ask surface a dialog-shaped target pane as a refusal
# instead of guessing. Both go through the one shared tmux boundary
# (wm_tmux_send_message in lib/common.sh, exercised directly in
# submit-delivery.test.sh); this proves the two callers wire its refusal (exit
# code 2) into their own contract correctly: crew-say exits nonzero with a
# clear reason and queues the message for the watcher's retry; crew-ask queues
# its one-line pointer, keeps the request pending, and says so - neither ever
# claims delivery, and neither drops the payload.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SAY="$TEST_REPO/bin/crew-say"
ASK="$TEST_REPO/bin/crew-ask"

# A stub that faithfully emulates a real confirmation dialog: raw mode, and any
# keystroke (typed message chars, Enter) only ever accepts the highlighted option.
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
    *) : ;;
  esac
done
DIALOGEOF
chmod +x "$DIALOG_STUB"

export WM_SUBMIT_DELAY=0 WM_READY_POLL=0.3 WM_SUBMIT_POLL=0.4 WM_READY_TRIES=20 WM_SUBMIT_TRIES=8

# --- crew-say refuses instead of claiming delivery -----------------------------
test_new_home
wm_state crew-add --id d1 --type developer --objective x --repo /tmp --window wm-d1 --session-id s1 >/dev/null
tmux new-session -d -s "$WM_TMUX_SESSION" -n wm-d1 "bash '$DIALOG_STUB'"
sleep 1
out="$("$SAY" d1 "do not reboot" 2>&1)"; rc=$?
assert_true "crew-say exits nonzero on a refused delivery" "[ $rc -ne 0 ]"
assert_contains "crew-say explains the dialog refusal" "$out" "permission/confirmation dialog"
assert_contains "crew-say never claims delivery on a refusal" "$out" "refused"
# The refused message is queued for the watcher's automatic retry, not dropped.
assert_contains "crew-say says the message was queued" "$out" "QUEUED"
_q1="$(ls "$WINGMAN_HOME/outbox/d1" 2>/dev/null | grep -v '^sent-' | head -1)"
assert_true "the refused message landed in the outbox" "[ -n \"$_q1\" ]"
assert_contains "the queued file carries the exact message" \
  "$(cat "$WINGMAN_HOME/outbox/d1/$_q1" 2>/dev/null)" "do not reboot"
pane_d1="$(tmux capture-pane -p -t "$WM_TMUX_SESSION:wm-d1")"
accepted_d1="$(printf '%s\n' "$pane_d1" | grep -c 'ACCEPTED_OPTION')"
assert_eq "the dialog's default option was never accepted" "$accepted_d1" "0"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- crew-ask queues the pointer and keeps the request pending -----------------
# The pre-queue behavior (resolve undeliverable + die) discarded the question;
# now the one-line pointer is queued for the watcher's retry and the request
# stays pending so the await still has something to wait on.
test_new_home
wm_state crew-add --id d2 --type developer --objective y --repo /tmp --window wm-d2 --session-id s2 >/dev/null
tmux new-session -d -s "$WM_TMUX_SESSION" -n wm-d2 "bash '$DIALOG_STUB'"
sleep 1
out2="$("$ASK" d2 "should we reboot?" 2>&1)"; rc2=$?
assert_true "crew-ask still exits 0 (the ask is minted and queued, not dead)" "[ $rc2 -eq 0 ]"
assert_contains "crew-ask says the pointer was queued for retry" "$out2" "QUEUED"
req="$(printf '%s\n' "$out2" | grep -oE 'ask-[a-f0-9]+' | head -n1)"
assert_true "crew-ask names the request" "[ -n \"$req\" ]"
assert_contains "the ask record stays pending for the await" \
  "$(wm_state ask-get --id "$req" 2>/dev/null)" '"status": "pending"'
assert_true "the framed question was written to the prompt file" \
  "[ -s '$WINGMAN_HOME/ask/$req.prompt.md' ]"
_q2="$(ls "$WINGMAN_HOME/outbox/d2" 2>/dev/null | grep -v '^sent-' | head -1)"
assert_true "the pointer landed in the outbox" "[ -n \"$_q2\" ]"
assert_contains "the queued pointer names the prompt file" \
  "$(cat "$WINGMAN_HOME/outbox/d2/$_q2" 2>/dev/null)" "$req.prompt.md"
pane_d2="$(tmux capture-pane -p -t "$WM_TMUX_SESSION:wm-d2")"
accepted_d2="$(printf '%s\n' "$pane_d2" | grep -c 'ACCEPTED_OPTION')"
assert_eq "the dialog's default option was never accepted" "$accepted_d2" "0"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

test_summary
