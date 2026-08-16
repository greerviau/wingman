#!/usr/bin/env bash
# E2E: the terminal-nudge wiring inside bin/watch-fleet's own poll loop - the
# throttle decision, the consumed-row send path (a real tmux pane, a real
# confirmed submission via the composer stub), and the pr-probe send path (a
# fake forge CLI via WM_GH). State-layer behavior (candidate selection,
# store shape) is already covered by tests/terminal-nudge.test.sh; this file
# proves the SHELL wiring around it: that a row actually lands a message in
# the right pane, that a confirmed send is what's required to mark
# 'delivered', that nothing enters the outbox, and that the once-per-window
# throttle genuinely gates the check rather than running on every poll.
#
# Fixture-versus-fire interaction, which applies to every case here: needs-
# attention's ATTENTION_STATES is ("blocked", "review", "done", "died",
# "stalled"), and on a fresh test home nothing is acked, so any fixture
# holding a member in one of those statuses makes fire() exit the watcher on
# the FIRST poll. The nudge block runs BEFORE the fire call in the same poll
# iteration, so the message and the store write both land on the arm that
# then exits - every case here below should treat "the watcher exits on this
# arm" as normal and assert on the pane/store, not on the watcher still
# running, EXCEPT case 8, whose fixture is chosen to produce no attention
# event at all.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$TEST_REPO/bin/lib/common.sh"

WF="$TEST_REPO/bin/watch-fleet"
COMPOSER_STUB="$TEST_REPO/tests/fixtures/composer-stub.sh"
export WM_WATCH_INTERVAL=1
export WM_TERMINAL_CHECK_EVERY=1

wm_py() { uv run --no-project --quiet python "$@"; }
field_of() {
  wm_state crew-get --id "$1" | wm_py -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1]) or "")' "$2"
}
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

# A fake `gh`, matching tests/pr-watch.test.sh's own make_fake_gh pattern:
# `pr view` serves $FAKE_PR.
make_fake_gh() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") cat "${FAKE_PR:-/dev/null}" ;;
  *)         echo "" ;;
esac
SH
  chmod +x "$1"
}

# --- #1/#2/#3: a consumed nudge lands a real, confirmed submission in the
# producer's pane, names the artifact, records a delivered consumed_nudge,
# leaves the producer's own status/updated untouched, and never enters the
# outbox --------------------------------------------------------------------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
P1_MARKER="$(wm_mktemp_file)"
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-p1 \
  "WM_TEST_BUSY=0 WM_TEST_SWALLOW=0 WM_TEST_MARKER='$P1_MARKER' bash '$COMPOSER_STUB'"
sleep 1
wm_state crew-add --id p1 --type software-analyst --objective x --repo /tmp --window wm-p1 --session-id s-p1 >/dev/null
wm_state crew-set --id p1 --status review --artifact "docs/plans/p1.md" --summary "plan ready" >/dev/null
wm_state crew-add --id c1 --type architect --objective x --repo /tmp --window wm-c1 --session-id s-c1 --input "docs/plans/p1.md" >/dev/null
wm_state crew-set --id c1 --status stood-down --summary closed >/dev/null

p1_updated_before="$(field_of p1 updated)"

wm_timeout 45 "$WF" >"$WINGMAN_HOME/wf1.log" 2>&1

assert_eq "case1: exactly one SUBMITTED line in the producer's pane" "$(grep -c SUBMITTED "$P1_MARKER")" "1"
assert_contains "case1: the submitted text names the artifact path" "$(cat "$P1_MARKER")" "docs/plans/p1.md"
assert_eq "case1: terminal-nudged.json records a delivered consumed_nudge for c1" "$(tn_get p1 consumed_nudge consumer)" "c1"

assert_eq "case2: the producer's status is still review" "$(field_of p1 status)" "review"
assert_eq "case2: the producer's updated stamp is unchanged" "$(field_of p1 updated)" "$p1_updated_before"

assert_true "case3: the producer's outbox directory is absent or empty" \
  '[ ! -d "$WINGMAN_HOME/outbox/p1" ] || [ -z "$(ls -A "$WINGMAN_HOME/outbox/p1" 2>/dev/null)" ]'

# --- #7: terminal-nudge.log gains one line per attempt, naming id/kind/key/rc
# (checked here, in the SAME home as case1's own delivery above - a later
# test_new_home would replace $WINGMAN_HOME and lose this entry) -----------
assert_true "case7: terminal-nudge.log exists" "[ -f '$WINGMAN_HOME/terminal-nudge.log' ]"
_log7="$(cat "$WINGMAN_HOME/terminal-nudge.log" 2>/dev/null)"
assert_contains "case7: the log names the member id" "$_log7" " p1 "
assert_contains "case7: the log names the kind" "$_log7" "consumed"
assert_contains "case7: the log names the key (consumer id)" "$_log7" "c1"
assert_contains "case7: the log records an rc=" "$_log7" "rc=0"

# --- #3 (the discriminating half): the outbox stays empty even when the send
# ITSELF fails to confirm - a clean, always-accepted composer (case1's own
# fixture) never exercises the §4.2 guarantee this case is actually about;
# only a genuinely unconfirmed submit (WM_TEST_SWALLOW=1: Enter is dropped,
# nothing registers) does. This is the fixture that discriminates
# terminal_nudge_send (which returns non-zero and never touches the outbox)
# from a bin/crew-say-based send (which queues into the outbox on exactly
# this failure shape). ------------------------------------------------------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
P3_MARKER="$(wm_mktemp_file)"
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-p3 \
  "WM_TEST_BUSY=0 WM_TEST_SWALLOW=1 WM_TEST_MARKER='$P3_MARKER' bash '$COMPOSER_STUB'"
sleep 1
wm_state crew-add --id p3 --type software-analyst --objective x --repo /tmp --window wm-p3 --session-id s-p3 >/dev/null
wm_state crew-set --id p3 --status review --artifact "docs/plans/p3.md" --summary "plan ready" >/dev/null
wm_state crew-add --id c3 --type architect --objective x --repo /tmp --window wm-c3 --session-id s-c3 --input "docs/plans/p3.md" >/dev/null
wm_state crew-set --id c3 --status stood-down --summary closed >/dev/null

wm_timeout 45 "$WF" >"$WINGMAN_HOME/wf3.log" 2>&1

assert_eq "case3 setup: the swallowed send left an attempt record, not a delivery" "$(tn_get p3 consumed_nudge consumer)" ""
assert_true "case3: an unconfirmed send never enters the outbox either" \
  '[ ! -d "$WINGMAN_HOME/outbox/p3" ] || [ -z "$(ls -A "$WINGMAN_HOME/outbox/p3" 2>/dev/null)" ]'

# --- #4: a member whose tmux window does not exist is never marked delivered.
# terminal_nudge_send is extracted directly from the REAL bin/watch-fleet
# (never hand-duplicated, so this always tests the current implementation)
# and called against a target that genuinely does not exist. A full-poll
# construction cannot discriminate this specific guard: reconcile and this
# function's own endpoint-alive check both key off the SAME roster `window`
# field, and reconcile always runs earlier in the same poll - so a producer
# whose window is truly gone is already flipped to 'died' (and excluded from
# candidacy entirely) before terminal_nudge_send would ever be reached,
# which would mask the mutation rather than catch it. ------------------------
_tn_send_src="$(sed -n '/^terminal_nudge_send() {/,/^}/p' "$TEST_REPO/bin/watch-fleet")"
[ -n "$_tn_send_src" ] || fail "case4 setup: terminal_nudge_send extracted cleanly from bin/watch-fleet"
_tn_send_rc="$(
  eval "$_tn_send_src"
  terminal_nudge_send tmux nosuchmember wm-does-not-exist-anywhere claude "hi" >/dev/null 2>&1
  echo $?
)"
assert_eq "case4: terminal_nudge_send returns non-zero against a nonexistent window" "$_tn_send_rc" "1"

# --- #5: with WM_GH stubbed to MERGED, a review member with a PR-URL delivery
# receives the forge-terminal message and is marked -------------------------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
P5_MARKER="$(wm_mktemp_file)"
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-p5 \
  "WM_TEST_BUSY=0 WM_TEST_SWALLOW=0 WM_TEST_MARKER='$P5_MARKER' bash '$COMPOSER_STUB'"
sleep 1
GH5="$(wm_mktemp_file)"; make_fake_gh "$GH5"
FAKE_PR5="$(wm_mktemp_file)"
printf '{"state":"MERGED"}' > "$FAKE_PR5"
wm_state crew-add --id p5 --type developer --objective x --repo /tmp --window wm-p5 --session-id s-p5 >/dev/null
wm_state crew-set --id p5 --status review --delivery "https://github.com/o/r/pull/5" --summary x >/dev/null

WM_GH="$GH5" FAKE_PR="$FAKE_PR5" wm_timeout 45 "$WF" >"$WINGMAN_HOME/wf5.log" 2>&1

assert_eq "case5: exactly one SUBMITTED line in the member's pane" "$(grep -c SUBMITTED "$P5_MARKER")" "1"
assert_contains "case5: the submitted text names the PR URL" "$(cat "$P5_MARKER")" "https://github.com/o/r/pull/5"
assert_contains "case5: the submitted text says MERGED" "$(cat "$P5_MARKER")" "MERGED"
assert_eq "case5: terminal-nudged.json records a delivered pr_nudge" "$(tn_get p5 pr_nudge delivery)" "https://github.com/o/r/pull/5"
assert_eq "case5: the recorded state is MERGED" "$(tn_get p5 pr_nudge state)" "MERGED"

# --- #6: with WM_GH stubbed to OPEN, the same shape receives no message and
# no pr_nudge entry, though a pr_probe stamp is still written ---------------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
P6_MARKER="$(wm_mktemp_file)"
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-p6 \
  "WM_TEST_BUSY=0 WM_TEST_SWALLOW=0 WM_TEST_MARKER='$P6_MARKER' bash '$COMPOSER_STUB'"
sleep 1
GH6="$(wm_mktemp_file)"; make_fake_gh "$GH6"
FAKE_PR6="$(wm_mktemp_file)"
printf '{"state":"OPEN"}' > "$FAKE_PR6"
wm_state crew-add --id p6 --type developer --objective x --repo /tmp --window wm-p6 --session-id s-p6 >/dev/null
wm_state crew-set --id p6 --status review --delivery "https://github.com/o/r/pull/6" --summary x >/dev/null

WM_GH="$GH6" FAKE_PR="$FAKE_PR6" wm_timeout 45 "$WF" >"$WINGMAN_HOME/wf6.log" 2>&1

# grep -c always prints a count (0 or more) regardless of its own exit
# status, so a trailing `|| echo 0` would double-print on the no-match case.
_submitted6="$(grep -c SUBMITTED "$P6_MARKER" 2>/dev/null)"
assert_eq "case6: no SUBMITTED line for an OPEN pr-probe" "${_submitted6:-0}" "0"
assert_eq "case6: no pr_nudge entry for an OPEN pr-probe" "$(tn_get p6 pr_nudge delivery)" ""
assert_eq "case6: a pr_probe stamp is still written (throttles the next query)" "$(tn_get p6 pr_probe delivery)" "https://github.com/o/r/pull/6"

# --- #8: throttle timing - run A discriminates the throttle-latch mutation,
# run B catches a narrower one. Fixture: a single 'working' member with a
# real window and NOTHING in ATTENTION_STATES, so the watcher genuinely
# keeps polling rather than firing on poll 1. -------------------------------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-w8 'sleep 600'
wm_state crew-add --id w8 --type developer --objective x --repo /tmp --window wm-w8 --session-id s-w8 >/dev/null
wm_state crew-set --id w8 --status working --summary "coding" >/dev/null

WM_TERMINAL_CHECK_EVERY=30 WM_WATCH_INTERVAL=1 "$WF" >"$WINGMAN_HOME/wf8a.log" 2>&1 &
w8a_pid=$!
wm_track "$w8a_pid"
sleep 6.5
assert_true "case8 run A: the watcher is still polling (nothing in ATTENTION_STATES)" "kill -0 $w8a_pid"
kill "$w8a_pid" 2>/dev/null
wait "$w8a_pid" 2>/dev/null
assert_eq "case8 run A: EVERY=30 for ~6 polls reads exactly 1 (throttle held)" \
  "$(cat "$WINGMAN_HOME/terminal-check-count" 2>/dev/null || echo 0)" "1"

test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-w8b 'sleep 600'
wm_state crew-add --id w8b --type developer --objective x --repo /tmp --window wm-w8b --session-id s-w8b >/dev/null
wm_state crew-set --id w8b --status working --summary "coding" >/dev/null

WM_TERMINAL_CHECK_EVERY=1 WM_WATCH_INTERVAL=1 "$WF" >"$WINGMAN_HOME/wf8b.log" 2>&1 &
w8b_pid=$!
wm_track "$w8b_pid"
# Each poll iteration here costs several `uv run` subprocess starts
# (reconcile, forward-motion-check, needs-attention, review-resurface-check,
# and now terminal-nudge-check every tick since EVERY=1) on top of the 1s
# sleep, so real wall-clock per iteration runs well over 1s - a longer
# window than run A's is needed to comfortably clear the >3 threshold.
sleep 12
assert_true "case8 run B: the watcher is still polling" "kill -0 $w8b_pid"
kill "$w8b_pid" 2>/dev/null
wait "$w8b_pid" 2>/dev/null
_count8b="$(cat "$WINGMAN_HOME/terminal-check-count" 2>/dev/null || echo 0)"
case "$_count8b" in
  ''|*[!0-9]*) fail "case8 run B: EVERY=1 counter is a plain integer"; _count8b=0 ;;
  *) ok "case8 run B: EVERY=1 counter is a plain integer" ;;
esac
assert_true "case8 run B: EVERY=1 for ~6 polls reads more than 3" "[ '$_count8b' -gt 3 ]"

test_summary
