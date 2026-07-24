#!/usr/bin/env bash
# E2E: the undelivered-message outbox (robustness audit finding 6) and
# crew-say's pointer-not-payload rule for multi-line/long messages (finding 5).
#
# crew-say queues a message it could not confirm delivered under
# outbox/<id>/; bin/watch-fleet retries the oldest queued message per member
# each poll once the pane is deliverable again, so a relayed answer is never
# simply dropped. A multi-line message is never typed raw into a pane at all:
# it goes to a file under say/ and only a one-line pointer is typed.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$TEST_REPO/bin/lib/common.sh"
test_new_home

SAY="$TEST_REPO/bin/crew-say"
WATCH="$TEST_REPO/bin/watch-fleet"

# The same faithful TUI-input stub submit-delivery.test.sh drives: raw mode,
# silent compose, echoes SUBMITTED:<text> on Enter.
STUB="$(wm_mktemp_dir)/tui-stub.sh"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
stty -echo -icanon intr undef min 1 time 0 2>/dev/null
printf 'PROMPT READY\n'
buf=""
while IFS= read -r -n1 ch; do
  case "$ch" in
    ""|$'\r'|$'\n') printf 'SUBMITTED:%s\n' "$buf"; buf="" ;;
    $'\003') buf="" ;;
    *) buf="$buf$ch" ;;
  esac
done
STUBEOF
chmod +x "$STUB"

export WM_SUBMIT_DELAY=0 WM_READY_POLL=0.3 WM_SUBMIT_POLL=0.4 WM_READY_TRIES=20 WM_SUBMIT_TRIES=8

# --- a multi-line crew-say goes as a file + one-line pointer ------------------
wm_state crew-add --id ml1 --type developer --objective x --repo /tmp --window wm-ml1 --session-id s1 >/dev/null
tmux new-session -d -s "$WM_TMUX_SESSION" -n wm-ml1 "bash '$STUB'"
sleep 0.5
out="$("$SAY" ml1 "line one
line two with the real payload" 2>&1)"
assert_contains "the multi-line say reports delivered" "$out" "delivered"
pane="$(wm_tmux capture-pane -p -t "$(wm_tmux_win_target wm-ml1)")"
assert_contains "the pane received a one-line pointer, not the raw payload" \
  "$pane" "read $WINGMAN_HOME/say/"
assert_not_contains "the raw multi-line payload was never typed" "$pane" "line two with the real payload"
_sayfile="$(ls "$WINGMAN_HOME/say" 2>/dev/null | head -1)"
assert_true "the payload file exists under say/" "[ -n \"$_sayfile\" ]"
assert_contains "the payload file carries the full message" \
  "$(cat "$WINGMAN_HOME/say/$_sayfile")" "line two with the real payload"

# --- a long single-line message also goes as a pointer ------------------------
long_msg="$(printf 'x%.0s' $(seq 1 600))"
out="$("$SAY" ml1 "$long_msg" 2>&1)"
assert_contains "the long say reports delivered" "$out" "delivered"
say_count="$(ls "$WINGMAN_HOME/say" | wc -l | tr -d ' ')"
assert_eq "a second payload file was written" "$say_count" "2"

# --- a short single-line message is still typed directly ----------------------
out="$("$SAY" ml1 "short direct message" 2>&1)"
assert_contains "the short say reports delivered" "$out" "delivered"
pane="$(wm_tmux capture-pane -p -t "$(wm_tmux_win_target wm-ml1)")"
assert_contains "the short message was typed raw" "$pane" "SUBMITTED:short direct message"

# --- the watcher redelivers a queued outbox message ---------------------------
# Queue a message by hand (the shape crew-say leaves on an unconfirmed
# delivery), then arm one watch-fleet cycle: its per-member pane pass must
# deliver the message and move the file to sent-.
mkdir -p "$WINGMAN_HOME/outbox/ml1"
printf 'queued answer from the human\n' > "$WINGMAN_HOME/outbox/ml1/1-queued.msg"
WM_WATCH_INTERVAL=1 "$WATCH" --owner "" >/dev/null 2>&1 &
wm_track $!
_i=0
while [ "$_i" -lt 20 ]; do
  [ -f "$WINGMAN_HOME/outbox/ml1/sent-1-queued.msg" ] && break
  sleep 0.5; _i=$((_i+1))
done
"$WATCH" --stop >/dev/null 2>&1
assert_true "the queued file moved to sent- after redelivery" \
  "[ -f '$WINGMAN_HOME/outbox/ml1/sent-1-queued.msg' ]"
pane="$(wm_tmux capture-pane -p -t "$(wm_tmux_win_target wm-ml1)")"
assert_contains "the queued message reached the pane" "$pane" "SUBMITTED:queued answer from the human"

# --- a multi-line queued message is redelivered as a pointer to its sent path -
printf 'first\nsecond line payload\n' > "$WINGMAN_HOME/outbox/ml1/2-multi.msg"
WM_WATCH_INTERVAL=1 "$WATCH" --owner "" >/dev/null 2>&1 &
wm_track $!
_i=0
while [ "$_i" -lt 20 ]; do
  [ -f "$WINGMAN_HOME/outbox/ml1/sent-2-multi.msg" ] && break
  sleep 0.5; _i=$((_i+1))
done
"$WATCH" --stop >/dev/null 2>&1
assert_true "the multi-line queued file moved to sent-" \
  "[ -f '$WINGMAN_HOME/outbox/ml1/sent-2-multi.msg' ]"
pane="$(wm_tmux capture-pane -p -t "$(wm_tmux_win_target wm-ml1)")"
assert_contains "the redelivery pointed at the sent- path, not the raw payload" \
  "$pane" "sent-2-multi.msg"
assert_not_contains "the raw multi-line payload was never typed by the watcher" \
  "$pane" "second line payload"

tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null
test_summary
