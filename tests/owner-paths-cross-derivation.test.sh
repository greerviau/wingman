#!/usr/bin/env bash
# E2E: hooks/lib/watcher-liveness.sh's wm_owner_paths, bin/watch-fleet's own
# per-owner file-definition block, and hooks/no-foreground-watcher-guard.sh's
# own python-side derivation are THREE independent derivations of the same
# owner-keyed paths (issue #185's own "known, accepted duplication", extended
# by issue #198's own standdown-marker denial - see the plan's "Files
# touched" section). This proves all three agree, behaviorally, for both an
# unscoped ("") and a scoped owner: bin/watch-fleet cannot be sourced for its
# own path variables (it is a full script, not a library of functions), so
# agreement with it is proven by observing that a claim actually clears
# $STOPFILE/$SUPPRESSEDFILE/$CLAIMFAILFILE at exactly the paths
# wm_owner_paths independently predicts; agreement with the guard is proven
# by observing that it denies an arm when a marker exists at exactly that
# same predicted path - a drift in any derivation would leave the "other
# side's" file untouched, or the guard reading (or missing) the wrong path.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WF="$TEST_REPO/bin/watch-fleet"
LIB="$TEST_REPO/hooks/lib/watcher-liveness.sh"
GUARD="$TEST_REPO/hooks/no-foreground-watcher-guard.sh"
export WM_WATCH_INTERVAL=1

run_guard() {
  # run_guard <command> - always run_in_background: true, matching an arm.
  uv run --no-project --quiet python -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1], "run_in_background": True}}))
' "$1" | bash "$GUARD"
}

check_owner() {
  _co_owner="$1"; _co_label="$2"
  test_new_home
  # A real roster record AND a real tmux window for a non-empty owner (issue
  # #237, Fix 2b - round-2 review's own MF-3/MF-4 finding): without a roster
  # record at all, that owner's cycle sees an AMBIGUOUS crew-get read every
  # poll, a legitimate trigger for Fix 2b's own debounce counter to start
  # writing $OWNERCHECKFILE again shortly after claim. A record alone is not
  # enough, though: without a matching LIVE window, reconcile flips it to
  # died (not resumable) within a couple of polls, and Fix 2b's self-check
  # then self-stops the cycle outright - removing $PIDFILE/$OWNERLOCK and
  # invalidating every assertion below it for a reason that has nothing to
  # do with path derivation, the only thing this test is actually about. Both
  # together keep the owner genuinely, indefinitely alive - also the
  # realistic shape, since a live lead always has both.
  if [ -n "$_co_owner" ]; then
    tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
    tmux new-window -d -t "$WM_TMUX_SESSION" -n "wm-$_co_owner" 'sleep 600'
    wm_state crew-add --id "$_co_owner" --type lead --objective x --repo /tmp --window "wm-$_co_owner" --session-id "s-$_co_owner" >/dev/null
    wm_state crew-set --id "$_co_owner" --status working --summary busy >/dev/null
  fi
  # wm_owner_paths' own derivation for this owner.
  ( . "$LIB"; wm_owner_paths "$_co_owner" "$WINGMAN_HOME"
    printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$pidfile" "$beatfile" "$stopfile" "$suppressedfile" "$claimfailfile" "$ownerlock" "$ownercheckfile" \
      > "$WINGMAN_HOME/lib-derived-paths.txt" )
  _lib_pidfile="$(sed -n '1p' "$WINGMAN_HOME/lib-derived-paths.txt")"
  _lib_beatfile="$(sed -n '2p' "$WINGMAN_HOME/lib-derived-paths.txt")"
  _lib_stopfile="$(sed -n '3p' "$WINGMAN_HOME/lib-derived-paths.txt")"
  _lib_suppressedfile="$(sed -n '4p' "$WINGMAN_HOME/lib-derived-paths.txt")"
  _lib_claimfailfile="$(sed -n '5p' "$WINGMAN_HOME/lib-derived-paths.txt")"
  _lib_ownerlock="$(sed -n '6p' "$WINGMAN_HOME/lib-derived-paths.txt")"
  _lib_ownercheckfile="$(sed -n '7p' "$WINGMAN_HOME/lib-derived-paths.txt")"

  # Pre-create files at the lib's own predicted stopfile/suppressedfile/
  # claimfailfile/ownercheckfile paths, then let bin/watch-fleet claim for
  # real. A successful claim clears all four unconditionally (see
  # bin/watch-fleet's own claim-point comment) - if bin/watch-fleet's own
  # derivation of any of these four names a DIFFERENT path than the lib
  # predicts, the corresponding file here would survive the claim untouched.
  printf 'x\n' > "$_lib_stopfile"
  printf 'x\ny\n' > "$_lib_suppressedfile"
  printf 'x\n' > "$_lib_claimfailfile"
  printf '2\n' > "$_lib_ownercheckfile"

  # issue #198: the guard's own independent derivation of the marker path -
  # a marker at exactly the lib-predicted SUPPRESSEDFILE path, read under
  # this owner's WINGMAN_CREW_ID, must deny an arm. No WINGMAN_RUN_ID is set
  # (test_new_home unsets it), so the marker's "x" stamp is honored
  # regardless (no run id to certify ownership against either way).
  if [ -n "$_co_owner" ]; then
    _guard_out="$(WINGMAN_CREW_ID="$_co_owner" run_guard 'bin/watch-fleet')"
  else
    unset WINGMAN_CREW_ID
    _guard_out="$(run_guard 'bin/watch-fleet')"
  fi
  assert_contains "$_co_label: the guard's own marker-path derivation agrees with wm_owner_paths' (denies at the lib-predicted path)" "$_guard_out" '"permissionDecision": "deny"'

  if [ -n "$_co_owner" ]; then
    export WINGMAN_CREW_ID="$_co_owner"
  else
    unset WINGMAN_CREW_ID
  fi
  "$WF" >"$WINGMAN_HOME/wf-$_co_label.log" 2>&1 &
  _co_pid=$!
  wm_track "$_co_pid"
  _n=0
  while [ ! -s "$_lib_pidfile" ] && [ "$_n" -lt 50 ]; do sleep 0.2; _n=$((_n+1)); done
  assert_true "$_co_label: watch-fleet's own PIDFILE derivation matches wm_owner_paths' (a live claim wrote it there)" "[ -s '$_lib_pidfile' ]"
  assert_true "$_co_label: the pid at the lib's predicted PIDFILE path is genuinely this claim" "[ \"\$(cat '$_lib_pidfile' 2>/dev/null)\" = '$_co_pid' ]"
  _n=0
  while [ ! -f "$_lib_beatfile" ] && [ "$_n" -lt 50 ]; do sleep 0.2; _n=$((_n+1)); done
  assert_true "$_co_label: watch-fleet's own BEATFILE derivation matches wm_owner_paths'" "[ -f '$_lib_beatfile' ]"
  assert_false "$_co_label: the claim cleared the lib-predicted STOPFILE (derivations agree)" "[ -f '$_lib_stopfile' ]"
  assert_false "$_co_label: the claim cleared the lib-predicted SUPPRESSEDFILE (derivations agree)" "[ -f '$_lib_suppressedfile' ]"
  assert_false "$_co_label: the claim cleared the lib-predicted CLAIMFAILFILE (derivations agree)" "[ -f '$_lib_claimfailfile' ]"
  assert_false "$_co_label: the claim cleared the lib-predicted OWNERCHECKFILE (derivations agree)" "[ -f '$_lib_ownercheckfile' ]"
  # $OWNERLOCK (issue #237) is CREATED and left in place, not cleared, so it
  # gets the opposite check: it must exist at exactly the lib-predicted path,
  # as a directory, stamped with this claim's own pid - if bin/watch-fleet's
  # own derivation disagreed, nothing would ever appear at this path at all.
  _n=0
  while [ ! -d "$_lib_ownerlock" ] && [ "$_n" -lt 50 ]; do sleep 0.2; _n=$((_n+1)); done
  assert_true "$_co_label: watch-fleet's own OWNERLOCK derivation matches wm_owner_paths' (a live claim created it there)" "[ -d '$_lib_ownerlock' ]"
  assert_true "$_co_label: the pid stamped at the lib's predicted OWNERLOCK path is genuinely this claim" "[ \"\$(sed -n '1p' '$_lib_ownerlock/owner' 2>/dev/null)\" = '$_co_pid' ]"
  kill "$_co_pid" 2>/dev/null
  unset WINGMAN_CREW_ID
  [ -n "$_co_owner" ] && tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null
}

check_owner "" unscoped
check_owner "leadx" scoped

test_summary
