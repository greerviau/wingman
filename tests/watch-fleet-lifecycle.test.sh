#!/usr/bin/env bash
# E2E: the wake loop's ownership and lifecycle self-checks. Proves run-id
# ownership (a healthy cycle is run-scoped; a foreign cycle is replaced, not
# adopted); the escape hatch for a check-in nudge that can never be delivered
# (issue #214 §3.6); a stalled classification that self-corrects silently once
# real liveness returns, with the one exemption (a genuine wedge revert to
# `blocked` fires once) - issue #235. The bulk of the file is issue #237's
# orphan-watcher-lifecycle: the owner-scoped self-checks (a cycle armed from a
# now-removed worktree, an irrecoverably-died or vanished owner, a failing
# owner-status read) and the identity-verified singleton lock with its
# hard-staleness takeover (a reused pid, owner_lock_alive()'s TZ-pinned
# identity comparison, an unreaped zombie, lock-file mkdir/write races, and
# the stale-code self-check's own anti-spin bound and worktree-removal race).
# One of three sibling files split from a single, much larger file (then named
# tests/watch-fleet.test.sh) once it became ~92% of the CI test job's own wall
# clock - see docs/analysis/2026-08-11-test-suite-slowness-investigation.md.
# See tests/watch-fleet.test.sh for the wake loop's core arm/fire/stall/
# permission-freeze semantics, and tests/watch-fleet-recovery.test.sh for
# Remote Control/lock/outage/usage-limit recovery.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
# For wm_ps_lstart (owner-identity verification, issue #303) and
# wm_tmux_send_lock (the send-lock reclaim cases), used by the singleton-lock
# and owner-scoped self-check cases below.
. "$TEST_REPO/bin/lib/common.sh"

WF="$TEST_REPO/bin/watch-fleet"
COMPOSER_STUB="$TEST_REPO/tests/fixtures/composer-stub.sh"
export WM_WATCH_INTERVAL=1
# The watcher blocks until an event fires, so bound every foreground run with
# wm_timeout and reap any backgrounded one on exit (lib.sh's shared trap; every
# background pid here is registered via wm_track). A watcher that never fires
# can then never wedge this file or, through run.sh, the whole suite.

# --- run-id ownership (#162): healthy is run-scoped, a foreign cycle is
# --- replaced rather than adopted --------------------------------------------
test_new_home
# r1 is backed by a real tmux window (issue #209): see b1's comment above.
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-r1 'sleep 600'
wm_state crew-add --id r1 --type analyst --objective e --repo /tmp --window wm-r1 --session-id s20 >/dev/null
wm_state crew-set --id r1 --status working --summary "busy" >/dev/null
WINGMAN_RUN_ID=run-old "$WF" >"$WINGMAN_HOME/old.log" 2>&1 &
oldpid=$!
wm_track "$oldpid"
sleep 3
assert_true "run-old's cycle is live and blocking" "kill -0 $oldpid"
assert_eq "cycle stamps its arming run id" "$(cat "$WINGMAN_HOME/watch.run")" "run-old"

# Same run id: healthy, nothing replaced.
outsame="$(WINGMAN_RUN_ID=run-old wm_timeout 45 "$WF" 2>&1)"
assert_contains "same-run re-arm reports healthy" "$outsame" "healthy"
assert_true "same-run re-arm leaves the cycle running" "kill -0 $oldpid"

# No run id on the arming side: ownership cannot be certified, legacy healthy.
# env -u makes this genuinely run-id-less regardless of what the invoking
# session exports (issue #170) - test_new_home already unsets WINGMAN_RUN_ID,
# but this test's whole point is the run-id-less path, so it asserts the
# precondition directly rather than relying on that unset holding by the time
# execution reaches here.
outnone="$(wm_timeout 45 env -u WINGMAN_RUN_ID "$WF" 2>&1)"
assert_contains "run-id-less arm keeps legacy healthy" "$outnone" "healthy"
assert_true "run-id-less arm leaves the cycle running" "kill -0 $oldpid"

# Different run id: the live foreign cycle is stopped and replaced in place.
WINGMAN_RUN_ID=run-new "$WF" >"$WINGMAN_HOME/new.log" 2>&1 &
newpid=$!
wm_track "$newpid"
sleep 3
assert_false "the foreign cycle was stopped by the new run's arm" "kill -0 $oldpid"
assert_true "the new run's own cycle is live and blocking" "kill -0 $newpid"
assert_contains "the arm announced the replacement" "$(cat "$WINGMAN_HOME/new.log")" "Replacing it with a cycle this run tracks"
assert_contains "the arm printed armed, never healthy" "$(cat "$WINGMAN_HOME/new.log")" "watcher: armed"
assert_eq "the run stamp now names the new run" "$(cat "$WINGMAN_HOME/watch.run")" "run-new"

# The replacement cycle is a fully functional watcher: it still fires.
wm_state crew-set --id r1 --status done --summary "done e" >/dev/null
sleep 3
assert_false "the replacement cycle fires normally" "kill -0 $newpid"
assert_contains "the replacement cycle printed the fire reason" "$(cat "$WINGMAN_HOME/new.log")" "done: r1"

# --- issue #214 §3.6: a nudge that can never be delivered still eventually --
# flips the member stalled, via the refused-nudge escape hatch, rather than
# exempting it from stall escalation forever. Simulated with a contended send
# lock (rc 4) - deterministic and trivial to hold open, unlike a genuinely
# busy pane (rc 6): a pane repainting fast enough for wm_tmux_send_message to
# read it "busy" would also read unstable to watch-fleet's own PANE_STABLE
# check above and never reach this block at all (§3.6's own note on why rc 2
# is unreachable here applies just as much to a real rc 6).
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id nu1 --type developer --objective f --repo /tmp --window wm-nu1 --session-id snu1 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-nu1 'trap "" INT; sleep 600'
wm_age_status nu1
# Pre-hold the per-pane send lock so every attempted nudge this test drives
# refuses with rc 4 rather than ever actually typing. The lock is a kernel
# flock() (issue #302), not a bare mkdir'd directory - genuinely holding it
# needs a real process calling wm_tmux_send_lock directly (the fd must live
# in the process that opens it), not a filesystem artifact a test can
# construct by hand.
_nu1_target="$(printf '=%s:=%s' "$WM_TMUX_SESSION" "wm-nu1")"
_nu1_holder="$(wm_mktemp_dir)/holder.sh"
cat > "$_nu1_holder" <<HOLDEREOF
#!/usr/bin/env bash
set -u
. "$TEST_REPO/bin/lib/common.sh"
wm_tmux_send_lock "$_nu1_target" || exit 9
echo "HOLDING \$\$"
while :; do sleep 0.05; done
HOLDEREOF
chmod +x "$_nu1_holder"
"$_nu1_holder" >"$WINGMAN_HOME/nu1-holder.out" 2>&1 &
_nu1_holder_shell_pid=$!
wm_track "$_nu1_holder_shell_pid"
_nu1_hi=0
while [ "$_nu1_hi" -lt 50 ]; do
  grep -q "^HOLDING " "$WINGMAN_HOME/nu1-holder.out" 2>/dev/null && break
  sleep 0.1; _nu1_hi=$((_nu1_hi+1))
done
assert_true "the pre-hold process genuinely acquired the send lock" \
  "grep -q '^HOLDING ' '$WINGMAN_HOME/nu1-holder.out'"
export WM_NUDGE_REFUSED_MAX=2
WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=1 \
  WM_SEND_LOCK_WAIT=1 \
  "$WF" >"$WINGMAN_HOME/nu1.log" 2>&1 &
nupid=$!
wm_track "$nupid"
# issue #236: .nudge-refused now carries "<count> <clock>" (extended from the
# bare-count shape #214 originally shipped) so the escape hatch's own
# --nudge-age can be derived from its own first-refusal clock rather than by
# stamping a synthetic .nudged the #236 confirm/retry parser would otherwise
# have to special-case. The two sidecars are therefore fully decoupled: .nudged
# is never touched by an undelivered-nudge episode (nothing was ever typed),
# only .nudge-refused is.
refusedfile="$WINGMAN_HOME/stall-nu1.nudge-refused"
refused_count_of() { awk '{print $1}' "$refusedfile" 2>/dev/null; }
_wait=0
while { [ ! -f "$refusedfile" ] || [ "$(refused_count_of)" -lt 2 ]; } && [ "$_wait" -lt 30 ]; do
  sleep 1; _wait=$((_wait+1))
done
assert_eq "the refused-nudge counter reaches WM_NUDGE_REFUSED_MAX before any nudge is ever delivered" \
  "$(refused_count_of)" "2"
nudgefile="$WINGMAN_HOME/stall-nu1.nudged"
assert_false "the escape hatch never stamps .nudged - that sidecar stays #236's alone" "[ -f '$nudgefile' ]"
assert_false "the escape hatch never sets nudged_at (it would render a false 'nudge sent' on the board)" \
  "wm_state crew-get --id nu1 | grep -q nudged_at"
i=0; while kill -0 "$nupid" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 1; i=$((i+1)); done
assert_false "watcher exited on the stall once the aged marker crossed the threshold" "kill -0 $nupid"
assert_contains "cycle exits with the stalled reason" "$(cat "$WINGMAN_HOME/nu1.log")" "stalled: nu1"
assert_contains "the reason names the undelivered nudge explicitly, not the generic template" \
  "$(cat "$WINGMAN_HOME/nu1.log")" "could not deliver a check-in nudge in 2 attempts"
kill "$nupid" 2>/dev/null
kill -KILL "$_nu1_holder_shell_pid" 2>/dev/null
wait "$_nu1_holder_shell_pid" 2>/dev/null
unset WM_NUDGE_REFUSED_MAX
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- issue #235: a stalled classification is self-correcting, and silently --
# Inverted reproduction of the incident behind #235
# (docs/plans/2026-08-04-issue-235-stalled-latch-plan.md, Appendix): a member
# is genuinely flipped stalled by a real watch-fleet cycle, comes back to
# unambiguous life (pane repainting continuously + a late-started descendant -
# the exact signal that was ABSENT at flip time), and a FRESH real
# watch-fleet cycle reverts it within a bounded number of polls - silently:
# the watcher never exits, the wake file is never rewritten, and no fire
# reason is ever printed naming it - while a genuinely still-dead sibling in
# the same fleet stays stalled throughout (the recheck never touches a
# record it has no evidence about). The only durable trace of the revert is
# a line in stall-recheck.log.
crew_status() { wm_state crew-get --id "$1" | uv run --no-project --quiet python -c "import json,sys; print(json.load(sys.stdin)['status'])"; }
crew_updated() { wm_state crew-get --id "$1" | uv run --no-project --quiet python -c "import json,sys; print(json.load(sys.stdin)['updated'])"; }

test_new_home
RV1_MARKER="$(wm_mktemp_file)"
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle

# rv1: flipped first, alone (so its own nudge-then-wait timing matches the
# proven single-candidate budget above, unslowed by any other candidate
# sharing the same poll cycle) - then recovers.
wm_state crew-add --id rv1 --type developer --objective e --repo /tmp --window wm-rv1 --session-id srv1 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-rv1 \
  "WM_TEST_BUSY=0 WM_TEST_SWALLOW=0 WM_TEST_MARKER='$RV1_MARKER' bash '$COMPOSER_STUB'"
sleep 1
wm_age_status rv1

WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=1 \
  "$WF" >"$WINGMAN_HOME/rv-p1.log" 2>&1 &
flip1_pid=$!
wm_track "$flip1_pid"
i=0; while kill -0 "$flip1_pid" 2>/dev/null && [ "$i" -lt 70 ]; do sleep 1; i=$((i+1)); done
kill "$flip1_pid" 2>/dev/null
assert_contains "rv1 flipped to stalled" "$(wm_state crew-get --id rv1)" '"status": "stalled"'

# Classify + ack the pending fire (matching the plan's own repro) so the next
# cycle genuinely POLLS this still-pending event instead of re-firing on arm.
"$WF" --classify >/dev/null 2>&1
rv1_updated_flip="$(crew_updated rv1)"
wm_state ack --id rv1 --updated "$rv1_updated_flip" >/dev/null

# dead2: a genuinely idle control that never recovers - added only now (after
# rv1's own flip is settled and acked) so it does not slow down rv1's own
# single-candidate flip timing above, and flipped by its own dedicated cycle
# for the identical reason. Backed by the SAME composer-stub fixture as rv1
# (not a bare `sleep 600`, and confirmed empirically why): a 'working'
# candidate always gets a check-in nudge typed into its pane before stall-
# check is even allowed to flip it, and a bare `sleep` has no composer to
# absorb that - the nudge's own keystrokes kill the pane's foreground
# process outright, closing the window and producing 'died', not 'stalled'.
DEAD2_MARKER="$(wm_mktemp_file)"
wm_state crew-add --id dead2 --type developer --objective f --repo /tmp --window wm-dead2 --session-id sdead2 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-dead2 \
  "WM_TEST_BUSY=0 WM_TEST_SWALLOW=0 WM_TEST_MARKER='$DEAD2_MARKER' bash '$COMPOSER_STUB'"
sleep 1
wm_age_status dead2

WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=1 \
  "$WF" >"$WINGMAN_HOME/rv-p1b.log" 2>&1 &
flip2_pid=$!
wm_track "$flip2_pid"
i=0; while kill -0 "$flip2_pid" 2>/dev/null && [ "$i" -lt 70 ]; do sleep 1; i=$((i+1)); done
kill "$flip2_pid" 2>/dev/null
assert_contains "dead2 flipped to stalled" "$(wm_state crew-get --id dead2)" '"status": "stalled"'
"$WF" --classify >/dev/null 2>&1
wm_state ack --id dead2 --updated "$(crew_updated dead2)" >/dev/null

# rv1 comes back to unambiguous life: same window name, a pane that repaints
# continuously and holds a late-started descendant.
tmux kill-window -t "$WM_TMUX_SESSION:wm-rv1" 2>/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-rv1 \
  'sh -c "sleep 4; while :; do echo tick; sleep 1; done"'
sleep 6

wake_before="$(cat "$WINGMAN_HOME/wake" 2>/dev/null || true)"

WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=1 \
  WM_STALL_RECHECK_CONFIRMS=2 \
  "$WF" >"$WINGMAN_HOME/rv-p2.log" 2>&1 &
rv2_pid=$!
wm_track "$rv2_pid"
i=0
while [ "$i" -lt 20 ]; do
  [ "$(crew_status rv1)" = working ] && break
  sleep 1; i=$((i+1))
done

assert_eq "rv1 reverted to working within a bounded number of polls" "$(crew_status rv1)" working
assert_true "the fix actually fixed the reported thing: updated is no longer the flip stamp" \
  "[ '$(crew_updated rv1)' != '$rv1_updated_flip' ]"
assert_eq "dead2 stays stalled throughout - the recheck never touches an unrelated record" \
  "$(crew_status dead2)" stalled

assert_true "the watcher NEVER EXITS across the silent revert - it keeps blocking" "kill -0 $rv2_pid"
assert_eq "the wake file is byte-identical - never rewritten for a silent auto-clear" \
  "$(cat "$WINGMAN_HOME/wake" 2>/dev/null || true)" "$wake_before"
assert_not_contains "no fire reason is ever printed for rv1's revert" "$(cat "$WINGMAN_HOME/rv-p2.log")" "rv1"

assert_true "stall-recheck.log recorded the clear" "[ -f '$WINGMAN_HOME/stall-recheck.log' ]"
assert_contains "the log line names rv1 and the liveness source" \
  "$(cat "$WINGMAN_HOME/stall-recheck.log")" "rv1 liveness cleared after"

kill "$rv2_pid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- issue #235: a wedge revert to 'blocked' DOES fire once ------------------
# The one exemption to the silent-clear rule: the restored blocker is a
# genuinely open question nobody answered, so it re-announces exactly once
# through the ordinary needs-attention path - not through anything the
# recheck itself does.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id wb1 --type developer --objective x --repo /tmp --window wm-wb1 --session-id swb1 >/dev/null
wm_state crew-set --id wb1 --status blocked --blocker "which approach?" >/dev/null
# Ack the pre-existing 'blocked' state itself before the flip watcher ever
# starts - otherwise the FIRST cycle fires immediately on THIS already-
# actionable event (needs-attention has no notion of "wait for wedge-check
# to get a look first"), before the wedge signature below ever gets a chance
# to run any poll at all.
wm_state ack --id wb1 --updated "$(crew_updated wb1)" >/dev/null
# A pane that repaints continuously (never idle at a prompt) and holds a
# `sleep`-matching descendant - the FOREGROUND-watcher wedge signature (issue
# #202). The descendant is reaped by a waiting subshell the instant it dies
# (verified empirically, mirroring tests/stall-recheck.test.sh's own fixture)
# so killing it later leaves no zombie for _ps_tree to still see. proc-re is
# narrowed to `sleep` (not the production default) purely to keep the
# fixture simple.
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-wb1 \
  'sleep 600 & child=$!; ( wait $child ) 2>/dev/null & while :; do echo tick; sleep 1; done'
sleep 1

WM_WEDGE_SECS=3 WM_WEDGE_PANE_GAP=5 WM_WEDGE_PROC_RE=sleep WM_WATCH_INTERVAL=1 \
  "$WF" >"$WINGMAN_HOME/wb-p1.log" 2>&1 &
wbflip_pid=$!
wm_track "$wbflip_pid"
i=0; while kill -0 "$wbflip_pid" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 1; i=$((i+1)); done
kill "$wbflip_pid" 2>/dev/null
assert_contains "the wedge flip fires with the FOREGROUND signature" "$(cat "$WINGMAN_HOME/wb-p1.log")" "stalled: wb1"
assert_contains "wb1 flipped to stalled" "$(wm_state crew-get --id wb1)" '"status": "stalled"'
"$WF" --classify >/dev/null 2>&1
wm_state ack --id wb1 --updated "$(crew_updated wb1)" >/dev/null

# Kill the wedging descendant so its pane's process tree no longer holds it -
# the wedge clearing predicate's own evidence.
wedge_pid="$(wm_state crew-get --id wb1 | uv run --no-project --quiet python -c "import json,sys; print(json.load(sys.stdin)['stall']['wedge_pid'])")"
kill "$wedge_pid" 2>/dev/null
sleep 1

out="$(wm_timeout 45 env WM_WEDGE_SECS=3 WM_WEDGE_PANE_GAP=5 WM_WEDGE_PROC_RE=sleep \
  WM_STALL_RECHECK_CONFIRMS=2 WM_WATCH_INTERVAL=1 "$WF" 2>/dev/null)"
assert_contains "the revert to blocked fires once, naming the restored blocker" "$out" "blocked: wb1"
assert_contains "the fire carries the restored blocker text" "$out" "which approach?"
assert_contains "wb1 is genuinely back to blocked" "$(wm_state crew-get --id wb1)" '"status": "blocked"'

tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# ============================================================================
# issue #237: orphan-watcher-lifecycle - the owner-scoped self-checks (Fix 2),
# the identity-verified singleton lock and hard-staleness takeover (Fix 3)
# ============================================================================

wait_for_owner_status() {
  _wos_i=0
  while [ "$_wos_i" -lt 50 ]; do
    "$WF" --owner "$1" --status >/dev/null 2>&1 && return 0
    sleep 0.2
    _wos_i=$((_wos_i + 1))
  done
  return 1
}

wait_for_pid_gone() {
  _wpg_i=0
  while [ "$_wpg_i" -lt 75 ]; do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.2
    _wpg_i=$((_wpg_i + 1))
  done
  return 1
}

# --- Fix 2a: a cycle armed from a worktree that has since been removed -------
# self-stops within one poll, with no standdown ever involved - the incident's
# own single most distinctive fact ("the worktree ... no longer existed").
# $0 is resolved from inside a throwaway directory (mirroring this plan's own
# reproduction), which is then removed out from under the running cycle. wt1
# is backed by a real tmux window (issue #209, and round-2 review MF-4's own
# finding): without one, reconcile flips a windowless "working" record to
# died on an early poll, and Fix 2b's own owner-status self-check then races
# ahead of the worktree-removal self-check this test means to isolate -
# masking the real assertions behind a coincidentally-similar outcome.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-wt1 'sleep 600'
WT_PARENT="$(wm_mktemp_dir)"
WT_DIR="$WT_PARENT/fake-worktree"
mkdir -p "$WT_DIR"
cp "$WF" "$WT_DIR/watch-fleet"
chmod +x "$WT_DIR/watch-fleet"
ln -s "$TEST_REPO/bin/lib" "$WT_DIR/lib"
wm_state crew-add --id wt1 --type lead --objective x --repo /tmp --window wm-wt1 --session-id swt1 >/dev/null
wm_state crew-set --id wt1 --status working --summary "in progress" >/dev/null
"$WT_DIR/watch-fleet" --owner wt1 >"$WINGMAN_HOME/wt1.log" 2>&1 &
wt1pid=$!
wm_track "$wt1pid"
assert_true "the cycle armed from the throwaway worktree comes up live" "wait_for_owner_status wt1"
rm -rf "$WT_PARENT"
assert_true "the cycle self-exits once its own worktree directory is gone" "wait_for_pid_gone $wt1pid"
wtclassify="$(wm_timeout 10 "$WF" --owner wt1 --classify 2>/dev/null)"
assert_eq "the worktree-removal self-stop classifies as a deliberate stop, not a spurious failure" "$wtclassify" "stopped"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- Fix 2b: a cycle self-stops once its owner is irrecoverably died, with no
# standdown ever called (a crashed lead nobody has stood down yet) -----------
# A real tmux window keeps the only cause of death here the explicit crew-set
# below, not reconcile racing ahead of it for an unrelated reason.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-dead1 'sleep 600'
wm_state crew-add --id dead1 --type lead --objective x --repo /tmp --window wm-dead1 --session-id sdead1 >/dev/null
wm_state crew-set --id dead1 --status working --summary "in progress" >/dev/null
"$WF" --owner dead1 >"$WINGMAN_HOME/dead1.log" 2>&1 &
dead1pid=$!
wm_track "$dead1pid"
assert_true "dead1's scoped cycle comes up live" "wait_for_owner_status dead1"
wm_state crew-set --id dead1 --status died >/dev/null
assert_true "the cycle self-stops once its owner is irrecoverably died" "wait_for_pid_gone $dead1pid"
deadclassify="$(wm_timeout 10 "$WF" --owner dead1 --classify 2>/dev/null)"
assert_eq "the died-owner self-stop classifies as a deliberate stop" "$deadclassify" "stopped"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- Fix 2b: died-but-RESUMABLE does NOT self-stop (issue #254 interaction) --
# A died member's session transcript surviving on disk is exactly the case
# #254's own takeover path exists for - self-stopping the watcher here would
# strand that recovery path's own wake channel. A real tmux window keeps the
# only cause of death the explicit crew-set below, not reconcile.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-resume1 'sleep 600'
PROJDIR="$(wm_mktemp_dir)"
export WM_CLAUDE_PROJECTS_DIR="$PROJDIR"
RESUME_SLUG="$(printf '%s' /tmp | sed -E 's/[^A-Za-z0-9-]/-/g')"
mkdir -p "$PROJDIR/$RESUME_SLUG"
: > "$PROJDIR/$RESUME_SLUG/sresume1.jsonl"
wm_state crew-add --id resume1 --type lead --objective x --repo /tmp --window wm-resume1 --session-id sresume1 >/dev/null
wm_state crew-set --id resume1 --status working --summary "in progress" >/dev/null
"$WF" --owner resume1 >"$WINGMAN_HOME/resume1.log" 2>&1 &
resume1pid=$!
wm_track "$resume1pid"
assert_true "resume1's scoped cycle comes up live" "wait_for_owner_status resume1"
wm_state crew-set --id resume1 --status died >/dev/null
assert_contains "resume1 is genuinely resumable (transcript on disk)" "$(wm_state crew-get --id resume1)" '"resumable": true'
sleep 4
assert_true "a resumable died owner's cycle keeps polling, not self-stopped" "kill -0 $resume1pid"
kill "$resume1pid" 2>/dev/null
unset WM_CLAUDE_PROJECTS_DIR
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- Fix 2b: a genuinely vanished-from-roster owner self-stops, debounced ----
# wm_state has no delete subcommand; bin/crew-prune (via `wm_state prune`)
# removes fully-closed (stood-down) records, reaching the genuinely-missing-
# record path with no hand-crafted fixture.
test_new_home
wm_state crew-add --id gone1 --type lead --objective x --repo /tmp --window wm-gone1 --session-id sgone1 >/dev/null
wm_state standdown --id gone1 >/dev/null
wm_state prune >/dev/null
assert_eq "gone1's record is genuinely gone from the roster" "$(wm_state crew-get --id gone1 2>/dev/null)" ""
"$WF" --owner gone1 >"$WINGMAN_HOME/gone1.log" 2>&1 &
gone1pid=$!
wm_track "$gone1pid"
assert_true "the vanished-owner cycle self-stops (debounced) once confirmed gone" "wait_for_pid_gone $gone1pid"
goneclassify="$(wm_timeout 10 "$WF" --owner gone1 --classify 2>/dev/null)"
assert_eq "the vanished-owner self-stop classifies as a deliberate stop" "$goneclassify" "stopped"

# --- Fix 2b SF1: a crew-get failure does not immediately self-stop a healthy
# owner's watcher - it debounces across WM_OWNER_MISSING_CONFIRMS consecutive
# ambiguous reads before acting -----------------------------------------------
# A real tmux window (round-2 review MF-4's own finding, applied here too):
# without one, reconcile flips sf1's record to died on an early poll, and
# once the stub's own recovery call (poll 3+) falls through to the REAL
# crew-get, it would read "died" instead of "working" - self-stopping the
# cycle for a reason this test does not mean to exercise at all.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-sf1 'sleep 600'
wm_state crew-add --id sf1 --type lead --objective x --repo /tmp --window wm-sf1 --session-id ssf1 >/dev/null
wm_state crew-set --id sf1 --status working --summary "in progress" >/dev/null

STUB_A="$(wm_mktemp_file)"
COUNTER_A="$(wm_mktemp_file)"; rm -f "$COUNTER_A"
cat > "$STUB_A" <<STUBEOF
#!/usr/bin/env bash
case "\$1" in
  */wm-state.py)
    if [ "\$2" = "crew-get" ] && [ "\$3" = "--id" ] && [ "\$4" = "sf1" ]; then
      n="\$(cat "$COUNTER_A" 2>/dev/null)"; case "\$n" in ''|*[!0-9]*) n=0 ;; esac
      n=\$((n+1))
      printf '%s\n' "\$n" > "$COUNTER_A"
      [ "\$n" -le 2 ] && exit 1
    fi
    ;;
esac
exec uv run --no-project --quiet "\$@"
STUBEOF
chmod +x "$STUB_A"
WM_UV="$STUB_A" "$WF" --owner sf1 >"$WINGMAN_HOME/sf1.log" 2>&1 &
sf1pid=$!
wm_track "$sf1pid"
assert_true "sf1's cycle comes up live despite a failing stub in place" "wait_for_owner_status sf1"
# Poll (bounded, generous) for the stub to have actually been called at
# least 3 times - i.e. genuinely past its own 2-failure window - rather than
# a fixed sleep: every wm_py/wm_state call in this cycle routes through the
# stub (WM_UV is process-wide), so poll cadence is not assumed.
_sf1_i=0
while { _sf1_n="$(cat "$COUNTER_A" 2>/dev/null)"; case "$_sf1_n" in ''|*[!0-9]*) _sf1_n=0 ;; esac; [ "$_sf1_n" -lt 3 ]; } \
  && [ "$_sf1_i" -lt 100 ]; do
  sleep 0.2; _sf1_i=$((_sf1_i + 1))
done
assert_true "the stub was actually exercised past its own 2-failure window" "[ \"\$(cat '$COUNTER_A' 2>/dev/null)\" -ge 3 ]"
assert_true "two transient ambiguous reads (below the confirm threshold) never self-stop a healthy owner" "kill -0 $sf1pid"
kill "$sf1pid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# The genuinely-and-persistently-ambiguous case: the stub fails every poll,
# standing in for a sustained inability to resolve the owner's status - the
# same debounce applies, but self-stop follows once the confirm threshold
# (WM_OWNER_MISSING_CONFIRMS, default 3) is actually reached. The stub never
# falls through to a real crew-get here, so no tmux window is needed for
# correctness - added anyway for consistency with the rest of this file.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-sf2 'sleep 600'
wm_state crew-add --id sf2 --type lead --objective x --repo /tmp --window wm-sf2 --session-id ssf2 >/dev/null
wm_state crew-set --id sf2 --status working --summary "in progress" >/dev/null

STUB_B="$(wm_mktemp_file)"
cat > "$STUB_B" <<STUBEOF
#!/usr/bin/env bash
case "\$1" in
  */wm-state.py)
    if [ "\$2" = "crew-get" ] && [ "\$3" = "--id" ] && [ "\$4" = "sf2" ]; then
      exit 1
    fi
    ;;
esac
exec uv run --no-project --quiet "\$@"
STUBEOF
chmod +x "$STUB_B"
WM_UV="$STUB_B" "$WF" --owner sf2 >"$WINGMAN_HOME/sf2.log" 2>&1 &
sf2pid=$!
wm_track "$sf2pid"
assert_true "sf2's cycle comes up live" "wait_for_owner_status sf2"
assert_true "a persistently ambiguous owner read self-stops once the confirm threshold is reached" "wait_for_pid_gone $sf2pid"
sf2classify="$(wm_timeout 10 "$WF" --owner sf2 --classify 2>/dev/null)"
assert_eq "the confirmed-gone self-stop classifies as a deliberate stop" "$sf2classify" "stopped"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- Fix 3 MF2: a stall under the hard-grace threshold is never stolen from -
# (mirrors this plan's own repro 2, at the new, coarser threshold). A real
# tmux window (round-2 review MF-4's own finding, applied here too): without
# one, reconcile flips hg1 to died mid-test and Fix 2b's own self-check
# would remove the very pidfile this test polls, for a reason unrelated to
# the hard-grace behavior actually under test.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-hg1 'sleep 600'
wm_state crew-add --id hg1 --type lead --objective x --repo /tmp --window wm-hg1 --session-id shg1 >/dev/null
wm_state crew-set --id hg1 --status working --summary "in progress" >/dev/null
export WM_WATCH_HARD_GRACE=20
"$WF" --owner hg1 >"$WINGMAN_HOME/hg1.log" 2>&1 &
hg1pid=$!
wm_track "$hg1pid"
assert_true "hg1's cycle comes up live" "wait_for_owner_status hg1"
kill -STOP "$hg1pid"
sleep 3   # well under the 20s hard grace
before_pid="$(cat "$WINGMAN_HOME/watch-hg1.pid" 2>/dev/null)"
out2="$(wm_timeout 15 "$WF" --owner hg1 2>&1)"
assert_contains "a stall under hard grace reports healthy, not a takeover" "$out2" "healthy"
after_pid="$(cat "$WINGMAN_HOME/watch-hg1.pid" 2>/dev/null)"
assert_eq "the pidfile is unchanged - no rival claim while under hard grace" "$after_pid" "$before_pid"
kill -CONT "$hg1pid" 2>/dev/null
kill "$hg1pid" 2>/dev/null
unset WM_WATCH_HARD_GRACE
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- Fix 3 MF2 (round-2 MF-A): a wedge beyond hard grace is taken over, ------
# escalating SIGTERM -> SIGKILL, since a genuinely SIGSTOPped process cannot
# process a SIGTERM until it is continued or killed outright - the same
# unresponsive-to-SIGTERM shape a cycle wedged in a blocking foreground child
# (e.g. a hung tmux call) exhibits, per this plan's own repro 3. A real tmux
# window (round-2 review MF-4's own finding): without one, reconcile flips
# hg2 to died shortly after the takeover's fresh claim, and Fix 2b's own
# self-check then self-stops the fresh claimant for a reason unrelated to
# the wedge-takeover behavior this test actually means to exercise - this
# case is about taking over a genuinely WEDGED holder, not a dead owner.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-hg2 'sleep 600'
wm_state crew-add --id hg2 --type lead --objective x --repo /tmp --window wm-hg2 --session-id shg2 >/dev/null
wm_state crew-set --id hg2 --status working --summary "in progress" >/dev/null
export WM_WATCH_HARD_GRACE=2
"$WF" --owner hg2 >"$WINGMAN_HOME/hg2.log" 2>&1 &
hg2pid=$!
wm_track "$hg2pid"
assert_true "hg2's cycle comes up live" "wait_for_owner_status hg2"
kill -STOP "$hg2pid"
sleep 4   # past the 2s hard grace
# NOT wm_timeout: a winning takeover falls through into "claim the cycle" and
# then BLOCKS (it is the fresh live cycle), so it never exits on its own -
# capturing it via a bounded foreground wm_timeout would only ever return
# once wm_timeout's own deadline force-kills it, discarding the very pid this
# block needs to assert is genuinely live. Background it instead, exactly
# like every other "arm a cycle" case in this suite, and poll its own log for
# its own "watcher: armed" line - the takeover completing (the old holder
# actually dying) is a strict PREFIX of that, so waiting for "armed" directly
# is the correct completion signal; waiting only for the old pid's death
# races ahead of the fresh claimant finishing its own claim sequence
# (teardown, OWNERLOCK creation, etc.) afterward.
"$WF" --owner hg2 >"$WINGMAN_HOME/hg2-takeover.log" 2>&1 &
newhg2pid=$!
wm_track "$newhg2pid"
_hg2_i=0
while ! grep -q "watcher: armed" "$WINGMAN_HOME/hg2-takeover.log" 2>/dev/null && [ "$_hg2_i" -lt 100 ]; do
  sleep 0.2; _hg2_i=$((_hg2_i + 1))
done
assert_true "the wedged (SIGSTOPped) holder is actually reaped by the takeover" "! kill -0 $hg2pid 2>/dev/null"
out3="$(cat "$WINGMAN_HOME/hg2-takeover.log")"
assert_contains "the arm detects the wedge and announces a takeover" "$out3" "treating as wedged and taking over"
assert_contains "the takeover claims a fresh cycle (armed, not healthy)" "$out3" "watcher: armed"
assert_true "the fresh claimant's pid is genuinely live" "kill -0 $newhg2pid"
# A bare read, not a poll: $PIDFILE is written well before this process's own
# "armed" line (already matched above), so by this point it is a same-machine
# read of a file another process already committed - not the kind of gap a
# poll defends against. With hg2 backed by a real tmux window (above), the
# fresh claimant also never self-stops out from under this assertion the way
# it did before that fixture existed.
assert_eq "the pidfile now names the fresh claimant" "$(cat "$WINGMAN_HOME/watch-hg2.pid" 2>/dev/null)" "$newhg2pid"
kill "$newhg2pid" 2>/dev/null
unset WM_WATCH_HARD_GRACE
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- Fix 3 MF1: a reused pid does not falsely pass identity verification ----
# Pre-seeds $OWNERLOCK with the test harness's own live pid ($$) and a
# mismatched start-time stamp - the cheapest available stand-in for a
# reboot-inherited reused pid, since it is trivially live but is not a
# watch-fleet cycle at all. NOT wm_timeout: identity verification failing
# means owner_lock_alive() is false, so this arm falls straight through to a
# normal claim and BLOCKS (it is the fresh live cycle) - a foreground
# wm_timeout would only ever return once its own deadline force-kills it,
# stalling this case for its full bound every run for no reason. Backgrounded
# instead, with a real tmux window (round-2 review MF-4's own finding,
# applied here too) so reconcile never flips ri1 to died out from under it.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-ri1 'sleep 600'
wm_state crew-add --id ri1 --type lead --objective x --repo /tmp --window wm-ri1 --session-id sri1 >/dev/null
wm_state crew-set --id ri1 --status working --summary "in progress" >/dev/null
mkdir "$WINGMAN_HOME/watch-ri1.pid.owner"
# The third line ("lstart-utc") marks this as a stamp whose start time was
# rendered by the pinned wm_ps_lstart (issue #303) - load-bearing here: a
# marker-less stamp instead degrades to identity-unverifiable (kill -0
# alone), which would read $$ as the live owner and route this arm into the
# wedged-takeover branch, killing the process running this test file.
printf '%s\n%s\n%s\n' "$$" "not-a-real-start-time" "lstart-utc" > "$WINGMAN_HOME/watch-ri1.pid.owner/owner"
"$WF" --owner ri1 >"$WINGMAN_HOME/ri1.log" 2>&1 &
ri1pid=$!
wm_track "$ri1pid"
_ri1_i=0
while ! grep -q "watcher: armed" "$WINGMAN_HOME/ri1.log" 2>/dev/null && [ "$_ri1_i" -lt 75 ]; do
  sleep 0.2; _ri1_i=$((_ri1_i + 1))
done
out4="$(cat "$WINGMAN_HOME/ri1.log")"
assert_contains "a fresh arm claims normally over a reused-pid stamp mismatch" "$out4" "watcher: armed"
assert_not_contains "the fresh arm never reports healthy against the mismatched stamp" "$out4" "healthy"
assert_not_contains "no takeover is attempted against the harness's own process" "$out4" "taking over"
assert_true "the test harness's own process ($$) is left untouched" "kill -0 $$"
assert_true "the fresh claimant's pid is genuinely live" "kill -0 $ri1pid"
kill "$ri1pid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- issue #303: owner_lock_alive()'s TZ-pinned identity comparison ---------
# ps -o lstart= renders an absolute instant into the CALLING process's own
# local time (unpinned), so a stamping cycle and a later checking process
# under a different $TZ would render the very same live process's start time
# as two different strings - misreading a live cycle as dead, the opposite
# (and more dangerous) polarity from issue #298's send-lock defect. Guard the
# precondition first: a minimal container with no tzdata renders every
# unresolvable zone identically to UTC, which would make every case below
# pass vacuously against unfixed code (mirrors the zoneinfo gap in PR #301's
# own $TZ case, closed here for all three zones this file uses).
_tz303_probe="$(TZ=America/New_York ps -o lstart= -p $$ | sed -e 's/^ *//' -e 's/ *$//')"
_tz303_probe2="$(TZ=Asia/Tokyo ps -o lstart= -p $$ | sed -e 's/^ *//' -e 's/ *$//')"
_tz303_probe3="$(TZ=Asia/Kathmandu ps -o lstart= -p $$ | sed -e 's/^ *//' -e 's/ *$//')"
if [ "$_tz303_probe" = "$_tz303_probe2" ] || [ "$_tz303_probe" = "$_tz303_probe3" ] || [ "$_tz303_probe2" = "$_tz303_probe3" ]; then
  echo "SKIP: this host's zoneinfo does not distinguish America/New_York, Asia/Tokyo, and Asia/Kathmandu (missing tzdata?) - skipping the issue #303 TZ-mismatch cases" >&2
else
  # Primary case: arm under one $TZ, confirm the cycle is read as LIVE (not
  # dead) when checked under a different $TZ via --status, then prove the
  # actual dual-watcher hazard directly: a second arm attempt under a THIRD,
  # genuinely distinct offset (Asia/Kathmandu is +05:45 - not Asia/Pyongyang,
  # which has been identical to Asia/Tokyo, UTC+9, since 2018) must recognize
  # the existing cycle rather than claim a rival one.
  test_new_home
  tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
  tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-tz1 'sleep 600'
  wm_state crew-add --id tz1 --type lead --objective x --repo /tmp --window wm-tz1 --session-id stz1 >/dev/null
  wm_state crew-set --id tz1 --status working --summary "in progress" >/dev/null
  TZ=America/New_York "$WF" --owner tz1 >"$WINGMAN_HOME/tz1.log" 2>&1 &
  tz1pid=$!
  wm_track "$tz1pid"
  _tz1_i=0
  while ! grep -q "watcher: armed" "$WINGMAN_HOME/tz1.log" 2>/dev/null && [ "$_tz1_i" -lt 100 ]; do
    sleep 0.2; _tz1_i=$((_tz1_i + 1))
  done
  out_tz1status="$(TZ=Asia/Tokyo "$WF" --owner tz1 --status 2>&1)"
  assert_contains "a cycle armed under one \$TZ reads live when checked under another" "$out_tz1status" "watch-fleet cycle live"
  assert_not_contains "it is never misread as dead across a \$TZ mismatch" "$out_tz1status" "no live watch-fleet cycle"
  # wm_timeout, not backgrounded: on the intended path this exits immediately
  # ("already armed and healthy"); on a regression it re-enters the claim
  # path and blocks forever (that is what an armed cycle does), which would
  # hang this file - tests/lib.sh:172-181 documents wm_timeout for exactly
  # this failure mode.
  out_tz1arm2="$(TZ=Asia/Kathmandu wm_timeout 10 "$WF" --owner tz1 2>&1)"
  assert_contains "a second arm under a third \$TZ recognizes the existing cycle" "$out_tz1arm2" "already armed and healthy"
  assert_eq "the pidfile still names the first-armed pid, not a rival claimant" "$(cat "$WINGMAN_HOME/watch-tz1.pid" 2>/dev/null)" "$tz1pid"
  assert_true "the first-armed pid is still alive" "kill -0 $tz1pid"
  kill "$tz1pid" 2>/dev/null
  tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

  # Legacy-stamp case: a marker-less two-line stamp (standing in for one a
  # pre-#303 cycle would have left on disk mid-rollout) must degrade to
  # trusting kill -0 alone - i.e. still the live owner, never misread as
  # reused/dead and never claimed over.
  test_new_home
  tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
  tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-tz2 'sleep 600'
  wm_state crew-add --id tz2 --type lead --objective x --repo /tmp --window wm-tz2 --session-id stz2 >/dev/null
  wm_state crew-set --id tz2 --status working --summary "in progress" >/dev/null
  "$WF" --owner tz2 >"$WINGMAN_HOME/tz2.log" 2>&1 &
  tz2pid=$!
  wm_track "$tz2pid"
  _tz2_i=0
  while ! grep -q "watcher: armed" "$WINGMAN_HOME/tz2.log" 2>/dev/null && [ "$_tz2_i" -lt 100 ]; do
    sleep 0.2; _tz2_i=$((_tz2_i + 1))
  done
  _tz2_start="$(sed -n '2p' "$WINGMAN_HOME/watch-tz2.pid.owner/owner" 2>/dev/null)"
  printf '%s\n%s\n' "$tz2pid" "$_tz2_start" > "$WINGMAN_HOME/watch-tz2.pid.owner/owner"
  out_tz2status="$("$WF" --owner tz2 --status 2>&1)"
  assert_contains "a marker-less (legacy) stamp for a genuinely live pid still reads live" "$out_tz2status" "watch-fleet cycle live"
  out_tz2arm2="$(wm_timeout 10 "$WF" --owner tz2 2>&1)"
  assert_contains "a second arm against a legacy stamp recognizes the existing cycle, not a takeover" "$out_tz2arm2" "already armed and healthy"
  assert_eq "the pidfile still names the original pid" "$(cat "$WINGMAN_HOME/watch-tz2.pid" 2>/dev/null)" "$tz2pid"
  kill "$tz2pid" 2>/dev/null
  tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null
fi

# --- issue #303 PR review round 1: a marker-less stamp must not trust kill -0
# alone - it must verify the pid is actually a watch-fleet cycle (its own
# argv), or a pid the stamp's own pid has been RECYCLED to (e.g. after a host
# reboot, the exact scenario the identity stamp exists for) gets treated as
# the live owner. With no beacon file at all (a marker-less stamp never
# written by this codebase's own claim step has none either), that reads as
# wedged past WM_WATCH_HARD_GRACE, and the singleton guard's existing
# takeover machinery SIGTERMs/SIGKILLs it - the exact harm the identity stamp
# was added to prevent, reintroduced by the "cannot verify" branch itself. ---
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
sleep 600 &
innocentpid=$!
wm_track "$innocentpid"
mkdir "$WINGMAN_HOME/watch.pid.owner"
_innocent_start="$(TZ=UTC LC_ALL=C ps -o lstart= -p "$innocentpid" | sed -e 's/^ *//' -e 's/ *$//')"
printf '%s\n%s\n' "$innocentpid" "$_innocent_start" > "$WINGMAN_HOME/watch.pid.owner/owner"
echo "$innocentpid" > "$WINGMAN_HOME/watch.pid"
# Deliberately no watch.beat - the recycled-pid scenario this stands in for
# (a reboot, nothing clears $WM_HOME) never had one from this codebase either.
out_innocent="$(wm_timeout 15 "$WF" >"$WINGMAN_HOME/innocent.log" 2>&1; cat "$WINGMAN_HOME/innocent.log")"
assert_true "the innocent pid behind a marker-less stamp survives" "kill -0 $innocentpid"
assert_contains "a fresh cycle claims normally instead of taking over" "$out_innocent" "watcher: armed"
kill "$innocentpid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- issue #312: owner_lock_alive() must not read an unreaped zombie as --
# alive on the MARKED (lstart-comparison) path. kill -0 succeeds against a
# zombie (its process-table entry persists until the parent wait()s it),
# and ps -o lstart= for a zombie still reports its true, original start
# time (verified empirically against this host's ps - see the issue #312
# plan) - so the existing marked-path comparison sees a perfect pid+lstart
# match and, pre-fix, reads it as genuinely alive. Left unfixed, the
# singleton guard's wedged-takeover branch then calls takeover_kill()
# against it: SIGTERM does nothing to a zombie, the 5s wait escalates to
# SIGKILL, which also does nothing to a zombie, and the second 5s wait
# ends in wm_die - the cycle wedges instead of being taken over cleanly
# (the issue's own described impact, reproduced end to end here, not
# inferred from kill -0 passing in isolation).
#
# An observable zombie needs a grandchild whose parent never reaps it:
# bash (not sh/dash, which reaps a background child opportunistically on
# its very next command dispatch) runs a grandchild that exits
# immediately, then sleeps without ever wait()ing on it.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-zom1 'sleep 600'
wm_state crew-add --id zom1 --type lead --objective x --repo /tmp --window wm-zom1 --session-id szom1 >/dev/null
wm_state crew-set --id zom1 --status working --summary "in progress" >/dev/null
_zo1_dir="$(wm_mktemp_dir)"
_zo1_pidfile="$_zo1_dir/pid"
bash -c "sh -c 'exit 0' & echo \$! > '$_zo1_pidfile'; sleep 30" &
_zo1_parent=$!
wm_track "$_zo1_parent"
_zo1_pid=""; _zo1_tries=0
while [ "$_zo1_tries" -lt 50 ]; do
  [ -s "$_zo1_pidfile" ] && { _zo1_pid="$(cat "$_zo1_pidfile")"; break; }
  sleep 0.1; _zo1_tries=$((_zo1_tries+1))
done
_zo1_state=""; _zo1_tries=0
if [ -n "$_zo1_pid" ]; then
  while [ "$_zo1_tries" -lt 50 ]; do
    _zo1_state="$(ps -o state= -p "$_zo1_pid" 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//')"
    case "$_zo1_state" in Z*) break ;; esac
    sleep 0.1; _zo1_tries=$((_zo1_tries+1))
  done
fi
_zo1_start=""
case "$_zo1_state" in
  Z*) _zo1_start="$(TZ=UTC LC_ALL=C ps -o lstart= -p "$_zo1_pid" 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//')" ;;
esac
if [ -n "$_zo1_start" ]; then
  mkdir "$WINGMAN_HOME/watch-zom1.pid.owner"
  printf '%s\n%s\n%s\n' "$_zo1_pid" "$_zo1_start" "lstart-utc" > "$WINGMAN_HOME/watch-zom1.pid.owner/owner"
  out_zo1status="$("$WF" --owner zom1 --status 2>&1)"
  assert_contains "a zombie-stamped marked lock reads as not-live" "$out_zo1status" "no live watch-fleet cycle"
  assert_not_contains "never reported WEDGED (that would mean owner_lock_alive still misread it as alive)" "$out_zo1status" "WEDGED"
  "$WF" --owner zom1 >"$WINGMAN_HOME/zom1-arm.log" 2>&1 &
  _zo1_armpid=$!
  wm_track "$_zo1_armpid"
  _zo1a_i=0
  while ! grep -qE "watcher: armed|SIGKILL|uninterruptible kernel wait" "$WINGMAN_HOME/zom1-arm.log" 2>/dev/null && [ "$_zo1a_i" -lt 150 ]; do
    sleep 0.2; _zo1a_i=$((_zo1a_i + 1))
  done
  out_zo1arm="$(cat "$WINGMAN_HOME/zom1-arm.log")"
  assert_contains "a fresh arm claims normally over a zombie-stamped marked lock" "$out_zo1arm" "watcher: armed"
  assert_not_contains "no takeover is attempted against the zombie" "$out_zo1arm" "taking over"
  assert_not_contains "the zombie never forces an escalation to SIGKILL" "$out_zo1arm" "SIGKILL"
  kill "$_zo1_armpid" 2>/dev/null
else
  echo "SKIP: could not construct an observable zombie process (with a readable lstart) on this host within budget - skipping the issue #312 marked-path case" >&2
fi
kill "$_zo1_parent" 2>/dev/null
wait "$_zo1_parent" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- issue #312: owner_lock_alive() must not read an unreaped zombie as --
# alive on the MARKER-LESS (argv-verification) path added by #303 either.
# This path's own pre-fix check is `ps -o args=` for the substring
# "watch-fleet" - a zombie's real argv is gone (its address space is
# already freed), but ps falls back to "[<comm>] <defunct>" using the
# executable's own basename, and a genuine watch-fleet cycle's comm IS
# "watch-fleet" - so pre-fix, a real watch-fleet zombie's args renders as
# "[watch-fleet] <defunct>", which STILL matches *watch-fleet* and reads
# as alive. A generic (e.g. sh) zombie would not exercise this - its
# bracketed comm never matched the check regardless of this fix - so the
# grandchild here is deliberately an executable literally named
# "watch-fleet" (a throwaway two-line script, unrelated to the real
# bin/watch-fleet binary), not the sh -c 'exit 0' used in case A above.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-zom2 'sleep 600'
wm_state crew-add --id zom2 --type lead --objective x --repo /tmp --window wm-zom2 --session-id szom2 >/dev/null
wm_state crew-set --id zom2 --status working --summary "in progress" >/dev/null
_zo2_dir="$(wm_mktemp_dir)"
printf '#!/bin/sh\nexit 0\n' > "$_zo2_dir/watch-fleet"
chmod +x "$_zo2_dir/watch-fleet"
_zo2_pidfile="$_zo2_dir/pid"
bash -c "'$_zo2_dir/watch-fleet' & echo \$! > '$_zo2_pidfile'; sleep 30" &
_zo2_parent=$!
wm_track "$_zo2_parent"
_zo2_pid=""; _zo2_tries=0
while [ "$_zo2_tries" -lt 50 ]; do
  [ -s "$_zo2_pidfile" ] && { _zo2_pid="$(cat "$_zo2_pidfile")"; break; }
  sleep 0.1; _zo2_tries=$((_zo2_tries+1))
done
_zo2_state=""; _zo2_tries=0
if [ -n "$_zo2_pid" ]; then
  while [ "$_zo2_tries" -lt 50 ]; do
    _zo2_state="$(ps -o state= -p "$_zo2_pid" 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//')"
    case "$_zo2_state" in Z*) break ;; esac
    sleep 0.1; _zo2_tries=$((_zo2_tries+1))
  done
fi
case "$_zo2_state" in
  Z*)
    mkdir "$WINGMAN_HOME/watch-zom2.pid.owner"
    # Marker-less (two-line) stamp: no third "lstart-utc" line, so
    # owner_lock_alive() degrades to the argv-verification path.
    printf '%s\n%s\n' "$_zo2_pid" "irrelevant-on-this-path" > "$WINGMAN_HOME/watch-zom2.pid.owner/owner"
    out_zo2status="$("$WF" --owner zom2 --status 2>&1)"
    assert_contains "a zombie-stamped marker-less lock reads as not-live" "$out_zo2status" "no live watch-fleet cycle"
    assert_not_contains "never reported WEDGED (that would mean owner_lock_alive still misread it as alive)" "$out_zo2status" "WEDGED"
    "$WF" --owner zom2 >"$WINGMAN_HOME/zom2-arm.log" 2>&1 &
    _zo2_armpid=$!
    wm_track "$_zo2_armpid"
    _zo2a_i=0
    while ! grep -qE "watcher: armed|SIGKILL|uninterruptible kernel wait" "$WINGMAN_HOME/zom2-arm.log" 2>/dev/null && [ "$_zo2a_i" -lt 150 ]; do
      sleep 0.2; _zo2a_i=$((_zo2a_i + 1))
    done
    out_zo2arm="$(cat "$WINGMAN_HOME/zom2-arm.log")"
    assert_contains "a fresh arm claims normally over a zombie-stamped marker-less lock" "$out_zo2arm" "watcher: armed"
    assert_not_contains "no takeover is attempted against the zombie" "$out_zo2arm" "taking over"
    assert_not_contains "the zombie never forces an escalation to SIGKILL" "$out_zo2arm" "SIGKILL"
    kill "$_zo2_armpid" 2>/dev/null
    ;;
  *)
    echo "SKIP: could not construct an observable zombie process on this host within budget - skipping the issue #312 marker-less-path case" >&2
    ;;
esac
kill "$_zo2_parent" 2>/dev/null
wait "$_zo2_parent" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- Fix 3 MF3 (round-2 MF-B): $OWNERLOCK creation - the mkdir itself fails -
# and is fatal on failure - never a silently-unprotected cycle. The
# obstruction is chmod 500 on the pre-created $OWNERLOCK directory itself
# (with a file already inside it), which genuinely survives the code's own
# `rm -rf "$OWNERLOCK"` (removing that inner file needs write permission ON
# $OWNERLOCK, which is denied) - unlike a bare pre-created regular file, whose
# removal only needs write on ITS PARENT and is therefore silently cleared by
# that same rm -rf, which is exactly why the original form of this test could
# never fail. Note this specific fixture makes `mkdir` itself fail (EEXIST) -
# it does not reach the readback-verification branch below (see ol2, which
# does).
test_new_home
wm_state crew-add --id ol1 --type lead --objective x --repo /tmp --window wm-ol1 --session-id sol1 >/dev/null
wm_state crew-set --id ol1 --status working --summary "in progress" >/dev/null
mkdir "$WINGMAN_HOME/watch-ol1.pid.owner"
: > "$WINGMAN_HOME/watch-ol1.pid.owner/owner"
chmod 500 "$WINGMAN_HOME/watch-ol1.pid.owner"
out5="$(wm_timeout 15 "$WF" --owner ol1 2>&1)"; rc5=$?
chmod 700 "$WINGMAN_HOME/watch-ol1.pid.owner" 2>/dev/null
assert_true "the arm dies loudly rather than proceeding with an unwritable owner lock" "[ $rc5 -ne 0 ]"
assert_contains "the die message names the owner lock" "$out5" "failed to create the owner lock"
assert_false "no pidfile is left behind" "[ -f '$WINGMAN_HOME/watch-ol1.pid' ]"
assert_false "no blocking loop was entered (beat file untouched)" "[ -f '$WINGMAN_HOME/watch-ol1.beat' ]"

# --- Fix 3 MF3 (round-2 MF-B), the write itself: mkdir SUCCEEDS but the -----
# stamp write into it fails - the genuine target of the readback verification,
# distinct from ol1 above (which never reaches this branch at all). A `mkdir`
# shim placed first on $PATH for this one arm creates the directory for real
# (via /bin/mkdir, so mkdir's own exit code is 0) and then chmods it 0500
# before returning, so the write immediately after is denied - deterministic,
# no permission race, and it only ever matches a *.pid.owner argument, so the
# unrelated $CLAIMLOCK (*.pid.lock) mkdir earlier in the same arm is
# untouched.
test_new_home
wm_state crew-add --id ol2 --type lead --objective x --repo /tmp --window wm-ol2 --session-id sol2 >/dev/null
wm_state crew-set --id ol2 --status working --summary "in progress" >/dev/null
MKDIR_SHIM_DIR="$(wm_mktemp_dir)"
cat > "$MKDIR_SHIM_DIR/mkdir" <<'SHIMEOF'
#!/usr/bin/env bash
/bin/mkdir "$@"
_rc=$?
for _a in "$@"; do
  case "$_a" in
    *.pid.owner) chmod 500 "$_a" 2>/dev/null ;;
  esac
done
exit "$_rc"
SHIMEOF
chmod +x "$MKDIR_SHIM_DIR/mkdir"
out6="$(wm_timeout 15 env PATH="$MKDIR_SHIM_DIR:$PATH" "$WF" --owner ol2 2>&1)"; rc6=$?
chmod 700 "$WINGMAN_HOME/watch-ol2.pid.owner" 2>/dev/null
assert_true "the arm dies loudly when the stamp write itself fails, even though mkdir succeeded" "[ $rc6 -ne 0 ]"
assert_contains "the die message names the owner lock" "$out6" "failed to create the owner lock"
assert_false "no pidfile is left behind" "[ -f '$WINGMAN_HOME/watch-ol2.pid' ]"
assert_false "no blocking loop was entered (beat file untouched)" "[ -f '$WINGMAN_HOME/watch-ol2.beat' ]"

# ============================================================================
# issue #219: a cycle notices its own code went stale on disk and exits
# cleanly (never externally killed) to be freshly re-armed
# ============================================================================

# Like wait_for_owner_status above, but against an arbitrary watch-fleet
# binary rather than always $WF - these tests arm a throwaway copy so its
# lib/common.sh can be safely mutated out from under the running cycle.
wait_for_scoped_status() {
  _wss_i=0
  while [ "$_wss_i" -lt 50 ]; do
    "$1" --owner "$2" --status >/dev/null 2>&1 && return 0
    sleep 0.2
    _wss_i=$((_wss_i + 1))
  done
  return 1
}

# --- SC1: a genuine content edit to lib/common.sh is noticed within a couple
# of polls, classifies as exactly stale-code, never consumes the
# spurious-failure budget, and a fresh re-arm from the same (now-edited)
# files comes up live again with its own fingerprint stamp matching the new
# content and no lingering codecheck streak - the ordinary, single-
# occurrence auto-heal path staying entirely silent and self-clearing. ------
test_new_home
SC1_DIR="$(wm_mktemp_dir)"
cp "$WF" "$SC1_DIR/watch-fleet"
chmod +x "$SC1_DIR/watch-fleet"
cp -r "$TEST_REPO/bin/lib" "$SC1_DIR/lib"
"$SC1_DIR/watch-fleet" --owner "" >"$WINGMAN_HOME/sc1.log" 2>&1 &
sc1pid=$!
wm_track "$sc1pid"
assert_true "sc1's cycle comes up live" "wait_for_scoped_status '$SC1_DIR/watch-fleet' ''"
printf '\n# sc1 marker\n' >> "$SC1_DIR/lib/common.sh"
assert_true "the cycle self-exits within a couple of poll intervals once its own code changes on disk" "wait_for_pid_gone $sc1pid"
sc1classify="$(wm_timeout 10 "$WF" --owner "" --classify 2>/dev/null)"
assert_eq "the stale-code self-exit classifies as exactly stale-code" "$sc1classify" "stale-code"
assert_eq "a stale-code exit never consumes the spurious-failure budget" "$(cat "$WINGMAN_HOME/watch-spurious-count" 2>/dev/null)" "0"
"$SC1_DIR/watch-fleet" --owner "" >"$WINGMAN_HOME/sc1-refresh.log" 2>&1 &
sc1refreshpid=$!
wm_track "$sc1refreshpid"
assert_true "a fresh re-arm from the same, now-edited files comes up live again" "wait_for_scoped_status '$SC1_DIR/watch-fleet' ''"
assert_eq "the fresh cycle's own fingerprint stamp matches the new on-disk content" "$(cat "$WINGMAN_HOME/watch.code" 2>/dev/null)" "$(cksum "$SC1_DIR/watch-fleet" "$SC1_DIR/lib/common.sh")"
sleep 3
assert_false "the fresh cycle's own first poll(s) find a match, clearing any codecheck streak" "[ -e '$WINGMAN_HOME/watch.codecheck' ]"
kill "$sc1refreshpid" 2>/dev/null

# --- SC2: a bare mtime bump with no content change never trips the check - --
# the direct proof this is a content-hash check, not an mtime check. --------
test_new_home
SC2_DIR="$(wm_mktemp_dir)"
cp "$WF" "$SC2_DIR/watch-fleet"
chmod +x "$SC2_DIR/watch-fleet"
cp -r "$TEST_REPO/bin/lib" "$SC2_DIR/lib"
"$SC2_DIR/watch-fleet" --owner "" >"$WINGMAN_HOME/sc2.log" 2>&1 &
sc2pid=$!
wm_track "$sc2pid"
assert_true "sc2's cycle comes up live" "wait_for_scoped_status '$SC2_DIR/watch-fleet' ''"
touch "$SC2_DIR/lib/common.sh"
sleep 5
assert_true "a bare mtime bump with no content change never trips the stale-code check" "kill -0 $sc2pid"
kill "$sc2pid" 2>/dev/null

# --- SC3: the anti-spin loop bound - a SECOND consecutive fresh arm also ----
# mismatching on its own first poll is a malfunction (e.g. an unwritable
# $CODEFILE), not a genuine code update, and correctly falls through to the
# EXISTING spurious-failure budget instead of spinning silently forever. Four
# arms total: the first is the genuine (if malfunction-caused) stale-code
# exit; the next three are what actually trips spurious-repeated. ----------
test_new_home
SC3_DIR="$(wm_mktemp_dir)"
cp "$WF" "$SC3_DIR/watch-fleet"
chmod +x "$SC3_DIR/watch-fleet"
cp -r "$TEST_REPO/bin/lib" "$SC3_DIR/lib"
# $CODEFILE's own path, pre-created as a directory: `code_fingerprint >
# "$CODEFILE"` fails (EISDIR) on every claim, and `cat` on it always reads
# empty - deterministic and platform-independent, unlike chmod 0444 (which a
# root-run suite would ignore).
mkdir "$WINGMAN_HOME/watch.code"

"$SC3_DIR/watch-fleet" --owner "" >"$WINGMAN_HOME/sc3-1.log" 2>&1 &
sc3pid1=$!
wm_track "$sc3pid1"
assert_true "arm 1 exits on its own (an unwritable \$CODEFILE can never stamp a fingerprint to match against)" "wait_for_pid_gone $sc3pid1"
sc3c1="$(wm_timeout 10 "$WF" --owner "" --classify 2>/dev/null)"
assert_eq "arm 1 classifies as stale-code (streak 1 - its own claim never actually wrote a stamp)" "$sc3c1" "stale-code"
assert_eq "the stale-code exit resets the spurious-failure count to 0" "$(cat "$WINGMAN_HOME/watch-spurious-count" 2>/dev/null)" "0"

"$SC3_DIR/watch-fleet" --owner "" >"$WINGMAN_HOME/sc3-2.log" 2>&1 &
sc3pid2=$!
wm_track "$sc3pid2"
assert_true "arm 2 also exits on its own (streak reaches 2 - a malfunction, not a code update)" "wait_for_pid_gone $sc3pid2"
sc3c2="$(wm_timeout 10 "$WF" --owner "" --classify 2>/dev/null)"
assert_contains "arm 2's death falls through to the ordinary no-record hint logic, feeding the REAL failure budget" "$sc3c2" "spurious 1 "

"$SC3_DIR/watch-fleet" --owner "" >"$WINGMAN_HOME/sc3-3.log" 2>&1 &
sc3pid3=$!
wm_track "$sc3pid3"
assert_true "arm 3 exits on its own too (streak 3)" "wait_for_pid_gone $sc3pid3"
sc3c3="$(wm_timeout 10 "$WF" --owner "" --classify 2>/dev/null)"
assert_contains "arm 3 continues feeding the real budget" "$sc3c3" "spurious 2 "

"$SC3_DIR/watch-fleet" --owner "" >"$WINGMAN_HOME/sc3-4.log" 2>&1 &
sc3pid4=$!
wm_track "$sc3pid4"
assert_true "arm 4 exits on its own too (streak 4)" "wait_for_pid_gone $sc3pid4"
sc3c4="$(wm_timeout 10 "$WF" --owner "" --classify 2>/dev/null)"
assert_contains "the real budget trips spurious-repeated on the fourth arm overall" "$sc3c4" "spurious-repeated 3 "
assert_true "a standdown is durably recorded" "[ -f '$WINGMAN_HOME/watch.suppressed' ]"
"$WF" --clear-standdown >/dev/null 2>&1

# --- SC4: the worktree-removal self-check still wins the ordering race - a --
# removed $SELF_BIN_DIR classifies as `stopped`, never `stale-code` (the
# stale-code check's own fail-closed handling of an uncomputable fingerprint
# correctly defers to the check immediately above it rather than racing
# ahead of it). Modeled directly on the existing Fix 2a worktree-removal
# test above. --------------------------------------------------------------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-scwt1 'sleep 600'
SCWT_PARENT="$(wm_mktemp_dir)"
SCWT_DIR="$SCWT_PARENT/fake-worktree"
mkdir -p "$SCWT_DIR"
cp "$WF" "$SCWT_DIR/watch-fleet"
chmod +x "$SCWT_DIR/watch-fleet"
ln -s "$TEST_REPO/bin/lib" "$SCWT_DIR/lib"
wm_state crew-add --id scwt1 --type lead --objective x --repo /tmp --window wm-scwt1 --session-id sscwt1 >/dev/null
wm_state crew-set --id scwt1 --status working --summary "in progress" >/dev/null
"$SCWT_DIR/watch-fleet" --owner scwt1 >"$WINGMAN_HOME/scwt1.log" 2>&1 &
scwt1pid=$!
wm_track "$scwt1pid"
assert_true "the cycle armed from the throwaway worktree comes up live" "wait_for_owner_status scwt1"
rm -rf "$SCWT_PARENT"
assert_true "the cycle self-exits once its own worktree directory is gone" "wait_for_pid_gone $scwt1pid"
scwt1classify="$(wm_timeout 10 "$WF" --owner scwt1 --classify 2>/dev/null)"
assert_eq "a removed worktree classifies as stopped, never stale-code" "$scwt1classify" "stopped"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

test_summary
