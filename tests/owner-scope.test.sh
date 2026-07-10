#!/usr/bin/env bash
# E2E: owner-scoped state - the hierarchy foundation. Proves each layer sees only
# its own direct reports: a worker's event surfaces to its lead but not to the top
# level; a lead re-raising surfaces to the top; crew-list scopes by owner; --tree
# renders the org; standing down a lead cascades to its whole sub-crew; and a
# per-owner watcher (wingman's and a lead's) coexist without contending. No real
# crew/tmux/claude needed - the state engine and watcher read the same files a real
# crew writes.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WF="$TEST_REPO/bin/watch-fleet"
export WM_WATCH_INTERVAL=1

# --- owner-scoped surfacing (escalation bubble-up) ---------------------------
test_new_home
wm_state crew-add --id lead1 --type lead  --objective big --repo /tmp --window wm-lead1 --session-id s1 >/dev/null
wm_state crew-add --id wkr1  --type build --objective a   --repo /tmp --window wm-wkr1  --session-id s2 --parent lead1 >/dev/null
wm_state crew-add --id top1  --type build --objective d   --repo /tmp --window wm-top1  --session-id s3 >/dev/null

# A worker blocks: it must surface to its lead's owner scope, not to the top level.
wm_state crew-set --id wkr1 --status blocked --blocker "which API?" >/dev/null
na_top="$(wm_state needs-attention --owner "")"
na_lead="$(wm_state needs-attention --owner lead1)"
case "$na_top" in *wkr1*) fail "a worker block does NOT surface to top level" ;; *) ok "a worker block does NOT surface to top level" ;; esac
assert_contains "a worker block surfaces to its lead's owner scope" "$na_lead" "wkr1"

# The lead re-raises (its own line): now the top level sees it.
wm_state crew-set --id lead1 --status blocked --blocker "escalated decision" >/dev/null
assert_contains "a lead's own block surfaces to top level" "$(wm_state needs-attention --owner "")" "lead1"

# --- crew-list owner scope ----------------------------------------------------
top_list="$(wm_state crew-list --owner "")"
assert_contains "top-scope list shows the lead"          "$top_list" "lead1"
assert_contains "top-scope list shows a direct worker"   "$top_list" "top1"
case "$top_list" in *wkr1*) fail "top-scope list hides the lead's worker" ;; *) ok "top-scope list hides the lead's worker" ;; esac

lead_list="$(wm_state crew-list --owner lead1)"
assert_contains "lead-scope list shows its worker" "$lead_list" "wkr1"
case "$lead_list" in *top1*) fail "lead-scope list hides a top-level member" ;; *) ok "lead-scope list hides a top-level member" ;; esac

# --- tree render --------------------------------------------------------------
tree="$(wm_state crew-list --tree)"
assert_contains "tree shows the lead" "$tree" "lead1"
assert_contains "tree indents the worker under its lead" "$tree" "  [build] wkr1"

# --- cascade standdown --------------------------------------------------------
wm_state standdown --id lead1 >/dev/null
assert_contains "standing down a lead cascades to its worker" "$(wm_state crew-get --id wkr1)" '"status": "stood-down"'
assert_contains "the lead itself is stood down"               "$(wm_state crew-get --id lead1)" '"status": "stood-down"'
assert_contains "a top-level sibling is untouched by the cascade" "$(wm_state crew-get --id top1)" '"status": "working"'

# --- per-owner watchers coexist ----------------------------------------------
test_new_home
wm_state crew-add --id lead1 --type lead  --objective big --repo /tmp --window wm-lead1 --session-id s1 >/dev/null
wm_state crew-add --id wkr1  --type build --objective a   --repo /tmp --window wm-wkr1  --session-id s2 --parent lead1 >/dev/null
wm_state crew-set --id lead1 --status working --summary "managing" >/dev/null
wm_state crew-set --id wkr1  --status working --summary "coding" >/dev/null

# Arm wingman's watcher (top) and the lead's watcher; both must block, not contend.
"$WF" --owner ""     >"$WINGMAN_HOME/top.log"  2>&1 &
tpid=$!
"$WF" --owner lead1  >"$WINGMAN_HOME/lead.log" 2>&1 &
lpid=$!
sleep 2
assert_true "top watcher is blocking"  "kill -0 $tpid"
assert_true "lead watcher is blocking" "kill -0 $lpid"
assert_true "top watcher uses the legacy pidfile"        "test -f '$WINGMAN_HOME/watch.pid'"
assert_true "lead watcher uses an owner-keyed pidfile"   "test -f '$WINGMAN_HOME/watch-lead1.pid'"

# A worker event fires ONLY the lead's watcher; the top keeps blocking.
wm_state crew-set --id wkr1 --status blocked --blocker "need input" >/dev/null
sleep 3
assert_false "lead watcher fired on its worker"                "kill -0 $lpid"
assert_true  "top watcher keeps blocking (worker not its concern)" "kill -0 $tpid"
assert_contains "lead wake file names the worker" "$(cat "$WINGMAN_HOME/wake-lead1")" "wkr1"

# A top-level event fires the top watcher.
wm_state crew-set --id lead1 --status done --summary "wrapped up" >/dev/null
sleep 3
assert_false "top watcher fired on its own layer" "kill -0 $tpid"
kill "$tpid" "$lpid" 2>/dev/null

test_summary
