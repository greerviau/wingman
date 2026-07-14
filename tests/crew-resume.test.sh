#!/usr/bin/env bash
# E2E: bin/crew-resume, the bulk/single relaunch of a `died` crew member via
# `claude --resume <session-id>` (#22). Uses a stub agent (WM_AGENT) and an
# isolated tmux session per test.new_home, exactly like spawn-scope.test.sh, so
# no real claude launches. Proves both idempotency guards, tree preservation
# across a lead + its sub-crew, and the fallback-to-manual path when the
# resumed process exits immediately (a stale/invalid session id).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

CR="$TEST_REPO/bin/crew-resume"
export WM_SUBMIT_DELAY=0 WM_READY_POLL=0.2 WM_SUBMIT_POLL=0.2 WM_SUBMIT_TRIES=1

field_of() { wm_state crew-get --id "$1" | uv run --no-project --quiet python -c 'import sys,json
print(json.load(sys.stdin).get(sys.argv[1]) or "")' "$2"; }

STUB_DIR="$(wm_mktemp_dir)"
ALIVE_STUB="$STUB_DIR/alive.sh"
DEAD_STUB="$STUB_DIR/dead.sh"
printf '#!/usr/bin/env bash\nexec sleep 600\n' > "$ALIVE_STUB"; chmod +x "$ALIVE_STUB"
printf '#!/usr/bin/env bash\nexit 7\n' > "$DEAD_STUB"; chmod +x "$DEAD_STUB"

# --- a died member with a live session resumes --------------------------------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id r1 --type developer --objective x --repo /tmp --window wm-r1 --session-id sess-r1 >/dev/null
wm_state crew-set --id r1 --status died >/dev/null
out="$(WM_AGENT="$ALIVE_STUB" WINGMAN_RUN_ID=run-resume-test "$CR" r1 2>&1)"
assert_contains "resume reports one resumed" "$out" "1 resumed"
assert_true "window wm-r1 exists after resume" \
  "tmux list-windows -t '$WM_TMUX_SESSION' -F '#{window_name}' 2>/dev/null | grep -qx wm-r1"
assert_eq "status flips to working" "$(field_of r1 status)" "working"
assert_eq "parent is unchanged (top-level)" "$(field_of r1 parent)" ""
# The generated launch script restores the full guard-relevant environment:
# the resuming session's own WINGMAN_RUN_ID (so the resumed member reads the
# current sit-down's cached preferences) and the record's own crew type (so a
# resumed lead keeps its orchestrator hooks).
launch="$(cat "$WINGMAN_HOME/crew/r1.resume.sh")"
assert_contains "the resume script exports the resuming session's run id" \
  "$launch" "export WINGMAN_RUN_ID='run-resume-test'"
assert_contains "the resume script exports the record's crew type" \
  "$launch" "export WINGMAN_CREW_TYPE='developer'"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- a resume outside any wingman run exports an empty run id ------------------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id r1b --type lead --objective x --repo /tmp --window wm-r1b --session-id sess-r1b >/dev/null
wm_state crew-set --id r1b --status died >/dev/null
_saved_run_id="${WINGMAN_RUN_ID:-}"
unset WINGMAN_RUN_ID
out="$(WM_AGENT="$ALIVE_STUB" "$CR" r1b 2>&1)"
[ -n "$_saved_run_id" ] && export WINGMAN_RUN_ID="$_saved_run_id"
assert_contains "resume without a run id still resumes" "$out" "1 resumed"
launch="$(cat "$WINGMAN_HOME/crew/r1b.resume.sh")"
assert_contains "no run id in the resuming environment exports empty" \
  "$launch" "export WINGMAN_RUN_ID=''"
assert_contains "a resumed lead's crew type is lead" \
  "$launch" "export WINGMAN_CREW_TYPE='lead'"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- idempotency guard 1: --all-died twice resumes zero the second time -------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id r2 --type developer --objective x --repo /tmp --window wm-r2 --session-id sess-r2 >/dev/null
wm_state crew-set --id r2 --status died >/dev/null
out2a="$(WM_AGENT="$ALIVE_STUB" "$CR" --all-died 2>&1)"
assert_contains "first --all-died resumes the died member" "$out2a" "1 resumed"
out2b="$(WM_AGENT="$ALIVE_STUB" "$CR" --all-died 2>&1)"
assert_contains "second --all-died is a no-op" "$out2b" "0 resumed"
assert_eq "status is still working after the no-op re-run" "$(field_of r2 status)" "working"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- idempotency guard 2: a pre-existing window is left alone -----------------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id r3 --type developer --objective x --repo /tmp --window wm-r3 --session-id sess-r3 >/dev/null
wm_state crew-set --id r3 --status died >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION:" -n wm-r3 'sleep 600'
before_pid="$(tmux list-panes -t "$WM_TMUX_SESSION:wm-r3" -F '#{pane_pid}' 2>/dev/null)"
out3="$(WM_AGENT="$ALIVE_STUB" "$CR" r3 2>&1)"
assert_contains "a pre-existing window is skipped, not duplicated" "$out3" "window already exists"
after_pid="$(tmux list-panes -t "$WM_TMUX_SESSION:wm-r3" -F '#{pane_pid}' 2>/dev/null)"
assert_eq "the original window's pane is untouched" "$after_pid" "$before_pid"
assert_eq "status stays died (guard 2 never resumes)" "$(field_of r3 status)" "died"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- two concurrent invocations racing the same died member never double-launch
# (the must-fix from the PR #29 review: `wm_tmux_windows | grep -qx` before
# `new-window` is a TOCTOU gap, since tmux happily creates two windows with the
# identical name rather than failing or deduping - an atomic mkdir claim closes
# it instead, same pattern as #12's watcher arm lock).
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id crx1 --type developer --objective x --repo /tmp --window wm-crx1 --session-id sess-crx1 >/dev/null
wm_state crew-set --id crx1 --status died >/dev/null
WM_AGENT="$ALIVE_STUB" WM_RESUME_VERIFY_TRIES=3 WM_RESUME_VERIFY_POLL=1 \
  "$CR" crx1 >"$WINGMAN_HOME/race-a.log" 2>&1 &
race_a=$!
WM_AGENT="$ALIVE_STUB" WM_RESUME_VERIFY_TRIES=3 WM_RESUME_VERIFY_POLL=1 \
  "$CR" crx1 >"$WINGMAN_HOME/race-b.log" 2>&1 &
race_b=$!
wait "$race_a" 2>/dev/null
wait "$race_b" 2>/dev/null
win_count="$(tmux list-windows -t "$WM_TMUX_SESSION" -F '#{window_name}' 2>/dev/null | grep -c '^wm-crx1$')"
assert_eq "exactly one wm-crx1 window exists after a concurrent race" "$win_count" "1"
assert_eq "status flips to working exactly once" "$(field_of crx1 status)" "working"
race_a_out="$(cat "$WINGMAN_HOME/race-a.log" 2>/dev/null)"
race_b_out="$(cat "$WINGMAN_HOME/race-b.log" 2>/dev/null)"
winners=0
case "$race_a_out" in *"1 resumed"*) winners=$((winners+1)) ;; esac
case "$race_b_out" in *"1 resumed"*) winners=$((winners+1)) ;; esac
assert_eq "exactly one racer reports having resumed it" "$winners" "1"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- a lead + its sub-crew, both died, both resumed: tree preserved -----------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id lead1 --type lead --objective L --repo /tmp --window wm-lead1 --session-id sess-lead1 >/dev/null
wm_state crew-add --id wkr1 --type developer --objective W --repo /tmp --window wm-wkr1 --session-id sess-wkr1 --parent lead1 >/dev/null
wm_state crew-set --id lead1 --status died >/dev/null
wm_state crew-set --id wkr1 --status died >/dev/null
out4="$(WM_AGENT="$ALIVE_STUB" "$CR" --all-died 2>&1)"
assert_contains "both dead members are resumed" "$out4" "2 resumed"
assert_eq "the lead's status flips to working" "$(field_of lead1 status)" "working"
assert_eq "the worker's status flips to working" "$(field_of wkr1 status)" "working"
assert_eq "the lead's parent is unchanged (top-level)" "$(field_of lead1 parent)" ""
assert_eq "the worker's parent is unchanged (still lead1)" "$(field_of wkr1 parent)" "lead1"
# A multi-id --all-died batch calls resume_one() once per id in the same
# process; every id but the last used to leak its claim dir (the EXIT trap
# only resolved $_claim, reassigned per id, to its final value at script
# exit) - assert neither claim dir survives, not just the one processed last.
assert_false "the first id's claim dir does not leak" "[ -d '$WINGMAN_HOME/crew/lead1.resuming' ]"
assert_false "the second id's claim dir does not leak" "[ -d '$WINGMAN_HOME/crew/wkr1.resuming' ]"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- a leaked claim would permanently block a re-died member; prove it can't --
# The reviewer's exact repro: --all-died over two members, then one of them
# dies again later - it must still be resumable, not stuck forever behind a
# claim dir that the first batch's non-last processing left behind.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id lk1 --type developer --objective a --repo /tmp --window wm-lk1 --session-id sess-lk1 >/dev/null
wm_state crew-add --id lk2 --type developer --objective b --repo /tmp --window wm-lk2 --session-id sess-lk2 >/dev/null
wm_state crew-set --id lk1 --status died >/dev/null
wm_state crew-set --id lk2 --status died >/dev/null
out4b="$(WM_AGENT="$ALIVE_STUB" "$CR" --all-died 2>&1)"
assert_contains "both members resume in the first batch" "$out4b" "2 resumed"
tmux kill-window -t "$WM_TMUX_SESSION:wm-lk1" 2>/dev/null
wm_state crew-set --id lk1 --status died >/dev/null
out4c="$(WM_AGENT="$ALIVE_STUB" "$CR" lk1 2>&1)"
assert_contains "the re-died member (processed first in the earlier batch) resumes again" "$out4c" "1 resumed"
assert_eq "its status flips back to working" "$(field_of lk1 status)" "working"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- a --resume that exits immediately falls back to the manual path ----------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id r5 --type developer --objective x --repo /tmp --window wm-r5 --session-id sess-r5 >/dev/null
wm_state crew-set --id r5 --status died >/dev/null
out5="$(WM_AGENT="$DEAD_STUB" WM_RESUME_VERIFY_TRIES=5 WM_RESUME_VERIFY_POLL=1 "$CR" r5 2>&1)"
assert_contains "a failed resume reports the manual fallback" "$out5" "resume failed"
assert_eq "status is left died after a failed resume" "$(field_of r5 status)" "died"
assert_false "the vanished window is not left behind" \
  "tmux list-windows -t '$WM_TMUX_SESSION' -F '#{window_name}' 2>/dev/null | grep -qx wm-r5"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

test_summary
