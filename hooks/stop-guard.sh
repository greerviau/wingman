#!/usr/bin/env bash
# stop-guard.sh - a Claude Code Stop hook, wired only for the wingman repo.
# It prevents wingman ending a turn "blind": if crew need attention, or crew are
# in flight while the zero-token watcher is not running, it blocks the stop and
# tells wingman what to do. It never loops (respects stop_hook_active).
#
# Wired in .claude/settings.json of this repo, so it applies only here.
# bash-3.2-safe.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
STATE_PY="$REPO/bin/lib/wm-state.py"
WM_HOME="${WINGMAN_HOME:-$HOME/.wingman}"
# Python via uv (matches the rest of the tool); --no-project so a surrounding
# pyproject is ignored.
WM_UV="${WM_UV:-uv run --no-project --quiet}"

INPUT="$(cat)"

# Have we already blocked once this turn? (stop_hook_active). This drives the
# two-pass state machine below; it no longer just early-exits.
active="$(printf '%s' "$INPUT" | $WM_UV python -c 'import sys,json;
try: print(json.load(sys.stdin).get("stop_hook_active"))
except Exception: print("None")' 2>/dev/null)"

# No state yet (pre-onboarding) → nothing to guard (neither pass has work to do).
[ -f "$STATE_PY" ] || exit 0
[ -d "$WM_HOME" ] || exit 0

# This hook guards wingman itself, so it scopes to wingman's own layer (owner "" -
# wingman has no $WINGMAN_CREW_ID): a lead's worker is that lead's concern, watched
# by the lead's own watcher, and must not block wingman's stop.
OWNER="${WINGMAN_CREW_ID:-}"

# Per-turn scratch set (Fix A / #8): the exact (id, updated) events this turn's
# block enumerated, TSV "id<TAB>updated" per line. Keyed by owner like the
# wake/pid files so wingman's hook and a lead's hook never collide.
if [ -n "$OWNER" ]; then
  _okey="$(printf '%s' "$OWNER" | tr -c 'A-Za-z0-9._-' '_')"
  SCRATCH="$WM_HOME/stop-blocked-$_okey.json"
else
  SCRATCH="$WM_HOME/stop-blocked.json"
fi

# --- pass 2: we already blocked once this turn. Mark EXACTLY the scratch set as
# handled - so those events stop suppressing a future block only once fully handled
# - delete the scratch, and allow the stop. Reading the set from the scratch file,
# not re-deriving it from the stores at allow-time, is what keeps a mid-turn new
# transition (or a mid-turn watcher ack) from being marked handled and dropped (#8):
# such an event was never in the scratch, so it re-blocks on the next turn.
if [ "$active" = "True" ]; then
  if [ -f "$SCRATCH" ]; then
    while IFS=$'\t' read -r _hid _hupd; do
      [ -n "$_hid" ] && WINGMAN_HOME="$WM_HOME" $WM_UV "$STATE_PY" mark-handled --id "$_hid" --updated "$_hupd" >/dev/null 2>&1
    done < "$SCRATCH"
    rm -f "$SCRATCH"
  fi
  exit 0
fi

# --- pass 1: first stop attempt this turn. --suppress-on handled keeps an
# acked-but-unhandled event visible here, so every surfaced event blocks once
# (guaranteeing the roster report) before the owner may stop.
attention="$(WINGMAN_HOME="$WM_HOME" $WM_UV "$STATE_PY" needs-attention --owner "$OWNER" --suppress-on handled 2>/dev/null)"
active_crew="$(WINGMAN_HOME="$WM_HOME" $WM_UV "$STATE_PY" crew-list --active --owner "$OWNER" --json 2>/dev/null | $WM_UV python -c 'import sys,json;
try: print(len(json.load(sys.stdin)))
except Exception: print(0)')"

# Is a watcher cycle live? A cycle is live iff its pid is alive AND its beacon is
# fresh - a blocking watcher touches the beacon every loop, so a crashed one goes
# stale within the grace even if a stale pidfile lingers.
watcher_up=0
pidfile="$WM_HOME/watch.pid"
beatfile="$WM_HOME/watch.beat"
grace="${WM_WATCH_GRACE:-30}"
if [ -f "$pidfile" ] && [ -f "$beatfile" ]; then
  pid="$(cat "$pidfile" 2>/dev/null)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    beat_m="$($WM_UV python -c 'import os,sys;print(int(os.path.getmtime(sys.argv[1])))' "$beatfile" 2>/dev/null)"
    now_s="$(date +%s)"
    if [ -n "$beat_m" ] && [ $(( now_s - beat_m )) -lt "$grace" ]; then watcher_up=1; fi
  fi
fi

# A pending ask with no live `await` waiter is the same failure shape as crew in
# flight with no watcher: the caller asked, did not arm the wait, and would sleep
# forever with the answer never waking it. Compute this layer's pending asks and
# flag any that have no live waiter (its ask/<req>.pid names a live pid AND its
# ask/<req>.beat is fresh within the grace - the same beacon-freshness test used
# for the watcher above).
ask_grace="${WM_ASK_WATCH_GRACE:-30}"
unwaited=""
pending_asks="$(WINGMAN_HOME="$WM_HOME" $WM_UV "$STATE_PY" ask-list --from "$OWNER" --status pending 2>/dev/null)"
if [ -n "$pending_asks" ]; then
  now_s="$(date +%s)"
  while IFS=$'\t' read -r req st frm to created; do
    [ -n "$req" ] || continue
    live=0
    apid_file="$WM_HOME/ask/$req.pid"
    abeat_file="$WM_HOME/ask/$req.beat"
    if [ -f "$apid_file" ] && [ -f "$abeat_file" ]; then
      apid="$(cat "$apid_file" 2>/dev/null)"
      if [ -n "$apid" ] && kill -0 "$apid" 2>/dev/null; then
        abeat_m="$($WM_UV python -c 'import os,sys;print(int(os.path.getmtime(sys.argv[1])))' "$abeat_file" 2>/dev/null)"
        if [ -n "$abeat_m" ] && [ $(( now_s - abeat_m )) -lt "$ask_grace" ]; then live=1; fi
      fi
    fi
    if [ "$live" = 0 ]; then
      unwaited="$unwaited
- ask $req to $to"
    fi
  done <<EOF
$pending_asks
EOF
fi

reason=""
if [ -n "$attention" ]; then
  # Record EXACTLY this turn's enumerated events as the scratch set, and ack each
  # (idempotent) so a freshly-armed watcher cycle will not also re-fire them. Do NOT
  # mark handled yet - pass 2 does that, only for this captured set. The watcher and
  # this hook share the one ack store (its writes are flock-serialized), so an event
  # shown by either channel does not re-fire until the crew's status changes.
  # needs-attention emits tab-separated "id status updated note".
  : > "$SCRATCH"
  printf '%s\n' "$attention" | while IFS=$'\t' read -r id st upd note; do
    [ -n "$id" ] || continue
    printf '%s\t%s\n' "$id" "$upd" >> "$SCRATCH"
    WINGMAN_HOME="$WM_HOME" $WM_UV "$STATE_PY" ack --id "$id" --updated "$upd" >/dev/null 2>&1
  done
  list="$(printf '%s\n' "$attention" | while IFS=$'\t' read -r id st upd note; do
    [ -n "$id" ] && printf -- '- %s [%s] %s\n' "$id" "$st" "$note"
  done)"
  reason="Crew need your attention before you go idle:
$list
Read $WM_HOME/wake and run bin/crew-list, surface each blocker/PR to the pilot (or
answer via bin/crew-say), and give the pilot a compact roster status (who is on what,
what is blocked, what is stalled, what is ready), then you may stop."
else
  # Nothing unhandled this turn → discard any stale scratch from a prior turn, then
  # fall through to the no-waiter / no-watcher guards.
  rm -f "$SCRATCH"
  if [ -n "$unwaited" ]; then
    reason="You have a pending question with no live waiter:$unwaited
Arm 'bin/crew-ask await --id <req>' as a harness-tracked background task for each so its exit wakes you when the answer lands, then you may stop."
  elif [ "${active_crew:-0}" -gt 0 ] && [ "$watcher_up" = 0 ]; then
    reason="You have crew in flight but no live watcher cycle. Arm one by running 'bin/watch-fleet' as a harness-tracked background task so its exit wakes you when crew need you, then you may stop."
  fi
fi

if [ -n "$reason" ]; then
  printf '%s' "$reason" | $WM_UV python -c 'import sys,json; print(json.dumps({"decision":"block","reason":sys.stdin.read()}))'
  exit 0
fi

exit 0
