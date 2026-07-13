#!/usr/bin/env bash
# E2E: exact-match tmux session/window targeting (issue #39). tmux resolves a
# bare `-t <name>` by prefix (then fnmatch) when no exact name exists, so with
# a prefix-sibling session present ("wingman-main", a user's "wingman-server")
# and no real crew session, every crew command silently operates on the wrong
# session - crew windows get injected into wingman's own orchestrator session,
# and restarting that session kills the whole fleet. Proves: spawn lands in an
# exact-named crew session even when only a prefix sibling exists; the crew
# session is created by spawn-crew itself (not dependent on any external
# starter); the fleet SURVIVES the sibling (orchestrator) session dying; and
# window targeting never prefix-matches a neighbouring window. Uses a stub
# agent (WM_AGENT) and throwaway session names so the live fleet is untouched.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SPAWN="$TEST_REPO/bin/spawn-crew"
STANDDOWN="$TEST_REPO/bin/crew-standdown"

WS="$(wm_mktemp_dir)/workspace"
mkdir -p "$WS/repoA"
git -C "$WS/repoA" init -q
printf '#!/usr/bin/env bash\nexec sleep 120\n' > "$WS/stub.sh"; chmod +x "$WS/stub.sh"

CFG="$TEST_REPO/config.local.sh"
if [ -e "$CFG" ]; then echo "SKIP: $CFG exists; not overwriting"; exit 0; fi
printf 'WM_ROOTS=%q\n' "$WS" > "$CFG"

export WM_AGENT="$WS/stub.sh" WM_SPAWN_DELAY=0 WM_SUBMIT_DELAY=0
test_new_home
wm_on_exit "rm -f '$CFG'"

# The decoy: a session whose name has the crew session's name as a PREFIX,
# standing in for wingman-main / a user's own session. The real crew session
# does not exist yet - exactly the live failure shape.
DECOY="$WM_TMUX_SESSION-main"
wm_track_tmux "$DECOY"

tmux new-session -d -s "$DECOY" -n orchestrator "sleep 120"

# --- has-session semantics: the trap this suite guards against ---------------
# (If tmux ever stops prefix-matching bare names, the =-prefix is still the
# correct spec; this assert documents why it is load-bearing today.)
assert_true "bare has-session prefix-matches the decoy (tmux behavior)" \
  "tmux has-session -t '$WM_TMUX_SESSION' 2>/dev/null"
assert_false "exact has-session does not match the decoy" \
  "tmux has-session -t '=$WM_TMUX_SESSION' 2>/dev/null"

# --- spawn with only the decoy present ----------------------------------------
id="$("$SPAWN" --type software-analyst --repo repoA --objective "targeting test" 2>/dev/null | tail -1)"
assert_true "spawn succeeds with only a prefix-sibling session present" "[ -n '$id' ]"

assert_true "spawn created the exact-named crew session" \
  "tmux list-sessions -F '#{session_name}' | grep -qx '$WM_TMUX_SESSION'"
crew_windows="$(tmux list-windows -t "=$WM_TMUX_SESSION" -F '#{window_name}' 2>/dev/null)"
decoy_windows="$(tmux list-windows -t "=$DECOY" -F '#{window_name}' 2>/dev/null)"
assert_contains "crew window landed in the crew session" "$crew_windows" "wm-$id"
assert_not_contains "crew window was NOT injected into the prefix sibling" "$decoy_windows" "wm-$id"

# --- fleet survives the orchestrator session dying -----------------------------
tmux kill-session -t "=$DECOY" 2>/dev/null
assert_true "crew session survives the sibling (orchestrator) session dying" \
  "tmux has-session -t '=$WM_TMUX_SESSION' 2>/dev/null"
assert_contains "crew window survives the sibling session dying" \
  "$(tmux list-windows -t "=$WM_TMUX_SESSION" -F '#{window_name}' 2>/dev/null)" "wm-$id"

# --- window targeting: no prefix fallback across window names ------------------
# A window target for an absent window must fail, not bind to a neighbour whose
# name extends it (wm-<id> extends wm-<shorter-id>).
assert_false "window target for an absent window does not prefix-match a neighbour" \
  "tmux list-panes -t \"=$WM_TMUX_SESSION:=wm-${id%?}\" 2>/dev/null"

# --- crew-standdown kills only the exact window, in the exact session ----------
"$STANDDOWN" "$id" >/dev/null 2>&1
assert_false "standdown removed the crew window" \
  "tmux list-windows -t '=$WM_TMUX_SESSION' -F '#{window_name}' 2>/dev/null | grep -qx 'wm-$id'"

# --- stray adoption: a pre-fix member in the wrong session is moved home -------
# Simulate the transitional state the prefix-matching era leaves behind: a
# roster record whose window lives in the sibling session and that has no
# window_id (a pre-fix spawn). Reconcile callers must adopt it - move the
# window into the crew session, process intact - never flag the live member
# died (which would get it reaped while its agent process keeps running).
tmux new-session -d -s "$DECOY" -n orchestrator "sleep 120"
sid="stray-member"
swin="wm-$sid"
tmux new-window -d -t "=$DECOY:" -n "$swin" "sleep 120"
wm_state crew-add --id "$sid" --type developer --objective "stray" \
  --repo "$WS/repoA" --window "$swin" --session-id fake >/dev/null
"$TEST_REPO/bin/crew-list" >/dev/null 2>&1
assert_contains "stray window is adopted into the crew session" \
  "$(tmux list-windows -t "=$WM_TMUX_SESSION" -F '#{window_name}' 2>/dev/null)" "$swin"
assert_false "stray window is no longer in the sibling session" \
  "tmux list-windows -t '=$DECOY' -F '#{window_name}' 2>/dev/null | grep -qx '$swin'"
sstatus="$(wm_state crew-get --id "$sid" | uv run --no-project --quiet python -c 'import sys,json;print(json.load(sys.stdin).get("status"))')"
assert_eq "adopted member is not flagged died" "$sstatus" "working"

# --- window-id identity: recorded at spawn, used for exact adoption ------------
id3="$("$SPAWN" --type software-analyst --repo repoA --objective "id adoption" 2>/dev/null | tail -1)"
wid="$(wm_state crew-get --id "$id3" | uv run --no-project --quiet python -c 'import sys,json;print(json.load(sys.stdin).get("window_id",""))')"
assert_contains "spawn records the tmux window id" "$wid" "@"
tmux move-window -d -s "=$WM_TMUX_SESSION:=wm-$id3" -t "=$DECOY:"
"$TEST_REPO/bin/crew-list" >/dev/null 2>&1
assert_true "a strayed post-fix member is adopted back by window id" \
  "tmux list-windows -t '=$WM_TMUX_SESSION' -F '#{window_name}' 2>/dev/null | grep -qx 'wm-$id3'"
istatus="$(wm_state crew-get --id "$id3" | uv run --no-project --quiet python -c 'import sys,json;print(json.load(sys.stdin).get("status"))')"
assert_eq "id-adopted member is not flagged died" "$istatus" "working"

test_summary
