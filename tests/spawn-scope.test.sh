#!/usr/bin/env bash
# E2E: repo vs global scope in bin/spawn-crew. Proves global scope grounds at the
# workspace root (no git checkout required there) with every discovered repo
# added, records scope=global, and that the git-checkout requirement still holds
# for repo scope. Uses a stub agent (WM_AGENT) and an isolated tmux session so no
# real claude launches and the live fleet is untouched.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SPAWN="$TEST_REPO/bin/spawn-crew"

# Isolated workspace: a non-git root holding two git repos.
WS="$(mktemp -d)/workspace"
mkdir -p "$WS/repoA" "$WS/repoB"
git -C "$WS/repoA" init -q
git -C "$WS/repoB" init -q
printf '#!/usr/bin/env bash\nexec sleep 60\n' > "$WS/stub.sh"; chmod +x "$WS/stub.sh"

# WM_ROOTS (the documented root hint) points discovery at the workspace. Guard
# against clobbering a real config.local.sh.
CFG="$TEST_REPO/config.local.sh"
if [ -e "$CFG" ]; then echo "SKIP: $CFG exists; not overwriting"; exit 0; fi
printf 'WM_ROOTS=%q\n' "$WS" > "$CFG"

export WM_AGENT="$WS/stub.sh" WM_SPAWN_DELAY=0 WM_SUBMIT_DELAY=0
test_new_home

cleanup() { rm -f "$CFG"; tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null; }
trap cleanup EXIT

# --- global scope ------------------------------------------------------------
id="$("$SPAWN" --type software-analyst --scope global --objective "cross repo cleanup" 2>/dev/null | tail -1)"
assert_true "global spawn succeeds" "[ -n '$id' ]"

scope="$(wm_state crew-get --id "$id" | uv run --no-project --quiet python -c 'import sys,json;print(json.load(sys.stdin).get("scope"))')"
assert_eq "roster records scope=global" "$scope" "global"

launch="$WINGMAN_HOME/crew/$id.launch.sh"
assert_contains "launch cds the workspace root" "$(grep '^cd ' "$launch")" "$WS"
assert_true "launch adds repoA" "grep -q 'repoA' '$launch'"
assert_true "launch adds repoB" "grep -q 'repoB' '$launch'"

# --- repo scope: a discovered git repo grounds there, scope=repo -------------
rid="$("$SPAWN" --type software-analyst --repo repoA --objective "just repoA" 2>/dev/null | tail -1)"
assert_true "repo-scoped spawn succeeds" "[ -n '$rid' ]"
rscope="$(wm_state crew-get --id "$rid" | uv run --no-project --quiet python -c 'import sys,json;print(json.load(sys.stdin).get("scope"))')"
assert_eq "repo-scoped record has scope=repo" "$rscope" "repo"
rlaunch="$WINGMAN_HOME/crew/$rid.launch.sh"
assert_contains "repo-scoped launch cds into repoA" "$(grep '^cd ' "$rlaunch")" "repoA"
assert_false "repo-scoped launch does not add the unrelated repoB" "grep -q 'repoB' '$rlaunch'"

# --- repo scope records + exports the worktree path (Fix B / #11) -------------
# The deterministic path is <dirname repo>/<basename repo>-<id>, recorded at spawn
# and exported so a non-graceful exit can still be torn down.
assert_contains "repo-scoped launch exports WINGMAN_WORKTREE" "$(grep 'WINGMAN_WORKTREE' "$rlaunch")" "repoA-$rid"
rwt="$(wm_state crew-get --id "$rid" | uv run --no-project --quiet python -c 'import sys,json;print(json.load(sys.stdin).get("worktree"))')"
assert_contains "repo-scoped record persists the worktree path" "$rwt" "repoA-$rid"
# Global scope cannot predetermine a worktree, so none is exported or recorded.
assert_false "global-scope launch exports no WINGMAN_WORKTREE" "grep -q 'WINGMAN_WORKTREE' '$launch'"
gwt="$(wm_state crew-get --id "$id" | uv run --no-project --quiet python -c 'import sys,json;print(json.load(sys.stdin).get("worktree") or "")')"
assert_eq "global-scope record has an empty worktree" "$gwt" ""

# --- repo scope still enforces a git checkout --------------------------------
if "$SPAWN" --type software-analyst --repo "$WS" --objective nope >/dev/null 2>&1; then rc=0; else rc=$?; fi
assert_true "repo scope on a non-git path fails" "[ $rc -ne 0 ]"

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

# --- argument guards ---------------------------------------------------------
if "$SPAWN" --type software-analyst --scope bogus --objective x >/dev/null 2>&1; then rc=0; else rc=$?; fi
assert_true "invalid --scope is rejected" "[ $rc -ne 0 ]"
if "$SPAWN" --type software-analyst --scope global --repo repoA --objective x >/dev/null 2>&1; then rc=0; else rc=$?; fi
assert_true "--scope global with --repo is rejected" "[ $rc -ne 0 ]"

test_summary
