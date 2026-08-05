#!/usr/bin/env bash
# stop-continuity.sh - a Claude Code Stop hook, asyncRewake-registered (see
# .claude/settings.json), wired only for the wingman repo. Tokenlessly
# auto-arms bin/watch-fleet when crew are in flight with no live cycle,
# accounting for whatever the previous cycle's exit actually was by running
# `bin/watch-fleet --classify` itself, with no model turn spent specifically
# on arming (issue #185).
#
# This hook's own process is the harness-tracked, long-lived thing under
# asyncRewake - never a `cmd &`-backgrounded detached child (see
# docs/architecture.md's wake-loop section for why that pattern cannot wake
# an idle session at all). It foregrounds bin/watch-fleet in a loop, one
# self-bounded window at a time, re-claiming in place across a quiet rollover
# or an unexpected watch-cycle death rather than ending the turn for either -
# until its own lifetime budget would be exceeded, the fleet empties, or
# something genuinely worth reporting happens. Only then does it either
# rewake with what happened (exit 2) or let the stop stand (exit 0). The
# lifetime budget self-clamps to this hook's own REGISTERED `timeout` (issue
# #231, see continuity_registered_timeout below) - but that is the on-disk
# value, not necessarily what THIS session's own harness is actually bound
# to (Claude Code binds hooks at session start, and the on-disk value moves
# the instant a new registration is deployed). RESTARTING every session that
# was already running when a `timeout` change lands is required, not merely
# advisable - the clamp only covers the narrower case where the on-disk
# value itself is still stale (unreadable, or a scope not yet reconciled).
# See the clamp's own comment below and docs/guards.md for the honest scope
# of what this actually protects.
#
# Recursion is NOT guarded by stop_hook_active - see the self-owned in-flight
# marker below and docs/plans/2026-08-02-issue-185-asyncrewake-autoarm-plan.md
# ("Why stop_hook_active cannot be the recursion guard") for why that would be
# wrong here specifically, even though hooks/stop-guard.sh's own pass-1/pass-2
# structure correctly relies on it for a different purpose.
# bash-3.2-safe.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
STATE_PY="$REPO/bin/lib/wm-state.py"
WM_HOME="${WINGMAN_HOME:-$HOME/.wingman}"
WM_UV="${WM_UV:-uv run --no-project --quiet}"
. "$HERE/lib/watcher-liveness.sh"

# Taken here, before any gate below, so the lifetime budget (see the
# window/lifetime block ahead of the claim loop) covers the whole invocation
# rather than only the time actually spent looping.
hook_start="$(date +%s)"

# 1. Read stdin and discard it. stop_hook_active is deliberately never read -
# not for gating (the in-flight marker below replaces that) and not for any
# other purpose.
cat >/dev/null

# No state yet (pre-onboarding) -> nothing to guard, matching stop-guard.sh's
# own fast exit.
[ -f "$STATE_PY" ] || exit 0
[ -d "$WM_HOME" ] || exit 0

# 2. Kill switch.
[ "${WM_STOP_AUTOARM:-1}" = "0" ] && exit 0

# This hook guards wingman itself, so it scopes to wingman's own layer (owner
# "" - wingman has no $WINGMAN_CREW_ID), exactly like hooks/stop-guard.sh.
OWNER="${WINGMAN_CREW_ID:-}"

# compose_attention_reason - restores incident-runbook routing (matched
# against the "## New events" reason lines specifically, longest-token-first,
# with `stalled` anchored to the bracketed status field) for a pre-claim or
# post-window `fire`/`remote-control-dropped` outcome, since this hook's own
# `auto` rewake is now the PRIMARY fire channel for wingman's top-level
# session (its own body forbids running /watch, so nothing else routes this).
compose_attention_reason() {
  _wf="$wakefile"
  _body="Crew need your attention (surfaced via automatic fleet continuity):
Read $_wf and run bin/crew-list, surface each blocker/PR to the pilot (or
answer via bin/crew-say), and give the pilot a compact roster status (who is
on what, what is blocked, what is stalled, what is ready)."
  # Only the "## New events" reason lines, not the whole wake file (which also
  # carries the full roster and every member's own summary text via fire()'s
  # crew-list dump) - a member whose summary happens to read "checking why the
  # watcher stalled" must not false-positive on `stalled`.
  _events="$(sed -n '/^## New events$/,/^## /{/^## /d;p}' "$_wf" 2>/dev/null)"
  # Seven of the eight tokens are synthetic ids or fleet-scoped reason text
  # fire() alone ever emits into this block, so a substring match against the
  # scoped section is safe for them. `stalled` is different: it is ALSO a
  # genuine English word a member's own free-text note (rendered inside the
  # same "## New events" block, as `- **<id>** [<status>] <note>`) could
  # plausibly contain - anchor that one token to the bracketed status field
  # specifically, where it can only ever appear as the genuine status enum
  # value, not as free text.
  _matched=""
  for _tok in correlated:api-outage-death correlated:mass-death \
              correlated:api-outage usage-limit-approaching \
              usage-limit-reset outage-detected outage-cleared; do
    if printf '%s\n' "$_events" | grep -q "$_tok"; then
      _matched="$_tok"
      break
    fi
  done
  if [ -z "$_matched" ] && printf '%s\n' "$_events" | grep -q '\[stalled\]'; then
    _matched="stalled"
  fi
  if [ -n "$_matched" ]; then
    _body="$_body
This wake includes a '$_matched' reason - read docs/runbooks/incidents.md and
follow its procedure before reporting anything; the generic roster report
above is the wrong response for this reason."
  fi
  printf '%s' "$_body"
}

# rewake <body> <mode>
# mode="auto": continuity is already handling re-arming on its own (rolled,
# fire, remote-control-dropped) - appends the explicit "do not run /watch, do
# not arm a watch-fleet cycle" sentence to the body itself, naming "a
# watch-fleet cycle" specifically (not the more ambiguous "a watcher") since
# an auto-mode body can also carry an appended unwaited instruction to arm a
# DIFFERENT background task (crew-ask await).
# mode="manual-remedy": automatic continuity has just demonstrated it isn't
# working, or needs a different kind of manual action - the remedy text
# already tells the model what to do; no "do not arm" sentence is appended.
# Does not itself exit - every call site writes exit 2 on the next line.
rewake() {
  _body="$1"; _mode="$2"
  if [ "$_mode" = "auto" ]; then
    _body="$_body
Fleet continuity is fully automatic for this session - do NOT run /watch and do NOT arm a watch-fleet cycle yourself in response to this. If nothing above asks for pilot action, just stop."
  fi
  printf '%s' "$_body" >&2
  printf '%s' "$_body" | $WM_UV python -c 'import sys,json; print(json.dumps({"decision":"block","reason":sys.stdin.read()}))'
}

# continuity_registered_timeout <settings_file> <command_marker>
# Prints the MINIMUM `timeout` across every Stop entry whose command contains
# <command_marker>, as a single value - never one line per match - or
# nothing if the file is missing/unparseable or carries no such entry; never
# a hard failure, just an empty result the caller folds into its own
# fallback. A single value matters: two Stop entries matching the same
# marker (e.g. absolute paths from two different checkouts of this repo)
# would otherwise hand the caller a multi-line capture, which is either a
# silent `integer expected` on stderr (if the OTHER lookup already produced
# a value) or a fatal, invocation-ending arithmetic error (if it did not) -
# print(min(...)) removes both by construction. Used by the lifetime
# self-clamp below to read this hook's own registration rather than trust
# the registration surface (four separate declaration sites - see the plan)
# to have moved in lockstep.
continuity_registered_timeout() {
  $WM_UV python -c '
import json, sys
path, marker = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path))
except Exception:
    sys.exit(0)
found = []
for entry in (d.get("hooks") or {}).get("Stop", []) or []:
    for h in entry.get("hooks") or []:
        cmd = h.get("command", "")
        t = h.get("timeout")
        if marker in cmd and isinstance(t, int):
            found.append(t)
if found:
    print(min(found))
' "$1" "$2" 2>/dev/null
}

# 3+4. Fast path: no crew in flight, or a live cycle already exists. Also
# leaves pidfile/beatfile/exitfile/runfile/wakefile/stopfile/suppressedfile/
# claimlock/inflightfile/claimfailfile set for everything below (see
# wm_owner_paths).
active_crew="$(WINGMAN_HOME="$WM_HOME" $WM_UV "$STATE_PY" crew-list --active --owner "$OWNER" --json 2>/dev/null | $WM_UV python -c 'import sys,json;
try: print(len(json.load(sys.stdin)))
except Exception: print(0)')"
wm_watcher_up "$OWNER" "$WM_HOME"
if [ "${active_crew:-0}" -eq 0 ] || [ "$watcher_up" = 1 ]; then
  exit 0
fi

window="${WM_STOP_CONTINUITY_WINDOW:-480}"
lifetime="${WM_STOP_CONTINUITY_LIFETIME:-$WM_CONTINUITY_LIFETIME_DEFAULT}"

# Self-clamp the lifetime budget against this hook's own registered
# `timeout` (issue #231). Finding 1 of the companion analysis is that a hook
# killed AT its own `timeout` has its exit code silently discarded, so
# trusting the configured lifetime blindly would go dark on exactly the
# session this exists to protect.
#
# What this clamp does NOT cover, honestly: Claude Code binds hooks at
# session start, but the value read here is the CURRENT on-disk
# registration, which moves the instant a new `timeout` is deployed - the
# same commit that ships this script. A session already running when that
# happens keeps executing the new script off disk while its own harness
# binding still kills it at the OLD timeout, and by the time its next Stop
# event runs this clamp, the on-disk value already reads the NEW (larger)
# timeout - so the clamp computes a lifetime that fits the NEW binding, not
# the OLD one it is actually still killed at, and provides no protection at
# all for that session. RESTARTING every such session is required, not
# optional; this clamp is not a substitute for it. What it DOES cover: the
# narrower window where the on-disk value itself is genuinely still stale -
# unreadable/missing, or one scope (typically crew-scope, reconciled only at
# the next spawn/resume) not yet caught up with the other.
#
# Read BOTH candidate settings files rather than choosing one by
# WINGMAN_CREW_ID: a crew session whose project root IS this repo loads both
# the project registration (stop-continuity.sh, in .claude/settings.json)
# and the user one (stop-continuity-crew.sh, in ~/.claude/settings.json),
# and either could be the stale one mid-migration - clamp to the minimum
# timeout found across whichever entries actually exist, so the result never
# depends on which registration happened to invoke this process (unknowable
# from inside the script - see hooks/stop-continuity-crew.sh's own header).
# A file that yields nothing (missing, unparseable, no matching entry)
# simply contributes nothing; if NEITHER yields a value at all, fall back to
# the historical 600 rather than the configured default - "the fix silently
# does nothing" is a far better failure than "continuity silently dies".
_continuity_project_settings="${WM_PROJECT_SETTINGS:-$REPO/.claude/settings.json}"
_continuity_user_settings="${WM_CLAUDE_USER_SETTINGS:-$HOME/.claude/settings.json}"
_registered_timeout=""
for _t in \
  "$(continuity_registered_timeout "$_continuity_project_settings" "stop-continuity.sh")" \
  "$(continuity_registered_timeout "$_continuity_user_settings" "stop-continuity-crew.sh")"; do
  [ -n "$_t" ] || continue
  if [ -z "$_registered_timeout" ] || [ "$_t" -lt "$_registered_timeout" ]; then
    _registered_timeout="$_t"
  fi
done
_lifetime_cap=$(( ${_registered_timeout:-600} - WM_CONTINUITY_TIMEOUT_MARGIN ))
[ "$lifetime" -gt "$_lifetime_cap" ] && lifetime="$_lifetime_cap"

# 5. Self-owned, time-bounded in-flight marker. Not "pid alive" alone - "pid
# alive AND recorded within $window plus a margin" - since this hook's own
# total runtime is bounded by its own referee at $window, so anything older
# than that plus a small margin (60s) cannot possibly be a live instance of
# this hook, regardless of what the pid says. Not actively cleaned up on exit
# (no rm in any trap) - the freshness bound makes that unnecessary.
inflight_pid="$(cat "$inflightfile" 2>/dev/null)"
inflight_age=999999
if [ -f "$inflightfile" ]; then
  inflight_age=$(( $(date +%s) - $($WM_UV python -c 'import os,sys;print(int(os.path.getmtime(sys.argv[1])))' "$inflightfile" 2>/dev/null || echo 0) ))
fi
if [ -n "$inflight_pid" ] && kill -0 "$inflight_pid" 2>/dev/null && [ "$inflight_age" -lt $(( window + 60 )) ]; then
  exit 0   # a genuinely concurrent instance is already managing continuity for this owner
fi
printf '%s\n' "$$" > "$inflightfile"

# 6. Persistent stop-sanction gate. Silently, every time, no rewake - the
# sanction was already reported once, synchronously, when `bin/watch-fleet
# --stop` itself ran.
wm_run_scoped_marker_active "$stopfile" && exit 0

# 7. Persistent spurious-repeated standdown gate, checked BEFORE accounting -
# not folded into accounting's own case - because accounting itself would
# otherwise keep re-deriving fresh forensics from the same stale, unattended
# residue. See hooks/stop-guard.sh's own no-watcher branch for the safety net
# that keeps this standdown from going silent while it holds. The marker
# itself is authored by `bin/watch-fleet --classify`'s own trip branch
# (issue #198), not by this hook - it exists no matter which consumer
# observed the trip (this hook, a lead's model-driven `/watch`, or a bare
# diagnostic call), so this gate catches a standdown from any of them.
wm_run_scoped_marker_active "$suppressedfile" && exit 0

# 8. Claim-failure backoff check: a rolling backoff, not a standdown - a claim
# failure may be transient, so this rate-limits automatic retry to once per
# window rather than suppressing it outright.
if [ -f "$claimfailfile" ]; then
  claimfail_age=$(( $(date +%s) - $($WM_UV python -c 'import os,sys;print(int(os.path.getmtime(sys.argv[1])))' "$claimfailfile" 2>/dev/null || echo 0) ))
  [ "$claimfail_age" -lt "$window" ] && exit 0
fi

# 9. Pre-claim accounting, guarded exactly as "nothing to classify yet": only
# proceed if $pidfile, $exitfile, or $runfile exists - otherwise there is no
# prior cycle to account for, and misclassifying "never ran" as "died" would
# falsely trip the failure budget.
if [ -f "$pidfile" ] || [ -f "$exitfile" ] || [ -f "$runfile" ]; then
  classify_out="$(WINGMAN_HOME="$WM_HOME" "$REPO/bin/watch-fleet" --classify --owner "$OWNER" 2>/dev/null)"
else
  classify_out=""
fi
case "$classify_out" in
  stopped)
    printf '%s\n' "${WINGMAN_RUN_ID:-}" > "$stopfile"
    exit 0 ;;
  spurious-repeated\ *)
    # --classify has already written $suppressedfile (the trip branch's own
    # marker write) - read it back rather than recomposing it, so the trip
    # text has exactly one author.
    _sr_reason="$(tail -n +2 "$suppressedfile" 2>/dev/null)"
    [ -n "$_sr_reason" ] || _sr_reason="$WM_STANDDOWN_FALLBACK"
    rewake "$_sr_reason" manual-remedy
    exit 2 ;;
  remote-control-dropped)
    # No crew-status row exists for this by construction (self_pane_check
    # fires independently of crew status), so hooks/stop-guard.sh's own
    # `needs-attention` check can never catch it on this same Stop event -
    # always report it here rather than silently proceeding to claim.
    rm -f "$runfile"
    rewake "$(compose_attention_reason)" auto
    exit 2 ;;
  fire)
    # #185's own reasoning (docs/plans/2026-08-02-issue-185-asyncrewake-
    # autoarm-plan.md:201) is that rewaking a pre-claim fire here would
    # double-report against hooks/stop-guard.sh's own independent
    # `needs-attention` check on the same Stop - true, and left alone, for a
    # fire that actually carries a crew-status row. But that reasoning does
    # not cover a fire whose only content is a queued notice or a
    # fleet-scoped signal (outage/usage-limit) - neither produces a
    # needs-attention row, so nothing else will ever report it, and the
    # premise the original decision leaned on for "it'll surface anyway"
    # (a fresh cycle "re-fires... within one poll") is false regardless:
    # fire() acks the event BEFORE writing the exit record
    # (bin/watch-fleet:873-875), so a fresh claim never rediscovers it.
    # Check the exact same predicate stop-guard.sh checks, so this can never
    # drift from what stop-guard.sh actually does.
    if [ -z "$(WINGMAN_HOME="$WM_HOME" $WM_UV "$STATE_PY" needs-attention --owner "$OWNER" --suppress-on handled 2>/dev/null)" ]; then
      rm -f "$runfile"
      rewake "$(compose_attention_reason)" auto
      exit 2
    fi
    ;;   # a crew-status row exists - stop-guard.sh already reports it; proceed to claim
  healthy|spurious\ *|stale-code|"")
    : ;;   # proceed to claim - nothing to absorb
  *)
    : ;;   # unrecognized output - defensively proceed to claim rather than silently stopping
esac

# 10+11. Claim, foreground, self-bounded, account for the outcome - looped in
# place (issue #231) so a quiet rollover or an unexpected watch-cycle death
# re-claims immediately instead of ending the turn. Truncated once here, then
# appended to per iteration (armlog="$WM_HOME/stop-autoarm..." stays below
# the gates above deliberately - hoisting it earlier would wipe the log on
# every gated exit, including every Stop event a spurious-repeated standdown
# holds, and that log is exactly what the standdown's own remedy text sends
# the pilot to read).
armlog="$WM_HOME/stop-autoarm${_okey:+-$_okey}.log"
: > "$armlog"

# child/referee are read by the trap below across the whole loop, so they are
# declared once, outside it, and the trap installed once too - re-installing
# it per iteration would be harmless but pointless. Left unquoted in the trap
# body (unlike the claim itself) so an iteration boundary, where both are
# momentarily "", expands to no argument rather than an empty-string one.
child=""; referee=""; term_forwarded=0
trap 'term_forwarded=1; kill -TERM $child $referee 2>/dev/null' TERM INT

while :; do
  # Refresh the in-flight marker every iteration, not just at entry: the
  # freshness bound wm_watcher_up's caller enforces is $window+60, and this
  # invocation can now live many multiples of $window - see "The concurrency
  # guard across a long lifetime" in the plan for why a stamp fixed at entry
  # would go stale mid-lifetime and let a concurrent instance in.
  printf '%s\n' "$$" > "$inflightfile"
  _body=""; _mode=""; _continue=0; _quiet=""

  # Re-claiming here is only safe because the PREVIOUS iteration's
  # --classify (below) already consumed $exitfile - bin/watch-fleet itself
  # refuses to arm over an unclassified exit record, and this iteration's own
  # referee writes "rolled" under `set -C`. A cross-file invariant with a
  # silent failure mode if --classify ever stopped consuming it.
  WINGMAN_HOME="$WM_HOME" "$REPO/bin/watch-fleet" --owner "$OWNER" >>"$armlog" 2>&1 &
  child=$!
  # The referee's own stdout/stderr are explicitly redirected to /dev/null -
  # never left to inherit this hook's own stdout, which under asyncRewake (or
  # a test capturing this hook via a pipe/command substitution) is a pipe. An
  # unredirected referee (or its own forked `sleep` child, which survives an
  # unexpected referee death since a dying parent does not take its children
  # down with it) would otherwise hold that pipe's write end open
  # indefinitely, so the reader on the other end would never see EOF - this
  # hook's own final JSON write in rewake() below would then never be
  # observed by its caller, even though the hook itself has long since
  # produced it and moved on.
  ( sleep "$window"
    ( set -C; printf 'rolled\n' > "$exitfile" ) 2>/dev/null
    kill -TERM "$child" 2>/dev/null
  ) >/dev/null 2>&1 &
  referee=$!

  wait "$child" 2>/dev/null; child_rc=$?
  exitfile_snapshot="$(cat "$exitfile" 2>/dev/null)"   # authoritative - see the plan's own rationale

  while kill -0 "$child" 2>/dev/null; do sleep 0.1; done
  kill "$referee" 2>/dev/null; wait "$referee" 2>/dev/null

  if [ -n "$exitfile_snapshot" ]; then
    printf '%s\n' "$exitfile_snapshot" > "$exitfile"
  else
    rm -f "$exitfile"
  fi

  # Captured before clearing $child/$referee, which happens immediately here
  # rather than after the accounting below that still needs $_reaped_child:
  # the trap fires on whatever $child/$referee currently name, and the gap
  # between this reap and the next iteration's spawn (the accounting, the
  # unwaited check, the budget check - all real wall-clock time) is exactly
  # where a stale pid the OS may have already recycled would otherwise be
  # targeted.
  _reaped_child="$child"
  child=""; referee=""

  # Account for the outcome. A nonzero $child_rc with no $exitfile is NOT by
  # itself proof the child never claimed - the identical pair also results
  # from a child that claimed and armed successfully, then died some other
  # way (a raw SIGKILL, an OOM kill, an unhandled crash, or a TERM/INT this
  # hook itself received and forwarded - none of which ever write
  # $exitfile). Three independent, imperfect-alone signals are combined below
  # because each one's own gap is closed by at least one of the other two:
  #
  # - $term_forwarded is set by this hook's own trap the instant an external
  #   TERM/INT reaches THIS process (see above) - a plain local fact, not
  #   evidence read back from the child's own side-effects, so it is exact
  #   regardless of how far the child itself had gotten. But $child_rc itself
  #   is NOT reliable evidence on its own once this trap has fired: the
  #   in-flight `wait` gets interrupted and returns 128+15=143 - a status
  #   reflecting that the WAIT was interrupted, not the child's own actual
  #   exit code - even on the fully ordinary path where the child's own
  #   INT/TERM trap ran cleanly (`rm -f "$PIDFILE"; exit 0`) moments later.
  # - $pidfile still naming the reaped child's own pid is exact for a child
  #   that claimed and was then SIGKILL'd (or crashed) before it could run
  #   its own cleanup trap - watch-fleet writes $pidfile unconditionally as
  #   its first act after passing the claim, before its blocking loop. But it
  #   is blind to a child that claimed and then died via its OWN clean
  #   INT/TERM trap (forwarded or not): that trap's `rm -f "$PIDFILE"` clears
  #   the one piece of evidence this check depends on, indistinguishable by
  #   content alone from "never claimed at all".
  # - $armlog containing "armed pid=<child>" is watch-fleet's own
  #   unambiguous, append-only confirmation that the claim succeeded, printed
  #   once, immediately after the claim - a claim that never got that far
  #   (still contending in the mkdir/retry loop, or wm_die's own failure
  #   text) never produces it. But there is a narrow window, between
  #   $pidfile's own write and this confirmation line a few statements later
  #   (release_claim, the beacon touch, the trap installation itself), where
  #   a SIGKILL landing inside it leaves $pidfile naming the child with no
  #   confirmation line yet - exactly the gap the $pidfile check above
  #   closes.
  #
  # None of the three is sufficient alone; together they leave no gap a
  # genuinely-armed child's own death - by any mechanism - can fall through.
  if [ ! -f "$exitfile" ] && [ "$child_rc" -ne 0 ] \
    && [ "$term_forwarded" -ne 1 ] \
    && [ "$(cat "$pidfile" 2>/dev/null)" != "$_reaped_child" ] \
    && ! grep -q "armed pid=$_reaped_child " "$armlog" 2>/dev/null; then
    touch "$claimfailfile"
    _body="Automatic watcher re-arm failed: bin/watch-fleet did not claim within the continuity window. Last output:
$(tail -n 20 "$armlog")
Investigate $claimlock and arm bin/watch-fleet manually, then you may stop."
    _mode="manual-remedy"
  else
    classify_out="$(WINGMAN_HOME="$WM_HOME" "$REPO/bin/watch-fleet" --classify --owner "$OWNER" 2>/dev/null)"
    case "$classify_out" in
      rolled)
        # Continue in place - no crew event, nothing to report yet. _mode is
        # set here even though _body stays empty, so that IF the unwaited
        # check below forces a break, the rewake carries "auto" (continuity
        # IS still re-arming) rather than the unwaited branch's own
        # "manual-remedy" default (which is only right when continuity is
        # NOT re-arming - see that check for the full reasoning).
        _continue=1; _quiet="rolled"; _mode="auto" ;;
      fire|remote-control-dropped)
        _body="$(compose_attention_reason)"
        _mode="auto" ;;
      stopped)
        printf '%s\n' "${WINGMAN_RUN_ID:-}" > "$stopfile"
        _body=""; _mode="" ;;
      healthy)
        _body=""; _mode="" ;;
      spurious-repeated\ *)
        # --classify has already written $suppressedfile (the trip branch's
        # own marker write) - read it back rather than recomposing it, so
        # the trip text has exactly one author.
        _sr_reason="$(tail -n +2 "$suppressedfile" 2>/dev/null)"
        [ -n "$_sr_reason" ] || _sr_reason="$WM_STANDDOWN_FALLBACK"
        _body="$_sr_reason"
        _mode="manual-remedy" ;;
      spurious\ *)
        # Continue in place - a deliberate behavior change (see the plan's
        # "spurious continuing is a deliberate behavior change"): a
        # watch-fleet child that died mid-window re-claims immediately rather
        # than abandoning the fleet until the model's own next natural turn.
        # Cannot spin: --classify's own consecutive-failure budget trips
        # spurious-repeated (above) on the third consecutive death.
        _continue=1; _quiet="spurious"; _mode="auto" ;;
      stale-code)
        # Continue in place, exactly like `spurious` (issue #219): the
        # cycle noticed its OWN code was stale relative to disk and exited
        # cleanly - not a failure, nothing to report. The very next claim
        # in this same loop iteration spawns a fresh process that reads
        # whatever is on disk NOW, which is what actually picks up the fix.
        _continue=1; _quiet="stale-code"; _mode="auto" ;;
      "")
        _body=""; _mode="" ;;
      *)
        _body=""; _mode="" ;;
    esac
  fi

  # Checked here - after the window, not before it - same reasoning as
  # today's single-shot version: checking pre-claim blocked the claim
  # entirely and duplicated hooks/stop-guard.sh's own report.
  _unwaited_text="$(wm_unwaited_reason "$OWNER")"   # empty if every pending ask has a live waiter
  if [ -n "$_unwaited_text" ]; then
    _continue=0
    if [ -n "$_body" ]; then
      _body="$_body

$_unwaited_text"
    else
      _body="$_unwaited_text"
      # Only defaulted when unset (see the `rolled`/`spurious` case above):
      # right for healthy/stopped, where continuity is NOT re-arming and the
      # "do NOT arm a watch-fleet cycle" sentence would be a lie; wrong for
      # rolled/spurious, where it IS re-arming and wm_unwaited_reason's own
      # remedy asks the model to arm a DIFFERENT background task
      # (bin/crew-ask await).
      [ -n "$_mode" ] || _mode="manual-remedy"
    fi
  fi

  [ "$term_forwarded" -eq 1 ] && _continue=0
  [ "$_continue" -eq 1 ] || break

  # Re-evaluate active_crew exactly as the fast path above does, BEFORE the
  # budget check below: without this, the loop would keep a cycle armed for
  # the rest of its lifetime after the last member finished, and checking it
  # after the budget instead would spend a wake announcing a rollover to a
  # session whose next invocation would exit immediately at the fast path
  # anyway.
  active_crew="$(WINGMAN_HOME="$WM_HOME" $WM_UV "$STATE_PY" crew-list --active --owner "$OWNER" --json 2>/dev/null | $WM_UV python -c 'import sys,json;
try: print(len(json.load(sys.stdin)))
except Exception: print(0)')"
  [ "${active_crew:-0}" -eq 0 ] && break

  # The lifetime budget would be exceeded by another full window - break with
  # an `auto` rewake naming what actually happened (a clean rollover, or a
  # re-arm after an unexpected watch-cycle exit - conflating the two would
  # misreport a killed child as a clean rollover). This is the one remaining
  # wake on a fully idle fleet, and it is what keeps the chain alive: only a
  # fresh Stop event can re-invoke an asyncRewake-registered hook.
  if [ $(( $(date +%s) - hook_start + window )) -gt "$lifetime" ]; then
    if [ "$_quiet" = "rolled" ]; then
      _body="Fleet continuity window rolled - no crew event yet. A fresh watch cycle is arming automatically."
    elif [ "$_quiet" = "stale-code" ]; then
      _body="Fleet continuity is re-arming to pick up an on-disk code update - nothing to report yet. A fresh watch cycle is arming automatically."
    else
      _body="Fleet continuity is re-arming after an unexpected watch-cycle exit - nothing to report yet. A fresh watch cycle is arming automatically."
    fi
    _mode="auto"
    break
  fi
done

if [ -n "$_body" ]; then
  rewake "$_body" "$_mode"
  exit 2
fi
exit 0
