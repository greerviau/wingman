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
                            mergeable,mergeStateStatus`
  --review-comments <path>  a JSON array of inline review-thread comments
                            (`gh api repos/{owner}/{repo}/pulls/{n}/comments`), optional
  --cursor <path>           the on-disk cursor of what has already been surfaced
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

It prints ONE reason line and advances the cursor for exactly that dimension, or
prints nothing when there is no new event. Priority (highest first):

  merged > closed > changes-requested > ci-failed > conflict > comment > checks-passed

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
"""
import argparse
import json
import re
import sys

# CheckRun conclusions that count as a failure the crew should fix. NEUTRAL,
# SKIPPED, STALE and SUCCESS are not failures; QUEUED/IN_PROGRESS have no
# conclusion yet (still pending).
FAIL_CONCLUSIONS = {"FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"}
# StatusContext states that count as a failure.
FAIL_STATES = {"ERROR", "FAILURE"}


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
    in PENDING/EXPECTED."""
    for c in pr.get("statusCheckRollup") or []:
        if not isinstance(c, dict):
            continue
        if "conclusion" in c or "status" in c:  # CheckRun
            if str(c.get("status") or "").upper() != "COMPLETED":
                return True
        elif str(c.get("state") or "").upper() in ("PENDING", "EXPECTED"):  # StatusContext
            return True
    return False


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


def evaluate(pr, review_comments, cursor, me, my_crew_id):
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

    # checks-passed: the PR has settled with nothing failing, nothing pending, and
    # mergeable (all-green, or no CI at all - and no open conflict). Fire once per
    # settle so the member moves into `review`; a later pending/failing/conflicting
    # reading re-arms it for the next recovery.
    ready = (not fail) and (not checks_pending(pr)) and mergeability == "MERGEABLE"
    if mergeability == "UNKNOWN":
        pass  # not yet resolved - leave ready_fired exactly as it was
    elif not ready:
        cur["ready_fired"] = False
    elif not cur.get("ready_fired"):
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
    ap.add_argument("--me", default="")
    ap.add_argument("--my-crew-id", required=True)
    args = ap.parse_args()

    pr = read_json(args.pr_json, None)
    if not isinstance(pr, dict):
        return  # no usable PR data (e.g. a transient gh failure) - not an event
    review_comments = read_json(args.review_comments, []) if args.review_comments else []
    cursor = read_json(args.cursor, {})

    reason, new_cursor = evaluate(pr, review_comments, cursor, args.me, args.my_crew_id)
    write_json(args.cursor, new_cursor)
    if reason:
        print(reason)


if __name__ == "__main__":
    main()
