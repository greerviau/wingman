#!/usr/bin/env bash
# E2E + unit: the resume-from-summary dialog auto-dismiss fallback (issue #30).
# `claude --resume` can show an interactive "resume from summary?" menu on a
# large/old transcript that nothing answers in an unattended relaunch. Unlike
# a permission/trust freeze (bin/watch-fleet's existing prompt_freeze_check,
# which escalates to `blocked`), this has a safe default answer, so the
# watcher auto-dismisses it instead. Proves: the detector matches the real
# dialog shape, never cross-fires with (or is cross-fired by) the permission
# detector, ignores either signature string alone, and a member frozen on it
# is auto-dismissed rather than ever flipped to blocked.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WF="$TEST_REPO/bin/watch-fleet"
COMMON="$TEST_REPO/bin/lib/common.sh"

field_of() { wm_state crew-get --id "$1" | uv run --no-project --quiet python -c 'import sys,json
print(json.load(sys.stdin).get(sys.argv[1]) or "")' "$2"; }

# Pull a variable's shell-default value out of the script itself (same
# extract-then-drive-with-real-grep pattern as detector-regex-portability.test.sh),
# so this exercises the regex actually shipped in bin/lib/common.sh, never a
# stale copy that could drift from it.
extract_default() {
  _ed_var="$1" _ed_file="$2"
  _ed_line="$(grep -m1 "^${_ed_var}=\"\\\${${_ed_var}:-" "$_ed_file")"
  [ -n "$_ed_line" ] || return 1
  ( unset "$_ed_var"; eval "$_ed_line"; eval "printf '%s' \"\$$_ed_var\"" )
}

RESUME_RE="$(extract_default WM_RESUME_PROMPT_RE "$COMMON")"
OPTION_RE="$(extract_default WM_RESUME_OPTION_RE "$COMMON")"
PERM_RE="$(extract_default WM_PERM_PROMPT_RE "$COMMON")"

assert_true "WM_RESUME_PROMPT_RE extracted a non-empty default" "[ -n '$RESUME_RE' ]"
assert_true "WM_RESUME_OPTION_RE extracted a non-empty default" "[ -n '$OPTION_RE' ]"

# --- unit: both signature strings together match, either alone does not -----
DIALOG="You've reached usage limits. We recommend resuming from a summary.

> 1. Resume from summary (recommended)
  2. Resume full session as-is
  3. Don't ask me again"

assert_true "the real dialog matches the summary-option regex" \
  "printf '%s\n' \"\$DIALOG\" | grep -qE '$RESUME_RE'"
assert_true "the real dialog matches the full-session-option regex" \
  "printf '%s\n' \"\$DIALOG\" | grep -qE '$OPTION_RE'"

ONLY_SUMMARY="1. Resume from summary (recommended)
  2. Do something else entirely"
assert_true "the recommended-summary string alone matches its own regex" \
  "printf '%s\n' \"\$ONLY_SUMMARY\" | grep -qE '$RESUME_RE'"
assert_false "the recommended-summary string alone does not match the full-session regex" \
  "printf '%s\n' \"\$ONLY_SUMMARY\" | grep -qE '$OPTION_RE'"

ONLY_FULL="1. Something else
  2. Resume full session as-is"
assert_false "the full-session string alone does not match the summary-option regex" \
  "printf '%s\n' \"\$ONLY_FULL\" | grep -qE '$RESUME_RE'"
assert_true "the full-session string alone matches its own regex" \
  "printf '%s\n' \"\$ONLY_FULL\" | grep -qE '$OPTION_RE'"

# --- unit: distinctness from the permission-dialog detector ------------------
assert_false "the resume dialog never matches the permission-dialog phrase regex" \
  "printf '%s\n' \"\$DIALOG\" | grep -qE '$PERM_RE'"

PERM_DIALOG="Do you want to proceed?
❯ 1. Yes
  2. No, and tell it what to do differently"
assert_false "a permission dialog never matches the resume-summary regex" \
  "printf '%s\n' \"\$PERM_DIALOG\" | grep -qE '$RESUME_RE'"
assert_false "a permission dialog never matches the full-session regex" \
  "printf '%s\n' \"\$PERM_DIALOG\" | grep -qE '$OPTION_RE'"

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
