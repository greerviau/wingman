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
# Not anchored to line-start: an adapter with a populated WM_AGENT_ENV_PREFIX
# (opencode) now composes the env-prefix BEFORE the literal "exec" word
# (round-2 review MF1 fix), so "exec" is no longer necessarily the line's
# first token - matches it as a standalone word wherever it falls instead.
exec_line="$(grep -E '(^|[[:space:]])exec ' "$launch")"
assert_contains "the OPENCODE_CONFIG_CONTENT env-var bypass prefixes the exec line" "$exec_line" "OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}'"
assert_contains "opencode's own binary is the exec target" "$exec_line" "$WS/stub.sh"
assert_not_contains "no --permission-mode (claude's own bypass flag shape) leaks into an opencode launch" "$exec_line" "--permission-mode"
assert_not_contains "no --session-id is emitted (opencode has no confirmed force-session-id-at-creation flag, plan §3)" "$exec_line" "--session-id"
assert_not_contains "no --name is emitted (--title is run-subcommand-only, not the interactive launch path, plan §3)" "$exec_line" "--name"
assert_contains "the resolved model is passed via --model" "$exec_line" "--model 'anthropic/claude-sonnet'"
assert_not_contains "no --effort/--variant leaks in (opencode has no effort flag on the interactive launch path, plan §3)" "$exec_line" "--effort"
assert_not_contains "no --add-dir/--settings (claude-only CLAUDE.md-exclusion mechanism) leaks into an opencode launch" "$exec_line" "--add-dir"
assert_not_contains "no OPENCODE_DISABLE_PROJECT_CONFIG (rejected: silently disables all project-local opencode config, not just AGENTS.md) leaks into an opencode launch" "$exec_line" "OPENCODE_DISABLE_PROJECT_CONFIG"
assert_contains "the system prompt is delivered via --prompt, opencode's own flag" "$exec_line" "--prompt "

# --- WM_AGENT_ENV_PREFIX must precede the literal `exec` word ---------------
# Round-2 review of PR #350: a real, blocking bug. `VAR=val` is only
# recognized as a command's own env-assignment prefix when it is the
# FIRST word of the simple command - `exec VAR=val cmd` does NOT qualify
# (`exec` is the command name there; VAR=val becomes its own first
# argument, a literal program name bash fails to find, rc 127, before
# `cmd` is ever reached). The composed line must read
# `VAR=val exec cmd ...`, never `exec VAR=val cmd ...`. Checking ordering
# relative to the BINARY alone (as this test originally did) does not
# catch this - both the broken and fixed shapes put the env-prefix before
# the binary path; only ordering relative to the literal "exec" word does.
assert_true "the env-prefix precedes the literal 'exec' word, not the reverse" \
  "printf '%s' \"\$exec_line\" | grep -qE '^OPENCODE_CONFIG_CONTENT=.*exec '"
assert_not_contains "the composed line never starts with the broken 'exec VAR=val' shape" "$exec_line" "exec OPENCODE_CONFIG_CONTENT="

# --- the composed launch script must actually be executable -----------------
# Textual shape alone is not proof (round-2 review): the reviewer caught
# this exact bug by running a real composed script and observing it die
# with rc 127. Runs the REAL launch script (not a hand-built proxy) and
# confirms the process is still alive a moment later - a broken `exec`
# ordering kills it immediately; a working one execs into the stub's own
# `exec sleep 60` and keeps running.
bash "$launch" &
launch_pid=$!
wm_track "$launch_pid"
sleep 0.5
assert_true "the composed launch script actually execs successfully, not rc 127 from the WM_AGENT_ENV_PREFIX/exec ordering bug" \
  "ps -p '$launch_pid' >/dev/null 2>&1"

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
# Deliberately left unset (round-2 review must-fix): nothing consumes it
# yet, and rc 5 is structurally unreachable for opencode anyway while
# composer mode stays disabled below - see opencode.sh's own comment.
assert_eq "opencode's descriptor leaves BUSY_MEANS_QUEUED unset - inert given composer mode is disabled, not a contradiction" "$WM_AGENT_BUSY_MEANS_QUEUED" ""
assert_eq "opencode's descriptor's model value shape is provider/model, not bare" "$WM_AGENT_MODEL_VALUE_SHAPE" "provider/model"
assert_eq "opencode's descriptor declares its double-escape interrupt, hands-on confirmed live" "$WM_AGENT_INTERRUPT_REPEAT" "2"
assert_eq "opencode's descriptor is not yet marked fully verified (no real-provider model turn was possible)" "$WM_AGENT_VERIFIED" "0"

# --- composer fallback: previously zero coverage (round-2 review must-fix) ---
# The reviewer mutated a copy of this descriptor to adopt claude's own
# WM_AGENT_COMPOSER_RULE_RE/ANCHOR (reproducing #348's original pi failure
# mode exactly) and every existing assertion across three suites stayed
# green - nothing here actually exercised the fallback claim at all. Two
# things close that gap: a direct field-value guard (the exact thing that
# mutation flips), and a real behavioral proof against a hands-on-captured
# opencode-shaped stub that delivery genuinely still confirms via the
# whole-pane-checksum path with these fields left empty.
assert_eq "opencode's own composer rule pattern is genuinely unset, not silently inherited from claude's ambient default" "$WM_AGENT_COMPOSER_RULE_RE" ""
assert_eq "opencode's own composer anchor is genuinely unset, not silently inherited from claude's ambient default" "$WM_AGENT_COMPOSER_ANCHOR" ""
assert_eq "opencode's own composer anchor-empty flag is genuinely unset (unlike pi's, which is deliberately 1)" "$WM_AGENT_COMPOSER_ANCHOR_EMPTY" ""

OC_STUB="$TEST_REPO/tests/fixtures/composer-stub-opencode.sh"
# Direct, timing-independent check first: opencode's real captured shape
# (a "┃" left bar, a "▀"-based bottom row - never wingman's own "─" rule
# character) must not be recognized by wm_composer_text_in at all, even
# under claude's own ambient WM_COMPOSER_RULE_RE (the default in scope
# here, unswapped) - confirming there is no accidental character overlap
# to worry about, not merely that this descriptor happens to leave the
# fields blank.
oc_pane="$(printf '┃\n┃  hello\n┃\n┃  Build \xc2\xb7 Big Pickle OpenCode Zen\n\xe2\x95\xb9%s\n' "$(_x=0; while [ "$_x" -lt 78 ]; do printf '\xe2\x96\x80'; _x=$((_x+1)); done)")"
if oc_out="$(wm_composer_text_in "$oc_pane")"; then oc_rc=0; else oc_rc=1; fi
assert_eq "opencode's real captured shape is 'not recognized' by wm_composer_text_in, even under claude's own ambient rule pattern" "$oc_rc" "1"

# Behavioral proof: a real send against a live opencode-shaped pane,
# threaded through wm_tmux_send_message with "opencode", must still
# confirm delivery correctly - via the whole-pane-checksum fallback, since
# composer mode never engages for this shape.
SESS_OC="$WM_TMUX_SESSION-composer-oc"
wm_track_tmux "$SESS_OC"
MARKER_OC="$(wm_mktemp_file)"
: > "$MARKER_OC"
tmux new-session -d -s "$SESS_OC" -n box "WM_TEST_MARKER='$MARKER_OC' bash '$OC_STUB'"
sleep 1
wm_tmux_send_message "$SESS_OC:box" "hello-opencode-threaded" "opencode"
rc_oc=$?
assert_eq "a threaded send against a real opencode-shaped pane submits the text" "$(grep -c SUBMITTED "$MARKER_OC")" "1"
assert_eq "and confirms via the whole-pane-checksum fallback (rc 0) - composer mode never engages for opencode's own shape" "$rc_oc" "0"

test_summary
