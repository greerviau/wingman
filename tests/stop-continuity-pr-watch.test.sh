#!/usr/bin/env bash
# E2E: hooks/stop-continuity.sh's pr-watch backstop (issue #319) - AC1/AC2
# folded into the SAME claim/window/classify loop tests/stop-continuity.test.sh
# already exercises for bin/watch-fleet. A separate file (not an extension of
# that one) because the combined fixture - a fake `gh` via WM_GH (reusing
# tests/pr-watch.test.sh's own make_fake_gh) plus the hook's own tmux/window
# machinery - is substantial on its own. tests/run.sh discovers every
# tests/*.test.sh via a bare glob, so this file needs no separate
# registration. See tests/stop-continuity.test.sh's own file header for what
# every test in this suite deliberately does NOT try to prove (that a real
# Claude Code session receives a rewake on exit 2 - established once,
# empirically, elsewhere).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

HOOK="$TEST_REPO/hooks/stop-continuity.sh"
export WM_WATCH_INTERVAL=1
export WM_PR_WATCH_INTERVAL=1
export WM_STOP_CONTINUITY_LIFETIME=1   # same file-level lever tests/stop-continuity.test.sh uses

run_hook() { printf '{}' | wm_timeout "${1:-20}" bash "$HOOK"; }

wait_for_file() {
  _wf_tries="${2:-100}"; _wf_n=0
  while [ ! -s "$1" ] && [ "$_wf_n" -lt "$_wf_tries" ]; do sleep 0.2; _wf_n=$((_wf_n+1)); done
  [ -s "$1" ]
}

wait_for_gone() {
  _wfg_tries="${2:-100}"; _wfg_n=0
  while kill -0 "$1" 2>/dev/null && [ "$_wfg_n" -lt "$_wfg_tries" ]; do sleep 0.2; _wfg_n=$((_wfg_n+1)); done
  ! kill -0 "$1" 2>/dev/null
}

wait_for_content() {
  _wfc_tries="${3:-100}"; _wfc_n=0
  while ! grep -q -- "$2" "$1" 2>/dev/null && [ "$_wfc_n" -lt "$_wfc_tries" ]; do sleep 0.2; _wfc_n=$((_wfc_n+1)); done
  grep -q -- "$2" "$1" 2>/dev/null
}

wait_for_pidfile_not() {
  _wpn_tries="${3:-100}"; _wpn_n=0
  while { [ ! -s "$1" ] || [ "$(cat "$1" 2>/dev/null)" = "$2" ]; } && [ "$_wpn_n" -lt "$_wpn_tries" ]; do
    sleep 0.2; _wpn_n=$((_wpn_n+1))
  done
  [ -s "$1" ] && [ "$(cat "$1" 2>/dev/null)" != "$2" ]
}

new_home() {
  test_new_home
  tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
}

# A fake `gh`, reused verbatim from tests/pr-watch.test.sh's own make_fake_gh
# (kept in sync deliberately - both drive the identical bin/pr-watch).
make_fake_gh() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "api user")   echo "botuser" ;;
  "pr view")    cat "$FAKE_PR" ;;
  "repo view")  echo "owner/repo" ;;
  "api repos/owner/repo/pulls/42/comments") echo "[]" ;;
  "api graphql") echo "" ;;
  *)            echo "" ;;
esac
SH
  chmod +x "$1"
}

# --- (1) Arms a report's own dependency watcher with no model turn, kills it
# out from under it, and asserts recovery within one continuity window - AC3's
# own option (a), the design target (see the plan's AC1b for why the unified
# loop should make this achievable without needing AC3's fallback option (b)).
new_home
export WINGMAN_CREW_ID=pw319
wm_state crew-add --id pw319 --type developer --objective x --repo /tmp \
  --window wm-pw319 --session-id s-pw319 >/dev/null
# A matching LIVE tmux window, not just the roster record - Change 4 now
# spawns bin/watch-fleet unconditionally every iteration regardless of
# active_crew (Design decision 6), and cmd_reconcile's own death-flip walks
# the WHOLE roster, not just the invoking --owner's children: any LIVE_STATES
# member (pw319 itself, status working/review, qualifies) whose own `window`
# has no matching live tmux window is flipped to died the instant any cycle
# polls. Mirrors tests/stop-continuity.test.sh's own add_crew_window, whose
# comment states this exact reason ("so reconcile never has reason to flip it
# to 'died' mid-test").
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-pw319 'sleep 600'
wm_state crew-set --id pw319 --status working \
  --delivery "https://github.com/owner/repo/pull/42" --summary "shepherding" >/dev/null

D="$(wm_mktemp_dir)"
GH="$D/gh"; make_fake_gh "$GH"
export WM_GH="$GH"
export FAKE_PR="$D/pr.json"
export WM_PR_WATCH_WORKFLOWS_DIR="$D/no-workflows"
# Unsettled: an in-progress check, so the real blocking loop keeps polling
# silently instead of firing on its very first poll.
cat > "$FAKE_PR" <<'JSON'
{"number":42,"state":"OPEN","mergedAt":null,
 "statusCheckRollup":[{"__typename":"CheckRun","name":"build","status":"IN_PROGRESS"}],
 "reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha1"}
JSON

# Arm a REAL bin/pr-watch cycle directly (not through the hook) - "arms a
# report's dependency watcher."
"$TEST_REPO/bin/pr-watch" --pr 42 >"$WINGMAN_HOME/pw319-initial.log" 2>&1 &
initial=$!; wm_track "$initial"
assert_true "the initial pr-watch cycle's pidfile appears" "wait_for_file '$WINGMAN_HOME/pr-watch-pw319.pid'"
assert_true "its beacon appears too" "[ -f '$WINGMAN_HOME/pr-watch-pw319.beat' ]"
_initial_pid="$(cat "$WINGMAN_HOME/pr-watch-pw319.pid")"

# "kills it out from under it" - the same kill -9/dead-pid shape
# tests/stop-continuity.test.sh already uses for its analogous watch-fleet
# case (case (6), "Stale-pid companion").
kill -9 "$_initial_pid" 2>/dev/null
wait "$initial" 2>/dev/null

export WM_STOP_CONTINUITY_WINDOW=20
# Backgrounded, NOT `out1="$(run_hook 30)"` (round-1 review, must-fix 2): a
# synchronous call blocks until the hook returns, but the hook's own design
# (Change 4) fully reaps pr_child - including its pidfile-removing trap -
# before it ever returns, and this fixture is deliberately unsettled so the
# window elapses and force-closes pr_child before that happens. By the time
# a synchronous call returns, the fresh pidfile this assertion wants to see
# is already gone. Poll for it WHILE the hook is still mid-iteration instead
# - mirroring this suite's own existing case (2)/(W2) precedent
# (`printf '{}' | bash "$HOOK" ... &` then `wait_for_file`/
# `wait_for_pidfile_not`), which `wait_for_pidfile_not`'s own comment already
# explains is why "waiting for it to vanish" is the wrong shape here.
run_hook 30 >"$D/hook1.out" 2>&1 &
hook1=$!; wm_track "$hook1"
assert_true "a fresh pr-watch pid is armed with no model turn, distinct from the killed one" \
  "wait_for_pidfile_not '$WINGMAN_HOME/pr-watch-pw319.pid' '$_initial_pid'"
_fresh_pid="$(cat "$WINGMAN_HOME/pr-watch-pw319.pid" 2>/dev/null)"
assert_true "the fresh pid is a real, live process" "[ -n '$_fresh_pid' ] && kill -0 $_fresh_pid"
# Let this iteration's pr_child run to completion (it never fires on its own
# against the unsettled fixture, so the window elapses and the referee force-
# closes it) and the hook itself finish before sub-case (2) starts a fresh
# invocation - avoids two hook processes racing on the same pidfile/armlog/
# exitfile. Change 6 appends pr_child's own captured output into $armlog
# during THIS reap, before the hook returns, so the armlog assertion below is
# correctly checked post-mortem (unlike the pidfile one above): $armlog is a
# separate, hook-owned file Change 6 appends to and pr_child's own exit never
# deletes.
wait "$hook1" 2>/dev/null; rc1=$?
out1="$(cat "$D/hook1.out" 2>/dev/null)"
# Owner-scoped, not the unscoped literal (plan review round 2, must-fix): this
# sub-case runs with WINGMAN_CREW_ID=pw319 set, so OWNER="pw319" inside the
# hook, and the fast-path gate's own wm_watcher_up call derives _okey="pw319"
# as a side effect (hooks/lib/watcher-liveness.sh's wm_owner_paths) before the
# loop ever reaches its armlog assignment - nothing between those two points
# resets _okey, so armlog resolves to stop-autoarm-pw319.log, never the
# unscoped stop-autoarm.log.
# Unanchored, not `^[0-9]{4}-...`: wm_ok (bin/lib/common.sh) unconditionally
# prepends its own "\xe2\x9c\x93 " (checkmark) formatting ahead of the
# message, so the real line is "<checkmark> <timestamp> pr-watch: armed
# pid=...", never the timestamp at column 1 - matching every existing
# consumer of this string elsewhere in the suite (unanchored `grep -c 'armed
# pid='`), per AC2's own stated design ("every existing consumer... is an
# unanchored substring match").
assert_true "a timestamped pr-watch armed line lands in the shared arm log (AC1+AC2 together)" \
  "grep -Eq '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z pr-watch: armed pid=' '$WINGMAN_HOME/stop-autoarm-pw319.log'"

# --- (2) Same test, second sub-case: the re-armed cycle's very next poll
# sees a settled event, and the hook's own rewake carries it distinctly - not
# compose_attention_reason's roster-report text, not a bare "no forward
# motion" string. Flip the fixture to MERGED and let the hook run one more
# time (the fresh cycle armed above is still polling against the OLD,
# unsettled fixture from before this flip).
cat > "$FAKE_PR" <<'JSON'
{"number":42,"state":"MERGED","mergedAt":"2026-08-12T00:00:00Z","statusCheckRollup":[],
 "reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}
JSON
out2="$(run_hook 30)"; rc2=$?
assert_eq "the hook exits 2 on the pr-watch fire" "$rc2" "2"
assert_contains "the rewake carries a block decision" "$out2" '"decision": "block"'
assert_contains "the rewake relays pr_child's own reason line verbatim" "$out2" "merged: #42"
assert_contains "the rewake points at the Shepherding table" "$out2" "Shepherding a PR"
assert_not_contains "a pr-watch fire is never conflated with a roster report" "$out2" "surfaced via automatic fleet continuity"
assert_not_contains "a pr-watch fire is never conflated with a bare rollover" "$out2" "window rolled"
assert_contains "the rewake still carries the do-not-arm-a-watch-fleet-cycle sentence" "$out2" "do NOT arm a watch-fleet cycle"
unset WM_STOP_CONTINUITY_WINDOW WINGMAN_CREW_ID WM_GH FAKE_PR WM_PR_WATCH_WORKFLOWS_DIR

# --- (3) A member with no PR-shaped delivery is untouched: the fast path
# still exits immediately even though the hook now also checks pr-watch.
new_home
export WINGMAN_CREW_ID=pw319b
wm_state crew-add --id pw319b --type developer --objective x --repo /tmp \
  --window wm-pw319b --session-id s-pw319b >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-pw319b 'sleep 600'
wm_state crew-set --id pw319b --status working --summary "no PR yet" >/dev/null
out3="$(run_hook)"; rc3=$?
assert_eq "no PR-shaped delivery: exit 0" "$rc3" "0"
assert_eq "no PR-shaped delivery: no stdout" "$out3" ""
assert_false "no PR-shaped delivery: pr-watch never spawned" "[ -f '$WINGMAN_HOME/pr-watch-pw319b.pid' ]"
unset WINGMAN_CREW_ID

test_summary
