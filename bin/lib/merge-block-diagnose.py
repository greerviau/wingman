#!/usr/bin/env python3
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""merge-block-diagnose: tell wingman's own merge gate apart from the forge's.

Two independent gates stand between a crew member and a merged PR:
wingman's own `hooks/no-merge-guard.sh` (governed by a crew record's
`allow_merge`/`review_gate_waived` fields), and GitHub's own branch ruleset
or classic branch protection on the default branch. `review_gate_waived`
clears the FIRST gate only - it has zero effect on the second - but until
this tool existed, nothing told a session which gate was actually objecting
before it escalated, so a blocked merge could cost two escalation round
trips where one would do (issue #190).

This tool classifies a blocked/failed merge attempt into one verdict:

  clear        - neither gate objects; the merge should succeed.
  self-fix     - the PR itself needs a fix only the crew member can make
                 (a merge conflict, a branch behind its base, a draft PR).
                 Never an escalation.
  wingman-gate - only wingman's own guard objects.
  forge-gate   - only the forge's branch rules object. Operator-only.
  both-gates   - both object. Operator-only remedy needed for at least part
                 of it.
  unknown      - a verdict-bearing dimension (the PR's own state, the
                 effective branch rules, or the crew record) could not be
                 read; re-run once resolvable rather than guess.

It deliberately does NOT re-implement hooks/no-merge-guard.sh's review-
evidence check (the comment-fallback marker/proof/roster verification is
~200 lines of security-relevant logic - a second, divergent copy would be
worse than no diagnostic at all). Instead it reports the wingman side
conservatively from cheaply-verifiable facts only (`allow_merge`,
`review_gate_waived`, and whether a current distinct-account APPROVED
review exists) and states plainly that the hook itself is authoritative.

Live mode (the default) gathers via `gh`; every gather is independently
fallible and a failure degrades ONLY that dimension - never guessed at as
"no objection" - except for the three dimensions enumerated as verdict-
bearing above, where an unresolvable read forces `verdict: unknown` rather
than a confident wrong answer.

Fixture-injection flags (`--pr-json`, `--rules-json`, `--rulesets-json`,
`--protection-json`, `--crew-record`, `--me`) let every dimension be
supplied canned, in which case no `gh` call is made at all - this is how
tests/merge-block-diagnose.test.sh drives it (the pr-eval.py pattern).

Crew-record resolution is by `delivery` matching the target PR (NOT by
`$WINGMAN_CREW_ID`), because the two call sites that escalate a merge - a
developer's own merge failure, and a lead escalating a WORKER's blocked
merge - are frequently different sessions than the one whose grants matter.
Resolution order: --crew-id override > delivery match (most-recently-
updated wins a tie, with a warning) > $WINGMAN_CREW_ID > none found (which
is itself verdict-bearing - see above, never silently read as "no grants").
"""
import argparse
import json
import os
import re
import subprocess
import sys

SELF_FIX_MAP = {"DIRTY": "conflict", "BEHIND": "behind", "DRAFT": "draft"}

PR_URL_RE = re.compile(r"^https://github\.com/([^/]+)/([^/]+)/pull/(\d+)/?$")


# ---------------------------------------------------------------------------
# gh / fixture gathering
# ---------------------------------------------------------------------------

def run_gh(argv, timeout=20):
    try:
        return subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               timeout=timeout)
    except Exception:
        return None


def read_json_file(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def parse_pr_url(s):
    if not s:
        return None
    m = PR_URL_RE.match(s.strip())
    if not m:
        return None
    return m.group(1), m.group(2), m.group(3)


def gather_pr(args):
    if args.pr_json:
        data = read_json_file(args.pr_json)
        if not isinstance(data, dict):
            return None, "could not read/parse --pr-json fixture at %s" % args.pr_json
        return data, None
    owner_repo = args.repo or None
    parsed = parse_pr_url(args.pr)
    if not owner_repo and parsed:
        owner_repo = "%s/%s" % (parsed[0], parsed[1])
    ref = parsed[2] if parsed else (args.pr or None)
    argv = ["gh", "pr", "view"]
    if ref:
        argv.append(str(ref))
    if owner_repo:
        argv += ["--repo", owner_repo]
    argv += ["--json",
             "number,url,state,isDraft,author,baseRefName,headRefOid,"
             "mergeable,mergeStateStatus,reviewDecision,reviews,statusCheckRollup"]
    r = run_gh(argv)
    if r is None or r.returncode != 0:
        return None, "gh pr view failed"
    try:
        return json.loads(r.stdout.decode()), None
    except Exception:
        return None, "gh pr view returned unparseable JSON"


def gather_rules(args, owner_repo, base_branch):
    if args.rules_json:
        data = read_json_file(args.rules_json)
        if not isinstance(data, list):
            return None, "could not read/parse --rules-json fixture at %s" % args.rules_json
        return data, None
    if not (owner_repo and base_branch):
        return [], None  # nothing to attribute against yet; not itself an error
    r = run_gh(["gh", "api", "repos/%s/rules/branches/%s" % (owner_repo, base_branch)])
    if r is None or r.returncode != 0:
        return None, "gh api rules/branches/%s failed" % base_branch
    try:
        data = json.loads(r.stdout.decode())
        return (data if isinstance(data, list) else []), None
    except Exception:
        return None, "gh api rules/branches/%s returned unparseable JSON" % base_branch


def gather_rulesets(args, owner_repo, objections):
    """Best-effort only (never verdict-bearing - see module docstring)."""
    if args.rulesets_json:
        data = read_json_file(args.rulesets_json)
        return data if isinstance(data, dict) else {}
    result = {}
    ids = {}
    for o in objections:
        rid = o.get("ruleset_id")
        if rid is not None:
            ids[str(rid)] = o.get("ruleset_source_type")
    if not owner_repo:
        return result
    for rid, source_type in ids.items():
        if source_type == "Organization":
            continue  # org name is not resolvable from owner_repo alone; degrades to unknown
        r = run_gh(["gh", "api", "repos/%s/rulesets/%s" % (owner_repo, rid)])
        if r is None or r.returncode != 0:
            continue
        try:
            result[rid] = json.loads(r.stdout.decode())
        except Exception:
            continue
    return result


def gather_protection(args, owner_repo, base_branch):
    """Best-effort only (never verdict-bearing). A 404 ("Branch not
    protected") and a 403 (no admin read) both degrade to {} identically -
    neither contributes a classic-protection objection, which is correct for
    the 404 case and a safe under-report for the 403 case (the ruleset
    endpoint above is the primary source on any repo using rulesets)."""
    if args.protection_json:
        data = read_json_file(args.protection_json)
        return data if isinstance(data, dict) else {}
    if not (owner_repo and base_branch):
        return {}
    r = run_gh(["gh", "api", "repos/%s/branches/%s/protection" % (owner_repo, base_branch)])
    if r is None or r.returncode != 0:
        return {}
    try:
        data = json.loads(r.stdout.decode())
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def gather_me(args):
    if args.me is not None:
        return args.me
    r = run_gh(["gh", "api", "user", "-q", ".login"])
    if r is None or r.returncode != 0:
        return None
    return r.stdout.decode().strip() or None


def gather_roster(args):
    if args.crew_record:
        data = read_json_file(args.crew_record)
        return data if isinstance(data, list) else []
    home = os.environ.get("WINGMAN_HOME") or os.path.expanduser("~/.wingman")
    try:
        with open(os.path.join(home, "crew.json")) as fh:
            data = json.load(fh)
        return data if isinstance(data, list) else []
    except (OSError, ValueError):
        return []


# ---------------------------------------------------------------------------
# crew-record resolution (4.1.1a) - delivery_matches_pr replicated, not
# imported: hooks/no-merge-guard.sh's Python is embedded in a shell heredoc
# ($WM_UV python -c '...', hooks/no-merge-guard.sh:230-236) and is not an
# importable module. Source of truth: hooks/no-merge-guard.sh:411-427
# (delivery_matches_pr). Keep these two in lockstep by hand; a divergence is
# caught by tests/merge-block-diagnose.test.sh asserting all four forms, not
# by import.
# ---------------------------------------------------------------------------

def delivery_matches_pr(delivery, pr_number, pr_url):
    if not delivery:
        return False
    delivery = str(delivery).strip()
    if pr_url and delivery.rstrip("/") == str(pr_url).rstrip("/"):
        return True
    if pr_number is not None:
        target = str(pr_number)
        m = re.search(r"/pull/(\d+)/?$", delivery)
        if m and m.group(1) == target:
            return True
        m = re.search(r"#(\d+)$", delivery)
        if m and m.group(1) == target:
            return True
        if delivery.lstrip("#") == target:
            return True
    return False


def resolve_crew_record(roster, pr_number, pr_url, crew_id_override, env_crew_id):
    """Returns (record_or_None, resolution_desc, warning_line_or_None)."""
    if crew_id_override:
        for r in roster:
            if r.get("id") == crew_id_override:
                return r, "%s (--crew-id)" % crew_id_override, None
        return None, "none found", None
    matches = [r for r in roster if delivery_matches_pr(r.get("delivery"), pr_number, pr_url)]
    if matches:
        warning = None
        if len(matches) > 1:
            chosen = sorted(matches, key=lambda r: r.get("updated") or "", reverse=True)[0]
            ids = ", ".join(str(r.get("id")) for r in matches)
            warning = ("crew-record: warning: %d records match this PR by delivery (%s); "
                       "using `%s` (most recently updated)" % (len(matches), ids, chosen.get("id")))
        else:
            chosen = matches[0]
        return chosen, "%s (matched by delivery)" % chosen.get("id"), warning
    if env_crew_id:
        for r in roster:
            if r.get("id") == env_crew_id:
                return r, "%s (this session)" % env_crew_id, None
    return None, "none found", None


# ---------------------------------------------------------------------------
# forge-side classification (4.1.2)
# ---------------------------------------------------------------------------

def rollup_lookup(status_check_rollup):
    lookup = {}
    for c in status_check_rollup or []:
        if not isinstance(c, dict):
            continue
        name = c.get("name") or c.get("context")
        if name:
            lookup[name] = c
    return lookup


def check_is_success(c):
    if c is None:
        return False  # absent from the rollup entirely counts as objecting (round-1 N2)
    if "conclusion" in c or "status" in c:  # CheckRun
        return (str(c.get("status") or "").upper() == "COMPLETED"
                and str(c.get("conclusion") or "").upper() == "SUCCESS")
    return str(c.get("state") or "").upper() == "SUCCESS"  # StatusContext


def attribute_blocked(pr, rules, protection):
    """mergeStateStatus == BLOCKED: attribute against the effective rules
    (or classic branch protection, when no ruleset rule of that type
    exists), producing one objection dict per attributable cause, or a
    single 'unattributed' objection when nothing accounts for it."""
    objections = []
    review_decision = (pr.get("reviewDecision") or "").upper() or "(none)"

    pr_rule = next((r for r in rules if r.get("type") == "pull_request"), None)
    if pr_rule:
        params = pr_rule.get("parameters") or {}
        count = params.get("required_approving_review_count")
        if count and count >= 1 and review_decision != "APPROVED":
            objections.append({
                "kind": "required-review",
                "count": count,
                "review_decision": review_decision,
                "ruleset_id": pr_rule.get("ruleset_id"),
                "ruleset_source_type": pr_rule.get("ruleset_source_type"),
                "allowed_merge_methods": params.get("allowed_merge_methods"),
                "source": "ruleset",
            })
    elif isinstance(protection.get("required_pull_request_reviews"), dict):
        count = protection["required_pull_request_reviews"].get("required_approving_review_count")
        if count and count >= 1 and review_decision != "APPROVED":
            objections.append({
                "kind": "required-review",
                "count": count,
                "review_decision": review_decision,
                "ruleset_id": None,
                "ruleset_source_type": None,
                "allowed_merge_methods": None,
                "source": "classic",
            })

    rsc_rule = next((r for r in rules if r.get("type") == "required_status_checks"), None)
    if rsc_rule:
        params = rsc_rule.get("parameters") or {}
        required_contexts = [c.get("context") for c in (params.get("required_status_checks") or [])
                              if c.get("context")]
        lookup = rollup_lookup(pr.get("statusCheckRollup"))
        failing = [ctx for ctx in required_contexts if not check_is_success(lookup.get(ctx))]
        if failing:
            objections.append({
                "kind": "required-checks",
                "contexts": failing,
                "ruleset_id": rsc_rule.get("ruleset_id"),
                "ruleset_source_type": rsc_rule.get("ruleset_source_type"),
            })

    if not objections:
        objections.append({"kind": "unattributed"})
    return objections


def current_approving_logins(reviews, head_ref_oid):
    """Distinct logins whose LATEST review state is APPROVED against the
    PR's CURRENT head commit - "current" meaning exactly what
    hooks/no-merge-guard.sh means by it (latest-per-login, issue #138
    staleness): see verify_reviewer_approval there."""
    latest = {}
    for r in reviews or []:
        st = (r.get("state") or "").upper()
        if st not in ("APPROVED", "CHANGES_REQUESTED"):
            continue
        login = ((r.get("author") or {}).get("login")) or ""
        if login:
            latest[login] = r  # gh returns chronological order; last wins
    approving = set()
    for login, r in latest.items():
        if (r.get("state") or "").upper() != "APPROVED":
            continue
        commit_oid = ((r.get("commit") or {}).get("oid") or "").strip().lower()
        if commit_oid and commit_oid == head_ref_oid:
            approving.add(login)
    return approving


def unmeetable_note(objections, pr, me, head_ref_oid):
    """The headline determination: a required-review objection is
    unmeetable-by-construction, not merely unmet, when the PR's own author
    is the authenticated account (every crew session shares one forge login
    - issue #50) and fewer than N distinct logins hold a current approval -
    GitHub structurally refuses self-approval, so no crew-side action can
    ever close that gap (round-1 N6: compares against N, not just "any
    approval exists")."""
    for o in objections:
        if o["kind"] != "required-review":
            continue
        author_login = ((pr.get("author") or {}).get("login")) or ""
        if not me or not author_login or author_login != me:
            return None
        count = o.get("count") or 0
        approving = current_approving_logins(pr.get("reviews") or [], head_ref_oid)
        if len(approving) < count:
            return ("forge: UNMEETABLE - the PR author (%s) is the authenticated account and "
                    "GitHub refuses self-approval; %d of the %d required approving reviews are "
                    "present from any other account. No crew-side action can satisfy this rule."
                    % (author_login, len(approving), count))
        return None
    return None


def merge_method_suggestion(allowed_methods):
    """Read from the pull_request rule's own allowed_merge_methods, never
    hardcoded - suggesting a method the ruleset forbids would reproduce the
    same class of failure this issue is about. An absent key means GitHub
    permits every method, so a suggestion is still produced (--squash)."""
    if not allowed_methods:
        return "--squash"
    for pref in ("squash", "merge", "rebase"):
        if pref in allowed_methods:
            return "--" + pref
    return "--squash"


# ---------------------------------------------------------------------------
# wingman-side classification (4.1.2) - conservative, cheaply-verifiable
# facts only. See module docstring: this deliberately does NOT re-implement
# hooks/no-merge-guard.sh's comment-fallback evidence check.
# ---------------------------------------------------------------------------

def wingman_objections(record, reviews, head_ref_oid):
    """Returns a list of objection dicts. Caller treats an empty list as
    'wingman side clear'. Assumes `record` is not None - a None record is
    the crew-record-unresolvable case, handled separately by the caller
    (that dimension is itself verdict-bearing, unlike this function's own
    conclusions)."""
    if not bool(record.get("allow_merge")):
        return [{"kind": "no-allow-merge"}]
    if bool(record.get("review_gate_waived")):
        return []

    latest = {}
    for r in reviews or []:
        st = (r.get("state") or "").upper()
        if st not in ("APPROVED", "CHANGES_REQUESTED"):
            continue
        login = ((r.get("author") or {}).get("login")) or ""
        if login:
            latest[login] = r
    current = {}
    stale = {}
    for login, r in latest.items():
        if (r.get("state") or "").upper() != "APPROVED":
            continue
        commit_oid = ((r.get("commit") or {}).get("oid") or "").strip().lower()
        if commit_oid and commit_oid == head_ref_oid:
            current[login] = commit_oid
        else:
            stale[login] = commit_oid

    if current:
        return []
    if stale:
        login, commit_oid = next(iter(stale.items()))
        return [{
            "kind": "review-evidence-likely-stale",
            "login": login,
            "commit_oid": commit_oid or "unknown",
            "head_ref_oid": head_ref_oid or "unknown",
        }]
    return [{"kind": "review-evidence-likely-missing"}]


# ---------------------------------------------------------------------------
# output formatting
# ---------------------------------------------------------------------------

def forge_objection_line(o, rulesets):
    kind = o["kind"]
    if kind == "conflict":
        return "forge: conflict - the base moved; rebase or merge the default branch in."
    if kind == "behind":
        return "forge: behind - update the branch."
    if kind == "draft":
        return "forge: draft - mark the PR ready for review."
    if kind == "required-review":
        if o.get("source") == "classic" or o.get("ruleset_id") is None:
            where = "classic branch protection"
        else:
            detail = rulesets.get(str(o.get("ruleset_id")))
            name = detail.get("name") if detail else str(o.get("ruleset_id"))
            where = 'ruleset "%s" (%s)' % (name, o.get("ruleset_source_type") or "Repository")
        plural = "" if o.get("count") == 1 else "s"
        return ("forge: required-review - %s requires %s approving review%s; reviewDecision=%s"
                % (where, o.get("count"), plural, o.get("review_decision")))
    if kind == "required-checks":
        return ("forge: required-checks - required status check(s) not passing: "
                + ", ".join(o.get("contexts") or []))
    if kind == "unattributed":
        return ("forge: unattributed - mergeStateStatus=BLOCKED but no rule in the effective "
                "rules or classic branch protection accounts for it.")
    return "forge: %s" % kind


def wingman_objection_line(o, record):
    kind = o["kind"]
    rid = record.get("id") if record else "?"
    if kind == "no-allow-merge":
        return "wingman: no-allow-merge - allow_merge is not true on crew record `%s`." % rid
    if kind == "review-evidence-likely-missing":
        return ("wingman: review-evidence-likely-missing - allow_merge=true, "
                "review_gate_waived=false, no current distinct-account APPROVED review. "
                "hooks/no-merge-guard.sh is authoritative; a marker-anchored reviewer "
                "comment-fallback verdict is not evaluated here.")
    if kind == "review-evidence-likely-stale":
        return ("wingman: review-evidence-likely-stale - %s's APPROVED review was submitted "
                "against commit %s, but the PR's current head is now %s."
                % (o["login"], o["commit_oid"][:12], o["head_ref_oid"][:12]))
    return "wingman: %s" % kind


def bypass_lines(objections, rulesets):
    lines = []
    seen = set()
    for o in objections:
        rid = o.get("ruleset_id")
        if rid is None:
            continue
        key = str(rid)
        if key in seen:
            continue
        seen.add(key)
        detail = rulesets.get(key)
        if not detail:
            lines.append("bypass: unknown - could not read ruleset %s" % rid)
            continue
        name = detail.get("name") or key
        cub = detail.get("current_user_can_bypass")
        if cub == "always":
            lines.append('bypass: AVAILABLE - current_user_can_bypass=always on ruleset "%s"' % name)
        else:
            lines.append('bypass: BLOCKED - current_user_can_bypass=%s on ruleset "%s"'
                          % (cub or "unknown", name))
    return lines


def remedy_forge_line(objections, rulesets):
    method = "--squash"
    any_available = False
    for o in objections:
        if o["kind"] == "required-review":
            method = merge_method_suggestion(o.get("allowed_merge_methods"))
        rid = o.get("ruleset_id")
        if rid is not None:
            detail = rulesets.get(str(rid))
            if detail and detail.get("current_user_can_bypass") == "always":
                any_available = True
    if any_available:
        caveat = ("Option (a) is available to this account now (see bypass, above) but is NOT "
                  "self-authorizing - it still needs the grants under remedy-wingman.")
    else:
        caveat = "Option (a)'s availability for this account is unknown or unavailable (see bypass, above)."
    return ("remedy-forge: operator-only. Either (a) the operator authorizes an admin override "
            "and this session merges with `gh pr merge %s --admin`, (b) a second, genuinely "
            "distinct reviewer credential approves the PR, or (c) the operator relaxes the "
            "ruleset. %s" % (method, caveat))


def remedy_wingman_line(wobjs):
    kinds = {o["kind"] for o in wobjs}
    parts = []
    if "no-allow-merge" in kinds:
        parts.append("ask the requester/lead to grant allow_merge for this effort")
    if kinds & {"review-evidence-likely-missing", "review-evidence-likely-stale"}:
        parts.append("ask the requester/lead for review_gate_waived for this effort, or obtain "
                      "a genuine separate reviewer approval")
    if not parts:
        parts.append("no wingman-side objection")
    return "remedy-wingman: " + "; ".join(parts) + "."


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def build_arg_parser():
    ap = argparse.ArgumentParser(
        prog="merge-block-diagnose",
        description="Classify a blocked/failed PR merge as wingman's own gate objecting, "
                     "the forge's own branch rules, both, or neither - see "
                     "docs/guards.md's 'Two merge gates, not one'.")
    ap.add_argument("--pr", default="", help="PR URL, or a bare number when --repo is also given")
    ap.add_argument("--repo", default="", help="owner/name; required in live mode with a bare PR number")
    ap.add_argument("--crew-id", default="", help="resolve the crew record by this id, overriding delivery matching")
    ap.add_argument("--pr-json", default="", help="fixture: gh pr view --json ... output")
    ap.add_argument("--rules-json", default="", help="fixture: gh api rules/branches/<base> output")
    ap.add_argument("--rulesets-json", default="", help="fixture: {ruleset_id: ruleset-detail} object")
    ap.add_argument("--protection-json", default="", help="fixture: gh api branches/<base>/protection output")
    ap.add_argument("--crew-record", default="", help="fixture: the whole roster (crew.json shape)")
    ap.add_argument("--me", default=None, help="fixture: the authenticated login")
    return ap


def main():
    args = build_arg_parser().parse_args()

    # 4.1.1b: live mode must not guess the repo from cwd. A full PR URL, or
    # --repo alongside a bare number, is required whenever a live gh call
    # would actually be needed (i.e. the two verdict-bearing gh-backed
    # fixtures - pr and rules - are not BOTH already supplied). No gh call
    # is attempted before this check.
    need_repo = not (args.pr_json and args.rules_json)
    owner_repo = args.repo or None
    if not owner_repo:
        parsed = parse_pr_url(args.pr)
        if parsed:
            owner_repo = "%s/%s" % (parsed[0], parsed[1])
    if need_repo and not owner_repo:
        sys.stderr.write(
            "error: live mode needs a full PR URL (https://github.com/<owner>/<repo>/pull/<n>) "
            "or --repo <owner>/name alongside --pr <number> - refusing to guess the repo from "
            "the working directory (issue #190 round-1 finding N1)\n")
        sys.exit(2)

    pr, pr_err = gather_pr(args)
    if pr_err:
        print("verdict: unknown")
        print("pr: %s - re-run this diagnostic once resolvable." % pr_err)
        sys.exit(2)

    if not owner_repo:
        parsed2 = parse_pr_url(pr.get("url") or "")
        if parsed2:
            owner_repo = "%s/%s" % (parsed2[0], parsed2[1])

    base_branch = pr.get("baseRefName")
    head_ref_oid = (pr.get("headRefOid") or "").strip().lower()
    merge_state = (pr.get("mergeStateStatus") or "UNKNOWN").upper()
    pr_state_unknown = merge_state == "UNKNOWN"

    rules, rules_err = gather_rules(args, owner_repo, base_branch)
    protection = gather_protection(args, owner_repo, base_branch)
    me = gather_me(args)
    roster = gather_roster(args)

    objections = []
    forge_class = "none"
    if not pr_state_unknown and not rules_err:
        if merge_state in SELF_FIX_MAP:
            forge_class = "self-fix"
            objections = [{"kind": SELF_FIX_MAP[merge_state]}]
        elif merge_state == "BLOCKED":
            forge_class = "operator-only"
            objections = attribute_blocked(pr, rules or [], protection)
        else:
            forge_class = "none"  # CLEAN / HAS_HOOKS / UNSTABLE, or an unrecognized value

    rulesets = gather_rulesets(args, owner_repo, objections)

    crew_record, resolution_desc, multi_warning = resolve_crew_record(
        roster, pr.get("number"), pr.get("url"), args.crew_id,
        os.environ.get("WINGMAN_CREW_ID") or "")
    if crew_record is None:
        wobjs, wingman_state = [], "unknown"
    else:
        wobjs = wingman_objections(crew_record, pr.get("reviews") or [], head_ref_oid)
        wingman_state = "some" if wobjs else "none"

    # Exactly three dimensions are verdict-bearing (round-1 M4): PR state,
    # effective branch rules, crew record. Everything else (ruleset detail,
    # classic protection, authenticated login) degrades in place above,
    # never touching the verdict.
    unresolved = pr_state_unknown or bool(rules_err) or wingman_state == "unknown"

    if unresolved:
        verdict, exit_code = "unknown", 2
    elif forge_class == "self-fix":
        verdict, exit_code = "self-fix", 1
    elif forge_class == "operator-only":
        verdict = "both-gates" if wingman_state == "some" else "forge-gate"
        exit_code = 1
    elif wingman_state == "some":
        verdict, exit_code = "wingman-gate", 1
    else:
        verdict, exit_code = "clear", 0

    lines = ["verdict: %s" % verdict]
    lines.append("pr: %s (%s, mergeStateStatus=%s, reviewDecision=%s)"
                  % (pr.get("url") or ("#%s" % pr.get("number") if pr.get("number") else "?"),
                     pr.get("state") or "?", merge_state, pr.get("reviewDecision") or "none"))
    if pr_state_unknown:
        lines.append("pr: mergeStateStatus is UNKNOWN - GitHub is still computing mergeability; "
                      "re-run this diagnostic in a moment.")
    if rules_err:
        lines.append("rules: %s - re-run this diagnostic once resolvable." % rules_err)

    if multi_warning:
        lines.append(multi_warning)
    lines.append("crew-record: %s" % resolution_desc)

    for o in objections:
        lines.append(forge_objection_line(o, rulesets))
    um = unmeetable_note(objections, pr, me, head_ref_oid)
    if um:
        lines.append(um)

    for o in wobjs:
        lines.append(wingman_objection_line(o, crew_record))
    if crew_record is None:
        lines.append("wingman: unknown - no matching crew record could be resolved; see crew-record above.")

    for bl in bypass_lines(objections, rulesets):
        lines.append(bl)

    if forge_class == "operator-only":
        lines.append(remedy_forge_line(objections, rulesets))
    if wingman_state == "some":
        lines.append(remedy_wingman_line(wobjs))
    if forge_class == "operator-only":
        lines.append("note: `review_gate_waived` clears ONLY the wingman line above. It has no "
                      "effect on the forge line.")

    print("\n".join(lines))
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
