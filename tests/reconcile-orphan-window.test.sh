#!/usr/bin/env bash
# E2E: issue #79, Fix 3 - cmd_reconcile's grace-period-gated orphan-window
# adoption. A live wm-*-prefixed tmux window with no matching crew.json record
# (however it got that way - a crashed spawn-crew, a window created outside it
# entirely) is recovered as a blocked roster record rather than staying
# permanently invisible.
#
# The central case (review finding MF-1): a naive "unmatched window == orphan"
# check would race bin/spawn-crew's own normal sequence, since the tmux window is
# created strictly before crew-add persists the record - a real gap present in
# EVERY ordinary spawn, not just a crashed one. Proves the two-phase
# mark-then-adopt with a grace period never flags a healthy in-flight spawn, and
# only ever adopts a window that stays unmatched past --grace-seconds.
#
# reconcile takes the live window list as a plain --windows CSV (not a real tmux
# query), so - mirroring tests/dead-lead-orphans.test.sh's own convention - no
# tmux session is needed here: a window is "live" simply by being named in
# --windows, "gone" by being omitted.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

field_of() {
  wm_state crew-get --id "$1" 2>/dev/null | uv run --no-project --quiet python -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit
v = d.get(sys.argv[1])
print("" if v is None else v)
' "$2"
}

# Rewrite a window'"'"'s first_seen stamp INSIDE orphan-candidates.json (the JSON
# content cmd_reconcile actually parses) to N seconds in the past - not the
# file'"'"'s mtime (wm_age_path has no effect on the grace check at all, per the
# plan'"'"'s P-1 finding).
backdate_candidate() {
  uv run --no-project --quiet python - "$WINGMAN_HOME/orphan-candidates.json" "$1" "$2" <<'PYEOF'
import json, sys, datetime
path, win, secs = sys.argv[1], sys.argv[2], int(sys.argv[3])
d = json.load(open(path))
d[win] = (datetime.datetime.now(datetime.timezone.utc)
          - datetime.timedelta(seconds=secs)).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
json.dump(d, open(path, "w"))
PYEOF
}

# --- MF-1: a healthy in-flight spawn is never flagged, at any grace value -----
test_new_home
wm_state reconcile --windows "wm-orphan1" --owner "" --grace-seconds 15 >/dev/null
assert_false "orphan1 is not adopted the instant its window is first seen" \
  "wm_state crew-get --id orphan1 >/dev/null 2>&1"

# The record lands normally (crew-add), simulating a spawn that completes well
# inside the grace window - no time advances between the two reconcile calls.
wm_state crew-add --id orphan1 --type developer --objective o --repo /tmp \
  --window wm-orphan1 --session-id s1 >/dev/null
wm_state reconcile --windows "wm-orphan1" --owner "" --grace-seconds 15 >/dev/null
assert_eq "the healthy spawn keeps its own status (working), never blocked" \
  "$(field_of orphan1 status)" "working"
assert_eq "orphan_adopted is never set on a healthy spawn" \
  "$(field_of orphan1 orphan_adopted)" ""
assert_false "the resolved candidate is pruned from orphan-candidates.json" \
  "grep -q 'wm-orphan1' '$WINGMAN_HOME/orphan-candidates.json' 2>/dev/null"
# A later reconcile call (even one that would otherwise be past any grace
# period) still leaves it alone - it's a known window now, never a candidate.
wm_state reconcile --windows "wm-orphan1" --owner "" --grace-seconds 0 >/dev/null
assert_eq "a later reconcile still never adopts the healthy spawn" \
  "$(field_of orphan1 status)" "working"

# --- adoption after the grace period genuinely elapses (P-1) -------------------
test_new_home
wm_state reconcile --windows "wm-orphan2" --owner "" --grace-seconds 15 >/dev/null
assert_false "orphan2 is not adopted before the grace period elapses" \
  "wm_state crew-get --id orphan2 >/dev/null 2>&1"
backdate_candidate wm-orphan2 900
wm_state reconcile --windows "wm-orphan2" --owner "" --grace-seconds 15 >/dev/null
assert_eq "orphan2 is adopted as blocked once the grace period has genuinely elapsed" \
  "$(field_of orphan2 status)" "blocked"
assert_eq "the adopted record is tagged orphan_adopted" \
  "$(field_of orphan2 orphan_adopted)" "True"
assert_contains "the blocker names the recovery commands" \
  "$(field_of orphan2 blocker)" "bin/crew-takeover orphan2"
assert_contains "the blocker also offers stand-down for a stale window" \
  "$(field_of orphan2 blocker)" "bin/crew-standdown orphan2"
assert_true "the adopted record has a non-empty updated stamp (P-2)" \
  "[ -n \"$(field_of orphan2 updated)\" ]"
assert_false "no crew/<id>.json status file is created for an adopted orphan (SF-2)" \
  "[ -e '$WINGMAN_HOME/crew/orphan2.json' ]"

# --- idempotency: a second reconcile after adoption doesn't duplicate/re-flag -
before_updated="$(field_of orphan2 updated)"
wm_state reconcile --windows "wm-orphan2" --owner "" --grace-seconds 15 >/dev/null
assert_eq "a second reconcile after adoption does not re-flag the same record" \
  "$(field_of orphan2 updated)" "$before_updated"
count="$(wm_state crew-list --owner '' --json 2>/dev/null | grep -c '"id": "orphan2"')"
assert_eq "orphan2 appears exactly once in the roster (no duplicate)" "$count" "1"

# --- id derivation strips only the leading wm- prefix (P-3) -------------------
test_new_home
wm_state reconcile --windows "wm-round-2-review-reviewer" --owner "" --grace-seconds 15 >/dev/null
backdate_candidate wm-round-2-review-reviewer 900
wm_state reconcile --windows "wm-round-2-review-reviewer" --owner "" --grace-seconds 15 >/dev/null
assert_eq "a hyphenated crew id is recovered whole, not split on the first hyphen" \
  "$(field_of round-2-review-reviewer status)" "blocked"

# --- a non-wm--prefixed window is never adopted --------------------------------
test_new_home
wm_state reconcile --windows "not-wm-prefixed" --owner "" --grace-seconds 0 >/dev/null
assert_false "a non-wm--prefixed window is never adopted, even at grace-seconds 0" \
  "wm_state crew-get --id not-wm-prefixed >/dev/null 2>&1"
assert_false "a non-wm--prefixed window is never even tracked as a candidate" \
  "grep -q 'not-wm-prefixed' '$WINGMAN_HOME/orphan-candidates.json' 2>/dev/null"

# --- SF-1: gated to owner == "" -------------------------------------------------
test_new_home
# No --owner at all (bin/crew-list's own call shape): never touches the
# candidates file or adopts anything, even past a zero grace period.
wm_state reconcile --windows "wm-orphan4" --grace-seconds 0 >/dev/null
assert_false "omitting --owner never adopts, even at grace-seconds 0" \
  "wm_state crew-get --id orphan4 >/dev/null 2>&1"
assert_false "omitting --owner never creates orphan-candidates.json" \
  "[ -e '$WINGMAN_HOME/orphan-candidates.json' ]"
# A non-empty (lead) --owner: same non-adoption guarantee...
wm_state reconcile --windows "wm-orphan4" --owner "some-lead" --grace-seconds 0 >/dev/null
assert_false "a lead-scoped reconcile never adopts, even at grace-seconds 0" \
  "wm_state crew-get --id orphan4 >/dev/null 2>&1"
assert_false "a lead-scoped reconcile never creates orphan-candidates.json" \
  "[ -e '$WINGMAN_HOME/orphan-candidates.json' ]"
# ...but the death-flip pass in the very same call still runs normally - the
# gate is scoped to the orphan-adoption addition only, not the whole command.
wm_state crew-add --id livemember --type developer --objective o --repo /tmp \
  --window wm-livemember --session-id s2 >/dev/null
wm_state reconcile --windows "wm-orphan4" --owner "some-lead" >/dev/null
assert_eq "the death-flip pass still runs under a lead-scoped reconcile" \
  "$(field_of livemember status)" "died"

test_summary
