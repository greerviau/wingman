#!/usr/bin/env bash
# E2E: the pi adapter (bin/lib/agents/pi.sh, issue #25 stage 4/8, plan §5
# step 8). Proves --agent pi actually switches bin/spawn-crew's composed
# launch line to pi's own flags - agent-selection.test.sh's own comment
# defers exactly this proof to each stage's own adapter test, since only the
# claude descriptor existed when that file was written.
#
# Uses a stub agent (WM_AGENT_BIN_OVERRIDE) and an isolated tmux session so
# no real pi binary launches and the live fleet is untouched - the hands-on
# verification against the real pi binary (bypass flag, composer shape,
# system-prompt delivery, control values) lives in this stage's PR
# description instead, not in this suite, exactly like the plan requires
# for something a stub can't actually exercise (a real TUI render).
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
id="$("$SPAWN" --type software-analyst --repo "$WS/repoA" --agent pi --model "anthropic/claude-sonnet" --effort high --objective "pi adapter test" 2>/dev/null | tail -1)"
assert_true "--agent pi spawn succeeds" "[ -n '$id' ]"

launch="$WINGMAN_HOME/crew/$id.launch.sh"
assert_true "launch script was written" "[ -f '$launch' ]"

sysprompt="$WINGMAN_HOME/crew/$id.sysprompt.md"
launch_body="$(cat "$launch")"

# --- CLAUDECODE unset before exec (WM_AGENT_ENV_UNSET, plan §5 step 8) -------
assert_contains "the launch script unsets CLAUDECODE before exec'ing pi" "$launch_body" "unset CLAUDECODE"

# --- the exec line composes pi's own flags, not claude's ----------------------
exec_line="$(grep '^exec ' "$launch")"
assert_contains "pi's own binary is the exec target" "$exec_line" "$WS/stub.sh"
assert_contains "the bypass flag is the bare --approve token (no %s value)" "$exec_line" " --approve "
assert_contains "the repo-doc-context suppression flag is present" "$exec_line" "--no-context-files"
assert_not_contains "no -c project_doc_max_bytes= (codex's own suppression flag shape) leaks into a pi launch" "$exec_line" "project_doc_max_bytes"
assert_not_contains "no --permission-mode (claude's own bypass flag shape) leaks into a pi launch" "$exec_line" "--permission-mode"
assert_not_contains "no --session-id is emitted (pi has no confirmed force-session-id-at-creation flag, plan §3)" "$exec_line" "--session-id"
assert_contains "the crew's own name is passed via --name" "$exec_line" "--name '$id'"
assert_contains "the resolved model is passed via --model" "$exec_line" "--model 'anthropic/claude-sonnet'"
assert_contains "the resolved effort is passed via --thinking, pi's own flag name" "$exec_line" "--thinking 'high'"
assert_not_contains "no --effort (claude's own flag name) leaks into a pi launch" "$exec_line" "--effort "
assert_not_contains "no --add-dir/--settings (claude-only CLAUDE.md-exclusion mechanism) leaks into a pi launch" "$exec_line" "--add-dir"
assert_contains "the system prompt is delivered via --append-system-prompt with the file's content substituted" \
  "$exec_line" "--append-system-prompt \"\$(cat '$sysprompt')\""

# --- the portable crew command vocabulary: pi's own --skill flag -----------
assert_contains "the crew command vocabulary is loaded via --skill, pointed at the canonical .agents/skills/ tree" \
  "$exec_line" "--skill '$TEST_REPO/.agents/skills'"

# --- an out-of-domain effort is omitted rather than composed (plan §4.3) ------
id2="$("$SPAWN" --type software-analyst --repo "$WS/repoA" --agent pi --effort "not-a-real-level" --objective "out of domain effort" 2>/dev/null | tail -1)"
assert_true "spawn with an out-of-domain effort still succeeds" "[ -n '$id2' ]"
exec_line2="$(grep '^exec ' "$WINGMAN_HOME/crew/$id2.launch.sh")"
assert_not_contains "the out-of-domain effort value never reaches the composed line" "$exec_line2" "not-a-real-level"
assert_not_contains "and --thinking itself is omitted entirely, not composed empty" "$exec_line2" "--thinking"

# --- wm_agent_list / descriptor resolution surface pi correctly --------------
. "$TEST_REPO/bin/lib/common.sh"
. "$TEST_REPO/bin/lib/agent.sh"
listed="$(wm_agent_list)"
assert_contains "wm_agent_list finds the pi descriptor" "$listed" "pi"

wm_agent_resolve pi
assert_eq "pi's descriptor resolves WM_AGENT_DISPLAY_NAME" "$WM_AGENT_DISPLAY_NAME" "pi"
assert_eq "pi's descriptor declares its guard transport" "$WM_AGENT_GUARD_TRANSPORT" "pi-extension"
assert_eq "pi's descriptor uses flag-mode system-prompt delivery" "$WM_AGENT_SYSPROMPT_MODE" "flag"
assert_eq "pi's descriptor's composer shape is separated, per the plan's §4.6 catalogue" "$WM_AGENT_COMPOSER_SHAPE" "separated"
assert_eq "pi's descriptor is not yet marked fully verified (no live model turn was possible)" "$WM_AGENT_VERIFIED" "0"
assert_eq "pi's descriptor sets its own repo-doc-context suppression flag" "$WM_AGENT_CONTEXT_SUPPRESS_FLAG" "--no-context-files"
assert_eq "pi's descriptor sets its own skills-directory launch flag" "$WM_AGENT_SKILLS_FLAG" "--skill %s"
assert_eq "pi's descriptor's skill invocation form is corrected to /skill:<skill>" "$WM_AGENT_SKILL_FORM" "/skill:<skill>"
assert_eq "pi's descriptor has no preflight - the --skill flag is a complete route on its own" "$WM_AGENT_PREFLIGHT" ""

# --- the portable crew command vocabulary block, pi's own
#     /skill:<skill> rendering ------------------------------------------------
sysprompt_body="$(cat "$sysprompt")"
assert_contains "the crew command vocabulary block is present" "$sysprompt_body" "The crew command vocabulary."
assert_contains "pi's own example renders the /skill:wingman-status form" "$sysprompt_body" "e.g. \`/skill:wingman-status\` invokes"

test_summary
