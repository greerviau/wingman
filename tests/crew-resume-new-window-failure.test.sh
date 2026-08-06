#!/usr/bin/env bash
# E2E: issue #179 - bin/crew-resume's relaunch also calls `tmux new-window`
# with no success check. Unlike spawn-crew, this does NOT read back as a
# false "resumed" success - resume_one()'s own later "verify the resume
# actually took" check (wm_tmux_windows) already catches a missing window
# and correctly leaves status at `died`. What the missing check still
# causes, uncaught: the resume nudge's full send/poll budget is spent
# probing a pane that was never created, an undeliverable nudge is queued
# into the outbox (eventually swept as abandoned, but pure noise until
# then), and the reported diagnosis names the wrong failure mode ("window
# vanished" implies one was created and disappeared; none was ever
# created). This test pins the two directly observable, deterministic
# symptoms: the diagnostic message and the outbox file.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

CR="$TEST_REPO/bin/crew-resume"
export WM_SUBMIT_DELAY=0 WM_READY_POLL=0.2 WM_SUBMIT_POLL=0.2 WM_SUBMIT_TRIES=1

test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle

wm_state crew-add --id r179 --type developer --objective x --repo /tmp --window wm-r179 --session-id sess-r179 >/dev/null
wm_state crew-set --id r179 --status died >/dev/null

SHIM_DIR="$(wm_mktemp_dir)"
cat > "$SHIM_DIR/tmux" <<'EOF'
#!/usr/bin/env bash
REAL_TMUX="$(command -v -p tmux)"
if [ "${1:-}" = "new-window" ]; then
  echo "simulated new-window failure (test): can't find session" >&2
  exit 1
fi
exec "$REAL_TMUX" "$@"
EOF
chmod +x "$SHIM_DIR/tmux"

out="$(PATH="$SHIM_DIR:$PATH" WM_AGENT="$TEST_REPO/tests/fixtures/stub-agent.sh" "$CR" r179 2>&1)"

assert_contains "the failure message names tmux new-window as the cause, not a vanished window" \
  "$out" "tmux new-window failed"
assert_not_contains "no outbox nudge is queued for a window that was never created" \
  "$out" "resume nudge is QUEUED"
assert_false "no outbox file is left behind for the undeliverable nudge" \
  "[ -d '$WINGMAN_HOME/outbox/r179' ] && [ -n \"\$(ls -A '$WINGMAN_HOME/outbox/r179' 2>/dev/null)\" ]"
assert_eq "status stays died, never falsely flips to working" \
  "$(wm_state crew-get --id r179 | uv run --no-project --quiet python -c 'import sys,json; print(json.load(sys.stdin).get("status"))')" \
  "died"

tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null
test_summary
