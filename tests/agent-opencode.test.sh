#!/usr/bin/env bash
# E2E: the opencode adapter (bin/lib/agents/opencode.sh, issue #25 stage 5/8,
# plan §5 step 8). Proves --agent opencode switches bin/spawn-crew's composed
# launch line to opencode's own flags - agent-selection.test.sh's own comment
# defers exactly this proof to each stage's own adapter test.
#
# Uses a stub agent (WM_AGENT_BIN_OVERRIDE) and an isolated tmux session so
# no real opencode binary launches and the live fleet is untouched - the
# hands-on verification against the real opencode binary (env-var bypass,
# left-bar composer shape, --prompt delivery, the busy/queued mechanism end
# to end, control values) lives in this stage's PR description instead, not
# in this suite, exactly like the plan requires for something a stub can't
# actually exercise (a real TUI render or a real model turn).
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
id="$("$SPAWN" --type software-analyst --repo "$WS/repoA" --agent opencode --model "anthropic/claude-sonnet" --objective "opencode adapter test" 2>/dev/null | tail -1)"
assert_true "--agent opencode spawn succeeds" "[ -n '$id' ]"

launch="$WINGMAN_HOME/crew/$id.launch.sh"
assert_true "launch script was written" "[ -f '$launch' ]"

launch_body="$(cat "$launch")"

# --- CLAUDECODE unset before exec (WM_AGENT_ENV_UNSET) -----------------------
assert_contains "the launch script unsets CLAUDECODE before exec'ing opencode" "$launch_body" "unset CLAUDECODE"

# --- the exec line composes opencode's own flags, not claude's ---------------
exec_line="$(grep '^exec ' "$launch")"
assert_contains "the OPENCODE_CONFIG_CONTENT env-var bypass prefixes the exec line" "$exec_line" "OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}'"
assert_contains "opencode's own binary is the exec target" "$exec_line" "$WS/stub.sh"
assert_not_contains "no --permission-mode (claude's own bypass flag shape) leaks into an opencode launch" "$exec_line" "--permission-mode"
assert_not_contains "no --session-id is emitted (opencode has no confirmed force-session-id-at-creation flag, plan §3)" "$exec_line" "--session-id"
assert_not_contains "no --name is emitted (--title is run-subcommand-only, not the interactive launch path, plan §3)" "$exec_line" "--name"
assert_contains "the resolved model is passed via --model" "$exec_line" "--model 'anthropic/claude-sonnet'"
assert_not_contains "no --effort/--variant leaks in (opencode has no effort flag on the interactive launch path, plan §3)" "$exec_line" "--effort"
assert_not_contains "no --add-dir/--settings (claude-only CLAUDE.md-exclusion mechanism) leaks into an opencode launch" "$exec_line" "--add-dir"
assert_contains "the system prompt is delivered via --prompt, opencode's own flag" "$exec_line" "--prompt "

# --- WM_AGENT_ENV_PREFIX composes before the binary, not as a flag -----------
assert_true "the env-prefix appears before the exec target in the composed line" \
  "printf '%s' \"\$exec_line\" | grep -qE 'OPENCODE_CONFIG_CONTENT=.*$WS/stub\\.sh'"

# --- wm_agent_list / descriptor resolution surface opencode correctly --------
. "$TEST_REPO/bin/lib/common.sh"
. "$TEST_REPO/bin/lib/agent.sh"
listed="$(wm_agent_list)"
assert_contains "wm_agent_list finds the opencode descriptor" "$listed" "opencode"

wm_agent_resolve opencode
assert_eq "opencode's descriptor resolves WM_AGENT_DISPLAY_NAME" "$WM_AGENT_DISPLAY_NAME" "opencode"
assert_eq "opencode's descriptor declares its guard transport" "$WM_AGENT_GUARD_TRANSPORT" "opencode-plugin"
assert_eq "opencode's descriptor uses prompt-flag system-prompt delivery" "$WM_AGENT_SYSPROMPT_MODE" "prompt-flag"
assert_eq "opencode's descriptor's composer shape is left-bar, per the plan's §4.6 catalogue" "$WM_AGENT_COMPOSER_SHAPE" "left-bar"
assert_eq "opencode's descriptor sets BUSY_MEANS_QUEUED, hands-on confirmed live" "$WM_AGENT_BUSY_MEANS_QUEUED" "1"
assert_eq "opencode's descriptor's model value shape is provider/model, not bare" "$WM_AGENT_MODEL_VALUE_SHAPE" "provider/model"
assert_eq "opencode's descriptor declares its double-escape interrupt, hands-on confirmed live" "$WM_AGENT_INTERRUPT_REPEAT" "2"
assert_eq "opencode's descriptor is not yet marked fully verified (no real-provider model turn was possible)" "$WM_AGENT_VERIFIED" "0"

test_summary
