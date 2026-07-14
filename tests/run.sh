#!/usr/bin/env bash
# Run every tests/*.test.sh, up to WM_TEST_JOBS at a time, and roll up the
# result. bash-3.2-safe.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

# --- static invariant checks (run once, before the suite loop) ---------------
# See docs/plans/2026-07-13-issue-38-test-suite-teardown.md. Both invariants
# below are permanent, not one-time cleanups: a future test that violates
# either fails the suite loudly instead of silently reintroducing the leak
# this plan closes. Line-based text matching, deliberately - clean today, but
# a test fixture written as an inline heredoc could false-positive if any of
# its lines happen to look like a trap/new-session invocation of its own;
# fixture scripts belong under tests/fixtures/, which is naturally outside
# this tests/*.test.sh glob.
_static_fail=0

# Invariant 1: lib.sh's shared trap is the only EXIT/INT/TERM trap anywhere in
# the suite - a second `trap ... EXIT` in the same shell replaces the first
# outright (bash traps do not chain), so any competing per-file trap silently
# defeats the shared teardown for that file.
_trap_files="$(grep -lE '^[[:space:]]*trap .* (EXIT|INT|TERM)' "$HERE"/*.test.sh 2>/dev/null)"
if [ -n "$_trap_files" ]; then
  printf 'STATIC CHECK FAILED: competing trap ... EXIT|INT|TERM outside lib.sh:\n%s\n' "$_trap_files"
  _static_fail=1
fi

# Invariant 2: every tmux session name any test mints is derived from
# $WM_TMUX_SESSION, so it carries this run's token and is visible to both the
# shared trap's registration and the identity-scoped sweep below. Pinned to an
# exact, runnable form rather than left for a reviewer to re-derive by hand:
# every variable ever used as a `new-session -s` target is either
# WM_TMUX_SESSION itself, or has an assignment somewhere in the suite whose
# right-hand side contains $WM_TMUX_SESSION.
for _v in $(grep -hoE 'new-session[^|]*-s "\$\{?([A-Za-z_]+)' "$HERE"/*.test.sh \
            | grep -oE '[A-Za-z_]+$' | sort -u); do
  [ "$_v" = WM_TMUX_SESSION ] && continue
  grep -qE "^[[:space:]]*$_v=.*\\\$\{?WM_TMUX_SESSION" "$HERE"/*.test.sh \
    || { printf 'STATIC CHECK FAILED: session name $%s is not derived from $WM_TMUX_SESSION\n' "$_v"; _static_fail=1; }
done

if [ "$_static_fail" -ne 0 ]; then
  printf '\nStatic invariant check(s) failed - see above. Fix before running the suite.\n'
  exit 1
fi

# --- run token: scopes the post-loop sweep to THIS run's own resources -------
# Baked into every child test process's tmux session names and temp-dir/file
# names (tests/lib.sh), so a concurrently running test process (a developer
# running one *.test.sh by hand while this run is also in flight) is never
# mistaken for this run's own leak - identity, not a creation timestamp,
# is what tells the two apart (see the plan's "Scoping the sweep" section for
# why timestamp-based scoping does not actually achieve this). This same
# per-process derivation is also what makes running the files below
# concurrently safe: every test's WINGMAN_HOME and tmux session name is keyed
# off its own $$, so sibling test processes never collide (tests/lib.sh:35-46).
export WM_TEST_RUN_ID="$$-$(date +%s)"

# --- parallelism: how many *.test.sh files run at once ------------------------
# See docs/analysis/2026-07-14-test-suite-runtime.md, Finding 1: the suite was
# purely serial despite every file already being isolated by design, making
# wall time additive across all 33+ files for no reason. WM_TEST_JOBS overrides
# for a slower/more constrained box; the default follows the machine's own core
# count so a laptop and a CI runner each parallelize to what they actually have.
_wm_jobs="${WM_TEST_JOBS:-}"
if [ -z "$_wm_jobs" ]; then
  if command -v nproc >/dev/null 2>&1; then
    _wm_jobs="$(nproc)"
  elif command -v sysctl >/dev/null 2>&1; then
    _wm_jobs="$(sysctl -n hw.ncpu 2>/dev/null)"
  fi
fi
case "$_wm_jobs" in ''|*[!0-9]*) _wm_jobs=4 ;; esac
[ "$_wm_jobs" -ge 1 ] || _wm_jobs=4

_wm_logdir="$(mktemp -d "${TMPDIR:-/tmp}/wm-test-run.XXXXXXXX")"

fails=0
swept=0
stale=0
swept_dirs=0

# The suite-level backstop: runs unconditionally after the loop below, even if
# a child test hangs and this script itself is killed and its own trap fires
# - traps cannot run at all under SIGKILL, but this is the layer that does not
# depend on any single test's own trap having fired (a Docker OOM-kill, a CI
# runner's force-kill). `exit N` executed *inside* an EXIT trap overrides
# whatever status the script was already exiting with, so the strict-leak-check
# failure below is what actually takes effect - not a flag some later line
# would have to notice, since there is no later line once the trap runs.
_wm_run_sweep() {
  _rc=$?

  _sessions="$(tmux list-sessions -F '#{session_name}' 2>/dev/null)"
  while read -r _name; do
    [ -z "$_name" ] && continue
    case "$_name" in
      wm-test-"$WM_TEST_RUN_ID"-*) tmux kill-session -t "$_name" 2>/dev/null; swept=$((swept+1)) ;;
      wm-test-*)
        stale=$((stale+1))
        [ "${WM_TEST_SWEEP_STALE:-0}" = 1 ] && tmux kill-session -t "$_name" 2>/dev/null
        ;;
    esac
  done <<<"$_sessions"

  _dirs="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name "wm-test.${WM_TEST_RUN_ID}.*" 2>/dev/null)"
  while read -r _d; do
    [ -z "$_d" ] && continue
    rm -rf "$_d"
    swept_dirs=$((swept_dirs+1))
  done <<<"$_dirs"

  rm -rf "$_wm_logdir"

  printf '\n=== teardown sweep (run %s) ===\n' "$WM_TEST_RUN_ID"
  printf "this run's leaked tmux sessions swept (swept):        %d\n" "$swept"
  printf 'stale (pre-existing or concurrent) wm-test-* sessions found, left alone: %d (rerun with WM_TEST_SWEEP_STALE=1 to remove)\n' "$stale"
  printf "this run's leaked temp dirs/files swept (swept_dirs):  %d\n" "$swept_dirs"

  # Gated behind WM_TEST_STRICT_LEAK_CHECK: CI runners are ephemeral and
  # always start clean, so it is set there unconditionally (no baseline to
  # wait for - the check has teeth from the first merge). A local run stays
  # unchecked by default, since an already-dirty local box should not fail an
  # unrelated change; it still gets the sweep and the report either way.
  if [ "${WM_TEST_STRICT_LEAK_CHECK:-0}" = 1 ] && { [ "$swept" -ne 0 ] || [ "$swept_dirs" -ne 0 ]; }; then
    printf 'WM_TEST_STRICT_LEAK_CHECK=1: this run leaked resources past its own traps - failing.\n'
    exit 1
  fi
  exit "$_rc"
}
trap _wm_run_sweep EXIT

# Longest-known-file-first: with a fixed number of job slots, starting the
# heaviest files immediately is what actually gets them running concurrently
# instead of queuing behind quick files that merely sort earlier
# alphabetically (a plain directory-order launch would let a slot free up
# from a fast file and start another fast file well before a slow file later
# in the alphabet ever gets a slot). Ranking is from
# docs/analysis/2026-07-14-test-suite-runtime.md's per-file timings; a file
# not in this list, or a rank that has since drifted, still just runs - this
# is a scheduling hint, not a required inventory.
_wm_priority="watch-fleet.test.sh crew-resume.test.sh playbook-resolution.test.sh watch-fleet-classify.test.sh spawn-scope.test.sh tmux-session-targeting.test.sh stall-check.test.sh"

_wm_ordered=()
for _p in $_wm_priority; do
  [ -f "$HERE/$_p" ] && _wm_ordered[${#_wm_ordered[@]}]="$HERE/$_p"
done
for t in "$HERE"/*.test.sh; do
  [ -f "$t" ] || continue
  case " $_wm_priority " in
    *" $(basename "$t") "*) continue ;;
  esac
  _wm_ordered[${#_wm_ordered[@]}]="$t"
done

# --- job pool: up to $_wm_jobs files in flight at once ------------------------
# Plain indexed-array bookkeeping, not `wait -n` or associative arrays, to stay
# bash-3.2-safe. A finished slot is marked by blanking its pid (never removed
# mid-array), so every array reference below is either a length check
# (`${#_wm_pids[@]}`, always safe under `set -u`) or a single-element access
# (`${_wm_pids[$_i]}`) - never a bare `${arr[@]}` expansion, which bash 3.2
# rejects under `set -u` for an empty array.
_wm_names=()
_wm_pids=()
_wm_logs=()
_wm_live=0

_wm_reap_one() {
  while :; do
    _i=0
    while [ "$_i" -lt "${#_wm_pids[@]}" ]; do
      _pid="${_wm_pids[$_i]}"
      if [ -n "$_pid" ] && ! kill -0 "$_pid" 2>/dev/null; then
        wait "$_pid" 2>/dev/null
        _rc=$?
        printf '\n=== %s ===\n' "${_wm_names[$_i]}"
        cat "${_wm_logs[$_i]}"
        rm -f "${_wm_logs[$_i]}"
        [ "$_rc" -eq 0 ] || fails=$((fails+1))
        _wm_pids[$_i]=""
        _wm_live=$((_wm_live-1))
        return
      fi
      _i=$((_i+1))
    done
    sleep 0.2
  done
}

printf 'running %d file(s), up to %d at a time\n' "${#_wm_ordered[@]}" "$_wm_jobs"

for t in "${_wm_ordered[@]}"; do
  while [ "$_wm_live" -ge "$_wm_jobs" ]; do
    _wm_reap_one
  done
  printf 'start: %s\n' "$(basename "$t")"
  _wm_log="$_wm_logdir/$(basename "$t").log"
  bash "$t" >"$_wm_log" 2>&1 &
  _idx=${#_wm_pids[@]}
  _wm_pids[$_idx]=$!
  _wm_names[$_idx]="$(basename "$t")"
  _wm_logs[$_idx]="$_wm_log"
  _wm_live=$((_wm_live+1))
done

while [ "$_wm_live" -gt 0 ]; do
  _wm_reap_one
done

printf '\n============================\n'
if [ "$fails" -eq 0 ]; then printf 'ALL SUITES PASSED\n'; else printf '%d SUITE(S) FAILED\n' "$fails"; fi
exit "$fails"
