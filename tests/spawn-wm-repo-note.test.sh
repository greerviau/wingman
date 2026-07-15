#!/usr/bin/env bash
# E2E: the CLAUDE.md persona-collision disambiguation note (issue #69).
# bin/spawn-crew injects a preamble into a crew member's composed system
# prompt (.sysprompt.md) whenever, and only whenever, that member's cwd will
# be the wingman repo's own root - the one case where Claude Code's automatic
# CLAUDE.md auto-load pulls in the orchestrator's own first-person persona
# file for a crew session to read. Proves: present for a repo-scoped spawn
# targeting the wingman repo root itself; absent for a repo-scoped spawn
# against an unrelated repo; absent for a global-scope spawn even when the
# wingman repo is among the discovered/added repos (global scope's cwd is the
# workspace root, not the wingman repo, so the auto-load hazard never fires
# there). Uses a stub agent (WM_AGENT) and an isolated tmux session so no real
# claude launches and the live fleet is untouched.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SPAWN="$TEST_REPO/bin/spawn-crew"
NOTE_MARKER="About this repo's CLAUDE.md"

# An unrelated workspace: a plain git repo with no connection to wingman.
WS="$(wm_mktemp_dir)/workspace"
mkdir -p "$WS/repoA"
git -C "$WS/repoA" init -q
printf '#!/usr/bin/env bash\nexec sleep 60\n' > "$WS/stub.sh"; chmod +x "$WS/stub.sh"

# WM_ROOTS points global-scope discovery at this unrelated workspace (so its
# workspace root, not the wingman repo, becomes cwd for the global-scope
# case). WM_PINS pins the wingman repo itself (TEST_REPO - this very checkout,
# since $SPAWN is invoked from it and bin/lib/common.sh derives WM_REPO from
# the invoked script's own location) into the discovered set under a
# collision-free name, so the global-scope case genuinely exercises "wingman
# repo is among the discovered/added repos" rather than trivially never
# encountering it. Guard against clobbering a real config.local.sh.
CFG="$TEST_REPO/config.local.sh"
if [ -e "$CFG" ]; then echo "SKIP: $CFG exists; not overwriting"; exit 0; fi
{
  printf 'WM_ROOTS=%q\n' "$WS"
  printf 'WM_PINS=%q\n' "wingman-pinned|$TEST_REPO"
} > "$CFG"

export WM_AGENT="$WS/stub.sh" WM_SPAWN_DELAY=0 WM_SUBMIT_DELAY=0 WM_READY_TRIES=1 WM_READY_POLL=0 \
  WM_SUBMIT_POLL=0.2 WM_SUBMIT_TRIES=1
test_new_home
wm_on_exit "rm -f '$CFG'"
wm_trust_repo "$TEST_REPO"
wm_trust_repo "$WS/repoA"
wm_trust_repo "$WS"

# --- positive case: repo scope, target is the wingman repo's own root ---------
wid="$("$SPAWN" --type software-analyst --repo "$TEST_REPO" --objective "edit a playbook" 2>/dev/null | tail -1)"
assert_true "spawn against the wingman repo root succeeds" "[ -n '$wid' ]"
wsysprompt="$WINGMAN_HOME/crew/$wid.sysprompt.md"
assert_true "sysprompt is written" "[ -f '$wsysprompt' ]"
assert_contains "the note is present when the target repo is the wingman repo itself" \
  "$(cat "$wsysprompt")" "$NOTE_MARKER"
assert_contains "the note names the crew's own type, not a generic hedge" \
  "$(cat "$wsysprompt")" "software-analyst"
# The note must land ahead of the playbook/objective content (right after the
# "Crew id / Type / Repo" header, before the --- separator and playbook body),
# so it is the next thing read once the assignment begins.
note_line="$(grep -n "$NOTE_MARKER" "$wsysprompt" | head -1 | cut -d: -f1)"
sep_line="$(grep -n '^---$' "$wsysprompt" | head -1 | cut -d: -f1)"
assert_true "the note precedes the first --- separator (playbook content)" "[ '$note_line' -lt '$sep_line' ]"

# --- negative case: repo scope, target is an unrelated repo -------------------
rid="$("$SPAWN" --type software-analyst --repo "$WS/repoA" --objective "unrelated repo work" 2>/dev/null | tail -1)"
assert_true "spawn against an unrelated repo succeeds" "[ -n '$rid' ]"
rsysprompt="$WINGMAN_HOME/crew/$rid.sysprompt.md"
assert_false "the note is absent for an unrelated target repo" "grep -qF \"$NOTE_MARKER\" '$rsysprompt'"

# --- global scope: absent even though the wingman repo is among the discovered/added repos ---
gid="$("$SPAWN" --type software-analyst --scope global --objective "cross repo cleanup" 2>/dev/null | tail -1)"
assert_true "global-scope spawn succeeds" "[ -n '$gid' ]"
glaunch="$WINGMAN_HOME/crew/$gid.launch.sh"
assert_true "the wingman repo is genuinely among the global-scope add-dirs (pin took effect)" \
  "grep -qF '$TEST_REPO' '$glaunch'"
gsysprompt="$WINGMAN_HOME/crew/$gid.sysprompt.md"
assert_false "the note is absent for a global-scope spawn" "grep -qF \"$NOTE_MARKER\" '$gsysprompt'"

test_summary
