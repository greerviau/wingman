#!/usr/bin/env bash
# E2E: hooks/no-watcher-kill-guard.sh (issue #64). Denies kill/pkill/tmux
# kill-window/tmux kill-session commands whose target resolves to a
# currently live bin/watch-fleet cycle - reusing cycle_live()'s own two-part
# definition (pid alive via kill -0 AND beat file fresher than the grace
# window), never a bare pid-alive check, so a dead watcher's leaked pidfile
# with a later-reused pid is not falsely protected. `kill -0` (the liveness
# probe) is always allowed, and `bin/watch-fleet --stop` (the sanctioned
# manual-stop path) never appears as a kill/pkill/tmux-kill-* shape at all.
# Registered for every session - no crew-type gating - so these assertions
# run with no WINGMAN_CREW_ID set, matching how the hook actually fires.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WF="$TEST_REPO/bin/watch-fleet"
HOOK="$TEST_REPO/hooks/no-watcher-kill-guard.sh"

run_hook() {
  # run_hook <command>
  uv run --no-project --quiet python -c '
import json, sys
data = {"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}
print(json.dumps(data))
' "$1" "$TEST_REPO" | bash "$HOOK"
}

# run_hook, but executed FROM WITHIN a real tmux pane via send-keys, so the
# guard's own tmux queries (list-panes with no -t, display-message) resolve
# "current session"/"current window" against that pane's REAL $TMUX context -
# needed to test the omitted-target default correctly, which plain run_hook
# (invoked from this test process's own, unrelated tmux context) cannot
# exercise faithfully. Writes the hook's stdout to $1, waited for below via
# wait_for_file_nonempty. A wrapper script file sidesteps send-keys quoting.
run_hook_in_pane() {
  # run_hook_in_pane <target-pane> <command> <outfile>
  _rhp_script="$(wm_mktemp_file)"
  cat > "$_rhp_script" <<SCRIPT
#!/usr/bin/env bash
export WINGMAN_HOME="$WINGMAN_HOME"
uv run --no-project --quiet python -c 'import json, sys
data = {"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}
print(json.dumps(data))' "$2" "$TEST_REPO" | bash "$HOOK" > "$3" 2>&1
SCRIPT
  chmod +x "$_rhp_script"
  tmux send-keys -t "$1" "bash '$_rhp_script'" Enter
}

wait_for_file_nonempty() {
  _i=0
  while [ ! -s "$1" ] && [ "$_i" -lt 50 ]; do
    sleep 0.2
    _i=$((_i + 1))
  done
  [ -s "$1" ]
}

# Poll `bin/watch-fleet --status` (documented: exit 0 iff a cycle is live)
# rather than a fixed sleep, so this is not flaky under load.
wait_for_cycle_live() {
  _i=0
  while [ "$_i" -lt 50 ]; do
    "$WF" --status >/dev/null 2>&1 && return 0
    sleep 0.2
    _i=$((_i + 1))
  done
  return 1
}

export WM_WATCH_INTERVAL=1

# ============================================================================
# A real, live, background-armed watch-fleet cycle (scenarios 1, 2, 3, 5)
# ============================================================================
test_new_home
wm_state crew-add --id a1 --type analyst --objective x --repo /tmp --window wm-a1 --session-id s1 >/dev/null
wm_state crew-set --id a1 --status working --summary "in progress" >/dev/null
"$WF" >"$WINGMAN_HOME/out.log" 2>&1 &
wpid=$!
wm_track "$wpid"
assert_true "a real watch-fleet cycle comes up live" "wait_for_cycle_live"
pid="$(cat "$WINGMAN_HOME/watch.pid")"
assert_eq "the armed cycle's pidfile names the backgrounded process" "$pid" "$wpid"

# --- scenario 1: direct pid kill, every signal spelling, is denied ----------
out="$(run_hook "kill $pid")"
assert_contains "kill <pid> is denied" "$out" '"permissionDecision": "deny"'
assert_contains "denial cites issue #64" "$out" "issue #64"
assert_contains "denial points at bin/watch-fleet --stop instead" "$out" "bin/watch-fleet --stop"

out="$(run_hook "kill -9 $pid")"
assert_contains "kill -9 <pid> is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook "kill -TERM $pid")"
assert_contains "kill -TERM <pid> is denied" "$out" '"permissionDecision": "deny"'

# --- scenario 2: kill -0 (the liveness probe) is always allowed -------------
out="$(run_hook "kill -0 $pid")"
assert_eq "kill -0 <pid> is allowed (no output)" "$out" ""

out="$(run_hook "kill -s 0 $pid")"
assert_eq "kill -s 0 <pid> is allowed (no output)" "$out" ""

out="$(run_hook "kill -n 0 $pid")"
assert_eq "kill -n 0 <pid> is allowed (no output)" "$out" ""

# --- scenario 3: an unrelated pid is unaffected ------------------------------
sleep 60 &
unrelated=$!
wm_track "$unrelated"
out="$(run_hook "kill $unrelated")"
assert_eq "kill <unrelated pid> is allowed (no output)" "$out" ""
kill "$unrelated" 2>/dev/null

# --- scenario 5: pkill pattern matching --------------------------------------
out="$(run_hook "pkill -f watch-fleet")"
assert_contains "pkill -f watch-fleet is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook "pkill watch-fleet")"
assert_contains "bare pkill watch-fleet (no -f) is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook "pkill -f totally-unrelated-name")"
assert_eq "pkill -f <unrelated pattern> is allowed (no output)" "$out" ""

# --- scenario 9: bin/watch-fleet --stop itself is never denied by this guard,
# even while a real cycle is live ---------------------------------------------
out="$(run_hook "bin/watch-fleet --stop")"
assert_eq "bin/watch-fleet --stop is allowed (no output)" "$out" ""

# --- clean up this cycle before moving on ------------------------------------
"$WF" --stop >/dev/null 2>&1

# ============================================================================
# scenario 4: stale pidfile / reused pid is not falsely protected
# ============================================================================
test_new_home
sleep 60 &
reused=$!
wm_track "$reused"
echo "$reused" > "$WINGMAN_HOME/watch.pid"
: > "$WINGMAN_HOME/watch.beat"
wm_age_path "$WINGMAN_HOME/watch.beat" 60   # older than the default 30s grace
out="$(run_hook "kill $reused")"
assert_eq "a live-but-unrelated pid behind a stale beat file is allowed (no output)" "$out" ""
kill "$reused" 2>/dev/null

# ============================================================================
# scenario 6: tmux kill-window / tmux kill-session
# ============================================================================
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
# A tmux window's pane starts with the SERVER's own environment, not this
# shell's - WINGMAN_HOME/WM_WATCH_INTERVAL must be passed explicitly in the
# command string itself (the same reason bin/spawn-crew writes its env
# exports into a launch script rather than relying on inheritance).
tmux new-window -d -t "=$WM_TMUX_SESSION" -n watcherwin \
  "WINGMAN_HOME='$WINGMAN_HOME' WM_WATCH_INTERVAL='$WM_WATCH_INTERVAL' '$WF'"
assert_true "the tmux-hosted cycle comes up live" "wait_for_cycle_live"

out="$(run_hook "tmux kill-window -t $WM_TMUX_SESSION:watcherwin")"
assert_contains "tmux kill-window on the watcher's own window is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook "tmux kill-window -t $WM_TMUX_SESSION:_wm_idle")"
assert_eq "tmux kill-window on an unrelated window is allowed (no output)" "$out" ""

out="$(run_hook "tmux kill-session -t $WM_TMUX_SESSION")"
assert_contains "tmux kill-session on the watcher's own session is denied" "$out" '"permissionDecision": "deny"'

# An unrelated session - name embedded directly (not via an intermediate
# variable) so tests/run.sh's static "derived from $WM_TMUX_SESSION" check
# recognizes it without a separate assignment line.
tmux new-session -d -s "$WM_TMUX_SESSION-other" -n idle
wm_track_tmux "$WM_TMUX_SESSION-other"
out="$(run_hook "tmux kill-session -t $WM_TMUX_SESSION-other")"
assert_eq "tmux kill-session on an unrelated session is allowed (no output)" "$out" ""
tmux kill-session -t "=$WM_TMUX_SESSION-other" 2>/dev/null

# --- clean up this cycle + session before moving on --------------------------
"$WF" --stop >/dev/null 2>&1
tmux kill-session -t "=$WM_TMUX_SESSION" 2>/dev/null

# ============================================================================
# PR #105 review round 1 (must-fix regressions):
#
# (a) `tmux kill-session` with -t OMITTED must protect a watcher living in a
#     SIBLING window of the same session, not just the pane the command was
#     typed into - `tmux kill-session` with no -t destroys the WHOLE current
#     session. Exercised from a REAL tmux pane (via send-keys) so the guard's
#     own `tmux list-panes -s` (no -t) resolves "current session" against
#     that pane's actual $TMUX context, not this test process's own.
#
# (b) a leading tmux global flag (-L/-S/...) before the subcommand must not
#     bypass detection - `tmux -S <sock> kill-window ...` must be denied
#     exactly like the bare form.
# ============================================================================
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n typedwin
tmux new-window -d -t "=$WM_TMUX_SESSION" -n watcherwin \
  "WINGMAN_HOME='$WINGMAN_HOME' WM_WATCH_INTERVAL='$WM_WATCH_INTERVAL' '$WF'"
assert_true "the sibling-window cycle comes up live" "wait_for_cycle_live"

OMITTED_OUT="$(wm_mktemp_file)"
run_hook_in_pane "=$WM_TMUX_SESSION:typedwin" "tmux kill-session" "$OMITTED_OUT"
assert_true "the hook call typed into the sibling pane completes" "wait_for_file_nonempty '$OMITTED_OUT'"
assert_contains "bare tmux kill-session (no -t), typed in a SIBLING window, is denied" \
  "$(cat "$OMITTED_OUT" 2>/dev/null)" '"permissionDecision": "deny"'
assert_true "the watcher is still alive - only the hook ran, never a real kill-session" "wait_for_cycle_live"

SOCK="$(tmux display-message -p '#{socket_path}')"
out="$(run_hook "tmux -S $SOCK kill-window -t $WM_TMUX_SESSION:watcherwin")"
assert_contains "a global -S <socket> flag before kill-window does not bypass detection" "$out" '"permissionDecision": "deny"'

out="$(run_hook "tmux -L somesockname kill-session -t $WM_TMUX_SESSION")"
assert_contains "a global -L <name> flag before kill-session does not bypass detection" "$out" '"permissionDecision": "deny"'

out="$(run_hook "tmux -2 -q kill-window -t $WM_TMUX_SESSION:typedwin")"
assert_eq "boolean global flags before kill-window on an unrelated (real) target are allowed (no output)" "$out" ""

# --- round 2 re-review: the flag-enumeration approach missed -T/-D/-h/-N -
# detection is now anchored on the subcommand name itself (see
# tmux_kill_subcommand_index), so ANY unenumerated global flag - not just
# the specific ones a prior round happened to test - stays covered. These
# cases prove that: -T and -D are the exact flags the round-2 review used to
# reproduce a real bypass; -h/-N round out tmux's remaining global options.
out="$(run_hook "tmux -T 256,clipboard kill-window -t $WM_TMUX_SESSION:watcherwin")"
assert_contains "a global -T <features> flag before kill-window does not bypass detection" "$out" '"permissionDecision": "deny"'

out="$(run_hook "tmux -D kill-window -t $WM_TMUX_SESSION:watcherwin")"
assert_contains "a global -D flag before kill-window does not bypass detection" "$out" '"permissionDecision": "deny"'

out="$(run_hook "tmux -h kill-window -t $WM_TMUX_SESSION:watcherwin")"
assert_contains "a global -h flag before kill-window does not bypass detection" "$out" '"permissionDecision": "deny"'

out="$(run_hook "tmux -N kill-window -t $WM_TMUX_SESSION:watcherwin")"
assert_contains "a global -N flag before kill-window does not bypass detection" "$out" '"permissionDecision": "deny"'

# A genuinely unknown/future flag this hook has never heard of must ALSO stay
# covered - the whole point of anchoring on the subcommand name rather than
# an enumerated flag list.
out="$(run_hook "tmux -Z kill-window -t $WM_TMUX_SESSION:watcherwin")"
assert_contains "an unrecognized future global flag before kill-window does not bypass detection" "$out" '"permissionDecision": "deny"'

# killw (kill-window's documented alias) must be recognized too.
out="$(run_hook "tmux killw -t $WM_TMUX_SESSION:watcherwin")"
assert_contains "the killw alias is recognized the same as kill-window" "$out" '"permissionDecision": "deny"'

assert_true "the watcher is still alive after every bypass attempt above" "wait_for_cycle_live"

"$WF" --stop >/dev/null 2>&1
tmux kill-session -t "=$WM_TMUX_SESSION" 2>/dev/null

# ============================================================================
# scenario 7: a parsed-but-unlexable command fails closed
# ============================================================================
out="$(run_hook "kill 'oops")"
assert_contains "an unresolvable command mentioning kill is denied" "$out" '"permissionDecision": "deny"'
assert_contains "the parse-failure denial cites issue #56" "$out" "issue #56"

# An unrelated malformed command (no "kill" substring) never even reaches
# command_segments() - the cheap pre-gate exits 0 before any parsing runs.
out="$(run_hook "echo 'oops")"
assert_eq "an unresolvable command mentioning no trigger word is allowed (pre-gate skips it)" "$out" ""

# ============================================================================
# pgrep (read-only) must stay completely unaffected, even mentioning the
# watcher pattern - only pkill acts on a match, pgrep never sends a signal.
# ============================================================================
out="$(run_hook "pgrep -f watch-fleet")"
assert_eq "pgrep -f watch-fleet is allowed (no output) - read-only, never pkill" "$out" ""

test_summary
