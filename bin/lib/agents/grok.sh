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
# docs/plans/2026-08-11-issue-25-multi-cli-agent-adapter-implementation-plan.md
# §3/§4.3/§4.6/§4.7/§5 step 8 for the full research and schema this
# descriptor implements, and bin/lib/agents/claude.sh for the field-by-field
# schema reference this file follows.
#
# Sourced by wm_agent_resolve (bin/lib/agent.sh), which has already sourced
# bin/lib/common.sh.
#
# *** AGENTS.md double-injection note (issue #353's own accepted residual) ***
# grok auto-loads a repo-root AGENTS.md for repo-level instructions - hands-on
# confirmed live via `grok inspect --json` (`projectInstructions` lists the
# discovered file). Unlike codex, grok has no confirmed way to fully suppress
# this discovery (no equivalent of codex's project_doc_max_bytes=0): setting
# GROK_CLAUDE_AGENTS_ENABLED=0 (below) is worth doing anyway, purely to avoid
# the SAME content being injected twice under two recognized filenames (grok
# separately auto-loads CLAUDE.md too, hands-on confirmed the same way) - but
# it does NOT close the underlying gap the way codex's flag does. This is
# issue #353's own explicitly accepted residual for grok, not a gap
# introduced here; a grok crew member's repo-level context still includes
# whatever AGENTS.md/CLAUDE.md this repo carries, on top of this descriptor's
# own composed brief (delivered via a direct flag, WM_AGENT_SYSPROMPT_FLAG
# below, not a positional argument) - both reach the model, for now
# unavoidably.
#
# Hands-on verified (2026-08-13) against real grok-build v1.0.0, but
# LESS THAN the other three adapters: grok's own headless (`-p`) and
# interactive TUI login paths both required a genuine grok.com OAuth
# round-trip that could not be completed in this credential-less
# environment (confirmed via --debug-file: a fake XAI_API_KEY successfully
# resolves as model-API credentials and the CLI completes a real ACP
# "initialize" handshake with the real xAI backend - but sending an actual
# turn is gated behind a SEPARATE grok.com account sign-in this environment
# has no way to satisfy, unlike codex where any string got past onboarding).
# What COULD be verified hands-on without that gate: the full `--help` flag
# surface (used directly below, not doc-derived), `grok inspect --json`'s
# live confirmation that a git-worktree launch is trusted immediately with
# no dialog (`"projectTrusted": true` on first read, no prompt shown - the
# plan's own positive finding, independently reconfirmed) and that AGENTS.md/
# CLAUDE.md are both discovered, `grok doctor`'s environment probe (no auth
# needed), and - via the real ACP "initialize" response captured over
# --debug-file - a live, protocol-level confirmation that only low/medium/
# high reasoning-effort levels exist for the current model (xhigh/max never
# appear in the response's own reasoningEfforts array), independently
# reconfirming the plan's own firstmate-sourced finding a third way (source
# reading, --help text, and now a live protocol response all agree). NOT
# verified live: the bordered composer's exact glyphs/anchor (attributed to
# the plan's own firstmate-sourced research, §4.6 - never independently
# captured from a real rendered pane), whether --rules vs
# --system-prompt-override actually composes the way each flag's --help text
# describes, GROK_CLAUDE_AGENTS_ENABLED's real effect (tested via `grok
# inspect --json` with and without it set - no observable difference in
# projectInstructions either way, so unlike codex's own capture-server proof,
# this could NOT be confirmed to work, only confirmed not to break anything;
# inspect may simply not reflect this toggle at all, since it appears to be a
# static discovery listing rather than a report of what actually gets
# injected - a real open question, not silently assumed resolved), exit
# command/interrupt key/skill form (attributed, not independently exercised
# against a live composer).
#
# GROK_CLAUDE_AGENTS_ENABLED=0's own value: confirmed to exist as a real,
# non-fabricated config key by reading the compiled binary directly (`strings`
# on the decompressed binary shows the full GROK_CLAUDE_{SKILLS,RULES,AGENTS,
# MCPS,HOOKS,SESSIONS}_ENABLED family, alongside matching GROK_CURSOR_* and
# GROK_CODEX_* families) - not fabricated, but also not proven to do what
# issue #353 assumes (see above).

WM_AGENT_BIN=grok
WM_AGENT_DISPLAY_NAME="grok"

# --- preflight and environment ------------------------------------------
# No preflight function needed - a POSITIVE finding, not an oversight (plan
# §3): grok's own project-picker/trust dialog appears only when launched from
# a non-project directory. wingman always launches into a git worktree, and
# `grok inspect --json` there hands-on confirmed "projectTrusted": true
# immediately, with projectInstructions already populated, no dialog and no
# prompt shown at all. Nothing for a preflight function to gate.
WM_AGENT_PREFLIGHT=""
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
WM_AGENT_SYSPROMPT_MODE=flag
WM_AGENT_SYSPROMPT_FLAG="--rules %s"
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
# Not 1: hands-on verification this stage confirmed the --help flag surface,
# trust-dialog absence in a worktree, AGENTS.md/CLAUDE.md discovery, and the
# reasoning-effort domain live via a real ACP handshake - but never reached a
# live composer, an actual model turn, or the grok-json guard-transport shim
# itself (held, plan step 12c, not yet built), all blocked by grok's own
# account-level auth gate in this credential-less environment.
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
