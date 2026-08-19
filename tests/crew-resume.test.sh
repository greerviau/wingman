#!/usr/bin/env bash
# E2E: bin/crew-resume, the bulk/single relaunch of a `died` crew member via
# `claude --resume <session-id>` (#22). Uses a stub agent (WM_AGENT_BIN_OVERRIDE)
# and an isolated tmux session per test.new_home, exactly like spawn-scope.test.sh, so
# no real claude launches. Proves both idempotency guards, tree preservation
# across a lead + its sub-crew, and the fallback-to-manual path when the
# resumed process exits immediately (a stale/invalid session id).
#
# Every fixture's `--repo /tmp` is trusted (wm_trust_repo /tmp) right after
# each test_new_home: crew-resume's own preflight now includes
# workspace-trust (issue #25's claude_preflight, relocated from
# bin/spawn-crew - not just the hook-sync check this file used to be the
# only thing crew-resume ran), so an untrusted repo would otherwise refuse
# every single resume in this file.
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
wm_trust_repo /tmp
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id r1 --type developer --objective x --repo /tmp --window wm-r1 --session-id sess-r1 >/dev/null
wm_state crew-set --id r1 --status died >/dev/null
out="$(WM_AGENT_BIN_OVERRIDE="$ALIVE_STUB" WINGMAN_RUN_ID=run-resume-test "$CR" r1 2>&1)"
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
wm_trust_repo /tmp
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
out_rw="$(WM_AGENT_BIN_OVERRIDE="$ALIVE_STUB" "$CR" rw1 2>&1)"
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
wm_trust_repo /tmp
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id rgate1 --type developer --objective x --repo /tmp --window wm-rgate1 --session-id sess-rgate1 >/dev/null
wm_state crew-set --id rgate1 --status died >/dev/null
out_gate="$(WM_AGENT_BIN_OVERRIDE="$DIALOG_STUB" "$CR" rgate1 2>&1)"
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

# --- issue #173: rc 3 (typed but unconfirmed) also warns with matched wording
# and queues, not just rc 2/6 ------------------------------------------------
# The relaunched window's pane genuinely accepts the nudge's keystrokes but
# never confirms the submit (composer-stub with SWALLOW=1, BUSY=0 - the same
# fixture tests/composer-confirm-delivery.test.sh proves returns rc 3): the
# resume still succeeds (window/roster already in place), the nudge is
# diagnosed with rc-3-specific wording (not the old silent fallback to the
# generic QUEUED line), and it's queued for the watcher's retry same as rc 2.
# WM_AGENT must be a real executable path - crew-resume writes it verbatim
# into the generated launch script's `exec` line, and that script runs
# inside a freshly spawned tmux window. tmux does not propagate the invoking
# shell's env vars into a window it creates (confirmed empirically; every
# other file driving this fixture bakes its WM_TEST_* vars directly into the
# command string handed to tmux new-session/new-window instead of exporting
# them beforehand), so the composer stub's knobs are baked into a thin
# wrapper script rather than set as plain env vars on the crew-resume call.
test_new_home
wm_trust_repo /tmp
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id rswallow1 --type developer --objective x --repo /tmp --window wm-rswallow1 --session-id sess-rswallow1 >/dev/null
wm_state crew-set --id rswallow1 --status died >/dev/null
SWALLOW_MARKER="$(wm_mktemp_file)"
SWALLOW_STUB="$(wm_mktemp_dir)/swallow-wrap.sh"
cat > "$SWALLOW_STUB" <<SWALLOWEOF
#!/usr/bin/env bash
export WM_TEST_BUSY=0 WM_TEST_SWALLOW=1 WM_TEST_MARKER='$SWALLOW_MARKER'
exec "$TEST_REPO/tests/fixtures/composer-stub.sh"
SWALLOWEOF
chmod +x "$SWALLOW_STUB"
out_swallow="$(WM_AGENT_BIN_OVERRIDE="$SWALLOW_STUB" \
  WM_SUBMIT_DELAY=0.3 WM_READY_POLL=0.3 WM_SUBMIT_POLL=0.4 WM_READY_TRIES=20 WM_SUBMIT_TRIES=8 \
  "$CR" rswallow1 2>&1)"
assert_contains "the resume itself still succeeds despite the unconfirmed nudge" "$out_swallow" "1 resumed"
assert_eq "status flips to working" "$(field_of rswallow1 status)" "working"
assert_contains "crew-resume warns the nudge was not delivered (rc 3 wording)" \
  "$out_swallow" "resume nudge NOT delivered"
assert_contains "the warning names the unconfirmed-submit shape, not the rc-2/6 wording" \
  "$out_swallow" "submit never visibly registered"
assert_contains "crew-resume still reports the nudge as queued" "$out_swallow" "resume nudge is QUEUED"
q_swallow="$(ls "$WINGMAN_HOME/outbox/rswallow1" 2>/dev/null | grep -v '^sent-' | head -1)"
assert_true "the resume nudge landed in the outbox" "[ -n \"$q_swallow\" ]"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- issue #173: rc 4 (send-lock contended) also warns with matched wording
# and queues -------------------------------------------------------------------
# A separate process holds crew-resume's own target's per-pane send lock
# before the resume even starts, forcing wm_tmux_send_message to give up with
# rc 4 (contention, not a dialog/composer refusal) once WM_SEND_LOCK_WAIT
# elapses - proving the lock-contended path is now diagnosed and queued too,
# not silently swallowed into the old generic "QUEUED" line.
test_new_home
wm_trust_repo /tmp
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id rlock1 --type developer --objective x --repo /tmp --window wm-rlock1 --session-id sess-rlock1 >/dev/null
wm_state crew-set --id rlock1 --status died >/dev/null

LOCK_HOLDER="$(wm_mktemp_dir)/holder.sh"
cat > "$LOCK_HOLDER" <<HOLDEREOF
#!/usr/bin/env bash
set -u
. "$TEST_REPO/bin/lib/common.sh"
wm_tmux_send_lock "=$WM_TMUX_SESSION:=wm-rlock1" || exit 9
echo "HOLDING \$\$"
while :; do sleep 0.05; done
HOLDEREOF
chmod +x "$LOCK_HOLDER"
"$LOCK_HOLDER" >"$WINGMAN_HOME/lock-holder.out" 2>&1 &
_lock_holder_shell_pid=$!
wm_track "$_lock_holder_shell_pid"
_lh_i=0
while [ "$_lh_i" -lt 50 ]; do
  grep -q "^HOLDING " "$WINGMAN_HOME/lock-holder.out" 2>/dev/null && break
  sleep 0.1; _lh_i=$((_lh_i+1))
done
_lock_holder_pid="$(awk '{print $2}' "$WINGMAN_HOME/lock-holder.out")"
assert_true "the holder process genuinely acquired the send lock" "[ -n \"$_lock_holder_pid\" ]"

out_lock="$(WM_AGENT_BIN_OVERRIDE="$ALIVE_STUB" WM_SEND_LOCK_WAIT=1 "$CR" rlock1 2>&1)"
assert_contains "the resume itself still succeeds despite the contended nudge" "$out_lock" "1 resumed"
assert_eq "status flips to working" "$(field_of rlock1 status)" "working"
assert_contains "crew-resume warns the nudge was not delivered (rc 4 wording)" \
  "$out_lock" "resume nudge NOT delivered"
assert_contains "the warning names lock contention, not a dialog/composer refusal" \
  "$out_lock" "holding the pane's send lock"
assert_contains "crew-resume still reports the nudge as queued" "$out_lock" "resume nudge is QUEUED"
q_lock="$(ls "$WINGMAN_HOME/outbox/rlock1" 2>/dev/null | grep -v '^sent-' | head -1)"
assert_true "the resume nudge landed in the outbox" "[ -n \"$q_lock\" ]"

kill -KILL "$_lock_holder_pid" 2>/dev/null
wait "$_lock_holder_shell_pid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- a resume outside any wingman run: computed identity, not a relayed ------
# --- empty (docs/analysis/2026-08-18-remove-bin-wingman-launcher-spec.md, ----
# --- §4.3/§8 step 4) ----------------------------------------------------------
test_new_home
wm_trust_repo /tmp
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id r1b --type lead --objective x --repo /tmp --window wm-r1b --session-id sess-r1b >/dev/null
wm_state crew-set --id r1b --status died >/dev/null
_saved_run_id="${WINGMAN_RUN_ID:-}"
unset WINGMAN_RUN_ID

# No recognizable harness ancestor within the bounded walk either (forced via
# WM_HARNESS_WALK_MAX=0): the one genuine "cannot resolve a run id at all"
# case - see hooks/pilot-preferences-guard.sh's identical-purpose test for
# the full rationale.
out="$(WM_AGENT_BIN_OVERRIDE="$ALIVE_STUB" WM_HARNESS_WALK_MAX=0 "$CR" r1b 2>&1)"
assert_contains "resume without a run id still resumes" "$out" "1 resumed"
launch="$(cat "$WINGMAN_HOME/crew/r1b.resume.sh")"
assert_contains "no run id resolvable at all: exports empty" \
  "$launch" "export WINGMAN_RUN_ID=''"
assert_contains "a resumed lead's crew type is lead" \
  "$launch" "export WINGMAN_CREW_TYPE='lead'"

tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# No WINGMAN_RUN_ID exported, but a computed identity DOES resolve - the
# no-launcher path this spec's whole design targets. Fresh state (a new
# crew member, a new test_new_home) rather than reusing r1b: crew-resume
# skips an already-live endpoint rather than duplicating it, so replaying
# the exact same window/member from the case above would silently no-op the
# second resume and leave `launch` reading the FIRST case's stale content.
# Run through a deterministic fake "claude" ancestor (wm_fake_harness_bin)
# rather than relying on whatever this test suite's own real parent process
# happens to be, so the assertion holds regardless of how these tests are
# invoked.
test_new_home
wm_trust_repo /tmp
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id r1c --type lead --objective x --repo /tmp --window wm-r1c --session-id sess-r1c >/dev/null
wm_state crew-set --id r1c --status died >/dev/null
FAKE_CLAUDE="$(wm_fake_harness_bin claude)"
CHILD_SCRIPT="$(wm_mktemp_file)"
# Not `quote` (bin/lib/common.sh): this file never sources it for real - the
# only `.` mentioning that path elsewhere here is inside a heredoc writing a
# DIFFERENT script's content, not a sourcing statement in this file's own
# shell. $ALIVE_STUB/$CR are plain, space-free fixture paths, so a literal
# single-quote wrap is safe without the general-purpose escaping quote()
# provides.
cat > "$CHILD_SCRIPT" <<EOF
WM_AGENT_BIN_OVERRIDE='$ALIVE_STUB' '$CR' r1c
EOF
out="$("$FAKE_CLAUDE" "$CHILD_SCRIPT" 2>&1)"
[ -n "$_saved_run_id" ] && export WINGMAN_RUN_ID="$_saved_run_id"
assert_contains "computed identity: resume still resumes" "$out" "1 resumed"
launch="$(cat "$WINGMAN_HOME/crew/r1c.resume.sh")"
assert_not_contains "computed identity: never exports the empty-string run id" \
  "$launch" "export WINGMAN_RUN_ID=''"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- idempotency guard 1: --all-died twice resumes zero the second time -------
test_new_home
wm_trust_repo /tmp
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id r2 --type developer --objective x --repo /tmp --window wm-r2 --session-id sess-r2 >/dev/null
wm_state crew-set --id r2 --status died >/dev/null
out2a="$(WM_AGENT_BIN_OVERRIDE="$ALIVE_STUB" "$CR" --all-died 2>&1)"
assert_contains "first --all-died resumes the died member" "$out2a" "1 resumed"
out2b="$(WM_AGENT_BIN_OVERRIDE="$ALIVE_STUB" "$CR" --all-died 2>&1)"
assert_contains "second --all-died is a no-op" "$out2b" "0 resumed"
assert_eq "status is still working after the no-op re-run" "$(field_of r2 status)" "working"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- idempotency guard 2: a pre-existing window is left alone -----------------
test_new_home
wm_trust_repo /tmp
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id r3 --type developer --objective x --repo /tmp --window wm-r3 --session-id sess-r3 >/dev/null
wm_state crew-set --id r3 --status died >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION:" -n wm-r3 'sleep 600'
before_pid="$(tmux list-panes -t "$WM_TMUX_SESSION:wm-r3" -F '#{pane_pid}' 2>/dev/null)"
out3="$(WM_AGENT_BIN_OVERRIDE="$ALIVE_STUB" "$CR" r3 2>&1)"
assert_contains "a pre-existing endpoint is skipped, not duplicated" "$out3" "endpoint already exists"
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
wm_trust_repo /tmp
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id crx1 --type developer --objective x --repo /tmp --window wm-crx1 --session-id sess-crx1 >/dev/null
wm_state crew-set --id crx1 --status died >/dev/null
WM_AGENT_BIN_OVERRIDE="$ALIVE_STUB" WM_RESUME_VERIFY_WINDOW=3 WM_RESUME_VERIFY_POLL=1 \
  "$CR" crx1 >"$WINGMAN_HOME/race-a.log" 2>&1 &
race_a=$!
WM_AGENT_BIN_OVERRIDE="$ALIVE_STUB" WM_RESUME_VERIFY_WINDOW=3 WM_RESUME_VERIFY_POLL=1 \
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
wm_trust_repo /tmp
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id lead1 --type lead --objective L --repo /tmp --window wm-lead1 --session-id sess-lead1 >/dev/null
wm_state crew-add --id wkr1 --type developer --objective W --repo /tmp --window wm-wkr1 --session-id sess-wkr1 --parent lead1 >/dev/null
wm_state crew-set --id lead1 --status died >/dev/null
wm_state crew-set --id wkr1 --status died >/dev/null
out4="$(WM_AGENT_BIN_OVERRIDE="$ALIVE_STUB" "$CR" --all-died 2>&1)"
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
wm_trust_repo /tmp
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id lk1 --type developer --objective a --repo /tmp --window wm-lk1 --session-id sess-lk1 >/dev/null
wm_state crew-add --id lk2 --type developer --objective b --repo /tmp --window wm-lk2 --session-id sess-lk2 >/dev/null
wm_state crew-set --id lk1 --status died >/dev/null
wm_state crew-set --id lk2 --status died >/dev/null
out4b="$(WM_AGENT_BIN_OVERRIDE="$ALIVE_STUB" "$CR" --all-died 2>&1)"
assert_contains "both members resume in the first batch" "$out4b" "2 resumed"
tmux kill-window -t "$WM_TMUX_SESSION:wm-lk1" 2>/dev/null
wm_state crew-set --id lk1 --status died >/dev/null
out4c="$(WM_AGENT_BIN_OVERRIDE="$ALIVE_STUB" "$CR" lk1 2>&1)"
assert_contains "the re-died member (processed first in the earlier batch) resumes again" "$out4c" "1 resumed"
assert_eq "its status flips back to working" "$(field_of lk1 status)" "working"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- a --resume that exits immediately falls back to the manual path ----------
test_new_home
wm_trust_repo /tmp
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id r5 --type developer --objective x --repo /tmp --window wm-r5 --session-id sess-r5 >/dev/null
wm_state crew-set --id r5 --status died >/dev/null
out5="$(WM_AGENT_BIN_OVERRIDE="$DEAD_STUB" WM_RESUME_VERIFY_WINDOW=5 WM_RESUME_VERIFY_POLL=1 "$CR" r5 2>&1)"
assert_contains "a failed resume reports the manual fallback" "$out5" "resume failed"
assert_eq "status is left died after a failed resume" "$(field_of r5 status)" "died"
assert_false "the vanished window is not left behind" \
  "tmux list-windows -t '$WM_TMUX_SESSION' -F '#{window_name}' 2>/dev/null | grep -qx wm-r5"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- outage-timing guard (issue #23, item 3): refuses while the fleet
# outage-state reads active, unless --force is passed ------------------------
test_new_home
wm_trust_repo /tmp
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id o1 --type developer --objective x --repo /tmp --window wm-o1 --session-id sess-o1 >/dev/null
wm_state crew-set --id o1 --status died >/dev/null
printf '{"state": "active", "since": "2026-07-15T00:00:00.000000Z", "last_signal": null, "signal_count": 2}\n' \
  > "$WINGMAN_HOME/api-outage-state.json"
out_o1="$(WM_AGENT_BIN_OVERRIDE="$ALIVE_STUB" "$CR" o1 2>&1)"; rc_o1=$?
assert_eq "crew-resume refuses while the outage is active" "$rc_o1" "1"
assert_contains "the refusal names the outage" "$out_o1" "API outage is currently active"
assert_contains "the refusal names the --force escape hatch" "$out_o1" "--force"
assert_eq "the member stays died, nothing was relaunched" "$(field_of o1 status)" "died"
assert_false "no window was created for the refused resume" \
  "tmux list-windows -t '$WM_TMUX_SESSION' -F '#{window_name}' 2>/dev/null | grep -qx wm-o1"

out_o2="$(WM_AGENT_BIN_OVERRIDE="$ALIVE_STUB" "$CR" o1 --force 2>&1)"
assert_contains "--force proceeds despite the active outage" "$out_o2" "1 resumed"
assert_eq "the member resumes (status flips to working) with --force" "$(field_of o1 status)" "working"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# A --all-died batch is refused the identical way.
test_new_home
wm_trust_repo /tmp
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id o3 --type developer --objective x --repo /tmp --window wm-o3 --session-id sess-o3 >/dev/null
wm_state crew-set --id o3 --status died >/dev/null
printf '{"state": "active", "since": "2026-07-15T00:00:00.000000Z", "last_signal": null, "signal_count": 2}\n' \
  > "$WINGMAN_HOME/api-outage-state.json"
out_o3="$(WM_AGENT_BIN_OVERRIDE="$ALIVE_STUB" "$CR" --all-died 2>&1)"; rc_o3=$?
assert_eq "--all-died also refuses while the outage is active" "$rc_o3" "1"
assert_eq "the member stays died" "$(field_of o3 status)" "died"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# A clear (or absent) outage state never gates a resume at all.
test_new_home
wm_trust_repo /tmp
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id o4 --type developer --objective x --repo /tmp --window wm-o4 --session-id sess-o4 >/dev/null
wm_state crew-set --id o4 --status died >/dev/null
printf '{"state": "clear", "since": "2026-07-15T00:00:00.000000Z", "last_signal": null, "signal_count": 0}\n' \
  > "$WINGMAN_HOME/api-outage-state.json"
out_o4="$(WM_AGENT_BIN_OVERRIDE="$ALIVE_STUB" "$CR" o4 2>&1)"
assert_contains "state clear: resume proceeds without --force" "$out_o4" "1 resumed"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# No state file at all (fresh install) fails open, matching the spawn guard's
# own posture.
test_new_home
wm_trust_repo /tmp
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id o5 --type developer --objective x --repo /tmp --window wm-o5 --session-id sess-o5 >/dev/null
wm_state crew-set --id o5 --status died >/dev/null
out_o5="$(WM_AGENT_BIN_OVERRIDE="$ALIVE_STUB" "$CR" o5 2>&1)"
assert_contains "no state file: resume proceeds without --force" "$out_o5" "1 resumed"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- #220: a delayed crash past the old fixed-latency check is now caught ----
# Before this fix, only one check ran shortly after the nudge settled; a crash
# landing after that check but before any human/watcher noticed was invisible
# forever. WM_RESUME_VERIFY_WINDOW=6 sets a deadline comfortably past the
# stub's 4s delayed crash, so the verify loop's polling must catch it.
test_new_home
wm_trust_repo /tmp
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id dc1 --type developer --objective x --repo /tmp --window wm-dc1 --session-id sess-dc1 >/dev/null
wm_state crew-set --id dc1 --status died >/dev/null
out_dc="$(WM_AGENT_BIN_OVERRIDE="$DELAYED_CRASH_STUB" WM_RESUME_VERIFY_WINDOW=6 WM_RESUME_VERIFY_POLL=0.3 "$CR" dc1 2>&1)"
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
wm_trust_repo /tmp
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id wt1 --type developer --objective x --repo /tmp \
  --window wm-wt1 --session-id sess-wt1 --worktree "$REMOVED_WT" >/dev/null
wm_state crew-set --id wt1 --status died >/dev/null
out_wt="$(WM_AGENT_BIN_OVERRIDE="$ALIVE_STUB" "$CR" wt1 2>&1)"
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
wm_trust_repo /tmp
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id wt2 --type developer --objective x --repo /tmp \
  --window wm-wt2 --session-id sess-wt2 --worktree "$LIVE_WT" >/dev/null
wm_state crew-set --id wt2 --status died >/dev/null
out_wt2="$(WM_AGENT_BIN_OVERRIDE="$ALIVE_STUB" "$CR" wt2 2>&1)"
assert_contains "an existing worktree still resumes normally" "$out_wt2" "1 resumed"
launch_wt2="$(cat "$WINGMAN_HOME/crew/wt2.resume.sh")"
assert_contains "the launch script cd's into the worktree" "$launch_wt2" "cd '$LIVE_WT'"
assert_contains "the launch script exports WINGMAN_WORKTREE" "$launch_wt2" "export WINGMAN_WORKTREE='$LIVE_WT'"
assert_not_contains "a healthy worktree gets no fallback wording in the output" "$out_wt2" "no longer exists"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- #221 part 2: a fast-crashing resume surfaces its captured stderr --------
test_new_home
wm_trust_repo /tmp
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id se1 --type developer --objective x --repo /tmp --window wm-se1 --session-id sess-se1 >/dev/null
wm_state crew-set --id se1 --status died >/dev/null
out_se="$(WM_AGENT_BIN_OVERRIDE="$STDERR_CRASH_STUB" "$CR" se1 2>&1)"
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
wm_trust_repo /tmp
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id wt3 --type developer --objective x --repo /tmp \
  --window wm-wt3 --session-id sess-wt3 --worktree "$REMOVED_WT2" >/dev/null
wm_state crew-add --id wt4 --type developer --objective x --repo /tmp \
  --window wm-wt4 --session-id sess-wt4 --worktree "$LIVE_WT2" >/dev/null
wm_state crew-set --id wt3 --status died >/dev/null
wm_state crew-set --id wt4 --status died >/dev/null
out_batch="$(WM_AGENT_BIN_OVERRIDE="$DIALOG_STUB" "$CR" --all-died 2>&1)"
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

# --- issue #25: crew-resume's own exec target is fully descriptor-driven ---
# (plan step 5, superseding round 1's original quick fix - $WM_AGENT is no
# longer read directly for the exec target at all; the roster's own `agent`
# field selects the descriptor via wm_agent_resolve, and
# WM_AGENT_BIN_OVERRIDE - the suite's own ambient default, tests/lib.sh -
# redirects its resolved WM_AGENT_BIN exactly like bin/spawn-crew's does.)
FALLBACK_STUB="$STUB_DIR/fallback-marker.sh"
FALLBACK_MARKER="$STUB_DIR/fallback-invoked"
cat > "$FALLBACK_STUB" <<EOF
#!/usr/bin/env bash
printf 'FALLBACK_STUB_INVOKED %s\n' "\$*" > "$FALLBACK_MARKER"
exec sleep 600
EOF
chmod +x "$FALLBACK_STUB"
test_new_home
wm_trust_repo /tmp
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id fb1 --type developer --objective x --repo /tmp --window wm-fb1 --session-id sess-fb1 >/dev/null
wm_state crew-set --id fb1 --status died >/dev/null
out_fb="$(WM_AGENT_BIN_OVERRIDE="$FALLBACK_STUB" "$CR" fb1 2>&1)"
assert_contains "a legacy record (no agent field) still resumes via the claude descriptor's own resolution" "$out_fb" "1 resumed"
assert_true "the fallback stub was the one actually execed, not real claude" "[ -f '$FALLBACK_MARKER' ]"
assert_contains "the launch script's exec line names the fallback stub" \
  "$(grep '^exec ' "$WINGMAN_HOME/crew/fb1.resume.sh" 2>/dev/null)" "$FALLBACK_STUB"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- issue #353: crew-resume's OWN composition site also emits a non-empty
# WM_AGENT_CONTEXT_SUPPRESS_FLAG, not just bin/spawn-crew's (round-2 review
# of PR #354: crew-resume's copy of the emission line had no coverage of its
# own - deleting it left the whole suite green). Uses the real codex
# descriptor, not a throwaway fixture, since it is the one this field is
# actually populated for today.
test_new_home
wm_trust_repo /tmp
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id cx1 --type developer --objective x --repo /tmp \
  --window wm-cx1 --session-id sess-cx1 --agent codex >/dev/null
wm_state crew-set --id cx1 --status died >/dev/null
out_cx="$(WM_AGENT_BIN_OVERRIDE="$ALIVE_STUB" "$CR" cx1 2>&1)"
assert_contains "a codex-agent'd died member resumes" "$out_cx" "1 resumed"
assert_contains "crew-resume's own composition site emits the context-suppression flag too" \
  "$(grep -E '(^|[[:space:]])exec ' "$WINGMAN_HOME/crew/cx1.resume.sh" 2>/dev/null)" "-c project_doc_max_bytes=0"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- issue #25 plan §4.8 / §7 test 8: relaunch mode's actual composed brief -
# (PR #335 review round 1, finding 4: this file previously had zero coverage
# of relaunch mode itself - only tests/crew-takeover.test.sh's hint-text
# check, which never runs bin/crew-resume at all). A throwaway descriptor
# with no WM_AGENT_RESUME_FLAG (same shape as crew-takeover.test.sh's own
# __test-no-resume-flag, unconditionally removed before test_summary since
# this file cannot use its own trap) forces relaunch mode; WM_AGENT_SYSPROMPT_
# MODE=positional folds the whole composed payload into the launch script's
# own command line, so it can be asserted on directly with no live-pane
# capture needed - WM_AGENT_OPENING_DELIVERED_AT_LAUNCH=1 for this mode, so
# crew-resume never attempts a separate post-launch nudge either. ------------
RELAUNCH_DESC="$TEST_REPO/bin/lib/agents/__test-relaunch-positional.sh"
cat > "$RELAUNCH_DESC" <<'EOF'
WM_AGENT_BIN="__test-relaunch-positional"
WM_AGENT_DISPLAY_NAME="Test Relaunch Positional Adapter"
WM_AGENT_SYSPROMPT_MODE=positional
EOF
test_new_home
wm_trust_repo /tmp
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id rl1 --type developer \
  --objective "port the widget subsystem to the new adapter layer" \
  --input "docs/plans/widget-plan.md" \
  --repo /tmp --window wm-rl1 --session-id sess-rl1 \
  --agent __test-relaunch-positional >/dev/null
wm_state crew-set --id rl1 --status died --artifact /tmp/widget-report.md \
  --delivery "https://github.com/x/y/pull/9" --allow-merge true \
  --summary "landed the first half; second half still open" >/dev/null
out_rl="$(WM_AGENT_BIN_OVERRIDE="$ALIVE_STUB" "$CR" rl1 2>&1)"
assert_contains "relaunch (no resume flag) still reports resumed" "$out_rl" "1 resumed"
assert_eq "relaunch preserves the crew id's window name" "$(field_of rl1 window)" "wm-rl1"
assert_true "the relaunched window exists under the SAME name" \
  "tmux list-windows -t '$WM_TMUX_SESSION' -F '#{window_name}' 2>/dev/null | grep -qx wm-rl1"
rl_script="$(cat "$WINGMAN_HOME/crew/rl1.resume.sh")"
# Round 2 nice-to-have: relaunch mode's whole point is that it composes NO
# resume-shaped flag (there is no session to resume) - the property this
# mode exists to guarantee, worth a permanent, explicit negative rather than
# only exercising it incidentally via the fixture's throwaway descriptor
# never defining WM_AGENT_RESUME_FLAG in the first place.
assert_not_contains "relaunch composes no resume-shaped flag at all" "$rl_script" "--resume"
# Finding 2: the objective is actually present, not silently dropped.
assert_contains "relaunch brief carries the 'your assignment' section" "$rl_script" "Your assignment (unchanged since spawn)"
assert_contains "...with the actual objective text" "$rl_script" "port the widget subsystem to the new adapter layer"
# Finding 3: the --input handoff pointer survives into BOTH the rebuilt
# sysprompt.md (via wm_compose_crew_sysprompt) and the relaunch note itself,
# rather than being silently dropped when the file is overwritten.
assert_contains "relaunch brief's assignment section carries the input handoff pointer" "$rl_script" "docs/plans/widget-plan.md"
rl_sysprompt="$(cat "$WINGMAN_HOME/crew/rl1.sysprompt.md")"
assert_contains "the rebuilt sysprompt.md itself still carries the original input handoff" \
  "$rl_sysprompt" "Input handoff: read the plan/spec at \`docs/plans/widget-plan.md\` and follow it."
# The rest of the three-layer progress note, unaffected by this fix but worth
# confirming still present and in the right relative order now that a new
# section was inserted ahead of them.
assert_contains "durably-recorded section: the artifact" "$rl_script" "widget-report.md"
assert_contains "durably-recorded section: the delivery" "$rl_script" "pull/9"
assert_contains "durably-recorded section: allow_merge" "$rl_script" "Merge autonomy (--allow-merge) is already granted"
assert_contains "worktree-state section header present" "$rl_script" "Worktree state as of relaunch"
assert_contains "last-reported-summary section present" "$rl_script" "Your own last reported summary"
assert_contains "...with the actual summary text" "$rl_script" "landed the first half; second half still open"
order_check="$(uv run --no-project --quiet python -c '
import sys
text = sys.stdin.read()
markers = [
    "Your assignment (unchanged since spawn)",
    "What is already durably recorded",
    "Worktree state as of relaunch",
    "Your own last reported summary",
]
positions = [text.find(m) for m in markers]
print("ok" if all(p != -1 for p in positions) and positions == sorted(positions) else "bad: %r" % positions)
' <<<"$rl_script")"
assert_eq "the four sections appear in the documented order (assignment, durable grants, worktree, summary)" "$order_check" "ok"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null
rm -f "$RELAUNCH_DESC"

test_summary
