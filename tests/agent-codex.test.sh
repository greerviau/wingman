#!/usr/bin/env bash
# E2E: the codex adapter (bin/lib/agents/codex.sh, issue #25 stage 6/8,
# plan §5 step 8). Proves --agent codex switches bin/spawn-crew's composed
# launch line to codex's own flags - agent-selection.test.sh's own comment
# defers exactly this proof to each stage's own adapter test.
#
# Uses a stub agent (WM_AGENT_BIN_OVERRIDE) and an isolated tmux session so
# no real codex binary launches and the live fleet is untouched - the
# hands-on verification against the real codex binary (trust dialog, bare
# composer shape, the -c model_reasoning_effort flag, positional sysprompt
# delivery, control values) lives in this stage's PR description instead,
# not in this suite, exactly like the plan requires for something a stub
# can't actually exercise (a real TUI render or a real model turn).
#
# Round-2 review of PR #350 (issue #25 stage 5) found that checking a
# composed launch line's TEXT SHAPE alone is not proof it actually runs -
# applied here from the start rather than retrofitted: this file both
# inspects the composed line AND actually executes it against a stub,
# confirming the process stays alive rather than dying on a malformed exec.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SPAWN="$TEST_REPO/bin/spawn-crew"

WS="$(wm_mktemp_dir)/workspace"
mkdir -p "$WS/repoA"
git -C "$WS/repoA" init -q
printf '#!/usr/bin/env bash\nexec sleep 60\n' > "$WS/stub.sh"; chmod +x "$WS/stub.sh"

export WM_AGENT_BIN_OVERRIDE="$WS/stub.sh" WM_SPAWN_DELAY=0 WM_SUBMIT_DELAY=0 WM_READY_TRIES=4 WM_READY_POLL=0 \
  WM_SUBMIT_POLL=0.2 WM_SUBMIT_TRIES=1
test_new_home
wm_trust_repo "$WS/repoA"

unset WM_AGENT
id="$("$SPAWN" --type software-analyst --repo "$WS/repoA" --agent codex --model "gpt-5" --effort high --objective "codex adapter test" 2>/dev/null | tail -1)"
assert_true "--agent codex spawn succeeds" "[ -n '$id' ]"

launch="$WINGMAN_HOME/crew/$id.launch.sh"
assert_true "launch script was written" "[ -f '$launch' ]"

launch_body="$(cat "$launch")"

# --- CLAUDECODE unset before exec (WM_AGENT_ENV_UNSET) -----------------------
assert_contains "the launch script unsets CLAUDECODE before exec'ing codex" "$launch_body" "unset CLAUDECODE"

# --- the exec line composes codex's own flags, not claude's ------------------
exec_line="$(grep -E '(^|[[:space:]])exec ' "$launch")"
assert_contains "codex's own binary is the exec target" "$exec_line" "$WS/stub.sh"
assert_contains "the repo-doc-context suppression flag is present (issue #353)" "$exec_line" "-c project_doc_max_bytes=0"
assert_contains "the bypass flag is codex's own dangerously-bypass flag" "$exec_line" "--dangerously-bypass-approvals-and-sandbox"
assert_not_contains "no --permission-mode (claude's own bypass flag shape) leaks into a codex launch" "$exec_line" "--permission-mode"
assert_not_contains "no --approve (pi's own bypass flag) leaks into a codex launch" "$exec_line" "--approve"
assert_not_contains "no --session-id is emitted (codex has no confirmed force-session-id-at-creation flag, plan §3)" "$exec_line" "--session-id"
assert_not_contains "no --name is emitted (codex has no display-name-at-creation flag, plan §3)" "$exec_line" "--name"
assert_contains "the resolved model is passed via --model" "$exec_line" "--model 'gpt-5'"
assert_contains "the resolved effort is passed via -c model_reasoning_effort=, codex's own config-override flag" "$exec_line" "-c model_reasoning_effort='high'"
assert_not_contains "no --effort/--thinking/--variant (other adapters' own effort flag shapes) leaks in" "$exec_line" "--effort"
assert_not_contains "no --add-dir/--settings (claude-only CLAUDE.md-exclusion mechanism) leaks into a codex launch" "$exec_line" "--add-dir"
assert_not_contains "no --prompt (opencode's own flag) leaks into a codex launch" "$exec_line" "--prompt"

# --- system prompt delivered positionally, not via a flag --------------------
# codex has no system-prompt flag at all (plan §4.5) - the composed brief
# rides as a single bare positional argument, the same mechanism codex
# shares with the schema's own "positional" mode. Checked against the
# WHOLE launch file body, not just the single line grep matched for
# "exec" - the quoted positional argument contains literal embedded
# newlines (the sysprompt file's own content), so it spans many physical
# lines in the file even though it's one logical shell argument; checking
# only the "exec"-matched line would miss content further down.
assert_contains "the composed brief appears as a bare positional argument (contains the playbook marker, not behind any flag)" \
  "$launch_body" "Your assignment"
assert_contains "...and the opening objective is folded into that same argument, not delivered separately" \
  "$launch_body" "codex adapter test"

# --- the composed launch script must actually be executable -----------------
# Textual shape alone is not proof (round-2 review of PR #350's own
# lesson, applied here proactively). Runs the REAL launch script and
# confirms the process is still alive a moment later.
bash "$launch" &
launch_pid=$!
wm_track "$launch_pid"
sleep 0.5
assert_true "the composed launch script actually execs successfully" \
  "ps -p '$launch_pid' >/dev/null 2>&1"

# --- an out-of-domain effort is omitted rather than composed (plan §4.3) ------
id2="$("$SPAWN" --type software-analyst --repo "$WS/repoA" --agent codex --effort "not-a-real-level" --objective "out of domain effort" 2>/dev/null | tail -1)"
assert_true "spawn with an out-of-domain effort still succeeds" "[ -n '$id2' ]"
exec_line2="$(grep -E '(^|[[:space:]])exec ' "$WINGMAN_HOME/crew/$id2.launch.sh")"
assert_not_contains "the out-of-domain effort value never reaches the composed line" "$exec_line2" "not-a-real-level"
assert_not_contains "and -c model_reasoning_effort= itself is omitted entirely, not composed empty" "$exec_line2" "model_reasoning_effort"

# --- wm_agent_list / descriptor resolution surface codex correctly ----------
. "$TEST_REPO/bin/lib/common.sh"
. "$TEST_REPO/bin/lib/agent.sh"
listed="$(wm_agent_list)"
assert_contains "wm_agent_list finds the codex descriptor" "$listed" "codex"

wm_agent_resolve codex
assert_eq "codex's descriptor resolves WM_AGENT_DISPLAY_NAME" "$WM_AGENT_DISPLAY_NAME" "codex"
assert_eq "codex's descriptor declares its guard transport" "$WM_AGENT_GUARD_TRANSPORT" "codex-json"
assert_eq "codex's descriptor uses positional system-prompt delivery" "$WM_AGENT_SYSPROMPT_MODE" "positional"
assert_eq "codex's descriptor's composer shape is bare, per the plan's §4.6 catalogue" "$WM_AGENT_COMPOSER_SHAPE" "bare"
assert_eq "codex's own composer rule pattern is genuinely unset (no rule-line pair in its own shape)" "$WM_AGENT_COMPOSER_RULE_RE" ""
assert_eq "codex's own composer anchor is genuinely unset - its idle hint rotates, hands-on confirmed live" "$WM_AGENT_COMPOSER_ANCHOR" ""
assert_eq "codex's descriptor's exit command is /quit" "$WM_AGENT_EXIT_CMD" "/quit"
assert_eq "codex's descriptor's skill form is \$<skill>, not /<skill>" "$WM_AGENT_SKILL_FORM" '$<skill>'
assert_eq "codex's descriptor sets SLASH_SETTLE for its own \$-prefixed skill form" "$WM_AGENT_SLASH_SETTLE" "1"
assert_eq "codex's descriptor is not yet marked fully verified (no real model turn was possible)" "$WM_AGENT_VERIFIED" "0"
assert_eq "codex's descriptor declares its skills-sync preflight" "$WM_AGENT_PREFLIGHT" "codex_preflight"

# --- the portable crew command vocabulary: codex_preflight actually
#     reconciles WM_CODEX_USER_SKILLS_DIR (test isolation override), never a
#     real developer's actual $HOME/.agents/skills ---------------------------
CODEX_SKILLS_DIR="$(wm_mktemp_dir)/agents-skills"
WM_CODEX_USER_SKILLS_DIR="$CODEX_SKILLS_DIR" codex_preflight "$WS/repoA" bypassPermissions spawn
assert_true "codex_preflight installs the seven wingman-<verb> symlinks into the overridden target" \
  "[ -L '$CODEX_SKILLS_DIR/wingman-status' ]"
resolved_codex_skill="$(uv run --no-project --quiet python -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$CODEX_SKILLS_DIR/wingman-status")"
assert_eq "codex_preflight points the symlink at this repo's own canonical tree" "$resolved_codex_skill" "$TEST_REPO/.agents/skills/wingman-status"

# --- the portable crew command vocabulary block, codex's own
#     $<skill> rendering ------------------------------------------------------
codex_sysprompt_body="$(cat "$WINGMAN_HOME/crew/$id.sysprompt.md")"
assert_contains "the crew command vocabulary block is present" "$codex_sysprompt_body" "The crew command vocabulary."
assert_contains "codex's own example renders the \$wingman-status form" "$codex_sysprompt_body" 'e.g. `$wingman-status` invokes'

test_summary
