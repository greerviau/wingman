#!/usr/bin/env bash
# E2E: cmd_terminal_nudge_check / cmd_terminal_nudge_mark, the shared
# candidate selector and delivery-record writer behind the consumption
# nudge (Class A/D1: a producer parked in review whose deliverable was
# handed to another member as its --input) and the forge-terminal nudge
# (Class C: a review member with a PR-URL delivery and no live pr-watch
# beacon). State layer only - no tmux, no real forge CLI (see
# tests/terminal-nudge-watch-fleet.test.sh for the wiring).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

wm_py() { uv run --no-project --quiet python "$@"; }

status_of() {
  wm_state crew-get --id "$1" | wm_py -c 'import json,sys; print(json.load(sys.stdin)["status"])'
}
field_of() {
  wm_state crew-get --id "$1" | wm_py -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1]) or "")' "$2"
}
# tn_get <id> <top-field> <sub-key> - one value out of terminal-nudged.json's
# {"<id>": {"<top-field>": {"<sub-key>": ...}}} shape.
tn_get() {
  wm_py -c '
import json, sys, os
p = sys.argv[1]
d = json.load(open(p)) if os.path.exists(p) else {}
e = (d.get(sys.argv[2]) or {}).get(sys.argv[3]) or {}
v = e.get(sys.argv[4])
print(v if v is not None else "")
' "$WINGMAN_HOME/terminal-nudged.json" "$1" "$2" "$3"
}
row_count() { printf '%s\n' "$1" | grep -c . ; }
col() { printf '%s' "$1" | cut -f"$2"; }
# Reads field <n> of one TSV row the same way bin/watch-fleet's own nudge
# loop does (IFS=$'\t' read), which - unlike `cut -f`, used by col() above -
# genuinely collapses a run of consecutive tabs (tab is IFS *whitespace*
# under POSIX field splitting). This is the reader that has to be used to
# prove the "no column ever emitted empty" invariant actually matters.
read_col() {
  IFS=$'\t' read -r _rc1 _rc2 _rc3 _rc4 _rc5 _rc6 _rc7 _rc8 <<EOF
$1
EOF
  case "$2" in
    1) printf '%s' "$_rc1" ;; 2) printf '%s' "$_rc2" ;;
    3) printf '%s' "$_rc3" ;; 4) printf '%s' "$_rc4" ;;
    5) printf '%s' "$_rc5" ;; 6) printf '%s' "$_rc6" ;;
    7) printf '%s' "$_rc7" ;; 8) printf '%s' "$_rc8" ;;
  esac
}

board_mtime() {
  stat -c %Y "$WINGMAN_HOME/board.md" 2>/dev/null || stat -f %m "$WINGMAN_HOME/board.md"
}

# --- #1: shape - exactly one row, 8 tab-separated columns, artifact + the
# producer's own backend/window/agent land in columns 5-8 -------------------
test_new_home
wm_state crew-add --id p1 --type software-analyst --objective x --repo /tmp --window wm-p1-real --session-id s-p1 --backend tmux --agent claude >/dev/null
wm_state crew-set --id p1 --status review --artifact "docs/plans/p1.md" --summary "plan ready" >/dev/null
wm_state crew-add --id c1 --type architect --objective x --repo /tmp --window wm-c1 --session-id s-c1 --input "docs/plans/p1.md" >/dev/null
wm_state crew-set --id c1 --status working --summary "working the plan" >/dev/null

out1="$(wm_state terminal-nudge-check --owner "")"
assert_eq "case1: exactly one row" "$(row_count "$out1")" "1"
assert_eq "case1: the row has 8 tab-separated columns" "$(printf '%s' "$out1" | awk -F'\t' '{print NF}')" "8"
assert_eq "case1: column 1 is the kind" "$(col "$out1" 1)" "consumed"
assert_eq "case1: column 2 is the producer's own id" "$(col "$out1" 2)" "p1"
assert_eq "case1: column 3 is the consumer's id" "$(col "$out1" 3)" "c1"
assert_eq "case1: column 5 is the artifact path" "$(col "$out1" 5)" "docs/plans/p1.md"
assert_eq "case1: column 6 is the producer's own backend" "$(col "$out1" 6)" "tmux"
assert_eq "case1: column 7 is the producer's own window" "$(col "$out1" 7)" "wm-p1-real"
assert_eq "case1: column 8 is the producer's own agent" "$(col "$out1" 8)" "claude"

# --- #2: column defaults - backend/agent/window all absent yield tmux/claude/wm-<id> ---
test_new_home
wm_state crew-add --id p2 --type software-analyst --objective x --repo /tmp --window wm-p2-placeholder --session-id s-p2 >/dev/null
wm_state crew-set --id p2 --status review --artifact "docs/plans/p2.md" --window "" --summary x >/dev/null
wm_state crew-add --id c2 --type architect --objective x --repo /tmp --window wm-c2 --session-id s-c2 --input "docs/plans/p2.md" >/dev/null

out2="$(wm_state terminal-nudge-check --owner "")"
assert_eq "case2: an absent backend defaults to tmux" "$(col "$out2" 6)" "tmux"
assert_eq "case2: an absent window defaults to wm-<id>" "$(col "$out2" 7)" "wm-p2"
assert_eq "case2: an absent agent defaults to claude" "$(col "$out2" 8)" "claude"

# --- #3: column alignment survives an empty value (consumer type == "") -----
test_new_home
wm_state crew-add --id p3 --type software-analyst --objective x --repo /tmp --window wm-p3 --session-id s-p3 >/dev/null
wm_state crew-set --id p3 --status review --artifact "docs/plans/p3.md" --summary x >/dev/null
wm_state crew-add --id c3 --type "" --objective x --repo /tmp --window wm-c3 --session-id s-c3 --input "docs/plans/p3.md" >/dev/null

out3="$(wm_state terminal-nudge-check --owner "")"
assert_eq "case3: an empty consumer type is emitted as the '-' placeholder" "$(read_col "$out3" 4)" "-"
assert_eq "case3: column 5 still carries the artifact path, not shifted left (IFS=\$'\\t' read)" \
  "$(read_col "$out3" 5)" "docs/plans/p3.md"

# --- #4: mark delivered suppresses re-emission ------------------------------
# Deliberately no prior --outcome attempted here (that is case16, below, on
# its own fixture): an attempt record on the SAME consumer would also
# suppress the row via the retry-cap path, masking a broken `delivered`
# write behind a different, unrelated skip condition.
test_new_home
wm_state crew-add --id p4 --type software-analyst --objective x --repo /tmp --window wm-p4 --session-id s-p4 >/dev/null
wm_state crew-set --id p4 --status review --artifact "docs/plans/p4.md" --summary x >/dev/null
wm_state crew-add --id c4 --type architect --objective x --repo /tmp --window wm-c4 --session-id s-c4 --input "docs/plans/p4.md" >/dev/null

wm_state terminal-nudge-mark --id p4 --kind consumed --key c4 --outcome delivered >/dev/null
out4="$(wm_state terminal-nudge-check --owner "")"
assert_eq "case4: after marking delivered, the next check emits nothing" "$out4" ""

# --- #5: a second, different consumer of the same artifact re-emits --------
# Continues the SAME home as case4: p4 was already marked delivered for c4;
# a NEW consumer of the same artifact must still re-qualify.
wm_state crew-add --id c4b --type developer --objective x --repo /tmp --window wm-c4b --session-id s-c4b --input "docs/plans/p4.md" >/dev/null
out5="$(wm_state terminal-nudge-check --owner "")"
assert_eq "case5: a second different consumer re-emits a row" "$(row_count "$out5")" "1"
assert_eq "case5: the new row names the new consumer" "$(col "$out5" 3)" "c4b"

# --- #16: marking delivered clears a prior attempt record -------------------
test_new_home
wm_state crew-add --id p16 --type software-analyst --objective x --repo /tmp --window wm-p16 --session-id s-p16 >/dev/null
wm_state crew-set --id p16 --status review --artifact "docs/plans/p16.md" --summary x >/dev/null
wm_state crew-add --id c16 --type architect --objective x --repo /tmp --window wm-c16 --session-id s-c16 --input "docs/plans/p16.md" >/dev/null

wm_state terminal-nudge-mark --id p16 --kind consumed --key c16 --outcome attempted >/dev/null
assert_eq "case16 setup: an attempt record exists before delivery" "$(tn_get p16 consumed_attempt tries)" "1"
wm_state terminal-nudge-mark --id p16 --kind consumed --key c16 --outcome delivered >/dev/null
assert_eq "case16: marking delivered clears the prior attempt record" "$(tn_get p16 consumed_attempt tries)" ""

# --- #6: three consumers - greatest spawned_at wins, ties by ascending id ---
test_new_home
wm_state crew-add --id p6 --type software-analyst --objective x --repo /tmp --window wm-p6 --session-id s-p6 >/dev/null
wm_state crew-set --id p6 --status review --artifact "docs/plans/p6.md" --summary x >/dev/null
wm_state crew-add --id c6-b --type developer --objective x --repo /tmp --window wm-c6b --session-id s-c6b --input "docs/plans/p6.md" >/dev/null
wm_state crew-add --id c6-a --type developer --objective x --repo /tmp --window wm-c6a --session-id s-c6a --input "docs/plans/p6.md" >/dev/null

out6a="$(wm_state terminal-nudge-check --owner "")"
assert_eq "case6a: tie on spawned_at breaks by ascending id (c6-a beats c6-b)" "$(col "$out6a" 3)" "c6-a"

wm_state crew-add --id c6-latest --type developer --objective x --repo /tmp --window wm-c6l --session-id s-c6l --input "docs/plans/p6.md" >/dev/null
out6b="$(wm_state terminal-nudge-check --owner "")"
assert_eq "case6b: the most-recently-spawned consumer wins outright" "$(col "$out6b" 3)" "c6-latest"

# --- #7: a producer in 'working' (not 'review') yields no row ---------------
test_new_home
wm_state crew-add --id p7 --type software-analyst --objective x --repo /tmp --window wm-p7 --session-id s-p7 >/dev/null
wm_state crew-set --id p7 --status working --artifact "docs/plans/p7.md" --summary x >/dev/null
wm_state crew-add --id c7 --type architect --objective x --repo /tmp --window wm-c7 --session-id s-c7 --input "docs/plans/p7.md" >/dev/null

out7="$(wm_state terminal-nudge-check --owner "")"
assert_eq "case7: a producer in working yields no row" "$out7" ""

# --- #8: a producer with a non-empty delivery of ANY shape yields no CONSUMED
# row (a canonical-PR-URL shape is legitimately still a pr-probe candidate in
# its own right - reviewer.md/etc are excluded from that side by the status
# filter alone, so this asserts on the 'consumed' kind specifically, not on
# empty output) ---------------------------------------------------------------
for shape in "https://github.com/o/r/pull/9" "feat/foo" "some-arbitrary-string"; do
  test_new_home
  wm_state crew-add --id p8 --type developer --objective x --repo /tmp --window wm-p8 --session-id s-p8 >/dev/null
  wm_state crew-set --id p8 --status review --artifact "docs/plans/p8.md" --delivery "$shape" --summary x >/dev/null
  wm_state crew-add --id c8 --type developer --objective x --repo /tmp --window wm-c8 --session-id s-c8 --input "docs/plans/p8.md" >/dev/null

  out8="$(wm_state terminal-nudge-check --owner "")"
  if printf '%s\n' "$out8" | grep -q '^consumed	'; then
    fail "case8: a delivery shaped like [$shape] suppresses the consumed row"
  else
    ok "case8: a delivery shaped like [$shape] suppresses the consumed row"
  fi
done

# --- #9: a consumer under a DIFFERENT owner still produces a row -----------
test_new_home
wm_state crew-add --id p9 --type software-analyst --objective x --repo /tmp --window wm-p9 --session-id s-p9 >/dev/null
wm_state crew-set --id p9 --status review --artifact "docs/plans/p9.md" --summary x >/dev/null
wm_state crew-add --id lead9 --type lead --objective x --repo /tmp --window wm-lead9 --session-id s-lead9 >/dev/null
wm_state crew-add --id c9 --type developer --objective x --repo /tmp --window wm-c9 --session-id s-c9 --parent lead9 --input "docs/plans/p9.md" >/dev/null

out9="$(wm_state terminal-nudge-check --owner "")"
assert_eq "case9: a cross-owner consumer is still detected" "$(col "$out9" 3)" "c9"

# --- #10: a producer under a DIFFERENT owner produces no row when --owner is set ---
test_new_home
wm_state crew-add --id lead10 --type lead --objective x --repo /tmp --window wm-lead10 --session-id s-lead10 >/dev/null
wm_state crew-add --id p10 --type software-analyst --objective x --repo /tmp --window wm-p10 --session-id s-p10 --parent lead10 >/dev/null
wm_state crew-set --id p10 --status review --artifact "docs/plans/p10.md" --summary x >/dev/null
wm_state crew-add --id c10 --type developer --objective x --repo /tmp --window wm-c10 --session-id s-c10 --input "docs/plans/p10.md" >/dev/null

out10="$(wm_state terminal-nudge-check --owner "")"
assert_eq "case10: --owner \"\" excludes a producer parented under lead10" "$out10" ""

# --- #11: a consumer in 'died' status is ignored ----------------------------
test_new_home
wm_state crew-add --id p11 --type software-analyst --objective x --repo /tmp --window wm-p11 --session-id s-p11 >/dev/null
wm_state crew-set --id p11 --status review --artifact "docs/plans/p11.md" --summary x >/dev/null
wm_state crew-add --id c11 --type developer --objective x --repo /tmp --window wm-c11 --session-id s-c11 --input "docs/plans/p11.md" >/dev/null
wm_state crew-set --id c11 --status died --summary gone >/dev/null

out11="$(wm_state terminal-nudge-check --owner "")"
assert_eq "case11: a died consumer is never a valid consumer" "$out11" ""

# --- #12: a member is never its own consumer --------------------------------
test_new_home
wm_state crew-add --id p12 --type developer --objective x --repo /tmp --window wm-p12 --session-id s-p12 --input "docs/plans/p12.md" >/dev/null
wm_state crew-set --id p12 --status review --artifact "docs/plans/p12.md" --summary x >/dev/null

out12="$(wm_state terminal-nudge-check --owner "")"
assert_eq "case12: a record whose own input equals its own artifact never self-matches" "$out12" ""

# --- #13: _same_deliverable's own suffix-matching semantics -----------------
test_new_home
wm_state crew-add --id p13a --type software-analyst --objective x --repo /tmp --window wm-p13a --session-id s-p13a >/dev/null
wm_state crew-set --id p13a --status review --artifact "docs/plans/p.md" --summary x >/dev/null
wm_state crew-add --id c13a --type developer --objective x --repo /tmp --window wm-c13a --session-id s-c13a --input "/abs/path/repo/docs/plans/p.md" >/dev/null
out13a="$(wm_state terminal-nudge-check --owner "")"
assert_eq "case13a: an absolute-path suffix match is a real match" "$(row_count "$out13a")" "1"

test_new_home
wm_state crew-add --id p13b --type software-analyst --objective x --repo /tmp --window wm-p13b --session-id s-p13b >/dev/null
wm_state crew-set --id p13b --status review --artifact "docs/plans/p.md" --summary x >/dev/null
wm_state crew-add --id c13b --type developer --objective x --repo /tmp --window wm-c13b --session-id s-c13b --input "other/dir/p.md" >/dev/null
out13b="$(wm_state terminal-nudge-check --owner "")"
assert_eq "case13b: a non-suffix path with the same basename does not match" "$out13b" ""

test_new_home
wm_state crew-add --id p13c --type software-analyst --objective x --repo /tmp --window wm-p13c --session-id s-p13c >/dev/null
wm_state crew-set --id p13c --status review --artifact "p.md" --summary x >/dev/null
wm_state crew-add --id c13c --type developer --objective x --repo /tmp --window wm-c13c --session-id s-c13c --input "/a/b/p.md" >/dev/null
out13c="$(wm_state terminal-nudge-check --owner "")"
assert_eq "case13c: a bare basename artifact does not suffix-match a longer path" "$out13c" ""

# --- #14: an absent artifact, or an absent input, yields no row ------------
test_new_home
wm_state crew-add --id p14a --type software-analyst --objective x --repo /tmp --window wm-p14a --session-id s-p14a >/dev/null
wm_state crew-set --id p14a --status review --summary x >/dev/null    # no --artifact
wm_state crew-add --id c14a --type developer --objective x --repo /tmp --window wm-c14a --session-id s-c14a --input "docs/plans/p14a.md" >/dev/null
out14a="$(wm_state terminal-nudge-check --owner "")"
assert_eq "case14a: a producer with no artifact yields no row" "$out14a" ""

wm_state crew-add --id p14b --type software-analyst --objective x --repo /tmp --window wm-p14b --session-id s-p14b >/dev/null
wm_state crew-set --id p14b --status review --artifact "docs/plans/p14b.md" --summary x >/dev/null
wm_state crew-add --id c14b --type developer --objective x --repo /tmp --window wm-c14b --session-id s-c14b >/dev/null    # no --input
out14b="$(wm_state terminal-nudge-check --owner "")"
assert_eq "case14b: a consumer with no input never matches anything" "$out14b" ""

# case14c: _same_deliverable("", "") itself, called directly - not reachable
# through cmd_terminal_nudge_check's own CLI, since that command already
# skips a producer with no artifact before _same_deliverable is ever called
# (case14a above), and os.path.normpath("") == "." fails 13c's own
# separator check regardless of the empty guard (case14b above) - so
# neither case14a nor case14b can actually discriminate _same_deliverable's
# OWN internal empty-string guard on its own. This is the one fixture where
# BOTH sides collapse to "." after normalization, which the internal guard
# - and only the internal guard - must catch to keep "an absent artifact
# must never match an absent input" (its own documented contract) true.
same_deliverable_direct="$(uv run --no-project --quiet python - "$TEST_REPO/bin/lib/wm-state.py" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("wm_state_mod", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(mod._same_deliverable("", ""))
PYEOF
)"
assert_eq "case14c: _same_deliverable(\"\", \"\") is False, not a '.'==''.' collision" \
  "$same_deliverable_direct" "False"

# --- #15: the retry cap - suppressed under retry-secs, re-emits once it has
# elapsed, permanently suppressed once tries reaches max-tries ---------------
test_new_home
wm_state crew-add --id p15 --type software-analyst --objective x --repo /tmp --window wm-p15 --session-id s-p15 >/dev/null
wm_state crew-set --id p15 --status review --artifact "docs/plans/p15.md" --summary x >/dev/null
wm_state crew-add --id c15 --type developer --objective x --repo /tmp --window wm-c15 --session-id s-c15 --input "docs/plans/p15.md" >/dev/null

wm_state terminal-nudge-mark --id p15 --kind consumed --key c15 --outcome attempted >/dev/null
out15a="$(wm_state terminal-nudge-check --owner "" --retry-secs 2 --max-tries 2)"
assert_eq "case15a: suppressed immediately after one attempt, within retry-secs" "$out15a" ""

sleep 2.2
out15b="$(wm_state terminal-nudge-check --owner "" --retry-secs 2 --max-tries 2)"
assert_eq "case15b: re-emits once retry-secs has elapsed" "$(row_count "$out15b")" "1"

wm_state terminal-nudge-mark --id p15 --kind consumed --key c15 --outcome attempted >/dev/null
assert_eq "case15: tries is now 2 (max-tries)" "$(tn_get p15 consumed_attempt tries)" "2"
sleep 2.2
out15c="$(wm_state terminal-nudge-check --owner "" --retry-secs 2 --max-tries 2)"
assert_eq "case15c: permanently suppressed once tries reaches max-tries" "$out15c" ""

# --- #17: a live pr-watch beacon suppresses the pr-probe row ---------------
test_new_home
wm_state crew-add --id p17 --type developer --objective x --repo /tmp --window wm-p17 --session-id s-p17 >/dev/null
wm_state crew-set --id p17 --status review --delivery "https://github.com/o/r/pull/17" --summary x >/dev/null

out17a="$(wm_state terminal-nudge-check --owner "")"
assert_eq "case17a: no beacon -> one pr-probe row" "$(row_count "$out17a")" "1"
assert_eq "case17a: the row's kind is pr-probe" "$(col "$out17a" 1)" "pr-probe"
assert_eq "case17a: the row's key is the PR URL" "$(col "$out17a" 3)" "https://github.com/o/r/pull/17"

# A SEPARATE producer, not the one already probed above: reusing p17 here
# would also be suppressed by the pr-poll-secs throttle (out17a already
# stamped its pr_probe), masking a removed beacon gate behind an unrelated
# throttle. --pr-poll-secs 0 removes that throttle from the equation
# entirely, so only the beacon gate is under test.
wm_state crew-add --id p17b --type developer --objective x --repo /tmp --window wm-p17b --session-id s-p17b >/dev/null
wm_state crew-set --id p17b --status review --delivery "https://github.com/o/r/pull/17" --summary x >/dev/null
touch "$WINGMAN_HOME/pr-watch-p17b.beat"
out17b="$(wm_state terminal-nudge-check --owner "" --pr-poll-secs 0)"
if printf '%s\n' "$out17b" | grep -q '	p17b	'; then
  fail "case17b: a fresh beacon suppresses the pr-probe row"
else
  ok "case17b: a fresh beacon suppresses the pr-probe row"
fi

# --- #18: the forge-query throttle - no immediate re-probe; re-probes after
# pr-poll-secs -----------------------------------------------------------
test_new_home
wm_state crew-add --id p18 --type developer --objective x --repo /tmp --window wm-p18 --session-id s-p18 >/dev/null
wm_state crew-set --id p18 --status review --delivery "https://github.com/o/r/pull/18" --summary x >/dev/null

out18a="$(wm_state terminal-nudge-check --owner "" --pr-poll-secs 2)"
assert_eq "case18a: the first check emits the row and stamps pr_probe" "$(row_count "$out18a")" "1"
out18b="$(wm_state terminal-nudge-check --owner "" --pr-poll-secs 2)"
assert_eq "case18b: an immediate re-check emits nothing (throttled)" "$out18b" ""
sleep 2.2
out18c="$(wm_state terminal-nudge-check --owner "" --pr-poll-secs 2)"
assert_eq "case18c: after pr-poll-secs elapses, it probes again" "$(row_count "$out18c")" "1"

# --- #19: non-canonical delivery shapes never yield a pr-probe row ---------
for shape in "feat/foo" "#12" "https://gitlab.com/o/r/pull/3"; do
  test_new_home
  wm_state crew-add --id p19 --type developer --objective x --repo /tmp --window wm-p19 --session-id s-p19 >/dev/null
  wm_state crew-set --id p19 --status review --delivery "$shape" --summary x >/dev/null
  out19="$(wm_state terminal-nudge-check --owner "")"
  assert_eq "case19: delivery [$shape] is never a pr-probe candidate" "$out19" ""
done

# --- #20: marking a pr delivered suppresses even past the poll window;
# a DIFFERENT pr url re-enables probing ------------------------------------
test_new_home
wm_state crew-add --id p20 --type developer --objective x --repo /tmp --window wm-p20 --session-id s-p20 >/dev/null
wm_state crew-set --id p20 --status review --delivery "https://github.com/o/r/pull/20" --summary x >/dev/null

wm_state terminal-nudge-check --owner "" --pr-poll-secs 1 >/dev/null
wm_state terminal-nudge-mark --id p20 --kind pr --key "https://github.com/o/r/pull/20" --state MERGED --outcome delivered >/dev/null
sleep 1.2
out20a="$(wm_state terminal-nudge-check --owner "" --pr-poll-secs 1)"
assert_eq "case20a: a delivered pr_nudge suppresses probing even past the poll window" "$out20a" ""

wm_state crew-set --id p20 --delivery "https://github.com/o/r/pull/21" >/dev/null
out20b="$(wm_state terminal-nudge-check --owner "" --pr-poll-secs 1)"
assert_eq "case20b: a different PR URL re-enables probing" "$(row_count "$out20b")" "1"

# --- #21: no side effects anywhere on the roster/board ----------------------
test_new_home
wm_state crew-add --id p21 --type software-analyst --objective x --repo /tmp --window wm-p21 --session-id s-p21 >/dev/null
wm_state crew-set --id p21 --status review --artifact "docs/plans/p21.md" --summary "plan ready" >/dev/null
wm_state crew-add --id c21 --type architect --objective x --repo /tmp --window wm-c21 --session-id s-c21 --input "docs/plans/p21.md" >/dev/null
wm_state crew-add --id p21b --type developer --objective x --repo /tmp --window wm-p21b --session-id s-p21b >/dev/null
wm_state crew-set --id p21b --status review --delivery "https://github.com/o/r/pull/21" --summary x >/dev/null

status_before="$(status_of p21)"
updated_before="$(field_of p21 updated)"
announced_before="$(field_of p21 announced)"
acked_before="$(cat "$WINGMAN_HOME/acked.json" 2>/dev/null || echo '{}')"
sleep 1.1
board_before="$(board_mtime)"
sleep 1.1
wm_state terminal-nudge-check --owner "" >/dev/null
wm_state terminal-nudge-mark --id p21 --kind consumed --key c21 --outcome attempted >/dev/null
wm_state terminal-nudge-mark --id p21b --kind pr --key "https://github.com/o/r/pull/21" --state OPEN --outcome attempted >/dev/null

assert_eq "case21: producer status unchanged across check + mark calls" "$(status_of p21)" "$status_before"
assert_eq "case21: producer updated stamp unchanged" "$(field_of p21 updated)" "$updated_before"
assert_eq "case21: producer announced stamp unchanged" "$(field_of p21 announced)" "$announced_before"
assert_eq "case21: acked.json is byte-identical" "$(cat "$WINGMAN_HOME/acked.json" 2>/dev/null || echo '{}')" "$acked_before"
assert_eq "case21: board.md's mtime is unchanged" "$(board_mtime)" "$board_before"

test_summary
