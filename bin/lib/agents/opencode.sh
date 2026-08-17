# bin/lib/agents/opencode.sh - the opencode agent descriptor (issue #25).
#
# opencode (npm opencode-ai, binary `opencode`) is the second non-claude
# adapter (plan §8's build order: pi, then opencode, then codex, then
# grok). Exercises the prompt-flag system-prompt path and an env-var
# permission bypass (WM_AGENT_ENV_PREFIX) - see
# issue #25 for the full research and schema this
# descriptor implements, and bin/lib/agents/claude.sh for the field-by-field
# schema reference this file follows.
#
# Sourced by wm_agent_resolve (bin/lib/agent.sh), which has already sourced
# bin/lib/common.sh.
#
# Hands-on verified (2026-08-13) against real opencode v1.18.17, launched in
# a live tmux pane. Unlike pi and claude, this environment has NO configured
# provider credentials but opencode ships a free default model ("Big
# Pickle") that works out of the box - this made a genuinely live model turn
# possible, not just launch-time behavior. Confirmed live: the
# OPENCODE_CONFIG_CONTENT env-var bypass (no permission dialog appeared with
# it set; --auto exists as a direct flag too - per the plan's own §3
# finding this is deliberately NOT used here, since it is documented as
# weaker than the env-var's full wildcard allow), the left-bar composer
# shape (a heavy "┃" left bar, no closing rule line wingman's own
# rule-based extraction would ever match - confirmed the composer correctly
# finds nothing and falls through to the whole-pane-checksum path),
# --prompt delivering the first message correctly, --model composing
# without error, Ctrl-C clearing without exiting, and `/exit` cleanly
# exiting. Also confirmed live, end to end, that opencode genuinely does
# queue a message sent mid-turn rather than reject or lose it: sent a
# second message while a first turn was still generating, watched it
# render with an explicit "QUEUED" label directly under it, then watched
# it get processed automatically the moment the first turn finished, with
# the model itself acknowledging the queued instruction. WM_AGENT_BUSY_
# MEANS_QUEUED itself stays unset below despite this confirmed fact - see
# that field's own comment for why setting it would currently be inert.
# Also confirmed live that a single Escape does not interrupt
# outright - the status bar changes to "esc again to interrupt", a genuine
# confirm step - consistent with the plan's own WM_AGENT_INTERRUPT_REPEAT
# note; no current code in this repo consumes WM_AGENT_INTERRUPT_KEY/
# _REPEAT yet (grepped bin/ and hooks/), so this is recorded for whichever
# future consumer needs it rather than exhaustively pinned down here. No
# trust/permission dialog was observed on first run across three separate
# fresh launches in this session, consistent with the plan's own "not
# previously noted" (unconfirmed, not confirmed-absent) status - so no
# WM_AGENT_PREFLIGHT is set; revisit if a future launch does hit one. NOT
# verified live: an actual working --model switch to a real paid provider
# (no credentials in this environment to confirm the flag actually changes
# which model answers, only that it doesn't error), and tool-call
# permission-prompt behavior beyond the blanket OPENCODE_CONFIG_CONTENT
# allow already covering it.
#
# Separately (2026-08-17, the portable crew command vocabulary): the
# OPENCODE_CONFIG_DIR route (WM_AGENT_ENV_PREFIX below) is hands-on
# verified live against real opencode v1.18.18, settling a genuinely open
# question decisively - two independent checks, both from an unrelated cwd:
# `opencode debug skill` listed all seven wingman-<verb> skills additively
# alongside opencode's own built-in skill, each `location` pointing at the
# real file under this repo's own .agents/skills/; and a genuine
# non-interactive model turn (`opencode run`, the free "Big Pickle" default
# model, no paid credentials needed) asked to name every skill starting
# with "wingman-" replied with the exact seven names, comma-separated -
# proof the model itself can see and could invoke them, not merely that the
# CLI's own debug tooling discovers the files.

WM_AGENT_BIN=opencode
WM_AGENT_DISPLAY_NAME="opencode"

# --- preflight and environment ------------------------------------------
# No preflight function: no trust/permission dialog was observed on first
# run in this session (see the file header) - if a future launch (a
# different opencode version, a different environment) does hit one, this
# needs revisiting, the same way pi's own env-unset comment reasons.
#
# Also, deliberately, no home-directory skills install (unlike codex/grok's
# own preflight-time installer, bin/lib/sync-user-skills.py): the
# per-launch OPENCODE_CONFIG_DIR route below (WM_AGENT_ENV_PREFIX) is
# strictly better once it is known to work - it composes with the existing
# WM_AGENT_ENV_PREFIX and leaves the operator's home directory untouched
# entirely, and hands-on verification (see the file header) confirms it does.
WM_AGENT_PREFLIGHT=""
# Two env vars, composed together:
#
# OPENCODE_CONFIG_CONTENT sets a full wildcard permission allow - verified
# live: no permission dialog appeared with this set, across every launch in
# this session's verification pass. The double-quotes inside are escaped so
# the assignment below evaluates (once this descriptor is sourced) to the
# literal shell text OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' -
# a single-quoted JSON value bin/spawn-crew's own composed launch script
# later re-parses as an ordinary env-var assignment ahead of the exec
# target, exactly like the plan's own example invocation.
#
# OPENCODE_CONFIG_DIR is opencode's own "load this directory just like
# .opencode/" escape hatch (opencode's own built-in customize-opencode
# skill, read directly via `opencode debug skill`) - pointed at this repo's
# own .agents/ directory (the PARENT of .agents/skills/, not skills/
# itself: OPENCODE_CONFIG_DIR expects a `skills/<name>/SKILL.md` structure
# underneath it, and .agents/ already has exactly that shape). Hands-on
# verified live against real opencode v1.18.18 (`opencode debug skill` from
# an unrelated cwd, both baseline and with OPENCODE_CONFIG_DIR set): all
# seven wingman-<verb> skills appear, additively alongside opencode's own
# built-in skill, each with `location` pointing at the real file under this
# repo's own .agents/skills/ - no copy, no symlink, no home-directory
# install of any kind. $WM_REPO is already resolved (common.sh runs before
# any descriptor is sourced) and quoted once, here, at descriptor-source
# time - not left as a literal $WM_REPO for the launch script's own shell to
# re-expand, since nothing guarantees that variable is set in the launched
# process's environment.
WM_AGENT_ENV_PREFIX="OPENCODE_CONFIG_DIR=$(quote "$WM_REPO/.agents") OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}'"
# The orchestrator that execs every crew member is always Claude Code, so a
# non-claude crew member (opencode included) would otherwise silently
# inherit CLAUDECODE=1 from it (plan §5 step 8).
WM_AGENT_ENV_UNSET="CLAUDECODE"
#
# *** No repo-doc-context suppression flag (investigated, not a gap) ***
# Unlike pi's --no-context-files (bin/lib/agents/pi.sh) or codex's own
# -c project_doc_max_bytes=0, opencode has no narrow, dedicated flag that
# suppresses AGENTS.md/CLAUDE.md discovery without unrelated collateral, so
# WM_AGENT_CONTEXT_SUPPRESS_FLAG is left unset (its schema default) -
# deliberately, not because this wasn't investigated.
#
# Two real env-var levers exist in the real opencode v1.18.17 binary
# (extracted directly from its own bundled source, since there is no public
# opencode --help line for either), and neither is a safe fit:
#
# - OPENCODE_DISABLE_CLAUDE_CODE_PROMPT / OPENCODE_DISABLE_CLAUDE_CODE
#   (source: disableClaudeCodePrompt) removes CLAUDE.md from opencode's own
#   discovery filename list and removes the operator's own global
#   ~/.claude/CLAUDE.md from its global-path list - but does NOT touch
#   AGENTS.md at all, and opencode's own discovery walk checks AGENTS.md
#   first and stops at the first filename with a match, so this repo's root
#   AGENTS.md is never even reached. Live-verified: with this var set and
#   only an AGENTS.md marker file present, the marker still reached the
#   model. A real mechanism, but not one for this problem.
#
# - OPENCODE_DISABLE_PROJECT_CONFIG=1 does suppress the whole AGENTS.md/
#   CLAUDE.md/CONTEXT.md discovery walk (confirmed directly in source: the
#   entire walk is wrapped in `if(!Jr.OPENCODE_DISABLE_PROJECT_CONFIG)`) and
#   was live-verified via the same marker-token method (the marker was
#   visible without it, absent with it) - but per opencode's own documented
#   purpose for this variable ("skip the project's local opencode.json and
#   start from globals only" - an escape hatch for a broken config file, not
#   an instructions-suppression feature), it ALSO disables the project's
#   own local opencode.json/.opencode directory entirely: its own
#   "instructions" config-key additions, local plugins, and local agents.
#   Live-verified: a project opencode.json with "instructions":
#   ["EXTRA.md"] was honored without the flag and silently dropped with it.
#   Setting this unconditionally for every opencode crew launch would
#   silently disable all project-local opencode configuration, forever, for
#   every opencode crew member - a functional regression far wider than
#   "stop loading the orchestrator-voiced root doc," not something worth
#   trading for that.
#
# No other OPENCODE_* env var (85 distinct names extracted from the binary)
# does anything narrower, and no flag on the base launch command (opencode
# --help) touches this at all. Conclusion: opencode is handled exactly like
# grok - the disclaimer composed into every crew member's own brief stays
# its only protection here - documented so a future reader (or a future
# opencode version that ships a real narrow flag) does not have to re-run
# this investigation from scratch.

# --- launch capability ----------------------------------------------------
# No confirmed bypass FLAG (the bypass is the env-var prefix above) - a
# separate WM_AGENT_BYPASS_FLAG would be redundant with WM_AGENT_ENV_PREFIX
# and PERM_MODE's own claude-specific value ("bypassPermissions") has no
# meaning to opencode, so this stays empty rather than composing a
# meaningless flag.
WM_AGENT_BYPASS_FLAG=""
# "Force session ID at creation": plan §3 finding is "Not found" for
# opencode - left empty, matching pi's own settled precedent (relaunch
# mode stands in, §4.8), not re-litigated here.
WM_AGENT_SESSION_ID_FLAG=""
# --title exists but is confirmed only on the `run` (one-shot) subcommand,
# not the interactive launch path wingman actually uses (plan §3's
# "Display/session name" row) - confirmed directly against --help output
# for the default (no subcommand) launch, which has no --title/-t at all.
# Left empty rather than composing a flag opencode would reject.
WM_AGENT_NAME_FLAG=""
WM_AGENT_REMOTE_CONTROL_FLAG=""
WM_AGENT_MODEL_FLAG="--model %s"
WM_AGENT_MODEL_VALUE_SHAPE="provider/model"
# Reasoning effort: --variant exists but, like --title, only on the `run`
# subcommand per plan §3 - the interactive launch path has no effort flag
# at all. Left empty rather than composing a flag that would be silently
# ignored or rejected on the launch shape wingman actually uses.
WM_AGENT_EFFORT_FLAG=""
WM_AGENT_EFFORT_VALUES=""

# --- system prompt and delivery -------------------------------------------
# prompt-flag, not positional (plan §4.5): opencode's own fallback chain
# for "no system prompt supplied" walks AGENTS.md -> CLAUDE.md upward, then
# ~/.config/opencode/AGENTS.md, then ~/.claude/CLAUDE.md - the last of
# which is a genuine privacy hazard (the OPERATOR's own personal Claude
# Code instructions, not even this repo's, sent to whatever provider
# opencode is configured against). --prompt must always be supplied to
# keep that fallback chain from ever being reached, not merely to deliver
# the brief. Verified live: --prompt correctly delivered the brief as the
# first turn's message.
WM_AGENT_SYSPROMPT_MODE=prompt-flag
WM_AGENT_SYSPROMPT_FLAG="--prompt %s"
WM_AGENT_SUBMIT_SETTLE=""
WM_AGENT_SLASH_SETTLE=""
# Verified live, end to end, that the underlying FACT this field is meant
# to describe is real: a second message sent while a first turn was still
# generating rendered with an explicit "QUEUED" label beneath it (not
# swallowed, not rejected) and was automatically processed - with the
# model itself acknowledging the queued instruction - the instant the
# first turn finished.
#
# Left UNSET here despite that (round-2 review of PR #350, must-fix):
# WM_AGENT_BUSY_MEANS_QUEUED is not consumed by any code in this repo yet
# (grepped bin/ and hooks/ directly - nothing reads it outside
# WM_AGENT_FIELDS's own declaration), and even once a consumer exists, the
# specific outcome it is documented to reinterpret - rc 5, "unconfirmed
# AND the pane was busy" - can only ever be produced by composer mode's
# own sticky-busy tracking inside _wm_tmux_send_message_locked
# (bin/lib/common.sh). This descriptor's own WM_AGENT_COMPOSER_RULE_RE/
# ANCHOR stay unset below (opencode's left-bar shape has no rule line
# wingman's extraction can recognize at all), which keeps every send on
# the whole-pane-checksum fallback path - and that path "can still only
# ever return 0 or 3" (common.sh's own doc comment), never 5. Setting
# this field to 1 here would describe a real fact about opencode with no
# way to ever take effect, given this file's OTHER, also-correct
# decision - two settings that silently cancel each other out rather
# than one coherent story. Revisit together if a future change either
# builds a real composer-mode-equivalent confirm path for opencode's own
# shape, or teaches the fallback path its own busy-reinterpretation.
WM_AGENT_BUSY_MEANS_QUEUED=""
# Verified live: a single Ctrl-C clears the composer's current text without
# exiting.
WM_AGENT_CLEAR_KEYS="C-c"

# --- detection --------------------------------------------------------------
# Verified live: opencode's composer renders as a heavy "┃" left bar
# prefixing each row (the idle hint, blank rows, a mode/model footer line),
# closed at the bottom by a row of "▀" (U+2580, upper half block) - never
# wingman's own "─" (U+2500) rule character - so wm_composer_text_in
# correctly finds no rule-line pair here and falls straight through to the
# pre-existing whole-pane-checksum confirm path, exactly the plan's own
# §4.6 prediction ("will find nothing with the current extraction rule").
# RULE_RE/ANCHOR stay unset - there is no rule-line shape here for either
# to describe, unlike pi's separated shape which merely lacked a
# characterized anchor.
WM_AGENT_COMPOSER_SHAPE=left-bar
WM_AGENT_COMPOSER_RULE_RE=""
WM_AGENT_COMPOSER_ANCHOR=""
WM_AGENT_COMPOSER_ANCHOR_EMPTY=""
# Genuinely unknown (plan §3): opencode does have a real permission system
# (unlike pi), but its own dialog/prompt text was not captured this pass -
# the env-var bypass above means wingman-launched crew members should never
# actually hit it in practice, so this stays "not yet characterized" rather
# than guessed.
WM_AGENT_PERM_PROMPT_RE=""
WM_AGENT_PERM_OPTION_RE=""
WM_AGENT_PERM_LEAD_RE=""
WM_AGENT_RESUME_PROMPT_RE=""

# --- resume, lifecycle, and verification -----------------------------------
# No verified pane-resume contract (plan §3): --continue/-c, --session/-s,
# and --fork all exist, but none is confirmed as a genuine force-session-
# id-at-creation mechanism (opencode's --session/-s is explicitly flagged
# "not found... as resume-only", unconfirmed either way) - relaunch mode
# stands in, the same settled precedent as pi and claude's own §8 decision,
# not re-litigated here.
WM_AGENT_RESUME_FLAG=""
WM_AGENT_GUARD_TRANSPORT=opencode-plugin
# Not yet 1: hands-on verification this stage confirmed launch-time
# behavior, the busy/queued mechanism end-to-end, and control values, but
# not an actual paid-provider model turn (no credentials in this
# environment beyond the free default model) or the opencode-plugin
# guard-transport shim itself (held, plan step 12b-12f, not yet built).
WM_AGENT_VERIFIED=0

# --- control values (B3) ----------------------------------------------------
WM_AGENT_EXIT_CMD="/exit"
WM_AGENT_INTERRUPT_KEY="Escape"
# Verified live: a single Escape does not interrupt outright - the status
# bar changes to "esc again to interrupt", a genuine two-step confirm.
WM_AGENT_INTERRUPT_REPEAT=2
WM_AGENT_POST_INTERRUPT_CLEAR=""
# Not confirmed either way this pass - opencode's own --agent flag selects
# between its OWN internal named agents/personas (a different concept from
# wingman's own adapter selection, confirmed distinct via --help), not an
# in-session skill-invocation syntax comparable to claude's "/<skill>" or
# codex's "$<skill>". Left unset rather than assumed.
WM_AGENT_SKILL_FORM=""
