# bin/lib/guard-transport.sh - per-transport guard install/verify (the
# orchestrator-guard-transports plan). Sourced by bin/wingman (and, once the
# crew-side follow-on lands, bin/spawn-crew/bin/crew-resume) after
# bin/lib/common.sh and bin/lib/agent.sh - assumes $WM_LIB/$WM_BIN/$WM_REPO
# and wm_die/wm_warn already exist.
#
# wm_guard_transport_sync <transport> <repo>
#   0  -> guards installed AND positively verified for this transport
#   1  -> refused; the reason is printed on stdout for the caller to feed
#         wm_launch_failure/wm_die (never printed directly, so the caller
#         owns the sink - see bin/wingman's own use of this function)
#
# One new file rather than inline in bin/wingman: bin/spawn-crew and
# bin/crew-resume will need the identical dispatch the moment crew run on a
# non-Claude CLI (a follow-on, not built by this plan - see docs/guards.md),
# and that follow-on must not have to re-extract this from bin/wingman.
#
# §5.4.0's self-test standard is the one check every branch below ends with,
# and it is the one that actually matters: run the EXACT command line that
# was registered, against two synthetic payloads whose verdicts are both
# known in advance (deny, allow), and assert both. A transport that merely
# REGISTERS a command - without ever executing it - proves nothing: `uv` not
# on the CLI's own PATH, a typo'd --dialect/--guards value, an import error
# inside the dispatcher, or a cold start slower than a fail-open CLI's own
# timeout would all read as "installed" while enforcing nothing.
#
# bash-3.2-safe: no associative arrays, no ${x,,}.
set -u

WM_UV="${WM_UV:-uv run --no-project --quiet}"

# --- §5.4.0 fixtures ---------------------------------------------------------
#
# The deny fixture is a bare arming `bin/watch-fleet` Bash call with no
# run_in_background - decided by the foreground-watcher guard, which has NO
# crew-id gating at all and whose every branch converges on deny (see
# hooks/lib/guard_policy.py's own no-foreground-watcher-guard section, and
# the plan's §5.4.0 table for the candidates this fixture beats: gh pr merge
# and pkill/watch-fleet-kill are both crew-only or state-dependent, so
# either would pass vacuously in the orchestrator's own preflight scope,
# which has no WINGMAN_CREW_ID and nothing armed yet). The allow fixture is
# a bare `ls`, which passes every guard in the set - asserting it catches an
# inverted or over-broad dispatcher that would otherwise deny everything and
# then block every tool call in the session.
#
# claude's own fixture is built inline here (its "registered command line"
# is hooks/no-foreground-watcher-guard.sh, a different program from
# guard_dispatch.py, with its own stdin contract - see that hook's own
# header). The four non-Claude dialects reuse guard_dispatch.py's own
# --emit-fixture so the fixture and that module's own parser can never drift
# apart (plan §5.4.0).
_wm_gt_fixture() {
  # _wm_gt_fixture <dialect> <deny|allow>
  _wgf_dialect="$1"; _wgf_case="$2"
  if [ "$_wgf_dialect" = claude ]; then
    if [ "$_wgf_case" = deny ]; then
      printf '{"tool_name":"Bash","tool_input":{"command":"bin/watch-fleet"}}'
    else
      printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
    fi
  else
    $WM_UV "$WM_REPO/hooks/lib/guard_dispatch.py" --emit-fixture "$_wgf_dialect" --case "$_wgf_case"
  fi
  unset _wgf_dialect _wgf_case
}

# _wm_gt_verify_deny/_wm_gt_verify_allow <dialect> <stdout> <rc> - true (0)
# iff <stdout>/<rc> match that dialect's own documented verdict shape
# (§5.4.0's table). claude and codex share the hookSpecificOutput shape;
# grok/opencode/pi share the {"decision": ...} shape; only opencode/pi
# require an EXPLICIT allow verdict rather than silence (§5.1's "allow is
# silence" holds only for the transports with no shim to interpret it).
_wm_gt_verify_deny() {
  _wgvd_dialect="$1"; _wgvd_out="$2"; _wgvd_rc="$3"
  case "$_wgvd_dialect" in
    claude)
      [ "$_wgvd_rc" -eq 0 ] && case "$_wgvd_out" in *'"permissionDecision": "deny"'*) return 0 ;; esac
      return 1
      ;;
    codex)
      [ "$_wgvd_rc" -eq 2 ] && case "$_wgvd_out" in *'"permissionDecision": "deny"'*) return 0 ;; esac
      return 1
      ;;
    grok|opencode|pi)
      [ "$_wgvd_rc" -eq 2 ] && case "$_wgvd_out" in *'"decision": "deny"'*) return 0 ;; esac
      return 1
      ;;
    *) return 1 ;;
  esac
}

_wm_gt_verify_allow() {
  _wgva_dialect="$1"; _wgva_out="$2"; _wgva_rc="$3"
  case "$_wgva_dialect" in
    claude|codex|grok)
      [ "$_wgva_rc" -eq 0 ] && [ -z "$_wgva_out" ]
      ;;
    opencode|pi)
      [ "$_wgva_rc" -eq 0 ] && case "$_wgva_out" in *'"decision": "allow"'*) return 0 ;; esac
      return 1
      ;;
    *) return 1 ;;
  esac
}

# wm_guard_transport_selftest <dialect> <cmd...>
#
# Runs both §5.4.0 fixtures through the registered command line `<cmd...>`
# (read on stdin, exactly the way the real transport invokes it) and asserts
# both verdicts. Returns 0 on success (nothing printed). On failure, prints a
# diagnostic to STDOUT (never stderr - the caller owns the sink, same
# convention as wm_guard_transport_sync itself) naming the exact command
# line, its stdout/stderr, and the remedy - §5.4.0's own requirement, since
# this self-test is the one new failure mode that reaches a live system
# (claude-json is the only branch reachable in real use today - the
# continuity gate refuses every other adapter before this ever runs there).
wm_guard_transport_selftest() {
  _wgt_dialect="$1"; shift

  _wgt_deny_fixture="$(_wm_gt_fixture "$_wgt_dialect" deny)"
  _wgt_deny_out="$(printf '%s' "$_wgt_deny_fixture" | "$@" 2>/tmp/wm-gt-selftest-stderr.$$)"
  _wgt_deny_rc=$?
  _wgt_deny_err="$(cat /tmp/wm-gt-selftest-stderr.$$ 2>/dev/null)"
  rm -f "/tmp/wm-gt-selftest-stderr.$$"

  if ! _wm_gt_verify_deny "$_wgt_dialect" "$_wgt_deny_out" "$_wgt_deny_rc"; then
    printf 'guard-transport self-test failed for %s: the registered command did not deny the known-deny fixture.\nCommand: %s\nFixture (stdin): %s\nExit status: %s\nStdout: %s\nStderr: %s\nRemedy: run the command above by hand with the fixture on stdin and inspect why it did not deny - a missing `uv`, a broken PYTHONPATH, or an import error inside the dispatcher would all produce exactly this.\n' \
      "$_wgt_dialect" "$*" "$_wgt_deny_fixture" "$_wgt_deny_rc" "$_wgt_deny_out" "$_wgt_deny_err"
    return 1
  fi

  _wgt_allow_fixture="$(_wm_gt_fixture "$_wgt_dialect" allow)"
  _wgt_allow_out="$(printf '%s' "$_wgt_allow_fixture" | "$@" 2>/tmp/wm-gt-selftest-stderr.$$)"
  _wgt_allow_rc=$?
  _wgt_allow_err="$(cat /tmp/wm-gt-selftest-stderr.$$ 2>/dev/null)"
  rm -f "/tmp/wm-gt-selftest-stderr.$$"

  if ! _wm_gt_verify_allow "$_wgt_dialect" "$_wgt_allow_out" "$_wgt_allow_rc"; then
    printf 'guard-transport self-test failed for %s: the registered command denied the known-allow fixture (a deny-everything dispatcher would block every tool call in the session).\nCommand: %s\nFixture (stdin): %s\nExit status: %s\nStdout: %s\nStderr: %s\nRemedy: run the command above by hand with the fixture on stdin - an inverted allow/deny condition, an unknown payload treated as closed, or a --guards list that picked up an unrelated closed-direction guard would all produce exactly this.\n' \
      "$_wgt_dialect" "$*" "$_wgt_allow_fixture" "$_wgt_allow_rc" "$_wgt_allow_out" "$_wgt_allow_err"
    return 1
  fi

  unset _wgt_dialect _wgt_deny_fixture _wgt_deny_out _wgt_deny_rc _wgt_deny_err \
    _wgt_allow_fixture _wgt_allow_out _wgt_allow_rc _wgt_allow_err
  return 0
}

# --- claude-json -------------------------------------------------------------
#
# Relocated verbatim from bin/wingman's own inline case (no behaviour
# change): run sync-user-hooks.py, on failure return its stderr. Project-
# scope hooks continue to come free from .claude/settings.json. The §5.4.0
# self-test is added here too (it costs one subprocess and closes the same
# "uv not runnable in THIS session's own environment" hole every other
# branch closes) - tests/orchestrator-guard-sync-gate.test.sh part (a) keeps
# passing unchanged.
_wm_gt_sync_claude() {
  _wgsc_repo="$1"
  if ! _wgsc_err="$($WM_UV "$WM_LIB/sync-user-hooks.py" \
      --settings "${WM_CLAUDE_USER_SETTINGS:-$HOME/.claude/settings.json}" --repo "$_wgsc_repo" 2>&1)"; then
    printf '%s' "$_wgsc_err"
    unset _wgsc_repo _wgsc_err
    return 1
  fi
  if ! _wgsc_st_out="$(wm_guard_transport_selftest claude \
      "$WM_REPO/hooks/no-foreground-watcher-guard.sh" 2>&1)"; then
    printf '%s' "$_wgsc_st_out"
    unset _wgsc_repo _wgsc_err _wgsc_st_out
    return 1
  fi
  unset _wgsc_repo _wgsc_err _wgsc_st_out
  return 0
}

# --- pi-extension -------------------------------------------------------
#
# Install: none. bin/lib/agents/pi/wingman-guard-extension.js ships in the
# repo and is delivered by WM_AGENT_GUARD_LAUNCH_FLAGS (-e <abs path>
# --no-extensions, pi.sh) - nothing written outside the repo, nothing
# reconciled, nothing to drift. Verify: the extension file exists; loading
# it under --offline (no network, no credentials needed) makes its
# registered --wingman-guard-active flag observable exactly once in
# `pi --help`'s own "Extension CLI Flags:" section (pi silently tolerates a
# broken/missing extension - exit status alone proves nothing, plan §3.2);
# plus the shared self-test, invoking the identical dispatcher command line
# the extension's own handler calls internally.
_WM_GT_ALL_GUARDS="direct-edit,watcher-kill,spawn-pause,foreground-watcher,foreground-poll-loop"

_wm_gt_sync_pi() {
  _wgsp_repo="$1"
  _wgsp_ext="$_wgsp_repo/bin/lib/agents/pi/wingman-guard-extension.js"
  _wgsp_bin="${WM_AGENT_BIN:-pi}"

  if [ ! -f "$_wgsp_ext" ]; then
    printf 'the pi guard extension is missing at %s' "$_wgsp_ext"
    unset _wgsp_repo _wgsp_ext _wgsp_bin
    return 1
  fi
  if ! wm_have "$_wgsp_bin"; then
    printf 'the pi binary (%s) is not on PATH, so the guard extension cannot be verified' "$_wgsp_bin"
    unset _wgsp_repo _wgsp_ext _wgsp_bin
    return 1
  fi

  _wgsp_help="$(timeout 20 "$_wgsp_bin" --offline -e "$_wgsp_ext" --no-extensions --help 2>&1)"
  _wgsp_flag_count=$(printf '%s' "$_wgsp_help" | grep -c -- --wingman-guard-active)
  if [ "$_wgsp_flag_count" -ne 1 ]; then
    printf 'the pi guard extension did not register its own --wingman-guard-active flag (expected exactly 1 occurrence in `%s --offline -e %s --no-extensions --help`, saw %s) - the extension likely failed to load. Output:\n%s' \
      "$_wgsp_bin" "$_wgsp_ext" "$_wgsp_flag_count" "$_wgsp_help"
    unset _wgsp_repo _wgsp_ext _wgsp_bin _wgsp_help _wgsp_flag_count
    return 1
  fi

  if ! _wgsp_st_out="$(wm_guard_transport_selftest pi \
      $WM_UV "$_wgsp_repo/hooks/lib/guard_dispatch.py" --dialect pi --guards "$_WM_GT_ALL_GUARDS" 2>&1)"; then
    printf '%s' "$_wgsp_st_out"
    unset _wgsp_repo _wgsp_ext _wgsp_bin _wgsp_help _wgsp_flag_count _wgsp_st_out
    return 1
  fi

  unset _wgsp_repo _wgsp_ext _wgsp_bin _wgsp_help _wgsp_flag_count _wgsp_st_out
  return 0
}

# --- grok-json ------------------------------------------------------------
#
# Install: bin/lib/sync-grok-hooks.py writes $HOME/.grok/hooks/wingman.json
# only - personal scope, no trust gate at all (plan §3.4/§5.4.3/§5.7).
# Suppress the Claude compatibility path: GROK_CLAUDE_HOOKS_ENABLED=0 must be
# in grok's own launch environment (plan §3.4's hazard - this repo's checked-
# in .claude/settings.json would otherwise silently allow on every call under
# grok, since its Claude-dialect scripts would read a camelCase payload as
# absent). This is carried by the descriptor's own WM_AGENT_GUARD_ENV field
# (grok.sh), read here directly rather than checked against the process's
# actual environment - by the time wm_guard_transport_sync runs, this
# descriptor field is already resolved (wm_agent_resolve has run), which is
# "the environment about to be exec'd into" in the sense that matters: it is
# the value wm_agent_apply_guard_env will apply verbatim before exec, whether
# or not that application has happened yet at THIS point in bin/wingman's own
# sequence.
_wm_gt_sync_grok() {
  _wgsg_repo="$1"

  if [ "${WM_AGENT_GUARD_ENV:-}" != "GROK_CLAUDE_HOOKS_ENABLED=0" ]; then
    printf 'grok launch is missing GROK_CLAUDE_HOOKS_ENABLED=0 in its own guard-transport environment (WM_AGENT_GUARD_ENV=%s) - without it, this repo'"'"'s own .claude/settings.json compatibility path silently allows every tool call under grok (see bin/lib/agents/grok.sh'"'"'s own header comment). Fix grok.sh'"'"'s WM_AGENT_GUARD_ENV field.' "${WM_AGENT_GUARD_ENV:-<empty>}"
    unset _wgsg_repo
    return 1
  fi

  if ! _wgsg_err="$($WM_UV "$WM_LIB/sync-grok-hooks.py" --repo "$_wgsg_repo" 2>&1)"; then
    printf '%s' "$_wgsg_err"
    unset _wgsg_repo _wgsg_err
    return 1
  fi

  if ! _wgsg_st_out="$(wm_guard_transport_selftest grok \
      $WM_UV "$_wgsg_repo/hooks/lib/guard_dispatch.py" --dialect grok --guards "$_WM_GT_ALL_GUARDS" 2>&1)"; then
    printf '%s' "$_wgsg_st_out"
    unset _wgsg_repo _wgsg_err _wgsg_st_out
    return 1
  fi

  unset _wgsg_repo _wgsg_err _wgsg_st_out
  return 0
}

# --- codex-json ------------------------------------------------------------
#
# Install: bin/lib/sync-codex-hooks.py writes $CODEX_HOME/hooks.json only
# (default $HOME/.codex/hooks.json) - user scope, no repo-scoped file (plan
# §5.7). That reconciler itself refuses (fails closed, writes nothing) on
# either of the two codex-specific hazards: [features].hooks explicitly
# false in any layer it reads, or a foreign hook source existing anywhere
# --dangerously-bypass-hook-trust would also un-gate - see its own docstring
# for the full reasoning. This branch's own job is just to check codex's
# --help actually documents that trust-bypass flag (so the launch line
# bin/lib/agents/codex.sh composes is not silently stale against whatever
# codex version is actually installed) and run the shared self-test.
_wm_gt_sync_codex() {
  _wgsc2_repo="$1"
  _wgsc2_bin="${WM_AGENT_BIN:-codex}"

  if ! wm_have "$_wgsc2_bin"; then
    printf 'the codex binary (%s) is not on PATH, so the guard transport cannot be verified' "$_wgsc2_bin"
    unset _wgsc2_repo _wgsc2_bin
    return 1
  fi

  _wgsc2_help="$(timeout 20 "$_wgsc2_bin" --help 2>&1)"
  case "$_wgsc2_help" in
    *--dangerously-bypass-hook-trust*) ;;
    *)
      printf 'the installed codex binary (%s) no longer documents --dangerously-bypass-hook-trust in its own --help output - bin/lib/agents/codex.sh'"'"'s launch line depends on this flag existing; an untrusted-and-therefore-skipped hook would otherwise silently disable enforcement.' "$_wgsc2_bin"
      unset _wgsc2_repo _wgsc2_bin _wgsc2_help
      return 1
      ;;
  esac

  if ! _wgsc2_err="$($WM_UV "$WM_LIB/sync-codex-hooks.py" --repo "$_wgsc2_repo" 2>&1)"; then
    printf '%s' "$_wgsc2_err"
    unset _wgsc2_repo _wgsc2_bin _wgsc2_help _wgsc2_err
    return 1
  fi

  if ! _wgsc2_st_out="$(wm_guard_transport_selftest codex \
      $WM_UV "$_wgsc2_repo/hooks/lib/guard_dispatch.py" --dialect codex --guards "$_WM_GT_ALL_GUARDS" 2>&1)"; then
    printf '%s' "$_wgsc2_st_out"
    unset _wgsc2_repo _wgsc2_bin _wgsc2_help _wgsc2_err _wgsc2_st_out
    return 1
  fi

  unset _wgsc2_repo _wgsc2_bin _wgsc2_help _wgsc2_err _wgsc2_st_out
  return 0
}

wm_guard_transport_sync() {
  _wgts_transport="$1"; _wgts_repo="$2"
  case "$_wgts_transport" in
    claude-json)
      _wgts_out="$(_wm_gt_sync_claude "$_wgts_repo")"; _wgts_rc=$?
      ;;
    pi-extension)
      _wgts_out="$(_wm_gt_sync_pi "$_wgts_repo")"; _wgts_rc=$?
      ;;
    grok-json)
      _wgts_out="$(_wm_gt_sync_grok "$_wgts_repo")"; _wgts_rc=$?
      ;;
    codex-json)
      _wgts_out="$(_wm_gt_sync_codex "$_wgts_repo")"; _wgts_rc=$?
      ;;
    *)
      _wgts_out="the guard transport '$_wgts_transport' has no orchestrator-side guard install/verify implementation yet."
      _wgts_rc=1
      ;;
  esac
  if [ "$_wgts_rc" -ne 0 ]; then
    printf '%s' "$_wgts_out"
    unset _wgts_transport _wgts_repo _wgts_out _wgts_rc
    return 1
  fi
  unset _wgts_transport _wgts_repo _wgts_out _wgts_rc
  return 0
}
