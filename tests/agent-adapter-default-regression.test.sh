#!/usr/bin/env bash
# E2E regression: bin/spawn-crew's composed launch line for the DEFAULT case
# (no --agent flag, no $WM_AGENT set) must be byte-identical to pre-#25
# output at every commit of the multi-CLI agent adapter port (plan §5 step 3,
# §7 item 3) - this is the hard regression gate the whole per-agent-adapter
# mechanism is built to preserve, not a nice-to-have. The expected exec line
# is reconstructed literally here (confirmed against a real capture of
# bin/spawn-crew at commit a405809, the merge-base this port was built from -
# see docs/plans/2026-08-11-issue-25-multi-cli-agent-adapter-implementation-plan.md)
# rather than a stored golden file, so the expected shape stays readable and
# self-documenting in a future diff instead of opaque fixture data.
#
# Also proves the descriptor mechanism actually resolves to claude by
# default: the claude descriptor's own populated fields (bin/lib/agents/claude.sh)
# are what have to reproduce this exact shape, not a bypass or a special case.
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

# The default case, precisely: no --agent flag, and $WM_AGENT (its NEW
# meaning post-#25: the descriptor selector, not a binary path) explicitly
# unset, so it has to fall through every precedence tier on its own to reach
# claude's own built-in default.
unset WM_AGENT
id="$("$SPAWN" --type software-analyst --repo "$WS/repoA" --id golden-default --objective "regression fixture" 2>/dev/null | tail -1)"
assert_true "default spawn succeeds" "[ -n '$id' ]"

launch="$WINGMAN_HOME/crew/$id.launch.sh"
assert_true "launch script was written" "[ -f '$launch' ]"

sid="$(wm_state crew-get --id "$id" | uv run --no-project --quiet python -c 'import sys,json;print(json.load(sys.stdin).get("session_id") or "")')"
assert_true "a session id was recorded (still minted unconditionally, issue #25 §4.4)" "[ -n '$sid' ]"

sysprompt="$WINGMAN_HOME/crew/$id.sysprompt.md"
# The exact shape common.sh's wm_claude_md_excludes() emits (untouched by
# this rewrite - a pure function of $WM_REPO) - reproduced literally rather
# than sourced, since tests/lib.sh deliberately never sources common.sh
# itself (every other test in this suite follows the same convention, to
# keep a test fixture's own environment from picking up common.sh's other
# side effects).
excludes_json="$(printf '{"claudeMdExcludes":["%s/CLAUDE.md","%s/CLAUDE.local.md","%s/.claude/CLAUDE.md","%s/.claude/rules/**","%s/AGENTS.md","%s-*/CLAUDE.md","%s-*/CLAUDE.local.md","%s-*/.claude/CLAUDE.md","%s-*/.claude/rules/**","%s-*/AGENTS.md"]}' \
  "$TEST_REPO" "$TEST_REPO" "$TEST_REPO" "$TEST_REPO" "$TEST_REPO" "$TEST_REPO" "$TEST_REPO" "$TEST_REPO" "$TEST_REPO" "$TEST_REPO")"

expected="exec $WS/stub.sh --permission-mode 'bypassPermissions' --session-id '$sid' --name '$id' --remote-control 'wm-$id' --add-dir '$WINGMAN_HOME' --add-dir '$TEST_REPO' --settings '$excludes_json' --append-system-prompt \"\$(cat '$sysprompt')\""
actual="$(grep '^exec ' "$launch")"
assert_eq "the composed exec line for the default (no --agent, no \$WM_AGENT) case is byte-identical to pre-#25 output" "$actual" "$expected"

# --list-agents/crew.json's agent field are later plan steps (4, 10) not yet
# implemented at this stage - deliberately not asserted on here (an absent
# `agent` field on the roster record is the correct current-stage state, not
# a regression); this file only pins the LAUNCH LINE regression step 3
# itself requires.

# --- the portable crew command vocabulary block: claude's own bare-filename
#     rendering ---------------------------------------------------------------
# claude is the one adapter whose command files keep their bare filenames
# (the whole design's linchpin - Claude Code ignores a command file's `name`
# frontmatter and resolves by filename instead) - the brief must render
# "/status", never "/wingman-status", even though the skill's own `name`
# frontmatter is wingman-status like every other adapter's.
sysprompt_body="$(cat "$sysprompt")"
assert_contains "the crew command vocabulary block is present" "$sysprompt_body" "The crew command vocabulary."
assert_contains "claude's own example renders the bare filename form" "$sysprompt_body" "e.g. \`/status\` invokes"
assert_not_contains "never the wingman-prefixed form on claude" "$sysprompt_body" "e.g. \`/wingman-status\`"
assert_contains "spawn/standdown are named as deliberately absent" "$sysprompt_body" "\`spawn\` and \`standdown\` are never exported as skills"

test_summary
