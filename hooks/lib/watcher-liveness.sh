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

# wm_harness_process_identity only - deliberately NOT bin/lib/common.sh: both
# callers of this file (hooks/stop-guard.sh, hooks/stop-continuity.sh) avoid
# sourcing common.sh themselves (its own config.local.toml load is a real
# `uv run` subprocess on any machine that has one), so this file does not
# reach for it either. Self-derives its own path via BASH_SOURCE rather than
# assuming a caller-set $REPO, since neither current caller defines one under
# that exact name.
# Tolerates a partial/broken install - see hooks/pilot-preferences-guard.sh's
# identical-purpose line for why.
_wlv_hi="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/bin/lib/harness-identity.sh"
[ -r "$_wlv_hi" ] && . "$_wlv_hi"
unset _wlv_hi

# The run id every marker/kill-stamp predicate below compares against:
# $WINGMAN_RUN_ID when genuinely set (a settable override), else the
# harness-agnostic computed identity (docs/analysis/2026-08-18-remove-bin-
# wingman-launcher-spec.md, §4.3) - the same substitution bin/watch-fleet's
# own $RUNFILE stamping makes. Computed once, at source time (both callers
# source this file once per hook invocation, and this process's own ancestry
# never changes mid-invocation), rather than re-walking the process tree on
# every predicate call.
WM_EFFECTIVE_RUN_ID="${WINGMAN_RUN_ID:-}"
# 2>/dev/null guards "command not found" only - see hooks/pilot-
# preferences-guard.sh's identical block for why.
[ -n "$WM_EFFECTIVE_RUN_ID" ] || WM_EFFECTIVE_RUN_ID="$(wm_harness_process_identity 2>/dev/null)" || WM_EFFECTIVE_RUN_ID=""

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
: "${WM_STANDDOWN_FALLBACK:=Fleet supervision is standing down after repeated watch-fleet deaths for this session (see ${WM_HOME:-}/watch-spurious.log); supervision is not being maintained. Report this to the pilot and stop. Do NOT arm a watch-fleet cycle and do NOT run /watch in response - lifting the standdown is up to the pilot, via 'bin/watch-fleet --clear-standdown' (or a fresh run).}"

# WM_STANDDOWN_TAG marks a crew-set --blocker value as the standdown's own
# (issue #331), distinguishing it from an ordinary blocked question at a
# glance - wm_assert_standdown_blocked below and bin/watch-fleet's own
# --clear-standdown restore-check both key off this same prefix. Must stay
# byte-identical to bin/watch-fleet's own copy (duplicated, not sourced - see
# wm_owner_paths' own header above for why that duplication between these two
# files is already accepted).
: "${WM_STANDDOWN_TAG:=watch-fleet-standdown:}"

# wm_owner_paths <owner> <wm_home>
# Derives the owner key once and sets every owner-keyed path both hooks (and
# bin/watch-fleet's own per-owner block, re-derived independently there - see
# the plan's "known, accepted duplication" note) reference: pidfile, beatfile,
# exitfile, runfile, stopfile, claimlock, wakefile, inflightfile,
# suppressedfile, claimfailfile, killstampfile, ownerlock, ownercheckfile.
# Owner "" (wingman's own top-level scope) keeps the legacy unscoped names,
# matching bin/watch-fleet exactly.
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
    ownercheckfile="$_wop_home/watch-$_okey.ownercheck"
  else
    pidfile="$_wop_home/watch.pid"
    beatfile="$_wop_home/watch.beat"
    exitfile="$_wop_home/watch-exit"
    runfile="$_wop_home/watch.run"
    wakefile="$_wop_home/wake"
    stopfile="$_wop_home/watch.stopped"
    suppressedfile="$_wop_home/watch.suppressed"
    ownercheckfile="$_wop_home/watch.ownercheck"
  fi
  claimlock="$pidfile.lock"
  # Run-id stamp on line 1 (empty for a run-id-less session), pid on line 2 -
  # the same two-line shape $killstampfile/$stopfile already use, so its own
  # kill-evidence read can be run-scoped and freshness-bound like theirs
  # (issue #278; see hooks/stop-continuity.sh's own header comment).
  inflightfile="$_wop_home/stop-continuity${_okey:+-$_okey}.pid"
  claimfailfile="$_wop_home/stop-continuity${_okey:+-$_okey}.claimfail"
  killstampfile="$_wop_home/stop-continuity${_okey:+-$_okey}.killstamp"
  ownerlock="$pidfile.owner"
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

# wm_pr_watch_up <crew_id> <wm_home>
# Sets pr_watch_up=1 iff a bin/pr-watch cycle is live for <crew_id>: its own
# pidfile ($wm_home/pr-watch-<ckey>.pid) names a live pid AND its own beacon
# ($wm_home/pr-watch-<ckey>.beat) is fresher than WM_PR_WATCH_GRACE (default
# 90s) - reused unmodified from bin/pr-watch's own singleton-guard constant,
# not a second, independently-tunable grace: one value is the single source
# of truth for "how stale can a pr-watch beacon be", so this check and
# pr-watch's own guard can never disagree about liveness (issue #319).
# Structurally mirrors wm_watcher_up above, but does NOT piggyback on
# wm_owner_paths - <crew_id> is a crew id, not an owner scope, and the ckey
# sanitization is duplicated here rather than factored into a shared helper,
# matching this file's own header comment on wm_owner_paths (duplication at
# each call site is the accepted precedent, not something to consolidate for
# one more caller). Does not set any path variable in the caller's scope.
wm_pr_watch_up() {
  _wpu_cid="$1"; _wpu_home="$2"
  pr_watch_up=0
  [ -n "$_wpu_cid" ] || return 0
  _wpu_ckey="$(printf '%s' "$_wpu_cid" | tr -c 'A-Za-z0-9._-' '_')"
  _wpu_pidfile="$_wpu_home/pr-watch-$_wpu_ckey.pid"
  _wpu_beatfile="$_wpu_home/pr-watch-$_wpu_ckey.beat"
  _wpu_grace="${WM_PR_WATCH_GRACE:-90}"
  if [ -f "$_wpu_pidfile" ] && [ -f "$_wpu_beatfile" ]; then
    _wpu_pid="$(cat "$_wpu_pidfile" 2>/dev/null)"
    if [ -n "$_wpu_pid" ] && kill -0 "$_wpu_pid" 2>/dev/null; then
      _wpu_beat_m="$($WM_UV python -c 'import os,sys;print(int(os.path.getmtime(sys.argv[1])))' "$_wpu_beatfile" 2>/dev/null)"
      _wpu_now="$(date +%s)"
      if [ -n "$_wpu_beat_m" ] && [ $(( _wpu_now - _wpu_beat_m )) -lt "$_wpu_grace" ]; then pr_watch_up=1; fi
    fi
  fi
}

# wm_run_scoped_stamp_active <stamp>
# The comparison half of wm_run_scoped_marker_active, split out for a caller
# that must read a marker's stamp BEFORE the marker itself is overwritten
# (hooks/stop-continuity.sh's own in-flight-marker kill-evidence read claims
# the file for itself a few lines after capturing this value - see issue
# #278). True (rc 0) iff <stamp> matches $WM_EFFECTIVE_RUN_ID (this session's
# own $WINGMAN_RUN_ID when genuinely exported, else the harness-agnostic
# computed identity - see that variable's own comment near the top of this
# file), or either side is empty (cannot certify ownership either way, so any
# stamp is honored - the existing $stopfile precedent). Deliberately compares
# against $WM_EFFECTIVE_RUN_ID, never a bare $WINGMAN_RUN_ID: an unset
# WINGMAN_RUN_ID used to make this predicate unconditionally true for EVERY
# stamp, including a genuinely different, still-live run's own real one - the
# defect this fixes (docs/analysis/2026-08-18-remove-bin-wingman-launcher-
# spec.md, §2).
wm_run_scoped_stamp_active() {
  _stamp="$1"
  [ -z "$WM_EFFECTIVE_RUN_ID" ] || [ -z "$_stamp" ] || [ "$_stamp" = "$WM_EFFECTIVE_RUN_ID" ]
}

# wm_run_scoped_marker_active <file>
# True (rc 0) iff <file> exists and is honored for the CURRENT run: its
# first line matches $WM_EFFECTIVE_RUN_ID, or is empty, or this session has
# no run id at all (cannot certify ownership either way, so any stamp is
# honored - the existing $stopfile precedent). False (rc 1) if absent, or
# stamped by a different, presumably-ended run. Reads only the first line,
# so this works unmodified for a marker that carries extra content after its
# stamp (see $suppressedfile below). stop-continuity.sh's own in-flight
# marker read cannot use this directly - see wm_run_scoped_stamp_active above.
wm_run_scoped_marker_active() {
  _f="$1"
  [ -f "$_f" ] || return 1
  wm_run_scoped_stamp_active "$(head -n 1 "$_f" 2>/dev/null)"
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

# wm_assert_standdown_blocked <owner> <suppressedfile>
# Mechanically (re-)asserts <owner>'s crew-set status as `blocked`, with a
# $WM_STANDDOWN_TAG-prefixed blocker, while a spurious-repeated standdown
# marker holds (issue #331) - the observability half of #198's refusal to
# re-arm. Without this, the affected session's OWN next self-report (e.g.
# "--status working ... not re-arming") silently reverts the mechanical flip
# bin/watch-fleet's trip branch made, and the standdown goes invisible to
# needs-attention again until something restores it. Call this from every
# Stop-hook branch that already gates on
# wm_run_scoped_marker_active "$suppressedfile" (stop-continuity.sh's own
# persistent gate, stop-guard.sh's own no-watcher marker-active branch) - it
# must run every such Stop event for as long as the marker holds, mirroring
# hooks/no-foreground-watcher-guard.sh's own posture of enforcing the refusal
# continuously rather than once.
#
# No-op if <owner> is empty (wingman's own top-level session has no crew
# record of itself - a human watches that pane directly, nothing crew-set-
# watches owner "") or <suppressedfile> is unreadable.
#
# Never writes unconditionally. bin/lib/wm-state.py's cmd_crew_set bumps
# `announced` (needs-attention's own dedup key) on EVERY non-silent `blocked`
# call, whether or not the blocker text actually changed - verified directly
# against the current implementation: the same-pointer "don't re-announce"
# suppression is `review`-only by explicit design; `blocked`/`done` are
# unconditionally treated as genuine because --silent is already forbidden
# for them, so cmd_crew_set has no notion of a redundant `blocked` refresh.
# Calling this unconditionally on every Stop event the marker holds would
# therefore re-bump `announced` every time, defeating needs-attention's
# ack/handled dedup (keyed on exact (id, announced)) and re-surfacing the
# SAME standdown as a brand-new event on every poll - a wake-storm on the
# very state this fix exists to make visible ONCE, not repeatedly. So: read
# the current record first via `crew-get`, and skip the write entirely when
# it is already `blocked` with a blocker that already starts with
# $WM_STANDDOWN_TAG - a PREFIX check, not full equality, because a lead with
# its own parked items (#203) has this composed lead-in appended with
# " | parked: ..." by cmd_crew_set itself, which must not be mistaken for
# drift. Nothing else in this codebase ever writes a blocker starting with
# this tag, so the prefix alone is conclusive. Only a genuine drift (a
# different status, or a blocker that lost the tag - e.g. the affected
# session's own "--status working" self-report) triggers a write, and THAT
# write's own fresh `announced` is exactly correct: a standdown resurfacing
# after being clobbered is a legitimately new, attention-worthy event.
wm_assert_standdown_blocked() {
  _wasb_owner="$1"; _wasb_file="$2"
  [ -n "$_wasb_owner" ] || return 0
  _wasb_already="$(WINGMAN_HOME="$WM_HOME" $WM_UV "$STATE_PY" crew-get --id "$_wasb_owner" 2>/dev/null \
    | $WM_UV python -c '
import json, sys
tag = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print("1" if d.get("status") == "blocked" and (d.get("blocker") or "").startswith(tag) else "0")
' "$WM_STANDDOWN_TAG" 2>/dev/null)"
  [ "$_wasb_already" = "1" ] && return 0
  _wasb_body="$(tail -n +2 "$_wasb_file" 2>/dev/null)"
  [ -n "$_wasb_body" ] || _wasb_body="$WM_STANDDOWN_FALLBACK"
  _wasb_blocker="$WM_STANDDOWN_TAG fleet supervision for this session is standing down after repeated watch-fleet deaths - not an ordinary blocker; do NOT tell this session to just re-arm, that is denied outright while the standdown holds. Run 'bin/watch-fleet --clear-standdown' once the cause is understood. Full detail: $_wasb_body"
  WINGMAN_HOME="$WM_HOME" $WM_UV "$STATE_PY" crew-set --id "$_wasb_owner" --status blocked \
    --blocker "$_wasb_blocker" >/dev/null 2>&1
}
