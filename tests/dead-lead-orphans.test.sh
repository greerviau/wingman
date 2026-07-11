#!/usr/bin/env bash
# E2E: dead-lead orphan re-adopt + robust teardown (Fix B / #11). Proves that when a
# lead dies with a still-live worker, wingman's reconcile re-parents the worker to
# wingman (so it stays watched), records orphaned_from, and enriches the lead's
# `died` event with the worker + dispositions; that the orphan mutation is scoped to
# wingman's watcher (owner "") and never runs from a lead's cycle (N4); that the
# re-adopt fires once (idempotent); and that crew-standdown on the dead lead still
# cascades to the re-adopted worker via orphaned_from, closing its window AND
# removing its worktree (N5 - the same test guards teardown, since a regressed
# cascade would leak the worktree, the original #11 symptom).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

STANDDOWN="$TEST_REPO/bin/crew-standdown"

field_of() { wm_state crew-get --id "$1" | uv run --no-project --quiet python -c 'import sys,json
print(json.load(sys.stdin).get(sys.argv[1]) or "")' "$2"; }

# --- dead-owner detection, scoping (N4), enrichment, and idempotency ----------
# No tmux needed: reconcile takes the live windows as a CSV, so we flip the lead by
# omitting its window while keeping the worker's.
test_new_home
wm_state crew-add --id lead1 --type lead --objective L --repo /tmp --window wm-lead1 --session-id sl1 >/dev/null
wm_state crew-add --id wkr1 --type developer --objective W --repo /tmp --window wm-wkr1 --session-id sw1 --parent lead1 >/dev/null
wm_state crew-set --id wkr1 --status review --delivery "PR#7" >/dev/null

# A NON-wingman reconcile (--owner <lead>) still does the global death-flip, but must
# NOT run the orphan re-parent (N4).
wm_state reconcile --windows "wm-wkr1" --owner "some-lead" >/dev/null
assert_eq   "death-flip is global regardless of owner scope" "$(field_of lead1 status)" "died"
assert_eq   "a non-wingman reconcile does NOT re-parent the orphan" "$(field_of wkr1 parent)" "lead1"
assert_eq   "a non-wingman reconcile sets no orphaned_from" "$(field_of wkr1 orphaned_from)" ""

# Wingman's reconcile (--owner "") re-adopts the orphan - even though the death
# happened on the prior cycle.
wm_state reconcile --windows "wm-wkr1" --owner "" >/dev/null
assert_eq       "wingman reconcile re-parents the orphan to wingman" "$(field_of wkr1 parent)" ""
assert_eq       "the orphan records orphaned_from = the dead lead" "$(field_of wkr1 orphaned_from)" "lead1"
assert_contains "the died event enumerates the re-adopted worker" "$(field_of lead1 summary)" "wkr1"
assert_contains "the died event offers cascade-standdown" "$(field_of lead1 summary)" "crew-standdown lead1"
assert_contains "the died event offers takeover" "$(field_of lead1 summary)" "crew-takeover"

# The orphan is now a wingman direct report: visible to owner-"" list, and its review
# now fires to wingman via the normal needs-attention path.
assert_contains "the orphan is now a top-level report" "$(wm_state crew-list --owner '' --json)" "wkr1"
assert_contains "the re-adopted worker's review fires to wingman" "$(wm_state needs-attention --owner '')" "wkr1"

# Idempotent: a second wingman reconcile does not re-fire (the worker is no longer
# this lead's orphan), so the lead's died event is unchanged.
before="$(field_of lead1 updated)"
wm_state reconcile --windows "wm-wkr1" --owner "" >/dev/null
assert_eq "the re-adopt fires exactly once (idempotent)" "$(field_of lead1 updated)" "$before"

# --- cascade after re-adopt + worktree teardown (N5) --------------------------
# A real repo + worktree + tmux window so we can assert the window closes AND the
# worktree is force-removed when the dead lead is stood down.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
REPO_B="$(mktemp -d)/repoB"
mkdir -p "$REPO_B"
git -C "$REPO_B" init -q
git -C "$REPO_B" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
WT_B="$(dirname "$REPO_B")/repoB-wkr2"
git -C "$REPO_B" worktree add -q "$WT_B" -b feat/x
assert_true "the worker's worktree exists before standdown" "[ -d '$WT_B' ]"

wm_state crew-add --id lead2 --type lead --objective L2 --repo "$REPO_B" --window wm-lead2 --session-id sl2 >/dev/null
wm_state crew-add --id wkr2 --type developer --objective W2 --repo "$REPO_B" --window wm-wkr2 --session-id sw2 --parent lead2 --worktree "$WT_B" >/dev/null
wm_state crew-set --id wkr2 --status review --delivery "PR#8" >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-wkr2 'sleep 600'

# lead2 dies, wkr2 stays live → wingman reconcile re-adopts wkr2.
wm_state reconcile --windows "wm-wkr2" --owner "" >/dev/null
assert_eq "wkr2 re-parented, orphaned_from lead2" "$(field_of wkr2 orphaned_from)" "lead2"

# Standing down the dead lead must still reach the re-adopted worker (via
# orphaned_from), close its window, and remove its worktree.
out="$(bash "$STANDDOWN" lead2 2>&1)"
assert_eq   "wkr2 is stood down via the orphaned_from cascade" "$(field_of wkr2 status)" "stood-down"
assert_false "wkr2's window was closed" "tmux list-windows -t '$WM_TMUX_SESSION' -F '#{window_name}' 2>/dev/null | grep -qx wm-wkr2"
assert_false "wkr2's worktree was force-removed (no leak - the #11 symptom)" "[ -d '$WT_B' ]"
assert_contains "standdown reports the removed worktree" "$out" "worktree(s) removed"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- teardown fallback: a gracefully-removed worktree is a harmless no-op ------
# A member that removed its own worktree first (the graceful path) leaves nothing;
# crew-standdown must not error, and an unset/empty worktree must be skipped safely.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
REPO_C="$(mktemp -d)/repoC"
mkdir -p "$REPO_C"
git -C "$REPO_C" init -q
git -C "$REPO_C" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
WT_C="$(dirname "$REPO_C")/repoC-wkr3"
git -C "$REPO_C" worktree add -q "$WT_C" -b feat/y
wm_state crew-add --id wkr3 --type developer --objective W3 --repo "$REPO_C" --window wm-wkr3 --session-id sw3 --worktree "$WT_C" >/dev/null
# The member removed its own worktree gracefully before standdown.
git -C "$REPO_C" worktree remove --force "$WT_C"
assert_false "the graceful worktree is already gone" "[ -d '$WT_C' ]"
out3="$(bash "$STANDDOWN" wkr3 2>&1)"
assert_eq "wkr3 is stood down" "$(field_of wkr3 status)" "stood-down"
assert_contains "standdown succeeds with a no-op teardown" "$out3" "stood down wkr3"
# An analyst with no recorded worktree tears down cleanly too (empty path skipped).
wm_state crew-add --id an1 --type analyst --objective A --repo /tmp --window wm-an1 --session-id sa1 >/dev/null
out4="$(bash "$STANDDOWN" an1 2>&1)"
assert_contains "a member with no worktree stands down cleanly" "$out4" "stood down an1"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

test_summary
