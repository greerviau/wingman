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
                            state,mergedAt,statusCheckRollup,reviews,comments,number,url`
  --review-comments <path>  a JSON array of inline review-thread comments
                            (`gh api repos/{owner}/{repo}/pulls/{n}/comments`), optional
  --cursor <path>           the on-disk cursor of what has already been surfaced
  --me <login>              the authenticated forge login, so the crew's OWN
                            comments/reviews never wake it (avoids a reply loop)

It prints ONE reason line and advances the cursor for exactly that dimension, or
prints nothing when there is no new event. Priority (highest first):

  merged > closed > changes-requested > ci-failed > comment > checks-passed

Only the fired dimension's cursor advances, so a co-occurring event of lower
priority still surfaces on the next poll instead of being skipped. A CI rollup
that has gone green resets the ci cursor (a later failure re-fires); a pending or
unchanged-failing rollup is not an event.

`checks-passed` fires once when the PR has nothing failing and nothing pending -
covering both an all-green rollup and a repo with no CI at all - so a member that
stays `working` through CI is woken to move into `review` the moment it settles.
It sits below `comment` so unaddressed feedback is handled before the member parks,
and it re-arms (fires again) once checks return to pending/failing and settle anew.
"""
import argparse
import json
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


def _login(item):
    a = item.get("author") or item.get("user") or {}
    if isinstance(a, dict):
        return a.get("login") or ""
    return a or ""


def _ts(item):
    return item.get("submittedAt") or item.get("createdAt") or item.get("created_at") or ""


def conversation(pr, review_comments, me):
    """Every conversation item as (ts, kind, login). kind is 'review' (a submitted
    review, carrying its state) or 'comment'. The crew's own items are dropped so a
    reply never wakes it."""
    items = []
    for r in pr.get("reviews") or []:
        st = str(r.get("state") or "").upper()
        if st in ("PENDING",):
            continue
        items.append((_ts(r), "review:" + st, _login(r)))
    for c in pr.get("comments") or []:
        items.append((_ts(c), "comment", _login(c)))
    for c in review_comments or []:
        items.append((_ts(c), "comment", _login(c)))
    return [(ts, kind, who) for (ts, kind, who) in items if ts and who != me]


def evaluate(pr, review_comments, cursor, me):
    """Return (reason_or_None, new_cursor)."""
    cur = dict(cursor) if isinstance(cursor, dict) else {}
    cur.setdefault("ci", "")
    # First run: treat conversation already present as seen (so we don't fire on
    # the crew's own PR-open state), but leave ci empty so an already-red build
    # still fires.
    convo = conversation(pr, review_comments, me)
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

    if fresh:
        cur["conv_hwm"] = convo_max
        return ("comment: %s %d new" % (_pr_ref(pr), len(fresh)), cur)

    # checks-passed: the PR has settled with nothing failing and nothing pending
    # (all-green, or no CI at all). Fire once per settle so the member moves into
    # `review`; a later pending/failing rollup re-arms it for the next recovery.
    ready = (not fail) and (not checks_pending(pr))
    if not ready:
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
    args = ap.parse_args()

    pr = read_json(args.pr_json, None)
    if not isinstance(pr, dict):
        return  # no usable PR data (e.g. a transient gh failure) - not an event
    review_comments = read_json(args.review_comments, []) if args.review_comments else []
    cursor = read_json(args.cursor, {})

    reason, new_cursor = evaluate(pr, review_comments, cursor, args.me)
    write_json(args.cursor, new_cursor)
    if reason:
        print(reason)


if __name__ == "__main__":
    main()
