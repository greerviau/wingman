#!/usr/bin/env bash
# E2E: hooks/lib/watcher-liveness.sh's wm_owner_paths and bin/watch-fleet's own
# per-owner file-definition block are two independent derivations of the same
# owner-keyed paths (issue #185's own "known, accepted duplication" - see the
# plan's "Files touched" section). This proves they agree, behaviorally, for
# both an unscoped ("") and a scoped owner: bin/watch-fleet cannot be sourced
# for its own path variables (it is a full script, not a library of
# functions), so agreement is proven by observing that a claim in
# bin/watch-fleet actually clears $STOPFILE/$SUPPRESSEDFILE/$CLAIMFAILFILE at
# exactly the paths wm_owner_paths independently predicts - a drift in either
# derivation would leave the "other side's" file untouched.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WF="$TEST_REPO/bin/watch-fleet"
LIB="$TEST_REPO/hooks/lib/watcher-liveness.sh"
export WM_WATCH_INTERVAL=1

check_owner() {
  _co_owner="$1"; _co_label="$2"
  test_new_home
  # wm_owner_paths' own derivation for this owner.
  ( . "$LIB"; wm_owner_paths "$_co_owner" "$WINGMAN_HOME"
    printf '%s\n%s\n%s\n%s\n%s\n' "$pidfile" "$beatfile" "$stopfile" "$suppressedfile" "$claimfailfile" \
      > "$WINGMAN_HOME/lib-derived-paths.txt" )
  _lib_pidfile="$(sed -n '1p' "$WINGMAN_HOME/lib-derived-paths.txt")"
  _lib_beatfile="$(sed -n '2p' "$WINGMAN_HOME/lib-derived-paths.txt")"
  _lib_stopfile="$(sed -n '3p' "$WINGMAN_HOME/lib-derived-paths.txt")"
  _lib_suppressedfile="$(sed -n '4p' "$WINGMAN_HOME/lib-derived-paths.txt")"
  _lib_claimfailfile="$(sed -n '5p' "$WINGMAN_HOME/lib-derived-paths.txt")"

  # Pre-create files at the lib's own predicted stopfile/suppressedfile/
  # claimfailfile paths, then let bin/watch-fleet claim for real. A
  # successful claim clears all three unconditionally (see bin/watch-fleet's
  # own claim-point comment) - if bin/watch-fleet's own derivation of any of
  # these three names a DIFFERENT path than the lib predicts, the
  # corresponding file here would survive the claim untouched.
  printf 'x\n' > "$_lib_stopfile"
  printf 'x\ny\n' > "$_lib_suppressedfile"
  printf 'x\n' > "$_lib_claimfailfile"

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
  kill "$_co_pid" 2>/dev/null
  unset WINGMAN_CREW_ID
}

check_owner "" unscoped
check_owner "leadx" scoped

test_summary
