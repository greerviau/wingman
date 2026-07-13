#!/usr/bin/env bash
# Run every tests/*.test.sh and roll up the result. bash-3.2-safe.
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
# why timestamp-based scoping does not actually achieve this).
export WM_TEST_RUN_ID="$$-$(date +%s)"

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

for t in "$HERE"/*.test.sh; do
  [ -f "$t" ] || continue
  printf '\n=== %s ===\n' "$(basename "$t")"
  bash "$t" || fails=$((fails+1))
done
printf '\n============================\n'
if [ "$fails" -eq 0 ]; then printf 'ALL SUITES PASSED\n'; else printf '%d SUITE(S) FAILED\n' "$fails"; fi
exit "$fails"
