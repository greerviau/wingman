#!/usr/bin/env bash
# E2E: repo vs global scope in bin/spawn-crew, and the conditional git/branch/PR
# workflow (docs/plans/2026-07-13-conditional-git-branch-pr-workflow.md). Proves:
# global scope grounds at the workspace root (no git checkout required there)
# with every discovered repo added and records scope=global; repo scope resolves
# an explicit path by directory-existence (not git-ness), detects IS_GIT/HAS_REMOTE
# mechanically (with the subdirectory rule and physical-path/symlink handling),
# and refuses a software-development spawn against a non-git target while
# allowing every other crew type to spawn there. Uses a stub agent (WM_AGENT)
# and an isolated tmux session so no real claude launches and the live fleet is
# untouched.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SPAWN="$TEST_REPO/bin/spawn-crew"

# is_git/has_remote are real tri-state JSON fields (True/False/None) - `.get(k)
# or ""` would collapse a confirmed False and an absent/None field to the
# identical empty string, which is exactly the bug this plan closes. Print all
# three states distinctly.
git_field_of() {
  wm_state crew-get --id "$1" | uv run --no-project --quiet python -c '
import sys, json
d = json.load(sys.stdin)
v = d.get(sys.argv[1])
print("" if v is None else ("true" if v else "false"))
' "$2"
}
field_of() {
  wm_state crew-get --id "$1" | uv run --no-project --quiet python -c '
import sys, json
print(json.load(sys.stdin).get(sys.argv[1]) or "")
' "$2"
}

# Isolated workspace: a non-git root holding two git repos (no remote
# configured on either - the has-remote=false tier) plus a third with a
# configured remote (the has-remote=true tier).
WS="$(wm_mktemp_dir)/workspace"
mkdir -p "$WS/repoA" "$WS/repoB" "$WS/repoC"
git -C "$WS/repoA" init -q
git -C "$WS/repoB" init -q
git -C "$WS/repoC" init -q
git -C "$WS/repoC" remote add origin https://example.invalid/repoC.git
# A subdirectory of an existing repo root (not the root itself) - the
# subdirectory rule (finding 4) says this reads as non-git.
mkdir -p "$WS/repoA/subdir"
printf '#!/usr/bin/env bash\nexec sleep 60\n' > "$WS/stub.sh"; chmod +x "$WS/stub.sh"

# A real git repo reached only through a symlinked path component (C.8, first
# half): a repo under one real directory, a symlink to its parent elsewhere.
REALPARENT="$(wm_mktemp_dir)/realparent"
mkdir -p "$REALPARENT/repoSym"
git -C "$REALPARENT/repoSym" init -q
SYMBASE="$(wm_mktemp_dir)"
ln -s "$REALPARENT" "$SYMBASE/link"

# A second repo reachable only through a symlinked path, resolved via the
# discover-projects NAME-LOOKUP route rather than an explicit --repo path (C.8,
# second half). Registered as a WM_PINS entry (name|path) rather than
# discovered by an automatic WM_ROOTS scan: `find`'s default (-P, "never follow
# symlinks") does not descend through a symlinked top-level scan root at all
# (verified empirically - bfs/GNU find both refuse to traverse a symlink given
# directly as a search path unless -H/-L is passed, which bin/discover-projects's
# scan deliberately never does), so a scan can never populate the cache with a
# symlinked path in the first place. A pin's path is used verbatim regardless of
# how it was discovered, which is exactly what is needed to exercise
# spawn-crew's own `-P` normalization against a discover-projects-resolved
# (rather than directly-typed) symlinked path.
WS2="$(wm_mktemp_dir)/workspace2"
mkdir -p "$WS2/repoSymName"
git -C "$WS2/repoSymName" init -q
SYMWS2="$(wm_mktemp_dir)/symws2-link"
mkdir -p "$(dirname "$SYMWS2")"
ln -s "$WS2" "$SYMWS2"

# WM_ROOTS (the documented root hint) points discovery at the workspace; WM_PINS
# registers the symlinked-path repo by name (see the comment above WS2). Guard
# against clobbering a real config.local.sh.
CFG="$TEST_REPO/config.local.sh"
if [ -e "$CFG" ]; then echo "SKIP: $CFG exists; not overwriting"; exit 0; fi
{
  printf 'WM_ROOTS=%q\n' "$WS"
  printf 'WM_PINS=%q\n' "repoSymName|$SYMWS2/repoSymName"
} > "$CFG"

export WM_AGENT="$WS/stub.sh" WM_SPAWN_DELAY=0 WM_SUBMIT_DELAY=0 WM_READY_TRIES=1 WM_READY_POLL=0 \
  WM_SUBMIT_POLL=0.2 WM_SUBMIT_TRIES=1
test_new_home
wm_on_exit "rm -f '$CFG'"
wm_trust_repo "$WS"
wm_trust_repo "$WS/repoA"
wm_trust_repo "$WS/repoC"
wm_trust_repo "$WS/repoA/subdir"
wm_trust_repo "$REALPARENT/repoSym"
wm_trust_repo "$WS2/repoSymName"

# --- global scope --------------------------------------------------------------
id="$("$SPAWN" --type software-analyst --scope global --objective "cross repo cleanup" 2>/dev/null | tail -1)"
assert_true "global spawn succeeds" "[ -n '$id' ]"

scope="$(field_of "$id" scope)"
assert_eq "roster records scope=global" "$scope" "global"

launch="$WINGMAN_HOME/crew/$id.launch.sh"
assert_contains "launch cds the workspace root" "$(grep '^cd ' "$launch")" "$WS"
assert_true "launch adds repoA" "grep -q 'repoA' '$launch'"
assert_true "launch adds repoB" "grep -q 'repoB' '$launch'"

# --- repo scope: a discovered git repo grounds there, scope=repo ---------------
rid="$("$SPAWN" --type software-analyst --repo repoA --objective "just repoA" 2>/dev/null | tail -1)"
assert_true "repo-scoped spawn succeeds" "[ -n '$rid' ]"
rscope="$(field_of "$rid" scope)"
assert_eq "repo-scoped record has scope=repo" "$rscope" "repo"
rlaunch="$WINGMAN_HOME/crew/$rid.launch.sh"
assert_contains "repo-scoped launch cds into repoA" "$(grep '^cd ' "$rlaunch")" "repoA"
assert_false "repo-scoped launch does not add the unrelated repoB" "grep -q 'repoB' '$rlaunch'"

# --- repo scope records + exports the worktree path (Fix B / #11) -------------
# The deterministic path is <dirname repo>/<basename repo>-<id>, recorded at spawn
# and exported so a non-graceful exit can still be torn down. Only for a
# confirmed git repo - a worktree is meaningless without one.
assert_contains "repo-scoped launch exports WINGMAN_WORKTREE" "$(grep 'WINGMAN_WORKTREE' "$rlaunch")" "repoA-$rid"
rwt="$(field_of "$rid" worktree)"
assert_contains "repo-scoped record persists the worktree path" "$rwt" "repoA-$rid"
# Global scope cannot predetermine a worktree, so none is exported or recorded.
assert_false "global-scope launch exports no WINGMAN_WORKTREE" "grep -q 'WINGMAN_WORKTREE' '$launch'"
gwt="$(field_of "$id" worktree)"
assert_eq "global-scope record has an empty worktree" "$gwt" ""

# --- repo scope: git-ness is recorded and exported (repoA has no remote) ------
assert_eq "repoA record has is_git=true" "$(git_field_of "$rid" is_git)" "true"
assert_eq "repoA record has has_remote=false (no origin configured)" "$(git_field_of "$rid" has_remote)" "false"
assert_contains "launch exports WINGMAN_IS_GIT=true" "$(grep 'WINGMAN_IS_GIT' "$rlaunch")" "true"
assert_contains "launch exports WINGMAN_HAS_REMOTE=false" "$(grep 'WINGMAN_HAS_REMOTE' "$rlaunch")" "false"

# --- C: has-remote tier (finding 5) --------------------------------------------
cid="$("$SPAWN" --type software-analyst --repo repoC --objective "repoC has a remote" 2>/dev/null | tail -1)"
assert_true "repoC spawn succeeds" "[ -n '$cid' ]"
assert_eq "repoC record has is_git=true" "$(git_field_of "$cid" is_git)" "true"
assert_eq "repoC record has has_remote=true" "$(git_field_of "$cid" has_remote)" "true"
claunch="$WINGMAN_HOME/crew/$cid.launch.sh"
assert_contains "repoC launch exports WINGMAN_HAS_REMOTE=true" "$(grep 'WINGMAN_HAS_REMOTE' "$claunch")" "true"

# --- global scope exports neither variable at all (not even =false) -----------
assert_false "global-scope launch has no WINGMAN_IS_GIT line" "grep -q 'WINGMAN_IS_GIT' '$launch'"
assert_false "global-scope launch has no WINGMAN_HAS_REMOTE line" "grep -q 'WINGMAN_HAS_REMOTE' '$launch'"
gis="$(git_field_of "$id" is_git)"
assert_eq "global-scope record has is_git absent (not false)" "$gis" ""

# --- C.1: a non-git directory now spawns a NON-software-development type ------
# (market-analyst, not software-analyst - the latter is itself a
# software-development playbook and would be refused by the fail-fast below;
# an earlier draft of this test used it by mistake and would have failed
# against this plan's own implementation).
naid="$("$SPAWN" --type market-analyst --repo "$WS" --objective "plain dir spawn" 2>/dev/null | tail -1)"
assert_true "a non-software-development spawn against a plain directory succeeds" "[ -n '$naid' ]"
assert_eq "the plain-directory record has scope=repo" "$(field_of "$naid" scope)" "repo"
assert_eq "the plain-directory record has is_git=false" "$(git_field_of "$naid" is_git)" "false"
assert_eq "the plain-directory record has has_remote absent" "$(git_field_of "$naid" has_remote)" ""
nalaunch="$WINGMAN_HOME/crew/$naid.launch.sh"
assert_contains "the plain-directory launch exports WINGMAN_IS_GIT=false" "$(grep 'WINGMAN_IS_GIT' "$nalaunch")" "false"
assert_false "the plain-directory launch exports no WINGMAN_WORKTREE" "grep -q 'WINGMAN_WORKTREE' '$nalaunch'"

# --- C.2: the software-development fail-fast (finding 2) ----------------------
if "$SPAWN" --type developer --repo "$WS" --objective "should refuse" >/tmp/wm-c2-out.$$ 2>&1; then rc=0; else rc=$?; fi
c2out="$(cat /tmp/wm-c2-out.$$ 2>/dev/null)"; rm -f /tmp/wm-c2-out.$$
assert_true "a developer spawn against a non-git directory is refused" "[ $rc -ne 0 ]"
assert_contains "the refusal names the git requirement" "$c2out" "git checkout"

# --- C.4: a subdirectory of a repo is treated as non-git (finding 4) ----------
sdid="$("$SPAWN" --type market-analyst --repo "$WS/repoA/subdir" --objective "nested in a repo" 2>/dev/null | tail -1)"
assert_true "a spawn against a repo subdirectory succeeds (non-software type)" "[ -n '$sdid' ]"
assert_eq "a repo subdirectory records is_git=false" "$(git_field_of "$sdid" is_git)" "false"
sdlaunch="$WINGMAN_HOME/crew/$sdid.launch.sh"
assert_false "a repo subdirectory launch exports no WINGMAN_WORKTREE" "grep -q 'WINGMAN_WORKTREE' '$sdlaunch'"
if "$SPAWN" --type developer --repo "$WS/repoA/subdir" --objective "should also refuse" >/dev/null 2>&1; then rc=0; else rc=$?; fi
assert_true "a developer spawn against a repo subdirectory is also refused" "[ $rc -ne 0 ]"

# --- C.8: a repo root reached through a symlinked path still detects as git ---
# (the explicit-path route)
symrid="$("$SPAWN" --type software-analyst --repo "$SYMBASE/link/repoSym" --objective "symlinked repo root" 2>/dev/null | tail -1)"
assert_true "a spawn through a symlinked path succeeds" "[ -n '$symrid' ]"
assert_eq "a symlinked repo root still records is_git=true" "$(git_field_of "$symrid" is_git)" "true"
symlaunch="$WINGMAN_HOME/crew/$symrid.launch.sh"
assert_true "a symlinked repo root still exports WINGMAN_WORKTREE" "grep -q 'WINGMAN_WORKTREE' '$symlaunch'"

# (the name-lookup route: repoSymName is reachable only via the symlinked
# WM_ROOTS entry $SYMWS2)
symnid="$("$SPAWN" --type software-analyst --repo repoSymName --objective "symlinked root, name lookup" 2>/dev/null | tail -1)"
assert_true "a name-lookup spawn through a symlinked root succeeds" "[ -n '$symnid' ]"
assert_eq "a name-lookup through a symlinked root still records is_git=true" "$(git_field_of "$symnid" is_git)" "true"

# --- C.9: a bare name colliding with an existing cwd-local directory resolves
# to the directory, not the discovered project (finding 3) --------------------
COLLIDE_DIR="$(wm_mktemp_dir)/collide"
mkdir -p "$COLLIDE_DIR/repoA"   # plain, non-git - collides by name with the
                                # discovered (git) repoA under $WS.
wm_trust_repo "$COLLIDE_DIR/repoA"
colid="$(cd "$COLLIDE_DIR" && "$SPAWN" --type market-analyst --repo repoA --objective "name collision" 2>/dev/null | tail -1)"
assert_true "a spawn against a colliding bare name succeeds" "[ -n '$colid' ]"
col_repo="$(field_of "$colid" repo)"
col_expected="$(cd -P "$COLLIDE_DIR/repoA" && pwd -P)"
assert_eq "the colliding name resolves to the cwd-local directory, not the discovered repo" "$col_repo" "$col_expected"
assert_eq "the cwd-local collision directory records is_git=false" "$(git_field_of "$colid" is_git)" "false"

# --- a genuinely nonexistent path (and an unresolvable name) still fail -------
if "$SPAWN" --type market-analyst --repo "$WS/does-not-exist-anywhere" --objective nope >/dev/null 2>&1; then rc=0; else rc=$?; fi
assert_true "a nonexistent path still fails to spawn" "[ $rc -ne 0 ]"
if "$SPAWN" --type market-analyst --repo no-such-project-xyz --objective nope >/dev/null 2>&1; then rc=0; else rc=$?; fi
assert_true "an unresolvable bare name still fails to spawn" "[ $rc -ne 0 ]"

# --- Remote Control visibility recorded on the roster (issue #96) ------------
# On by default (mirrors the launch flag's own on-by-default/empty-to-disable
# convention): remote_control=true and remote_control_connected=true (no
# ambiguity at spawn - launching with --remote-control starts a session
# actively connected).
rcid="$("$SPAWN" --type software-analyst --repo repoA --objective "rc default on" 2>/dev/null | tail -1)"
assert_true "Remote Control default-on spawn succeeds" "[ -n '$rcid' ]"
assert_eq "default spawn records remote_control=true" "$(git_field_of "$rcid" remote_control)" "true"
assert_eq "default spawn records remote_control_connected=true" "$(git_field_of "$rcid" remote_control_connected)" "true"

norcid="$(WM_REMOTE_CONTROL= "$SPAWN" --type software-analyst --repo repoA --objective "rc disabled" 2>/dev/null | tail -1)"
assert_true "WM_REMOTE_CONTROL= spawn succeeds" "[ -n '$norcid' ]"
assert_eq "disabled spawn records remote_control=false" "$(git_field_of "$norcid" remote_control)" "false"
assert_eq "disabled spawn records remote_control_connected absent (None, not false)" "$(git_field_of "$norcid" remote_control_connected)" ""

# --- model default: --model > $WM_MODEL > agent CLI default -------------------
unset WM_MODEL
nid="$("$SPAWN" --type software-analyst --repo repoA --objective "no model set" 2>/dev/null | tail -1)"
assert_false "no --model and no WM_MODEL leaves the agent default" \
  "grep -q -- '--model' '$WINGMAN_HOME/crew/$nid.launch.sh'"
mid="$(WM_MODEL=opus "$SPAWN" --type software-analyst --repo repoA --objective "env model" 2>/dev/null | tail -1)"
assert_contains "WM_MODEL is the default when --model is not passed" \
  "$(grep -- '--model' "$WINGMAN_HOME/crew/$mid.launch.sh")" "--model 'opus'"
xid="$(WM_MODEL=opus "$SPAWN" --type software-analyst --repo repoA --objective "explicit model" --model sonnet 2>/dev/null | tail -1)"
assert_contains "an explicit --model wins over WM_MODEL" \
  "$(grep -- '--model' "$WINGMAN_HOME/crew/$xid.launch.sh")" "--model 'sonnet'"

# --- config.local.sh wiring (issue #13): WM_MODEL sourced via lib/common.sh --
# Previously only WM_ROOTS/WM_IGNORE/WM_PINS were sourced from config.local.sh,
# and only by discover-projects - a WM_MODEL set there had no effect anywhere.
# Appended to the shared $CFG only now, after every test above that depends on
# WM_MODEL being otherwise unset has already run.
printf 'WM_MODEL=%q\n' "config-local-test-model" >> "$CFG"
unset WM_MODEL
cfgmid="$("$SPAWN" --type software-analyst --repo repoA --objective "config.local.sh model" 2>/dev/null | tail -1)"
assert_true "spawn with config.local.sh WM_MODEL succeeds" "[ -n '$cfgmid' ]"
assert_contains "config.local.sh WM_MODEL is picked up absent --model/env WM_MODEL" \
  "$(grep -- '--model' "$WINGMAN_HOME/crew/$cfgmid.launch.sh")" "--model 'config-local-test-model'"

# --- argument guards ---------------------------------------------------------
if "$SPAWN" --type software-analyst --scope bogus --objective x >/dev/null 2>&1; then rc=0; else rc=$?; fi
assert_true "invalid --scope is rejected" "[ $rc -ne 0 ]"
if "$SPAWN" --type software-analyst --scope global --repo repoA --objective x >/dev/null 2>&1; then rc=0; else rc=$?; fi
assert_true "--scope global with --repo is rejected" "[ $rc -ne 0 ]"

test_summary
