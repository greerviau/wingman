#!/usr/bin/env bash
# E2E: the mechanical claudeMdExcludes exclusion (issue #213). The prose
# disclaimer (tested in spawn-wm-repo-note.test.sh) is a mitigation a crew
# member can ignore or misread; this is the actual fix - wingman's own root
# CLAUDE.md (and its worktree-sibling copy) must never auto-load into a crew
# session's context, applied unconditionally regardless of scope or target,
# not gated on TARGET_IS_WM_REPO the way the disclaimer is.
#
# Proves the exclusion payload is emitted at every site a crew session's
# command line is constructed: bin/spawn-crew's generated .launch.sh (for a
# repo-scope spawn targeting wingman itself, an unrelated repo, and a
# global-scope spawn), and bin/crew-takeover's printed resume command for a
# member with no live window. bin/crew-resume's own generated .resume.sh is
# covered separately, in crew-resume.test.sh (it already owns that artifact).
# Uses a stub agent (WM_AGENT_BIN_OVERRIDE) and an isolated tmux session so no
# real claude launches and the live fleet is untouched.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SPAWN="$TEST_REPO/bin/spawn-crew"
TAKEOVER="$TEST_REPO/bin/crew-takeover"

# An unrelated workspace: a plain git repo with no connection to wingman.
WS="$(wm_mktemp_dir)/workspace"
mkdir -p "$WS/repoA"
git -C "$WS/repoA" init -q
printf '#!/usr/bin/env bash\nexec sleep 60\n' > "$WS/stub.sh"; chmod +x "$WS/stub.sh"

export WM_AGENT_BIN_OVERRIDE="$WS/stub.sh" WM_SPAWN_DELAY=0 WM_SUBMIT_DELAY=0 WM_READY_TRIES=4 WM_READY_POLL=0 \
  WM_SUBMIT_POLL=0.2 WM_SUBMIT_TRIES=1
test_new_home
# Same fixture shape as spawn-wm-repo-note.test.sh: [projects].roots points
# global-scope discovery at the unrelated workspace, and [projects.pins] pins
# this very checkout (TEST_REPO, since $SPAWN is invoked from it) into the
# discovered set, so the global-scope case genuinely exercises "wingman repo
# is among the discovered/added repos."
wm_write_config <<EOF
[projects]
roots = ["$WS"]

[projects.pins]
wingman-pinned = "$TEST_REPO"
EOF
wm_trust_repo "$TEST_REPO"
wm_trust_repo "$WS/repoA"
wm_trust_repo "$WS"

# --- repo scope, target is the wingman repo's own root -------------------------
wid="$("$SPAWN" --type software-analyst --repo "$TEST_REPO" --objective "edit a playbook" 2>/dev/null | tail -1)"
assert_true "spawn against the wingman repo root succeeds" "[ -n '$wid' ]"
wlaunch="$(cat "$WINGMAN_HOME/crew/$wid.launch.sh")"
assert_contains "the launch script carries --settings" "$wlaunch" "--settings"
assert_contains "the exclusion payload is present" "$wlaunch" "claudeMdExcludes"
assert_contains "the exclusion names the repo root's CLAUDE.md" "$wlaunch" "$TEST_REPO/CLAUDE.md"
assert_contains "the exclusion names the repo root's CLAUDE.local.md" "$wlaunch" "$TEST_REPO/CLAUDE.local.md"
assert_contains "the exclusion names the repo root's .claude/CLAUDE.md" "$wlaunch" "$TEST_REPO/.claude/CLAUDE.md"
assert_contains "the exclusion names the repo root's .claude/rules glob" "$wlaunch" "$TEST_REPO/.claude/rules/**"
assert_contains "the exclusion also names the worktree-sibling glob's CLAUDE.md" "$wlaunch" "$TEST_REPO-*/CLAUDE.md"
assert_contains "the exclusion also names the worktree-sibling glob's CLAUDE.local.md" "$wlaunch" "$TEST_REPO-*/CLAUDE.local.md"

# --- repo scope, target is an unrelated repo: still unconditionally present ----
# The regression guard against re-introducing a TARGET_IS_WM_REPO-only gate:
# the payload is a no-op against this target (none of the named paths exist
# under it), but it must still be emitted, unconditionally, like every other
# --add-dir in this block.
rid="$("$SPAWN" --type software-analyst --repo "$WS/repoA" --objective "unrelated repo work" 2>/dev/null | tail -1)"
assert_true "spawn against an unrelated repo succeeds" "[ -n '$rid' ]"
rlaunch="$(cat "$WINGMAN_HOME/crew/$rid.launch.sh")"
assert_contains "the exclusion is present even for an unrelated target repo" "$rlaunch" "claudeMdExcludes"
assert_contains "the exclusion still names the wingman repo's own CLAUDE.md, not the target's" \
  "$rlaunch" "$TEST_REPO/CLAUDE.md"

# --- global scope: present, worktree glob included ------------------------------
gid="$("$SPAWN" --type software-analyst --scope global --objective "cross repo cleanup" 2>/dev/null | tail -1)"
assert_true "global-scope spawn succeeds" "[ -n '$gid' ]"
glaunch="$(cat "$WINGMAN_HOME/crew/$gid.launch.sh")"
assert_true "the wingman repo is genuinely among the global-scope add-dirs (pin took effect)" \
  "printf '%s' \"\$glaunch\" | grep -qF '$TEST_REPO'"
assert_contains "the exclusion is present for a global-scope spawn" "$glaunch" "claudeMdExcludes"
assert_contains "the exclusion's worktree glob is present for a global-scope spawn" \
  "$glaunch" "$TEST_REPO-*/CLAUDE.md"

# --- crew-takeover: a member with no live window ---------------------------------
# Simulated the same way tests/dead-lead-orphans.test.sh does: a roster record
# with no corresponding tmux session at all, so crew-takeover's own live check
# fails and it takes the "no live window" branch. No tmux session for
# $WM_TMUX_SESSION is ever created in this block, deliberately.
wm_state crew-add --id dead1 --type developer --objective "fix a bug" --repo "$TEST_REPO" \
  --window wm-dead1 --session-id sess-dead1 >/dev/null
tout="$("$TAKEOVER" dead1 2>&1)"
assert_contains "crew-takeover reports no live window" "$tout" "no live window"
assert_contains "the printed resume command carries --settings" "$tout" "--settings"
assert_contains "the printed resume command carries the exclusion payload" "$tout" "claudeMdExcludes"
assert_contains "the exclusion names the repo root's CLAUDE.md" "$tout" "$TEST_REPO/CLAUDE.md"
# Exactly one --resume invocation is printed (round 3's fix collapsed the
# second, previously-unpatched copy-pasteable form into a bare caveat with no
# command of its own, rather than leaving a second command a human could
# paste that lacks the exclusion).
resume_count="$(printf '%s' "$tout" | grep -o -- '--resume' | wc -l | tr -d ' ')"
assert_eq "exactly one --resume command is printed" "$resume_count" "1"

test_summary
