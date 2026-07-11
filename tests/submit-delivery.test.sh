#!/usr/bin/env bash
# E2E: robust message delivery (bin/lib/common.sh wm_tmux_send_message), the path
# both spawn-crew (opening objective) and crew-say use. Proves delivery waits for
# the TUI to settle, then confirms the submit actually registered and re-presses
# Enter when the first one is swallowed during startup - the failure that left a
# freshly spawned crew member's objective sitting unsent in the input box.
#
# Drives a real tmux pane running a stub that faithfully emulates a TUI input box:
# it puts the terminal in raw mode (no echo) so the pane changes only when the
# stub itself draws, accumulates typed characters silently (the "composed" state),
# and eats the first WM_TEST_SWALLOW submits before echoing SUBMITTED on a real one.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
# The tmux/send helpers under test live in common.sh, not lib.sh.
. "$TEST_REPO/bin/lib/common.sh"

STUB="$(mktemp -d)/tui-stub.sh"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
# Raw mode: the terminal never echoes, so the pane advances only when this stub
# prints. Characters accumulate silently in an "input box" buffer that survives a
# swallowed Enter, exactly as a real TUI holds unsent text across a startup race.
stty -echo -icanon min 1 time 0 2>/dev/null
swallow="${WM_TEST_SWALLOW:-0}"
printf 'PROMPT READY\n'
buf=""
while IFS= read -r -n1 ch; do
  case "$ch" in
    ""|$'\r'|$'\n')
      if [ "$swallow" -gt 0 ]; then swallow=$((swallow-1)); continue; fi
      printf 'SUBMITTED:%s\n' "$buf"; buf="" ;;
    *) buf="$buf$ch" ;;
  esac
done
STUBEOF
chmod +x "$STUB"

# Fast, deterministic polling so the suite stays quick.
export WM_SUBMIT_DELAY=0 WM_READY_POLL=0.3 WM_SUBMIT_POLL=0.4 WM_READY_TRIES=20 WM_SUBMIT_TRIES=8

SESS="wm-test-submit-$$-$RANDOM"
trap 'tmux kill-session -t "$SESS" 2>/dev/null' EXIT

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

test_summary
