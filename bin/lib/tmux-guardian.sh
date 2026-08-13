#!/usr/bin/env bash
# tmux-guardian.sh - a standalone liveness logger for the shared tmux server
# (issue #218: the wingman-main tmux server's cgroup scope has twice died with
# zero preceding journal trace - no Stopping/Stopped/Failed line, no OOM, no
# kernel fault, no deliberate stop, no reboot - taking wingman-main and every
# crew window down with it in the same instant, since all of them are just
# sessions on the one shared server socket).
#
# THIS IS NOT bin/watch-fleet AND MUST NEVER BE TREATED LIKE IT. watch-fleet's
# entire wake mechanism is a harness-tracked background task whose EXIT is
# what re-invokes an idle session - so it must never be nohup'd/setsid'd/
# backgrounded with a bare "&" (see watch-fleet's own header, and
# hooks/no-foreground-watcher-guard.sh, which enforces this). This script has
# no such constraint and inverts it on purpose: its entire job is to survive
# the exact event that kills everything else on the shared tmux server, so it
# MUST run detached from any tracked task and, more importantly, in a cgroup
# genuinely separate from the tmux server's own scope. A companion process
# that stays inside the doomed cgroup dies with it and catches nothing.
# It writes to disk only; it wakes nobody and injects no
# keystrokes anywhere, so none of watch-fleet's wake-loop rules apply to it.
#
# Launched by bin/wingman on every startup, wrapped in `systemd-run --user
# --scope --collect --quiet` when available (falling back to a plain
# detached background process otherwise) - the same runtime idiom
# bin/lib/common.sh's wm_tmux_scoped already uses everywhere in this repo.
# This is a one-off transient-unit invocation at process-launch time, not an
# installed unit file - it requires no `systemctl enable`, drops no file
# under /etc or ~/.config/systemd, and needs no installation step. Issue #250
# ruled systemd unit files/timers out of wingman's scope; this is not one.
#
# What it does: polls (default every 2s, $WM_GUARDIAN_INTERVAL) whether a
# tmux server answers at all, tracking its pid (via `tmux list-sessions -F
# '#{pid}'`, which reports the server's own pid, not a pane's). A bounded
# "last known good" heartbeat is kept (overwritten every poll, so it never
# grows); the moment the tracked pid disappears, or changes without ever
# having been seen absent (the fastest possible turnover - the 2026-08-04
# incident's own new panes appeared just 17ms after the old server's scope
# died, comfortably faster than any poll interval could straddle), a full
# forensic event is appended to a bounded events log: the last heartbeat,
# a fresh whole-system process snapshot, and - for a revival/change - the
# new pid's full ancestry chain walked via /proc, which is exactly the
# question the 2026-08-04 postmortem's open questions section could not
# answer about the mystery pid it saw (88313) that created new panes with no
# accompanying [systemd-run] session-creation line anywhere nearby.
#
# What it does NOT do: it never guesses at or fixes the root cause, never
# restarts anything, never touches the tmux server or any crew window, and
# never depends on wingman, crew, or Claude Code being alive at all - only on
# `tmux`, `ps`, and `/proc` existing, which is nearly always true regardless
# of what else on the box is broken.
#
# Usage: tmux-guardian.sh [--daemon|--stop|--status]
#   --daemon (default if no args) - run the poll loop forever. Idempotent:
#            if a live instance is already running (per its own pidfile),
#            this exits immediately rather than starting a second one - so
#            it is always safe for bin/wingman to invoke unconditionally on
#            every startup, deliberate restart or otherwise.
#   --stop   - signal a running instance to exit and wait briefly for it.
#   --status - print whether an instance is running and the most recent
#              heartbeat/event, then exit. Read-only.
#
# Linux/systemd-only, not bash-3.2-safe like most of this repo's bin/
# scripts: its entire reason to exist is a systemd-specific cgroup-teardown
# failure mode (the `systemd-run --user --scope` check bin/wingman gates on
# before ever launching this), so portability to a non-systemd host buys
# nothing. Uses GNU-only `ps --ppid`/`/proc` accordingly.
set -u
. "$(dirname "$0")/common.sh"

PIDFILE="$WM_HOME/tmux-guardian.pid"
HEARTBEAT="$WM_HOME/tmux-guardian.heartbeat"
EVENTS="$WM_HOME/tmux-guardian-events.log"
INTERVAL="${WM_GUARDIAN_INTERVAL:-2}"
# Bound the events log so a box that restarts wingman.service often (routine
# dev-workflow use, not just genuine mystery deaths) never grows this file
# without limit. Each event is a handful of lines; 4000 lines is generous
# headroom (hundreds of events) while staying trivially small on disk.
MAX_EVENT_LINES="${WM_GUARDIAN_MAX_EVENT_LINES:-4000}"

# Extra flags spliced into every tmux invocation this script makes - e.g.
# "-L wm-test-guardian-$$" so a test can point this at a private, disposable
# tmux server instead of whatever the box's real default socket holds.
# Deliberately word-split, not quoted: only ever set to a short flag list,
# never to a value containing spaces that must survive as one token.
_gd_tmux() {
  # shellcheck disable=SC2086
  tmux ${WM_GUARDIAN_TMUX_ARGS:-} "$@"
}

_gd_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# The tmux server's own pid, or empty if no server answers. #{pid} in a
# list-sessions format string is the SERVER's pid (verified directly against
# a running server: every session on one server reports the identical pid
# here), not a pane's - so this needs no session name and works whether the
# server currently hosts wingman-main, the crew session, both, or neither.
_gd_server_pid() {
  _gd_tmux list-sessions -F '#{pid}' 2>/dev/null | head -n 1
}

_gd_session_names() {
  _gd_tmux list-sessions -F '#{session_name}' 2>/dev/null | tr '\n' ',' | sed 's/,$//'
}

# Walk /proc/<pid>/status PPid upward, printing one "pid comm ppid cmdline"
# line per ancestor, until pid 1, an unreadable/gone pid, or 20 levels (a
# generous ceiling - real ancestry chains here are a handful of levels deep).
# This is the piece that answers "what created this process" directly from
# /proc rather than from a journal that (per this investigation's findings)
# cannot distinguish a clean exit from an external kill for scope units, let
# alone name what recreated one.
_gd_ancestry() {
  _ga_pid="$1"
  _ga_depth=0
  while [ -n "$_ga_pid" ] && [ "$_ga_pid" != "0" ] && [ "$_ga_depth" -lt 20 ]; do
    [ -r "/proc/$_ga_pid/status" ] || { echo "  $_ga_pid <gone before capture>"; break; }
    _ga_comm="$(sed -n 's/^Name:[[:space:]]*//p' "/proc/$_ga_pid/status" 2>/dev/null)"
    _ga_ppid="$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$_ga_pid/status" 2>/dev/null)"
    _ga_cmd="$(tr '\0' ' ' < "/proc/$_ga_pid/cmdline" 2>/dev/null)"
    echo "  $_ga_pid ($_ga_comm) ppid=$_ga_ppid: ${_ga_cmd:-<no cmdline>}"
    [ "$_ga_pid" = "1" ] && break
    _ga_pid="$_ga_ppid"
    _ga_depth=$((_ga_depth + 1))
  done
}

# Overwrite (never append) the last-known-good snapshot. Called every poll a
# server is seen, so this file is always small and always fresh - it is the
# forensic record of "what things looked like immediately before" whatever
# happens next, without needing unbounded history.
_gd_snapshot_heartbeat() {
  _hb_pid="$1"
  {
    echo "time: $(_gd_now)"
    echo "server_pid: $_hb_pid"
    echo "sessions: $(_gd_session_names)"
    if [ -r "/proc/$_hb_pid/status" ]; then
      sed -n 's/^\(VmRSS\|Threads\|PPid\):[[:space:]]*/\1: /p' "/proc/$_hb_pid/status"
    fi
    echo "children:"
    ps --ppid "$_hb_pid" -o pid,stat,etimes,comm 2>/dev/null | tail -n +2 | sed 's/^/  /'
  } > "$HEARTBEAT.tmp" 2>/dev/null && mv -f "$HEARTBEAT.tmp" "$HEARTBEAT"
}

# Append one bounded forensic event: $1 = kind (server-first-seen,
# server-died, server-revived, server-changed), $2 = human-readable one-line
# detail, $3 = optional pid to capture full /proc ancestry for. Truncates
# the log to the newest
# $MAX_EVENT_LINES lines first if it has grown past that, so this never
# grows without bound across a box's lifetime.
_gd_log_event() {
  _le_kind="$1"; _le_detail="$2"
  if [ -f "$EVENTS" ]; then
    _le_lines="$(wc -l < "$EVENTS" 2>/dev/null || echo 0)"
    if [ "${_le_lines:-0}" -gt "$MAX_EVENT_LINES" ]; then
      # A plain `tail -n` cut can land mid-record (each event is several
      # lines starting with a "=== ..." marker) - drop everything before
      # the first surviving marker too, so a reader never has to guess
      # whether a truncated-looking record at the top is real or an
      # artifact of where the line-count cutoff happened to fall.
      tail -n "$MAX_EVENT_LINES" "$EVENTS" 2>/dev/null | sed -n '/^=== /,$p' > "$EVENTS.tmp" \
        && mv -f "$EVENTS.tmp" "$EVENTS"
    fi
  fi
  {
    echo "=== $(_gd_now) $_le_kind: $_le_detail ==="
    echo "-- last known-good heartbeat --"
    [ -f "$HEARTBEAT" ] && sed 's/^/  /' "$HEARTBEAT" || echo "  (none captured yet)"
    if [ "$_le_kind" = "server-died" ] || [ "$_le_kind" = "server-changed" ]; then
      echo "-- full process snapshot at detection time --"
      ps -eo pid,ppid,pgid,stat,etimes,comm 2>/dev/null | sed 's/^/  /'
    fi
    if [ -n "${3:-}" ]; then
      echo "-- ancestry of $3 --"
      _gd_ancestry "$3"
    fi
    echo
  } >> "$EVENTS" 2>/dev/null
}

_gd_pidfile_live() {
  [ -f "$PIDFILE" ] || return 1
  _pl_pid="$(cat "$PIDFILE" 2>/dev/null)"
  [ -n "$_pl_pid" ] || return 1
  kill -0 "$_pl_pid" 2>/dev/null || return 1
  # Confirm the live pid is actually this script, not an unrelated process
  # that happens to have been assigned the same pid number since. A pidfile
  # from an instance that died without its own trap running (any signal not
  # in cmd_daemon's TERM/INT/HUP list) is never cleaned up, so without this
  # check pid reuse would eventually make this always report "already
  # running" against a process that has nothing to do with the guardian -
  # permanently and silently disabling it until something notices and
  # manually removes the stale pidfile. An unreadable/non-matching cmdline
  # is treated as "not confirmed" rather than "confirmed alive", the safer
  # direction: worst case a redundant instance briefly starts, never a
  # wedged one that can't.
  tr '\0' '\n' < "/proc/$_pl_pid/cmdline" 2>/dev/null | grep -q "tmux-guardian\.sh"
}

cmd_status() {
  if _gd_pidfile_live; then
    echo "running: pid $(cat "$PIDFILE")"
  else
    echo "not running"
  fi
  if [ -f "$HEARTBEAT" ]; then
    echo "--- last heartbeat ---"
    cat "$HEARTBEAT"
  fi
  if [ -f "$EVENTS" ]; then
    echo "--- last event ---"
    tail -n 20 "$EVENTS"
  fi
}

cmd_stop() {
  if _gd_pidfile_live; then
    _sp_pid="$(cat "$PIDFILE")"
    kill -TERM "$_sp_pid" 2>/dev/null
    _sp_i=0
    while [ "$_sp_i" -lt 50 ] && kill -0 "$_sp_pid" 2>/dev/null; do
      sleep 0.1
      _sp_i=$((_sp_i + 1))
    done
  fi
}

cmd_daemon() {
  mkdir -p "$WM_HOME" 2>/dev/null
  if _gd_pidfile_live; then
    exit 0   # another live instance already owns this WM_HOME - never duplicate
  fi
  echo $$ > "$PIDFILE" 2>/dev/null

  _gd_cleanup() {
    [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$PIDFILE" 2>/dev/null
    exit 0
  }
  # HUP is defense in depth, not the primary protection: the launcher
  # (bin/wingman) is what actually keeps this process out of the tmux
  # server's terminal session via `setsid`, so a dying pane's controlling
  # terminal never reaches this process as a HUP target in the first place.
  # This trap only matters if something upstream ever launches the daemon
  # without setsid - it should not be relied on as the sole defense.
  trap _gd_cleanup TERM INT HUP

  # $_last_pid holds the most recent pid actually seen (empty while down),
  # so a prolonged outage does not need periodic re-logging to stay
  # distinguishable from "just started" - the single server-died event
  # already describes the whole outage until something changes.
  #
  # $_ever_seen_up is distinct from "was the server down last poll": it
  # tracks whether THIS guardian instance has ever confirmed the server
  # alive, at least once. A guardian started while the server happens to
  # already be down has nothing to "revive" - calling its first-ever
  # sighting "server-revived" would misdescribe a guardian startup as a
  # recovery from a death it never actually observed.
  _last_pid=""
  _ever_seen_up=0
  while :; do
    _cur_pid="$(_gd_server_pid)"
    if [ -n "$_cur_pid" ]; then
      # Detect and log BEFORE overwriting the heartbeat: server-changed's
      # whole value is showing what the OLD (now-dead) server last looked
      # like, and _gd_log_event reads $HEARTBEAT for that. Snapshotting
      # first would overwrite it with the NEW server's own state before the
      # event ever reads it - destroying exactly the evidence a fast
      # turnover (no observed gap) is supposed to carry, silently, on every
      # such event.
      if [ -z "$_last_pid" ]; then
        if [ "$_ever_seen_up" -eq 1 ]; then
          _gd_log_event server-revived "server pid $_cur_pid answered again" "$_cur_pid"
        else
          _gd_log_event server-first-seen "guardian started, server pid $_cur_pid already up" "$_cur_pid"
        fi
      elif [ "$_cur_pid" != "$_last_pid" ]; then
        _gd_log_event server-changed "pid $_last_pid -> $_cur_pid with no observed gap (turnover faster than the ${INTERVAL}s poll interval)" "$_cur_pid"
      fi
      _gd_snapshot_heartbeat "$_cur_pid"
      _ever_seen_up=1
    else
      if [ -n "$_last_pid" ]; then
        _gd_log_event server-died "tracked pid $_last_pid no longer answers"
      fi
    fi
    _last_pid="$_cur_pid"
    sleep "$INTERVAL"
  done
}

case "${1:-}" in
  --stop) cmd_stop ;;
  --status) cmd_status ;;
  --daemon|"") cmd_daemon ;;
  *) wm_die "usage: tmux-guardian.sh [--daemon|--stop|--status]" ;;
esac
