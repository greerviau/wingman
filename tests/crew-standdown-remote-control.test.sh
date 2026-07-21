#!/usr/bin/env bash
# E2E: bin/crew-standdown deregisters Remote Control before killing a still-
# live crew member's window (issue #96): `/remote-control` is a blind stateful
# toggle, not an idempotent disconnect, so it must only be sent when the
# roster's own already-vetted `remote_control_connected` field (written by
# bin/watch-fleet's stability-gated poll - see tests/watch-fleet.test.sh) says
# the session is (or is assumed to still be) connected. crew-standdown itself
# does no pane inspection at all - every case below sets the roster fields
# directly via wm_state crew-add/crew-set rather than needing a stub pane to
# simulate connection state, closing the round-2 review's test-blind-spot note
# (N1): a stub pane has no real connection state to represent "banner-like
# text present but genuinely still connected"; a roster field does not have
# that limitation, since the test sets the field itself.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

STANDDOWN="$TEST_REPO/bin/crew-standdown"

export WM_SUBMIT_DELAY=0 WM_READY_POLL=0.3 WM_SUBMIT_POLL=0.4 WM_READY_TRIES=20 WM_SUBMIT_TRIES=8 \
  WM_RC_DISCONNECT_SETTLE=0

strip_remote_control_fields() {
  # strip_remote_control_fields <crew.json path> <id> - simulate a pre-fix
  # legacy record: both fields entirely absent, not merely false/null.
  uv run --no-project --quiet python -c '
import json, sys
path, rid = sys.argv[1], sys.argv[2]
d = json.load(open(path))
for r in d:
    if r.get("id") == rid:
        r.pop("remote_control", None)
        r.pop("remote_control_connected", None)
json.dump(d, open(path, "w"))
' "$1" "$2"
}

# --- Case A: live window, remote_control=true, remote_control_connected=true -
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id a1 --type developer --objective x --repo /tmp --window wm-a1 --session-id sa1 --remote-control >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-a1 "sleep 120"
"$STANDDOWN" a1 >/dev/null 2>&1
assert_false "case A: the window is closed" "tmux list-windows -t '=$WM_TMUX_SESSION' -F '#{window_name}' 2>/dev/null | grep -qx wm-a1"

# --- Case B: live window, remote_control=false --------------------------------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id b1 --type developer --objective x --repo /tmp --window wm-b1 --session-id sb1 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-b1 "sleep 120"
"$STANDDOWN" b1 >/dev/null 2>&1
assert_false "case B: the window is closed" "tmux list-windows -t '=$WM_TMUX_SESSION' -F '#{window_name}' 2>/dev/null | grep -qx wm-b1"
# (the literal-send content assertion for this case is in the pipe-pane-backed
# re-run near the end of this file, since a closed window has no scrollback
# left to directly confirm "no send happened" against)

# --- Case C: live window, both fields absent (a pre-fix legacy record) -------
# Treated the same as case A (absent reads as true on both fields).
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id c1 --type developer --objective x --repo /tmp --window wm-c1 --session-id sc1 >/dev/null
strip_remote_control_fields "$WINGMAN_HOME/crew.json" c1
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-c1 "sleep 120"
"$STANDDOWN" c1 >/dev/null 2>&1
assert_false "case C: the window is closed" "tmux list-windows -t '=$WM_TMUX_SESSION' -F '#{window_name}' 2>/dev/null | grep -qx wm-c1"

# --- Case D: window already dead by the time standdown runs -------------------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id d1 --type developer --objective x --repo /tmp --window wm-d1 --session-id sd1 --remote-control >/dev/null
# No window ever created for wm-d1 - nothing to send into, and standdown must
# complete without error.
out_d="$("$STANDDOWN" d1 2>&1)"; rc_d=$?
assert_eq "case D: standdown exits 0 with no window to act on" "$rc_d" "0"
assert_contains "case D: standdown still reports success" "$out_d" "stood down d1"

# --- Case E: dialog-shaped pane refuses the send but standdown still proceeds -
DIALOG_STUB="$(wm_mktemp_dir)/dialog-stub.sh"
cat > "$DIALOG_STUB" <<'DIALOGEOF'
#!/usr/bin/env bash
stty -echo -icanon min 1 time 0 2>/dev/null
printf 'Do you want to run reboot now?\n'
printf '\xe2\x9d\xaf 1. Yes\n'
printf '  2. No, and tell it what to do differently\n'
while IFS= read -r -n1 ch; do
  case "$ch" in
    ""|$'\r'|$'\n') printf 'ACCEPTED_OPTION:1\n' ;;
    *) : ;;
  esac
done
DIALOGEOF
chmod +x "$DIALOG_STUB"

test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id e1 --type developer --objective x --repo /tmp --window wm-e1 --session-id se1 --remote-control >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-e1 "bash '$DIALOG_STUB'"
sleep 1
out_e="$("$STANDDOWN" e1 2>&1)"; rc_e=$?
assert_eq "case E: standdown still exits 0 despite the dialog-shaped refusal" "$rc_e" "0"
assert_false "case E: the window is closed anyway" "tmux list-windows -t '=$WM_TMUX_SESSION' -F '#{window_name}' 2>/dev/null | grep -qx wm-e1"

# --- Case F (round-1 toggle-inversion fix): remote_control=true, ------------
# remote_control_connected=false - already known disconnected, must NOT send.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id f1 --type developer --objective x --repo /tmp --window wm-f1 --session-id sf1 --remote-control >/dev/null
wm_state crew-set --id f1 --remote-control-connected false >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-f1 "sleep 120"
pane_f1_before="$(tmux capture-pane -p -t "$WM_TMUX_SESSION:wm-f1")"
assert_false "case F setup: no stray /remote-control text pre-exists in the pane" \
  "printf '%s\n' \"$pane_f1_before\" | grep -q '/remote-control'"
"$STANDDOWN" f1 >/dev/null 2>&1
assert_false "case F: the window is closed" "tmux list-windows -t '=$WM_TMUX_SESSION' -F '#{window_name}' 2>/dev/null | grep -qx wm-f1"

# --- Case G (round-2 false-positive direction): the roster says connected, ---
# but the pane's own transcript happens to mention the banner strings as
# ordinary content, not a real disconnect - the send must still happen,
# because the decision is driven by the roster field, never a fresh pane read.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id g1 --type developer --objective x --repo /tmp --window wm-g1 --session-id sg1 --remote-control >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-g1 \
  'printf "grep: matched \"Remote Control disconnected\" in bin/watch-fleet\n"; sleep 120'
sleep 1
"$STANDDOWN" g1 >/dev/null 2>&1
assert_false "case G: the window is closed" "tmux list-windows -t '=$WM_TMUX_SESSION' -F '#{window_name}' 2>/dev/null | grep -qx wm-g1"

# --- Direct send-content assertions (A/C/G expect a send; B/F must not) -------
# Case A/B/C/D/E/F/G above prove standdown always finishes (window closed,
# exit 0) regardless of which branch it took, but a closed window has no
# scrollback left to inspect - proving the ABSENCE of a send that way is only
# as strong as "the window is gone", which is true either way. `tmux
# pipe-pane` logs everything the pane ever displayed (including any
# /remote-control keystrokes standdown types - the terminal echoes them
# whether or not the foreground process reads them, exactly like the reconnect
# side in tests/watch-fleet.test.sh) to a plain file that survives the window
# being killed, so this re-run of A/B/C/F/G confirms the literal content, not
# just the end state.
run_and_capture() {
  # run_and_capture <id> <mode> <banner-text-or-empty>
  # mode:
  #   true-true  - remote_control=true,  remote_control_connected=true
  #   false      - remote_control=false (crew-add's own default without
  #                --remote-control; remote_control_connected naturally stays
  #                None, distinct from the "legacy" case below)
  #   legacy     - both fields entirely absent (a genuine pre-fix record)
  #   true-false - remote_control=true,  remote_control_connected=false
  # Prints the path to the persisted pipe-pane log.
  _id="$1"; _mode="$2"; _banner="$3"
  test_new_home
  tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
  case "$_mode" in
    true-true|true-false)
      wm_state crew-add --id "$_id" --type developer --objective x --repo /tmp --window "wm-$_id" --session-id "s-$_id" --remote-control >/dev/null
      ;;
    *)
      wm_state crew-add --id "$_id" --type developer --objective x --repo /tmp --window "wm-$_id" --session-id "s-$_id" >/dev/null
      ;;
  esac
  case "$_mode" in
    true-false) wm_state crew-set --id "$_id" --remote-control-connected false >/dev/null ;;
    legacy) strip_remote_control_fields "$WINGMAN_HOME/crew.json" "$_id" ;;
  esac
  # trap '' INT: wm_tmux_send_message now sends a defensive Ctrl-C before typing
  # (issue #157) - harmless against a real Claude Code composer (its own
  # raw-mode input handling never lets the tty's SIGINT disposition fire), but
  # fatal to this bare `sleep` stand-in without the same immunity.
  if [ -n "$_banner" ]; then
    tmux new-window -d -t "$WM_TMUX_SESSION" -n "wm-$_id" "trap '' INT; printf '%s\n' '$_banner'; sleep 120"
  else
    tmux new-window -d -t "$WM_TMUX_SESSION" -n "wm-$_id" "trap '' INT; sleep 120"
  fi
  sleep 1
  _log="$(wm_mktemp_file)"
  tmux pipe-pane -o -t "$WM_TMUX_SESSION:wm-$_id" "cat >> '$_log'"
  "$STANDDOWN" "$_id" >/dev/null 2>&1
  tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null
  printf '%s' "$_log"
}

logA="$(run_and_capture ra1 true-true "")"
assert_contains "case A (direct): /remote-control is sent when true/true" "$(cat "$logA" 2>/dev/null)" "/remote-control"

logB="$(run_and_capture rb1 false "")"
assert_false "case B (direct): no send when remote_control=false" "grep -q '/remote-control' '$logB' 2>/dev/null"

logC="$(run_and_capture rc1x legacy "")"
assert_contains "case C (direct): a legacy record (both fields absent) is sent, matching A" "$(cat "$logC" 2>/dev/null)" "/remote-control"

logF="$(run_and_capture rf1 true-false "")"
assert_false "case F (direct): no send when remote_control_connected=false" "grep -q '/remote-control' '$logF' 2>/dev/null"

logG="$(run_and_capture rg1 true-true "grep: matched \"Remote Control disconnected\" in bin/watch-fleet")"
assert_contains "case G (direct): the send still happens despite banner-like transcript content" "$(cat "$logG" 2>/dev/null)" "/remote-control"

test_summary
