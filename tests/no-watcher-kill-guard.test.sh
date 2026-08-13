#!/usr/bin/env bash
# E2E: hooks/no-watcher-kill-guard.sh (issue #64). Denies kill/pkill/tmux
# kill-window/tmux kill-session commands whose target resolves to a
# currently live bin/watch-fleet cycle - reusing bin/watch-fleet's own
# owner_lock_alive() identity check (pid alive via kill -0 AND a matching
# process start-time stamp - issue #237), never a bare pid-alive check, so a
# dead watcher's leaked lock with a later-reused pid is not falsely
# protected. Protection also requires the beacon to be fresher than
# WM_WATCH_HARD_GRACE (default 300s, mirroring cycle_healthy()): a cycle
# wedged beyond that is no longer protected, since bin/watch-fleet's own
# singleton guard is by then entitled to take it over. `kill -0` (the
# liveness probe) is always allowed, and `bin/watch-fleet --stop` (the
# sanctioned manual-stop path) never appears as a kill/pkill/tmux-kill-*
# shape at all. Registered for every session - no crew-type gating - so
# these assertions run with no WINGMAN_CREW_ID set, matching how the hook
# actually fires.
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
# a1 is backed by a real tmux window (issue #209): the cycle armed below runs a
# real reconcile now that it no longer skips merely because the crew session is
# absent, so a LIVE_STATES fixture with no matching window would flip to 'died'
# (and the watcher would fire and exit) before this block's guard scenarios run.
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-a1 'sleep 600'
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
assert_contains "denial names the liveness rationale" "$out" "its liveness is the only channel"
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

# --- scenario 10 (issue #168): a wrapped kill is caught exactly like the
# unwrapped form, and a wrapped liveness probe / the sanctioned stop command
# stay allowed -----------------------------------------------------------
out="$(run_hook "bash -c \"kill $pid\"")"
assert_contains "bash -c \"kill <pid>\" is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook "eval \"kill $pid\"")"
assert_contains "eval \"kill <pid>\" is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook "bash -c \"kill -0 $pid\"")"
assert_eq "bash -c \"kill -0 <pid>\" is allowed (no output)" "$out" ""

out="$(run_hook 'bash -c "bin/watch-fleet --stop"')"
assert_eq "bash -c \"bin/watch-fleet --stop\" is allowed (no output)" "$out" ""

# --- clean up this cycle before moving on ------------------------------------
"$WF" --stop >/dev/null 2>&1

# ============================================================================
# scenario 4: a reused pid is not falsely protected (issue #237:
# protected_pids() requires the SAME pid+start-time identity
# owner_lock_alive() itself requires, never a bare pid-alive check - a reused
# pid after e.g. a host reboot carries a mismatched start-time stamp and is
# never mistaken for the true owner)
# ============================================================================
test_new_home
sleep 60 &
reused=$!
wm_track "$reused"
mkdir "$WINGMAN_HOME/watch.pid.owner"
# The third line ("lstart-utc") marks this as a stamp whose start time was
# rendered by the pinned wm_ps_lstart (issue #303) - load-bearing here: a
# marker-less stamp instead reads as identity-unverifiable and degrades to
# protected (kill -0 alone), which would invert this assertion.
printf '%s\n%s\n%s\n' "$reused" "not-a-real-start-time" "lstart-utc" > "$WINGMAN_HOME/watch.pid.owner/owner"
: > "$WINGMAN_HOME/watch.beat"
out="$(run_hook "kill $reused")"
assert_eq "a live-but-unrelated pid behind a mismatched identity stamp is allowed (no output)" "$out" ""
kill "$reused" 2>/dev/null

# ============================================================================
# scenario 12 (issue #303 PR review round 1): a marker-less stamp must not
# protect on kill -0 alone - it must verify the pid's own argv actually names
# watch-fleet, or a pid the stamp's pid has been recycled to (e.g. after a
# host reboot) gets wrongly protected from a legitimate kill.
# ============================================================================
test_new_home
sleep 60 &
recycled=$!
wm_track "$recycled"
mkdir "$WINGMAN_HOME/watch.pid.owner"
printf '%s\n%s\n' "$recycled" "some-bogus-start-time" > "$WINGMAN_HOME/watch.pid.owner/owner"
: > "$WINGMAN_HOME/watch.beat"
out="$(run_hook "kill $recycled")"
assert_eq "a marker-less stamp for a pid that is not actually watch-fleet is not protected (no output)" "$out" ""
kill "$recycled" 2>/dev/null

# ============================================================================
# scenario 11 (issue #303): protected_pids()'s own ps -o lstart= call must be
# pinned exactly like owner_lock_alive()'s - a cycle armed under one $TZ must
# still be recognized (and protected) when this hook runs under a different
# $TZ, never falling open on a live cycle mid-rollout or on any host whose
# local $TZ is not UTC
# ============================================================================
_kg303_probe="$(TZ=America/New_York ps -o lstart= -p $$ | sed -e 's/^ *//' -e 's/ *$//')"
_kg303_probe2="$(TZ=Asia/Tokyo ps -o lstart= -p $$ | sed -e 's/^ *//' -e 's/ *$//')"
if [ "$_kg303_probe" = "$_kg303_probe2" ]; then
  echo "SKIP: this host's zoneinfo does not distinguish America/New_York from Asia/Tokyo (missing tzdata?) - skipping the issue #303 TZ-mismatch case" >&2
else
  test_new_home
  tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
  tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-tzguard 'sleep 600'
  wm_state crew-add --id a11 --type analyst --objective x --repo /tmp --window wm-tzguard --session-id s11 >/dev/null
  wm_state crew-set --id a11 --status working --summary "in progress" >/dev/null
  TZ=America/New_York "$WF" >"$WINGMAN_HOME/out11.log" 2>&1 &
  wpid11=$!
  wm_track "$wpid11"
  _wp11_i=0
  while ! grep -q "watcher: armed" "$WINGMAN_HOME/out11.log" 2>/dev/null && [ "$_wp11_i" -lt 100 ]; do
    sleep 0.2; _wp11_i=$((_wp11_i + 1))
  done
  out11="$(TZ=Asia/Tokyo run_hook "kill $wpid11")"
  assert_contains "kill <pid> is still denied when the hook runs under a different \$TZ than the arming cycle" "$out11" '"permissionDecision": "deny"'
  kill "$wpid11" 2>/dev/null
  tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null
fi

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

# --- round 3 re-review: tmux resolves ANY unambiguous PREFIX of a full
# command name too, not just the exact name/alias - `tmux kill-win` and
# `tmux kill-ses` bypassed the round-1/2 exact-match set entirely (live
# repro'd against a real cycle: hook output empty, then the real command
# genuinely killed the watcher). Detection now introspects the CONNECTED
# tmux binary's own `list-commands` and replicates its real resolution
# grammar, so any abbreviation this tmux accepts is covered without needing
# a fourth hand-maintained spelling list.
out="$(run_hook "tmux kill-win -t $WM_TMUX_SESSION:watcherwin")"
assert_contains "the kill-win abbreviation (round 3 finding) is recognized as kill-window" "$out" '"permissionDecision": "deny"'

out="$(run_hook "tmux kill-ses -t $WM_TMUX_SESSION")"
assert_contains "the kill-ses abbreviation (round 3 finding) is recognized as kill-session" "$out" '"permissionDecision": "deny"'

out="$(run_hook "tmux kill-s -t $WM_TMUX_SESSION")"
assert_eq "an AMBIGUOUS abbreviation (kill-s: kill-server or kill-session) is allowed - real tmux itself refuses to run it, so there is nothing to guard against" "$out" ""

out="$(run_hook "tmux kill-w -t $WM_TMUX_SESSION:watcherwin")"
assert_contains "the shortest unambiguous kill-window abbreviation (kill-w) is recognized" "$out" '"permissionDecision": "deny"'

# Global flag + abbreviation combined - the exact shape a future round would
# need if abbreviation resolution and global-flag skipping were not both
# anchored on the live tmux grammar.
out="$(run_hook "tmux -S $SOCK kill-win -t $WM_TMUX_SESSION:watcherwin")"
assert_contains "a global -S flag followed by an abbreviated subcommand does not bypass detection" "$out" '"permissionDecision": "deny"'

out="$(run_hook "tmux -T 256,clipboard kill-ses -t $WM_TMUX_SESSION")"
assert_contains "a global -T flag followed by an abbreviated subcommand does not bypass detection" "$out" '"permissionDecision": "deny"'

# An abbreviation on an UNRELATED, real target is still allowed - proves this
# isn't a blanket deny of every abbreviated tmux kill command, only ones that
# actually resolve to a protected pid.
out="$(run_hook "tmux kill-win -t $WM_TMUX_SESSION:typedwin")"
assert_eq "kill-win on an unrelated (real) window is allowed (no output)" "$out" ""

assert_true "the watcher is still alive after every round-3 bypass attempt" "wait_for_cycle_live"

"$WF" --stop >/dev/null 2>&1
tmux kill-session -t "=$WM_TMUX_SESSION" 2>/dev/null

# ============================================================================
# round 4 re-review: a kill/pkill/tmux -t target built via command
# substitution or shell-variable indirection must FAIL CLOSED, not be
# silently treated as "does not match" - live-repro'd during review to
# actually kill a real watcher: `kill $(cat watch.pid)`, `WATCHPID=<pid>;
# kill $WATCHPID`, and `pkill -f "$(echo watch-fleet)"` all reached
# cmd_match.py's inert substitution placeholder or an unexpanded $VAR token,
# which matched nothing, so the real target was never compared against the
# protected set at all.
# ============================================================================
test_new_home
"$WF" >"$WINGMAN_HOME/out.log" 2>&1 &
wpid=$!
wm_track "$wpid"
assert_true "round-4: a real watch-fleet cycle comes up live" "wait_for_cycle_live"
pid="$(cat "$WINGMAN_HOME/watch.pid")"

out="$(run_hook "kill \$(cat $WINGMAN_HOME/watch.pid)")"
assert_contains "kill \$(cat watch.pid) - the exact round-4 repro - fails closed" "$out" '"permissionDecision": "deny"'
assert_contains "the round-4 denial names the conservative refusal" "$out" "Denied conservatively rather than risk"

out="$(run_hook "WATCHPID=$pid; kill \$WATCHPID")"
assert_contains "a variable-indirected kill target fails closed" "$out" '"permissionDecision": "deny"'

out="$(run_hook 'pkill -f "$(echo watch-fleet)"')"
assert_contains "a pkill pattern built via command substitution fails closed" "$out" '"permissionDecision": "deny"'

out="$(run_hook 'kill $(cat /tmp/definitely-not-a-real-pidfile-xyz)')"
assert_contains "an UNRELATED dynamic kill target also fails closed while any cycle is live (accepted conservative tradeoff - cannot be proven safe either)" "$out" '"permissionDecision": "deny"'

out="$(run_hook 'kill -0 $(cat /tmp/definitely-not-a-real-pidfile-xyz)')"
assert_eq "kill -0 on a dynamic target is still allowed (the null-signal check runs before target resolution)" "$out" ""

out="$(run_hook "kill 999999")"
assert_eq "a literal, unrelated pid is still allowed (no output) - this is not a blanket deny of every kill" "$out" ""

assert_true "the watcher is still alive after every round-4 bypass attempt" "wait_for_cycle_live"
"$WF" --stop >/dev/null 2>&1

# tmux -t built via command substitution must fail closed the same way.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n watcherwin \
  "WINGMAN_HOME='$WINGMAN_HOME' WM_WATCH_INTERVAL='$WM_WATCH_INTERVAL' '$WF'"
assert_true "round-4 tmux: the tmux-hosted cycle comes up live" "wait_for_cycle_live"

out="$(run_hook "tmux kill-window -t \"\$(tmux display-message -t $WM_TMUX_SESSION:watcherwin -p '#S:#I')\"")"
assert_contains "a tmux -t value built via command substitution fails closed" "$out" '"permissionDecision": "deny"'

assert_true "the tmux-hosted watcher is still alive after the -t substitution attempt" "wait_for_cycle_live"
"$WF" --stop >/dev/null 2>&1
tmux kill-session -t "=$WM_TMUX_SESSION" 2>/dev/null

# ============================================================================
# scenario 7: a parsed-but-unlexable command fails closed
# ============================================================================
out="$(run_hook "kill 'oops")"
assert_contains "an unresolvable command mentioning kill is denied" "$out" '"permissionDecision": "deny"'
assert_contains "the parse-failure denial names the fail-closed rule" "$out" "denied rather than partially checked"

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

# ============================================================================
# issue #237: a stall under hard grace stays protected. The old beacon-only
# design (protected iff beat file fresher than 30s) had exactly this blind
# spot - this plan's own repro 2 demonstrates a `kill <pid>` during a
# beacon-stale-but-alive window was NOT denied by this guard before this fix.
# The identity-verified, hard-grace-gated design (protected_pids() mirroring
# cycle_healthy()) must keep protecting a merely-stalled (sub-hard-grace)
# cycle - only a genuinely wedged (beyond-hard-grace) one should ever stop
# being protected, which is exactly the population bin/watch-fleet's own
# supervised takeover is now entitled to reap.
# ============================================================================
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-hg1 'sleep 600'
wm_state crew-add --id hg1 --type analyst --objective x --repo /tmp --window wm-hg1 --session-id shg1 >/dev/null
wm_state crew-set --id hg1 --status working --summary "in progress" >/dev/null
"$WF" >"$WINGMAN_HOME/hg.log" 2>&1 &
hgpid=$!
wm_track "$hgpid"
assert_true "the cycle comes up live" "wait_for_cycle_live"
kill -STOP "$hgpid"
sleep 3   # well under the default 300s hard grace
out="$(run_hook "kill $hgpid")"
assert_contains "a stall under hard grace is still denied - the old beacon-only blind spot is closed" "$out" '"permissionDecision": "deny"'

# The other, CHANGED half of this correction: once the same holder crosses
# the hard-grace threshold, protected_pids() must stop protecting it - that
# population is exactly what bin/watch-fleet's own supervised takeover is now
# entitled to reap, and a guard that kept protecting it forever would be the
# one thing left able to override that takeover's own kill. Reverting the
# hard-grace term back to unconditional protection would make every assertion
# above still pass - only this one actually exercises the change.
wm_age_path "$WINGMAN_HOME/watch.beat" 400
# Confirmed directly, not only inferred from the guard's own output below: a
# wm_age_path failure could, in principle, leave the beat file missing rather
# than genuinely aged, and a MISSING beat file also reads as "not protected"
# to protected_pids() - which would make the assertion below pass vacuously
# without the hard-grace term itself ever actually being exercised.
assert_true "the beat file survives aging (still exists, not deleted)" "[ -f '$WINGMAN_HOME/watch.beat' ]"
_beat_mtime="$(uv run --no-project --quiet python -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$WINGMAN_HOME/watch.beat" 2>/dev/null)"
_beat_age=$(( $(date +%s) - _beat_mtime ))
assert_true "the beat file is genuinely aged past the 300s default hard grace" "[ $_beat_age -ge 300 ]"
out2="$(run_hook "kill $hgpid")"
assert_eq "a stall past hard grace is no longer protected - the changed half of the correction" "$out2" ""

kill -CONT "$hgpid" 2>/dev/null
kill "$hgpid" 2>/dev/null
tmux kill-session -t "=$WM_TMUX_SESSION" 2>/dev/null

test_summary
