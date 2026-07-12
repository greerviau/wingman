#!/usr/bin/env bash
# Unit + E2E: merge-conflict drift detection layered onto watch-fleet's wake loop
# (see docs/plans/2026-07-12-watch-fleet-merge-conflict-drift-detection.md). The
# unit section drives wm_state's mergeability-* subcommands and needs-attention
# directly (no blocking loop, no gh). The E2E section drives the real blocking
# watch-fleet loop against a FAKE gh (via WM_GH), mirroring the pattern in
# tests/pr-watch.test.sh (fake gh) and tests/watch-fleet.test.sh (blocking loop).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WF="$TEST_REPO/bin/watch-fleet"
export WM_WATCH_INTERVAL=1
# Never let a blocking watcher wedge the suite: bound every foreground run and
# reap any backgrounded one on exit.
trap wm_kill_tracked EXIT

# A `gh pr view --json mergeStateStatus,mergeable,url,number` payload.
pr_json() { printf '{"mergeable":"%s","mergeStateStatus":"%s","url":"%s","number":5}' "$1" "$2" "$3"; }

# A fake `gh` for the E2E section: `gh pr view <url> --json ...` serves whatever
# is currently in $FAKE_MERGE_JSON, mirroring make_fake_gh in tests/pr-watch.test.sh.
make_fake_gh() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") cat "$FAKE_MERGE_JSON" ;;
  *)         echo "" ;;
esac
SH
  chmod +x "$1"
}

# mergeability.json[<id>][<field>], "" if missing/null.
mg_get() {
  uv run --no-project --quiet python - "$WINGMAN_HOME/mergeability.json" "$1" "$2" <<'EOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
v = d.get(sys.argv[2])
v = v.get(sys.argv[3]) if isinstance(v, dict) else None
print(v if v is not None else "")
EOF
}

# Exit 0 iff <key> is present in the JSON object at <file>.
has_key() {
  uv run --no-project --quiet python -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
sys.exit(0 if sys.argv[2] in d else 1)
' "$1" "$2"
}

assert_not_contains() {
  case "$2" in
    *"$3"*) fail "$1"; printf '         [%s] should not contain [%s]\n' "$2" "$3" ;;
    *)      ok "$1" ;;
  esac
}

# =============================================================================
# Unit: mergeability-set is edge-triggered, not level-triggered
# =============================================================================
test_new_home
wm_state crew-add --id x1 --type developer --objective a --repo /tmp --window wm-x1 --session-id sx1 >/dev/null
wm_state crew-set --id x1 --status review --delivery https://github.com/o/r/pull/1 >/dev/null

pr_json CONFLICTING DIRTY https://github.com/o/r/pull/1 | wm_state mergeability-set --id x1 --pr-json - >/dev/null
assert_eq "a CONFLICTING/DIRTY reading sets state=CONFLICTING" "$(mg_get x1 state)" "CONFLICTING"
cd1="$(mg_get x1 conflict_detected)"
if [ -n "$cd1" ]; then ok "conflict_detected is set on the CONFLICTING transition"; else fail "conflict_detected is set on the CONFLICTING transition"; fi

pr_json CONFLICTING DIRTY https://github.com/o/r/pull/1 | wm_state mergeability-set --id x1 --pr-json - >/dev/null
assert_eq "re-feeding the same CONFLICTING reading does not change conflict_detected" "$(mg_get x1 conflict_detected)" "$cd1"

pr_json MERGEABLE CLEAN https://github.com/o/r/pull/1 | wm_state mergeability-set --id x1 --pr-json - >/dev/null
assert_eq "a MERGEABLE reading clears conflict_detected to null" "$(mg_get x1 conflict_detected)" ""
assert_eq "a MERGEABLE reading sets state=MERGEABLE" "$(mg_get x1 state)" "MERGEABLE"

pr_json CONFLICTING DIRTY https://github.com/o/r/pull/1 | wm_state mergeability-set --id x1 --pr-json - >/dev/null
cd2="$(mg_get x1 conflict_detected)"
if [ -n "$cd2" ] && [ "$cd2" != "$cd1" ]; then ok "resolve-then-reconflict sets a NEW conflict_detected"; else fail "resolve-then-reconflict sets a NEW conflict_detected"; fi

pr_json UNKNOWN UNKNOWN https://github.com/o/r/pull/1 | wm_state mergeability-set --id x1 --pr-json - >/dev/null
assert_eq "an UNKNOWN reading after CONFLICTING leaves state untouched" "$(mg_get x1 state)" "CONFLICTING"
assert_eq "an UNKNOWN reading after CONFLICTING leaves conflict_detected untouched" "$(mg_get x1 conflict_detected)" "$cd2"
checked_after_unknown="$(mg_get x1 checked)"
if [ -n "$checked_after_unknown" ]; then ok "an UNKNOWN reading still bumps checked"; else fail "an UNKNOWN reading still bumps checked"; fi

# --fail bumps only checked
wm_state crew-add --id x2 --type developer --objective b --repo /tmp --window wm-x2 --session-id sx2 >/dev/null
wm_state crew-set --id x2 --status review --delivery https://github.com/o/r/pull/2 >/dev/null
pr_json MERGEABLE CLEAN https://github.com/o/r/pull/2 | wm_state mergeability-set --id x2 --pr-json - >/dev/null
checked_before="$(mg_get x2 checked)"
sleep 0.05
wm_state mergeability-set --id x2 --fail >/dev/null
assert_eq "--fail leaves state untouched" "$(mg_get x2 state)" "MERGEABLE"
assert_eq "--fail leaves conflict_detected untouched" "$(mg_get x2 conflict_detected)" ""
if [ "$(mg_get x2 checked)" != "$checked_before" ]; then ok "--fail bumps checked"; else fail "--fail bumps checked"; fi

# =============================================================================
# Unit: mergeability-poll-list scoping
# =============================================================================
test_new_home
wm_state crew-add --id p1 --type developer --objective a --repo /tmp --window wm-p1 --session-id sp1 >/dev/null
wm_state crew-set --id p1 --status blocked --delivery https://github.com/o/r/pull/1 >/dev/null

wm_state crew-add --id p2 --type developer --objective b --repo /tmp --window wm-p2 --session-id sp2 >/dev/null
wm_state crew-set --id p2 --status review --delivery "not-a-pr-url" >/dev/null

wm_state crew-add --id p3 --type developer --objective c --repo /tmp --window wm-p3 --session-id sp3 >/dev/null
wm_state crew-set --id p3 --status review --delivery https://github.com/o/r/pull/3 >/dev/null

wm_state crew-add --id p4 --type developer --objective d --repo /tmp --window wm-p4 --session-id sp4 >/dev/null
wm_state crew-set --id p4 --status working --delivery https://github.com/o/r/pull/4 >/dev/null
pr_json MERGEABLE CLEAN https://github.com/o/r/pull/4 | wm_state mergeability-set --id p4 --pr-json - >/dev/null

due1="$(wm_state mergeability-poll-list --owner "" --interval 3600)"
assert_not_contains "a blocked member is excluded from poll-list" "$due1" "p1"
assert_not_contains "a non-PR-URL delivery is excluded from poll-list" "$due1" "p2"
assert_contains "a never-checked review member is due" "$due1" "p3"
assert_not_contains "a recently-checked member within the interval is excluded" "$due1" "p4"

# a delivery change makes p4 due again immediately, ignoring the interval
wm_state crew-set --id p4 --delivery https://github.com/o/r/pull/44 >/dev/null
due2="$(wm_state mergeability-poll-list --owner "" --interval 3600)"
assert_contains "a changed delivery is due even within the interval" "$due2" "$(printf 'p4\thttps://github.com/o/r/pull/44')"

# =============================================================================
# Unit: needs-attention's synthetic "<id>#conflict" row
# =============================================================================
test_new_home
wm_state crew-add --id q1 --type developer --objective e --repo /tmp --window wm-q1 --session-id sq1 >/dev/null
wm_state crew-set --id q1 --status review --delivery https://github.com/o/r/pull/9 >/dev/null
pr_json CONFLICTING DIRTY https://github.com/o/r/pull/9 | wm_state mergeability-set --id q1 --pr-json - >/dev/null

na1="$(wm_state needs-attention --owner "")"
assert_contains "needs-attention emits the synthetic conflict row" "$na1" "q1#conflict"
assert_contains "the conflict row carries status=conflict" "$na1" "$(printf 'q1#conflict\tconflict\t')"
assert_contains "the member's own review event still surfaces independently" "$na1" "$(printf 'q1\treview\t')"

cdupd="$(printf '%s\n' "$na1" | grep 'q1#conflict' | cut -f3)"
wm_state ack --id "q1#conflict" --updated "$cdupd" >/dev/null
na2="$(wm_state needs-attention --owner "")"
assert_not_contains "an acked conflict event no longer surfaces" "$na2" "q1#conflict"
assert_contains "the member's own review event is a separate ack timeline (still unacked)" "$na2" "$(printf 'q1\treview\t')"

# a fresh (unacked) conflict on a `working` member stops once the member leaves
# review/working - re-checked at emission time, not polling time
wm_state crew-add --id q2 --type developer --objective f --repo /tmp --window wm-q2 --session-id sq2 >/dev/null
wm_state crew-set --id q2 --status working --delivery https://github.com/o/r/pull/10 >/dev/null
pr_json CONFLICTING DIRTY https://github.com/o/r/pull/10 | wm_state mergeability-set --id q2 --pr-json - >/dev/null
na3="$(wm_state needs-attention --owner "")"
assert_contains "the conflict row is present while the member is working" "$na3" "q2#conflict"

wm_state crew-set --id q2 --status done --summary "shipped" >/dev/null
na4="$(wm_state needs-attention --owner "")"
assert_not_contains "the conflict row stops once the member leaves review/working" "$na4" "q2#conflict"

# =============================================================================
# Unit: standdown/prune clean up mergeability state
# =============================================================================
test_new_home
wm_state crew-add --id s1 --type developer --objective g --repo /tmp --window wm-s1 --session-id ss1 >/dev/null
wm_state crew-set --id s1 --status review --delivery https://github.com/o/r/pull/11 >/dev/null
pr_json CONFLICTING DIRTY https://github.com/o/r/pull/11 | wm_state mergeability-set --id s1 --pr-json - >/dev/null
na5="$(wm_state needs-attention --owner "")"
cdupd5="$(printf '%s\n' "$na5" | grep 's1#conflict' | cut -f3)"
wm_state ack --id "s1#conflict" --updated "$cdupd5" >/dev/null

wm_state standdown --id s1 >/dev/null
assert_eq "standdown removes the member's mergeability entry" "$(mg_get s1 state)" ""
assert_false "standdown removes the acked #conflict key" "has_key '$WINGMAN_HOME/acked.json' 's1#conflict'"

# prune's own cleanup path: put a member in `stood-down` WITHOUT going through
# cmd_standdown (which already does its own cleanup), so mergeability.json still
# holds a live entry for prune itself to clean up.
wm_state crew-add --id r1 --type developer --objective h --repo /tmp --window wm-r1 --session-id sr1 >/dev/null
wm_state crew-set --id r1 --status review --delivery https://github.com/o/r/pull/12 >/dev/null
pr_json CONFLICTING DIRTY https://github.com/o/r/pull/12 | wm_state mergeability-set --id r1 --pr-json - >/dev/null
na6="$(wm_state needs-attention --owner "")"
cdupd6="$(printf '%s\n' "$na6" | grep 'r1#conflict' | cut -f3)"
wm_state ack --id "r1#conflict" --updated "$cdupd6" >/dev/null
wm_state crew-set --id r1 --status stood-down --summary "done" >/dev/null
wm_state prune >/dev/null
assert_eq "prune removes the member's mergeability entry" "$(mg_get r1 state)" ""
assert_false "prune removes the acked #conflict key" "has_key '$WINGMAN_HOME/acked.json' 'r1#conflict'"

# =============================================================================
# E2E: the real blocking watch-fleet loop against a fake gh
# =============================================================================
test_new_home
D="$(mktemp -d)"
GH="$D/gh"; make_fake_gh "$GH"
export WM_GH="$GH"
export FAKE_MERGE_JSON="$D/pr.json"
PRURL="https://github.com/o/r/pull/77"

# `working` (not an ATTENTION_STATE on its own), so only the merge-conflict signal
# can make the watcher fire - isolates this from the primary review/blocked/done path.
wm_state crew-add --id e1 --type developer --objective i --repo /tmp --window wm-e1 --session-id se1 >/dev/null
wm_state crew-set --id e1 --delivery "$PRURL" >/dev/null
pr_json MERGEABLE CLEAN "$PRURL" > "$FAKE_MERGE_JSON"

WM_MERGE_CHECK_INTERVAL=1 "$WF" >"$WINGMAN_HOME/e2e.log" 2>&1 &
epid=$!
wm_track "$epid"
sleep 4
assert_true "watcher keeps blocking while the PR is mergeable (no tmux session needed)" "kill -0 $epid"

# flip to CONFLICTING -> the blocking watcher fires within one cycle
pr_json CONFLICTING DIRTY "$PRURL" > "$FAKE_MERGE_JSON"
i=0; while kill -0 "$epid" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 1; i=$((i+1)); done
assert_false "watcher exits once the PR conflicts" "kill -0 $epid"
assert_contains "the fire carries a conflict: reason line naming the real id" "$(cat "$WINGMAN_HOME/e2e.log")" "conflict: e1#conflict"
wm_state render-board >/dev/null
assert_contains "board.md shows the CONFLICT marker" "$(cat "$WINGMAN_HOME/board.md")" "CONFLICTING"
assert_contains "crew-list shows the CONFLICT marker" "$(wm_state crew-list)" "CONFLICT"
kill "$epid" 2>/dev/null

# re-arm: the still-conflicting PR does not re-fire (ack suppression holds)
WM_MERGE_CHECK_INTERVAL=1 "$WF" >"$WINGMAN_HOME/e2e2.log" 2>&1 &
epid2=$!
wm_track "$epid2"
sleep 4
assert_true "re-arm keeps blocking on the already-fired conflict" "kill -0 $epid2"
kill "$epid2" 2>/dev/null
# Wait for epid2 to fully die (and release the PIDFILE) before arming a fresh
# cycle - otherwise the next arm can race the exiting process, see the stale
# PIDFILE, decide a cycle is still "healthy", and exit without ever polling.
i=0; while kill -0 "$epid2" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.5; i=$((i+1)); done

# resolve -> the marker clears, with no spurious fire on resolution. Wait for the
# polled state to actually flip (bounded poll, not a fixed sleep) rather than
# racing the watcher's own interval.
pr_json MERGEABLE CLEAN "$PRURL" > "$FAKE_MERGE_JSON"
WM_MERGE_CHECK_INTERVAL=1 "$WF" >"$WINGMAN_HOME/e2e3.log" 2>&1 &
epid3=$!
wm_track "$epid3"
i=0; while [ "$(mg_get e1 state)" != "MERGEABLE" ] && [ "$i" -lt 20 ]; do sleep 1; i=$((i+1)); done
assert_eq "the polled state resolves to MERGEABLE" "$(mg_get e1 state)" "MERGEABLE"
assert_true "watcher keeps blocking on resolution (no spurious fire)" "kill -0 $epid3"
wm_state render-board >/dev/null
assert_not_contains "board.md no longer shows CONFLICT after resolution" "$(cat "$WINGMAN_HOME/board.md")" "CONFLICTING"
assert_not_contains "crew-list no longer shows CONFLICT after resolution" "$(wm_state crew-list)" "CONFLICT"
kill "$epid3" 2>/dev/null

test_summary
