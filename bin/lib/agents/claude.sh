# bin/lib/agents/claude.sh - the claude agent descriptor (issue #25).
#
# Encodes exactly today's hardcoded behavior - this file is the regression
# anchor for the whole adapter mechanism: bin/spawn-crew's composed launch
# line for the default case (no --agent, no $WM_AGENT) must stay byte-identical
# to pre-change output at every commit, which this descriptor's values are
# what make possible. See the plan (§5 step 2) for the full field-by-field
# rationale.
#
# Sourced by wm_agent_resolve (bin/lib/agent.sh), which has already sourced
# bin/lib/common.sh - the WM_PERM_*/WM_COMPOSER_*/WM_RESUME_PROMPT_RE globals
# referenced below already exist by the time this runs, and are themselves
# already override-able via their own environment variables (common.sh:
# "${WM_PERM_PROMPT_RE:-...}" etc.) - referencing them here (rather than
# duplicating their literal text) is what keeps an operator's existing
# WM_PERM_PROMPT_RE-style override working as *claude's* value after this
# port, per the plan's explicit requirement (§5 step 7).

WM_AGENT_BIN=claude
WM_AGENT_DISPLAY_NAME="Claude Code"

# --- preflight and environment ------------------------------------------
WM_AGENT_PREFLIGHT=claude_preflight
WM_AGENT_ENV_PREFIX=""
# The orchestrator that execs every crew member is always Claude Code, so a
# claude crew member legitimately inherits CLAUDECODE=1 from it - nothing to
# unset for itself.
WM_AGENT_ENV_UNSET=""

# --- launch capability ----------------------------------------------------
WM_AGENT_BYPASS_FLAG="--permission-mode %s"
WM_AGENT_SESSION_ID_FLAG="--session-id %s"
WM_AGENT_NAME_FLAG="--name %s"
WM_AGENT_REMOTE_CONTROL_FLAG="--remote-control %s"
WM_AGENT_MODEL_FLAG="--model %s"
WM_AGENT_MODEL_VALUE_SHAPE="bare"
WM_AGENT_EFFORT_FLAG="--effort %s"
# No accepted-value domain recorded for claude: today's behavior passes any
# string straight through to claude's own alias resolution unconstrained, and
# that must stay unconstrained for the byte-identical regression to hold.
WM_AGENT_EFFORT_VALUES=""

# --- system prompt and delivery -------------------------------------------
WM_AGENT_SYSPROMPT_MODE=flag
WM_AGENT_SYSPROMPT_FLAG='--append-system-prompt "$(cat %s)"'
WM_AGENT_SUBMIT_SETTLE=""
WM_AGENT_SLASH_SETTLE=""
WM_AGENT_BUSY_MEANS_QUEUED=""
# Verified against a live Claude Code pane (common.sh's own long-standing
# default): a single Ctrl-C clears the composer's current text without
# exiting.
WM_AGENT_CLEAR_KEYS="C-c"

# --- detection --------------------------------------------------------------
WM_AGENT_COMPOSER_SHAPE=bare
WM_AGENT_COMPOSER_RULE_RE="$WM_COMPOSER_RULE_RE"
WM_AGENT_COMPOSER_ANCHOR="$WM_COMPOSER_ANCHOR"
# WM_AGENT_COMPOSER_ANCHOR_EMPTY (issue #25, PR #348) is not claude's field
# to set: claude's own anchor is a real, non-empty glyph ("❯"+NBSP) above,
# so the ambiguity this flag exists to resolve - "is the empty anchor field
# unset, or is empty genuinely the right value?" - never arises for it. See
# bin/lib/agents/pi.sh for the adapter this flag was actually added for.
WM_AGENT_PERM_PROMPT_RE="$WM_PERM_PROMPT_RE"
WM_AGENT_PERM_OPTION_RE="$WM_PERM_OPTION_RE"
WM_AGENT_PERM_LEAD_RE="$WM_PERM_LEAD_RE"
WM_AGENT_RESUME_PROMPT_RE="$WM_RESUME_PROMPT_RE"

# --- resume, lifecycle, and verification -----------------------------------
WM_AGENT_RESUME_FLAG="--resume %s"
WM_AGENT_GUARD_TRANSPORT=claude-json
WM_AGENT_VERIFIED=1

# --- control values (B3) ----------------------------------------------------
WM_AGENT_EXIT_CMD="/exit"
WM_AGENT_INTERRUPT_KEY="Escape"
WM_AGENT_INTERRUPT_REPEAT=1
WM_AGENT_POST_INTERRUPT_CLEAR=""
WM_AGENT_SKILL_FORM="/<skill>"

# claude_preflight <repo> <perm_mode> [<action>]
#
# Wraps claude's three unconditional launch-time gates, relocated verbatim
# from bin/spawn-crew (issue #16, #241) rather than reimplemented: the
# one-time workspace-trust dialog, the one-time Bypass-Permissions acceptance
# dialog (only when $2 requests bypassPermissions), and the user-scope
# guard-hook sync/reconciliation. Every gate dies (wm_die) on its own failure
# with its own original message. A caller MUST run this before any
# window/tmux/roster side effect - exactly like bin/spawn-crew's own preflight
# block did before this relocation - so a gate failure here still leaves
# nothing to tear down.
#
# <action> (default "spawn") names the caller's own verb in the user-facing
# message ("retry this spawn" vs "retry this resume") - the two call sites
# this consolidates (bin/spawn-crew, and bin/crew-resume per plan step 5) had
# slightly different wording for exactly this reason.
claude_preflight() {
  _cp_repo="$1"
  _cp_perm_mode="$2"
  _cp_action="${3:-spawn}"

  # --- workspace-trust gate (issue #16) -----------------------------------
  if ! uv run --no-project --quiet "$WM_LIB/claude-gate-check.py" trust-status \
      --config "${WM_CLAUDE_USER_CONFIG:-$HOME/.claude.json}" --repo "$_cp_repo"; then
    wm_die "workspace trust for '$_cp_repo' has not been accepted yet. Run 'claude' there once, interactively, and accept the trust dialog, then retry this $_cp_action."
  fi

  # --- Bypass-Permissions mode acceptance (issue #16) ---------------------
  if [ "$_cp_perm_mode" = bypassPermissions ] && \
     ! uv run --no-project --quiet "$WM_LIB/claude-gate-check.py" bypass-status \
       --settings "${WM_CLAUDE_USER_SETTINGS:-$HOME/.claude/settings.json}"; then
    wm_die "Bypass-Permissions mode has not been accepted yet. Run 'bin/doctor -y', or accept it manually (see bin/doctor's own message), then retry this $_cp_action."
  fi

  # --- reconcile user-scope guard hooks (issue #241) -----------------------
  if ! _cp_sync_err="$(uv run --no-project --quiet "$WM_LIB/sync-user-hooks.py" \
      --settings "${WM_CLAUDE_USER_SETTINGS:-$HOME/.claude/settings.json}" --repo "$WM_REPO" 2>&1)"; then
    wm_launch_failure "guard-hook sync ($_cp_action)" "$_cp_sync_err"
    wm_die "could not wire the user-level guard hooks this session needs: $_cp_sync_err
Fix the reported problem, or run 'bin/doctor -y', then retry this $_cp_action."
  fi

  unset _cp_repo _cp_perm_mode _cp_action _cp_sync_err
  return 0
}
