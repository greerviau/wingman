# bin/lib/agents/pi.sh - the pi agent descriptor (issue #25).
#
# pi (npm @earendil-works/pi-coding-agent, binary `pi`) is the first
# non-claude adapter (plan §8's build order: pi, then opencode, codex,
# grok), chosen lowest-risk for two independent reasons the plan lays out
# (§4.5/§4.6): a direct flag-mode system-prompt path, and a composer shape
# that already matches wingman's existing extraction rule. See
# issue #25 for the full research and schema this
# descriptor implements, and bin/lib/agents/claude.sh for the field-by-field
# schema reference this file follows.
#
# Sourced by wm_agent_resolve (bin/lib/agent.sh), which has already sourced
# bin/lib/common.sh.
#
# Hands-on verified (2026-08-12) against real pi v0.84.1, launched in a live
# tmux pane with no API credentials configured (this environment has none) -
# see this stage's PR description for the full verification log. Confirmed
# live: the --approve bypass flag (dialog appears without it whenever
# project-local resources like .agents/skills exist, and is cleanly skipped
# with it - see WM_AGENT_BYPASS_FLAG below), the composer's separated shape,
# its exact rule character, AND its byte-exact empty anchor (a genuinely
# blank content row, confirmed against a real post-submit pane - see
# WM_AGENT_COMPOSER_ANCHOR below), --append-system-prompt accepting literal
# text without error, --model/--thinking/--name composing and rendering
# correctly together in the status bar, Escape/Ctrl-C/`/quit` control
# values, and --offline/--no-session hygiene. Also confirmed live: a real
# submit against a pane with no configured provider still registers locally
# (composer clears, a new error line appears in the transcript above it) -
# proof the whole-pane-checksum fallback path genuinely detects this case,
# not merely that the code takes that branch. NOT verified live (no
# credentials in this environment): an actual successful model turn, so
# tool-call permission-prompt behavior and busy-queue behavior remain
# unconfirmed and stay at their documented degrade defaults below.
#
# Separately (2026-08-17): WM_AGENT_CONTEXT_SUPPRESS_FLAG's suppression of
# AGENTS.md/CLAUDE.md auto-loading was live-verified via real model turns
# against a real provider credential (openai-codex) - the marker text was
# absent from what the model could see with the flag set and present
# without it, confirmed across both filenames and both flag spellings - see
# that field's own comment below for the exact method and result.
#
# Separately (2026-08-17, portable crew command vocabulary): WM_AGENT_SKILLS_
# FLAG/WM_AGENT_SKILL_FORM below are live-verified against real pi v0.84.1
# in a tmux pane, launched with --offline --no-session --no-context-files
# --skill <this repo>/.agents/skills --no-approve from an UNRELATED cwd
# (/tmp, not this repo) - confirming the flag's cwd-independence directly,
# not just its documented behavior. The startup banner listed all seven
# skills under [Skills]: wingman-ask, wingman-blocked, wingman-prune,
# wingman-say, wingman-status, wingman-takeover, wingman-watch. Typing
# "/skill:wingman-sta" rendered the autocomplete entry "→ skill:wingman-
# status [t] Show the current crew roster (who is on what, what is blocked,
# what is ready)" - the exact description from wingman-status/SKILL.md,
# confirming both the invocation form and that pi reads the file's real
# frontmatter, not a stale/cached copy.

WM_AGENT_BIN=pi
WM_AGENT_DISPLAY_NAME="pi"

# --- preflight and environment ------------------------------------------
# No preflight function: unlike claude's workspace-trust dialog (which has
# no flag-based bypass and must be automated via claude-gate-check.py), pi's
# own project-trust dialog is fully avoidable with a plain launch flag - see
# WM_AGENT_BYPASS_FLAG below - so there is no separate gate left to wrap.
#
# Also, deliberately, no home-directory skills install (unlike codex/grok/
# opencode's own preflight-time installer, bin/lib/sync-user-skills.py):
# WM_AGENT_SKILLS_FLAG below is a complete per-launch route on its own, and
# installing pi's own link set on top of it would be actively worse than
# useless - pi reads ~/.agents/skills/ as a global location in ADDITION to
# every --skill path, so the same seven wingman-<verb> names would be
# discovered twice. Once codex is served from ~/.agents/skills/ (its own
# only cwd-independent location), pi sees the same seven names from both
# that directory and its --skill path regardless of anything this
# descriptor does - a startup warning per name ("Name collisions... warn and
# keep the first skill found", pi's own shipped docs), cosmetic and provably
# so: both discoveries resolve to the identical file through the identical
# symlink, so "keep the first found" can never pick different content.
WM_AGENT_PREFLIGHT=""
WM_AGENT_ENV_PREFIX=""
# The orchestrator that execs every crew member is always Claude Code, so a
# non-claude crew member (pi included) would otherwise silently inherit
# CLAUDECODE=1 from it (plan §5 step 8's explicit instruction: unset this
# for every non-claude adapter).
WM_AGENT_ENV_UNSET="CLAUDECODE"
# Repo-doc-context suppression: --no-context-files (-nc, pi --help) is pi's
# own dedicated flag for exactly this - not a repurposed generic option the
# way codex's -c project_doc_max_bytes=0 is, so there is no cross-adapter
# subtlety to record here. pi's own --help text names both AGENTS.md and
# CLAUDE.md explicitly as what it disables. Live-verified against real pi
# v0.84.1 with a real provider credential (openai-codex): a scratch repo's
# AGENTS.md (and, separately, its CLAUDE.md with no AGENTS.md present) each
# held a unique marker token, and pi was asked (-p, non-interactively) to
# report any MARKER-prefixed token visible in its own system prompt or
# project context. Without the flag, the marker was echoed back in both
# cases (the file was loaded); with --no-context-files, and separately with
# its short form -nc, the marker was absent in both cases (the file was
# suppressed) - a genuine model-turn-level proof, not merely a check that
# the flag appears in argv, exercised across both filenames and both flag
# spellings.
WM_AGENT_CONTEXT_SUPPRESS_FLAG="--no-context-files"

# --- launch capability ----------------------------------------------------
# --approve ("Trust project-local files for this run", pi --help) is a bare
# boolean flag with no value of its own - the template below has no %s, so
# wm_agent_emit_flag's printf-format substitution just prints it literally
# whenever $PERM_MODE is non-empty (its own default), which is every launch
# unless an operator explicitly blanks WM_PERMISSION_MODE. Verified live:
# with a project-local .agents/skills present, pi blocks on an interactive
# "Trust project folder?" dialog without this flag, and launches straight
# through to the composer with it - the exact freeze this flag exists to
# prevent (plan §4.3's "bypass permission prompts" contract), even though
# pi's own permission MODEL is unrelated to claude's (pi has no per-tool
# permission-bypass mode at all - confirmed absent by design, per the
# plan's §3 finding - this flag is about the project-trust gate, not tool
# permissions).
WM_AGENT_BYPASS_FLAG="--approve"
# "Force session ID at creation": the plan's §3 finding records this as
# "not found" for pi despite --session-id appearing in --help, and that
# finding stays authoritative here (no re-litigating a settled plan
# decision). Left empty as documented. NOTE for a future revisit: a live
# hands-on launch with --session-id <id> in this environment printed
# `Warning: No project session found with id '<id>'; creating a new
# session with that id.` - direct evidence the flag does something at
# creation time - but no session file was ever observed on disk afterward
# (no credentials here to drive a real turn that would flush one), so
# this remains short of the full round-trip confirmation the plan's
# stricter "not found" conclusion was presumably after. Reported to the
# lead alongside this PR rather than acted on unilaterally.
WM_AGENT_SESSION_ID_FLAG=""
WM_AGENT_NAME_FLAG="--name %s"
WM_AGENT_REMOTE_CONTROL_FLAG=""
WM_AGENT_MODEL_FLAG="--model %s"
WM_AGENT_MODEL_VALUE_SHAPE="bare"
WM_AGENT_EFFORT_FLAG="--thinking %s"
# Full domain confirmed live (pi --help and a live --thinking high launch,
# reflected correctly in the status bar): off, minimal, low, medium, high,
# xhigh, max.
WM_AGENT_EFFORT_VALUES="off minimal low medium high xhigh max"

# --- system prompt and delivery -------------------------------------------
WM_AGENT_SYSPROMPT_MODE=flag
# Same shape as claude's own: wingman reads the sysprompt file itself and
# passes its literal content as --append-system-prompt's argument, rather
# than relying on pi's own "text or file contents" auto-detection (pi
# --help) for a path it may or may not treat specially. Verified live that
# --append-system-prompt accepts a literal multi-word string with no error.
WM_AGENT_SYSPROMPT_FLAG='--append-system-prompt "$(cat %s)"'
WM_AGENT_SUBMIT_SETTLE=""
WM_AGENT_SLASH_SETTLE=""
# Not yet characterized: pi has a distinct "alt+enter to queue follow-up"
# keybinding (confirmed live via its own expanded keybinding panel),
# implying a plain Enter submitted while pi is mid-turn may not simply
# auto-queue the same way - unconfirmed without a live model turn, so this
# stays at its safe "not yet characterized" default rather than guessing.
WM_AGENT_BUSY_MEANS_QUEUED=""
# Verified live: a single Ctrl-C clears the composer's current text without
# exiting (pi's own expanded keybinding panel: "ctrl+c to clear" as
# distinct from "ctrl+c twice to exit" - wingman only ever sends one).
WM_AGENT_CLEAR_KEYS="C-c"

# --- detection --------------------------------------------------------------
# Verified live: pi's composer renders as content rows strictly between two
# solid horizontal rule lines, no glyph or border on the content row itself
# - exactly the plan's §4.6 "separated" shape, and its rule character (U+2500
# "─", repeated far past WM_COMPOSER_RULE_MIN) is byte-identical to
# common.sh's own $WM_COMPOSER_RULE_CHAR, so WM_AGENT_COMPOSER_RULE_RE reuses
# the shared ambient pattern directly rather than duplicating it.
#
# The anchor itself is now live-verified too (issue #25 stage 4, PR #348,
# review follow-up): sent a real message against a live pi pane (--offline,
# --approve, no provider credentials configured) and captured the composer
# region immediately after Enter, once the local submit had genuinely
# registered (confirmed by a new "Error: No API key found..." line appearing
# in the transcript above it) - the emptied content row is a literal,
# zero-byte blank line, not a glyph of any kind. WM_AGENT_COMPOSER_ANCHOR=""
# is that real, confirmed value, not an unset placeholder - distinguished
# from "not yet characterized" via WM_AGENT_COMPOSER_ANCHOR_EMPTY=1 (see
# common.sh's own comment on this field). Only the PRE-submit fresh-launch
# idle state was not independently re-confirmed blank in this same pass
# (only the post-submit idle state was, directly) - no contextual-hint
# mechanism (claude's own v2.1.220-style "❯ Try..." suggestion) was ever
# observed for pi in this or the earlier verification pass, so this is
# treated as the same state, not a guess.
WM_AGENT_COMPOSER_SHAPE=separated
WM_AGENT_COMPOSER_RULE_RE="$WM_COMPOSER_RULE_RE"
WM_AGENT_COMPOSER_ANCHOR=""
WM_AGENT_COMPOSER_ANCHOR_EMPTY=1
# Genuinely unknown, per the plan (§3: still uncharacterized for every
# follow-on CLI) - pi has no per-tool permission-bypass system at all
# (confirmed absent by design), so a permission prompt in the claude sense
# may never even arise, but nothing here has been live-verified either way.
WM_AGENT_PERM_PROMPT_RE=""
WM_AGENT_PERM_OPTION_RE=""
WM_AGENT_PERM_LEAD_RE=""
WM_AGENT_RESUME_PROMPT_RE=""

# --- resume, lifecycle, and verification -----------------------------------
# No verified pane-resume contract exists for pi (plan §3) - crew-resume
# falls back to its relaunch mode for this adapter rather than a live
# --resume/-r/--continue flag, none of which have been confirmed to
# reattach a wingman-managed session correctly.
WM_AGENT_RESUME_FLAG=""
WM_AGENT_GUARD_TRANSPORT=pi-extension
# Not yet 1: hands-on verification this stage confirmed launch-time
# behavior (bypass flag, composer shape, system-prompt delivery, control
# values) but not a full live model turn (no credentials in this
# environment) or the pi-extension guard-transport shim itself (held,
# plan step 12b-12f, not yet built).
WM_AGENT_VERIFIED=0

# --- control values (B3) ----------------------------------------------------
# Verified live via pi's own expanded keybinding panel (ctrl+o) and a live
# /quit + Enter that cleanly exited the process.
WM_AGENT_EXIT_CMD="/quit"
WM_AGENT_INTERRUPT_KEY="Escape"
WM_AGENT_INTERRUPT_REPEAT=1
WM_AGENT_POST_INTERRUPT_CLEAR=""
# pi's own --skill <path> launch-time flag (pi --help) loads a skills
# directory in addition to its two always-scanned global locations
# (~/.pi/agent/skills/, ~/.agents/skills/) - repeatable and additive even
# with --no-skills, and confirmed live to accept a directory
# wholly outside the working tree, independent of cwd and of project trust
# (--skill <path> with --no-approve). Pointed at wingman's own canonical
# .agents/skills/ tree (bin/spawn-crew/bin/crew-resume), so a pi crew member
# sees the seven exported wingman-<verb> skills regardless of which repo it
# is grounded in.
WM_AGENT_SKILLS_FLAG="--skill %s"
# Verified live via pi's own autocomplete popup: typing "/sk" rendered
# "→ skill:wm-status" for a project-local test skill - confirmed invocation
# syntax, not attributed. Corrected from the earlier unset value now that
# this descriptor has a real route to load skills at all (WM_AGENT_SKILLS_FLAG
# above) - there was nothing to characterize an invocation form FOR before.
WM_AGENT_SKILL_FORM="/skill:<skill>"
