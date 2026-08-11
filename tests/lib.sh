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

# Shared path template for wm_mktemp_dir/wm_mktemp_file (see wm_cleanup_all
# below). $$ inside a command substitution is the PARENT shell's pid, not the
# subshell's - stable across the substitution, unlike $BASHPID - so every
# directory or file a given test process creates, however many times it calls
# either helper, lands under the identical wm-test.<run-token>.<pid>. prefix.
# This makes the temp-path cleanup glob-based rather than list-tracked: a
# wm_track_dir-style registration made from inside wm_mktemp_dir would append
# to a copy of the tracking list that dies with the command-substitution
# subshell it runs in, leaving the parent shell's list empty forever. The
# glob needs nothing to survive a subshell boundary because nothing has to
# propagate out of one - the template is reconstructible from
# $WM_TEST_RUN_ID and $$, both already known in the parent shell.
# The base is physically normalized (cd -P) once: macOS's $TMPDIR is a
# symlink under /var -> /private/var (often with a trailing slash), while the
# product code normalizes every path it echoes back (spawn-crew's `cd -P`,
# wm-state's abspath) - an unnormalized template here makes assert_contains
# compare /var/...//... against /private/var/..., failing on macOS only.
_WM_TMP_BASE="$(cd -P "${TMPDIR:-/tmp}" && pwd -P)"
# Floor for settings-file isolation, in force from the moment this file is
# sourced and regardless of whether a test ever calls test_new_home (which
# re-points it at that test's own home). Unconditional, not `:-`: a developer
# with WM_CONFIG_TOML already exported, or with a config.local.toml at the repo
# root, must not have it read by the suite.
export WM_CONFIG_TOML="$_WM_TMP_BASE/wm-test-absent-config.toml"
# Exported so every consumer of $TMPDIR in the code under test (e.g.
# wm_guard_test_fixture_agent's case match in bin/lib/common.sh) sees the same
# normalized base the temp dirs are actually created under.
export TMPDIR="$_WM_TMP_BASE"
_wm_tmpl() { printf '%s/wm-test.%s.%s.' "$_WM_TMP_BASE" "${WM_TEST_RUN_ID:-x}" "$$"; }
wm_mktemp_dir()  { mktemp -d "$(_wm_tmpl)XXXXXXXX"; }
wm_mktemp_file() { mktemp    "$(_wm_tmpl)XXXXXXXX"; }

# Each test gets its own throwaway state home and a tmux session name that does
# not exist (so the watcher's reconcile step is skipped - no live windows to check
# against - and a test never disturbs the real fleet).
#
# Also records $WINGMAN_HOME onto WM_TRACKED_HOMES (every home this file ever
# creates, not just the current one - a file may call test_new_home several
# times) so wm_cleanup_all's wait-for-death step below can find any watch.pid
# this file's tests might have left running.
test_new_home() {
  _wm_home_parent="$(wm_mktemp_dir)"
  WINGMAN_HOME="$_wm_home_parent/wm"
  export WINGMAN_HOME
  WM_TRACKED_HOMES="$WM_TRACKED_HOMES $WINGMAN_HOME"
  export WM_TMUX_SESSION="wm-test-${WM_TEST_RUN_ID:-x}-$$-$RANDOM"
  wm_track_tmux "$WM_TMUX_SESSION"
  # The tests model wingman's own top-level scope (owner ""). When the suite runs
  # inside a crew session, the inherited crew id would silently re-scope
  # watch-fleet and the Stop hook to that crew's (empty) reports.
  unset WINGMAN_CREW_ID
  # Pre-existing, unrelated gap found while validating issue #202: the suite
  # also runs inside a real wingman/crew session sometimes (this repo's own
  # tests are exercised by crew members), which exports a real, non-empty
  # WINGMAN_RUN_ID. bin/watch-fleet's run-id ownership check (#162) then reads
  # every fixture-recorded live cycle with no matching RUNFILE stamp as a
  # FOREIGN cycle armed by "a different run" rather than legacy/unset-run-id
  # behavior (a live cycle reads as healthy) - silently changing which branch
  # a test exercises based on who happens to be running the suite, not what
  # the test itself set up. Every test that cares about WINGMAN_RUN_ID already
  # exports/unsets it explicitly around its own assertions (e.g.
  # stop-continuity.test.sh), so unsetting it here is exactly as safe as the
  # WINGMAN_CREW_ID unset just above and closes the same class of gap.
  unset WINGMAN_RUN_ID
  # Same class of gap, one variable further (review round on issue #202's own
  # PR): a session that holds a real reviewer's WM_REVIEW_TOKEN leaks it into
  # every wm_state review-sign call a test makes without passing --token/
  # WM_REVIEW_TOKEN explicitly, which can silently swap in a real proof
  # instead of the test's own fixture token. Every test that cares about
  # WM_REVIEW_TOKEN already sets it per-command (e.g. no-merge-guard.test.sh,
  # wm-state-review-gate.test.sh), so unsetting it here is safe.
  unset WM_REVIEW_TOKEN
  # A wingman/crew session (or a dev shell sourcing this box's autostart env)
  # may export a non-default budget, which would silently invalidate every
  # assertion that depends on the documented implicit default of 3.
  unset WM_SPURIOUS_BUDGET_COUNT
  # Isolated Claude Code gate fixtures (issue #16), so bin/spawn-crew's
  # preflight trust/bypass checks never read (or write) a real developer
  # machine's ~/.claude.json / ~/.claude/settings.json, and never block a
  # test spawn by default. Bypass-Permissions starts pre-accepted (mirrors
  # the common real-machine state - only the dedicated preflight test
  # exercises the "not yet accepted" path); the trust config starts with no
  # repos trusted - see wm_trust_repo below for granting it per repo, the
  # test-fixture equivalent of "run claude here once and accept the dialog".
  WM_CLAUDE_USER_SETTINGS="$_wm_home_parent/claude-settings.json"
  export WM_CLAUDE_USER_SETTINGS
  printf '{"skipDangerousModePermissionPrompt": true}\n' > "$WM_CLAUDE_USER_SETTINGS"
  WM_CLAUDE_USER_CONFIG="$_wm_home_parent/claude-config.json"
  export WM_CLAUDE_USER_CONFIG
  printf '{"projects": {}}\n' > "$WM_CLAUDE_USER_CONFIG"
  # Isolated settings file, pointed at a path that does not exist yet. Without
  # this the suite would read whatever config.local.toml the developer running
  # it happens to keep at the repo root: their own [prefs] answers would make
  # every "preferences are unanswered" assertion pass vacuously, and their
  # [models] entries would rewrite the model a test spawn resolves. A test that
  # WANTS a settings file writes one here (see wm_write_config below).
  WM_CONFIG_TOML="$_wm_home_parent/config.local.toml"
  export WM_CONFIG_TOML
  wm_state init >/dev/null
}

# Write the current test's isolated settings file (see test_new_home) from
# stdin, so a test exercises config.local.toml exactly as a pilot would keep it:
#   wm_write_config <<'EOF'
#   [models]
#   default = "opus"
#   EOF
wm_write_config() { cat > "$WM_CONFIG_TOML"; }

# Remove the current test's settings file, back to the no-file baseline.
wm_rm_config() { rm -f "$WM_CONFIG_TOML"; }

# Grant workspace trust for one repo path in the current test's isolated
# WM_CLAUDE_USER_CONFIG fixture (see test_new_home above) - the test-fixture
# equivalent of "run claude here once, interactively, and accept the trust
# dialog." Physically normalizes the path first so it matches exactly what
# bin/spawn-crew itself queries against (a symlinked route would otherwise
# mismatch the real, resolved path).
wm_trust_repo() {
  _tr_path="$(cd -P "$1" && pwd -P)"
  uv run --no-project --quiet python - "$WM_CLAUDE_USER_CONFIG" "$_tr_path" <<'EOF'
import json, sys
path, repo = sys.argv[1], sys.argv[2]
d = json.load(open(path))
d.setdefault("projects", {})[repo] = {"hasTrustDialogAccepted": True}
json.dump(d, open(path, "w"))
EOF
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

# Back-date a path's mtime by N seconds (default 30), for testing the
# claim-lock age gate deterministically. Uses os.utime rather than shelling
# out to `touch -d`/`touch -v`, which differ between GNU and BSD - portable
# to macOS, mirroring wm_age_status above.
wm_age_path() {
  uv run --no-project --quiet python - "$1" "${2:-30}" <<'EOF'
import os, sys, time
path, seconds_ago = sys.argv[1], int(sys.argv[2])
t = time.time() - seconds_ago
os.utime(path, (t, t))
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

# Track background watch-fleet (or other) pids a test launches, so the shared
# EXIT trap (wm_cleanup_all, below) can reap them. A test's happy path still
# kills its own watchers explicitly; this is the safety net that stops a
# blocking watcher outliving the test - and leaking into later suites - if an
# assertion path returns early. Call `wm_track "$pid"` after each background
# launch; nothing needs to install a trap itself, lib.sh already has.
WM_TRACKED_PIDS=""
wm_track() { WM_TRACKED_PIDS="$WM_TRACKED_PIDS $1"; }

# Track tmux session names for kill-session on cleanup. Accumulates across
# multiple test_new_home calls in the same file (a plain list append, never
# an overwrite), so a file with several sessions gets every one of them torn
# down, not just the last captured. test_new_home calls this itself for the
# WM_TMUX_SESSION name it generates, so every file gets this for free; a file
# that mints an *additional* session name derived from $WM_TMUX_SESSION (e.g.
# a DECOY or a "$WM_TMUX_SESSION-submit" companion) calls this once more
# explicitly.
WM_TRACKED_TMUX=""
wm_track_tmux() { WM_TRACKED_TMUX="$WM_TRACKED_TMUX $1"; }

# Stop a guardian a real bin/wingman invocation spawned against the CURRENT
# $WINGMAN_HOME, right away rather than waiting for this file's own
# end-of-run cleanup (_wm_live_guardian_pids/wm_cleanup_all, above) to reap
# it. The guardian polls the box's real default tmux socket (it has no
# per-test isolation the way WM_TMUX_SESSION gives ordinary tmux operations),
# forking a handful of tmux/ps processes every couple of seconds - genuinely
# real, continuous background load for however long it survives, which is
# otherwise "until this whole file's trap fires," not "until the one
# assertion that needed it is done." A test invoking real bin/wingman
# (tests/session-guard-hook-sync.test.sh) should call this immediately after
# each such invocation, before its assertions even run.
wm_stop_guardian() { "$TEST_REPO/bin/lib/tmux-guardian.sh" --stop 2>/dev/null; }

# Every $WINGMAN_HOME test_new_home has ever pointed at in this file (see
# test_new_home above) - not pids, paths. wm_cleanup_all reads each one's
# watch.pid/watch-*.pid to learn which watch-fleet cycles might still be
# alive, regardless of whether they were backgrounded directly (WM_TRACKED_PIDS)
# or hosted in a tracked tmux pane (WM_TRACKED_TMUX, which only records the
# session name, not the process inside it).
WM_TRACKED_HOMES=""

# pids of every watch-fleet cycle that might still be alive across every home
# this file used, read from each home's watch.pid/watch-*.pid BEFORE anything
# is signaled (kill/tmux kill-session do not erase the pidfile - only the
# watcher's own INT/TERM trap does, as part of exiting - so reading first just
# avoids a benign miss if that trap already ran independently).
_wm_live_watch_pids() {
  for _h in $WM_TRACKED_HOMES; do
    for _pf in "$_h"/watch.pid "$_h"/watch-*.pid; do
      [ -f "$_pf" ] || continue
      _p="$(cat "$_pf" 2>/dev/null)"
      case "$_p" in ''|*[!0-9]*) continue ;; esac
      printf '%s ' "$_p"
    done
  done
}

# Same shape as _wm_live_watch_pids, for bin/lib/tmux-guardian.sh's own
# tmux-guardian.pid (issue #218). Kept as a separate helper, not folded into
# the one above, because it is a genuinely different daemon with a different
# lifecycle - but it needs the identical treatment: any test that runs a
# real bin/wingman (e.g. tests/session-guard-hook-sync.test.sh) launches one
# of these as a deliberately detached, scope-wrapped background process (the
# whole point of the guardian is to survive a death nothing else in its
# tmux server survives), so nothing about a normal test teardown (killing
# tracked pids, killing tracked tmux sessions) would ever stop it on its
# own. Without this, every such test would leak one guardian process per
# invocation, forever polling a now-deleted $WINGMAN_HOME after this file's
# own rm -rf runs.
_wm_live_guardian_pids() {
  for _h in $WM_TRACKED_HOMES; do
    _pf="$_h/tmux-guardian.pid"
    [ -f "$_pf" ] || continue
    _p="$(cat "$_pf" 2>/dev/null)"
    case "$_p" in ''|*[!0-9]*) continue ;; esac
    printf '%s ' "$_p"
  done
}

# Register teardown logic beyond "kill this pid / this session / remove this
# glob-cleaned temp path" (e.g. an explicit `rm -f "$CFG"` for a config file
# wm_mktemp_dir/wm_mktemp_file didn't create). Appends to a list the shared
# trap eval's during cleanup. This is registration, not re-trapping: any
# number of call sites can call this, and none of them installs a competing
# trap.
WM_ON_EXIT_CMDS=""
wm_on_exit() { WM_ON_EXIT_CMDS="$WM_ON_EXIT_CMDS
$1"; }

# The single EXIT/INT/TERM handler for the whole suite - see the trap
# installation at the bottom of this file for why no test file may install a
# competing trap ... EXIT|INT|TERM of its own: a second `trap ... EXIT` in
# the same shell replaces the first outright, bash traps do not chain.
# Idempotent (each tracked list is cleared as it is consumed, and the glob
# removal is inherently idempotent - a second rm -rf over an already-empty
# match is a no-op), so a second invocation (INT/TERM firing after EXIT
# already ran once, or vice versa) is always safe. Order matters: on-exit
# commands and pid kills first, then sessions, then a bounded wait for those
# same watch-fleet cycles to actually be gone, then finally the temp-path
# glob - a still-running pane can otherwise recreate output into a directory
# mid-removal.
#
# The wait step closes a real, empirically-confirmed race (issue #99): kill(1)
# and `tmux kill-session` only request termination, they do not block until
# the target has actually exited - 27/30 direct trials of `tmux kill-session`
# against a live bin/watch-fleet cycle found it still answering `kill -0`
# immediately afterward (never past ~2s, but never instantly gone either). If
# the surviving cycle completes one more poll-loop iteration before it
# actually dies, that iteration's `wm_state ...` call recreates $WINGMAN_HOME's
# whole directory tree (wm-state.py's ensure_home() runs `os.makedirs(...,
# exist_ok=True)` on every invocation) - including the top-level
# wm-test.<run>.<pid>.* directory the rm -rf below is about to remove, if that
# removal already ran first. Waiting here for the cycle to be provably dead
# before removing anything closes the race outright, rather than merely
# narrowing its window via ordering alone.
#
# The pids waited on here are the UNION of _wm_live_watch_pids() (read from
# each home's watch.pid/watch-*.pid) and WM_TRACKED_PIDS (raw pids from
# wm_track "$!"), not just the former: a watch-fleet cycle deletes its own
# pidfile as part of its OWN graceful shutdown, which can complete well
# BEFORE the underlying process has actually exited - so by the time this
# function reads _wm_live_watch_pids() the pidfile may already be gone (an
# empty result) while WM_TRACKED_PIDS still names the real, live pid.
# Waiting on the pidfile-derived set alone missed exactly that window
# (confirmed on a real CI run: wait_pids=[] while tracked_pids=[<two real
# still-alive pids>] at cleanup time, for tests/outbox-redelivery.test.sh's
# own `"$WATCH" --stop` shutdown), so both sets get the identical
# wait-then-force-kill treatment below.
wm_cleanup_all() {
  _rc=$?
  if [ -n "$WM_ON_EXIT_CMDS" ]; then
    _cmds="$WM_ON_EXIT_CMDS"
    WM_ON_EXIT_CMDS=""
    while IFS= read -r _cmd; do
      [ -z "$_cmd" ] && continue
      eval "$_cmd"
    done <<<"$_cmds"
  fi
  _guardian_pids="$(_wm_live_guardian_pids)"
  _wait_pids="$(_wm_live_watch_pids) $_guardian_pids $WM_TRACKED_PIDS"
  [ -n "$WM_TRACKED_PIDS" ] && kill $WM_TRACKED_PIDS 2>/dev/null
  # Unlike a watch-fleet pid (expected to already have been stopped by the
  # test's own explicit `--stop` call, so this loop is purely a backstop), no
  # test here knows to stop a guardian a real bin/wingman invocation happened
  # to spawn - so it gets an explicit, immediate TERM (its own trap handles
  # it in well under the 5s wait-then-SIGKILL window below) rather than
  # sitting through the full grace window on every such test for no reason.
  [ -n "$_guardian_pids" ] && kill $_guardian_pids 2>/dev/null
  WM_TRACKED_PIDS=""
  if [ -n "$WM_TRACKED_TMUX" ]; then
    for _s in $WM_TRACKED_TMUX; do
      tmux kill-session -t "=$_s" 2>/dev/null
    done
    WM_TRACKED_TMUX=""
  fi
  if [ -n "$_wait_pids" ]; then
    _wait_deadline=$(($(date +%s) + 5))
    while [ "$(date +%s)" -lt "$_wait_deadline" ]; do
      _still_alive=0
      for _p in $_wait_pids; do
        kill -0 "$_p" 2>/dev/null && _still_alive=1
      done
      [ "$_still_alive" -eq 0 ] && break
      sleep 0.05
    done
    # A pid that has not exited within the grace window above is force-
    # killed here, rather than left to possibly complete one more poll
    # iteration afterward - under load (many concurrent test files, or a
    # busy CI runner), a graceful TERM can take longer than the window to be
    # noticed, and that one extra iteration's own wm_state call recreates
    # $WINGMAN_HOME's whole directory tree (ensure_home() runs os.makedirs
    # exist_ok=True on every invocation) right after the rm -rf below already
    # removed it - a leaked, orphaned wm-test.* directory the next run's
    # sweep has to clean up after the fact. SIGKILL is safe here: everything
    # this cycle could still be mid-write to lives under the very path about
    # to be removed anyway, so there is nothing graceful left worth waiting
    # for - it only needs to be reliably dead before rm -rf runs.
    for _p in $_wait_pids; do
      kill -0 "$_p" 2>/dev/null && kill -9 "$_p" 2>/dev/null
    done
  fi
  WM_TRACKED_HOMES=""
  rm -rf "$(_wm_tmpl)"* 2>/dev/null
  return "$_rc"
}

# Defense-in-depth safe default for the automated suite: any test that omits
# its own stub override gets a harmless one instead of falling through to a
# real `claude` launch. This does not cover the vector actually reproduced
# for issue #38 (a manual bin/crew-resume invocation against a leaked
# fixture never sources this file) - that is closed by
# wm_guard_test_fixture_agent in bin/lib/common.sh instead, which every real
# launch point calls regardless of who invoked it. sleep infinity (not sleep
# 60) so it cannot expire mid-file in a long-running suite like
# watch-fleet.test.sh.
#
# WM_AGENT_BIN_OVERRIDE, not WM_AGENT (issue #25): $WM_AGENT now selects a
# DESCRIPTOR (bin/lib/agents/<name>.sh - claude by default), not a binary
# path directly, so setting it to a stub path would make bin/spawn-crew die
# looking for a nonexistent "bin/lib/agents/<stub-path>.sh" descriptor
# instead of substituting the exec target. WM_AGENT_BIN_OVERRIDE is the
# escape hatch that still redirects just the exec target while leaving the
# claude descriptor's own real flag/preflight/detection logic in force - see
# bin/lib/agent.sh's wm_agent_resolve.
export WM_AGENT_BIN_OVERRIDE="${WM_AGENT_BIN_OVERRIDE:-$TEST_REPO/tests/fixtures/stub-agent.sh}"

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

# Installed last so it is armed the moment any test file finishes sourcing
# this file, with no per-file action required. This is the ONLY place any of
# these three traps is installed in the entire suite - no test file may
# install a competing trap ... EXIT|INT|TERM of its own (enforced by a static
# check in tests/run.sh). INT and TERM get their own terminal handlers rather
# than being folded into the EXIT trap's signal list: a `trap foo INT`
# handler that does not itself terminate the process leaves bash resuming the
# script body right after the handler returns, so a bare `trap wm_cleanup_all
# INT` would delete the fixtures a Ctrl-C'd test's remaining assertions still
# expect, then keep running those assertions against now-deleted state, and
# exit 0. `exit 130`/`exit 143` (128+signal) makes each handler terminal
# instead.
trap wm_cleanup_all EXIT
trap 'wm_cleanup_all; exit 130' INT   # 128+SIGINT
trap 'wm_cleanup_all; exit 143' TERM  # 128+SIGTERM
