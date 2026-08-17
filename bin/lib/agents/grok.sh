# bin/lib/agents/grok.sh - the grok agent descriptor (issue #25).
#
# Grok Build (npm @xai-official/grok, binary `grok`) is the fourth and final
# non-claude adapter for this effort (plan §8's build order: pi, opencode,
# codex, grok - unchanged). "Grok" here means xAI's own first-party CLI
# (`xai-org/grok-build`), not the unrelated third-party `superagent-ai/
# grok-cli` fork the plan's own research explicitly excluded (plan §3).
# Exercises the `bordered` composer shape (the one shape not shared with any
# earlier adapter), a slash-autocomplete popup that needs WM_AGENT_SLASH_
# SETTLE, and a genuinely different interrupt/clear-key split (C-c interrupts
# a turn; nothing clears the composer) from every earlier adapter - see
# issue #25 for the full research and schema this
# descriptor implements, and bin/lib/agents/claude.sh for the field-by-field
# schema reference this file follows.
#
# Sourced by wm_agent_resolve (bin/lib/agent.sh), which has already sourced
# bin/lib/common.sh.
#
# *** AGENTS.md double-injection note (issue #353's own accepted residual) ***
# grok auto-loads a repo-root AGENTS.md for repo-level instructions - hands-on
# confirmed live via `grok inspect --json` (`projectInstructions` lists the
# discovered file, with no `vendor`/`compatibilityStatus` fields at all - it
# is grok's own native format, not a compat-layer entry). GROK_CLAUDE_AGENTS_
# ENABLED=0 (below) does NOT suppress this: directly confirmed by diffing
# `grok inspect --json` with a local AGENTS.md present, with and without the
# var set - that entry is byte-identical either way. This is issue #353's own
# explicitly accepted residual for grok, not a gap introduced here; a grok
# crew member's repo-level context still includes whatever AGENTS.md this
# repo carries, on top of this descriptor's own composed brief (delivered via
# a direct flag, WM_AGENT_SYSPROMPT_FLAG below) - both reach the model.
#
# What GROK_CLAUDE_AGENTS_ENABLED=0 DOES do, confirmed by the same diff
# technique (round-2 review of this PR - the original version of this
# comment claimed "no observable effect" from testing only the local-repo
# case above, and that claim was wrong): it disables grok's `vendor: claude,
# surface: agents` external-compat cell, which - separately confirmed by
# planting a file at a fake `$HOME/.claude/CLAUDE.md` - governs whether grok
# reads the OPERATOR'S OWN GLOBAL Claude Code instructions file at all.
# Without this var, that entry appears in `projectInstructions` with
# `"compatibilityStatus": "enabled"` (grok reads it); with it set to 0, the
# same entry flips to `"compatibilityStatus": "disabled"`. This is a real,
# meaningful protection, not a no-op - and it is the plan's own §4.5 "the
# operator's personal Claude Code instructions leaving the machine to
# whatever provider the non-claude CLI is configured against" privacy hazard,
# already required to be actively prevented for opencode, now confirmed
# closed for grok too as a side effect of this same var. Deliberately kept
# set unconditionally (not made contingent on anything) precisely because of
# this: a grok crew member never leaking the operator's own global
# `~/.claude/CLAUDE.md` content to xAI's inference backend is worth keeping
# even though it does nothing for the AGENTS.md concern this var was
# originally added for. `wm_claude_md_excludes()` has no equivalent reach
# here - it only ever excludes THIS repo's own root CLAUDE.md, never the
# operator's global one, so claude crew members DO still load the operator's
# global `~/.claude/CLAUDE.md` (Claude Code's own standard behavior,
# unaffected by this repo's descriptor work) while grok crew members do not.
# This is an accepted, deliberate divergence, not an oversight: it is
# strictly a privacy IMPROVEMENT for grok specifically (never sending the
# operator's personal instructions to a third-party provider), not a loss of
# anything grok crew members need - the actual crew brief still arrives in
# full via WM_AGENT_SYSPROMPT_FLAG regardless.
#
# Hands-on verified (2026-08-13, revised 2026-08-13 after round-2 review)
# against real grok-build v1.0.0, but LESS THAN the other three adapters:
# grok's own headless (`-p`) and interactive TUI login paths both required a
# genuine grok.com OAuth round-trip that could not be completed in this
# credential-less environment (confirmed via --debug-file: a fake
# XAI_API_KEY successfully resolves as model-API credentials and the CLI
# completes a real ACP "initialize" handshake with the real xAI backend -
# but sending an actual turn is gated behind a SEPARATE grok.com account
# sign-in this environment has no way to satisfy, unlike codex where any
# string got past onboarding). What COULD be verified hands-on without that
# gate: the full `--help` flag surface (used directly below, not
# doc-derived); `grok inspect --json`'s confirmation that AGENTS.md/CLAUDE.md
# are both discovered; `grok doctor`'s environment probe (no auth needed);
# via the real ACP "initialize" response captured over --debug-file, a live,
# protocol-level confirmation that only low/medium/high reasoning-effort
# levels exist for the current model (xhigh/max never appear in the
# response's own reasoningEfforts array), independently reconfirming the
# plan's own firstmate-sourced finding a third way; and, confirmed via a
# controlled `grok inspect --json` diff (planting a marker file and toggling
# the env var), GROK_CLAUDE_AGENTS_ENABLED=0's real effect - see this file's
# own header note above for the full finding. NOT verified live: the
# bordered composer's exact glyphs/anchor (attributed to the plan's own
# firstmate-sourced research, §4.6 - never independently captured from a
# real rendered pane), whether --rules vs --system-prompt-override actually
# composes the way each flag's --help text describes, exit command/
# interrupt key/skill form (attributed, not independently exercised against
# a live composer), and - genuinely unresolved, see WM_AGENT_PREFLIGHT's own
# comment below - whether the real interactive trust dialog behaves the way
# `grok inspect --json`'s own `projectTrusted` field suggests, since that
# field was never cross-checked against the real dialog (auth-gated).
#
# GROK_CLAUDE_AGENTS_ENABLED=0's own value: confirmed to exist as a real,
# non-fabricated config key by reading the compiled binary directly (`strings`
# on the decompressed binary shows the full GROK_CLAUDE_{SKILLS,RULES,AGENTS,
# MCPS,HOOKS,SESSIONS}_ENABLED family, alongside matching GROK_CURSOR_* and
# GROK_CODEX_* families), and its real, confirmed effect (disables the
# `vendor: claude, surface: agents` compat cell, which gates the operator's
# global `~/.claude/CLAUDE.md`, not `.claude/agents/` subagent definitions as
# initially hypothesized - see the header note above) is documented there in
# full, not repeated here.
#
# Separately (2026-08-17, the portable crew command vocabulary): both
# symlink-following AND the ~/.grok/skills discovery path are hands-on
# verified live against real grok-build v1.0.4, with $HOME overridden to a
# scratch directory containing a real symlink set built by
# bin/lib/sync-user-skills.py (pointed at this repo's own canonical
# .agents/skills/ tree), launched from an unrelated cwd - the SAME gate
# this file's header already documents as blocking most other live checks
# was reached again here (grok.com account sign-in required, no real
# credentials in this environment), so the "$wingman-sta" typed-invocation
# check itself stays attributed rather than independently confirmed, same
# as every other grok control value in this file - but `grok inspect --json`
# needs no auth at all and settled the two things that mattered: its
# `skills` array listed all seven wingman-<verb> entries, each with
# `"source": {"type": "user", "path": ".../.grok/skills/wingman-<verb>/
# SKILL.md"}` resolved THROUGH the symlink (byte-exact description, and
# "userInvocable": true, confirming the documented "/<skill>" slash form is
# real) - conclusive proof grok follows a symlinked skill directory, the
# one fact its own docs never state either way. Separately, `externalCompat.
# cells` was inspected directly for a `{"vendor": "claude", "surface":
# "commands"}` entry: none exists (only skills/rules/agents/mcps/hooks/
# sessions appear for vendor "claude") - independently reconfirming, live,
# the plan's own §3.4 finding that grok's Claude-compat layer does not read
# `.claude/commands/` at all, so nothing about this design depends on it.

WM_AGENT_BIN=grok
WM_AGENT_DISPLAY_NAME="grok"

# --- preflight and environment ------------------------------------------
# No trust-dialog automation wired up - attributed to the plan's own
# positive finding (§3: grok's project-picker/trust dialog appears only when
# launched from a non-project directory, which wingman's own git-worktree
# launch always avoids), but with LOWER confidence than that phrasing
# implies. `grok inspect --json` reported "projectTrusted": true in a git
# worktree, matching the plan - but round-2 review of this PR prompted a
# direct recheck of that signal's own reliability, and it also reports
# "projectTrusted": true with NO .git directory at all and no project
# markers of any kind (projectRoot itself reads null in that case) - meaning
# this field may simply default to true regardless of trust state, not a
# genuine reflection of whatever the real interactive dialog would show.
# The real dialog was never reached live (the account-auth gate in this
# environment blocks getting that far - see the header comment above), so
# this is genuinely unconfirmed, not merely attributed: if a real trust
# freeze does occur on a codex/pi-shaped first launch, the existing
# freeze-detector + crew-takeover fallback still applies, the same
# degradation any gate with no automation gets.
#
# WM_AGENT_PREFLIGHT IS wired up below, for a different gate: the portable
# crew command vocabulary. grok has no documented per-launch flag for an
# arbitrary skills directory, so ~/.grok/skills is the reconciled route, on
# every spawn/resume, exactly like claude_preflight's own guard-hook sync.
# Symlink-following is UNDOCUMENTED for grok (unlike codex, whose own docs
# confirm it) - this was a genuinely open question, hands-on verified
# rather than assumed (see the header comment above for the result);
# grok_preflight defaults to symlink mode but is ready to switch to copy
# mode (see grok_preflight's own comment) without a second round of design
# if the symlink turns out not to be followed.
WM_AGENT_PREFLIGHT=grok_preflight
# GROK_CLAUDE_AGENTS_ENABLED=0 is an ENVIRONMENT VARIABLE, not a CLI flag -
# it belongs here (composed as an env-var prefix before `exec`, exactly like
# opencode's own OPENCODE_DISABLE_PROJECT_CONFIG=true), never in
# WM_AGENT_CONTEXT_SUPPRESS_FLAG (codex's own field, issue #353): that field
# is specifically an unconditionally-appended LAUNCH ARGUMENT - routing an
# env-var assignment through it would append the literal text
# "GROK_CLAUDE_AGENTS_ENABLED=0" as a bogus positional/flag argument to
# grok's own argv, corrupting the composed brief instead of setting an
# environment variable. See this file's own header comment for what this
# toggle does and does not close.
WM_AGENT_ENV_PREFIX="GROK_CLAUDE_AGENTS_ENABLED=0"
# The orchestrator that execs every crew member is always Claude Code, so a
# non-claude crew member (grok included) would otherwise silently inherit
# CLAUDECODE=1 from it (plan §5 step 8).
WM_AGENT_ENV_UNSET="CLAUDECODE"

# --- launch capability ----------------------------------------------------
# Two bypass shapes exist (plan §3): --always-approve (a plain boolean) and
# --permission-mode bypassPermissions, described as "the stronger
# equivalent". Confirmed directly against --help: --permission-mode's own
# documented value domain is [default, acceptEdits, auto, dontAsk,
# bypassPermissions, plan] - bypassPermissions is a real, listed value, not a
# guess. Using this form (reusing claude's own template shape and $PERM_MODE
# value, matching wm_agent_emit_flag's existing %s-substitution path) rather
# than the plain boolean, on the "stronger equivalent" finding - not
# independently exercised against a live turn (auth-gated, see header), so
# this choice rests on the --help text's own wording rather than an observed
# behavioral difference.
WM_AGENT_BYPASS_FLAG="--permission-mode %s"
# "Force session ID at creation": plan §3's own firstmate-sourced finding is
# "Not found" for grok - but this repo's own --help (grok-build v1.0.0)
# shows a real `-s, --session-id <SESSION_ID>` flag documented as "Use a
# specific session UUID for a **new** conversation" (not a resume flag) -
# directly contradicting that finding. Left unset anyway, not populated on
# this discrepancy alone: not independently confirmed to actually take
# effect against a live launch (the auth gate blocked reaching a real
# session), and the plan's own settled §8 decision for every other adapter's
# unconfirmed session-id claim is to fall back to relaunch mode rather than
# risk composing a flag that silently no-ops or errors. Worth a follow-up
# hands-on pass once credentials are available - flagged here rather than
# quietly acted on.
WM_AGENT_SESSION_ID_FLAG=""
# No display-name-at-creation flag found in --help either (plan §3
# confirms: not found).
WM_AGENT_NAME_FLAG=""
WM_AGENT_REMOTE_CONTROL_FLAG=""
WM_AGENT_MODEL_FLAG="--model %s"
# Bare model id, not provider-qualified (unlike opencode) - confirmed live
# via the real ACP "initialize" response's own modelState.currentModelId
# ("grok-4.5", no provider prefix).
WM_AGENT_MODEL_VALUE_SHAPE="bare"
# --reasoning-effort (--effort is a documented alias, confirmed via --help;
# using the canonical long form). Domain corrected by the plan (§3) from an
# earlier draft that listed xhigh/max as accepted - grok 0.2.99 rejects both
# outright ("use one of: high, medium, low"). Independently reconfirmed here
# a second way, live rather than doc-derived: the real ACP "initialize"
# response (captured via --debug-file, ordinary API-key resolution succeeds
# even in this credential-less environment - the LATER account-sign-in gate
# is what blocks an actual turn, not this handshake) carries the current
# model's own reasoningEfforts array - exactly three entries, high/medium/
# low, no xhigh or max anywhere in the payload.
WM_AGENT_EFFORT_FLAG="--reasoning-effort %s"
WM_AGENT_EFFORT_VALUES="low medium high"

# --- system prompt and delivery -------------------------------------------
# flag mode: grok has a real direct flag, confirmed via --help (unlike
# codex). Two candidates exist - --rules <RULES> ("Extra rules to append to
# the system prompt") and --system-prompt-override <PROMPT> ("Override the
# agent's system prompt", alias --system-prompt). Chose --rules (append),
# matching the established precedent for every other flag-mode adapter
# (claude's --append-system-prompt, pi's --append-system-prompt) rather than
# a full replace: overriding wholesale risks stripping whatever baseline
# tool-use scaffolding grok's own default system prompt provides, a risk
# --rules does not carry. Not independently exercised against a live turn
# (auth-gated, see header) - this is a documented choice from --help's own
# wording and consistency with the rest of this schema, not a behaviorally
# confirmed one.
#
# The %s substitutes a FILE PATH, not file content (wm_agent_emit_sysprompt's
# own flag branch passes the sysprompt file's path straight through) - the
# template itself must expand it, exactly like claude.sh/pi.sh's own
# '--append-system-prompt "$(cat %s)"'. A bare "--rules %s" (this file's own
# original, broken value) would compose --rules '<path>/<id>.sysprompt.md' -
# the literal path string as the rules text, not its contents, leaving every
# grok crew member with no playbook and no status contract at all (round-1
# review of this PR, a real launch-breaking bug, reproduced end-to-end
# against the real bin/spawn-crew composition path - not a hypothetical).
WM_AGENT_SYSPROMPT_MODE=flag
WM_AGENT_SYSPROMPT_FLAG='--rules "$(cat %s)"'
WM_AGENT_SUBMIT_SETTLE=""
# grok's own slash-autocomplete popup eats the first Enter for an
# argument-taking skill command, requiring a genuine second Enter after the
# placeholder expands (plan §4.7, firstmate-sourced) - attributed, not
# independently exercised against a live composer this pass (auth-gated).
WM_AGENT_SLASH_SETTLE="1"
WM_AGENT_BUSY_MEANS_QUEUED=""
# Genuinely empty, not uncharacterized - a positive fact recorded with a
# comment, not a silent gap (plan §4.3/§4.7's own explicit requirement for
# this exact field). grok's C-c is the TURN INTERRUPT (WM_AGENT_INTERRUPT_KEY
# below), not a composer-clear keystroke; Esc moves focus to scrollback
# instead of clearing anything. Sending C-c here to "clear before typing"
# would interrupt whatever grok is doing instead, the opposite of the
# intended effect. Attributed to the plan's own firstmate-sourced research,
# not independently exercised against a live composer this pass (auth-gated).
WM_AGENT_CLEAR_KEYS=""

# --- detection --------------------------------------------------------------
# bordered shape (plan §4.6): a complete boxed composer - top border,
# side-bordered content rows, bottom border (which may carry the model name
# as a title). Attributed to the plan's own firstmate-sourced byte-level
# characterization, not independently captured from a real rendered pane
# this pass (auth-gated, see header) - the auth gate blocked reaching a live
# composer at all, unlike codex/opencode where a real pane was captured even
# without full credentials. WM_AGENT_COMPOSER_RULE_RE/ANCHOR stay unset: this
# shape has no rule-line pair for RULE_RE to describe at all (the plan's own
# §4.6 finding - bordered, left-bar, and bare shapes all find nothing with
# the current rule-line-pair extraction, confirming the whole-pane-checksum
# fallback is the correct degradation for grok, not a gap to apologize for).
WM_AGENT_COMPOSER_SHAPE=bordered
WM_AGENT_COMPOSER_RULE_RE=""
WM_AGENT_COMPOSER_ANCHOR=""
WM_AGENT_COMPOSER_ANCHOR_EMPTY=""
# Genuinely unknown: no freeze-dialog text signature was captured this pass
# (auth-gated - never reached a live composer or permission prompt).
WM_AGENT_PERM_PROMPT_RE=""
WM_AGENT_PERM_OPTION_RE=""
WM_AGENT_PERM_LEAD_RE=""
WM_AGENT_RESUME_PROMPT_RE=""

# --- resume, lifecycle, and verification -----------------------------------
# grok has real resume subcommands (`--resume <id>` / `-c/--continue` /
# `--fork-session`, confirmed against --help), but per the plan's own settled
# §8 decision this is not wired as WM_AGENT_RESUME_FLAG: no confirmed way to
# FORCE a specific session id at creation time (the --session-id discrepancy
# noted above is flagged, not acted on), so wingman has no id to hand this
# flag at relaunch time regardless of the resume subcommand existing -
# relaunch mode stands in, the same settled precedent as pi/opencode/codex's
# own §8 decision, not re-litigated here.
WM_AGENT_RESUME_FLAG=""
WM_AGENT_GUARD_TRANSPORT=grok-json
# No fleet-continuity transport is built for grok (the orchestrator-guard-
# transports plan, §5.5/§10) - documented "not built", not "impossible" -
# see pi.sh's own field for the fuller reasoning; grok's own primitives were
# not probed at all this pass (plan §3.2's own honest labeling), unlike
# pi's.
WM_AGENT_CONTINUITY_TRANSPORT=""
# GROK_CLAUDE_HOOKS_ENABLED=0 is an ENVIRONMENT VARIABLE the orchestrator's
# own launch needs (plan §3.4's hazard, §5.6): this repo's checked-in
# .claude/settings.json registers Claude-dialect hooks that would silently
# read absent under grok's own camelCase payload and allow every call.
# Delivered via WM_AGENT_GUARD_ENV (applied by bin/wingman's own
# wm_agent_apply_guard_env, never WM_AGENT_ENV_PREFIX above, which
# bin/wingman does not apply at all - plan §2.2/§5.6) - a SEPARATE field
# from that one, not an addition to it, since WM_AGENT_ENV_PREFIX carries
# crew-side settings (this file's own GROK_CLAUDE_AGENTS_ENABLED=0) that
# have nothing to do with the guard transport specifically.
WM_AGENT_GUARD_ENV="GROK_CLAUDE_HOOKS_ENABLED=0"
# grok's own project-scope trust gate (--trust/grok inspect --json
# projectTrusted) governs <project>/.grok/hooks/*.json only - this plan
# installs personal scope only ($HOME/.grok/hooks/wingman.json, plan §5.7),
# which grok's own docs state carries no trust requirement at all (plan
# §3.4), so no --trust flag belongs here.
WM_AGENT_GUARD_LAUNCH_FLAGS=""
# Not 1: this stage installed real grok-build v1.0.4 (npm @xai-official/grok,
# via a user-prefix npm install - the plan's own research pass never had it
# installed) and confirmed several things hands-on that the plan's own
# research left attributed: `grok inspect --json` genuinely reports a
# "hooks" array reading this MACHINE's real Claude-dialect user-scope
# registrations, each carrying `vendor: "claude"`; setting
# GROK_CLAUDE_HOOKS_ENABLED=0 flips every one of them from
# compatibilityStatus "enabled" to "disabled" in that same output (a live
# diff, not source-reading) - direct, repeatable confirmation of the exact
# mechanism this file's own WM_AGENT_GUARD_ENV comment describes; and a
# rendered bin/lib/sync-grok-hooks.py wingman.json placed under a scratch
# $HOME/.grok/hooks/ is genuinely discovered by `grok inspect --json` as a
# native (vendor: none, no compatibilityStatus/trust gate at all) hook entry
# - confirming plan §3.4's "personal hooks carry no trust requirement"
# finding directly rather than by documentation alone. `grok login` was
# also confirmed live to hang on an interactive OAuth flow with no
# credential-based escape (10s timeout, no prompt reachable non-
# interactively) - the account-level auth gate is real and not this
# environment's own artifact. What remains unreached: an actual model turn
# (blocked by that same auth gate), so the two things §7's hands-on gate
# still needs - the deny fixture genuinely blocking a live tool call, and
# the allow fixture's tool call genuinely executing - are not yet done.
WM_AGENT_VERIFIED=0

# --- control values (B3) ----------------------------------------------------
# Attributed to the plan's own firstmate-sourced research (§4.3's B3 table) -
# none of these were independently exercised against a live composer this
# pass (auth-gated, see header).
WM_AGENT_EXIT_CMD="/exit"
WM_AGENT_INTERRUPT_KEY="C-c"
WM_AGENT_INTERRUPT_REPEAT=1
WM_AGENT_POST_INTERRUPT_CLEAR=""
WM_AGENT_SKILL_FORM="/<skill>"

# grok_preflight <repo> <perm_mode> [<action>]
#
# Reconciles ~/.grok/skills against this repo's own canonical
# .agents/skills/ tree (bin/lib/sync-user-skills.py) - grok's own dedicated
# user-level skills directory, preferred over editing `[skills] paths` in
# ~/.grok/config.toml (harder to make idempotent and to reverse than named
# symlinks). <repo>/<perm_mode> are unused (this gate has nothing to do
# with the target repo or the permission mode) but accepted for a uniform
# call signature with every other WM_AGENT_PREFLIGHT function.
#
# Mode defaults to symlink; switch WM_GROK_SKILLS_SYNC_MODE=copy if hands-on
# verification shows grok does not follow a symlinked skill directory -
# grok's own docs, unlike codex's, say nothing about symlinks either way,
# so this is a gated assumption, not a confirmed one.
#
# WM_GROK_USER_SKILLS_DIR overrides the target directory (test isolation,
# mirrors claude_preflight's WM_CLAUDE_USER_SETTINGS/WM_CLAUDE_USER_CONFIG
# convention) - a test suite run must never write into a real developer's
# actual ~/.grok/skills.
grok_preflight() {
  _grp_action="${3:-spawn}"
  if ! _grp_err="$(uv run --no-project --quiet "$WM_LIB/sync-user-skills.py" \
      --target "${WM_GROK_USER_SKILLS_DIR:-$HOME/.grok/skills}" --repo "$WM_REPO" \
      --mode "${WM_GROK_SKILLS_SYNC_MODE:-symlink}" 2>&1)"; then
    wm_launch_failure "grok skills sync ($_grp_action)" "$_grp_err"
    wm_die "could not reconcile grok's user-level skills directory (~/.grok/skills): $_grp_err
Fix the reported problem, or run 'bin/doctor -y', then retry this $_grp_action."
  fi
  unset _grp_action _grp_err
  return 0
}
