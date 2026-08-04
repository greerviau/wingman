#!/usr/bin/env bash
# E2E: issue #251 - a `died` crew member's session transcript survives on disk
# independent of its worktree (crew.json already stores session_id), but
# nothing surfaced that. Covers is_resumable's existence-only check and every
# render/notification surface it feeds: crew-list/crew-tree/board annotation,
# crew-get's JSON (consumed by bin/crew-takeover), and the needs-attention /
# group-attention notification text.
#
# No tmux needed anywhere here - these are all pure display/notification
# functions read straight from wm-state's own state home, exactly like
# tests/group-attention.test.sh. $WM_CLAUDE_PROJECTS_DIR isolates the
# transcript lookup from a developer machine's real ~/.claude/projects.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# Mirrors _claude_project_slug in bin/lib/wm-state.py: every character that
# is not alphanumeric or '-' becomes '-'.
slugify() { printf '%s' "$1" | sed -E 's/[^A-Za-z0-9-]/-/g'; }

# seed_transcript <projects-dir> <repo> <session-id>  - create an empty file
# at the exact path is_resumable() checks for, so a died member with this
# (repo, session-id) pair reads as resumable.
seed_transcript() {
  _st_dir="$1/$(slugify "$2")"
  mkdir -p "$_st_dir"
  : > "$_st_dir/$3.jsonl"
}

resumable_field() {
  wm_state crew-get --id "$1" | uv run --no-project --quiet python -c '
import sys, json
d = json.load(sys.stdin)
v = d.get("resumable")
print("" if v is None else ("true" if v else "false"))'
}

# --- a died member with an on-disk transcript reads as resumable everywhere --
test_new_home
PROJDIR="$(wm_mktemp_dir)"
export WM_CLAUDE_PROJECTS_DIR="$PROJDIR"
REPO_A="$(wm_mktemp_dir)/repo-a"
mkdir -p "$REPO_A"
wm_state crew-add --id m1 --type developer --objective x --repo "$REPO_A" --window wm-m1 --session-id sess-m1 >/dev/null
wm_state crew-set --id m1 --status died >/dev/null
seed_transcript "$PROJDIR" "$REPO_A" sess-m1

assert_eq "crew-get reports resumable=true when the transcript exists" "$(resumable_field m1)" "true"

roster_out="$(wm_state crew-list --owner "")"
assert_contains "crew-list roster text marks it died (resumable)" "$roster_out" "died (resumable)"

tree_out="$(wm_state crew-list --tree)"
assert_contains "crew-tree marks it died (resumable) too" "$tree_out" "died (resumable)"

board_out="$(wm_state render-board)"
assert_contains "the board's Closed table marks it died (resumable)" "$board_out" "died (resumable)"

na_out="$(wm_state needs-attention --owner "")"
assert_contains "needs-attention leads with recovery, not absence" "$na_out" "Session state survived and is resumable"
assert_contains "needs-attention names the exact recovery commands" "$na_out" "bin/crew-takeover m1"
assert_contains "needs-attention also names bin/crew-resume" "$na_out" "bin/crew-resume m1"

# --- a died member with NO transcript on disk reads as unresumable everywhere -
test_new_home
PROJDIR2="$(wm_mktemp_dir)"
export WM_CLAUDE_PROJECTS_DIR="$PROJDIR2"
REPO_B="$(wm_mktemp_dir)/repo-b"
mkdir -p "$REPO_B"
wm_state crew-add --id m2 --type developer --objective x --repo "$REPO_B" --window wm-m2 --session-id sess-m2 >/dev/null
wm_state crew-set --id m2 --status died >/dev/null
# deliberately never seed a transcript file

assert_eq "crew-get reports resumable=false when the transcript is absent" "$(resumable_field m2)" "false"
roster_out2="$(wm_state crew-list --owner "")"
assert_false "crew-list never claims resumable when the transcript is gone" \
  "printf '%s\n' \"$roster_out2\" | grep -q '(resumable)'"
assert_contains "the row still shows the bare died status" "$roster_out2" "died"
na_out2="$(wm_state needs-attention --owner "")"
assert_false "needs-attention never claims recovery when the transcript is gone" \
  "printf '%s\n' \"$na_out2\" | grep -q 'Session state survived'"

# --- resumable is computed only for a died member; a live member's JSON never
# carries the key at all (it is meaningless while the member is still running)
test_new_home
wm_state crew-add --id m3 --type developer --objective x --repo /tmp --window wm-m3 --session-id sess-m3 >/dev/null
assert_eq "a working member's crew-get carries no resumable key" "$(resumable_field m3)" ""

# --- a died member with a missing session_id/repo never crashes, just reads
# as not resumable (pre-#251 record shape, or a hand-edited one) --------------
test_new_home
wm_state crew-add --id m4 --type developer --objective x --repo /tmp --window wm-m4 --session-id "" >/dev/null
wm_state crew-set --id m4 --status died >/dev/null
assert_eq "an empty session_id reads as not resumable, not an error" "$(resumable_field m4)" "false"

# --- MF-3: a repo path reached through a symlink resolves via realpath, not
# abspath - the CLI's own getcwd(3) resolves symlinks, so a slug computed
# from the unresolved symlink path would never match the CLI's own transcript
# directory -------------------------------------------------------------------
test_new_home
PROJDIR4="$(wm_mktemp_dir)"
export WM_CLAUDE_PROJECTS_DIR="$PROJDIR4"
REAL_REPO="$(wm_mktemp_dir)/real-repo"
mkdir -p "$REAL_REPO"
SYMLINK_REPO="$(wm_mktemp_dir)/symlink-repo"
ln -s "$REAL_REPO" "$SYMLINK_REPO"
wm_state crew-add --id m5 --type developer --objective x --repo "$SYMLINK_REPO" --window wm-m5 --session-id sess-m5 >/dev/null
wm_state crew-set --id m5 --status died >/dev/null
# Seed the transcript under the REAL (resolved) path's slug, not the symlink's.
seed_transcript "$PROJDIR4" "$REAL_REPO" sess-m5

assert_eq "a repo reached through a symlink still resolves to its real transcript (realpath, MF-3)" \
  "$(resumable_field m5)" "true"

# --- MF-3: a session transcript under a slug the exact derivation doesn't
# predict (a naming-scheme drift, a truncated+hashed slug) is still found via
# the session-id-keyed glob fallback -------------------------------------------
test_new_home
PROJDIR5="$(wm_mktemp_dir)"
export WM_CLAUDE_PROJECTS_DIR="$PROJDIR5"
REPO_E="$(wm_mktemp_dir)/repo-e"
mkdir -p "$REPO_E"
wm_state crew-add --id m6 --type developer --objective x --repo "$REPO_E" --window wm-m6 --session-id sess-m6 >/dev/null
wm_state crew-set --id m6 --status died >/dev/null
# Seed the transcript under a completely unrelated slug directory name - the
# exact derived path is a guaranteed miss, so only the glob fallback can find it.
mkdir -p "$PROJDIR5/some-other-slug-entirely"
: > "$PROJDIR5/some-other-slug-entirely/sess-m6.jsonl"

assert_eq "a transcript under an unpredicted slug is still found via the glob fallback (MF-3)" \
  "$(resumable_field m6)" "true"

# --- CLAUDE_CONFIG_DIR is honored (MF-3) - $WM_CLAUDE_PROJECTS_DIR still wins
# outright when both are set, since it is the test-isolation escape hatch ----
test_new_home
unset WM_CLAUDE_PROJECTS_DIR
CCD="$(wm_mktemp_dir)/relocated-claude-home"
export CLAUDE_CONFIG_DIR="$CCD"
REPO_F="$(wm_mktemp_dir)/repo-f"
mkdir -p "$REPO_F"
wm_state crew-add --id m7 --type developer --objective x --repo "$REPO_F" --window wm-m7 --session-id sess-m7 >/dev/null
wm_state crew-set --id m7 --status died >/dev/null
mkdir -p "$CCD/projects/$(slugify "$REPO_F")"
: > "$CCD/projects/$(slugify "$REPO_F")/sess-m7.jsonl"

assert_eq "a transcript under a relocated \$CLAUDE_CONFIG_DIR is found (MF-3)" \
  "$(resumable_field m7)" "true"
unset CLAUDE_CONFIG_DIR

# --- the mass-death correlated batch note reports how many of the batch are
# actually resumable, not just a bare "resume" pointer -------------------------
test_new_home
PROJDIR3="$(wm_mktemp_dir)"
export WM_CLAUDE_PROJECTS_DIR="$PROJDIR3"
REPO_C="$(wm_mktemp_dir)/repo-c"
mkdir -p "$REPO_C"
wm_state crew-add --id n1 --type developer --objective a --repo "$REPO_C" --window wm-n1 --session-id sess-n1 >/dev/null
wm_state crew-add --id n2 --type developer --objective b --repo "$REPO_C" --window wm-n2 --session-id sess-n2 >/dev/null
wm_state crew-add --id n3 --type developer --objective c --repo "$REPO_C" --window wm-n3 --session-id sess-n3 >/dev/null
wm_state crew-set --id n1 --status died >/dev/null
wm_state crew-set --id n2 --status died >/dev/null
# Only n1's transcript survives; n2's does not - a mixed batch.
seed_transcript "$PROJDIR3" "$REPO_C" sess-n1
input="$(printf 'n1\tdied\tX\t\nn2\tdied\tX\t')"
out="$(printf '%s\n' "$input" | wm_state group-attention --owner "")"
assert_contains "the collapsed note says how many of the batch are actually resumable" "$out" "1/2"
assert_contains "the collapsed note frames it as not lost" "$out" "not lost work"

test_summary
