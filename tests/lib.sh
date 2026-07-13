# tests/lib.sh - tiny shared helpers for wingman's bash E2E tests.
# Sourced by each *.test.sh. bash-3.2-safe. No framework, just asserts + a
# per-test isolated state home and tmux session name so tests never touch a
# pilot's real ~/.wingman or the live "wingman" tmux session.

# uv may live in ~/.local/bin without being on a bare PATH.
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
export PATH

TEST_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WM_STATE="uv run --no-project --quiet $TEST_REPO/bin/lib/wm-state.py"

_TESTS_RUN=0
_TESTS_FAIL=0

# Each test gets its own throwaway state home and a tmux session name that does
# not exist (so the watcher's reconcile step is skipped - no live windows to check
# against - and a test never disturbs the real fleet).
test_new_home() {
  WINGMAN_HOME="$(mktemp -d)/wm"
  export WINGMAN_HOME
  export WM_TMUX_SESSION="wm-test-$$-$RANDOM"
  # The tests model wingman's own top-level scope (owner ""). When the suite runs
  # inside a crew session, the inherited crew id would silently re-scope
  # watch-fleet and the Stop hook to that crew's (empty) reports.
  unset WINGMAN_CREW_ID
  wm_state init >/dev/null
}

# Rewrite a member's live-status `updated` stamp to N minutes ago (default 10) so
# staleness-gated paths (wm-state stall-check) trip without waiting.
wm_age_status() {
  uv run --no-project --quiet python - "$WINGMAN_HOME/crew/$1.json" "${2:-10}" <<'EOF'
import json, sys, datetime
d = json.load(open(sys.argv[1]))
d["updated"] = (datetime.datetime.now(datetime.timezone.utc)
                - datetime.timedelta(minutes=int(sys.argv[2]))).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
json.dump(d, open(sys.argv[1], "w"))
EOF
}

wm_state() { uv run --no-project --quiet "$TEST_REPO/bin/lib/wm-state.py" "$@"; }

# Run a command under a hard wall-clock timeout. macOS ships no coreutils
# `timeout`, and every watch-fleet invocation in the suite must be bounded: the
# watcher BLOCKS until an event, so a foreground `$(watch-fleet)` that never fires
# would wedge the test - and, through tests/run.sh, the whole suite - forever.
# Returns the command's own exit status when it finishes in time; on timeout the
# command is killed (TERM, then KILL) and a diagnostic goes to stderr so the
# awaiting assertion fails loudly instead of hanging. Usable inside command
# substitution: only the command writes to stdout; the watchdog's stdout is
# detached so it never holds the substitution pipe open. bash-3.2-safe.
wm_timeout() {
  _wt_secs="$1"; shift
  "$@" &
  _wt_pid=$!
  ( sleep "$_wt_secs"
    printf 'wm_timeout: command exceeded %ss (pid %s); killing\n' "$_wt_secs" "$_wt_pid" >&2
    kill -TERM "$_wt_pid" 2>/dev/null
    sleep 2
    kill -KILL "$_wt_pid" 2>/dev/null ) >/dev/null &
  _wt_wd=$!
  wait "$_wt_pid" 2>/dev/null; _wt_rc=$?
  kill "$_wt_wd" 2>/dev/null
  wait "$_wt_wd" 2>/dev/null
  return "$_wt_rc"
}

# Track background watch-fleet (or other) pids a test launches, so an EXIT trap can
# reap them. A test's happy path still kills its own watchers explicitly; this is
# the safety net that stops a blocking watcher outliving the test - and leaking
# into later suites - if an assertion path returns early. Install with:
#   trap wm_kill_tracked EXIT
# and call `wm_track "$pid"` after each background launch.
WM_TRACKED_PIDS=""
wm_track() { WM_TRACKED_PIDS="$WM_TRACKED_PIDS $1"; }
wm_kill_tracked() {
  _rc=$?
  [ -n "$WM_TRACKED_PIDS" ] && kill $WM_TRACKED_PIDS 2>/dev/null
  WM_TRACKED_PIDS=""
  return "$_rc"
}

ok()   { _TESTS_RUN=$((_TESTS_RUN+1)); printf '  ok   - %s\n' "$1"; }
fail() { _TESTS_RUN=$((_TESTS_RUN+1)); _TESTS_FAIL=$((_TESTS_FAIL+1)); printf '  FAIL - %s\n' "$1"; }

assert_eq()       { [ "$2" = "$3" ] && ok "$1" || { fail "$1"; printf '         expected [%s] got [%s]\n' "$3" "$2"; }; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1"; printf '         [%s] does not contain [%s]\n' "$2" "$3" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) fail "$1"; printf '         [%s] should not contain [%s]\n' "$2" "$3" ;; *) ok "$1" ;; esac; }
assert_true()     { if eval "$2" >/dev/null 2>&1; then ok "$1"; else fail "$1"; fi; }
assert_false()    { if eval "$2" >/dev/null 2>&1; then fail "$1"; else ok "$1"; fi; }

test_summary() {
  printf '\n%d run, %d failed\n' "$_TESTS_RUN" "$_TESTS_FAIL"
  [ "$_TESTS_FAIL" -eq 0 ]
}
