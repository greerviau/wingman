#!/usr/bin/env bash
# E2E: tests/lib.sh's own shared teardown machinery (issue #38). Not just read
# the code - each case below drives a real bash process to prove the shared
# trap actually fires and actually removes real resources, since that is
# exactly the class of mistake earlier drafts of this fix made (a design that
# looked correct on paper but silently registered nothing, because every
# wm_mktemp_dir call site runs inside a command-substitution subshell).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# --- case 1: an unbound-variable abort under `set -u` still tears down -------
# The regression this guards: a wm_track_dir-style registration made *inside*
# wm_mktemp_dir would append to a copy of the tracking list that dies with the
# command-substitution subshell it runs in, leaving the parent shell's list
# empty forever - so wm_cleanup_all would remove nothing, even though the trap
# itself fired correctly. Checking only "did the trap run" would not have
# caught this; the directories must actually be gone on disk.
c1_out="$(bash -c '
set -u
. "'"$TEST_REPO"'/tests/lib.sh"
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
extra="$(wm_mktemp_dir)"
printf "%s\n%s\n%s\n" "$WM_TMUX_SESSION" "$WINGMAN_HOME" "$extra"
: "${THIS_VAR_IS_DELIBERATELY_UNBOUND}"
' 2>/dev/null)"
c1_sess="$(printf '%s\n' "$c1_out" | sed -n 1p)"
c1_home="$(printf '%s\n' "$c1_out" | sed -n 2p)"
c1_extra="$(printf '%s\n' "$c1_out" | sed -n 3p)"
c1_home_parent="$(dirname "$c1_home")"
assert_true  "case1 setup: captured a session name" "[ -n '$c1_sess' ]"
assert_false "case1: tmux session torn down after a set -u abort" \
  "tmux has-session -t '=$c1_sess' 2>/dev/null"
assert_false "case1: test_new_home's WINGMAN_HOME parent dir torn down (bare wm_mktemp_dir call shape)" \
  "[ -d '$c1_home_parent' ]"
assert_false "case1: a direct wm_mktemp_dir call's dir torn down (parent+child call shape)" \
  "[ -d '$c1_extra' ]"

# --- case 2: SIGINT is terminal, not resumable ------------------------------
# The regression this guards: a bare `trap wm_cleanup_all INT` would return
# control to the script body right after the handler runs, so a Ctrl-C mid-test
# would delete the fixtures the remaining assertions still expect, then keep
# running those assertions against now-deleted state, and exit 0. The INT
# handler must instead be terminal (exit 130) and never let the script resume.
c2_out="$(wm_mktemp_file)"
# A plain, non-interactive, job-control-off shell (this file's own execution
# mode, and every *.test.sh under tests/run.sh) sets SIGINT/SIGQUIT to
# IGNORED for an asynchronous ("&") child by default, and a `trap ... INT`
# inside that child cannot override an inherited ignore - only enabling job
# control (set -m) before backgrounding gives the child a real, catchable
# SIGINT disposition, in its own process group. Even then, a real terminal
# Ctrl-C lands on that whole foreground process group at once, so the
# backgrounded bash's own pending trap AND its foreground `sleep` child both
# get the signal simultaneously and the child dies immediately, letting
# bash's wait() return right away; signaling only the top pid would leave
# bash blocked in wait() for its still-alive `sleep` child - bash defers
# running a pending trap until that wait() returns, so the trap would not
# fire until the full 30s sleep completed on its own (both failure modes
# confirmed empirically). set -m plus a negative (process-group) kill target
# replicates real Ctrl-C delivery exactly, scoped to just this one job's own
# group so it cannot touch anything outside it.
set -m
bash -c '
set -u
. "'"$TEST_REPO"'/tests/lib.sh"
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
extra="$(wm_mktemp_dir)"
printf "%s\n%s\n%s\n" "$WM_TMUX_SESSION" "$WINGMAN_HOME" "$extra" > "'"$c2_out"'"
sleep 30
printf "RESUMED\n" >> "'"$c2_out"'"
' &
c2_pid=$!
wm_track "$c2_pid"
c2_tries=0
while [ ! -s "$c2_out" ] && [ "$c2_tries" -lt 50 ]; do sleep 0.1; c2_tries=$((c2_tries+1)); done
kill -INT "-$c2_pid" 2>/dev/null
wait "$c2_pid" 2>/dev/null; c2_rc=$?
set +m
sleep 0.3
c2_sess="$(sed -n 1p "$c2_out")"
c2_home="$(sed -n 2p "$c2_out")"
c2_extra="$(sed -n 3p "$c2_out")"
c2_home_parent="$(dirname "$c2_home")"
assert_eq   "case2: SIGINT's terminal handler exits 130 (128+SIGINT)" "$c2_rc" "130"
assert_false "case2: the interrupted process did not resume its remaining body" \
  "grep -q RESUMED '$c2_out'"
assert_false "case2: tmux session torn down after SIGINT" \
  "tmux has-session -t '=$c2_sess' 2>/dev/null"
assert_false "case2: WINGMAN_HOME parent dir torn down after SIGINT" \
  "[ -d '$c2_home_parent' ]"
assert_false "case2: directly-created dir torn down after SIGINT" \
  "[ -d '$c2_extra' ]"

# --- case 3: watch-fleet.test.sh no longer installs a competing trap ---------
# watch-fleet.test.sh is named explicitly in the plan as the file most likely
# to hide a regression: the largest tmux consumer in the suite (46 blocks) and
# the file whose old `trap wm_kill_tracked EXIT` most directly collided with
# the shared one (a second `trap ... EXIT` replaces the first outright - bash
# traps do not chain). This is the permanent, whole-suite version of the check
# below (tests/run.sh's own static check, run before every suite loop); this
# case pins it to the one file the review called out by name.
assert_false "case3: watch-fleet.test.sh no longer installs its own EXIT trap" \
  "grep -qE '^[[:space:]]*trap .* EXIT' '$TEST_REPO/tests/watch-fleet.test.sh'"
# And a live demonstration that one of its resources (a background watcher pid
# plus its session), left to an abnormal exit exactly like its real blocks,
# is torn down by the shared trap now that no competing one exists.
c3_out="$(bash -c '
set -u
. "'"$TEST_REPO"'/tests/lib.sh"
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
"'"$TEST_REPO"'/bin/watch-fleet" >/dev/null 2>&1 &
wm_track "$!"
printf "%s\n" "$WM_TMUX_SESSION"
: "${THIS_VAR_IS_DELIBERATELY_UNBOUND}"
' 2>/dev/null)"
assert_true  "case3 setup: captured a session name" "[ -n '$c3_out' ]"
assert_false "case3: watch-fleet.test.sh-shaped block torn down by the shared trap" \
  "tmux has-session -t '=$c3_out' 2>/dev/null"

# --- case 4: the session-naming static check catches an independently-minted
# session name, and passes once it is derived from $WM_TMUX_SESSION ----------
# The regression this guards: submit-delivery.test.sh minted
# SESS="wm-test-submit-$$-$RANDOM" - a name carrying no run token, invisible to
# both the shared trap's registration and run.sh's identity-scoped sweep.
run_session_naming_check() {
  # Same check tests/run.sh runs before the suite loop, parameterized over a
  # directory so this case can point it at an isolated scratch fixture instead
  # of the real suite.
  _dir="$1"
  for v in $(grep -hoE 'new-session[^|]*-s "\$\{?([A-Za-z_]+)' "$_dir"/*.test.sh \
             | grep -oE '[A-Za-z_]+$' | sort -u); do
    [ "$v" = WM_TMUX_SESSION ] && continue
    grep -qE "^[[:space:]]*$v=.*\\\$\{?WM_TMUX_SESSION" "$_dir"/*.test.sh \
      || { printf 'session name $%s is not derived from $WM_TMUX_SESSION\n' "$v"; return 1; }
  done
  return 0
}
c4_dir="$(wm_mktemp_dir)"
cat > "$c4_dir/bad.test.sh" <<'EOF'
SESS="wm-test-submit-$$-$RANDOM"
tmux new-session -d -s "$SESS" -n box "true"
EOF
assert_false "case4: the check flags an independently-minted session name" \
  "run_session_naming_check '$c4_dir' >/dev/null 2>&1"
cat > "$c4_dir/bad.test.sh" <<'EOF'
SESS="$WM_TMUX_SESSION-submit"
tmux new-session -d -s "$SESS" -n box "true"
EOF
assert_true "case4: the check passes once the session name is derived from \$WM_TMUX_SESSION" \
  "run_session_naming_check '$c4_dir' >/dev/null 2>&1"

# --- case 5: wm_guard_test_fixture_agent actually refuses a real launch -----
# The regression this guards: the live evidence for issue #38 was a manual
# `bin/crew-resume --all-died` run against a leaked wm-test-* fixture with
# WM_AGENT unset, which launched real `claude --resume ... --permission-mode
# bypassPermissions` processes. This drives the real launch point
# (bin/crew-resume), not just the guard function in isolation.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id g5 --type developer --objective x --repo /tmp --window wm-g5 --session-id sess-g5-teardown >/dev/null
wm_state crew-set --id g5 --status died >/dev/null
c5_pre="$(pgrep -f 'claude --resume sess-g5-teardown' | wc -l | tr -d ' ')"
c5_out="$(env -u WM_AGENT "$TEST_REPO/bin/crew-resume" g5 2>&1)"; c5_rc=$?
c5_post="$(pgrep -f 'claude --resume sess-g5-teardown' | wc -l | tr -d ' ')"
assert_true "case5: crew-resume refuses to launch into a wm-test-* fixture with WM_AGENT unset" \
  "[ $c5_rc -ne 0 ]"
assert_contains "case5: the refusal names why" "$c5_out" "looks like a test fixture"
assert_eq "case5: no real claude process was ever spawned" "$c5_pre" "0"
assert_eq "case5: still no real claude process after the refused resume" "$c5_post" "0"

test_summary
