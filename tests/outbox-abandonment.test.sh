#!/usr/bin/env bash
# E2E: issue #169 - queued crew messages are silently abandoned when the
# target member ends. Covers the fix's core mechanism: the outbox-meta
# sidecar tree, the delivery-reachability/notice-routing predicate split, the
# generic per-poll scan (with its wm_tmux_reachable fail-closed gate and
# exact-field window match), the sweep's own claim protocol and notify
# routing, the wake channel's rename-aside fold, and the crew-standdown/
# crew-prune cascades. tests/outbox-redelivery.test.sh already covers the
# baseline redelivery mechanism (claim protocol, pointer-not-payload,
# multi-line queued redelivery) and is not duplicated here.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
test_new_home
# Sourced AFTER test_new_home: common.sh computes WM_HOME/WM_TMUX_TARGET from
# WINGMAN_HOME/WM_TMUX_SESSION at SOURCE time, and this file calls several
# common.sh functions directly (wm_outbox_*, wm_needs_pointer) in its own
# process rather than only through a subprocess that re-sources it fresh -
# sourcing it before the isolated per-test home/session exist would freeze
# both at their real, non-isolated defaults.
. "$TEST_REPO/bin/lib/common.sh"

SAY="$TEST_REPO/bin/crew-say"
ASK="$TEST_REPO/bin/crew-ask"
STANDDOWN="$TEST_REPO/bin/crew-standdown"
PRUNE="$TEST_REPO/bin/crew-prune"
WATCH="$TEST_REPO/bin/watch-fleet"

# File-scope, not per-block (issue #214): wm_tmux_pane_ready's readiness gate
# is now duration-based (WM_READY_QUIET, default 1.5s), and the capture count
# it derives scales INVERSELY with WM_READY_POLL - both blocks below set a
# sub-second poll (0.3s and 0.2s) to keep the suite fast, which at the
# default quiet window would derive 6 and 9 captures respectively (~1.5-1.6s
# per readiness check instead of ~0.2-0.3s), and the second block's cycle
# (bounded by `wm_timeout 45` below) then runs out of budget before emitting
# its `blocked: blk1` event. Measured: patched without this, 2 failed;
# patched with it, green. Set once here so both blocks are covered, not just
# whichever one a per-block fix happened to touch.
export WM_READY_QUIET=0.2

# A real tmux server is up for the whole file (mirrors every other E2E test
# here) so wm_tmux_reachable reads "reachable" throughout except where a test
# deliberately breaks it.
tmux new-session -d -s "$WM_TMUX_SESSION" -n _idle "sleep 300"

# =============================================================================
# Section 1 - the two predicates, direct calls against hand-built roster JSON
# (no wm_state/tmux round-trip needed - these are pure function tests).
# =============================================================================

# --- delivery-reachability -----------------------------------------------
assert_true "missing record is delivery-terminal" \
  "wm_outbox_delivery_terminal missing '[]' '' 1"
assert_true "stood-down is delivery-terminal" \
  "wm_outbox_delivery_terminal a '[{\"id\":\"a\",\"status\":\"stood-down\"}]' '' 1"
assert_true "died is delivery-terminal" \
  "wm_outbox_delivery_terminal a '[{\"id\":\"a\",\"status\":\"died\"}]' '' 1"
assert_false "working is NOT delivery-terminal" \
  "wm_outbox_delivery_terminal a '[{\"id\":\"a\",\"status\":\"working\"}]' '' 1"

# Round-6 finding 1: done + a LIVE window is NOT delivery-terminal (the
# done-loop still owns it); done + a DEAD (or no) window IS.
assert_false "done with a live window is NOT delivery-terminal" \
  "wm_outbox_delivery_terminal a '[{\"id\":\"a\",\"status\":\"done\",\"window\":\"wm-a\"}]' 'wm-a,wm-b' 1"
assert_true "done with no live window IS delivery-terminal" \
  "wm_outbox_delivery_terminal a '[{\"id\":\"a\",\"status\":\"done\",\"window\":\"wm-a\"}]' 'wm-b,wm-c' 1"

# Round-2 MF-1: an ambiguous (untrusted) window snapshot must never be used
# to conclude a done target is windowless - it defers instead.
assert_false "done target defers (not terminal) when the window snapshot is untrusted" \
  "wm_outbox_delivery_terminal a '[{\"id\":\"a\",\"status\":\"done\",\"window\":\"wm-a\"}]' '' 0"
assert_true "stood-down still resolves even when the window snapshot is untrusted" \
  "wm_outbox_delivery_terminal a '[{\"id\":\"a\",\"status\":\"stood-down\",\"window\":\"wm-a\"}]' '' 0"

# --- notice-routing (deliberately no window clause) -----------------------
assert_true "notice-routing: missing record is terminal" \
  "wm_outbox_notice_terminal missing '[]'"
assert_true "notice-routing: done IS terminal regardless of window (round-6 finding 2)" \
  "wm_outbox_notice_terminal a '[{\"id\":\"a\",\"status\":\"done\",\"window\":\"wm-a\"}]'"
assert_false "notice-routing: working is NOT terminal" \
  "wm_outbox_notice_terminal a '[{\"id\":\"a\",\"status\":\"working\"}]'"

# --- wm_outbox_resolve_notice_owner: the parent-chain walk -----------------
R1='[{"id":"w1","status":"working","parent":""}]'
assert_eq "a member with no parent record floors at wingman" \
  "$(wm_outbox_resolve_notice_owner w1missing "$R1")" ""

R2='[{"id":"lead1","status":"working","parent":""},{"id":"w1","status":"working","parent":"lead1"}]'
assert_eq "a non-terminal parent is returned directly" \
  "$(wm_outbox_resolve_notice_owner w1 "$R2")" "lead1"

R3='[{"id":"lead1","status":"stood-down","parent":""},{"id":"w1","status":"working","parent":"lead1"}]'
assert_eq "a stood-down parent with a non-terminal grandparent (wingman) still floors correctly at wingman when lead1 has no further parent" \
  "$(wm_outbox_resolve_notice_owner w1 "$R3")" ""

R4='[{"id":"gp","status":"working","parent":""},{"id":"lead1","status":"stood-down","parent":"gp"},{"id":"w1","status":"working","parent":"lead1"}]'
assert_eq "a terminal parent is skipped in favor of the first non-terminal ancestor" \
  "$(wm_outbox_resolve_notice_owner w1 "$R4")" "gp"

# Round-6 finding 2, the key regression: a `done` parent with a LIVE window
# is STILL notice-routing-terminal (no window clause at all) - a `done`
# member's own watcher arms nothing further regardless of window liveness.
R5='[{"id":"lead1","status":"done","parent":"","window":"wm-lead1"},{"id":"w1","status":"working","parent":"lead1"}]'
assert_eq "a done parent with a LIVE window still floors to wingman, never resolves to the dead-end parent" \
  "$(wm_outbox_resolve_notice_owner w1 "$R5")" ""

# =============================================================================
# Section 2 - wm_needs_pointer / wm_outbox_basename (direct function tests)
# =============================================================================
assert_true "a multi-line message needs a pointer" "wm_needs_pointer 'line one
line two'"
LONG_MSG="$(printf 'x%.0s' $(seq 1 600))"
assert_true "a >500-char single-line message needs a pointer" "wm_needs_pointer '$LONG_MSG'"
assert_false "a short single-line message does not need a pointer" "wm_needs_pointer 'hello'"
assert_eq "wm_outbox_basename strips a sent- claim prefix" "$(wm_outbox_basename /tmp/outbox/x/sent-123-456.msg)" "123-456.msg"
assert_eq "wm_outbox_basename is a no-op on an unclaimed file" "$(wm_outbox_basename /tmp/outbox/x/123-456.msg)" "123-456.msg"

# =============================================================================
# Section 3 - callers write the sidecar BEFORE the payload
# =============================================================================
# A stub that faithfully emulates a real confirmation dialog (mirrors
# tests/dialog-delivery-refusal.test.sh), so a real send genuinely refuses
# and queues rather than needing "no live window" (a different, earlier
# refusal that never reaches the outbox write at all).
DIALOG_STUB="$(wm_mktemp_dir)/dialog-stub.sh"
cat > "$DIALOG_STUB" <<'DIALOGEOF'
#!/usr/bin/env bash
stty -echo -icanon min 1 time 0 2>/dev/null
printf 'Do you want to proceed?\n'
printf '\xe2\x9d\xaf 1. Yes\n'
printf '  2. No\n'
while IFS= read -r -n1 ch; do :; done
DIALOGEOF
chmod +x "$DIALOG_STUB"
export WM_SUBMIT_DELAY=0 WM_READY_POLL=0.3 WM_SUBMIT_POLL=0.4 WM_READY_TRIES=20 WM_SUBMIT_TRIES=8

wm_state crew-add --id sc1 --type developer --objective x --repo /tmp --window wm-sc1 --session-id s1 >/dev/null
tmux new-window -t "$WM_TMUX_TARGET:" -n wm-sc1 "bash '$DIALOG_STUB'"
sleep 1
"$SAY" sc1 "hello there" >/dev/null 2>&1
_sc1_file="$(ls "$WINGMAN_HOME/outbox/sc1" 2>/dev/null | head -1)"
assert_true "crew-say queued a file for sc1" "[ -n '$_sc1_file' ]"
assert_true "crew-say wrote a sidecar for it before the payload" \
  "[ -f '$WINGMAN_HOME/outbox-meta/sc1/$_sc1_file' ]"
assert_eq "the sidecar records wingman (empty) as sender for a wingman-issued crew-say" \
  "$(cat "$WINGMAN_HOME/outbox-meta/sc1/$_sc1_file" 2>/dev/null)" ""

wm_state crew-add --id sc2 --type developer --objective x --repo /tmp --window wm-sc2 --session-id s2 >/dev/null
tmux new-window -t "$WM_TMUX_TARGET:" -n wm-sc2 "bash '$DIALOG_STUB'"
sleep 1
WINGMAN_CREW_ID=lead1 "$ASK" --force sc2 "what is your status?" >/dev/null 2>&1
_sc2_file="$(ls "$WINGMAN_HOME/outbox/sc2" 2>/dev/null | head -1)"
assert_true "crew-ask queued a file for sc2" "[ -n '$_sc2_file' ]"
assert_eq "the sidecar records the asking crew id as sender" \
  "$(cat "$WINGMAN_HOME/outbox-meta/sc2/$_sc2_file" 2>/dev/null)" "lead1"

# =============================================================================
# Section 4 - the sweep's own mechanics (wm_outbox_sweep_abandoned, direct)
# =============================================================================

# --- unreachable/unknown sender routes through <notify-mode> --------------
mkdir -p "$WINGMAN_HOME/outbox/sw1" "$WINGMAN_HOME/outbox-meta/sw1"
printf 'a message nobody will ever see\n' > "$WINGMAN_HOME/outbox/sw1/1-a.msg"
printf 'ghost-sender\n' > "$WINGMAN_HOME/outbox-meta/sw1/1-a.msg"
_ros='[{"id":"sw1","status":"stood-down"},{"id":"ghost-sender","status":"died"}]'
_out="$(wm_outbox_sweep_abandoned sw1 "it was stood down" stdout "$_ros" "" 1)"
assert_contains "a terminal sender's notice prints via stdout notify-mode" "$_out" "Abandoned outbox message for 'sw1'"
assert_true "the payload moved to outbox-abandoned/sw1/" \
  "[ -f '$WINGMAN_HOME/outbox-abandoned/sw1/1-a.msg' ]"
assert_false "the original queued file is gone" "[ -f '$WINGMAN_HOME/outbox/sw1/1-a.msg' ]"
assert_true "the sidecar was removed" "[ ! -f '$WINGMAN_HOME/outbox-meta/sw1/1-a.msg' ]"
assert_true "the outbox/<id> directory was rmdir'd once empty" "[ ! -d '$WINGMAN_HOME/outbox/sw1' ]"
assert_contains "the audit log recorded the sweep" \
  "$(cat "$WINGMAN_HOME/outbox-abandoned.log" 2>/dev/null)" "sw1"

# --- a live, reachable sender gets the notice queued into its OWN outbox --
mkdir -p "$WINGMAN_HOME/outbox/sw2" "$WINGMAN_HOME/outbox-meta/sw2"
printf 'a message for a live lead to relay\n' > "$WINGMAN_HOME/outbox/sw2/1-b.msg"
printf 'lead-alive\n' > "$WINGMAN_HOME/outbox-meta/sw2/1-b.msg"
_ros2='[{"id":"sw2","status":"stood-down"},{"id":"lead-alive","status":"working"}]'
_out2="$(wm_outbox_sweep_abandoned sw2 "it was stood down" stdout "$_ros2" "" 1)"
assert_eq "a reachable sender gets no stdout notice - it is queued instead" "$_out2" ""
_sw2_notice="$(ls "$WINGMAN_HOME/outbox/lead-alive" 2>/dev/null | head -1)"
assert_true "the notice was queued into the reachable sender's own outbox" "[ -n '$_sw2_notice' ]"
assert_eq "the queued notice's own sidecar attributes it to wingman (empty)" \
  "$(cat "$WINGMAN_HOME/outbox-meta/lead-alive/$_sw2_notice" 2>/dev/null)" ""
assert_contains "the queued notice names the swept id" \
  "$(cat "$WINGMAN_HOME/outbox/lead-alive/$_sw2_notice")" "sw2"

# --- pointer-not-payload applies to the notice's own content too ----------
mkdir -p "$WINGMAN_HOME/outbox/sw3" "$WINGMAN_HOME/outbox-meta/sw3"
printf '%s\n' "$LONG_MSG" > "$WINGMAN_HOME/outbox/sw3/1-c.msg"
printf 'long-gone-sender\n' > "$WINGMAN_HOME/outbox-meta/sw3/1-c.msg"
_ros3='[{"id":"sw3","status":"died"}]'
_out3="$(wm_outbox_sweep_abandoned sw3 "it died" stdout "$_ros3" "" 1)"
assert_not_contains "a long payload's raw content is never inlined into the notice" "$_out3" "$LONG_MSG"
assert_contains "the notice instead points at the durable copy" "$_out3" "outbox-abandoned/sw3"

# --- concurrency: the mv-based claim resolves a race to exactly one winner
mkdir -p "$WINGMAN_HOME/outbox/sw4" "$WINGMAN_HOME/outbox-meta/sw4"
printf 'raced message\n' > "$WINGMAN_HOME/outbox/sw4/1-d.msg"
printf 'long-gone-sender\n' > "$WINGMAN_HOME/outbox-meta/sw4/1-d.msg"
_ros4='[{"id":"sw4","status":"died"}]'
_race_out1="$(wm_mktemp_file)"; _race_out2="$(wm_mktemp_file)"
wm_outbox_sweep_abandoned sw4 "race test" stdout "$_ros4" "" 1 > "$_race_out1" 2>&1 &
_racepid1=$!
wm_outbox_sweep_abandoned sw4 "race test" stdout "$_ros4" "" 1 > "$_race_out2" 2>&1 &
_racepid2=$!
wait "$_racepid1" "$_racepid2"
_race_lines="$(cat "$_race_out1" "$_race_out2" | grep -c "Abandoned outbox message")"
assert_eq "exactly one of the two racing sweeps produced a notice" "$_race_lines" "1"
_race_log_lines="$(grep -c "sw4" "$WINGMAN_HOME/outbox-abandoned.log" 2>/dev/null)"
assert_eq "exactly one audit-log line was written for the raced message" "$_race_log_lines" "1"

# --- review round 1, must-fix 1: an empty (KNOWN) sender is wingman, and
# wingman must route through <notify-mode> like any other unreachable
# sender - it is never itself an outbox this mechanism delivers into. The
# bug this guards: treating empty-as-reachable wrote the notice to
# "$WM_HOME/outbox/$_sw_sender" with the variable empty, which collapses to
# a stray FILE directly under outbox/ that nothing ever reads. ------------
mkdir -p "$WINGMAN_HOME/outbox/sw5" "$WINGMAN_HOME/outbox-meta/sw5"
printf 'a message wingman itself queued\n' > "$WINGMAN_HOME/outbox/sw5/1-m.msg"
: > "$WINGMAN_HOME/outbox-meta/sw5/1-m.msg"   # empty sidecar = wingman
_ros5='[{"id":"sw5","status":"died"}]'
_out5="$(wm_outbox_sweep_abandoned sw5 "it died" stdout "$_ros5" "" 1)"
assert_contains "a wingman-authored (empty sender) message routes through notify-mode" \
  "$_out5" "Abandoned outbox message for 'sw5'"
assert_false "no stray file was ever written directly under outbox/ itself" \
  "find '$WINGMAN_HOME/outbox' -maxdepth 1 -type f 2>/dev/null | grep -q ."

# --- issue #230: dead-to-dead residue is archived and logged, but never
# announced - a notice whose sender is ALSO terminal would otherwise be
# enough on its own to fire a full attention wake with nothing behind it.
# The notice-file assertions glob over pending-notices* rather than naming
# the wingman floor, so a future change to the notice-routing walk cannot
# make them pass vacuously by writing to a per-owner channel instead.
mkdir -p "$WINGMAN_HOME/outbox/dd1" "$WINGMAN_HOME/outbox-meta/dd1"
printf 'dead to dead\n' > "$WINGMAN_HOME/outbox/dd1/1.msg"
printf 'dead-sender\n' > "$WINGMAN_HOME/outbox-meta/dd1/1.msg"
_rosdd='[{"id":"dd1","status":"stood-down"},{"id":"dead-sender","status":"stood-down"}]'
wm_outbox_sweep_abandoned dd1 "its crew record is stood-down" wake "$_rosdd" "" 1
assert_false "a dead-to-dead sweep appends no notice to any wake channel" \
  "find '$WINGMAN_HOME' -maxdepth 1 -name 'pending-notices*' -size +0 2>/dev/null | grep -q ."
assert_true "the durable archive is still written for a suppressed notice" \
  "[ -f '$WINGMAN_HOME/outbox-abandoned/dd1/1.msg' ]"
assert_contains "the audit log line is still written for a suppressed notice" \
  "$(cat "$WINGMAN_HOME/outbox-abandoned.log" 2>/dev/null)" "dd1"

# A `done` sender with no live window reaches this branch and is
# notice-routing-terminal, so it is dead-to-dead too.
mkdir -p "$WINGMAN_HOME/outbox/dd2" "$WINGMAN_HOME/outbox-meta/dd2"
printf 'done sender\n' > "$WINGMAN_HOME/outbox/dd2/1.msg"
printf 'done-sender\n' > "$WINGMAN_HOME/outbox-meta/dd2/1.msg"
_rosdd2='[{"id":"dd2","status":"died"},{"id":"done-sender","status":"done"}]'
wm_outbox_sweep_abandoned dd2 "its crew record is died" wake "$_rosdd2" "" 1
assert_false "a done sender with no live window is also dead-to-dead (no notice)" \
  "find '$WINGMAN_HOME' -maxdepth 1 -name 'pending-notices*' -size +0 2>/dev/null | grep -q ."

# The two senders that must KEEP waking: neither is evidence anyone is gone.
mkdir -p "$WINGMAN_HOME/outbox/dd3"
printf 'unknown sender\n' > "$WINGMAN_HOME/outbox/dd3/1.msg"   # no sidecar at all
_rosdd3='[{"id":"dd3","status":"stood-down"}]'
wm_outbox_sweep_abandoned dd3 "its crew record is stood-down" wake "$_rosdd3" "" 1
assert_contains "an unattributable (no sidecar) sender still queues a wake notice" \
  "$(cat "$WINGMAN_HOME/pending-notices" 2>/dev/null)" "dd3"
: > "$WINGMAN_HOME/pending-notices"

mkdir -p "$WINGMAN_HOME/outbox/dd4" "$WINGMAN_HOME/outbox-meta/dd4"
printf 'wingman sender\n' > "$WINGMAN_HOME/outbox/dd4/1.msg"
: > "$WINGMAN_HOME/outbox-meta/dd4/1.msg"   # empty sidecar = wingman
_rosdd4='[{"id":"dd4","status":"stood-down"}]'
wm_outbox_sweep_abandoned dd4 "its crew record is stood-down" wake "$_rosdd4" "" 1
assert_contains "a wingman-authored (empty, known) sender still queues a wake notice" \
  "$(cat "$WINGMAN_HOME/pending-notices" 2>/dev/null)" "dd4"
rm -f "$WINGMAN_HOME/pending-notices"

# --- review round 1, must-fix 2: the notice filename must not collide
# across SEPARATE calls to wm_outbox_sweep_abandoned in the same process
# within the same second - watch-fleet's own scan calls it once per
# terminal id per poll, and crew-standdown/crew-prune call it once per
# cascaded/swept id, so two ids notifying the same live sender in one poll
# must not have the second call's notice silently overwrite the first's. -
mkdir -p "$WINGMAN_HOME/outbox/sw6a" "$WINGMAN_HOME/outbox-meta/sw6a"
printf 'first message\n' > "$WINGMAN_HOME/outbox/sw6a/1.msg"
printf 'shared-live-sender\n' > "$WINGMAN_HOME/outbox-meta/sw6a/1.msg"
mkdir -p "$WINGMAN_HOME/outbox/sw6b" "$WINGMAN_HOME/outbox-meta/sw6b"
printf 'second message\n' > "$WINGMAN_HOME/outbox/sw6b/1.msg"
printf 'shared-live-sender\n' > "$WINGMAN_HOME/outbox-meta/sw6b/1.msg"
_ros6='[{"id":"sw6a","status":"died"},{"id":"sw6b","status":"died"},{"id":"shared-live-sender","status":"working"}]'
wm_outbox_sweep_abandoned sw6a "it died" stdout "$_ros6" "" 1 >/dev/null
wm_outbox_sweep_abandoned sw6b "it died" stdout "$_ros6" "" 1 >/dev/null
_notice_count="$(ls "$WINGMAN_HOME/outbox/shared-live-sender" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "two separate sweeps notifying the same sender within one second each leave their own distinct notice" \
  "$_notice_count" "2"

# --- nice-to-have: the sent- skip matches the file's own BASENAME, never a
# path substring - an outbox id that itself begins with "sent-" must not
# have its own genuinely pending files misread as already-delivered. ------
mkdir -p "$WINGMAN_HOME/outbox/sent-report" "$WINGMAN_HOME/outbox-meta/sent-report"
printf 'a real pending message under a sent--prefixed id\n' > "$WINGMAN_HOME/outbox/sent-report/1.msg"
printf 'long-gone-sender\n' > "$WINGMAN_HOME/outbox-meta/sent-report/1.msg"
_ros7='[{"id":"sent-report","status":"died"}]'
_out7="$(wm_outbox_sweep_abandoned sent-report "it died" stdout "$_ros7" "" 1)"
assert_contains "an id beginning with 'sent-' does not fool the skip into ignoring its own pending file" \
  "$_out7" "Abandoned outbox message for 'sent-report'"

# =============================================================================
# Section 5 - bin/crew-standdown cascades the sweep
# =============================================================================
wm_state crew-add --id sd1 --type developer --objective x --repo /tmp --window wm-sd1 --session-id s3 >/dev/null
mkdir -p "$WINGMAN_HOME/outbox/sd1" "$WINGMAN_HOME/outbox-meta/sd1"
printf 'answer for sd1\n' > "$WINGMAN_HOME/outbox/sd1/1-e.msg"
printf 'long-gone-sender\n' > "$WINGMAN_HOME/outbox-meta/sd1/1-e.msg"
_sd_out="$("$STANDDOWN" sd1 2>&1)"
assert_contains "crew-standdown reports the abandoned message directly on stdout" "$_sd_out" "Abandoned outbox message for 'sd1'"
assert_true "sd1's payload is durably archived" "[ -f \"\$(ls $WINGMAN_HOME/outbox-abandoned/sd1/1-e.msg 2>/dev/null)\" ]"
assert_true "sd1's outbox directory is gone" "[ ! -d '$WINGMAN_HOME/outbox/sd1' ]"

# =============================================================================
# Section 6 - bin/crew-prune sweeps before wm_state prune removes the record
# (round-2 SF-1, corrected per round-3: the observable, structural ordering
# invariant - no archived id retains a pending outbox file).
# =============================================================================
wm_state crew-add --id pr1 --type developer --objective x --repo /tmp --window wm-pr1 --session-id s4 >/dev/null
wm_state crew-set --id pr1 --status stood-down >/dev/null
mkdir -p "$WINGMAN_HOME/outbox/pr1" "$WINGMAN_HOME/outbox-meta/pr1"
printf 'never delivered to pr1\n' > "$WINGMAN_HOME/outbox/pr1/1-f.msg"
printf 'long-gone-sender\n' > "$WINGMAN_HOME/outbox-meta/pr1/1-f.msg"
_pr_out="$("$PRUNE" 2>&1)"
assert_contains "crew-prune reports the sweep before pruning" "$_pr_out" "Abandoned outbox message for 'pr1'"
assert_contains "crew-prune still reports the removal" "$_pr_out" "pruned"
assert_true "pr1 was archived" "grep -q '\"id\": \"pr1\"' '$WINGMAN_HOME/crew-archive.jsonl'"
# The invariant this whole ordering depends on (bin/spawn-crew:288-291 - an id
# with any roster record, live or terminal, is never reused by the allocator)
# is what makes this after-the-fact assertion sufficient: pass 1/pass 2 both
# ran inside this SAME crew-prune invocation, strictly before wm_state prune
# removed pr1's record, so no id in crew-archive.jsonl can retain a pending
# outbox file - asserted here from OUTSIDE the crew-prune call, never by
# instrumenting its internals.
assert_true "no pending (non-sent-) file remains for the pruned id" \
  "[ ! -d '$WINGMAN_HOME/outbox/pr1' ]"

# =============================================================================
# Section 7 - the generic per-poll scan (bin/watch-fleet)
# =============================================================================

# --- the original bug: a NESTED member's outbox, owned by a lead whose own
# watcher isn't running, is still serviced by wingman's top-level scan -----
wm_state crew-add --id lead-x --type lead --objective x --repo /tmp --window wm-lead-x --session-id s5 >/dev/null
wm_state crew-set --id lead-x --status stood-down >/dev/null
wm_state crew-add --id nested1 --type developer --objective x --repo /tmp --window wm-nested1 --session-id s6 --parent lead-x >/dev/null
wm_state crew-set --id nested1 --status stood-down >/dev/null
mkdir -p "$WINGMAN_HOME/outbox/nested1" "$WINGMAN_HOME/outbox-meta/nested1"
printf 'stuck under a dead lead\n' > "$WINGMAN_HOME/outbox/nested1/1-g.msg"
: > "$WINGMAN_HOME/outbox-meta/nested1/1-g.msg"

WM_WATCH_INTERVAL=1 "$WATCH" --owner "" >/dev/null 2>&1 &
wm_track $!
_i=0
while [ "$_i" -lt 20 ]; do
  [ -d "$WINGMAN_HOME/outbox-abandoned/nested1" ] && break
  sleep 0.5; _i=$((_i+1))
done
"$WATCH" --stop >/dev/null 2>&1
assert_true "wingman's own top-level cycle swept a nested member's outbox, not just top-level ones" \
  "[ -d '$WINGMAN_HOME/outbox-abandoned/nested1' ]"

# --- round-6 finding 1: done + live window is never swept; done + dead
# window is (this poll, not deferred to the next) --------------------------
wm_state crew-add --id done-live --type developer --objective x --repo /tmp --window wm-done-live --session-id s7 >/dev/null
wm_state crew-set --id done-live --status done >/dev/null
tmux new-window -t "$WM_TMUX_TARGET:" -n wm-done-live "sleep 300"
mkdir -p "$WINGMAN_HOME/outbox/done-live" "$WINGMAN_HOME/outbox-meta/done-live"
printf 'the done-loop still owns this\n' > "$WINGMAN_HOME/outbox/done-live/1-h.msg"
: > "$WINGMAN_HOME/outbox-meta/done-live/1-h.msg"

wm_state crew-add --id done-dead --type developer --objective x --repo /tmp --window wm-done-dead --session-id s8 >/dev/null
wm_state crew-set --id done-dead --status done >/dev/null
mkdir -p "$WINGMAN_HOME/outbox/done-dead" "$WINGMAN_HOME/outbox-meta/done-dead"
printf 'the window is gone - sweep this\n' > "$WINGMAN_HOME/outbox/done-dead/1-i.msg"
: > "$WINGMAN_HOME/outbox-meta/done-dead/1-i.msg"

WM_WATCH_INTERVAL=1 "$WATCH" --owner "" >/dev/null 2>&1 &
wm_track $!
_i=0
while [ "$_i" -lt 20 ]; do
  [ -d "$WINGMAN_HOME/outbox-abandoned/done-dead" ] && break
  sleep 0.5; _i=$((_i+1))
done
sleep 1.5   # let a couple more polls pass so a wrongly-swept done-live would have shown up too
"$WATCH" --stop >/dev/null 2>&1
assert_true "a done member with a live window keeps its outbox untouched" \
  "[ -f '$WINGMAN_HOME/outbox/done-live/1-h.msg' ]"
assert_false "a done member with a live window was NOT swept" \
  "[ -d '$WINGMAN_HOME/outbox-abandoned/done-live' ]"
assert_true "a done member with a dead window was swept" \
  "[ -d '$WINGMAN_HOME/outbox-abandoned/done-dead' ]"

# --- round-7 observation A: exact-field window match, never a substring ---
# done-live's own window (wm-done-live) is a strict prefix of no other
# window here, so construct the actual collision shape: an id whose window
# name is a strict prefix of another live window's name.
wm_state crew-add --id issue-169-plan-reviewer --type reviewer --objective x --repo /tmp --window wm-issue-169-plan-reviewer --session-id s9 >/dev/null
wm_state crew-set --id issue-169-plan-reviewer --status done >/dev/null
mkdir -p "$WINGMAN_HOME/outbox/issue-169-plan-reviewer" "$WINGMAN_HOME/outbox-meta/issue-169-plan-reviewer"
printf 'the short id is dead - sweep it\n' > "$WINGMAN_HOME/outbox/issue-169-plan-reviewer/1-j.msg"
: > "$WINGMAN_HOME/outbox-meta/issue-169-plan-reviewer/1-j.msg"

wm_state crew-add --id issue-169-plan-reviewer7 --type reviewer --objective x --repo /tmp --window wm-issue-169-plan-reviewer7 --session-id s10 >/dev/null
wm_state crew-set --id issue-169-plan-reviewer7 --status done >/dev/null
tmux new-window -t "$WM_TMUX_TARGET:" -n wm-issue-169-plan-reviewer7 "sleep 300"
mkdir -p "$WINGMAN_HOME/outbox/issue-169-plan-reviewer7" "$WINGMAN_HOME/outbox-meta/issue-169-plan-reviewer7"
printf 'the long id is alive - never sweep it\n' > "$WINGMAN_HOME/outbox/issue-169-plan-reviewer7/1-k.msg"
: > "$WINGMAN_HOME/outbox-meta/issue-169-plan-reviewer7/1-k.msg"

WM_WATCH_INTERVAL=1 "$WATCH" --owner "" >/dev/null 2>&1 &
wm_track $!
_i=0
while [ "$_i" -lt 20 ]; do
  [ -d "$WINGMAN_HOME/outbox-abandoned/issue-169-plan-reviewer" ] && break
  sleep 0.5; _i=$((_i+1))
done
sleep 1.5
"$WATCH" --stop >/dev/null 2>&1
assert_true "the dead short-id window was swept" \
  "[ -d '$WINGMAN_HOME/outbox-abandoned/issue-169-plan-reviewer' ]"
assert_false "the live long-id window, a strict superstring of the dead one, was NOT misread as live and swept" \
  "[ -d '$WINGMAN_HOME/outbox-abandoned/issue-169-plan-reviewer7' ]"

# =============================================================================
# Section 8 - review round 1, must-fix 3: the whole-fleet backstop (piece 1)
# reaches an indirect descendant, with a namespaced PANE_STABLE capture that
# does not contend with the owner-scoped watcher polling the same id, under
# real two-process concurrency.
# =============================================================================
IDLE_STUB="$(wm_mktemp_dir)/idle-stub2.sh"
cat > "$IDLE_STUB" <<'STUBEOF'
#!/usr/bin/env bash
stty -echo -icanon intr undef min 1 time 0 2>/dev/null
printf 'PROMPT READY\n'
buf=""
while IFS= read -r -n1 ch; do
  case "$ch" in
    ""|$'\r'|$'\n') printf 'SUBMITTED:%s\n' "$buf"; buf="" ;;
    $'\003') buf="" ;;
    *) buf="$buf$ch" ;;
  esac
done
STUBEOF
chmod +x "$IDLE_STUB"
export WM_SUBMIT_DELAY=0 WM_READY_POLL=0.2 WM_SUBMIT_POLL=0.3 WM_READY_TRIES=20 WM_SUBMIT_TRIES=8

# lead-b needs its own LIVE window: if it had none, reconcile would flip it
# to died and needs-attention would fire and exit the poll before the
# backstop below ever runs on that same poll - looking like a broken
# backstop when the real cause is an unrelated early exit.
wm_state crew-add --id lead-b --type lead --objective x --repo /tmp --window wm-lead-b --session-id s11 >/dev/null
tmux new-window -t "$WM_TMUX_TARGET:" -n wm-lead-b "sleep 300"
wm_state crew-add --id worker-b --type developer --objective x --repo /tmp --window wm-worker-b --session-id s12 --parent lead-b >/dev/null
tmux new-window -t "$WM_TMUX_TARGET:" -n wm-worker-b "bash '$IDLE_STUB'"
sleep 0.3
mkdir -p "$WINGMAN_HOME/outbox/worker-b"
printf 'a message stuck behind lead-b own watcher not being current\n' > "$WINGMAN_HOME/outbox/worker-b/1.msg"

# Two real, concurrent watch-fleet processes: lead-b's own owner-scoped cycle
# (which directly covers worker-b, a report of lead-b) and wingman's
# top-level cycle (which does NOT - worker-b's parent is lead-b, not "" - so
# only its whole-fleet backstop can reach it).
WM_WATCH_INTERVAL=1 "$WATCH" --owner lead-b >/dev/null 2>&1 &
wm_track $!
WM_WATCH_INTERVAL=1 "$WATCH" --owner "" >/dev/null 2>&1 &
wm_track $!
_i=0
while [ "$_i" -lt 20 ]; do
  [ -f "$WINGMAN_HOME/outbox/worker-b/sent-1.msg" ] && break
  sleep 0.5; _i=$((_i+1))
done
"$WATCH" --owner lead-b --stop >/dev/null 2>&1
"$WATCH" --owner "" --stop >/dev/null 2>&1
assert_true "the backstop reached an indirect descendant (not a direct report of the top-level cycle)" \
  "[ -f '$WINGMAN_HOME/outbox/worker-b/sent-1.msg' ]"
assert_true "the backstop used its own NAMESPACED pane capture" \
  "[ -f '$WINGMAN_HOME/pane-worker-b-backstop.hash' ]"
assert_true "lead-b's own owner-scoped loop independently used the SHARED (non-namespaced) capture for the same id" \
  "[ -f '$WINGMAN_HOME/pane-worker-b.hash' ]"

# =============================================================================
# Section 9 - nice-to-have: a sweep happens on the SAME poll that also fires
# needs-attention, never deferred to a later poll by fire()'s own exit 0.
# =============================================================================
wm_state crew-add --id blk1 --type developer --objective x --repo /tmp --window wm-blk1 --session-id s13 >/dev/null
tmux new-window -t "$WM_TMUX_TARGET:" -n wm-blk1 "sleep 300"
wm_state crew-set --id blk1 --status blocked --blocker "needs a decision" >/dev/null
mkdir -p "$WINGMAN_HOME/outbox/term1" "$WINGMAN_HOME/outbox-meta/term1"
printf 'must be swept on the very poll that also fires\n' > "$WINGMAN_HOME/outbox/term1/1.msg"
printf 'long-gone-sender\n' > "$WINGMAN_HOME/outbox-meta/term1/1.msg"
wm_state crew-add --id term1 --type developer --objective x --repo /tmp --window wm-term1 --session-id s14 >/dev/null
wm_state crew-set --id term1 --status stood-down >/dev/null
_samepoll_out="$(WM_WATCH_INTERVAL=1 wm_timeout 45 "$WATCH" --owner "")"
assert_contains "the genuine attention event fired as usual" "$_samepoll_out" "blocked: blk1"
assert_true "the terminal member's outbox was swept on that SAME poll, not deferred" \
  "[ -d '$WINGMAN_HOME/outbox-abandoned/term1' ]"

tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null
test_summary
