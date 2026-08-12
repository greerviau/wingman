#!/usr/bin/env bash
# E2E + unit: hooks/lib/guard_policy.py (issue #25 stage 3, plan step 12a) -
# the transport-agnostic core extracted from no-merge-guard.sh,
# no-direct-edit-guard.sh, and no-worker-spawn-guard.sh. The three rewired
# hook scripts already keep their own ~1,900-line E2E suites (tests/no-
# merge-guard.test.sh, tests/no-direct-edit-guard.test.sh, tests/no-worker-
# spawn-guard.test.sh) passing unchanged - that is the primary drift net for
# everything those suites already cover. This file adds the two invariants
# the stage-3 design review required as explicit, tested guarantees rather
# than incidental fixture coverage:
#
#   1. Two OPPOSITE fail-directions for the same absent crew_type field,
#      exercised directly against the core's own functions (not through a
#      bash entry point), proving the guarantee holds at the module level
#      and cannot be lost to a future refactor that merges the three
#      evaluate_*() functions into one.
#   2. Decision equivalence: a corpus of real commands run through BOTH the
#      pre-extraction hook scripts (read from the stage-2 branch this stage
#      stacks on, before 12a touched them) and the post-extraction ones
#      (this checkout), asserting byte-identical stdout for every case.
#
# Corpus cases are deliberately chosen to never require a live network call
# (no case reaches no-merge-guard's gh-pr-view evidence check with a grant
# that isn't also review_gate_waived, which short-circuits before any call).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

GP_PYTHONPATH="$TEST_REPO/hooks/lib"

# =============================================================================
# Part 1: fail-direction invariant, exercised directly against the core
# =============================================================================
invariant_out="$(PYTHONPATH="$GP_PYTHONPATH" uv run --no-project --quiet python -c '
import sys
from guard_policy import GuardInput, GuardDenied, evaluate_no_worker_spawn_guard, evaluate_no_direct_edit_guard, no_direct_edit_guard_active

def gi(**over):
    base = dict(tool_name="", command="", cwd="/tmp", crew_id="dev1", crew_type="",
                file_path="", notebook_path="", project_dir="", home="/tmp/wm-guard-policy-invariant")
    base.update(over)
    return GuardInput(**base)

# no-worker-spawn-guard: crew_id set, crew_type EMPTY -> must fail CLOSED (deny).
spawn_denied = False
try:
    evaluate_no_worker_spawn_guard(gi(
        tool_name="Bash", command="bin/spawn-crew --type developer --repo x --objective y"))
except GuardDenied:
    spawn_denied = True
print("spawn:%s" % ("denied" if spawn_denied else "allowed"))

# no-direct-edit-guard: crew_id set, crew_type EMPTY -> must fail OPEN (allow/no-op) -
# no_direct_edit_guard_active() returns False for this shape (not "lead", and the
# wingman-own-session arm requires crew_id EMPTY, which it is not here), so the
# function returns without ever reaching the Edit-denial branch.
edit_denied = False
try:
    evaluate_no_direct_edit_guard(gi(
        tool_name="Edit", file_path="/tmp/wm-guard-policy-invariant-repo/file.py"))
except GuardDenied:
    edit_denied = True
print("edit:%s" % ("denied" if edit_denied else "allowed"))

# PR #338 review round 2, must-fix 1: the corpus case originally named for
# this (see Part 2 history) went through the full bash entry point, whose
# OWN unchanged activation pre-gate short-circuits before crew_id is unset
# and CLAUDE_PROJECT_DIR is not set in this test context - both the buggy
# (round-1) rsplit-based core and the fixed exact-match core produce the
# identical bash-level outcome there regardless of which one is actually
# running, so that corpus case could never fail even reverted to the bug
# (reviewer confirmed this by mutation). Asserting no_direct_edit_guard_
# active() directly, bypassing the bash pre-gate entirely, is what actually
# exercises the fixed comparison: a category-qualified lead type
# ("common/lead") must stay INACTIVE, matching the original bash pre-gate'"'"'s
# own exact string comparison (`= "lead"`), not the base-role-name match
# no-worker-spawn-guard uses for its own, different, caller-is-lead check.
qualified_lead_active = no_direct_edit_guard_active(gi(tool_name="Edit", crew_type="common/lead"))
print("qualified_lead_active:%s" % qualified_lead_active)
')"
assert_contains "no-worker-spawn-guard fails CLOSED on an absent crew_type" "$invariant_out" "spawn:denied"
assert_contains "no-direct-edit-guard fails OPEN on an absent crew_type (opposite direction)" "$invariant_out" "edit:allowed"
assert_contains "no-direct-edit-guard stays inactive for a category-qualified lead type (exact-match only, asserted directly against the core)" "$invariant_out" "qualified_lead_active:False"

# =============================================================================
# Part 2: decision equivalence - pre-extraction hooks vs the rewired ones
# =============================================================================
# The pre-extraction blobs are static, checked-in fixtures (tests/fixtures/
# guard-policy-pre-extraction/*.sh - byte-identical copies of the three hooks
# as they stood immediately before 12a's extraction), NOT read live from a
# git ref (PR #338 review round 1, must-fix): a branch name is neither
# durable (it disappears the moment the stage-2 branch merges and gets
# deleted, breaking this suite permanently the day the PR that requires it
# lands) nor even reliably present in a fresh clone today (a shallow CI
# checkout has no reason to fetch a sibling branch by name at all, so this
# failed 22-run/10-failed in the reviewer's own fresh-clone repro despite
# passing in this session's own worktree, which happened to have every
# stacked branch created locally). Copied into throwaway files placed IN
# hooks/ itself (not a separate tmp dir) so their own
# `HERE="$(cd "$(dirname "$0")" && pwd -P)"` resolves to the real hooks/
# directory and finds the real (unmodified by this stage) hooks/lib/
# cmd_match.py - removed unconditionally before test_summary, matching this
# suite's established throwaway-descriptor convention (this file cannot use
# its own `trap ... EXIT`; lib.sh's shared trap is the only one allowed).
FIXTURE_DIR="$TEST_REPO/tests/fixtures/guard-policy-pre-extraction"
OLD_MERGE="$TEST_REPO/hooks/no-merge-guard.OLD.sh"
OLD_EDIT="$TEST_REPO/hooks/no-direct-edit-guard.OLD.sh"
OLD_SPAWN="$TEST_REPO/hooks/no-worker-spawn-guard.OLD.sh"
cp "$FIXTURE_DIR/no-merge-guard.sh" "$OLD_MERGE"
cp "$FIXTURE_DIR/no-direct-edit-guard.sh" "$OLD_EDIT"
cp "$FIXTURE_DIR/no-worker-spawn-guard.sh" "$OLD_SPAWN"
chmod +x "$OLD_MERGE" "$OLD_EDIT" "$OLD_SPAWN"
# PR #338 review round 2, must-fix 2: an empty or missing fixture (a bad
# checkout, a botched future edit to tests/fixtures/guard-policy-pre-
# extraction/) makes the "old" side of every equivalence_check below exit 0
# with no output regardless of input - silently losing every denial
# comparison rather than failing loudly. Reviewer reproduced by deleting one
# fixture: 23 run, 6 failed - the exact phantom "lost every denial" shape
# the original extraction bug itself would have produced, not an obvious
# setup error a future maintainer could tell apart from a real regression.
# Fail fast and explicitly instead.
for _fixture in "$OLD_MERGE" "$OLD_EDIT" "$OLD_SPAWN"; do
  [ -s "$_fixture" ] || { echo "guard-policy.test.sh: fixture copy at $_fixture is empty or missing - refusing to run the decision-equivalence corpus against a broken baseline" >&2; exit 1; }
done

NEW_MERGE="$TEST_REPO/hooks/no-merge-guard.sh"
NEW_EDIT="$TEST_REPO/hooks/no-direct-edit-guard.sh"
NEW_SPAWN="$TEST_REPO/hooks/no-worker-spawn-guard.sh"

# equivalence_check <label> <old-hook> <new-hook> <json-payload>
# Runs the SAME payload through both hook scripts under the SAME env (the
# caller has already exported whatever env vars this case needs) and asserts
# byte-identical stdout.
equivalence_check() {
  _ec_label="$1"; _ec_old="$2"; _ec_new="$3"; _ec_payload="$4"
  _ec_old_out="$(printf '%s' "$_ec_payload" | bash "$_ec_old" 2>/dev/null)"
  _ec_new_out="$(printf '%s' "$_ec_payload" | bash "$_ec_new" 2>/dev/null)"
  assert_eq "decision equivalence: $_ec_label" "$_ec_new_out" "$_ec_old_out"
}

payload() {
  # payload <tool_name> <command> [cwd] [file_path] [notebook_path]
  uv run --no-project --quiet python -c '
import json, sys
d = {"tool_name": sys.argv[1], "tool_input": {}}
if sys.argv[2]:
    d["tool_input"]["command"] = sys.argv[2]
if len(sys.argv) > 3 and sys.argv[3]:
    d["cwd"] = sys.argv[3]
if len(sys.argv) > 4 and sys.argv[4]:
    d["tool_input"]["file_path"] = sys.argv[4]
if len(sys.argv) > 5 and sys.argv[5]:
    d["tool_input"]["notebook_path"] = sys.argv[5]
print(json.dumps(d))
' "$1" "${2:-}" "${3:-}" "${4:-}" "${5:-}"
}

# --- a real scratch repo with a resolvable origin/HEAD (default branch =
# main), mirroring tests/no-merge-guard.test.sh's own setup, so the git-push
# corpus cases exercise real default-branch resolution rather than the
# fallback guess. -------------------------------------------------------------
SCRATCH="$(wm_mktemp_dir)"
BARE="$SCRATCH/origin.git"
git init -q --bare "$BARE"
CLONE="$SCRATCH/work"
git clone -q "$BARE" "$CLONE"
(
  cd "$CLONE"
  git checkout -q -b main
  echo hi > a.txt
  git -c user.email=a@a -c user.name=a add a.txt
  git -c user.email=a@a -c user.name=a commit -q -m init
  git push -q origin main
  git remote set-head origin main
  git checkout -q -b feature/foo
)

test_new_home
export WINGMAN_HOME

# --- no-merge-guard corpus ----------------------------------------------------
unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE
equivalence_check "no-merge: non-crew gh pr merge is allowed" \
  "$OLD_MERGE" "$NEW_MERGE" "$(payload Bash "gh pr merge 46")"
equivalence_check "no-merge: non-crew git push origin main is allowed" \
  "$OLD_MERGE" "$NEW_MERGE" "$(payload Bash "git push origin main" "$CLONE")"

export WINGMAN_CREW_ID=dev1 WINGMAN_CREW_TYPE=developer
equivalence_check "no-merge: crew, no grant, gh pr merge is denied" \
  "$OLD_MERGE" "$NEW_MERGE" "$(payload Bash "gh pr merge 46")"
equivalence_check "no-merge: crew, no grant, gh pr merge --auto is denied" \
  "$OLD_MERGE" "$NEW_MERGE" "$(payload Bash "gh pr merge --auto")"
equivalence_check "no-merge: crew, git push to default branch is denied" \
  "$OLD_MERGE" "$NEW_MERGE" "$(payload Bash "git push origin main" "$CLONE")"
equivalence_check "no-merge: crew, git push to a feature branch is allowed" \
  "$OLD_MERGE" "$NEW_MERGE" "$(payload Bash "git push origin feature/foo" "$CLONE")"
equivalence_check "no-merge: crew, self-grant --allow-merge is denied" \
  "$OLD_MERGE" "$NEW_MERGE" "$(payload Bash 'wm-state crew-set --id dev1 --allow-merge true')"
equivalence_check "no-merge: crew, crew-add is denied outright" \
  "$OLD_MERGE" "$NEW_MERGE" "$(payload Bash 'wm-state crew-add --id x --type reviewer --repo y --window w --session-id s')"
equivalence_check "no-merge: crew, an unrelated command is allowed" \
  "$OLD_MERGE" "$NEW_MERGE" "$(payload Bash "ls -la")"
equivalence_check "no-merge: crew, an unparseable merge-mentioning command is denied" \
  "$OLD_MERGE" "$NEW_MERGE" "$(payload Bash "gh pr merge \"unterminated")"

export WINGMAN_CREW_TYPE=lead
equivalence_check "no-merge: lead granting a worker (not itself) is allowed" \
  "$OLD_MERGE" "$NEW_MERGE" "$(payload Bash 'wm-state crew-set --id worker1 --allow-merge true')"
unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

# --- no-direct-edit-guard corpus ----------------------------------------------
EDIT_REPO="$(wm_mktemp_dir)/edit-repo"
mkdir -p "$EDIT_REPO"
git -C "$EDIT_REPO" init -q
OUTSIDE_DIR="$(wm_mktemp_dir)"

export WINGMAN_CREW_TYPE=lead
equivalence_check "no-direct-edit: lead, Edit inside a git repo is denied" \
  "$OLD_EDIT" "$NEW_EDIT" "$(payload Edit "" "" "$EDIT_REPO/x.py")"
equivalence_check "no-direct-edit: lead, Edit outside any git repo is allowed" \
  "$OLD_EDIT" "$NEW_EDIT" "$(payload Edit "" "" "$OUTSIDE_DIR/x.py")"
equivalence_check "no-direct-edit: lead, a test-runner Bash call is denied" \
  "$OLD_EDIT" "$NEW_EDIT" "$(payload Bash "pytest")"
equivalence_check "no-direct-edit: lead, an ordinary Bash call is allowed" \
  "$OLD_EDIT" "$NEW_EDIT" "$(payload Bash "git status")"

# PR #338 review round 1, should-fix (the exact-match lead check) is covered
# in Part 1 above, directly against no_direct_edit_guard_active(), not here:
# review round 2, must-fix 1 found that an equivalence_check for this shape
# routes through both hook scripts' OWN UNCHANGED bash activation pre-gate,
# which exits before crew_id/CLAUDE_PROJECT_DIR ever reach python in this
# test's own env (crew_id unset, no CLAUDE_PROJECT_DIR) - so it produces the
# identical bash-level outcome whether the core's own comparison is exact-
# match or the round-1 base-role-name bug, and can never actually fail
# either way (reviewer confirmed by reverting the fix and re-running: still
# 23/23). A corpus case cannot exercise this specific property at all while
# the bash pre-gate stays in front of it by design (must-fix 1.3's own
# reasoning); asserting the core function directly is the only way to.

export WINGMAN_CREW_TYPE=developer
equivalence_check "no-direct-edit: a worker's own Edit inside a git repo is allowed (inactive)" \
  "$OLD_EDIT" "$NEW_EDIT" "$(payload Edit "" "" "$EDIT_REPO/x.py")"
unset WINGMAN_CREW_TYPE

# --- no-worker-spawn-guard corpus ---------------------------------------------
export WINGMAN_CREW_ID=dev1 WINGMAN_CREW_TYPE=developer
equivalence_check "no-worker-spawn: a worker spawning anything is denied" \
  "$OLD_SPAWN" "$NEW_SPAWN" "$(payload Bash "bin/spawn-crew --type reviewer --repo x --objective y")"

export WINGMAN_CREW_TYPE=lead
equivalence_check "no-worker-spawn: a lead spawning a worker is allowed" \
  "$OLD_SPAWN" "$NEW_SPAWN" "$(payload Bash "bin/spawn-crew --type developer --repo x --objective y")"
equivalence_check "no-worker-spawn: a lead spawning a further lead is denied" \
  "$OLD_SPAWN" "$NEW_SPAWN" "$(payload Bash "bin/spawn-crew --type lead --repo x --objective y")"
unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

equivalence_check "no-worker-spawn: wingman's own top-level session spawning a lead is allowed" \
  "$OLD_SPAWN" "$NEW_SPAWN" "$(payload Bash "bin/spawn-crew --type lead --repo x --objective y")"

rm -f "$OLD_MERGE" "$OLD_EDIT" "$OLD_SPAWN"

test_summary
