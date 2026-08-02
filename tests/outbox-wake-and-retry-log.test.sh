#!/usr/bin/env bash
# E2E: issue #169's remaining coverage not in tests/outbox-abandonment.test.sh
# - M1 (forensic logging: pane-unstable/empty-file, restructured so the
# no-pending-file case is never logged), M5 (the watcher's own long-single-
# line pointer fix), the wake channel's routing + fire()'s notice-only firing
# and rename-aside fold, and round-2 MF-1's wm_tmux_reachable fail-closed
# gate end to end.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
test_new_home
# Sourced AFTER test_new_home - see the identical comment in
# tests/outbox-abandonment.test.sh for why the order matters here.
. "$TEST_REPO/bin/lib/common.sh"

WATCH="$TEST_REPO/bin/watch-fleet"

tmux new-session -d -s "$WM_TMUX_SESSION" -n _idle "sleep 300"

# =============================================================================
# Section 1 - M1: the restructured forensic log
# =============================================================================

# --- pane-unstable, then sent once the pane settles ------------------------
# A busy stub that keeps repainting (defeating PANE_STABLE) for a few ticks,
# then goes idle and behaves like the faithful TUI-input stub every other
# outbox test here drives.
BUSY_STUB="$(wm_mktemp_dir)/busy-stub.sh"
cat > "$BUSY_STUB" <<'STUBEOF'
#!/usr/bin/env bash
stty -echo -icanon intr undef min 1 time 0 2>/dev/null
i=0
while [ "$i" -lt 6 ]; do
  printf 'busy tick %s\n' "$i"
  i=$((i+1))
  sleep 0.4
done
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
chmod +x "$BUSY_STUB"

wm_state crew-add --id busy1 --type developer --objective x --repo /tmp --window wm-busy1 --session-id b1 >/dev/null
tmux new-window -t "$WM_TMUX_TARGET:" -n wm-busy1 "bash '$BUSY_STUB'"
mkdir -p "$WINGMAN_HOME/outbox/busy1"
printf 'queued while the pane is busy\n' > "$WINGMAN_HOME/outbox/busy1/1.msg"

export WM_SUBMIT_DELAY=0 WM_READY_POLL=0.2 WM_SUBMIT_POLL=0.3 WM_READY_TRIES=20 WM_SUBMIT_TRIES=8
WM_WATCH_INTERVAL=1 "$WATCH" --owner "" >/dev/null 2>&1 &
wm_track $!
_i=0
while [ "$_i" -lt 20 ]; do
  [ -f "$WINGMAN_HOME/outbox/busy1/sent-1.msg" ] && break
  sleep 0.5; _i=$((_i+1))
done
"$WATCH" --stop >/dev/null 2>&1
assert_true "the busy-pane message was eventually delivered" \
  "[ -f '$WINGMAN_HOME/outbox/busy1/sent-1.msg' ]"
assert_contains "at least one pane-unstable outcome was logged while the pane was busy" \
  "$(cat "$WINGMAN_HOME/outbox-retry.log" 2>/dev/null)" "	busy1	pane-unstable"
assert_contains "a sent outcome was logged once it settled" \
  "$(cat "$WINGMAN_HOME/outbox-retry.log" 2>/dev/null)" "	busy1	sent"

# --- empty-file: a wedged, unreadable-as-content queued file is diagnosed --
wm_state crew-add --id empty1 --type developer --objective x --repo /tmp --window wm-empty1 --session-id b2 >/dev/null
STUB="$(wm_mktemp_dir)/idle-stub.sh"
cat > "$STUB" <<'STUBEOF'
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
chmod +x "$STUB"
tmux new-window -t "$WM_TMUX_TARGET:" -n wm-empty1 "bash '$STUB'"
mkdir -p "$WINGMAN_HOME/outbox/empty1"
: > "$WINGMAN_HOME/outbox/empty1/1.msg"   # genuinely empty

WM_WATCH_INTERVAL=1 "$WATCH" --owner "" >/dev/null 2>&1 &
wm_track $!
_i=0
while [ "$_i" -lt 10 ]; do
  grep -q "	empty1	empty-file" "$WINGMAN_HOME/outbox-retry.log" 2>/dev/null && break
  sleep 0.5; _i=$((_i+1))
done
"$WATCH" --stop >/dev/null 2>&1
assert_contains "the empty queued file is diagnosed as empty-file" \
  "$(cat "$WINGMAN_HOME/outbox-retry.log" 2>/dev/null)" "	empty1	empty-file"
assert_true "the wedged empty file is left in place (no quarantine - N2 is diagnosis only)" \
  "[ -f '$WINGMAN_HOME/outbox/empty1/1.msg' ]"

# --- no-pending-file is never logged (the outcome round-1 review removed) -
wm_state crew-add --id noneq1 --type developer --objective x --repo /tmp --window wm-noneq1 --session-id b3 >/dev/null
tmux new-window -t "$WM_TMUX_TARGET:" -n wm-noneq1 "bash '$STUB'"
WM_WATCH_INTERVAL=1 "$WATCH" --owner "" >/dev/null 2>&1 &
wm_track $!
sleep 3
"$WATCH" --stop >/dev/null 2>&1
assert_not_contains "a member with no outbox at all never gets a log line" \
  "$(cat "$WINGMAN_HOME/outbox-retry.log" 2>/dev/null)" "noneq1"

# =============================================================================
# Section 2 - M5: the watcher's own long-single-line pointer fix
# =============================================================================
wm_state crew-add --id long1 --type developer --objective x --repo /tmp --window wm-long1 --session-id b4 >/dev/null
tmux new-window -t "$WM_TMUX_TARGET:" -n wm-long1 "bash '$STUB'"
sleep 0.3
LONG_MSG="$(printf 'x%.0s' $(seq 1 600))"
mkdir -p "$WINGMAN_HOME/outbox/long1"
printf '%s\n' "$LONG_MSG" > "$WINGMAN_HOME/outbox/long1/1.msg"

WM_WATCH_INTERVAL=1 "$WATCH" --owner "" >/dev/null 2>&1 &
wm_track $!
# The pointer branch renames to sent- BEFORE typing the pointer (so the
# pointer names the file's final path), so polling on the file's existence
# alone races the actual pane confirm - wait for the pointer to actually
# land in the pane instead (mirrors tests/outbox-redelivery.test.sh's own
# identical multi-line case).
_i=0
while [ "$_i" -lt 20 ]; do
  wm_tmux capture-pane -pJ -t "$(wm_tmux_win_target wm-long1)" 2>/dev/null \
    | grep -q "sent-1.msg" && break
  sleep 0.5; _i=$((_i+1))
done
"$WATCH" --stop >/dev/null 2>&1
assert_true "the long single-line queued message was delivered (moved to sent-)" \
  "[ -f '$WINGMAN_HOME/outbox/long1/sent-1.msg' ]"
pane="$(wm_tmux capture-pane -pJ -t "$(wm_tmux_win_target wm-long1)")"
assert_contains "the pane received a pointer to the sent- file, not the raw payload" \
  "$pane" "sent-1.msg"
assert_not_contains "the raw >500-char single-line payload was never retyped by the watcher" \
  "$pane" "$LONG_MSG"

# =============================================================================
# Section 3 - the wake channel: notice-only fire + the rename-aside fold
# =============================================================================

# --- a notice with no genuine attention event still fires, with its own
# explicit stdout reason line (fire()'s own trigger channel) --------------
printf 'a pre-existing pending notice for wingman\n' > "$WINGMAN_HOME/pending-notices"
_fireout="$(WM_WATCH_INTERVAL=1 wm_timeout 45 "$WATCH" --owner "")"
assert_contains "a notice-only fire prints its own abandoned-message reason line" \
  "$_fireout" "abandoned-message:"
assert_contains "the wake file carries an Abandoned messages section" \
  "$(cat "$WINGMAN_HOME/wake" 2>/dev/null)" "## Abandoned messages"
assert_contains "the wake file's Abandoned messages section carries the actual notice" \
  "$(cat "$WINGMAN_HOME/wake" 2>/dev/null)" "a pre-existing pending notice for wingman"
assert_false "the notice file was consumed (rename-aside emptied it) after the fire" \
  "[ -s '$WINGMAN_HOME/pending-notices' ]"

# --- concurrent appenders during several fire cycles: nothing is silently
# lost (best-effort concurrency stress for the rename-aside fold - S-4) ----
rm -f "$WINGMAN_HOME/wake" "$WINGMAN_HOME/pending-notices"
wm_state crew-add --id churn1 --type developer --objective x --repo /tmp --window wm-churn1 --session-id b5 >/dev/null
_collected="$(wm_mktemp_file)"
(
  for _n in $(seq 1 25); do
    printf 'race-notice-%s\n' "$_n" >> "$WINGMAN_HOME/pending-notices"
    sleep 0.05
  done
) &
_writerpid=$!
WM_WATCH_INTERVAL=1 "$WATCH" --owner "" >/dev/null 2>&1 &
wm_track $!
_wpid=$!
# Force repeated fire/re-arm cycles by flipping churn1's status every beat -
# each cycle's wake file is captured before the next re-arm can overwrite it.
_j=0
while kill -0 "$_writerpid" 2>/dev/null || [ "$_j" -lt 30 ]; do
  wait "$_wpid" 2>/dev/null
  [ -f "$WINGMAN_HOME/wake" ] && cat "$WINGMAN_HOME/wake" >> "$_collected"
  wm_state crew-set --id churn1 --status blocked --blocker "churn $_j" >/dev/null 2>&1
  WM_WATCH_INTERVAL=1 "$WATCH" --owner "" >/dev/null 2>&1 &
  wm_track $!
  _wpid=$!
  wm_state crew-set --id churn1 --status working --summary "churn $_j" >/dev/null 2>&1
  _j=$((_j+1))
  kill -0 "$_writerpid" 2>/dev/null || break
done
wait "$_writerpid" 2>/dev/null
# Drain any remaining notices with a final handful of cycles.
_k=0
while [ "$_k" -lt 5 ]; do
  wait "$_wpid" 2>/dev/null
  [ -f "$WINGMAN_HOME/wake" ] && cat "$WINGMAN_HOME/wake" >> "$_collected"
  [ -s "$WINGMAN_HOME/pending-notices" ] || break
  WM_WATCH_INTERVAL=1 "$WATCH" --owner "" >/dev/null 2>&1 &
  wm_track $!
  _wpid=$!
  _k=$((_k+1))
done
"$WATCH" --stop >/dev/null 2>&1
_missing=0
for _n in $(seq 1 25); do
  grep -q "race-notice-$_n" "$_collected" || _missing=$((_missing+1))
done
assert_eq "every concurrently-appended notice survived across the fire/re-arm churn (none silently lost)" "$_missing" "0"

# =============================================================================
# Section 4 - round-2 MF-1: the wm_tmux_reachable fail-closed gate, end to end
# =============================================================================

# --- genuinely ambiguous (permission-denied socket dir): the scan defers,
# never sweeps a done target's outbox on this poll ------------------------
wm_state crew-add --id ambig1 --type developer --objective x --repo /tmp --window wm-ambig1 --session-id b6 >/dev/null
wm_state crew-set --id ambig1 --status done >/dev/null
mkdir -p "$WINGMAN_HOME/outbox/ambig1"
printf 'must not be swept while tmux is ambiguous\n' > "$WINGMAN_HOME/outbox/ambig1/1.msg"

_broken="$(wm_mktemp_dir)/broken"
mkdir -p "$_broken"
chmod 000 "$_broken"
(
  unset TMUX
  export TMUX_TMPDIR="$_broken"
  WM_WATCH_INTERVAL=1 "$WATCH" --owner "" >/dev/null 2>&1 &
  echo $! > "$WINGMAN_HOME/.ambig-watch.pid"
  wait
) &
wm_track $!
sleep 3
chmod 755 "$_broken"   # restore before any cleanup can remove it
_ambig_watch_pid="$(cat "$WINGMAN_HOME/.ambig-watch.pid" 2>/dev/null)"
[ -n "$_ambig_watch_pid" ] && kill "$_ambig_watch_pid" 2>/dev/null
"$WATCH" --stop >/dev/null 2>&1
assert_true "a done member's outbox is left untouched while wm_tmux_reachable is ambiguous" \
  "[ -f '$WINGMAN_HOME/outbox/ambig1/1.msg' ]"

# --- server genuinely absent (a fresh, never-started isolated socket dir):
# the scan proceeds and sweeps a done target with no live window -----------
wm_state crew-add --id absent1 --type developer --objective x --repo /tmp --window wm-absent1 --session-id b7 >/dev/null
wm_state crew-set --id absent1 --status done >/dev/null
mkdir -p "$WINGMAN_HOME/outbox/absent1"
printf 'no server at all - definitively reachable, sweep this\n' > "$WINGMAN_HOME/outbox/absent1/1.msg"

_never="$(wm_mktemp_dir)/never-started"
(
  unset TMUX
  export TMUX_TMPDIR="$_never"
  WM_WATCH_INTERVAL=1 "$WATCH" --owner "" >/dev/null 2>&1 &
  echo $! > "$WINGMAN_HOME/.absent-watch.pid"
  wait
) &
wm_track $!
_i=0
while [ "$_i" -lt 10 ]; do
  [ -d "$WINGMAN_HOME/outbox-abandoned/absent1" ] && break
  sleep 0.5; _i=$((_i+1))
done
_absent_watch_pid="$(cat "$WINGMAN_HOME/.absent-watch.pid" 2>/dev/null)"
[ -n "$_absent_watch_pid" ] && kill "$_absent_watch_pid" 2>/dev/null
"$WATCH" --stop >/dev/null 2>&1
assert_true "a done member with no server reachable at all is correctly treated as definitively windowless and swept" \
  "[ -d '$WINGMAN_HOME/outbox-abandoned/absent1' ]"

tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null
test_summary
