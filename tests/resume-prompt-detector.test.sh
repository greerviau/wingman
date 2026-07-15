#!/usr/bin/env bash
# E2E + unit: the resume-from-summary dialog auto-dismiss fallback (issue #30).
# `claude --resume` can show an interactive "resume from summary?" menu on a
# large/old transcript that nothing answers in an unattended relaunch. Unlike
# a permission/trust freeze (bin/watch-fleet's existing prompt_freeze_check,
# which escalates to `blocked`), this has a safe default answer, so the
# watcher auto-dismisses it instead.
#
# Round 2 (PR #106 review): an earlier version of resume_prompt_shape_in
# required only that both option-row strings appear anywhere within the pane
# tail, with no shape/adjacency requirement - the reviewer demonstrated this
# is trivially false-positived by a pane merely displaying (e.g. `cat`-ing)
# static text that happens to reproduce the pair, including this very test
# file's own first-draft fixture. The detector now shares prompt_shape_in's
# UI-shape/adjacency walk (own-line phrase anchoring a contiguous option
# block) plus an additional content-specificity check. Every fixture below
# that represents multi-line pane content is built via `printf` with escaped
# `\n` sequences (matching the existing suite's own convention, e.g.
# watch-fleet.test.sh's z4/z10 fixtures) rather than a literal multi-line
# bash string constant - a literal multi-line constant would itself
# reproduce the real dialog's shape as adjacent lines in this file's own
# checked-in source, recreating the exact trap this round closes.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WF="$TEST_REPO/bin/watch-fleet"
COMMON="$TEST_REPO/bin/lib/common.sh"

field_of() { wm_state crew-get --id "$1" | uv run --no-project --quiet python -c 'import sys,json
print(json.load(sys.stdin).get(sys.argv[1]) or "")' "$2"; }

# Runs resume_prompt_shape_in against $1 in an isolated subshell (sourcing
# common.sh there, never in this file's own shell, so its env/function
# definitions never leak into the rest of the suite). Exit status mirrors the
# function's own, so this composes directly with assert_true/assert_false.
resume_matches() { ( . "$COMMON" >/dev/null 2>&1; resume_prompt_shape_in "$1" ); }
perm_matches()   { ( . "$COMMON" >/dev/null 2>&1; prompt_shape_in "$1" ); }

# The real dialog's rendered text, generated via printf (single line in this
# file's own source - see the header comment above).
REAL_DIALOG="$(printf "You've reached usage limits. We recommend resuming from a summary.\n\n> 1. Resume from summary (recommended)\n  2. Resume full session as-is\n  3. Don't ask me again\n")"

# --- unit: the real dialog shape matches ---------------------------------------
assert_true "the real dialog shape matches resume_prompt_shape_in" \
  "resume_matches \"\$REAL_DIALOG\""
assert_false "the real dialog shape never matches the permission-dialog detector" \
  "perm_matches \"\$REAL_DIALOG\""

# --- unit: a permission dialog never matches the resume detector ---------------
PERM_DIALOG="$(printf 'Do you want to proceed?\n\xe2\x9d\xaf 1. Yes\n  2. No, and tell it what to do differently\n')"
assert_false "a permission dialog never matches the resume-summary detector" \
  "resume_matches \"\$PERM_DIALOG\""

# --- unit: the phrase embedded mid-sentence (not its own line) does not anchor -
# The exact discipline this repo's existing z5/z7 fixtures already use for the
# permission detector (a quoting sentence defeats the own-line anchor).
MIDSENTENCE="$(printf 'the test fixture echoes: Resume from summary (recommended) is one option\n  2. Resume full session as-is\n')"
assert_false "a phrase quoted mid-sentence does not anchor a block" \
  "resume_matches \"\$MIDSENTENCE\""

# --- unit: an unrelated numbered list near the phrase does not match -----------
# Shape (phrase + adjacent 2-row option block) is present, but neither row
# carries this dialog's specific option-2 text - the content-specificity
# check must still reject it.
UNRELATED_LIST="$(printf '1. Resume from summary (recommended)\n  2. Do something else entirely\n')"
assert_false "an unrelated numbered list does not match despite matching shape" \
  "resume_matches \"\$UNRELATED_LIST\""

# --- unit: the two required strings present but not adjacent (no option block) -
NOT_ADJACENT="$(printf 'Resume from summary (recommended) was mentioned in passing.\nSeveral paragraphs later, someone typed: Resume full session as-is, unrelated to any menu.\n')"
assert_false "non-adjacent mentions of both strings do not match" \
  "resume_matches \"\$NOT_ADJACENT\""

# --- unit: a real dialog capture pasted inline in prose (no adjacency-breaking
#     prefix) is the accepted residual - documented, not asserted against here.
#     See the WM_RESUME_PROMPT_RE comment in bin/lib/common.sh.

# --- E2E: a member frozen on the resume dialog is auto-dismissed, not blocked -
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id rp1 --type developer --objective x --repo /tmp --window wm-rp1 --session-id s1 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-rp1 'printf "You'"'"'ve reached usage limits. We recommend resuming from a summary.\n\n> 1. Resume from summary (recommended)\n  2. Resume full session as-is\n  3. Don'"'"'t ask me again\n"; sleep 600'
WM_WATCH_INTERVAL=1 "$WF" >"$WINGMAN_HOME/out.log" 2>&1 &
rppid=$!
wm_track "$rppid"
sleep 6
assert_true "watcher keeps blocking (auto-dismiss is not a fire event)" "kill -0 $rppid"
assert_eq "the member is never flipped to blocked" "$(field_of rp1 status)" "working"
assert_contains "the summary records the auto-dismissal" \
  "$(field_of rp1 summary)" "auto-dismissed the resume-from-summary dialog"
assert_not_contains "the watcher never printed a blocked fire for it" "$(cat "$WINGMAN_HOME/out.log")" "blocked: rp1"
kill "$rppid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- E2E: cat-ing this very PR's own test source (the reviewer's exact repro) -
# Reproduces the reviewer's finding directly against the fixed detector: a
# working member's pane displays (via `cat`) this test file itself - which,
# post-fix, no longer contains the dialog's three lines as literal adjacent
# text - and must never be auto-dismissed.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id rp3 --type developer --objective z --repo /tmp --window wm-rp3 --session-id s3 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-rp3 "cat '$0'; sleep 600"
WM_WATCH_INTERVAL=1 "$WF" >/dev/null 2>&1 &
rp3pid=$!
wm_track "$rp3pid"
sleep 6
assert_true "watcher keeps blocking while its own source is cat'd" "kill -0 $rp3pid"
assert_eq "the member's status is untouched by cat-ing this test file" "$(field_of rp3 status)" "working"
assert_not_contains "no auto-dismiss summary was written from cat-ing this file" "$(field_of rp3 summary)" "auto-dismissed"
kill "$rp3pid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- E2E: a pane quoting only one of the two strings is left alone -----------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id rp2 --type developer --objective y --repo /tmp --window wm-rp2 --session-id s2 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-rp2 'echo "docs mention: Resume from summary (recommended) is one option"; sleep 600'
WM_WATCH_INTERVAL=1 "$WF" >/dev/null 2>&1 &
rp2pid=$!
wm_track "$rp2pid"
sleep 6
assert_true "watcher keeps blocking on a one-string mention" "kill -0 $rp2pid"
assert_eq "the member's status is untouched" "$(field_of rp2 status)" "working"
assert_not_contains "no auto-dismiss summary was written" "$(field_of rp2 summary)" "auto-dismissed"
kill "$rp2pid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

test_summary
