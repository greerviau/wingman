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
# WM_RESUME_VERIFY_WINDOW must stay an integer: the verify loop's guard is
# test's `-lt`, which errors ("integer expected", rc 2) on a fractional
# operand rather than raising - under set -u without set -e that doesn't
# abort, it just silently skips the loop body, disabling the verify stage in
# every test that doesn't override it. Since the deadline is measured from
# window creation rather than added on top of the first check, most
# ALIVE_STUB-based tests will already have exceeded this small window by the
# time they reach the verify loop and pay no extra wait; this default exists
# only to bound the rare case where the first check runs before 1s elapses.
export WM_RESUME_VERIFY_WINDOW=1 WM_RESUME_VERIFY_POLL=0.2

field_of() { wm_state crew-get --id "$1" | uv run --no-project --quiet python -c 'import sys,json
print(json.load(sys.stdin).get(sys.argv[1]) or "")' "$2"; }

STUB_DIR="$(wm_mktemp_dir)"
ALIVE_STUB="$STUB_DIR/alive.sh"
DEAD_STUB="$STUB_DIR/dead.sh"
DIALOG_STUB="$STUB_DIR/dialog.sh"
printf '#!/usr/bin/env bash\nexec sleep 600\n' > "$ALIVE_STUB"; chmod +x "$ALIVE_STUB"
printf '#!/usr/bin/env bash\nexit 7\n' > "$DEAD_STUB"; chmod +x "$DEAD_STUB"
# A freshly relaunched window that lands straight on a startup gate
# (workspace-trust/Bypass) instead of an idle chat prompt - exactly the shape
# §3.7 row 7 (issue #214) covers: the resume itself succeeds (the window and
# roster record are already in place by the time the nudge is attempted), but
# the nudge send refuses (rc 2, dialog-shaped) since typing into it risks the
# Enter being consumed as the dialog's own answer.
cat > "$DIALOG_STUB" <<'DIALOGEOF'
#!/usr/bin/env bash
stty -echo -icanon min 1 time 0 2>/dev/null
printf 'Do you want to proceed?\n'
printf '\xe2\x9d\xaf 1. Yes\n'
printf '  2. No, exit\n'
while IFS= read -r -n1 ch; do :; done
DIALOGEOF
chmod +x "$DIALOG_STUB"
# #220: prints a banner immediately (clearing wm_tmux_pane_ready's quiet
# floor), then crashes only after a delay - discriminating only if the delay
# lands after the old single fixed-latency check would have already run and
# before the new wall-clock deadline expires.
DELAYED_CRASH_STUB="$STUB_DIR/delayed_crash.sh"
printf '#!/usr/bin/env bash\necho "Claude Code - ready"\nsleep 4\nexit 1\n' > "$DELAYED_CRASH_STUB"
chmod +x "$DELAYED_CRASH_STUB"
# #221 part 2: crashes fast, writing a distinctive line to its own stderr, so
# a test can prove that line is captured and surfaced instead of only the
# generic "resume failed" message.
STDERR_CRASH_STUB="$STUB_DIR/stderr_crash.sh"
printf '#!/usr/bin/env bash\necho "fatal: invalid session id xyz" >&2\nexit 1\n' > "$STDERR_CRASH_STUB"
chmod +x "$STDERR_CRASH_STUB"

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
# Issue #213: the unattended relaunch must carry the same claudeMdExcludes
# payload as a fresh spawn, so wingman's own root CLAUDE.md never reloads for
# a resumed member - this is the one of the three sites with no human in the
# loop to catch a dropped exclusion.
assert_contains "the resume script carries the claudeMdExcludes settings payload" \
  "$launch" "claudeMdExcludes"
assert_contains "the exclusion payload names the wingman repo root's CLAUDE.md" \
  "$launch" "$TEST_REPO/CLAUDE.md"
assert_contains "the exclusion payload also names the worktree-glob pattern" \
  "$launch" "$TEST_REPO-*/CLAUDE.md"
# Issue #30: defeat the CLI's own "resume from summary?" prompt on every
# unattended relaunch by overriding both gating env vars to an absurdly high
# value, so its size/age check can never be satisfied.
assert_contains "the resume script exports a high CLAUDE_CODE_RESUME_TOKEN_THRESHOLD" \
  "$launch" "export CLAUDE_CODE_RESUME_TOKEN_THRESHOLD=999999999"
assert_contains "the resume script exports a high CLAUDE_CODE_RESUME_THRESHOLD_MINUTES" \
  "$launch" "export CLAUDE_CODE_RESUME_THRESHOLD_MINUTES=999999999"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- issue #251, review round 1, nice-to-have 3: a successful resume clears a
# died member's WIP-anchor pointer/error - both describe a death that is now
# over, and a live `working` member should not keep rendering `wip-ref:
# refs/wip/<id> (<sha>)` for a crash it just recovered from -------------------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id rw1 --type developer --objective x --repo /tmp --window wm-rw1 --session-id sess-rw1 >/dev/null
wm_state crew-set --id rw1 --status died >/dev/null
uv run --no-project --quiet python -c '
import json, sys
path = sys.argv[1]
d = json.load(open(path))
for r in d:
    if r.get("id") == "rw1":
        r["wip_ref_sha"] = "deadbeef"
        r["wip_anchor_error"] = "stale index.lock"
json.dump(d, open(path, "w"))
' "$WINGMAN_HOME/crew.json"
out_rw="$(WM_AGENT="$ALIVE_STUB" "$CR" rw1 2>&1)"
assert_contains "the resume succeeds" "$out_rw" "1 resumed"
assert_eq "wip_ref_sha is cleared on successful resume" "$(field_of rw1 wip_ref_sha)" ""
assert_eq "wip_anchor_error is cleared on successful resume too" "$(field_of rw1 wip_anchor_error)" ""
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- issue #214, §3.7 row 7: an undelivered resume nudge is queued, not lost --
# The relaunched window lands on a startup gate instead of an idle prompt, so
# the resume nudge (WM_CLEAR_KEYS="") refuses with rc 2. The resume itself
# still succeeds (the window/roster registration happened before the nudge
# was ever attempted); only the nudge is queued for the watcher's outbox
# retry, and crew-resume warns rather than silently dropping it.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id rgate1 --type developer --objective x --repo /tmp --window wm-rgate1 --session-id sess-rgate1 >/dev/null
wm_state crew-set --id rgate1 --status died >/dev/null
out_gate="$(WM_AGENT="$DIALOG_STUB" "$CR" rgate1 2>&1)"
assert_contains "the resume itself still succeeds despite the undeliverable nudge" "$out_gate" "1 resumed"
assert_eq "status flips to working" "$(field_of rgate1 status)" "working"
assert_contains "crew-resume warns the nudge was not delivered (dialog-shaped)" \
  "$out_gate" "resume nudge NOT delivered"
assert_contains "the warning names the dialog/trust shape, not silence" "$out_gate" "trust dialog"
assert_contains "crew-resume reports the nudge as queued" "$out_gate" "resume nudge is QUEUED"
q_gate="$(ls "$WINGMAN_HOME/outbox/rgate1" 2>/dev/null | grep -v '^sent-' | head -1)"
assert_true "the resume nudge landed in the outbox, not dropped" "[ -n \"$q_gate\" ]"
assert_contains "the queued nudge carries the resumed-session context text" \
  "$(cat "$WINGMAN_HOME/outbox/rgate1/$q_gate" 2>/dev/null)" "Your previous window was interrupted"
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
WM_AGENT="$ALIVE_STUB" WM_RESUME_VERIFY_WINDOW=3 WM_RESUME_VERIFY_POLL=1 \
  "$CR" crx1 >"$WINGMAN_HOME/race-a.log" 2>&1 &
race_a=$!
WM_AGENT="$ALIVE_STUB" WM_RESUME_VERIFY_WINDOW=3 WM_RESUME_VERIFY_POLL=1 \
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
out5="$(WM_AGENT="$DEAD_STUB" WM_RESUME_VERIFY_WINDOW=5 WM_RESUME_VERIFY_POLL=1 "$CR" r5 2>&1)"
assert_contains "a failed resume reports the manual fallback" "$out5" "resume failed"
assert_eq "status is left died after a failed resume" "$(field_of r5 status)" "died"
assert_false "the vanished window is not left behind" \
  "tmux list-windows -t '$WM_TMUX_SESSION' -F '#{window_name}' 2>/dev/null | grep -qx wm-r5"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- outage-timing guard (issue #23, item 3): refuses while the fleet
# outage-state reads active, unless --force is passed ------------------------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id o1 --type developer --objective x --repo /tmp --window wm-o1 --session-id sess-o1 >/dev/null
wm_state crew-set --id o1 --status died >/dev/null
printf '{"state": "active", "since": "2026-07-15T00:00:00.000000Z", "last_signal": null, "signal_count": 2}\n' \
  > "$WINGMAN_HOME/api-outage-state.json"
out_o1="$(WM_AGENT="$ALIVE_STUB" "$CR" o1 2>&1)"; rc_o1=$?
assert_eq "crew-resume refuses while the outage is active" "$rc_o1" "1"
assert_contains "the refusal names the outage" "$out_o1" "API outage is currently active"
assert_contains "the refusal names the --force escape hatch" "$out_o1" "--force"
assert_eq "the member stays died, nothing was relaunched" "$(field_of o1 status)" "died"
assert_false "no window was created for the refused resume" \
  "tmux list-windows -t '$WM_TMUX_SESSION' -F '#{window_name}' 2>/dev/null | grep -qx wm-o1"

out_o2="$(WM_AGENT="$ALIVE_STUB" "$CR" o1 --force 2>&1)"
assert_contains "--force proceeds despite the active outage" "$out_o2" "1 resumed"
assert_eq "the member resumes (status flips to working) with --force" "$(field_of o1 status)" "working"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# A --all-died batch is refused the identical way.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id o3 --type developer --objective x --repo /tmp --window wm-o3 --session-id sess-o3 >/dev/null
wm_state crew-set --id o3 --status died >/dev/null
printf '{"state": "active", "since": "2026-07-15T00:00:00.000000Z", "last_signal": null, "signal_count": 2}\n' \
  > "$WINGMAN_HOME/api-outage-state.json"
out_o3="$(WM_AGENT="$ALIVE_STUB" "$CR" --all-died 2>&1)"; rc_o3=$?
assert_eq "--all-died also refuses while the outage is active" "$rc_o3" "1"
assert_eq "the member stays died" "$(field_of o3 status)" "died"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# A clear (or absent) outage state never gates a resume at all.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id o4 --type developer --objective x --repo /tmp --window wm-o4 --session-id sess-o4 >/dev/null
wm_state crew-set --id o4 --status died >/dev/null
printf '{"state": "clear", "since": "2026-07-15T00:00:00.000000Z", "last_signal": null, "signal_count": 0}\n' \
  > "$WINGMAN_HOME/api-outage-state.json"
out_o4="$(WM_AGENT="$ALIVE_STUB" "$CR" o4 2>&1)"
assert_contains "state clear: resume proceeds without --force" "$out_o4" "1 resumed"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# No state file at all (fresh install) fails open, matching the spawn guard's
# own posture.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id o5 --type developer --objective x --repo /tmp --window wm-o5 --session-id sess-o5 >/dev/null
wm_state crew-set --id o5 --status died >/dev/null
out_o5="$(WM_AGENT="$ALIVE_STUB" "$CR" o5 2>&1)"
assert_contains "no state file: resume proceeds without --force" "$out_o5" "1 resumed"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- #220: a delayed crash past the old fixed-latency check is now caught ----
# Before this fix, only one check ran shortly after the nudge settled; a crash
# landing after that check but before any human/watcher noticed was invisible
# forever. WM_RESUME_VERIFY_WINDOW=6 sets a deadline comfortably past the
# stub's 4s delayed crash, so the verify loop's polling must catch it.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id dc1 --type developer --objective x --repo /tmp --window wm-dc1 --session-id sess-dc1 >/dev/null
wm_state crew-set --id dc1 --status died >/dev/null
out_dc="$(WM_AGENT="$DELAYED_CRASH_STUB" WM_RESUME_VERIFY_WINDOW=6 WM_RESUME_VERIFY_POLL=0.3 "$CR" dc1 2>&1)"
assert_contains "a delayed crash inside the verify window is caught, not reported as resumed" "$out_dc" "resume failed"
assert_not_contains "a delayed crash never gets reported as resumed" "$out_dc" "1 resumed"
assert_eq "status is left died for a delayed crash caught by the verify window" "$(field_of dc1 status)" "died"
assert_false "the vanished window is not left behind after a delayed crash" \
  "tmux list-windows -t '$WM_TMUX_SESSION' -F '#{window_name}' 2>/dev/null | grep -qx wm-dc1"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- #221 part 1: a missing worktree falls back to the repo root, not a
# failure -----------------------------------------------------------------
REMOVED_WT="$STUB_DIR/worktree-cleaned-up-after-merge"
mkdir -p "$REMOVED_WT"; rmdir "$REMOVED_WT"
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id wt1 --type developer --objective x --repo /tmp \
  --window wm-wt1 --session-id sess-wt1 --worktree "$REMOVED_WT" >/dev/null
wm_state crew-set --id wt1 --status died >/dev/null
out_wt="$(WM_AGENT="$ALIVE_STUB" "$CR" wt1 2>&1)"
assert_contains "a missing worktree falls back to the repo root instead of failing" "$out_wt" "1 resumed"
assert_contains "the operator is told about the fallback" "$out_wt" "no longer exists"
assert_eq "status flips to working despite the missing worktree" "$(field_of wt1 status)" "working"
assert_eq "the roster's worktree field is cleared, not left stale" "$(field_of wt1 worktree)" ""
launch_wt="$(cat "$WINGMAN_HOME/crew/wt1.resume.sh")"
assert_contains "the launch script cd's into the repo root, not the missing worktree" "$launch_wt" "cd '/tmp'"
assert_not_contains "the launch script must not reference the removed worktree path" "$launch_wt" "$REMOVED_WT"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- #221 part 1, positive case: an existing worktree still resumes into it,
# and gets no fallback wording ----------------------------------------------
# The needles use the literal single-quoted form (matching the test above's
# own "cd '/tmp'"), not quote() - bin/lib/common.sh's quote() is never
# sourced by this test file (tests/lib.sh has no ./source line for it), so
# $(quote "$LIVE_WT") would silently expand to empty and collapse the first
# needle to the bare, non-discriminating "cd " that every launch script this
# suite generates contains regardless of correctness. LIVE_WT comes from
# wm_mktemp_dir and contains no single quotes, so the literal form is exact.
LIVE_WT="$STUB_DIR/worktree-still-here"
mkdir -p "$LIVE_WT"
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id wt2 --type developer --objective x --repo /tmp \
  --window wm-wt2 --session-id sess-wt2 --worktree "$LIVE_WT" >/dev/null
wm_state crew-set --id wt2 --status died >/dev/null
out_wt2="$(WM_AGENT="$ALIVE_STUB" "$CR" wt2 2>&1)"
assert_contains "an existing worktree still resumes normally" "$out_wt2" "1 resumed"
launch_wt2="$(cat "$WINGMAN_HOME/crew/wt2.resume.sh")"
assert_contains "the launch script cd's into the worktree" "$launch_wt2" "cd '$LIVE_WT'"
assert_contains "the launch script exports WINGMAN_WORKTREE" "$launch_wt2" "export WINGMAN_WORKTREE='$LIVE_WT'"
assert_not_contains "a healthy worktree gets no fallback wording in the output" "$out_wt2" "no longer exists"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- #221 part 2: a fast-crashing resume surfaces its captured stderr --------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id se1 --type developer --objective x --repo /tmp --window wm-se1 --session-id sess-se1 >/dev/null
wm_state crew-set --id se1 --status died >/dev/null
out_se="$(WM_AGENT="$STDERR_CRASH_STUB" "$CR" se1 2>&1)"
assert_contains "a stderr-crashing resume still reports the manual fallback" "$out_se" "resume failed"
assert_contains "the real cause is surfaced from the captured stderr, not just the generic message" \
  "$out_se" "invalid session id xyz"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- #221 part 1: _worktree_fallback must not leak across an --all-died batch
# resume_one() runs repeatedly in the same shell process for --all-died, so
# without a per-member reset the first member's fallback would leave the flag
# set for the rest of the batch, wrongly telling a healthy member with a live
# worktree to abandon it. Both members use DIALOG_STUB so their nudges fail
# delivery and get queued to the outbox (any nonzero delivery rc queues), so
# the queued body can be inspected directly rather than relying on the
# operator-console wording, which isn't gated on this flag at all. --all-died
# processes crew-add's insertion order, so wt3 (missing worktree) is resumed
# before wt4 (live worktree).
REMOVED_WT2="$STUB_DIR/worktree-cleaned-up-batch"
mkdir -p "$REMOVED_WT2"; rmdir "$REMOVED_WT2"
LIVE_WT2="$STUB_DIR/worktree-still-here-batch"
mkdir -p "$LIVE_WT2"
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id wt3 --type developer --objective x --repo /tmp \
  --window wm-wt3 --session-id sess-wt3 --worktree "$REMOVED_WT2" >/dev/null
wm_state crew-add --id wt4 --type developer --objective x --repo /tmp \
  --window wm-wt4 --session-id sess-wt4 --worktree "$LIVE_WT2" >/dev/null
wm_state crew-set --id wt3 --status died >/dev/null
wm_state crew-set --id wt4 --status died >/dev/null
out_batch="$(WM_AGENT="$DIALOG_STUB" "$CR" --all-died 2>&1)"
assert_contains "both batch members resume despite each one's undeliverable nudge" "$out_batch" "2 resumed"
q_wt3="$(ls "$WINGMAN_HOME/outbox/wt3" 2>/dev/null | grep -v '^sent-' | head -1)"
q_wt4="$(ls "$WINGMAN_HOME/outbox/wt4" 2>/dev/null | grep -v '^sent-' | head -1)"
assert_true "the fallback member's nudge is queued" "[ -n '$q_wt3' ]"
assert_true "the healthy member's nudge is queued" "[ -n '$q_wt4' ]"
assert_contains "the fallback member's queued nudge carries the re-isolate sentence" \
  "$(cat "$WINGMAN_HOME/outbox/wt3/$q_wt3" 2>/dev/null)" "re-isolate into a fresh worktree"
assert_not_contains "the flag does not leak: the healthy member's queued nudge carries no re-isolate wording" \
  "$(cat "$WINGMAN_HOME/outbox/wt4/$q_wt4" 2>/dev/null)" "re-isolate into a fresh worktree"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

test_summary
