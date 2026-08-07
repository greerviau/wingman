#!/usr/bin/env bash
# E2E: pr-eval's checks-passed/merge-ready decision. Drives bin/lib/pr-eval.py
# directly with canned PR JSON and a persistent cursor, proving checks-passed
# fires once when the PR settles (green or no-CI), stays quiet while nothing
# changes, re-arms after the rollup goes pending/failing and settles anew, and
# yields to a fresh comment - and that merge-ready fires instead of
# checks-passed at that same slot whenever --crew-record reports
# allow_merge:true, including the case a grant lands on an already-settled PR
# with no PR-side change at all.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

EVAL="$TEST_REPO/bin/lib/pr-eval.py"
D="$(wm_mktemp_dir)"
PRJ="$D/pr.json"; CUR="$D/cur.json"
ev() { uv run --no-project --quiet "$EVAL" --pr-json "$PRJ" --cursor "$CUR" --me me --my-crew-id dev-1 2>/dev/null; }

# All fixtures below carry an explicit mergeable=MERGEABLE/mergeStateStatus=CLEAN
# pair, matching what a real `gh pr view --json ...,mergeable,mergeStateStatus`
# call always returns (never an absent field), so these CI-focused cases exercise
# checks-passed without also exercising the mergeability gate (covered in its own
# section below).

# --- no CI at all: settles immediately, fires once ---------------------------
echo '{"number":1,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_contains "a no-CI PR fires checks-passed on first poll" "$(ev)" "checks-passed: #1"
assert_eq "a settled no-CI PR does not re-fire" "$(ev)" ""

# --- pending -> green fires once, then quiet ---------------------------------
rm -f "$CUR"
echo '{"number":2,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_eq "a pending rollup is not an event" "$(ev)" ""
echo '{"number":2,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_contains "the rollup going green fires checks-passed" "$(ev)" "checks-passed: #2"
assert_eq "a green rollup does not re-fire" "$(ev)" ""

# --- failing then green re-arms checks-passed --------------------------------
rm -f "$CUR"
echo '{"number":3,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_contains "a failing rollup fires ci-failed" "$(ev)" "ci-failed: #3"
echo '{"number":3,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_contains "recovering to green re-arms checks-passed" "$(ev)" "checks-passed: #3"

# --- a fresh comment beats checks-passed ------------------------------------
rm -f "$CUR"
echo '{"number":4,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
ev >/dev/null  # seed: pending, nothing fires, conv_hwm empty
echo '{"number":4,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"reviews":[],"comments":[{"createdAt":"2026-07-10T12:00:00Z","author":{"login":"rev"}}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_contains "a fresh comment wins over checks-passed" "$(ev)" "comment: #4"
assert_contains "checks-passed then fires once the comment is handled" "$(ev)" "checks-passed: #4"

# --- mergeability: CONFLICTING fires once, re-feeding does not re-fire -------
rm -f "$CUR"
echo '{"number":5,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}' > "$PRJ"
assert_contains "a CONFLICTING/DIRTY reading fires conflict" "$(ev)" "conflict: #5"
assert_eq "the same CONFLICTING reading does not re-fire" "$(ev)" ""

# --- resolving clears the cursor silently; re-conflicting fires a NEW event --
echo '{"number":5,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_contains "a MERGEABLE reading clears the conflict cursor via checks-passed, not a conflict event" "$(ev)" "checks-passed: #5"
echo '{"number":5,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}' > "$PRJ"
assert_contains "resolve-then-reconflict fires a NEW conflict event" "$(ev)" "conflict: #5"
# A follow-up poll of the same still-conflicting state falls through to the ready
# gate (mirrors the `ci` cursor: the transition itself returns early, a later
# unchanged-bad poll is what resets ready_fired) - same fixture, no event.
assert_eq "a follow-up poll of the same still-conflicting state stays quiet" "$(ev)" ""

# --- UNKNOWN neither fires nor clears an existing conflict, nor satisfies ready
echo '{"number":5,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN"}' > "$PRJ"
assert_eq "an UNKNOWN reading after CONFLICTING neither fires nor clears" "$(ev)" ""
assert_eq "a second UNKNOWN poll still does not fire checks-passed" "$(ev)" ""
echo '{"number":5,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_contains "resolving after the UNKNOWN gap still fires checks-passed once" "$(ev)" "checks-passed: #5"
assert_eq "checks-passed does not re-fire once settled" "$(ev)" ""

# --- checks-passed withholds while conflicting, even with all checks green ---
rm -f "$CUR"
echo '{"number":6,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"reviews":[],"comments":[],"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}' > "$PRJ"
assert_contains "a conflicting PR fires conflict, not checks-passed, even with green checks" "$(ev)" "conflict: #6"
case "$(ev)" in *checks-passed*) fail "checks-passed must not fire while still conflicting" ;; *) ok "checks-passed withheld while still conflicting" ;; esac
echo '{"number":6,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_contains "checks-passed fires once mergeability resolves with checks still green" "$(ev)" "checks-passed: #6"

# --- priority: a co-occurring ci-failed and conflict fires ci-failed first, ---
# --- conflict still surfaces on the next poll ---------------------------------
rm -f "$CUR"
echo '{"number":7,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE"}],"reviews":[],"comments":[],"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}' > "$PRJ"
assert_contains "ci-failed takes priority over a co-occurring conflict" "$(ev)" "ci-failed: #7"
assert_contains "the co-occurring conflict still surfaces on the next poll" "$(ev)" "conflict: #7"

# --- self-filter: login alone is never sufficient (issues #118, #59) --------
# ev() defaults to --my-crew-id dev-1; only a marker naming THAT crew id,
# anchored at the body's start, should ever be treated as this session's own
# reply and dropped. Every other same-login shape must surface as a real event.

rm -f "$CUR"
echo '{"number":8,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
ev >/dev/null  # seed: baseline, nothing fires yet
echo '{"number":8,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[{"createdAt":"2026-07-15T12:00:00Z","author":{"login":"me"},"body":"please rename this variable"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_contains "a same-login comment with no marker at all surfaces (issue #118)" "$(ev)" "comment: #8"

rm -f "$CUR"
echo '{"number":9,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
ev >/dev/null  # seed: baseline, nothing fires yet
echo '{"number":9,"state":"OPEN","statusCheckRollup":[],"reviews":[{"state":"CHANGES_REQUESTED","submittedAt":"2026-07-15T12:00:00Z","author":{"login":"me"},"body":"<!-- wingman-crew:reviewer-1 --> needs work"}],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_contains "a same-login review marked by a DIFFERENT crew id surfaces (issue #59)" "$(ev)" "changes-requested: #9"

rm -f "$CUR"
echo '{"number":10,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
ev >/dev/null  # seed: baseline, nothing fires yet
echo '{"number":10,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[{"createdAt":"2026-07-15T12:00:00Z","author":{"login":"me"},"body":"<!-- wingman-crew:dev-1 --> fixed, PTAL"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_eq "a same-login comment marked with THIS session's own crew id, anchored at body start, stays filtered (reply-loop guard)" "$(ev)" ""

rm -f "$CUR"
echo '{"number":11,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
ev >/dev/null  # seed: baseline, nothing fires yet
echo '{"number":11,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[{"createdAt":"2026-07-15T12:00:00Z","author":{"login":"me"},"body":"> <!-- wingman-crew:dev-1 --> fixed, PTAL\n\nActually, one more thing before this merges."}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_contains "a same-login comment whose own marker is only quoted (not at body start) surfaces (round-1 must-fix, quote-reply)" "$(ev)" "comment: #11"

# --- the merge-attribution comment marker (issue #50's consistency fix) follows
# --- the exact same self-filter rule as every other marked comment ----------
# hooks/merge-attribution-tracker.sh's COMMENT_BODY now opens with the same
# <!-- wingman-crew:<id> --> marker as any other crew-authored comment - it
# gets no special-casing here: a watching session filters it out only when its
# own --my-crew-id matches the id that performed the merge, and sees it as a
# real event otherwise (e.g. a reviewer polling the same PR after a different
# crew member merged it).
ev_as() { uv run --no-project --quiet "$EVAL" --pr-json "$PRJ" --cursor "$CUR" --me me --my-crew-id "$1" 2>/dev/null; }

rm -f "$CUR"
echo '{"number":12,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
ev_as dev1 >/dev/null  # seed: baseline, nothing fires yet
echo '{"number":12,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[{"createdAt":"2026-07-15T12:00:00Z","author":{"login":"me"},"body":"<!-- wingman-crew:dev1 --> Merged by wingman crew `dev1` (type: `developer`), not by the human - see issue #46."}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_eq "the merging session's own merge-attribution comment is filtered out (pointless self-wake)" "$(ev_as dev1)" ""

rm -f "$CUR"
echo '{"number":12,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
ev_as reviewer-9 >/dev/null  # seed: baseline, nothing fires yet
echo '{"number":12,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[{"createdAt":"2026-07-15T12:00:00Z","author":{"login":"me"},"body":"<!-- wingman-crew:dev1 --> Merged by wingman crew `dev1` (type: `developer`), not by the human - see issue #46."}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_contains "a different watching session (e.g. a reviewer) still surfaces the same comment (issue #59)" "$(ev_as reviewer-9)" "comment: #12"

# --- merge-ready: allow_merge layered on the same "ready" condition ----------
# --crew-record points at a file shaped like a crew.json record (only
# `allow_merge` is read); ev_cr() is ev() plus that flag.
CRJ="$D/crew.json"
ev_cr() { uv run --no-project --quiet "$EVAL" --pr-json "$PRJ" --cursor "$CUR" --crew-record "$CRJ" --me me --my-crew-id dev-1 2>/dev/null; }

# settling with allow_merge already granted fires merge-ready, not checks-passed
rm -f "$CUR"
echo '{"allow_merge":true}' > "$CRJ"
echo '{"number":20,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_contains "settling with allow_merge already granted fires merge-ready" "$(ev_cr)" "merge-ready: #20"
assert_eq "a settled merge-ready PR does not re-fire" "$(ev_cr)" ""

# a mid-flight allow_merge grant landing on an ALREADY-settled PR (checks-passed
# already fired under no grant) fires merge-ready on the very next poll with no
# PR-side change at all - the exact gap the investigation identified.
rm -f "$CUR"
echo '{"allow_merge":false}' > "$CRJ"
echo '{"number":21,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_contains "not yet granted: settling fires ordinary checks-passed" "$(ev_cr)" "checks-passed: #21"
echo '{"allow_merge":true}' > "$CRJ"
assert_contains "granting allow_merge afterward fires merge-ready next poll, no PR change needed" "$(ev_cr)" "merge-ready: #21"
assert_eq "merge-ready does not re-fire while still settled" "$(ev_cr)" ""

# revoking allow_merge after merge-ready already fired does not produce a stray
# checks-passed for a PR the member already knows is ready
echo '{"allow_merge":false}' > "$CRJ"
assert_eq "revoking allow_merge (ready unchanged) does not fire a stray checks-passed" "$(ev_cr)" ""

# re-granting (still no PR-side change) re-fires merge-ready - either side of the
# combined (ready AND allow_merge) condition flipping independently re-arms it
echo '{"allow_merge":true}' > "$CRJ"
assert_contains "re-granting allow_merge re-fires merge-ready with no PR-side change" "$(ev_cr)" "merge-ready: #21"

# resettling (ready False, then True) with allow_merge held throughout re-fires
# merge-ready, mirroring checks-passed's own re-arm behavior
echo '{"number":21,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_eq "a pending rollup withholds merge-ready" "$(ev_cr)" ""
echo '{"number":21,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_contains "resettling with allow_merge still granted re-fires merge-ready" "$(ev_cr)" "merge-ready: #21"

# a fresh comment still beats merge-ready - same priority slot as checks-passed
rm -f "$CUR"
echo '{"allow_merge":true}' > "$CRJ"
echo '{"number":22,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
ev_cr >/dev/null  # seed: settles and fires merge-ready once, consumed
echo '{"number":22,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[{"createdAt":"2026-07-10T12:00:00Z","author":{"login":"rev"}}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_contains "a fresh comment wins over merge-ready" "$(ev_cr)" "comment: #22"

# a missing --crew-record (never passed, or pointing at a nonexistent file) is
# treated as allow_merge:false, the safe default, not an error
rm -f "$CUR"
echo '{"number":23,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_contains "omitting --crew-record behaves exactly as before (checks-passed)" "$(ev)" "checks-passed: #23"
rm -f "$CUR"
assert_contains "a nonexistent --crew-record file falls back to allow_merge:false" "$(uv run --no-project --quiet "$EVAL" --pr-json "$PRJ" --cursor "$CUR" --crew-record "$D/does-not-exist.json" --me me --my-crew-id dev-1 2>/dev/null)" "checks-passed: #23"

# --- omitting --my-crew-id is a hard argument error, not a silent fallback ---
rm -f "$CUR"
echo '{"number":13,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
if uv run --no-project --quiet "$EVAL" --pr-json "$PRJ" --cursor "$CUR" --me me >/dev/null 2>&1; then
  fail "omitting --my-crew-id must be a hard argparse error, not a silent login-only fallback"
else
  ok "omitting --my-crew-id exits non-zero (no silent fallback to the always-wrong login-only rule)"
fi

# --- headRefOid settle-gate: a head must be confirmed on two consecutive
# --- polls before an empty/resolved rollup can satisfy checks-passed
# --- (issue #257) -------------------------------------------------------------
# A fresh push - including the FIRST push of a brand-new PR, the moment
# bin/pr-watch is armed immediately after `gh pr create` - can leave
# statusCheckRollup empty for the NEW head for the 20-30s window before
# Actions registers any check runs for it, identical at the data level to a
# genuine no-CI PR. checks-passed/merge-ready must not fire until the SAME
# head has been observed on two consecutive polls.

# regression pin: a FRESH cursor (no prior poll at all) with headRefOid
# present and an empty rollup must NOT fire on its very first poll - this is
# the case a naive "baseline the first observation" design misses, since a
# fresh cursor is exactly what a brand-new PR's first poll sees.
rm -f "$CUR"
echo '{"number":30,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-new"}' > "$PRJ"
assert_eq "a fresh cursor with headRefOid present and an empty rollup does NOT fire on the first poll" "$(ev)" ""
assert_contains "the SAME head confirmed on a second poll fires checks-passed" "$(ev)" "checks-passed: #30"
assert_eq "a settled poll after that does not re-fire" "$(ev)" ""

# fix-up push race: an established head (already confirmed, already fired
# once) changes mid-flight; the new head must independently earn its own
# two-poll confirmation before checks-passed re-fires for it.
rm -f "$CUR"
echo '{"number":31,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-old"}' > "$PRJ"
assert_eq "seed: old head's CI in progress, nothing fires" "$(ev)" ""
echo '{"number":31,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-new"}' > "$PRJ"
assert_eq "a fix-up push landing (new head, rollup now empty) does NOT fire checks-passed on this same poll" "$(ev)" ""
assert_contains "a follow-up poll with the SAME new head and still-empty rollup fires checks-passed" "$(ev)" "checks-passed: #31"

# empty -> CI actually registers -> green: checks-passed must fire only on
# the poll that confirms green for the confirmed head, never on the
# transient empty reading that preceded CI registering at all.
rm -f "$CUR"
echo '{"number":32,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-x"}' > "$PRJ"
assert_eq "fresh cursor, empty rollup, head not yet confirmed - nothing fires" "$(ev)" ""
echo '{"number":32,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-x"}' > "$PRJ"
assert_eq "same head now shows CI actually pending - still nothing (an ordinary pending rollup)" "$(ev)" ""
echo '{"number":32,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-x"}' > "$PRJ"
assert_contains "same head now green fires checks-passed" "$(ev)" "checks-passed: #32"

# a caller that never supplies headRefOid at all (older/degraded gh output,
# or every existing fixture in this file above) never gates - byte-identical
# to pre-fix behavior. The existing "a no-CI PR fires checks-passed on first
# poll" case (line 25-27 of this file, unmodified) already covers this; no
# new fixture is needed to prove it, since none of the file's existing
# fixtures carry the field.

# the same settle-gate applies to merge-ready (same ready computation,
# allow_merge layered on top). $CRJ is set fresh here so this case does not
# depend on whatever the last --crew-record section above left it holding.
rm -f "$CUR"
echo '{"allow_merge":true}' > "$CRJ"
echo '{"number":33,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-y"}' > "$PRJ"
assert_eq "fresh cursor, allow_merge granted, head not yet confirmed - merge-ready withheld" "$(ev_cr)" ""
assert_contains "the SAME head confirmed on a second poll fires merge-ready" "$(ev_cr)" "merge-ready: #33"

# pin: a poll that fires a DIFFERENT, higher-priority event for a newly-changed
# head still advances the recorded head - so the very next poll can confirm and
# fire checks-passed, without a second full settle poll for the head itself.
# This is intended (head-tracking is unconditional and independent of which
# event a poll returns), but was unpinned before this case - see the plan's
# "Risks / follow-ups" section for why this means the settle delay is "at
# least one more poll," not always a full $WM_PR_WATCH_INTERVAL.
rm -f "$CUR"
echo '{"number":34,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-old"}' > "$PRJ"
assert_eq "seed (interleaved-event case): old head's CI in progress, nothing fires" "$(ev)" ""
echo '{"number":34,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[{"createdAt":"2026-07-10T12:00:00Z","author":{"login":"rev"}}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-new"}' > "$PRJ"
assert_contains "head changes AND a fresh comment land on the same poll - comment wins priority, but the head still advances" "$(ev)" "comment: #34"
echo '{"number":34,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[{"createdAt":"2026-07-10T12:00:00Z","author":{"login":"rev"}}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-new"}' > "$PRJ"
assert_contains "the SAME head, confirmed on the very next poll, fires checks-passed - only one poll after the comment, not one full interval after the head change" "$(ev)" "checks-passed: #34"

# --- outage settle-gate: an existing, already-confirmed head going empty must
# --- never be trusted as resolved when the caller knows this repo has CI
# --- configured (issue #274) -------------------------------------------------
ev_ci() { uv run --no-project --quiet "$EVAL" --pr-json "$PRJ" --cursor "$CUR" --me me --my-crew-id dev-1 --has-ci-config 2>/dev/null; }

# an ALREADY-confirmed head (CI was healthy last poll) going empty must not
# fire checks-passed even once - the #257 "same head twice" gate is already
# satisfied from before the outage began, so this is NOT the same case #257
# covers; it needs its own gate.
rm -f "$CUR"
echo '{"number":40,"state":"OPEN","statusCheckRollup":[{"name":"test","status":"IN_PROGRESS"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-existing"}' > "$PRJ"
assert_eq "seed: CI genuinely running, nothing fires" "$(ev_ci)" ""
echo '{"number":40,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-existing"}' > "$PRJ"
assert_eq "outage begins on the SAME already-confirmed head - rollup empties but must NOT fire checks-passed" "$(ev_ci)" ""
assert_eq "outage persisting across several more polls still does not fire" "$(ev_ci)" ""
assert_eq "and again" "$(ev_ci)" ""
echo '{"number":40,"state":"OPEN","statusCheckRollup":[{"name":"test","status":"COMPLETED","conclusion":"SUCCESS"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-existing"}' > "$PRJ"
assert_contains "the outage clears and CI genuinely reports green - checks-passed fires on the real signal" "$(ev_ci)" "checks-passed: #40"

# a fresh PR opened DURING an outage (repo has CI, head never confirmed, rollup
# empty from the very start) - both gates (head-confirm and has-ci) must
# independently withhold it; neither masks the other.
rm -f "$CUR"
echo '{"number":41,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-new"}' > "$PRJ"
assert_eq "fresh cursor, has-ci-config, empty rollup, head unconfirmed - withheld" "$(ev_ci)" ""
assert_eq "same head now confirmed, still empty, has-ci-config still withholds it" "$(ev_ci)" ""

# without --has-ci-config (the caller couldn't determine it, or genuinely has
# no CI), behavior is byte-identical to pre-#274 - the existing "a no-CI PR
# fires checks-passed on first poll" case (line 25-27, unmodified) already
# covers the no-headRefOid variant of this; this pins the headRefOid variant.
rm -f "$CUR"
echo '{"number":42,"state":"OPEN","statusCheckRollup":[{"name":"test","status":"IN_PROGRESS"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-x"}' > "$PRJ"
ev >/dev/null  # seed, no --has-ci-config
echo '{"number":42,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-x"}' > "$PRJ"
assert_contains "no --has-ci-config: an established head going empty still settles exactly as before #274" "$(ev)" "checks-passed: #42"

# merge-ready inherits the same gate - the most safety-critical case, since
# firing this on a lie would attempt a merge on unverified code.
CRJ2="$D/crj2.json"
ev_ci_mr() { uv run --no-project --quiet "$EVAL" --pr-json "$PRJ" --cursor "$CUR" --crew-record "$CRJ2" --me me --my-crew-id dev-1 --has-ci-config 2>/dev/null; }
rm -f "$CUR"
echo '{"allow_merge":true}' > "$CRJ2"
echo '{"number":43,"state":"OPEN","statusCheckRollup":[{"name":"test","status":"IN_PROGRESS"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-m"}' > "$PRJ"
assert_eq "seed: CI running, allow_merge granted" "$(ev_ci_mr)" ""
echo '{"number":43,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-m"}' > "$PRJ"
assert_eq "outage on an already-confirmed head with allow_merge granted - merge-ready must NOT fire" "$(ev_ci_mr)" ""
assert_eq "outage persists - still withheld" "$(ev_ci_mr)" ""

# --- malformed/incomplete rollup entries never parse as resolved (issue #274)
# --- - independent of --has-ci-config, and independent of whether the array
# --- is otherwise empty ------------------------------------------------------
rm -f "$CUR"
echo '{"number":50,"state":"OPEN","statusCheckRollup":[{"name":"test"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-b"}' > "$PRJ"
assert_eq "fresh cursor, malformed entry (no conclusion/status/state at all), head unconfirmed" "$(ev)" ""
assert_eq "same head confirmed, entry still malformed - still withheld (no --has-ci-config needed)" "$(ev)" ""
echo '{"number":50,"state":"OPEN","statusCheckRollup":[{"name":"test","status":"COMPLETED","conclusion":"SUCCESS"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-b"}' > "$PRJ"
assert_contains "the entry resolving to a real conclusion fires checks-passed normally" "$(ev)" "checks-passed: #50"

# --- a StatusContext entry that DOES match the recognized shape, but with a
# --- garbled or null "state" value, is just as reachable as the no-shape-at-
# --- all case above and must be hardened the same direction (issue #274,
# --- round-1 review finding) --------------------------------------------------
rm -f "$CUR"
echo '{"number":61,"state":"OPEN","statusCheckRollup":[{"context":"ci/legacy","state":null}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-d"}' > "$PRJ"
assert_eq "fresh cursor, StatusContext with state:null, head unconfirmed" "$(ev)" ""
assert_eq "same head confirmed, state still null - still withheld" "$(ev)" ""
echo '{"number":61,"state":"OPEN","statusCheckRollup":[{"context":"ci/legacy","state":"UNKNOWN"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-d"}' > "$PRJ"
assert_eq "same head, a garbled non-null state value ('UNKNOWN') is also withheld, not just null" "$(ev)" ""
echo '{"number":61,"state":"OPEN","statusCheckRollup":[{"context":"ci/legacy","state":"SUCCESS"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-d"}' > "$PRJ"
assert_contains "the state resolving to a real terminal value fires checks-passed normally" "$(ev)" "checks-passed: #61"

# the same gap on the merge-ready path - the safety-critical case: a real
# merge attempt must never be triggered on a garbled/null StatusContext state
CRJ3="$D/crj3.json"
ev_ci_mr2() { uv run --no-project --quiet "$EVAL" --pr-json "$PRJ" --cursor "$CUR" --crew-record "$CRJ3" --me me --my-crew-id dev-1 2>/dev/null; }
rm -f "$CUR"
echo '{"allow_merge":true}' > "$CRJ3"
echo '{"number":62,"state":"OPEN","statusCheckRollup":[{"context":"ci/legacy","state":null}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-e"}' > "$PRJ"
assert_eq "fresh cursor, allow_merge granted, state:null, head unconfirmed" "$(ev_ci_mr2)" ""
assert_eq "same head confirmed, state still null - merge-ready must NOT fire" "$(ev_ci_mr2)" ""

# a malformed entry must not be misreported as ci-failed either - it should
# simply withhold readiness, never misdirect a member to "fix CI".
rm -f "$CUR"
echo '{"number":51,"state":"OPEN","statusCheckRollup":[{"weird":"shape"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
case "$(ev)" in *ci-failed*) fail "a malformed rollup entry must never fire ci-failed" ;; *) ok "a malformed entry does not misreport as ci-failed" ;; esac

# --- checkSuite forge signal (issue #259), strictly conservative: a non-zero
# --- count withholds unconditionally; a zero/unavailable count changes
# --- nothing and falls through to --has-ci-config exactly as before -------
CSJ="$D/cs.json"
ev_cs() { uv run --no-project --quiet "$EVAL" --pr-json "$PRJ" --cursor "$CUR" --me me --my-crew-id dev-1 --check-suites-json "$CSJ" 2>/dev/null; }

# THE #259 BUG ITSELF: checkSuiteCount > 0 (checks ARE registered for this
# exact commit) but the rollup stays empty for MULTIPLE polls beyond the #257
# settle gate - must stay withheld the whole time, with NO --has-ci-config,
# only firing once the rollup genuinely reports a real entry.
rm -f "$CUR"
echo '{"number":101,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-b"}' > "$PRJ"
echo '{"data":{"repository":{"pullRequest":{"commits":{"nodes":[{"commit":{"oid":"sha-b","checkSuites":{"totalCount":1}}}]}}}}}' > "$CSJ"
assert_eq "poll 1: head unconfirmed (the pre-existing #257 gate, unrelated to this fix)" "$(ev_cs)" ""
assert_eq "poll 2: head confirmed, checkSuite registered, rollup still empty - withheld, NOT the #257 one-poll settle" "$(ev_cs)" ""
assert_eq "poll 3: still slow to report - still withheld" "$(ev_cs)" ""
assert_eq "poll 4: still slow - still withheld" "$(ev_cs)" ""
echo '{"number":101,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-b"}' > "$PRJ"
assert_contains "poll 5: CI finally reports - checks-passed fires on the real signal" "$(ev_cs)" "checks-passed: #101"

# the real #274/PR#271 incident shape: an ALREADY-confirmed head (CI healthy
# last poll) whose rollup empties out while checkSuiteCount stays >= 1 for
# the SAME head - withheld immediately, no --has-ci-config needed at all.
rm -f "$CUR"
echo '{"number":271,"state":"OPEN","statusCheckRollup":[{"name":"test","status":"IN_PROGRESS"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-existing"}' > "$PRJ"
assert_eq "seed: CI genuinely running, nothing fires" "$(ev_cs)" ""
echo '{"number":271,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-existing"}' > "$PRJ"
echo '{"data":{"repository":{"pullRequest":{"commits":{"nodes":[{"commit":{"oid":"sha-existing","checkSuites":{"totalCount":1}}}]}}}}}' > "$CSJ"
assert_eq "outage begins on the SAME already-confirmed head - checkSuite still registered - withheld with NO --has-ci-config" "$(ev_cs)" ""
assert_eq "outage persists - still withheld" "$(ev_cs)" ""

# checkSuiteCount == 0 is NOT trusted as "no CI" - falls straight through,
# byte-identical to the signal being absent entirely.
rm -f "$CUR"
echo '{"number":100,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-a"}' > "$PRJ"
echo '{"data":{"repository":{"pullRequest":{"commits":{"nodes":[{"commit":{"oid":"sha-a","checkSuites":{"totalCount":0}}}]}}}}}' > "$CSJ"
assert_eq "poll 1" "$(ev_cs)" ""
assert_contains "poll 2: count==0 settles via the plain #257 gate - identical timing to no forge signal at all" "$(ev_cs)" "checks-passed: #100"

# checkSuiteCount == 0 does NOT override --has-ci-config=True - the #274 hang
# is explicitly NOT resolved by this fix (out of scope - see Problem).
# $CSJ MUST be rewritten here with an oid matching THIS block's own $PRJ
# (sha-d): round-2 review caught that reusing the prior block's $CSJ
# (oid sha-a, against this block's headRefOid sha-d) makes the assertions
# below pass for the WRONG reason - an oid MISMATCH, which already returns
# None via check_suite_count_for_head regardless of what the (unread)
# totalCount says, so the test would pass identically under the rejected
# "trust count==0" design too. Proven vacuous, then proven fixed: with the
# mismatched fixture, both the strict formula and a reconstructed "trust
# count==0" variant give the same (withheld) result; with the oid corrected
# to sha-d below, the trusting variant fires checks-passed on poll 2 (fails
# this assertion) while the strict formula still correctly withholds.
ev_cs_ci() { uv run --no-project --quiet "$EVAL" --pr-json "$PRJ" --cursor "$CUR" --me me --my-crew-id dev-1 --has-ci-config --check-suites-json "$CSJ" 2>/dev/null; }
rm -f "$CUR"
echo '{"number":104,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-d"}' > "$PRJ"
echo '{"data":{"repository":{"pullRequest":{"commits":{"nodes":[{"commit":{"oid":"sha-d","checkSuites":{"totalCount":0}}}]}}}}}' > "$CSJ"
assert_eq "poll 1" "$(ev_cs_ci)" ""
assert_eq "poll 2: count==0 (a REAL read, oid matches) does NOT override has-ci-config=True - still withheld (the #274 hang, unresolved by design)" "$(ev_cs_ci)" ""
assert_eq "poll 3: still withheld" "$(ev_cs_ci)" ""

# merge-ready inherits the same conservative gate.
CRJ="$D/crj-cs.json"
ev_cs_mr() { uv run --no-project --quiet "$EVAL" --pr-json "$PRJ" --cursor "$CUR" --crew-record "$CRJ" --me me --my-crew-id dev-1 --check-suites-json "$CSJ" 2>/dev/null; }
rm -f "$CUR"
echo '{"allow_merge":true}' > "$CRJ"
echo '{"number":105,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-e"}' > "$PRJ"
echo '{"data":{"repository":{"pullRequest":{"commits":{"nodes":[{"commit":{"oid":"sha-e","checkSuites":{"totalCount":2}}}]}}}}}' > "$CSJ"
assert_eq "seed: allow_merge granted, checkSuites registered, rollup empty" "$(ev_cs_mr)" ""
assert_eq "same head confirmed, still empty - merge-ready must NOT fire" "$(ev_cs_mr)" ""
echo '{"number":105,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-e"}' > "$PRJ"
assert_contains "CI finally reports - merge-ready fires on the real signal" "$(ev_cs_mr)" "merge-ready: #105"

# oid mismatch (a push landed between the --pr-json and --check-suites-json
# calls) must never misattribute a stale count to the new commit - falls back
# to --has-ci-config (unset here), settling via the plain #257 gate.
rm -f "$CUR"
echo '{"number":102,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-new-push"}' > "$PRJ"
echo '{"data":{"repository":{"pullRequest":{"commits":{"nodes":[{"commit":{"oid":"sha-stale","checkSuites":{"totalCount":5}}}]}}}}}' > "$CSJ"
assert_eq "poll 1" "$(ev_cs)" ""
assert_contains "poll 2: mismatched oid every time (count=5 for the WRONG commit) - falls back to the plain #257 gate, checks-passed fires" "$(ev_cs)" "checks-passed: #102"

# malformed/error --check-suites-json degrades to the has_ci_config fallback,
# never raises and never silently miscounts.
rm -f "$CUR"
echo '{"number":106,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-f"}' > "$PRJ"
echo '{"errors":[{"message":"boom"}]}' > "$CSJ"
assert_eq "poll 1" "$(ev_cs)" ""
assert_contains "poll 2: malformed graphql response falls back to plain #257 settle" "$(ev_cs)" "checks-passed: #106"

# N5 (round-1 review): --check-suites-json present while --pr-json carries no
# headRefOid at all - check_suite_count_for_head's own "not head_oid" guard
# returns None, and the separate "or not head_oid" clause in ready fires
# immediately, exactly as if the flag had never been passed.
rm -f "$CUR"
echo '{"number":300,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
echo '{"data":{"repository":{"pullRequest":{"commits":{"nodes":[{"commit":{"oid":"sha-x","checkSuites":{"totalCount":5}}}]}}}}}' > "$CSJ"
assert_contains "no headRefOid at all: fires on first poll exactly as pre-#257 behavior, forge signal ignored" "$(ev_cs)" "checks-passed: #300"

# no --check-suites-json at all (the call failed/was skipped in bin/pr-watch)
# is byte-identical to pre-#259 (--has-ci-config-only) behavior.
rm -f "$CUR"
echo '{"number":103,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-c"}' > "$PRJ"
ev_ci_only() { uv run --no-project --quiet "$EVAL" --pr-json "$PRJ" --cursor "$CUR" --me me --my-crew-id dev-1 --has-ci-config 2>/dev/null; }
assert_eq "poll 1" "$(ev_ci_only)" ""
assert_eq "poll 2: no forge signal, has-ci-config withholds exactly as pre-#259" "$(ev_ci_only)" ""

test_summary
