# bin/lib/agents/codex.sh - the codex agent descriptor (issue #25).
#
# codex (npm @openai/codex, binary `codex`) is the third non-claude adapter
# (plan §8's build order: pi, then opencode, then codex, then grok).
# Exercises positional system-prompt delivery (codex has no system-prompt
# flag at all) and a first-run project-trust dialog with no flag-based
# bypass - see
# issue #25 for the full research and schema this
# descriptor implements, and bin/lib/agents/claude.sh for the field-by-field
# schema reference this file follows.
#
# Sourced by wm_agent_resolve (bin/lib/agent.sh), which has already sourced
# bin/lib/common.sh.
#
# *** AGENTS.md gap (explicit, not papered over) ***
# codex auto-loads a repo-root AGENTS.md for repo-level instructions/
# conventions (plan §3) - it does NOT read CLAUDE.md. This repo currently
# has no AGENTS.md, only CLAUDE.md, so a codex crew member spawned here gets
# ZERO repo-level auto-loaded context beyond what this descriptor's own
# positional brief delivers (the playbook + objective, composed by
# wm_agent_emit_sysprompt - that part is unaffected and works normally). A
# separate effort (issue #351) is porting AGENTS.md for this repo; this
# descriptor deliberately does not duplicate that work, and does not attempt
# to work around the gap (e.g. by pointing codex at CLAUDE.md itself, which
# codex does not recognize) - it only documents that the gap exists and why,
# so a future reader does not have to rediscover it.
#
# This gap is NOT expected to close once #351 lands, and that's deliberate
# (issue #353): WM_AGENT_CONTEXT_SUPPRESS_FLAG below actively suppresses
# codex's own AGENTS.md auto-load for every codex crew member, unconditionally,
# rather than relying on #351's prose preface block alone (the same mechanical-
# guarantee-over-prose reasoning issue #213/PR #215 already applied to
# claudeMdExcludes for claude). A codex crew member's repo-level context
# will keep coming solely from the positional brief, by design, both before
# and after #351 lands - not a residual gap to revisit.
#
# Hands-on verified (2026-08-13) against real codex-cli v0.147.0, launched
# in a live tmux pane with a syntactically-valid but non-functional API key
# (this environment has no real OpenAI credentials). Unlike opencode, codex
# has no free/unauthenticated default model, but unlike pi, the sign-in flow
# itself does not block reaching the real TUI - entering any string as an
# API key (even an invalid one) is enough to get past onboarding into the
# genuine trust dialog and composer. Confirmed live: the first-run project-
# trust dialog ("Do you trust the contents of this directory?"), that it
# persists per worktree path (a second launch in the same directory skips
# straight to the TUI), --dangerously-bypass-approvals-and-sandbox (status
# panel shows "permissions: YOLO mode"), the bare composer shape (a "› "
# glyph - U+203A + a literal ASCII space, not NBSP - prefixing the composer
# row, no border), --model and -c model_reasoning_effort=<value> composing
# together correctly (status panel showed "gpt-5 high" for
# `--model gpt-5 -c model_reasoning_effort=high`) - notably confirmed the
# BARE (unquoted) value works fine, so no TOML-string-quoting trick is
# needed in the flag template despite `-c`'s own values normally being
# TOML-parsed (codex's own documented fallback: "If it fails to parse as
# TOML, the raw string is used as a literal"), a real submit registering
# and correctly triggering a genuine API round-trip (a 401 error surfaced
# from codex's own retry logic, not a local/composer-level failure -
# confirming delivery itself works end-to-end even though the call itself
# can't succeed here), Escape interrupting ("esc to interrupt" shown live
# during a retry), Ctrl-C clearing the composer without exiting, and
# `/quit` cleanly exiting. Also confirmed live: the composer's own "empty"
# render is NOT byte-stable - it shows a rotating suggested-prompt hint
# (e.g. "Summarize recent commits") rather than a blank row, the same
# contextual-hint hazard common.sh's own comment already documents for
# claude's v2.1.220 - so WM_AGENT_COMPOSER_ANCHOR stays deliberately
# uncharacterized rather than pinned to one observed hint string. NOT
# verified live: an actual successful model turn (no real credentials in
# this environment), the project-trust dialog's own exact freeze-signature
# text (only that the dialog exists and what accepting it looks like), and
# WM_AGENT_SLASH_SETTLE's own need (attributed below, not independently
# re-derived - no in-session skill invocation was exercised this pass).
# Separately (same date, issue #353): WM_AGENT_CONTEXT_SUPPRESS_FLAG's
# suppression of AGENTS.md auto-loading was live-verified via a captured
# outbound request body against a local stand-in endpoint, not a live model
# turn - see that field's own comment below for the exact method and result.
#
# Separately (2026-08-17, the portable crew command vocabulary): both
# symlink-following AND the $HOME/.agents/skills discovery path are
# hands-on verified live against real codex-cli v0.147.0, with $HOME
# overridden to a scratch directory containing a real symlink set built by
# bin/lib/sync-user-skills.py (pointed at this repo's own canonical
# .agents/skills/ tree), launched from an unrelated cwd. Two independent
# checks: `codex debug prompt-input` (no live credentials needed) rendered
# the model-visible prompt input with all seven wingman-<verb> names and
# their real descriptions, each resolved through the symlink to the real
# file; and, in a live interactive TUI pane (a syntactically-valid but
# non-functional API key, same technique as the rest of this file's own
# verification), typing "$wingman-sta" autocompleted to "wingman-status
# [Skill] Show the current crew roster (who is on what, what is blocked,
# what is ready)" - confirming the "$<skill>" invocation form end to end,
# not merely that the file is discovered.

WM_AGENT_BIN=codex
WM_AGENT_DISPLAY_NAME="codex"

# --- preflight and environment ------------------------------------------
# Verified live: a first-run "Do you trust the contents of this directory?"
# dialog blocks the TUI entirely until answered ("1. Yes, continue" /
# "2. No, quit") - confirmed by walking through it directly - and there is
# no CLI flag or documented config key to pre-accept it (unlike claude's
# own workspace-trust, which claude_preflight below already automates via
# claude-gate-check.py). No automation is wired up here for THAT dialog: a
# codex crew member's first launch in a given worktree will freeze on it
# and rely on the freeze detector + crew-takeover, exactly the documented
# degradation for a gate with no automation (bin/lib/agent.sh's own
# WM_AGENT_PREFLIGHT doc comment). Confirmed live that trust DOES persist
# per worktree path once accepted once (a second launch in the same
# directory skips straight to the TUI), so this is a one-time cost per
# worktree, not per-launch - still worth automating properly in a follow-up
# (find and pre-populate whatever on-disk trust record codex itself
# consults - not yet located this pass) rather than left as a standing
# freeze risk indefinitely.
#
# WM_AGENT_PREFLIGHT IS wired up below, for a different gate: the portable
# crew command vocabulary. codex has no per-launch flag for an arbitrary
# skills directory - unlike pi's --skill, there is no key or CLI flag to
# ADD a discovery path, only to disable one already found - so
# $HOME/.agents/skills is codex's only
# cwd-independent route, reconciled here on every spawn/resume exactly like
# claude_preflight's own guard-hook sync below - a codex crew member never
# launches into a half-installed vocabulary, and a moved/renamed repo
# self-heals on the next spawn.
WM_AGENT_PREFLIGHT=codex_preflight
WM_AGENT_ENV_PREFIX=""
# The orchestrator that execs every crew member is always Claude Code, so a
# non-claude crew member (codex included) would otherwise silently inherit
# CLAUDECODE=1 from it (plan §5 step 8).
WM_AGENT_ENV_UNSET="CLAUDECODE"
# Repo-doc-context suppression (issue #353, see the AGENTS.md gap note
# above): codex's own project_doc_max_bytes config value, confirmed directly
# in codex's own source (codex-rs/core/src/agents_md.rs) to gate its whole
# AGENTS.md-discovery walk - 0 means "load nothing" (`if max_total == 0 {
# return Ok(None); }`), not "truncate to 0 bytes". Live-verified (2026-08-13)
# against the real codex-cli v0.147.0 binary, not shipped on source-reading
# confidence alone: a scratch repo with a marker-content AGENTS.md, launched
# against a local HTTP endpoint standing in for the model provider so the
# actual outbound request body could be captured directly (no real
# credentials needed for this - the request is fully composed and sent
# before codex ever sees a response). Without this flag, the marker text
# appeared verbatim in the captured request body; with `-c
# project_doc_max_bytes=0` added, the marker was completely absent (0
# occurrences) and the request shrank by exactly the injected block's size -
# direct proof against the real binary, not an inference from source alone.
# This also sidesteps issue #352 (this repo's docs file already exceeds
# codex's 32KB default budget, silently truncating the tail for an ordinary,
# non-crew codex user) for crew sessions specifically: nothing loads at all
# when fully suppressed, so the truncation question never arises here.
WM_AGENT_CONTEXT_SUPPRESS_FLAG="-c project_doc_max_bytes=0"

# --- launch capability ----------------------------------------------------
# Verified live: --dangerously-bypass-approvals-and-sandbox correctly puts
# codex into "YOLO mode" (its own status panel's literal label) - no
# per-tool-call approval prompt, matching the unattended-crew-member need
# WM_AGENT_BYPASS_FLAG exists for.
WM_AGENT_BYPASS_FLAG="--dangerously-bypass-approvals-and-sandbox"
# "Force session ID at creation": plan §3 finding is "Not found" for codex
# (confirmed directly against --help: no such flag on the base launch
# command) - left empty, matching pi's and opencode's own settled
# precedent (relaunch mode stands in, §4.8), not re-litigated here.
WM_AGENT_SESSION_ID_FLAG=""
# No display-name flag "at creation" either (plan §3) - confirmed directly
# against --help, nothing resembling --name/--title on the base launch
# command.
WM_AGENT_NAME_FLAG=""
WM_AGENT_REMOTE_CONTROL_FLAG=""
WM_AGENT_MODEL_FLAG="--model %s"
WM_AGENT_MODEL_VALUE_SHAPE="bare"
# codex's own generic config-override flag (-c key=value), not a dedicated
# effort flag - verified live that a bare (unquoted-by-us) value composes
# and takes effect correctly: `-c model_reasoning_effort=high` alongside
# `--model gpt-5` rendered "gpt-5 high" in codex's own status panel. The
# %s placeholder receives wm_agent_emit_flag's own single-quoted value
# (e.g. 'high'), which the shell strips before codex ever sees it, leaving
# codex with the identical bare `model_reasoning_effort=high` this was
# tested against directly - no extra TOML-string-quoting needed despite
# -c's own values normally being TOML-parsed, since codex's own documented
# fallback treats an unparseable bare word as a literal string.
WM_AGENT_EFFORT_FLAG="-c model_reasoning_effort=%s"
WM_AGENT_EFFORT_VALUES="low medium high xhigh"

# --- system prompt and delivery -------------------------------------------
# positional, not flag (plan §4.5): codex has no system-prompt flag at all
# (confirmed against --help - no --system-prompt/--append-system-prompt/
# --rules equivalent), only an optional [PROMPT] positional argument
# ("Optional user prompt to start the session"). wm_agent_emit_sysprompt's
# own positional case composes the sysprompt file's content and the opening
# objective into that one argument.
WM_AGENT_SYSPROMPT_MODE=positional
WM_AGENT_SYSPROMPT_FLAG=""
WM_AGENT_SUBMIT_SETTLE=""
# codex needs a settle only for its own "$<skill>" form specifically, not
# universally (plan §4.7: a leading "$" commonly starts ordinary text
# elsewhere, e.g. "$5/month", "$HOME", so a blanket slash-settle rule would
# slow every ordinary send for no reason). Attributed per the plan's own
# firstmate-sourced finding, not independently re-derived this pass - no
# in-session skill invocation was exercised against the real binary.
WM_AGENT_SLASH_SETTLE="1"
WM_AGENT_BUSY_MEANS_QUEUED=""
# Verified live: a single Ctrl-C clears the composer's current text without
# exiting.
WM_AGENT_CLEAR_KEYS="C-c"

# --- detection --------------------------------------------------------------
# Verified live: codex's composer renders as a single row prefixed by "› "
# (U+203A RIGHT-POINTING ANGLE QUOTATION MARK, U+0020 ASCII space - NOT
# NBSP), no border, no closing rule line - exactly the plan's §4.6 "bare"
# shape. WM_AGENT_COMPOSER_RULE_RE/ANCHOR stay unset: this shape has no
# rule-line pair for RULE_RE to describe at all (only claude's own "bare"
# shape happens to pair a glyph row with rule lines elsewhere in its own
# frame - codex's does not), and separately, codex's own "empty" render
# rotates through suggested-prompt hint text ("Summarize recent commits"
# and others, confirmed by watching it change across launches) rather than
# settling on one fixed byte sequence - the same contextual-hint hazard
# common.sh's own comment already documents for claude's v2.1.220, so
# pinning ANCHOR to one observed hint would risk exactly the false-
# negative/false-positive class that comment warns against. Composer-based
# confirm is correctly skipped; every send falls through to the
# pre-existing whole-pane-checksum path, verified live to register a real
# submit correctly (the pane visibly changed once codex attempted its own
# API round-trip).
WM_AGENT_COMPOSER_SHAPE=bare
WM_AGENT_COMPOSER_RULE_RE=""
WM_AGENT_COMPOSER_ANCHOR=""
WM_AGENT_COMPOSER_ANCHOR_EMPTY=""
# Genuinely unknown (plan §3): the project-trust dialog's own text is
# confirmed to exist (see WM_AGENT_PREFLIGHT above) but its freeze
# signature was not captured as a regex this pass, and codex's own
# approval-policy prompts (a separate concept from the trust dialog,
# gated by -a/--ask-for-approval) were never triggered live either, since
# --dangerously-bypass-approvals-and-sandbox was used throughout
# verification.
WM_AGENT_PERM_PROMPT_RE=""
WM_AGENT_PERM_OPTION_RE=""
WM_AGENT_PERM_LEAD_RE=""
WM_AGENT_RESUME_PROMPT_RE=""

# --- resume, lifecycle, and verification -----------------------------------
# codex has a real `codex resume [SESSION_ID] --last` subcommand (confirmed
# against --help), but per the plan's own settled decision this is not
# wired as WM_AGENT_RESUME_FLAG: there is no confirmed way to FORCE a
# specific session id AT CREATION time (only to resume an existing,
# already-created one by id/--last later), so wingman has no id to hand
# this flag at relaunch time regardless of the subcommand existing -
# relaunch mode stands in, the same settled precedent as pi/opencode's own
# §8 decision, not re-litigated here.
WM_AGENT_RESUME_FLAG=""
WM_AGENT_GUARD_TRANSPORT=codex-json
# No fleet-continuity transport is built for codex (the orchestrator-guard-
# transports plan, §5.5/§10) - documented "not built", not "impossible" -
# see pi.sh's own field for the fuller reasoning; codex's own primitives
# were not probed at all this pass.
WM_AGENT_CONTINUITY_TRANSPORT=""
# codex needs no extra environment for its guard transport - bin/lib/sync-
# codex-hooks.py writes user-scope $CODEX_HOME/hooks.json directly, with no
# compatibility-path hazard analogous to grok's own GROK_CLAUDE_HOOKS_ENABLED
# (codex reads no Claude-dialect settings file at all).
WM_AGENT_GUARD_ENV=""
# --dangerously-bypass-hook-trust (confirmed live against real codex-cli
# v0.147.0: `codex exec --dangerously-bypass-hook-trust ...` prints "warning:
# `--dangerously-bypass-hook-trust` is enabled. Enabled hooks may run without
# review for this invocation." - the flag is real and does something
# observable) so an untrusted-and-therefore-SKIPPED hook cannot silently
# disable enforcement. This un-gates every enabled hook source for the
# invocation, not only wingman's own - bin/lib/sync-codex-hooks.py's own
# check_no_foreign_hook_sources() is the compensating control (plan §5.4.2).
WM_AGENT_GUARD_LAUNCH_FLAGS="--dangerously-bypass-hook-trust"
# Not yet 1: this stage installed real codex-cli v0.147.0 (npm @openai/codex,
# a user-prefix npm install - matching the exact version this descriptor was
# verified against) and confirmed hands-on, beyond the plan's own research
# pass: `codex features list` genuinely reports `hooks  stable  true` (the
# documented default, live not just source-read); `--dangerously-bypass-
# hook-trust` prints the warning above when passed to a real `codex exec`
# invocation; `$CODEX_HOME` override and `codex login --with-api-key` both
# work exactly as the plan's own research found (a syntactically-valid but
# non-functional key gets past onboarding into a genuine attempted API
# round-trip - confirmed here as a real 401 against
# wss://api.openai.com/v1/responses, not a local/composer-level failure);
# and a hand-written hooks.json under a scratch $CODEX_HOME produced no
# startup error from `codex doctor`. What remains blocked, identically to
# the plan's own finding: an actual model turn, which needs a real OpenAI
# credential this environment does not have - so whether the guard
# genuinely blocks a live tool call (as opposed to being silently skipped
# by the trust gate, or read as a malformed/timed-out hook under codex's
# own fail-open posture) is not yet confirmed end to end. That is §7's
# remaining gate.
WM_AGENT_VERIFIED=0

# --- control values (B3) ----------------------------------------------------
# Verified live via a real /quit + Enter that cleanly exited the process.
WM_AGENT_EXIT_CMD="/quit"
# Verified live: "esc to interrupt" appeared in codex's own status line
# during a live retry.
WM_AGENT_INTERRUPT_KEY="Escape"
WM_AGENT_INTERRUPT_REPEAT=1
WM_AGENT_POST_INTERRUPT_CLEAR=""
# codex rejects the "/<skill>" form outright and uses "$<skill>" instead
# (plan §4.3's B3 table) - attributed, not independently re-derived this
# pass; no skill/extension invocation was exercised against the real
# binary.
WM_AGENT_SKILL_FORM="\$<skill>"

# codex_preflight <repo> <perm_mode> [<action>]
#
# Reconciles $HOME/.agents/skills against this repo's own canonical
# .agents/skills/ tree (bin/lib/sync-user-skills.py) - codex's only
# cwd-independent skill-discovery location, also read by opencode and pi
# as one of their own discovery locations, so this single reconcile serves
# all three.
# <repo>/<perm_mode> are unused here (this gate has nothing to do with the
# target repo or the permission mode) but accepted for a uniform call
# signature with every other WM_AGENT_PREFLIGHT function.
#
# WM_CODEX_USER_SKILLS_DIR overrides the target directory (test isolation,
# mirrors claude_preflight's WM_CLAUDE_USER_SETTINGS/WM_CLAUDE_USER_CONFIG
# convention) - a test suite run must never write into a real developer's
# actual $HOME/.agents/skills.
#
# Mode defaults to symlink, matching grok_preflight's own convention;
# switch WM_CODEX_SKILLS_SYNC_MODE=copy if hands-on verification ever shows
# codex stops following a symlinked skill folder (its own docs currently
# confirm it does - see the file header - so this is not expected to be
# needed, but the switch exists for symmetry with grok and so bin/doctor's
# own reconcile can read the identical variable rather than guessing).
codex_preflight() {
  _cop_action="${3:-spawn}"
  if ! _cop_err="$(uv run --no-project --quiet "$WM_LIB/sync-user-skills.py" \
      --target "${WM_CODEX_USER_SKILLS_DIR:-$HOME/.agents/skills}" --repo "$WM_REPO" \
      --mode "${WM_CODEX_SKILLS_SYNC_MODE:-symlink}" 2>&1)"; then
    wm_launch_failure "codex skills sync ($_cop_action)" "$_cop_err"
    wm_die "could not reconcile codex's user-level skills directory (\$HOME/.agents/skills): $_cop_err
Fix the reported problem, or run 'bin/doctor -y', then retry this $_cop_action."
  fi
  unset _cop_action _cop_err
  return 0
}
