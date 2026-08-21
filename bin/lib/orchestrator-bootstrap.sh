#!/usr/bin/env bash
# orchestrator-bootstrap.sh - the harness-agnostic replacement for the work
# bin/wingman used to do before exec'ing into the resolved CLI (docs/analysis/
# 2026-08-18-remove-bin-wingman-launcher-spec.md, §4.5, §8 steps 6-7): guard-
# transport reconcile+self-test, self-pane registration, tmux-guardian launch,
# a checkout-freshness advisory, and the continuity-transport notice (§4.6).
#
# There is no launcher anymore, so nothing execs into a resolved CLI and
# nothing can export a variable into an already-running harness process
# (§4.2). This script is instead invoked AFTER the harness is already
# running, from whichever entry point that harness offers:
#   - claude:                   hooks/session-init.sh (SessionStart, eager,
#                                every trigger) and hooks/orchestrator-guard-
#                                sync-gate.sh (PreToolUse, cache-gated).
#   - codex/grok/opencode/pi:   hooks/lib/guard_dispatch.py, as a lazy,
#                                cache-gated first step before guard
#                                evaluation (§4.5's "closest available
#                                equivalent of bin/wingman's own pre-first-
#                                action gate").
#
# ALWAYS runs the full bootstrap when invoked directly - it has no internal
# caching of its own. The lazy, once-per-process-identity gating described in
# §4.5 is the CALLER's job (both entry points check the per-identity status
# files this script writes, below, before ever invoking it) - keeping the
# caching decision in the caller means a caller that wants an eager,
# always-fresh run (session-init.sh) and a caller that wants a cheap,
# cached read (orchestrator-guard-sync-gate.sh / guard_dispatch.py) can both
# be correct without this script needing to know which kind of caller it is.
#
# Usage:
#   orchestrator-bootstrap.sh --agent <name> [--repo <path>]
#
# <name> is one of the descriptor names under bin/lib/agents/ (claude, codex,
# grok, opencode, pi). --repo defaults to the repo this script itself lives
# in (bin/lib/common.sh's own $WM_REPO) - always correct for the orchestrator's
# own bootstrap, since the orchestrator always runs from inside its own
# checkout (the acceptance bar this whole migration is built around: clone,
# cd in, run your harness).
#
# Exit status: 0 - the one gating condition (guard-transport reconcile+self-
#                   test) passed. Every other step (self-pane, tmux-guardian,
#                   freshness advisory, continuity notice) is best-effort and
#                   never affects this, matching bin/wingman's own posture for
#                   those exact steps.
#              1 - the guard-transport reconcile+self-test failed; nothing
#                   past that step ran. The reason is on stdout AND already
#                   written to the per-identity .reason file (see below).
#              2 - usage error (bad/missing --agent).
#
# Per-identity status files (bin/lib/harness-identity.sh's
# wm_harness_process_identity, or $WINGMAN_RUN_ID when a caller has already
# resolved one via $WM_EFFECTIVE_RUN_ID and passed it through), under
# $WINGMAN_HOME/orchestrator-bootstrap/:
#   <identity>.outcome  - "pass" or "fail", one line. The cache callers check
#                          before ever invoking this script again for the
#                          same identity.
#   <identity>.reason   - present only when outcome is "fail": the guard-
#                          transport error plus the literal retry command
#                          (re-running this exact script) a denial should
#                          allowlist and quote verbatim.
#   <identity>.notice   - present only when there is a one-time, non-blocking
#                          notice to surface (the continuity-transport gap,
#                          §4.6; a stale-checkout advisory). A caller that
#                          surfaces it (denies once, worded as a pass-through
#                          notice rather than a problem, or - for claude -
#                          folds it into SessionStart's additionalContext)
#                          deletes this file afterward so it fires exactly
#                          once per identity, never again for the same live
#                          process. Absent entirely when there is nothing to
#                          say - a caller that ignores it every time never
#                          malfunctions, only under-informs.
# Written atomically (temp file + rename) so a reader never observes a
# half-written file.
#
# No identity resolvable at all (no $WINGMAN_RUN_ID override, no recognizable
# harness ancestor within bin/lib/harness-identity.sh's own bounded walk):
# every existing identity-gated guard in this codebase treats that as "nothing
# to gate" (fail open), and this script does the same - it still runs the
# full bootstrap (there is no cache key to skip it under), but writes nothing
# to disk, since there is no identity to file it under. A caller that finds no
# identity of its own should skip the whole bootstrap gate rather than call
# this script at all, matching hooks/pilot-preferences-guard.sh's own
# `[ -n "$WM_RUN_ID" ] || exit 0` precedent.
#
# bash-3.2-safe: no associative arrays, no ${x,,}.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$HERE/common.sh"
. "$HERE/agent.sh"
. "$HERE/guard-transport.sh"
. "$HERE/harness-identity.sh"

WM_OB_AGENT=""
WM_OB_REPO="$WM_REPO"
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) WM_OB_AGENT="${2:-}"; shift 2 ;;
    --repo)  WM_OB_REPO="${2:-}"; shift 2 ;;
    *) printf 'usage: orchestrator-bootstrap.sh --agent <name> [--repo <path>]\n' >&2; exit 2 ;;
  esac
done
[ -n "$WM_OB_AGENT" ] || { printf 'usage: orchestrator-bootstrap.sh --agent <name> [--repo <path>]\n' >&2; exit 2; }

wm_agent_resolve "$WM_OB_AGENT"

# The identity this run's status files are filed under: a caller that has
# already resolved one at its own shallow depth (guard_dispatch.py,
# hooks/no-foreground-watcher-guard.sh's own convention) passes it through
# WM_EFFECTIVE_RUN_ID; $WINGMAN_RUN_ID is the settable override test fixtures
# use; otherwise this script resolves it itself.
WM_OB_ID="${WM_EFFECTIVE_RUN_ID:-}"
if [ -z "$WM_OB_ID" ]; then
  WM_OB_ID="${WINGMAN_RUN_ID:-}"
fi
if [ -z "$WM_OB_ID" ]; then
  WM_OB_ID="$(wm_harness_process_identity 2>/dev/null)" || WM_OB_ID=""
fi

WM_OB_STATUS_DIR="$WM_HOME/orchestrator-bootstrap"
WM_OB_OUTCOME_FILE=""
WM_OB_REASON_FILE=""
WM_OB_NOTICE_FILE=""
if [ -n "$WM_OB_ID" ]; then
  mkdir -p "$WM_OB_STATUS_DIR" 2>/dev/null
  WM_OB_OUTCOME_FILE="$WM_OB_STATUS_DIR/$WM_OB_ID.outcome"
  WM_OB_REASON_FILE="$WM_OB_STATUS_DIR/$WM_OB_ID.reason"
  WM_OB_NOTICE_FILE="$WM_OB_STATUS_DIR/$WM_OB_ID.notice"
fi

# _wm_ob_write <path> - writes stdin to <path> atomically (temp file in the
# same directory, then rename - rename is atomic on the same filesystem, so a
# concurrent reader never observes a truncated/partial file). A no-op when
# <path> is empty (no identity resolved - see header comment).
_wm_ob_write() {
  [ -n "$1" ] || return 0
  _wow_tmp="$1.tmp.$$"
  cat > "$_wow_tmp"
  mv -f "$_wow_tmp" "$1"
  unset _wow_tmp
}

# --- 1. guard-transport reconcile + self-test (§4.5) - the one gating step -
_gt_err="$(wm_guard_transport_sync "$WM_AGENT_GUARD_TRANSPORT" "$WM_OB_REPO")"
_gt_rc=$?

# --- 1a. pi's own persistent-install step, orchestrator-only ----------------
# Every OTHER transport's own reconcile (bin/lib/guard-transport.sh) already
# writes a persistent, user-scope registration that a later BARE launch of
# that CLI picks up automatically with no flag at all (codex's hooks.json,
# grok's hooks/wingman.json, opencode's rendered plugin file). pi's own
# reconcile deliberately does not (bin/lib/guard-transport.sh's own
# _wm_gt_sync_pi comment: "Install: none... nothing written outside the
# repo") - crew's own launch line (bin/spawn-crew) always composes the
# `-e <path> --no-extensions` flag explicitly, so pi crew never needed a
# persistent install. The ORCHESTRATOR's own bare launch has no launch line
# at all (nothing composes ANY flag for it - that is the entire premise of
# this migration), so without a persistent install a bare `pi` invocation
# would never load the guard extension, ever again, for any session, on any
# machine - guard_dispatch.py would simply never be invoked as pi's own
# PreToolUse-equivalent hook, and this whole bootstrap mechanism would be
# permanently unreachable for pi specifically.
#
# `pi install <path>` (confirmed live, 2026-08-21, against real pi v0.84.1
# with a fake $HOME): registers the given path in $HOME/.pi/agent/settings.json
# (user scope, like every other transport's own install) and a later BARE
# `pi` launch - no -e flag, no --no-extensions - auto-discovers and loads it,
# confirmed via `--wingman-guard-active` appearing in `pi --offline --help`
# with zero extension-related flags on the command line. Idempotent
# (confirmed live: a second install of the identical path does not duplicate
# the settings entry) and local-only (a `./local/path` source, no network
# fetch), so paying this on every bootstrap success costs nothing measurable
# and never touches the network. `--no-approve` (bare boolean, no value)
# skips pi's own project-trust prompt for this one command - safe here
# because it operates on pi's OWN user-scope settings file, never on
# project-local resources.
if [ "$_gt_rc" -eq 0 ] && [ "$WM_OB_AGENT" = pi ]; then
  _pi_ext="$WM_OB_REPO/bin/lib/agents/pi/wingman-guard-extension.js"
  _pi_bin="${WM_AGENT_BIN:-pi}"
  if ! _pi_err="$("$_pi_bin" install "$_pi_ext" --no-approve 2>&1)"; then
    _gt_err="pi-extension: could not persistently install the guard extension so a future bare 'pi' launch (no -e flag) would auto-load it - a bare pi orchestrator session would otherwise never enforce guards at all. '$_pi_bin install $_pi_ext --no-approve' failed: $_pi_err"
    _gt_rc=1
  fi
  unset _pi_ext _pi_bin _pi_err
fi

# --- 1b. grok's own REAL process environment, not just the descriptor field
# ($WM_AGENT_GUARD_ENV) bin/lib/guard-transport.sh's _wm_gt_sync_grok already
# checks. That check is correct for bin/wingman's own old design, where the
# field was a PROMISE about what wm_agent_apply_guard_env was about to export
# right before exec - a promise bin/wingman itself kept. With no launcher,
# nothing ever execs grok on wingman's behalf: a bare `grok` in the operator's
# own shell inherits whatever THAT shell already has, and this script - a
# descendant of the live grok process - inherits the same real environment
# grok itself is running under. Without GROK_CLAUDE_HOOKS_ENABLED=0 genuinely
# exported BEFORE grok started, grok's own Claude-compatibility path can
# silently read this repo's checked-in .claude/settings.json and allow every
# tool call without ever reaching guard_dispatch.py at all - exactly the
# hazard bin/lib/agents/grok.sh's own header names, unreachable in practice
# until now (bin/wingman's old continuity gate made every grok orchestrator
# launch dead code, so this was never live-checked before). No hook running
# after grok has already started can inject an env var into it - this is a
# genuine precondition on the OPERATOR's own shell, not something any
# reconcile step here can fix, so it fails with an actionable remedy instead.
if [ "$_gt_rc" -eq 0 ] && [ "$WM_OB_AGENT" = grok ] && [ "${GROK_CLAUDE_HOOKS_ENABLED:-}" != "0" ]; then
  _gt_err="grok's Claude-compatibility path is not suppressed in this session's OWN process environment: GROK_CLAUDE_HOOKS_ENABLED is '${GROK_CLAUDE_HOOKS_ENABLED:-<unset>}', not '0'. Without it, grok can silently read this repo's .claude/settings.json and allow every tool call without ever reaching wingman's guard dispatcher - a real, live hazard now that a bare grok orchestrator launch is possible, not merely a theoretical one. This must be exported BEFORE grok starts, since nothing running after the fact can inject it into an already-running process: exit this session, run 'export GROK_CLAUDE_HOOKS_ENABLED=0' in your shell, then start grok again."
  _gt_rc=1
fi

if [ "$_gt_rc" -ne 0 ]; then
  wm_launch_failure "orchestrator bootstrap: guard transport ($WM_OB_AGENT)" "$_gt_err"
  # A bare, direct invocation - no `uv run` wrapper (this is a bash script,
  # not one of the PEP-723 python scripts $WM_UV/uv run exists for) - so it
  # resolves in hooks/lib/cmd_match.py's own terms to exactly one basename,
  # "orchestrator-bootstrap.sh", with no interpreter-unwrap step to get
  # wrong. The callers that allowlist this exact retry shape (hooks/lib/
  # guard_dispatch.py, hooks/orchestrator-guard-sync-gate.sh) match on that
  # same basename - keep this shape and that allowlist in sync.
  _reason="could not wire wingman's guard hooks for '$WM_AGENT_DISPLAY_NAME' (guard transport '$WM_AGENT_GUARD_TRANSPORT'): $_gt_err
Fix the reported problem, then retry with:
  $HERE/orchestrator-bootstrap.sh --agent $WM_OB_AGENT --repo $WM_OB_REPO
(or run 'bin/doctor -y' first if this is the claude-json transport). This failure was also recorded in $WM_HOME/last-launch-failure."
  printf '%s' "$_reason"
  printf '%s' "$_reason" | _wm_ob_write "$WM_OB_REASON_FILE"
  printf 'fail\n' | _wm_ob_write "$WM_OB_OUTCOME_FILE"
  # A failed bootstrap has nothing to notice about yet (fix the gate first,
  # then the next successful run computes a fresh notice) - clear any stale
  # notice from an earlier, since-superseded successful run rather than
  # leaving it to fire alongside an unrelated later success.
  [ -n "$WM_OB_NOTICE_FILE" ] && rm -f "$WM_OB_NOTICE_FILE"
  unset _gt_err _gt_rc _reason
  exit 1
fi
unset _gt_err _gt_rc

# --- 2. self-pane registration (best-effort, never gates) -------------------
# Registers this pane for watch-fleet's Remote-Control drop watch only when
# the resolved adapter sets WM_AGENT_REMOTE_CONTROL_FLAG (claude today);
# clears any stale pane/hash/fired files from a prior adapter otherwise -
# verbatim port of bin/wingman's own logic (§1 row 6).
if [ -n "${TMUX_PANE:-}" ] && [ -n "$WM_AGENT_REMOTE_CONTROL_FLAG" ]; then
  printf '%s\n' "$TMUX_PANE" > "$WM_HOME/self-pane" 2>/dev/null
else
  rm -f "$WM_HOME/self-pane" "$WM_HOME/self-pane.hash" "$WM_HOME/self-pane.fired"
fi

# --- 3. tmux-guardian launch (best-effort, never gates) ---------------------
# Verbatim port of bin/wingman's own logic (§1 row 7) - see that file's
# header comment (preserved there, not duplicated here) for why `setsid` is
# not optional and why this is a one-off systemd-run --scope invocation
# rather than an installed unit.
if [ -n "${TMUX_PANE:-}" ] && wm_have tmux; then
  if wm_have systemd-run && [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -e "${XDG_RUNTIME_DIR}/systemd/private" ]; then
    systemd-run --user --scope --collect --quiet -- setsid "$WM_LIB/tmux-guardian.sh" --daemon >/dev/null 2>&1 &
  else
    setsid "$WM_LIB/tmux-guardian.sh" --daemon >/dev/null 2>&1 < /dev/null &
  fi
fi

# --- 4. checkout-freshness advisory + continuity-transport notice (§4.6) ---
# Both are one-time, non-blocking notices - folded into the same .notice
# file/channel rather than two separate ones, since every caller treats them
# identically (surface once, then never again for this identity).
_notice=""

_gfc_out="$(REPO_DIR="$WM_OB_REPO" timeout 15 "$WM_LIB/git-freshness-check.sh" 2>/dev/null)"
case "$_gfc_out" in
  stale:*)
    _notice="this wingman checkout is behind origin/main - guard fixes that have merged are not running here. Run: git -C $WM_OB_REPO pull --ff-only, then restart this session."
    ;;
esac
unset _gfc_out

if [ -z "$WM_AGENT_CONTINUITY_TRANSPORT" ]; then
  _ct_msg="the resolved orchestrator agent '$WM_AGENT_DISPLAY_NAME' has a guard transport ('$WM_AGENT_GUARD_TRANSPORT'), but wingman has no fleet-continuity transport built for it: nothing re-invokes this session after a blocking wait, so the wake loop ('bin/watch-fleet', armed as a background task after a Stop event) cannot run here, and this session cannot wake itself the way a claude orchestrator does. This is a capability that has not been built for '$WM_AGENT_DISPLAY_NAME', not one that was shown to be impossible. Everything else - guard enforcement, onboarding-preferences enforcement, crew spawning, status commands - works normally. If you need fleet continuity, run wingman's orchestrator on Claude Code instead."
  if [ -n "$_notice" ]; then
    _notice="$_notice

$_ct_msg"
  else
    _notice="$_ct_msg"
  fi
  unset _ct_msg
fi

if [ -n "$_notice" ]; then
  printf '%s' "$_notice" | _wm_ob_write "$WM_OB_NOTICE_FILE"
else
  [ -n "$WM_OB_NOTICE_FILE" ] && rm -f "$WM_OB_NOTICE_FILE"
fi
unset _notice

rm -f "$WM_HOME/last-launch-failure"   # the one gating step passed
printf 'pass\n' | _wm_ob_write "$WM_OB_OUTCOME_FILE"
[ -n "$WM_OB_REASON_FILE" ] && rm -f "$WM_OB_REASON_FILE"
exit 0
