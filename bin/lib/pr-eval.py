#!/usr/bin/env python3
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""pr-eval: decide the single actionable PR event since the last one handled.

This is the decision core of `bin/pr-watch` (the crew-level watcher), kept in
Python so the shell stays a thin poll loop and the logic is unit-testable with
canned JSON. It reads:

  --pr-json <path|->        output of `gh pr view <pr> --json
                            state,mergedAt,statusCheckRollup,reviews,comments,number,url,
                            mergeable,mergeStateStatus,headRefOid` - headRefOid (the
                            SHA of the commit the rollup describes) gates checks-passed/
                            merge-ready, see the settle-gate paragraph below
  --review-comments <path>  a JSON array of inline review-thread comments
                            (`gh api repos/{owner}/{repo}/pulls/{n}/comments`), optional
  --cursor <path>           the on-disk cursor of what has already been surfaced - read,
                            evaluated, and written under an exclusive flock (bin/lib/wm_lock.py),
                            so two overlapping invocations can never race on a lost cursor update
                            (issue #180)
  --crew-record <path>      OPTIONAL: this session's own crew.json record (or a
                            file shaped like one), e.g. `wm-state crew-get --id
                            $WINGMAN_CREW_ID` written to a file the same way
                            --pr-json/--review-comments already are. Only the
                            `allow_merge` field is read; a missing/unreadable
                            file (no grant, or the record predates this flag)
                            is treated as `allow_merge: false` - the safe
                            default. `review_gate_waived` is deliberately NOT
                            consulted here: it decides whether a merge ATTEMPT
                            succeeds (hooks/no-merge-guard.sh's job), not
                            whether attempting is worth waking the crew for.
  --me <login>              the authenticated forge login. Combined with
                            --my-crew-id (below), identifies THIS session's own
                            comments/reviews so a reply never wakes its own
                            author (avoids a reply loop). Every crew session
                            shares one forge login (issue #50) - by itself this
                            flag can only ever mean "same account", never "same
                            session", so login alone is never sufficient to
                            drop an item (see --my-crew-id).
  --my-crew-id <id>         REQUIRED. This session's own $WINGMAN_CREW_ID. An
                            item is treated as this session's own reply, and
                            dropped, only when BOTH its author's login equals
                            --me AND its body OPENS WITH (not merely contains
                            - see _is_own_reply) a `<!-- wingman-crew:<id> -->`
                            marker whose <id> equals this value. A same-login
                            item with no marker (a human's genuine comment,
                            issue #118), a marker naming a DIFFERENT crew id
                            (another crew member's own genuine review/comment,
                            e.g. a reviewer's verdict, issue #59), or a marker
                            that appears only quoted/mid-body (a human's
                            GitHub "Quote reply" to a marked reply) is never
                            dropped - it surfaces as a real event. This flag is
                            required (not optional) because a login-only
                            fallback is exactly the bug this file fixes -
                            bin/pr-watch always passes its own $WINGMAN_CREW_ID
                            (guaranteed set at that point), so there is no
                            legitimate caller this would ever break.
  --has-ci-config           OPTIONAL: this repo's checkout has at least one
                            workflow file under .github/workflows/, computed
                            by the caller (bin/pr-watch) from the local
                            filesystem, once per arm cycle. Gates the empty-
                            rollup settle shortcut - see the outage-gate
                            paragraph below. Omitting it is byte-identical to
                            pre-#274 behavior.
  --check-suites-json <path> OPTIONAL: raw `gh api graphql` response naming the
                            checkSuites totalCount for the PR's current head
                            commit (issue #259), shaped like
                            commits(last:1){nodes{commit{oid
                            checkSuites(first:1){totalCount}}}}. A NON-zero
                            count for the exact head commit withholds
                            checks-passed/merge-ready unconditionally, even
                            without --has-ci-config - see the checkSuite-gate
                            paragraph below. A zero or unavailable count (a
                            missing flag, an oid mismatch, or a
                            malformed/error response) carries no information
                            and falls straight through to --has-ci-config
                            unchanged. Omitting it is byte-identical to
                            pre-#259 behavior.

It prints ONE reason line and advances the cursor for exactly that dimension, or
prints nothing when there is no new event. Priority (highest first):

  merged > closed > changes-requested > ci-failed > conflict > comment
    > merge-ready (if allow_merge) / checks-passed (otherwise)

Only the fired dimension's cursor advances, so a co-occurring event of lower
priority still surfaces on the next poll instead of being skipped. A CI rollup
that has gone green resets the ci cursor (a later failure re-fires); a pending or
unchanged-failing rollup is not an event. `conflict` mirrors the same edge-
triggered shape: it fires once on the transition into a conflicting mergeability
and is cleared (without re-firing) the moment the base moves back to mergeable -
see `_map_mergeability`.

`checks-passed` fires once when the PR has nothing failing, nothing pending, and
is mergeable - covering both an all-green rollup and a repo with no CI at all - so
a member that stays `working` through CI (and any merge-conflict drift) is woken
to move into `review` the moment it settles. It sits below `comment` so
unaddressed feedback is handled before the member parks, and it re-arms (fires
again) once checks or mergeability go back to pending/failing/conflicting and
settle anew.

`checks-passed`/`merge-ready` are additionally gated on `headRefOid` (issue #257):
an empty or fully-resolved `statusCheckRollup` is trusted only once the SAME head
has been observed on two consecutive polls, including a fresh cursor's very first
poll. Right after a push (a fix-up commit, or the first push of a brand-new PR),
`statusCheckRollup` can be transiently empty for the new head for the 20-30s
window before Actions registers any check runs for it - a snapshot
indistinguishable, at the data level, from a genuine no-CI PR's permanently-empty
rollup. Requiring two consecutive polls to agree on the head before trusting that
snapshot closes the race for both the fix-up-push case and the arm-immediately-
after-`gh pr create` case. A PR whose `--pr-json` carries no `headRefOid` at all
(an older/degraded caller, or a test fixture omitting the field) never gates -
this is byte-identical to pre-#257 behavior.

`checks-passed`/`merge-ready` are further gated on `--has-ci-config` (issue #274):
an EMPTY `statusCheckRollup` (zero entries) is trusted as "resolved, no CI" only
when the caller has NOT established that this repo has CI configured. When
`--has-ci-config` is passed, an empty rollup on an already-confirmed head means
checks exist but are not currently reporting - e.g. a GitHub Actions outage -
and is never read as resolved, no matter how many polls agree on the same head;
this closes a gap the `headRefOid` settle-gate above does not cover, since a
head confirmed as healthy BEFORE an outage begins already satisfies that gate
on the very first outage-degraded poll. A rollup entry that is present but
malformed or carries an unrecognized/garbled state is separately never treated
as resolved by `checks_pending` itself, independent of `--has-ci-config`.

`checks-passed`/`merge-ready` are also gated on `--check-suites-json` (issue
#259): when the forge reports a NON-zero checkSuite count for the exact head
commit, an empty `statusCheckRollup` is never treated as resolved, regardless
of `head_confirmed` or `--has-ci-config` - checks are registered for this
commit but have not reported into the rollup yet. This is strictly
conservative (a non-zero count can only withhold a result that would
otherwise have fired, never produce one that wouldn't have), so it applies on
the very first poll, with no settle window of its own. A zero or unavailable
count is NOT trusted as "no CI" - it carries exactly as little information as
`statusCheckRollup` itself being empty - and falls straight through to the
`--has-ci-config` behavior above, unchanged.

`merge-ready` occupies the exact same slot as `checks-passed` but fires instead
of it when `--crew-record` reports `allow_merge: true`: the PR being green and
mergeable is no longer just a cue to park in `review`, it is a cue to attempt the
merge (see playbooks/_delivery.md's "Merge authorization"). It is tracked by its
own cursor (`merge_ready_fired`), independent of `ready_fired`, so it re-fires
whenever the combined condition (ready AND allow_merge) transitions back to true
from either side: the PR resettling after a new commit, or `allow_merge` being
newly granted while the PR was already sitting ready (the case a mid-flight grant
on an already-settled PR would otherwise never wake anyone for). Firing
merge-ready also marks `ready_fired`, so a later `allow_merge` revoke does not
cause a redundant `checks-passed` for a PR the member already knows is ready.
"""
import argparse
import json
import os
import re
import sys

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from wm_lock import with_locked

# CheckRun conclusions that count as a failure the crew should fix. NEUTRAL,
# SKIPPED, STALE and SUCCESS are not failures; QUEUED/IN_PROGRESS have no
# conclusion yet (still pending).
FAIL_CONCLUSIONS = {"FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"}
# StatusContext states that count as a failure.
FAIL_STATES = {"ERROR", "FAILURE"}
# StatusContext states that count as terminal/resolved (success or a
# recognized failure). Anything else - PENDING, EXPECTED, null, empty, or a
# garbled/unrecognized value a degraded API response could plausibly return -
# is treated as still-pending, the same safe default the sibling CheckRun
# branch already applies via its own "status != COMPLETED" check.
RESOLVED_STATES = {"SUCCESS"} | FAIL_STATES


def read_json(path, default):
    if not path:
        return default
    try:
        if path == "-":
            return json.load(sys.stdin)
        with open(path) as fh:
            return json.load(fh)
    except (FileNotFoundError, ValueError):
        return default


def write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(obj, fh, indent=2, sort_keys=True)
        fh.write("\n")
    import os
    os.replace(tmp, path)


def failing_checks(pr):
    """Sorted names of currently-failing checks. Empty = green or still pending."""
    names = []
    for c in pr.get("statusCheckRollup") or []:
        if not isinstance(c, dict):
            continue
        if "conclusion" in c or "status" in c:  # CheckRun
            if str(c.get("status") or "").upper() == "COMPLETED" \
                    and str(c.get("conclusion") or "").upper() in FAIL_CONCLUSIONS:
                names.append(c.get("name") or c.get("context") or "check")
        elif str(c.get("state") or "").upper() in FAIL_STATES:  # StatusContext
            names.append(c.get("context") or c.get("name") or "check")
    return sorted(set(names))


def checks_pending(pr):
    """True if any check has not yet concluded (still queued/in-progress/expected).
    A CheckRun is pending until its status is COMPLETED; a StatusContext is pending
    unless its state is a recognized terminal value (RESOLVED_STATES); a dict
    entry matching NEITHER recognized shape (a malformed/partial record -
    issue #274) is also pending, never silently invisible."""
    for c in pr.get("statusCheckRollup") or []:
        if not isinstance(c, dict):
            continue
        if "conclusion" in c or "status" in c:  # CheckRun
            if str(c.get("status") or "").upper() != "COMPLETED":
                return True
        elif "state" in c:  # StatusContext
            if str(c.get("state") or "").upper() not in RESOLVED_STATES:
                return True
        else:
            # Neither shape - a partial/malformed record. Never silently
            # invisible: treat as still-unresolved so a degraded rollup can't
            # be read as settled just because none of its entries parsed.
            return True
    return False


def check_suite_count_for_head(check_suites_json, head_oid):
    """checkSuites totalCount for the exact head commit, from a `gh api graphql`
    response shaped like bin/pr-watch's commits(last:1){nodes{commit{oid
    checkSuites(first:1){totalCount}}}} query (issue #259) - or None if the
    response is absent/malformed, OR the commit it describes does not match
    head_oid (a push landed between the two `gh` calls that produced --pr-json
    and --check-suites-json this same poll; the next poll's own consistent
    snapshot settles it instead of miscounting across commits)."""
    if not isinstance(check_suites_json, dict) or not head_oid:
        return None
    try:
        nodes = check_suites_json["data"]["repository"]["pullRequest"]["commits"]["nodes"]
        if not nodes:
            return None
        commit = nodes[0]["commit"]
        oid = (commit.get("oid") or "").strip().lower()
        if oid != head_oid:
            return None
        return int(commit["checkSuites"]["totalCount"])
    except (AttributeError, KeyError, TypeError, ValueError, IndexError):
        return None


def _map_mergeability(mergeable, merge_state_status):
    """Collapse gh's mergeable/mergeStateStatus pair into MERGEABLE/CONFLICTING/
    UNKNOWN. Either field can lag (GitHub computes them asynchronously), so a
    CONFLICTING/DIRTY reading from either wins outright; only when BOTH are absent
    or UNKNOWN is the result UNKNOWN (not yet computed); everything else
    (CLEAN/BEHIND/BLOCKED/UNSTABLE/HAS_HOOKS/DRAFT) is MERGEABLE."""
    mergeable = (mergeable or "UNKNOWN").upper()
    merge_state_status = (merge_state_status or "UNKNOWN").upper()
    if mergeable == "CONFLICTING" or merge_state_status == "DIRTY":
        return "CONFLICTING"
    if mergeable == "UNKNOWN" and merge_state_status == "UNKNOWN":
        return "UNKNOWN"
    return "MERGEABLE"


CREW_MARKER_RE = re.compile(r"^\s*<!--\s*wingman-crew:([A-Za-z0-9._-]+)\s*-->")


def _login(item):
    a = item.get("author") or item.get("user") or {}
    if isinstance(a, dict):
        return a.get("login") or ""
    return a or ""


def _body(item):
    return item.get("body") or ""


def _ts(item):
    return item.get("submittedAt") or item.get("createdAt") or item.get("created_at") or ""


def _is_own_reply(login, body, me, my_crew_id):
    """True iff this item is THIS session's own reply and should be dropped so
    it never wakes its own author. Login alone can never decide this (every
    crew session shares one forge login, issue #50); a marker naming a
    DIFFERENT crew id is a genuine external event (issue #59), not a reply to
    drop. The marker is matched ANCHORED to the body's start (re.match, not
    re.search): every emit site posts it as the body's first characters, so a
    match anywhere else is not this session's own top-level reply - it is a
    human quoting a marked reply (GitHub's "Quote reply", or a quoted email
    reply), which must surface as the genuine feedback it is (issue #118,
    reintroduced through quoting if matched unanchored)."""
    if not me or login != me:
        return False
    m = CREW_MARKER_RE.match(body)
    return bool(m) and m.group(1) == my_crew_id


def conversation(pr, review_comments, me, my_crew_id):
    """Every conversation item as (ts, kind, login). kind is 'review' (a submitted
    review, carrying its state) or 'comment'. THIS session's own items are
    dropped (see _is_own_reply) so a reply never wakes its own author; a
    same-login item from a different crew session, a human's genuine
    same-login comment, or a human's quote-reply of a marked comment, is never
    dropped."""
    items = []
    for r in pr.get("reviews") or []:
        st = str(r.get("state") or "").upper()
        if st in ("PENDING",):
            continue
        items.append((_ts(r), "review:" + st, _login(r), _body(r)))
    for c in pr.get("comments") or []:
        items.append((_ts(c), "comment", _login(c), _body(c)))
    for c in review_comments or []:
        items.append((_ts(c), "comment", _login(c), _body(c)))
    return [
        (ts, kind, who) for (ts, kind, who, body) in items
        if ts and not _is_own_reply(who, body, me, my_crew_id)
    ]


def evaluate(pr, review_comments, cursor, me, my_crew_id, allow_merge=False, has_ci_config=False,
             check_suites_json=None):
    """Return (reason_or_None, new_cursor)."""
    cur = dict(cursor) if isinstance(cursor, dict) else {}
    cur.setdefault("ci", "")
    cur.setdefault("mergeable", "")
    # First run: treat conversation already present as seen (so we don't fire on
    # the crew's own PR-open state), but leave ci empty so an already-red build
    # still fires.
    convo = conversation(pr, review_comments, me, my_crew_id)
    convo_max = max((ts for ts, _, _ in convo), default="")
    if "conv_hwm" not in cur:
        cur["conv_hwm"] = convo_max

    # headRefOid settle-gate (issue #257): a fresh push - including the very
    # first push of a brand-new PR, the moment bin/pr-watch is armed
    # immediately after `gh pr create` - can leave statusCheckRollup empty
    # for the NEW head for the 20-30s window before Actions registers any
    # check runs for it, identical at the data level to a genuine no-CI PR's
    # rollup. Require the SAME head to be observed on two consecutive polls
    # before an empty/resolved rollup can satisfy `ready` - uniformly,
    # including a fresh cursor's very first poll (there is no legitimate
    # "trust it immediately" case: a no-CI PR settles one poll later instead,
    # a real race is closed both on a fix-up push AND on a brand-new PR). A
    # PR carrying no headRefOid at all (an older/degraded caller, or a test
    # fixture omitting the field) never gates - head_confirmed is False and
    # head_oid is empty, and `or not head_oid` below restores exactly the
    # pre-fix behavior.
    head_oid = (pr.get("headRefOid") or "").strip().lower()
    head_confirmed = bool(head_oid) and cur.get("head_ref_oid") == head_oid
    if head_oid:
        cur["head_ref_oid"] = head_oid

    state = str(pr.get("state") or "").upper()
    if state == "MERGED" or pr.get("mergedAt"):
        return ("merged: %s" % _pr_ref(pr), cur)
    if state == "CLOSED":
        return ("closed: %s" % _pr_ref(pr), cur)

    # Conversation: anything strictly newer than the high-water mark.
    fresh = [(ts, kind) for ts, kind, _ in convo if ts > cur["conv_hwm"]]
    changes = [1 for ts, kind in fresh if kind == "review:CHANGES_REQUESTED"]
    if changes:
        cur["conv_hwm"] = convo_max
        return ("changes-requested: %s" % _pr_ref(pr), cur)

    # CI: fire only on a new failing signature; a green rollup resets the cursor.
    fail = failing_checks(pr)
    sig = ",".join(fail)
    if not fail:
        cur["ci"] = ""
    elif sig != cur["ci"]:
        cur["ci"] = sig
        return ("ci-failed: %s %s" % (_pr_ref(pr), sig), cur)

    # Mergeability: edge-triggered exactly like ci above. UNKNOWN (GitHub hasn't
    # finished computing it) touches neither the cursor nor ready_fired below - it
    # is treated like a pending check, not a resolved one, so it never clears an
    # open conflict and never causes a spurious checks-passed re-fire once GitHub
    # settles back to whatever it already was.
    mergeability = _map_mergeability(pr.get("mergeable"), pr.get("mergeStateStatus"))
    if mergeability == "CONFLICTING":
        if cur["mergeable"] != "CONFLICTING":
            cur["mergeable"] = "CONFLICTING"
            return ("conflict: %s" % _pr_ref(pr), cur)
    elif mergeability == "MERGEABLE":
        cur["mergeable"] = "MERGEABLE"

    if fresh:
        cur["conv_hwm"] = convo_max
        return ("comment: %s %d new" % (_pr_ref(pr), len(fresh)), cur)

    # checks-passed / merge-ready: the PR has settled with nothing failing,
    # nothing pending, and mergeable (all-green, or no CI at all - and no open
    # conflict). `ready` is the same settle condition as always; `merge_ready`
    # layers `allow_merge` on top of it, tracked by its OWN cursor so the two
    # fire independently:
    #   - allow_merge is False (the common case): unchanged from before -
    #     checks-passed fires once per settle, re-arming after the next
    #     pending/failing/conflicting reading.
    #   - allow_merge is True: merge-ready fires once per settle INSTEAD (the
    #     member should attempt the merge, not just park) and also marks
    #     ready_fired, so a later allow_merge revoke never produces a stray
    #     checks-passed for a PR the member already knows is ready.
    # Either side flipping independently re-arms it: the PR resettling (ready
    # goes False then True again) resets both cursors via the `not ready`
    # branch below; allow_merge being newly granted while the PR was ALREADY
    # sitting ready resets only merge_ready_fired (via `not merge_ready`), so
    # merge-ready still fires on the very next poll with no dependency on any
    # further PR-side event - closing the gap where a mid-flight allow_merge
    # grant lands on an already-settled PR.
    # Outage settle-gate (issue #274): an EMPTY rollup ([] - zero entries,
    # never populated at all) is trusted as "resolved, no CI" only when the
    # caller has established, independent of the rollup itself, that this
    # repo genuinely has no CI configured. When has_ci_config is True (the
    # repo's .github/workflows/ has at least one workflow file), an empty
    # rollup means checks exist but are not currently reporting - degraded
    # Actions, or a run stuck queued with no runner ever assigned - and must
    # never be read as a resolved result, no matter how many polls agree on
    # the same head. A NON-empty rollup is unaffected either way: real
    # entries (green, pending, or malformed - see checks_pending above) are
    # evaluated exactly as before.
    # Per-commit checkSuite forge signal (issue #259), strictly conservative:
    # a NON-zero count means checks ARE registered for this exact commit but
    # have not reported into the rollup yet - always withhold, regardless of
    # head_confirmed or has_ci_config, and on the very first poll (no settle
    # needed: this only ever *withholds*, so it can never itself produce a
    # false checks-passed). A ZERO or unavailable count carries no
    # information of its own - it is exactly as much "nothing observed" as
    # statusCheckRollup itself being empty - so it is NOT trusted as "no CI"
    # and falls straight through to the has_ci_config branch unchanged.
    empty_rollup = not (pr.get("statusCheckRollup") or [])
    check_suite_count = check_suite_count_for_head(check_suites_json, head_oid)
    empty_rollup_blocks = empty_rollup and ((check_suite_count or 0) > 0 or has_ci_config)
    ready = (not fail) and (not checks_pending(pr)) and mergeability == "MERGEABLE" \
        and (head_confirmed or not head_oid) \
        and not empty_rollup_blocks
    merge_ready = ready and allow_merge
    if mergeability == "UNKNOWN":
        pass  # not yet resolved - leave both cursors exactly as they were
    else:
        if not ready:
            cur["ready_fired"] = False
        if not merge_ready:
            cur["merge_ready_fired"] = False
        if merge_ready and not cur.get("merge_ready_fired"):
            cur["merge_ready_fired"] = True
            cur["ready_fired"] = True
            return ("merge-ready: %s" % _pr_ref(pr), cur)
        if ready and not allow_merge and not cur.get("ready_fired"):
            cur["ready_fired"] = True
            return ("checks-passed: %s" % _pr_ref(pr), cur)

    return (None, cur)


def _pr_ref(pr):
    n = pr.get("number")
    if n:
        return "#%s" % n
    return pr.get("url") or "pr"


def main():
    ap = argparse.ArgumentParser(prog="pr-eval")
    ap.add_argument("--pr-json", required=True)
    ap.add_argument("--review-comments", default="")
    ap.add_argument("--cursor", required=True)
    ap.add_argument("--crew-record", default="")
    ap.add_argument("--me", default="")
    ap.add_argument("--my-crew-id", required=True)
    ap.add_argument("--has-ci-config", action="store_true", default=False)
    ap.add_argument("--check-suites-json", default="")
    args = ap.parse_args()

    pr = read_json(args.pr_json, None)
    if not isinstance(pr, dict):
        return  # no usable PR data (e.g. a transient gh failure) - not an event
    review_comments = read_json(args.review_comments, []) if args.review_comments else []
    crew_record = read_json(args.crew_record, {}) if args.crew_record else {}
    allow_merge = bool(crew_record.get("allow_merge"))
    check_suites_json = read_json(args.check_suites_json, {}) if args.check_suites_json else {}

    with with_locked(args.cursor):
        cursor = read_json(args.cursor, {})
        reason, new_cursor = evaluate(pr, review_comments, cursor, args.me, args.my_crew_id, allow_merge,
                                       args.has_ci_config, check_suites_json)
        write_json(args.cursor, new_cursor)
    if reason:
        print(reason)


if __name__ == "__main__":
    main()
