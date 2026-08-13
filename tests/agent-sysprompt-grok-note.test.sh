#!/usr/bin/env bash
# E2E: wm_agent_emit_sysprompt's grok-only note append (bin/lib/agent.sh).
#
# Grok Build has no way to exclude this repo's AGENTS.md from a crew
# session's context, so wm_agent_emit_sysprompt appends
# bin/lib/agents/grok-crew-note.md to a grok crew member's own composed
# brief - a note appended for grok, and no other adapter, without mutating
# the original sysprompt file itself. Exercised here by calling
# wm_agent_emit_sysprompt directly with hand-set WM_AGENT_* fields, not by
# spawning a real --agent grok crew member: bin/lib/agents/grok.sh may or
# may not exist yet at any given point in this repo's history (it ships in
# a separate, independent change), and this behavior must hold either way.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$TEST_REPO/bin/lib/common.sh"
. "$TEST_REPO/bin/lib/agent.sh"

test_new_home

sysprompt="$(wm_mktemp_file)"
printf 'the assignment and playbook body\n' > "$sysprompt"

# --- WM_AGENT_BIN=grok: the emitted flag reads a combined file, not the ------
# --- bare sysprompt file, and that combined file carries both texts ---------
WM_AGENT_SYSPROMPT_MODE=flag
WM_AGENT_SYSPROMPT_FLAG='--rules "$(cat %s)"'
WM_AGENT_BIN=grok
# Emitted via file redirection, not "$(...)": wm_agent_emit_sysprompt's own
# WM_AGENT_OPENING_DELIVERED_AT_LAUNCH side effect (like the real launch-line
# composition in bin/spawn-crew/bin/crew-resume) must land in THIS shell, and
# a command-substitution subshell would swallow it.
out_file="$(wm_mktemp_file)"
wm_agent_emit_sysprompt "$sysprompt" "the opening objective" > "$out_file"
out="$(cat "$out_file")"

assert_eq "the opening objective is not folded into a flag-mode emission" "$WM_AGENT_OPENING_DELIVERED_AT_LAUNCH" "0"
assert_not_contains "the bare sysprompt path alone is not what gets composed for grok" "$out" "--rules \"\$(cat '$sysprompt')\""
assert_contains "the composed flag points at a sibling file, not the original" "$out" "--rules \"\$(cat '$sysprompt.grok-note.md')\""

combined="$sysprompt.grok-note.md"
assert_true "the combined file was written" "[ -f '$combined' ]"
combined_body="$(cat "$combined")"
assert_contains "the combined file still carries the original sysprompt content" "$combined_body" "the assignment and playbook body"
assert_contains "the combined file also carries the grok crew-session note" "$combined_body" "AGENTS.md"
assert_contains "the note explains Grok Build's own reason for seeing it" "$combined_body" "Grok Build has no way to exclude"

sysprompt_body="$(cat "$sysprompt")"
assert_not_contains "the original sysprompt file itself is never mutated" "$sysprompt_body" "AGENTS.md"

# --- the note's own committed text never cites a tracker number -------------
note_file="$TEST_REPO/bin/lib/agents/grok-crew-note.md"
assert_true "the grok crew-session note file exists" "[ -f '$note_file' ]"
assert_true "the note's own text never cites an issue/PR number" \
  "! grep -Eq '#[0-9]+' '$note_file'"

# --- every other adapter's own sysprompt-file value is left alone -----------
for other_bin in claude pi some-future-cli; do
  WM_AGENT_BIN="$other_bin"
  wm_agent_emit_sysprompt "$sysprompt" "the opening objective" > "$out_file"
  other_out="$(cat "$out_file")"
  assert_contains "WM_AGENT_BIN=$other_bin still composes the bare sysprompt file path" \
    "$other_out" "--rules \"\$(cat '$sysprompt')\""
  assert_not_contains "WM_AGENT_BIN=$other_bin never gets the grok note file appended" \
    "$other_out" "grok-note.md"
done

test_summary
