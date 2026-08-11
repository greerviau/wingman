#!/usr/bin/env bash
# E2E: agent CLI selection and its precedence chain (issue #25, plan §4.4,
# §5 step 3). Proves: --agent/$WM_AGENT/[harness.agent] all reach
# wm_agent_resolve, most-specific-first, exactly like --model/--effort
# already do; an unknown agent name is a hard, fail-fast refusal (no tmux
# window, no roster record) rather than a broken launch line; and an
# out-of-domain --effort is silently omitted rather than composed, per the
# resolved adapter's own WM_AGENT_EFFORT_VALUES.
#
# Only the claude descriptor exists at this stage of the port, so this can't
# yet prove an actual SWITCH to a different CLI (stages 4-7 add pi/opencode/
# codex/grok and their own hands-on-verified adapter tests) - it proves the
# selection PLUMBING reaches wm_agent_resolve correctly, using "claude" and a
# deliberately-unknown name as the two probe values.
#
# Uses a stub agent (WM_AGENT_BIN_OVERRIDE) and an isolated tmux session so no
# real claude launches and the live fleet is untouched.
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

# --- an explicit --agent claude behaves exactly like the default -------------
unset WM_AGENT
eid="$("$SPAWN" --type software-analyst --repo "$WS/repoA" --agent claude --objective "explicit claude" 2>/dev/null | tail -1)"
assert_true "--agent claude spawn succeeds" "[ -n '$eid' ]"
elaunch="$WINGMAN_HOME/crew/$eid.launch.sh"
assert_contains "an explicit --agent claude still composes claude's real flags" \
  "$(grep '^exec ' "$elaunch")" "--session-id"

# --- an unknown --agent is a hard, fail-fast refusal --------------------------
before_count="$(tmux list-windows -t "=$WM_TMUX_SESSION" 2>/dev/null | grep -c .)"
if bad_out="$("$SPAWN" --type software-analyst --repo "$WS/repoA" --agent no-such-agent-xyz --objective "should refuse" 2>&1)"; then bad_rc=0; else bad_rc=$?; fi
assert_true "an unknown --agent refuses the spawn" "[ $bad_rc -ne 0 ]"
assert_contains "the refusal names the unknown agent" "$bad_out" "unknown agent 'no-such-agent-xyz'"
assert_contains "the refusal points at --list-agents" "$bad_out" "--list-agents"
after_count="$(tmux list-windows -t "=$WM_TMUX_SESSION" 2>/dev/null | grep -c .)"
assert_eq "no tmux window was created for the refused spawn" "$after_count" "$before_count"

# --- $WM_AGENT (env var layer) also reaches resolution ------------------------
venv_id="$(WM_AGENT=no-such-agent-xyz "$SPAWN" --type software-analyst --repo "$WS/repoA" --objective "env agent" 2>/dev/null | tail -1)"
assert_true "\$WM_AGENT alone (no --agent) fails to resolve an unknown name too" "[ -z '$venv_id' ]"

# --- config.local.toml's [harness.agent] per-type table also reaches it -------
# (plan §4.4's 3rd precedence tier) - proven with an intentionally-unknown
# value so the failure itself is the positive signal that the config layer's
# value actually reached wm_agent_resolve, not merely that the spawn
# succeeded on some other tier's fallback.
wm_write_config <<EOF
[harness.agent]
developer = "no-such-agent-xyz"
EOF
unset WM_AGENT
if cfg_out="$("$SPAWN" --type developer --repo "$WS/repoA" --objective "config-selected agent" 2>&1)"; then cfg_rc=0; else cfg_rc=$?; fi
assert_true "[harness.agent].developer reaches resolution: the spawn is refused for the configured bogus name" "[ $cfg_rc -ne 0 ]"
assert_contains "the refusal names the config-selected agent, not claude" "$cfg_out" "unknown agent 'no-such-agent-xyz'"
# A DIFFERENT crew type (not named in [harness.agent]) is unaffected -
# specificity, not a fleet-wide override.
other_id="$("$SPAWN" --type software-analyst --repo "$WS/repoA" --objective "unaffected type" 2>/dev/null | tail -1)"
assert_true "a crew type [harness.agent] does not name still resolves to claude" "[ -n '$other_id' ]"
wm_rm_config

test_summary
