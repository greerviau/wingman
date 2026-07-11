#!/usr/bin/env bash
# E2E: the crew-ask team guardrail. Identical policy to crew-say (both call the
# shared wm_team_guardrail helper): a caller may ask its own reports, a sibling
# under the same lead, or its own lead - and is refused any other target. An
# allowed target passes the guardrail and only then hits the "no live window"
# check (there is no real tmux here), which is how we prove it was allowed; a
# refused target dies with the guardrail message before ever reaching the window
# check. --force (and WM_TEAM_FORCE) bypass the guardrail.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ASK="$TEST_REPO/bin/crew-ask"

test_new_home
# Two teams: lead1 over wkr1a/wkr1b, lead2 over wkr2a. All top-level leads.
wm_state crew-add --id lead1 --type lead      --objective big --repo /tmp --window wm-lead1 --session-id s1 >/dev/null
wm_state crew-add --id lead2 --type lead      --objective big --repo /tmp --window wm-lead2 --session-id s2 >/dev/null
wm_state crew-add --id wkr1a --type developer --objective a   --repo /tmp --window wm-wkr1a --session-id s3 --parent lead1 >/dev/null
wm_state crew-add --id wkr1b --type reviewer  --objective b   --repo /tmp --window wm-wkr1b --session-id s4 --parent lead1 >/dev/null
wm_state crew-add --id wkr2a --type developer --objective c   --repo /tmp --window wm-wkr2a --session-id s5 --parent lead2 >/dev/null

# A worker -> its sibling under the same lead: ALLOWED (passes guardrail, then no window).
out="$(WINGMAN_CREW_ID=wkr1a "$ASK" wkr1b "did you touch the API?" 2>&1)"
assert_contains "worker asks a sibling under the same lead" "$out" "no live window"

# A worker -> its own lead: ALLOWED.
out="$(WINGMAN_CREW_ID=wkr1a "$ASK" lead1 "which contract should I follow?" 2>&1)"
assert_contains "worker asks its own lead" "$out" "no live window"

# A worker -> a worker under a DIFFERENT lead: REFUSED by the guardrail.
out="$(WINGMAN_CREW_ID=wkr1a "$ASK" wkr2a "cross-team" 2>&1)"
assert_contains "worker is refused a non-sibling target" "$out" "team guardrail"

# A worker -> a different lead: REFUSED.
out="$(WINGMAN_CREW_ID=wkr1a "$ASK" lead2 "not my lead" 2>&1)"
assert_contains "worker is refused another lead" "$out" "team guardrail"

# Wingman (no crew id) -> a top-level direct report (a lead): ALLOWED.
out="$("$ASK" lead1 "status?" 2>&1)"
assert_contains "wingman asks a top-level direct report" "$out" "no live window"

# Wingman -> a lead's worker (two layers down): REFUSED (wingman talks to the lead).
out="$("$ASK" wkr1a "go around the lead" 2>&1)"
assert_contains "wingman is refused a member two layers down" "$out" "team guardrail"

# A lead -> its own worker: ALLOWED.
out="$(WINGMAN_CREW_ID=lead1 "$ASK" wkr1a "did the signature change?" 2>&1)"
assert_contains "a lead asks its own worker" "$out" "no live window"

# --force bypasses the guardrail on an otherwise-refused target.
out="$(WINGMAN_CREW_ID=wkr1a "$ASK" --force wkr2a "override" 2>&1)"
assert_contains "--force bypasses the guardrail" "$out" "no live window"
case "$out" in *"team guardrail"*) fail "--force still hit the guardrail" ;; *) ok "--force skips the guardrail" ;; esac

# WM_TEAM_FORCE (the shared env override) also bypasses the guardrail.
out="$(WINGMAN_CREW_ID=wkr1a WM_TEAM_FORCE=1 "$ASK" wkr2a "env override" 2>&1)"
assert_contains "WM_TEAM_FORCE bypasses the guardrail" "$out" "no live window"

test_summary
