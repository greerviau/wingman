#!/usr/bin/env bash
# hooks/lib/watcher-liveness.sh - shared watcher/marker liveness helpers for
# hooks/stop-guard.sh and hooks/stop-continuity.sh (issue #185). Sourced, not
# executed directly. bash-3.2-safe.
#
# Every function here reads/sets plain (non-local) shell variables - this is
# deliberate: callers rely on wm_owner_paths leaving pidfile/beatfile/etc set
# in their own scope afterward, exactly like the inline blocks it replaces
# used to. wm_watcher_up and wm_unwaited_reason also assume the caller has
# already set $WM_HOME, $WM_UV, and $STATE_PY (every hook that sources this
# file defines all three near the top, identically) - not re-threaded through
# every call for that reason.

# The internal claim-wait-account loop's own budget constants (issue #231):
# how long one hook invocation's lifetime defaults to, the minimum registered
# `timeout` bin/doctor requires so that lifetime actually fits inside it, and
# the safety margin the hook clamps its own lifetime below the registered
# timeout by (see hooks/stop-continuity.sh's own self-clamp). Env-overridable
# (`:=`, not the functions' own `:-`) so the test suite can exercise the
# clamp - in particular the margin, whose fixed 300s default cannot otherwise
# be made to bind within a short test window.
: "${WM_CONTINUITY_LIFETIME_DEFAULT:=3300}"
: "${WM_CONTINUITY_TIMEOUT_MIN:=3600}"
: "${WM_CONTINUITY_TIMEOUT_MARGIN:=300}"

# The spurious-repeated standdown's fallback text (issue #198), used by both
# Stop hooks whenever a marker's own stored text (line 2+) comes back empty -
# a pre-fix marker written by an older session, or a truncated write. Never
# the routine arm-demanding nudge: falling back to that would be R1 again for
# any legacy marker. Env-overridable like the constants above, primarily so
# the test suite can assert against it directly rather than duplicating its
# prose. `${WM_HOME:-}`, not a bare `$WM_HOME`: this line runs at SOURCE time,
# unconditionally, and a caller that sources this file only for its
# path-derivation helpers (e.g. tests/owner-paths-cross-derivation.test.sh)
# may do so under `set -u` without ever setting $WM_HOME - a bare reference
# would abort that sourcing outright. Every real Stop-hook caller has already
# set $WM_HOME before sourcing this file (see the header comment above), so
# this resolves to the real path in every case that actually surfaces it.
: "${WM_STANDDOWN_FALLBACK:=Fleet supervision is standing down after repeated watch-fleet deaths for this session (see ${WM_HOME:-}/watch-spurious.log); supervision is not being maintained. Report this to the pilot and stop. Do NOT arm a watch-fleet cycle and do NOT run /watch in response - lifting the standdown is up to the pilot.}"

# wm_owner_paths <owner> <wm_home>
# Derives the owner key once and sets every owner-keyed path both hooks (and
# bin/watch-fleet's own per-owner block, re-derived independently there - see
# the plan's "known, accepted duplication" note) reference: pidfile, beatfile,
# exitfile, runfile, stopfile, claimlock, wakefile, inflightfile,
# suppressedfile, claimfailfile. Owner "" (wingman's own top-level scope)
# keeps the legacy unscoped names, matching bin/watch-fleet exactly.
wm_owner_paths() {
  _wop_owner="$1"; _wop_home="$2"
  if [ -n "$_wop_owner" ]; then
    _okey="$(printf '%s' "$_wop_owner" | tr -c 'A-Za-z0-9._-' '_')"
  else
    _okey=""
  fi
  if [ -n "$_okey" ]; then
    pidfile="$_wop_home/watch-$_okey.pid"
    beatfile="$_wop_home/watch-$_okey.beat"
    exitfile="$_wop_home/watch-exit-$_okey"
    runfile="$_wop_home/watch-$_okey.run"
    wakefile="$_wop_home/wake-$_okey"
    stopfile="$_wop_home/watch-$_okey.stopped"
    suppressedfile="$_wop_home/watch-$_okey.suppressed"
  else
    pidfile="$_wop_home/watch.pid"
    beatfile="$_wop_home/watch.beat"
    exitfile="$_wop_home/watch-exit"
    runfile="$_wop_home/watch.run"
    wakefile="$_wop_home/wake"
    stopfile="$_wop_home/watch.stopped"
    suppressedfile="$_wop_home/watch.suppressed"
  fi
  claimlock="$pidfile.lock"
  inflightfile="$_wop_home/stop-continuity${_okey:+-$_okey}.pid"
  claimfailfile="$_wop_home/stop-continuity${_okey:+-$_okey}.claimfail"
}

# wm_watcher_up <owner> <wm_home>
# Sets watcher_up=1 iff a watch-fleet cycle is live for <owner>: its pidfile
# names a live pid AND its beacon is fresher than $WM_WATCH_GRACE (default
# 30s) - a blocking watcher touches the beacon every loop, so a crashed one
# goes stale within the grace even if a stale pidfile lingers. Also leaves
# pidfile/beatfile/etc (see wm_owner_paths) set in the caller's scope.
wm_watcher_up() {
  wm_owner_paths "$1" "$2"
  watcher_up=0
  _wwu_grace="${WM_WATCH_GRACE:-30}"
  if [ -f "$pidfile" ] && [ -f "$beatfile" ]; then
    _wwu_pid="$(cat "$pidfile" 2>/dev/null)"
    if [ -n "$_wwu_pid" ] && kill -0 "$_wwu_pid" 2>/dev/null; then
      _wwu_beat_m="$($WM_UV python -c 'import os,sys;print(int(os.path.getmtime(sys.argv[1])))' "$beatfile" 2>/dev/null)"
      _wwu_now="$(date +%s)"
      if [ -n "$_wwu_beat_m" ] && [ $(( _wwu_now - _wwu_beat_m )) -lt "$_wwu_grace" ]; then watcher_up=1; fi
    fi
  fi
}

# wm_run_scoped_marker_active <file>
# True (rc 0) iff <file> exists and is honored for the CURRENT run: its
# first line matches $WINGMAN_RUN_ID, or is empty, or this session has no
# run id at all (cannot certify ownership either way, so any stamp is
# honored - the existing $stopfile precedent). False (rc 1) if absent, or
# stamped by a different, presumably-ended run. Reads only the first line,
# so this works unmodified for a marker that carries extra content after its
# stamp (see $suppressedfile below).
wm_run_scoped_marker_active() {
  _f="$1"
  [ -f "$_f" ] || return 1
  _stamp="$(head -n 1 "$_f" 2>/dev/null)"
  [ -z "${WINGMAN_RUN_ID:-}" ] || [ -z "$_stamp" ] || [ "$_stamp" = "${WINGMAN_RUN_ID:-}" ]
}

# wm_unwaited_reason <owner>
# Prints the composed "pending question with no live waiter" reason text (the
# same text hooks/stop-guard.sh has always produced), or nothing if every
# pending ask for <owner> has a live waiter. A live waiter is a pending ask
# whose ask/<req>.pid names a live pid AND whose ask/<req>.beat is fresher
# than $WM_ASK_WATCH_GRACE (default 30s) - the identical pidfile-plus-beacon
# shape wm_watcher_up uses for the watcher itself, applied per-request.
# Assumes the caller has already set $WM_HOME, $WM_UV, $STATE_PY.
wm_unwaited_reason() {
  _wur_owner="$1"
  _wur_grace="${WM_ASK_WATCH_GRACE:-30}"
  _wur_unwaited=""
  _wur_pending="$(WINGMAN_HOME="$WM_HOME" $WM_UV "$STATE_PY" ask-list --from "$_wur_owner" --status pending 2>/dev/null)"
  if [ -n "$_wur_pending" ]; then
    _wur_now="$(date +%s)"
    while IFS=$'\t' read -r req st frm to created; do
      [ -n "$req" ] || continue
      _wur_live=0
      _wur_apid_file="$WM_HOME/ask/$req.pid"
      _wur_abeat_file="$WM_HOME/ask/$req.beat"
      if [ -f "$_wur_apid_file" ] && [ -f "$_wur_abeat_file" ]; then
        _wur_apid="$(cat "$_wur_apid_file" 2>/dev/null)"
        if [ -n "$_wur_apid" ] && kill -0 "$_wur_apid" 2>/dev/null; then
          _wur_abeat_m="$($WM_UV python -c 'import os,sys;print(int(os.path.getmtime(sys.argv[1])))' "$_wur_abeat_file" 2>/dev/null)"
          if [ -n "$_wur_abeat_m" ] && [ $(( _wur_now - _wur_abeat_m )) -lt "$_wur_grace" ]; then _wur_live=1; fi
        fi
      fi
      if [ "$_wur_live" = 0 ]; then
        _wur_unwaited="$_wur_unwaited
- ask $req to $to"
      fi
    done <<EOF
$_wur_pending
EOF
  fi
  if [ -n "$_wur_unwaited" ]; then
    printf '%s' "You have a pending question with no live waiter:$_wur_unwaited
Arm 'bin/crew-ask await --id <req>' as a harness-tracked background task for each so its exit wakes you when the answer lands, then you may stop."
  fi
}
