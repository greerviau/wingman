# bin/lib/agent.sh - per-agent-CLI adapter resolution (issue #25).
#
# A wingman crew member (and, per plan steps 13-16, the orchestrator itself)
# can run on any agent CLI a descriptor exists for, not just Claude Code. A
# "descriptor" is a small shell-sourceable file at bin/lib/agents/<name>.sh
# defining WM_AGENT_* variables that describe one CLI's launch flags,
# preflight checks, system-prompt delivery, freeze/composer detection
# signatures, guard-hook transport, and control values - see
# bin/lib/agents/claude.sh for the full field list and
# docs/plans/2026-08-11-issue-25-multi-cli-agent-adapter-implementation-plan.md
# (§4.3) for the schema this file implements.
#
# Sourced, never executed; assumes bin/lib/common.sh has already been sourced
# ($WM_LIB, wm_die must already exist). bash-3.2-safe: no associative arrays,
# no ${x,,}.
#
# Absence of a field (or an empty string) is always the adapter contract's own
# "unsupported/degrade" sentinel - never a magic string like "none" - so every
# consumer tests with `[ -n "$WM_AGENT_..." ]`, the same convention
# bin/spawn-crew already uses for $PERM_MODE/$MODEL/$EFFORT. wm_agent_resolve
# itself sets exactly two literal-value defaults (WM_AGENT_BIN,
# WM_AGENT_SYSPROMPT_MODE) and one degrade-value default (WM_AGENT_VERIFIED) -
# every other field stays genuinely empty when a descriptor omits it.

# Every WM_AGENT_* field a descriptor may define. wm_agent_resolve unsets this
# whole set before sourcing a new descriptor, so a second resolve in the same
# process (a test switching agents, or a future caller resolving both a crew
# adapter and the orchestrator's own $WM_ORCH_AGENT adapter) never silently
# inherits a stale value the new descriptor doesn't happen to override.
WM_AGENT_FIELDS="
WM_AGENT_BIN WM_AGENT_DISPLAY_NAME
WM_AGENT_PREFLIGHT WM_AGENT_ENV_PREFIX WM_AGENT_ENV_UNSET
WM_AGENT_CONTEXT_SUPPRESS_FLAG
WM_AGENT_BYPASS_FLAG WM_AGENT_SESSION_ID_FLAG WM_AGENT_NAME_FLAG
WM_AGENT_REMOTE_CONTROL_FLAG WM_AGENT_MODEL_FLAG WM_AGENT_MODEL_VALUE_SHAPE
WM_AGENT_EFFORT_FLAG WM_AGENT_EFFORT_VALUES
WM_AGENT_SYSPROMPT_MODE WM_AGENT_SYSPROMPT_FLAG
WM_AGENT_SUBMIT_SETTLE WM_AGENT_SLASH_SETTLE WM_AGENT_BUSY_MEANS_QUEUED
WM_AGENT_CLEAR_KEYS
WM_AGENT_COMPOSER_SHAPE WM_AGENT_COMPOSER_RULE_RE WM_AGENT_COMPOSER_ANCHOR
WM_AGENT_COMPOSER_ANCHOR_EMPTY
WM_AGENT_PERM_PROMPT_RE WM_AGENT_PERM_OPTION_RE WM_AGENT_PERM_LEAD_RE
WM_AGENT_RESUME_PROMPT_RE
WM_AGENT_RESUME_FLAG WM_AGENT_GUARD_TRANSPORT WM_AGENT_VERIFIED
WM_AGENT_EXIT_CMD WM_AGENT_INTERRUPT_KEY WM_AGENT_INTERRUPT_REPEAT
WM_AGENT_POST_INTERRUPT_CLEAR WM_AGENT_SKILL_FORM
"

# wm_agent_resolve <name>
#
# Sources bin/lib/agents/<name>.sh into the CALLING shell - this must never
# run inside a subshell or command substitution, or every variable/function it
# sets would die with it, defeating the whole point. Dies loudly (wm_die) on
# an unknown agent name or a descriptor that never sets WM_AGENT_DISPLAY_NAME,
# the one required field with no computed fallback (WM_AGENT_BIN's fallback -
# the descriptor's own filename stem - means it can never actually be empty
# after this runs, so there is nothing to fail loudly about there).
#
# Exports nothing: every WM_AGENT_* variable is a plain shell variable in the
# caller's process, read there and in whatever it sources next, never leaked
# into a launched agent's own environment.
wm_agent_resolve() {
  _war_name="$1"
  [ -n "$_war_name" ] || wm_die "wm_agent_resolve: no agent name given"
  _war_file="$WM_LIB/agents/$_war_name.sh"
  # Points at the descriptor directory itself, not `spawn-crew --list-agents`
  # (plan step 10) - that flag does not exist yet at this stage of the port,
  # and a message pointing at a flag that itself fails with "unknown arg"
  # would be worse than no pointer at all.
  [ -f "$_war_file" ] || wm_die "unknown agent '$_war_name' - no descriptor at bin/lib/agents/$_war_name.sh (see bin/lib/agents/ for the currently shipped adapters)"

  for _war_f in $WM_AGENT_FIELDS; do unset "$_war_f"; done

  . "$_war_file"

  # Every field defaults to empty (never left unbound), so a consumer can
  # reference $WM_AGENT_FOO directly - under this codebase's `set -u` - without
  # an inline ${:-} fallback at every call site. Without this, a newly-written
  # descriptor that simply omits an optional field would turn "$WM_AGENT_FOO"
  # into a script-ending unbound-variable error at the first reference, rather
  # than the intended "" degrade sentinel every consumer is written to expect.
  for _war_f in $WM_AGENT_FIELDS; do
    eval "$_war_f=\"\${$_war_f:-}\""
  done

  # Literal-value schema defaults (§4.3): a real value, not merely "degrade
  # when empty" - every other field's emptiness IS the degrade signal and gets
  # no default here.
  [ -n "$WM_AGENT_BIN" ]             || WM_AGENT_BIN="$_war_name"
  [ -n "$WM_AGENT_SYSPROMPT_MODE" ]  || WM_AGENT_SYSPROMPT_MODE="positional"
  [ -n "$WM_AGENT_VERIFIED" ]        || WM_AGENT_VERIFIED="0"

  # WM_AGENT_BIN_OVERRIDE (test/dev escape hatch, deliberately outside
  # WM_AGENT_FIELDS so the unset loop above never touches it): forces the exec
  # target regardless of which descriptor was selected, while every other
  # resolved field - flags, preflight, detection - still comes from the real
  # descriptor. This is what lets the test suite substitute a harmless stub
  # binary (tests/fixtures/stub-agent.sh and friends) while still exercising
  # claude's own real preflight/flag-composition logic, now that $WM_AGENT
  # itself selects a DESCRIPTOR rather than naming a binary path directly (the
  # pre-#25 convention every "WM_AGENT=<stub-path>" test fixture used).
  [ -n "${WM_AGENT_BIN_OVERRIDE:-}" ] && WM_AGENT_BIN="$WM_AGENT_BIN_OVERRIDE"

  [ -n "$WM_AGENT_DISPLAY_NAME" ] || wm_die "agent descriptor '$_war_file' does not set WM_AGENT_DISPLAY_NAME (required)"

  # WM_AGENT_PREFLIGHT names a function a caller invokes BY STRING later
  # (bin/spawn-crew: `"$WM_AGENT_PREFLIGHT" ...`) - a typo'd or removed
  # function name would otherwise fail silently: bash's own "command not
  # found" for a name that resolves to nothing is just another nonzero exit
  # status, indistinguishable at the call site from the preflight function
  # itself legitimately returning failure, and neither this codebase nor the
  # call site runs under `set -e` to turn that into a hard stop on its own.
  # Verified here, once, at resolve time, so every gate a descriptor's
  # preflight is supposed to run (workspace trust, Bypass-Permissions,
  # guard-hook sync, for claude) cannot go silently missing behind a bad
  # string.
  [ -z "$WM_AGENT_PREFLIGHT" ] || command -v "$WM_AGENT_PREFLIGHT" >/dev/null 2>&1 \
    || wm_die "agent descriptor '$_war_file' sets WM_AGENT_PREFLIGHT='$WM_AGENT_PREFLIGHT' but no such function is defined"

  unset _war_name _war_file _war_f
  return 0
}

# wm_agent_list - every descriptor name under bin/lib/agents/, one per line,
# sorted. The single enumeration point spawn-crew --list-agents and any future
# caller share, so they can never disagree about what "every supported agent"
# means.
wm_agent_list() {
  ( cd "$WM_LIB/agents" 2>/dev/null && ls -1 -- *.sh 2>/dev/null | sed 's/\.sh$//' | sort )
}

# wm_agent_emit_flag <template> <value>
#
# Prints " <flag-text>" (one leading space, matching every existing
# flag-composition call site's own convention) with <template>'s single %s
# replaced by the shell-quoted <value> - e.g. template "--model %s" and value
# "opus" prints " --model 'opus'". A no-op (prints nothing) when either
# argument is empty, which is how an unpopulated/degraded descriptor field
# (or a value the caller has already blanked out, e.g. an out-of-domain
# effort) omits its flag entirely rather than composing a broken one.
#
# <template> may itself contain shell syntax meant to run when the composed
# launch SCRIPT later executes (claude's WM_AGENT_SYSPROMPT_FLAG,
# '--append-system-prompt "$(cat %s)"', is exactly this) - it is never
# evaluated here, only used as a printf format string with %s substituted, so
# that syntax passes through as literal text into the caller's own output.
wm_agent_emit_flag() {
  [ -n "$1" ] && [ -n "$2" ] || return 0
  printf ' %s' "$(printf -- "$1" "$(quote "$2")")"
}

# wm_agent_emit_sysprompt <sysprompt-file> <opening-text>
#
# Emits this crew member's system-prompt delivery onto the launch line
# currently being composed by the caller, dispatched on the resolved
# adapter's WM_AGENT_SYSPROMPT_MODE (plan §4.5):
#   flag        - WM_AGENT_SYSPROMPT_FLAG with <sysprompt-file> substituted -
#                 claude/grok/pi's own direct flag, unchanged from claude's
#                 original single mechanism. The opening objective is NOT
#                 folded in here; the caller still delivers it separately,
#                 post-launch, exactly as before this adapter mechanism
#                 existed.
#   positional  - <sysprompt-file>'s content and <opening-text>, composed into
#                 ONE bare positional argument (codex has no system-prompt
#                 flag at all; pi requires the whole brief be exactly one
#                 positional argument, so the same composed-single-argument
#                 shape is used for prompt-flag below too, for the same
#                 reason).
#   prompt-flag - the same composed brief, via WM_AGENT_SYSPROMPT_FLAG
#                 (opencode's --prompt).
#   pointer-after-ready - nothing emitted at launch; the composed brief is
#                 left for the caller to deliver post-launch instead, the
#                 same path as an ordinary opening-objective delivery. No
#                 current target CLI uses this mode.
#
# Sets WM_AGENT_OPENING_DELIVERED_AT_LAUNCH=1 when <opening-text> was folded
# into what this function just emitted (positional/prompt-flag) - the caller
# must then skip its own separate post-launch delivery of the same text, or
# the objective would be sent twice. Left 0 (flag/pointer-after-ready), where
# the caller still owns delivering it.
wm_agent_emit_sysprompt() {
  _waes_file="$1"; _waes_opening="$2"
  WM_AGENT_OPENING_DELIVERED_AT_LAUNCH=0
  case "$WM_AGENT_SYSPROMPT_MODE" in
    flag)
      wm_agent_emit_flag "$WM_AGENT_SYSPROMPT_FLAG" "$_waes_file"
      ;;
    positional|prompt-flag)
      _waes_brief="$(cat "$_waes_file"; printf '\n\n---\n\nYour first objective: %s\n' "$_waes_opening")"
      if [ "$WM_AGENT_SYSPROMPT_MODE" = positional ]; then
        printf ' %s' "$(quote "$_waes_brief")"
      else
        wm_agent_emit_flag "$WM_AGENT_SYSPROMPT_FLAG" "$_waes_brief"
      fi
      WM_AGENT_OPENING_DELIVERED_AT_LAUNCH=1
      ;;
    pointer-after-ready)
      : # nothing at launch - the caller delivers the combined brief post-launch
      ;;
  esac
  unset _waes_file _waes_opening _waes_brief
}
