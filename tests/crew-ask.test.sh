#!/usr/bin/env bash
# E2E: the crew-ask request/response channel end-to-end, over a real (isolated)
# tmux session. Proves: send mints a request and frames the delegate; the await
# watcher BLOCKS while the request is pending and fires `answered` the instant the
# delegate replies; a no-reply request times out with `unanswered`; a delegate that
# vanishes yields `undeliverable`; an oversized answer is rejected; a spoofed
# responder is refused; and concurrent asks stay independent.
#
# The delegate windows run `sleep` (the framed keystrokes land harmlessly in them);
# the delegate's reply is exercised by invoking `crew-ask reply` with the delegate's
# own $WINGMAN_CREW_ID - exactly the command a real delegate runs. Every blocking
# await is bounded by wm_timeout and every backgrounded one is reaped on exit, so a
# watcher that fails to fire can never wedge this file or the whole suite.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ASK="$TEST_REPO/bin/crew-ask"
# Fast, deterministic tmux delivery against a sleeping pane, and a snappy watcher.
export WM_ASK_WATCH_INTERVAL=1
export WM_SUBMIT_DELAY=0 WM_SUBMIT_TRIES=1 WM_SUBMIT_POLL=0.2
export WM_READY_TRIES=1 WM_READY_POLL=0
trap wm_kill_tracked EXIT

# Extract the "request <req>" id from a send's output.
req_of() { printf '%s\n' "$1" | sed -n 's/.*request \(ask-[a-z0-9]*\).*/\1/p' | head -1; }

start_session() {
  tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
}
add_delegate_window() {
  tmux new-window -d -t "$WM_TMUX_SESSION" -n "wm-$1" 'sleep 300'
}

# --- happy path: await blocks while pending, fires answered on the reply --------
test_new_home
start_session
add_delegate_window wkr
send="$(WINGMAN_CREW_ID=lead "$ASK" wkr "did the public signature of foo change? y/n" 2>&1)"
assert_contains "send reports the ask" "$send" "asked wkr"
req="$(req_of "$send")"
assert_true "send minted a request id" "[ -n '$req' ]"
assert_contains "the request record is pending" "$(wm_state ask-get --id "$req")" '"status": "pending"'

# Arm the blocking await; it must keep blocking while the request is pending.
"$ASK" await --id "$req" >"$WINGMAN_HOME/await.log" 2>&1 &
apid=$!
wm_track "$apid"
sleep 3
assert_true "await keeps blocking while the request is pending" "kill -0 $apid"

# The delegate replies (the exact command a real delegate runs).
WINGMAN_CREW_ID=wkr "$ASK" reply --id "$req" --answer "no; foo is unchanged" >/dev/null 2>&1
i=0; while kill -0 "$apid" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 1; i=$((i+1)); done
assert_false "await exits once the answer lands" "kill -0 $apid"
alog="$(cat "$WINGMAN_HOME/await.log")"
assert_contains "await fires the answered event" "$alog" "answered: $req no; foo is unchanged"
assert_contains "await marks it a captured reply, not roster status" "$alog" "not a crew status event"
assert_contains "the record is now answered" "$(wm_state ask-get --id "$req")" '"status": "answered"'
kill "$apid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- --once: nothing while pending, the answer once it lands -------------------
test_new_home
start_session
add_delegate_window wkr
req="$(req_of "$(WINGMAN_CREW_ID=lead "$ASK" wkr "q2" 2>&1)")"
assert_eq "await --once prints nothing while pending" "$("$ASK" await --id "$req" --once 2>/dev/null)" ""
WINGMAN_CREW_ID=wkr "$ASK" reply --id "$req" --answer "the answer" >/dev/null 2>&1
assert_contains "await --once prints the answer once it lands" "$("$ASK" await --id "$req" --once 2>/dev/null)" "answered: $req the answer"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- an --answer-file pointer is surfaced alongside the inline answer ----------
test_new_home
start_session
add_delegate_window wkr
req="$(req_of "$(WINGMAN_CREW_ID=lead "$ASK" wkr "q-detail" 2>&1)")"
detail="$WINGMAN_HOME/detail.md"; printf 'fuller detail\n' > "$detail"
WINGMAN_CREW_ID=wkr "$ASK" reply --id "$req" --answer "see the file" --answer-file "$detail" >/dev/null 2>&1
once="$("$ASK" await --id "$req" --once 2>/dev/null)"
assert_contains "answer-file is surfaced as a detail pointer" "$once" "detail: $detail"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- timeout: no reply within the window fires unanswered ----------------------
test_new_home
start_session
add_delegate_window wkr
req="$(req_of "$(WINGMAN_CREW_ID=lead "$ASK" wkr "will be ignored" 2>&1)")"
out="$(wm_timeout 30 env WM_ASK_TIMEOUT=3 WM_ASK_WATCH_INTERVAL=1 "$ASK" await --id "$req" 2>/dev/null)"
assert_contains "a no-reply request fires unanswered at timeout" "$out" "unanswered: $req"
assert_contains "the record is resolved to timeout" "$(wm_state ask-get --id "$req")" '"status": "timeout"'
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- undeliverable: the delegate vanishes before replying ----------------------
test_new_home
start_session
add_delegate_window wkr
req="$(req_of "$(WINGMAN_CREW_ID=lead "$ASK" wkr "you will die" 2>&1)")"
tmux kill-window -t "$WM_TMUX_SESSION:wm-wkr" 2>/dev/null
out="$(wm_timeout 30 "$ASK" await --id "$req" 2>/dev/null)"
assert_contains "a vanished delegate fires undeliverable" "$out" "undeliverable: $req"
assert_contains "the record is resolved to undeliverable" "$(wm_state ask-get --id "$req")" '"status": "undeliverable"'
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- oversized answer is rejected (never truncated) ----------------------------
test_new_home
start_session
add_delegate_window wkr
req="$(req_of "$(WINGMAN_CREW_ID=lead "$ASK" wkr "keep it short" 2>&1)")"
rej="$(WINGMAN_CREW_ID=wkr WM_ASK_MAX_CHARS=5 "$ASK" reply --id "$req" --answer "way too long to fit" 2>&1)"
assert_contains "an oversized answer is rejected" "$rej" "over the"
assert_contains "the request stays pending after a rejected reply" "$(wm_state ask-get --id "$req")" '"status": "pending"'
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- a spoofed responder is refused -------------------------------------------
test_new_home
start_session
add_delegate_window wkr
req="$(req_of "$(WINGMAN_CREW_ID=lead "$ASK" wkr "only wkr may answer" 2>&1)")"
spoof="$(WINGMAN_CREW_ID=someone-else "$ASK" reply --id "$req" --answer "sneaky" 2>&1)"
assert_contains "a non-addressed responder is refused" "$spoof" "not the addressed delegate"
assert_contains "the request stays pending after a spoofed reply" "$(wm_state ask-get --id "$req")" '"status": "pending"'
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- concurrent asks stay independent -----------------------------------------
test_new_home
start_session
add_delegate_window w1
add_delegate_window w2
r1="$(req_of "$(WINGMAN_CREW_ID=lead "$ASK" w1 "question one" 2>&1)")"
r2="$(req_of "$(WINGMAN_CREW_ID=lead "$ASK" w2 "question two" 2>&1)")"
assert_true "two concurrent asks get distinct request ids" "[ '$r1' != '$r2' ]"
# Answer only the first; the second must stay independently pending.
WINGMAN_CREW_ID=w1 "$ASK" reply --id "$r1" --answer "answer one" >/dev/null 2>&1
assert_contains "the answered ask surfaces its own answer" "$("$ASK" await --id "$r1" --once 2>/dev/null)" "answered: $r1 answer one"
assert_eq "the unanswered concurrent ask stays quiet" "$("$ASK" await --id "$r2" --once 2>/dev/null)" ""
assert_contains "the second request is still pending" "$(wm_state ask-get --id "$r2")" '"status": "pending"'
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

test_summary
