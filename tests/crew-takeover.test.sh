#!/usr/bin/env bash
# E2E: bin/crew-takeover (issue #251). Covers the reworded dead-member
# messaging: a died member with an intact transcript leads with recovery
# rather than reading as a dead end, a died member with no transcript is told
# plainly that the conversation itself is gone, a non-died non-live member
# (done/stood-down) keeps the pre-#251 generic messaging, and any member with
# an auto-anchored refs/wip/<id> ref (see reconcile-wip-anchor.test.sh) has it
# surfaced regardless of transcript state. No tmux session is ever created in
# these cases, so bin/crew-takeover's own has-session check naturally reads
# "not live" - exactly the branch under test.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

CT="$TEST_REPO/bin/crew-takeover"
slugify() { printf '%s' "$1" | sed -E 's/[^A-Za-z0-9-]/-/g'; }
seed_transcript() {
  _st_dir="$1/$(slugify "$2")"
  mkdir -p "$_st_dir"
  : > "$_st_dir/$3.jsonl"
}

# --- died + transcript intact: leads with recovery --------------------------
test_new_home
PROJDIR="$(wm_mktemp_dir)"
export WM_CLAUDE_PROJECTS_DIR="$PROJDIR"
REPO_A="$(wm_mktemp_dir)/repo-a"
mkdir -p "$REPO_A"
wm_state crew-add --id t1 --type developer --objective x --repo "$REPO_A" --window wm-t1 --session-id sess-t1 >/dev/null
wm_state crew-set --id t1 --status died >/dev/null
seed_transcript "$PROJDIR" "$REPO_A" sess-t1

out1="$("$CT" t1 2>&1)"
assert_contains "leads with recovery, not absence" "$out1" "session state survived"
assert_contains "states this command recovers it" "$out1" "This command recovers it"
assert_contains "prints the exact resume command with the right repo" "$out1" "cd '$REPO_A'"
assert_contains "prints the exact resume command with the right session id" "$out1" "--resume sess-t1"
assert_contains "also offers bin/crew-resume as the automated path" "$out1" "bin/crew-resume t1"

# --- died + transcript gone: honest, no false recovery promise --------------
test_new_home
PROJDIR2="$(wm_mktemp_dir)"
export WM_CLAUDE_PROJECTS_DIR="$PROJDIR2"
REPO_B="$(wm_mktemp_dir)/repo-b"
mkdir -p "$REPO_B"
wm_state crew-add --id t2 --type developer --objective x --repo "$REPO_B" --window wm-t2 --session-id sess-t2 >/dev/null
wm_state crew-set --id t2 --status died >/dev/null
# deliberately no transcript seeded

out2="$("$CT" t2 2>&1)"
assert_contains "says the transcript is gone" "$out2" "transcript is gone"
assert_contains "says the conversation is not recoverable" "$out2" "not recoverable"
assert_false "never claims session state survived when it did not" \
  "printf '%s\n' \"$out2\" | grep -q 'session state survived'"

# --- non-died, non-live (finished normally): unchanged generic messaging ----
test_new_home
PROJDIR3="$(wm_mktemp_dir)"
export WM_CLAUDE_PROJECTS_DIR="$PROJDIR3"
REPO_C="$(wm_mktemp_dir)/repo-c"
mkdir -p "$REPO_C"
wm_state crew-add --id t3 --type developer --objective x --repo "$REPO_C" --window wm-t3 --session-id sess-t3 >/dev/null
wm_state crew-set --id t3 --status done --summary "shipped" >/dev/null

out3="$("$CT" t3 2>&1)"
assert_contains "names the actual status rather than guessing died" "$out3" "status=done"
assert_contains "still offers the manual resume command" "$out3" "--resume sess-t3"
assert_false "never claims died-specific recovery framing for a normal finish" \
  "printf '%s\n' \"$out3\" | grep -q 'session state survived'"

# --- a refs/wip/<id> ref (auto-anchored at death, issue #251) is surfaced,
# even for a died member whose transcript is ALSO gone - it may be the only
# recoverable trace left ------------------------------------------------------
test_new_home
PROJDIR4="$(wm_mktemp_dir)"
export WM_CLAUDE_PROJECTS_DIR="$PROJDIR4"
REPO_D="$(wm_mktemp_dir)/repo-d"
mkdir -p "$REPO_D"
git -C "$REPO_D" init -q
git -C "$REPO_D" config user.email t@t.com
git -C "$REPO_D" config user.name t
git -C "$REPO_D" commit -q --allow-empty -m init
WIP_SHA="$(git -C "$REPO_D" commit-tree -m wip "$(git -C "$REPO_D" write-tree)" -p HEAD)"
git -C "$REPO_D" update-ref "refs/wip/t4" "$WIP_SHA"
wm_state crew-add --id t4 --type developer --objective x --repo "$REPO_D" --window wm-t4 --session-id sess-t4 >/dev/null
wm_state crew-set --id t4 --status died >/dev/null
# deliberately no transcript seeded - the WIP ref should still surface

out4="$("$CT" t4 2>&1)"
assert_contains "surfaces the auto-anchored wip ref even with no transcript" "$out4" "auto-anchored"
assert_contains "prints the exact recovery command" "$out4" "git -C '$REPO_D' stash apply $WIP_SHA"
assert_contains "notes the ref is safe to retry" "$out4" "safe to retry"

# --- a live member is unaffected (pre-existing behavior, still parses the
# widened field list correctly) ------------------------------------------------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION:" -n wm-t5 'sleep 600'
wm_state crew-add --id t5 --type developer --objective x --repo /tmp --window wm-t5 --session-id sess-t5 >/dev/null
out5="$("$CT" t5 2>&1)"
assert_contains "a live member still gets the tmux attach command" "$out5" "tmux attach"
assert_false "a live member never shows the died/resume framing" \
  "printf '%s\n' \"$out5\" | grep -q 'session state survived'"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

test_summary
