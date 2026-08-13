#!/usr/bin/env bash
# E2E: the grok adapter (bin/lib/agents/grok.sh, issue #25 stage 7/8,
# plan §5 step 8). Proves --agent grok switches bin/spawn-crew's composed
# launch line to grok's own flags - agent-selection.test.sh's own comment
# defers exactly this proof to each stage's own adapter test.
#
# Uses a stub agent (WM_AGENT_BIN_OVERRIDE) and an isolated tmux session so
# no real grok binary launches and the live fleet is untouched - the
# hands-on verification against the real grok binary (--help flag surface,
# trust-dialog absence in a worktree, AGENTS.md/CLAUDE.md discovery, the
# reasoning-effort domain via a live ACP handshake) lives in this stage's PR
# description instead, not in this suite, exactly like the plan requires for
# something a stub can't actually exercise (a real TUI render or a real
# model turn) - grok's own account-level auth gate blocked reaching either
# in this environment, more than any earlier adapter; see grok.sh's own
# header comment for exactly what could and couldn't be confirmed live.
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
id="$("$SPAWN" --type software-analyst --repo "$WS/repoA" --agent grok --model "grok-4.5" --effort high --objective "grok adapter test" 2>/dev/null | tail -1)"
assert_true "--agent grok spawn succeeds" "[ -n '$id' ]"

launch="$WINGMAN_HOME/crew/$id.launch.sh"
assert_true "launch script was written" "[ -f '$launch' ]"

launch_body="$(cat "$launch")"

# --- CLAUDECODE unset before exec (WM_AGENT_ENV_UNSET) -----------------------
assert_contains "the launch script unsets CLAUDECODE before exec'ing grok" "$launch_body" "unset CLAUDECODE"

# --- the exec line composes grok's own flags, not any other adapter's --------
# Not anchored to line-start: an adapter with a populated WM_AGENT_ENV_PREFIX
# (grok) composes the env-prefix BEFORE the literal "exec" word, so "exec"
# is not necessarily the line's first token - matches it as a standalone
# word wherever it falls instead (issue #25's own MF1 lesson, opencode's own
# stage-5 review).
exec_line="$(grep -E '(^|[[:space:]])exec ' "$launch")"
assert_contains "the GROK_CLAUDE_AGENTS_ENABLED=0 env-var prefixes the exec line" "$exec_line" "GROK_CLAUDE_AGENTS_ENABLED=0"
assert_contains "grok's own binary is the exec target" "$exec_line" "$WS/stub.sh"
assert_contains "the bypass flag is grok's own --permission-mode bypassPermissions" "$exec_line" "--permission-mode 'bypassPermissions'"
assert_not_contains "no --always-approve (grok's OTHER bypass shape, not the one this descriptor uses) leaks in" "$exec_line" "--always-approve"
assert_not_contains "no --dangerously-bypass-approvals-and-sandbox (codex's own bypass flag) leaks into a grok launch" "$exec_line" "--dangerously-bypass-approvals-and-sandbox"
assert_not_contains "no --approve (pi's own bypass flag) leaks into a grok launch" "$exec_line" "--approve"
assert_not_contains "no --session-id is emitted (left unset on this descriptor's own discrepancy note, plan §3 vs --help)" "$exec_line" "--session-id"
assert_not_contains "no --name is emitted (grok has no display-name-at-creation flag, plan §3)" "$exec_line" "--name"
assert_contains "the resolved model is passed via --model" "$exec_line" "--model 'grok-4.5'"
assert_contains "the resolved effort is passed via --reasoning-effort, grok's own effort flag" "$exec_line" "--reasoning-effort 'high'"
assert_not_contains "no -c model_reasoning_effort= (codex's own effort flag shape) leaks in" "$exec_line" "model_reasoning_effort"
assert_not_contains "no --thinking (pi's own effort flag) leaks in" "$exec_line" "--thinking"
assert_not_contains "no --add-dir/--settings (claude-only CLAUDE.md-exclusion mechanism) leaks into a grok launch" "$exec_line" "--add-dir"
assert_not_contains "no --prompt (opencode's own flag) leaks into a grok launch" "$exec_line" "--prompt"

# --- system prompt delivered via --rules, grok's own direct flag -------------
# flag mode: unlike codex, grok has a real system-prompt flag, so the brief
# rides behind --rules rather than as a bare positional argument.
assert_contains "the composed brief is delivered via --rules, grok's own direct flag" "$exec_line" "--rules "
assert_not_contains "no --system-prompt-override (grok's OTHER sysprompt flag, not the one this descriptor uses) leaks in" "$exec_line" "--system-prompt-override"
# Round-1 review must-fix: a bare "--rules %s" template composes the
# sysprompt FILE PATH literally (wm_agent_emit_sysprompt's flag branch
# substitutes the path, not the file's content) - every grok crew member
# would launch with no playbook and no status contract at all, the exact
# bug this assertion pair exists to catch. Checking only "--rules " is
# present (the original, insufficient assertion) is satisfied by the
# broken shape too - both checks below must actually distinguish it.
assert_contains "--rules wraps the sysprompt file in a real \$(cat ...) content expansion, not a bare path" \
  "$exec_line" "--rules \"\$(cat '"
assert_not_contains "the composed line never ends with a bare .sysprompt.md path right after --rules (the literal-path bug's own signature)" \
  "$exec_line" "--rules '"

# --- WM_AGENT_ENV_PREFIX must precede the literal `exec` word ---------------
# The exact bug class round-2 review of PR #350 caught for opencode: `VAR=val`
# is only recognized as a command's own env-assignment prefix when it is the
# FIRST word of the simple command - `exec VAR=val cmd` does NOT qualify.
assert_true "the env-prefix precedes the literal 'exec' word, not the reverse" \
  "printf '%s' \"\$exec_line\" | grep -qE '^GROK_CLAUDE_AGENTS_ENABLED=0 exec '"
assert_not_contains "the composed line never starts with the broken 'exec VAR=val' shape" "$exec_line" "exec GROK_CLAUDE_AGENTS_ENABLED="

# --- the composed launch script must actually be executable -----------------
# Textual shape alone is not proof (established lesson from opencode's own
# round-2 review). Runs the REAL launch script and confirms the process is
# still alive a moment later.
bash "$launch" &
launch_pid=$!
wm_track "$launch_pid"
sleep 0.5
assert_true "the composed launch script actually execs successfully" \
  "ps -p '$launch_pid' >/dev/null 2>&1"

# --- an out-of-domain effort is omitted rather than composed (plan §4.3) ------
id2="$("$SPAWN" --type software-analyst --repo "$WS/repoA" --agent grok --effort "xhigh" --objective "out of domain effort" 2>/dev/null | tail -1)"
assert_true "spawn with an out-of-domain effort (xhigh, rejected outright by grok per plan §3) still succeeds" "[ -n '$id2' ]"
exec_line2="$(grep -E '(^|[[:space:]])exec ' "$WINGMAN_HOME/crew/$id2.launch.sh")"
assert_not_contains "the out-of-domain effort value never reaches the composed line" "$exec_line2" "xhigh"
assert_not_contains "and --reasoning-effort itself is omitted entirely, not composed with an invalid value" "$exec_line2" "--reasoning-effort"

# --- wm_agent_list / descriptor resolution surface grok correctly -----------
. "$TEST_REPO/bin/lib/common.sh"
. "$TEST_REPO/bin/lib/agent.sh"
listed="$(wm_agent_list)"
assert_contains "wm_agent_list finds the grok descriptor" "$listed" "grok"

wm_agent_resolve grok
assert_eq "grok's descriptor resolves WM_AGENT_DISPLAY_NAME" "$WM_AGENT_DISPLAY_NAME" "grok"
assert_eq "grok's descriptor declares its guard transport" "$WM_AGENT_GUARD_TRANSPORT" "grok-json"
assert_eq "grok's descriptor uses flag system-prompt delivery" "$WM_AGENT_SYSPROMPT_MODE" "flag"
assert_eq "grok's descriptor's composer shape is bordered, per the plan's §4.6 catalogue" "$WM_AGENT_COMPOSER_SHAPE" "bordered"
assert_eq "grok's own composer rule pattern is genuinely unset (no rule-line pair in its own shape)" "$WM_AGENT_COMPOSER_RULE_RE" ""
assert_eq "grok's own composer anchor is genuinely unset - never independently captured from a live pane" "$WM_AGENT_COMPOSER_ANCHOR" ""
assert_eq "grok's descriptor's exit command is /exit" "$WM_AGENT_EXIT_CMD" "/exit"
assert_eq "grok's descriptor's interrupt key is C-c" "$WM_AGENT_INTERRUPT_KEY" "C-c"
assert_eq "grok's descriptor's skill form is /<skill>, matching claude's own form" "$WM_AGENT_SKILL_FORM" "/<skill>"
assert_eq "grok's descriptor sets SLASH_SETTLE to dodge its own slash-autocomplete popup" "$WM_AGENT_SLASH_SETTLE" "1"
# The one field #4.7 explicitly requires be set with a comment rather than
# left blank as if uncharacterized: C-c is grok's own turn-interrupt key,
# not a composer-clear keystroke - this asserts the VALUE (empty), the same
# value an uncharacterized field would also have; grok.sh's own comment is
# what carries the "positive fact, not a gap" distinction the plan requires.
assert_eq "grok's descriptor leaves CLEAR_KEYS empty (C-c is its interrupt key, not a composer clear)" "$WM_AGENT_CLEAR_KEYS" ""
assert_eq "grok's descriptor is not yet marked fully verified (no real model turn was possible - account auth gate)" "$WM_AGENT_VERIFIED" "0"

test_summary
