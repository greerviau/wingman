#!/usr/bin/env bash
# E2E: the crew-say team guardrail. A caller may message its own reports, a sibling
# under the same lead, or its own lead - and is refused any other target so
# collaboration stays within a team. An allowed target passes the guardrail and
# only then hits the "no live window" check (there is no real tmux here), which is
# how we prove it was allowed; a refused target dies with the guardrail message
# before ever reaching the window check. --force bypasses the guardrail.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SAY="$TEST_REPO/bin/crew-say"

test_new_home
# Two teams: lead1 over wkr1a/wkr1b, lead2 over wkr2a. All top-level leads.
wm_state crew-add --id lead1 --type lead      --objective big --repo /tmp --window wm-lead1 --session-id s1 >/dev/null
wm_state crew-add --id lead2 --type lead      --objective big --repo /tmp --window wm-lead2 --session-id s2 >/dev/null
wm_state crew-add --id wkr1a --type developer --objective a   --repo /tmp --window wm-wkr1a --session-id s3 --parent lead1 >/dev/null
wm_state crew-add --id wkr1b --type reviewer  --objective b   --repo /tmp --window wm-wkr1b --session-id s4 --parent lead1 >/dev/null
wm_state crew-add --id wkr2a --type developer --objective c   --repo /tmp --window wm-wkr2a --session-id s5 --parent lead2 >/dev/null

# A worker -> its sibling under the same lead: ALLOWED (passes guardrail, then no window).
out="$(WINGMAN_CREW_ID=wkr1a "$SAY" wkr1b "hi peer" 2>&1)"
assert_contains "worker reaches a sibling under the same lead" "$out" "no live window"

# A worker -> its own lead: ALLOWED.
out="$(WINGMAN_CREW_ID=wkr1a "$SAY" lead1 "escalating" 2>&1)"
assert_contains "worker reaches its own lead" "$out" "no live window"

# A worker -> a worker under a DIFFERENT lead: REFUSED by the guardrail.
out="$(WINGMAN_CREW_ID=wkr1a "$SAY" wkr2a "cross-team" 2>&1)"
assert_contains "worker is refused a non-sibling target" "$out" "team guardrail"

# A worker -> a different lead: REFUSED.
out="$(WINGMAN_CREW_ID=wkr1a "$SAY" lead2 "not my lead" 2>&1)"
assert_contains "worker is refused another lead" "$out" "team guardrail"

# Wingman (no crew id) -> a top-level direct report (a lead): ALLOWED.
out="$("$SAY" lead1 "status?" 2>&1)"
assert_contains "wingman reaches a top-level direct report" "$out" "no live window"

# Wingman -> a lead's worker (two layers down): REFUSED (wingman talks to the lead).
out="$("$SAY" wkr1a "go around the lead" 2>&1)"
assert_contains "wingman is refused a member two layers down" "$out" "team guardrail"

# A lead -> its own worker: ALLOWED.
out="$(WINGMAN_CREW_ID=lead1 "$SAY" wkr1a "here is your task" 2>&1)"
assert_contains "a lead reaches its own worker" "$out" "no live window"

# --force bypasses the guardrail on an otherwise-refused target.
out="$(WINGMAN_CREW_ID=wkr1a "$SAY" --force wkr2a "override" 2>&1)"
assert_contains "--force bypasses the guardrail" "$out" "no live window"
case "$out" in *"team guardrail"*) fail "--force still hit the guardrail" ;; *) ok "--force skips the guardrail" ;; esac

test_summary
