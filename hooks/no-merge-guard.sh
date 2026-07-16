#!/usr/bin/env bash
# no-merge-guard.sh - a Claude Code PreToolUse hook (matcher "Bash").
# Mechanically enforces issue #46's requirement: "crew must never merge a PR
# unless the pilot explicitly grants merge autonomy for that effort." Two
# things silently made this true before (nobody had asked for it, and the
# convention was only ever prose in a playbook); this hook makes it
# structurally true instead.
#
# What is denied, for every crew session (WINGMAN_CREW_ID set) by default:
#   - `gh pr merge` (any flags: --merge/--squash/--rebase/--admin/--auto/...).
#   - `gh api` hitting the REST merge endpoint with an explicit PUT method
#     (repos/{owner}/{repo}/pulls/{number}/merge) - a GET on the same path
#     only reads merge status and is left alone.
#   - `gh api graphql` carrying a `mergePullRequest(` mutation.
#   - `git push` whose destination resolves to the repository's default
#     branch (origin/HEAD if resolvable, else the conventional main/master
#     pair) - landing commits on the trunk branch directly is the same
#     merge-equivalent action as pressing the merge button, whether or not a
#     PR exists for them. Pushing a crew member's own feature branch (the
#     normal `developer` "Publish" step) is unaffected: only a push whose
#     resolved destination IS the default branch trips this. The directory
#     used to resolve that destination is not unconditionally the hook
#     payload's own cwd: a `cd <path>` (or `git -C <path>`) earlier in the
#     SAME command chain is tracked and takes precedence, since the payload
#     cwd can name an unrelated checkout of the same repo (a worktree) that
#     sits on a different branch (issue #117).
#
# What lifts the deny: the crew member's own crew.json record carries
# `"allow_merge": true` - set only via `wm-state.py crew-set --id <id>
# --allow-merge true`, itself gated below (see check_allow_merge_grant) so
# that only wingman's own top-level session or a lead (granting to one of
# its OWN workers, never itself) can set it - never the crew member on its
# own id. This is deliberately a live per-effort record, not a spawn-time-only
# env var: the pilot saying "you may merge this one" mid-session must not
# require respawning the developer to take effect, and the record is what
# `bin/crew-list` / board.md make visible for audit, satisfying the "explicit,
# per-effort, and visible" requirement from issue #46 without a hidden
# global switch.
#
# issue #132: `allow_merge: true` alone is no longer sufficient. Because every
# crew session authenticates as the same forge account (issue #50), a
# developer granted merge autonomy could post its own comment-fallback
# `VERDICT: approve` (the same shape a genuinely separate reviewer crew
# member uses - see playbooks/software-development/reviewer.md) and treat
# that as satisfying an effort's own "merge once genuinely reviewed"
# instruction - nothing mechanical stopped it. Once `allow_merge` is granted,
# this hook now ALSO requires verifiable evidence of a genuinely separate
# approving review before letting a merge-equivalent proceed:
#   - a real `APPROVED` review state (any author) - GitHub itself refuses this
#     from the PR's own author, so its mere presence is structurally
#     guaranteed to be a different account; or
#   - a same-login comment-fallback verdict (`COMMENTED`, marker-anchored
#     `<!-- wingman-crew:<id> -->`, `VERDICT: approve`) whose `<id>` is NOT
#     this session's own, and resolves to a real roster record with
#     `type == "reviewer"` and a `delivery` naming this same PR - and, when
#     that record carries a spawn-time review-token commitment (issue #135,
#     see below), a matching `wingman-review-proof` marker in the same
#     comment.
# `review_gate_waived: true` (mirroring `allow_merge`'s own grant shape and
# actor restriction exactly - see check_review_gate_waiver_grant) is the
# explicit, per-effort escape hatch for a requester who has personally
# examined the diff and wants no review round at all. This evidence check
# calls `gh pr view` live (see fetch_reviews) - a security-relevant gate, so a
# resolution failure (network hiccup, unresolvable PR/node id) fails CLOSED
# (denied), unlike hooks/merge-attribution-tracker.sh's best-effort posture.
#
# issue #132 review (PR #134): the evidence check above trusts a roster
# record's `type`/`delivery` fields (crew.json/crew-archive.jsonl) to tell a
# genuine reviewer's comment-fallback approve from a self-dealing one - but
# the FIRST version of this hook left the write paths to those exact fields
# ungated, so the sessions it polices could write the state it trusts. Two
# reproduced bypasses, same root cause:
#   1. `wm-state crew-add` dedups by id (re-adding an existing id silently
#      replaces the whole record), and check_allow_merge_grant/check_review_
#      gate_waiver_grant only ever inspected `crew-set` segments - so a
#      developer could re-add its OWN record with `--allow-merge
#      --waive-review-gate` and merge unreviewed, bypassing the self-grant
#      restriction entirely.
#   2. `crew-add --type reviewer` (to mint a new id) plus `crew-set
#      --delivery <this PR>` (to point it at the PR being merged) were both
#      similarly ungated, so a developer could fabricate a `type: reviewer`
#      roster record with no real, independently-spawned session behind it,
#      post the marker verdict itself under that forged id, and have the
#      evidence check treat it as genuine.
# check_crew_add_restriction() and check_crew_set_delivery_restriction()
# close both: `wm-state crew-add` is grep-confirmed to be called from exactly
# one place in this codebase (bin/spawn-crew, on behalf of wingman or a lead
# spawning one of its own NEW workers) - so ANY crew-add from a live crew
# session is now denied outright, not just the merge-flag-carrying ones. This
# alone closes bypass 1 (crew-add can no longer replace one's own record at
# all) and the minting half of bypass 2 (a fresh sockpuppet id can no longer
# be created either). `--delivery` gets its own restriction (self-id, or
# wingman, only - every legitimate delivery report in this codebase is
# self-targeted, see playbooks/_status-contract.md) closing the remaining
# half of bypass 2: repointing an *existing* other id's delivery at this PR.
#
# issue #136 (round-2 review of PR #134): verify_reviewer_approval() also
# trusts a roster record's `type` field (must equal "reviewer") - exactly as
# security-relevant as `delivery`, but left ungated. check_crew_set_type_
# restriction() extends the identical self/wingman restriction already
# applied to `--delivery` to `--type` for the same reason. `crew-set` does
# not currently define a `--type` flag at all (wm-state.py's crew-add
# subparser is the only place `--type` is accepted, at creation time), so
# this closes a write path pre-emptively rather than one that's reachable
# today - defense-in-depth against a future `crew-set --type` addition
# silently inheriting an ungated write path.
#
# issue #135: even a genuine `type == reviewer` record with a `delivery`
# naming this PR was not enough - shape 2 has no cryptographic binding at
# all, so any crew session that knows a genuine reviewer's id and the PR
# number (both visible via bin/crew-list/board.md and the PR thread itself)
# could post a LATER `COMMENTED` `VERDICT: approve` bearing that reviewer's
# marker, overriding the real reviewer's verdict ("latest wins"). Closed with
# a spawn-time, per-verdict one-way hash commitment: `bin/spawn-crew` mints a
# random 32-byte token for every `--type reviewer` spawn, held only in that
# member's own process environment (`WM_REVIEW_TOKEN`, never written to any
# file); `wm-state crew-add` derives and stores only
# `sha256(sha256(token||id||verdict))` for each of "approve"/"request
# changes" (`review_commit_approve`/`review_commit_request_changes`); the
# reviewer embeds the *preimage* (`$WINGMAN_STATE review-sign --verdict ...`)
# in a second marker line in its own comment; this hook now requires that
# preimage to hash to the recorded commitment before trusting a `VERDICT:
# approve` from a record that carries one. A record with no commitment on
# file (predates this fix, or was hand-spawned with no token) falls straight
# through to the pre-issue-#135 marker-only acceptance, unchanged. The
# commitment is re-derived whenever a live reviewer's `delivery` is
# genuinely repointed at a different PR (`review_delivery_bound`, a
# dedicated monotonic roster field immune to an intervening `--delivery ""`
# clear) so a proof genuinely posted for one PR cannot keep validating
# against another, and whenever `bin/crew-resume` relaunches a `died`
# reviewer (`--regenerate-review-token`, gated below identically to
# `--allow-merge`/`--review-gate-waived` - see
# check_regenerate_review_token_grant) since the crashed process's token is
# unrecoverable. See `bin/lib/wm-state.py`'"'"'s `_apply_review_token` and
# `docs/analysis/2026-07-16-issue-135-review-evidence-forgery-plan.md` for
# the full design and its threat-model boundary (a genuinely snooping peer
# session on this shared-OS-user architecture is explicitly out of scope -
# see that plan's "constraint that shapes every option" section).
#
# The `--allow-merge` grant check does NOT rely on cmd_match.py resolving the
# call to `wm-state.py` (unlike every other hook in this repo): the
# documented invocation shape is `$WINGMAN_STATE crew-set --id ... `, and
# `$WINGMAN_STATE` arrives at a PreToolUse hook as an unexpanded literal
# token (see issue #49) - resolve_command has no way to see through it today.
# Rather than depend on cmd_match's fix landing first (issue #49 / PR #48 are
# both touching hooks/lib/cmd_match.py concurrently with this hook), the
# grant check matches on token presence within a segment (`crew-set` and
# `--allow-merge` appearing anywhere in it) instead of resolving argv[0] at
# all - correct regardless of how $WINGMAN_STATE is spelled, and it never
# collides with cmd_match.py's own file.
#
# Registered user-level by bin/doctor (crew sessions have their project root
# in other repos, where this repo's project settings never load) - same
# reasoning as the delegation guard and the Artifact-publish contract hooks.
# bash-3.2-safe.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
WM_UV="${WM_UV:-uv run --no-project --quiet}"

INPUT="$(cat)"

# Cheap no-op gate: only a command mentioning one of these words can possibly
# match anything below (gh pr merge / gh api .../merge / mergePullRequest all
# contain "merge"; git push contains "push"; the grant-guards need
# "allow-merge" and "review-gate" respectively; the roster-integrity guards
# (issue #132 review) need "crew-add" and "--delivery" - a bare `crew-add
# --type reviewer ...` or `crew-set --delivery ...` carries none of the other
# trigger words; the review-token grant guard (issue #135) needs
# "review-token", covering both `crew-add --review-token` and `crew-set
# --regenerate-review-token`). Precise matching happens in the python block.
#
# issue #136: `crew-set --type` gets its own, narrower arm rather than being
# folded into the bare-alternative list above. Unlike every other trigger
# word here, a bare `*--type*` alternative would NOT be purely additive:
# `--type` is a common flag on many unrelated CLI tools crew members
# legitimately run in arbitrary repos (e.g. `kubectl ... --type=Opaque`), and
# this hook is registered user-level, firing for every crew Bash call in
# every repo, not just wingman's own. A bare `*--type*` alternative would
# newly expose any unrelated, unparseable command containing `--type` (e.g. a
# quoting slip in an otherwise ordinary kubectl/config-tool invocation) to
# the fail-closed PARSE_FAIL_REASON denial below, despite having nothing to
# do with crew-set, merges, or PRs. Requiring `crew-set` and `--type` to both
# appear (in either order) keeps the pre-gate scoped to actual crew-set
# calls, exactly as tightly as the other trigger words already are.
case "$INPUT" in
  *merge*|*push*|*allow-merge*|*review-gate*|*crew-add*|*--delivery*|*review-token*) ;;
  *crew-set*--type*) ;;
  *) exit 0 ;;
esac

printf '%s' "$INPUT" | \
  WINGMAN_HOME="${WINGMAN_HOME:-$HOME/.wingman}" \
  WINGMAN_CREW_ID="${WINGMAN_CREW_ID:-}" \
  WINGMAN_CREW_TYPE="${WINGMAN_CREW_TYPE:-}" \
  PYTHONPATH="$HERE/lib${PYTHONPATH:+:$PYTHONPATH}" $WM_UV python -c '
import hashlib, json, os, re, subprocess, sys

from cmd_match import command_segments, resolve_command

try:
    data = json.load(sys.stdin)
except Exception:
    data = {}

if data.get("tool_name") != "Bash":
    sys.exit(0)

tool_input = data.get("tool_input", {}) or {}
command = tool_input.get("command", "") or ""
cwd = data.get("cwd") or os.getcwd()
crew_id = os.environ.get("WINGMAN_CREW_ID", "")
crew_type = os.environ.get("WINGMAN_CREW_TYPE", "")
home = os.path.expanduser(os.environ.get("WINGMAN_HOME") or "~/.wingman")


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


# cmd_match.py fails CLOSED on a command it cannot fully lex (issue #56):
# command_segments() returns None rather than a partial, truncated segment
# list. Computed once, up front, and passed to check_allow_merge_grant()/
# check_merge_paths() as `segments or []` so their own known-shape detection
# (and early returns) run unchanged; only after BOTH have had their chance to
# deny on a specific recognized shape does the fallback below deny generically
# on an unresolvable command that reached this hook'"'"'s substring pre-gate.
segments = command_segments(command)


def flag_value(tokens, *names):
    for i, tok in enumerate(tokens):
        if tok in names and i + 1 < len(tokens):
            return tokens[i + 1]
        for name in names:
            if tok.startswith(name + "="):
                return tok[len(name) + 1:]
    return None


def own_roster_record():
    if not crew_id:
        return None
    try:
        with open(os.path.join(home, "crew.json")) as fh:
            roster = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(roster, list):
        return None
    for r in roster:
        if r.get("id") == crew_id:
            return r
    return None


def allow_merge_granted():
    r = own_roster_record()
    return bool(r and r.get("allow_merge"))


def review_gate_waived():
    r = own_roster_record()
    return bool(r and r.get("review_gate_waived"))


# ---------------------------------------------------------------------------
# issue #132: verifiable evidence of a genuinely separate approving review.
# ---------------------------------------------------------------------------

CREW_MARKER_RE = re.compile(r"^\s*<!--\s*wingman-crew:([A-Za-z0-9._-]+)\s*-->")
VERDICT_RE = re.compile(r"VERDICT:\s*(approve|request changes)", re.IGNORECASE)
# issue #135: the spawn-time hash-commitment proof a genuine reviewer embeds
# alongside its marker (playbooks/software-development/reviewer.md step 4,
# via `$WINGMAN_STATE review-sign`) - a 64-hex-char sha256 preimage. Required
# on a VERDICT: approve comment only when the resolved roster record carries
# a review_commit_approve commitment (see the shape-2 loop below); absent
# entirely, this falls through to the pre-issue-#135 marker-only check.
PROOF_MARKER_RE = re.compile(r"<!--\s*wingman-review-proof:([0-9a-fA-F]{64})\s*-->")

NODE_TO_PR_QUERY = (
    "query($id:ID!){node(id:$id){... on PullRequest{number repository{"
    "owner{login} name}}}}"
)


def run_gh(argv, exec_cwd, timeout=20):
    try:
        return subprocess.run(argv, cwd=exec_cwd, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, timeout=timeout)
    except Exception:
        return None


def resolve_current_pr_ref(exec_cwd):
    r = run_gh(["gh", "pr", "view", "--json", "number", "-q", ".number"], exec_cwd)
    if r is None or r.returncode != 0:
        return None
    out = r.stdout.decode().strip()
    return out or None


def resolve_graphql_pr(node_id, exec_cwd):
    r = run_gh(["gh", "api", "graphql", "-f", "query=" + NODE_TO_PR_QUERY,
                "-f", "id=" + node_id], exec_cwd)
    if r is None or r.returncode != 0:
        return None, None
    try:
        node = json.loads(r.stdout.decode())["data"]["node"]
        number = str(node["number"])
        owner_repo = "%s/%s" % (node["repository"]["owner"]["login"],
                                 node["repository"]["name"])
        return owner_repo, number
    except Exception:
        return None, None


def fetch_reviews(owner_repo, ref, exec_cwd):
    argv = ["gh", "pr", "view"]
    if ref:
        argv.append(str(ref))
    if owner_repo:
        argv += ["--repo", owner_repo]
    argv += ["--json", "reviews,number,url"]
    r = run_gh(argv, exec_cwd)
    if r is None or r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout.decode())
    except Exception:
        return None


def find_roster_record(rid, home_dir):
    # crew.json first (the common, still-live case)...
    try:
        with open(os.path.join(home_dir, "crew.json")) as fh:
            roster = json.load(fh)
        if isinstance(roster, list):
            for r in roster:
                if r.get("id") == rid:
                    return r
    except (OSError, ValueError):
        pass
    # ...falling back to crew-archive.jsonl for a reviewer already stood down
    # and pruned. Append-only, one JSON object per line; the LAST matching
    # line wins (an id could in principle be reused across time).
    found = None
    try:
        with open(os.path.join(home_dir, "crew-archive.jsonl")) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if rec.get("id") == rid:
                    found = rec
    except OSError:
        pass
    return found


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


def no_evidence_reason(pr_number, pr_url, issues):
    target = pr_url or ("PR #%s" % pr_number if pr_number else "this PR")
    parts = [
        "No verifiable evidence of a genuinely separate approving review was "
        "found for %s (issue #132) - allow_merge alone no longer permits a "
        "merge." % target
    ]
    if issues:
        parts.append("Found: " + "; ".join(issues) + ".")
    parts.append(
        "Get a real, independently-spawned `reviewer` crew member to approve "
        "this PR (a genuine APPROVED review, or its documented comment-"
        "fallback `VERDICT: approve` with a matching roster record and "
        "delivery - see playbooks/software-development/reviewer.md), or ask "
        "the requester/lead to grant review_gate_waived for this effort if no "
        "review round is actually wanted (never settable by this session on "
        "itself): $WINGMAN_STATE crew-set --id %s --review-gate-waived true"
        % (crew_id or "<this-crew-id>")
    )
    return " ".join(parts)


def unresolved_pr_reason(detail):
    return (
        "Could not verify review evidence for this merge attempt (issue "
        "#132): %s Denied out of caution rather than allowed unchecked - this "
        "is a security-relevant gate, not a best-effort attribution comment. "
        "Retry once resolvable, or ask the requester/lead to grant "
        "review_gate_waived for this effort if no review round is actually "
        "wanted." % detail
    )


def verify_reviewer_approval(pr_json):
    reviews = pr_json.get("reviews") or []
    pr_number = pr_json.get("number")
    pr_url = pr_json.get("url") or ""

    # Shape 1: a real APPROVED review, any author. GitHub refuses this from
    # the PR'"'"'s own author, so an APPROVED/CHANGES_REQUESTED state can only
    # ever come from a genuinely different account already - no marker/roster
    # check needed. Only the LATEST state per author login counts (PR #134
    # review, minor finding): `any(APPROVED)` alone would let a stale approve
    # stay load-bearing even after that SAME reviewer later requested
    # changes. COMMENTED is deliberately excluded from this login-keyed
    # tracking - it is always the shared-login marker convention (shape 2
    # below), never a distinct-account signal, and collapsing it in here
    # would let one crew id'"'"'s marker verdict get silently shadowed by an
    # unrelated later comment under the same shared login.
    latest_state_by_login = {}
    for r in reviews:
        st = str(r.get("state") or "").upper()
        if st not in ("APPROVED", "CHANGES_REQUESTED"):
            continue
        login = ((r.get("author") or {}).get("login")) or ""
        if not login:
            continue
        latest_state_by_login[login] = st
    if any(st == "APPROVED" for st in latest_state_by_login.values()):
        return True, ""

    # Shape 2: comment-fallback marker verdict. Only the LATEST verdict per
    # marked crew id counts (reviewer.md step 6'"'"'s own "a rerun stacks
    # additional reviews, check the latest" rule) - gh returns reviews in
    # chronological order, so a later entry for the same id simply
    # overwrites an earlier one in this dict. The body itself is retained too
    # (not just the parsed verdict), so the proof-marker check below (issue
    # #135) can be run against the LATEST comment for that id, not just its
    # verdict string.
    latest_by_id = {}
    for r in reviews:
        if str(r.get("state") or "").upper() != "COMMENTED":
            continue
        body = r.get("body") or ""
        m = CREW_MARKER_RE.match(body)
        if not m:
            continue
        vm = VERDICT_RE.search(body)
        latest_by_id[m.group(1)] = (vm.group(1).lower() if vm else None, body)

    issues = []
    for rid, (verdict, body) in latest_by_id.items():
        if verdict != "approve":
            continue
        if rid == crew_id:
            issues.append(
                "crew `%s` posted its own VERDICT: approve comment - "
                "self-approval never counts" % rid)
            continue
        record = find_roster_record(rid, home)
        if record is None:
            issues.append(
                "crew `%s` posted VERDICT: approve but no matching roster "
                "record exists (unrecognized reviewer id)" % rid)
            continue
        if record.get("type") != "reviewer":
            issues.append(
                "crew `%s` posted VERDICT: approve but its roster record is "
                "type `%s`, not `reviewer`" % (rid, record.get("type") or "?"))
            continue
        if not delivery_matches_pr(record.get("delivery"), pr_number, pr_url):
            issues.append(
                "crew `%s` (a reviewer) posted VERDICT: approve but its "
                "delivery (%s) does not name this PR"
                % (rid, record.get("delivery") or "none"))
            continue
        # issue #135: a reviewer record minted with a spawn-time token
        # carries a review_commit_approve commitment - require and verify a
        # matching proof marker before trusting this approve. A record with
        # no commitment on file (predates this fix, or was hand-spawned with
        # no token) falls straight through to the marker-only acceptance
        # below, unchanged from before this fix.
        commitment = record.get("review_commit_approve")
        if commitment:
            pm = PROOF_MARKER_RE.search(body)
            if not pm:
                issues.append(
                    "crew `%s` posted VERDICT: approve but the comment "
                    "carries no wingman-review-proof marker, required "
                    "because this reviewer'"'"'s roster record has a "
                    "review-token commitment on file (issue #135)" % rid)
                continue
            if hashlib.sha256(bytes.fromhex(pm.group(1).lower())).hexdigest() != commitment:
                issues.append(
                    "crew `%s` posted VERDICT: approve but its wingman-"
                    "review-proof marker does not match the commitment "
                    "recorded for this reviewer at spawn time - treating as "
                    "a forged approve (issue #135)" % rid)
                continue
        return True, ""

    return False, no_evidence_reason(pr_number, pr_url, issues)


# `gh pr merge` flags that consume a following value token (from `gh help pr
# merge`'"'"'s FLAGS + INHERITED FLAGS) - a naive "first token not starting with
# -" scan (this file'"'"'s original approach, matching hooks/merge-attribution-
# tracker.sh'"'"'s best-effort attribution parsing) would misread e.g. `--body
# "merge it"` as the PR ref (PR #134 review, minor finding). Misreading it
# already failed safe here (an unresolvable ref denies via unresolved_pr_
# reason below), but it verified the WRONG PR when the misread token
# happened to resolve to a real one - a correctness bug, not just a safety
# one.
GH_PR_MERGE_VALUE_FLAGS = (
    "-A", "--author-email", "-b", "--body", "-F", "--body-file",
    "--match-head-commit", "-t", "--subject", "-R", "--repo",
)


def gh_pr_merge_ref(argv):
    """The explicit PR ref argument to `gh pr merge argv[3:]`, or None if the
    command relies on the current branch'"'"'s PR (no positional ref given)."""
    i = 3  # argv[0:3] == ["gh", "pr", "merge"]
    while i < len(argv):
        tok = argv[i]
        if tok in GH_PR_MERGE_VALUE_FLAGS:
            i += 2
            continue
        if tok.startswith("-"):
            i += 1
            continue
        return tok
    return None


def evidence_check(shape, argv, exec_cwd, command, path_arg=None):
    """Returns None if this merge-equivalent segment may proceed (real
    APPROVED review, or a verified comment-fallback approve from a
    genuinely different, real reviewer crew member), else a denial reason."""
    if shape == "git_push":
        return no_evidence_reason(None, None, [
            "a direct push to the default branch has no PR to point review "
            "evidence against"])

    owner_repo = None
    if shape == "gh_pr_merge":
        ref = gh_pr_merge_ref(argv) or resolve_current_pr_ref(exec_cwd)
        if ref is None:
            return unresolved_pr_reason(
                "could not resolve the current branch'"'"'s PR (no ref given "
                "and `gh pr view` failed).")
    elif shape == "gh_api_put":
        m = re.match(r"^/?repos/([^/]+)/([^/]+)/pulls/(\d+)/merge/?$", path_arg or "")
        if not m:
            return unresolved_pr_reason(
                "could not parse the REST merge endpoint path.")
        owner, repo, number = m.groups()
        owner_repo, ref = "%s/%s" % (owner, repo), number
    elif shape == "gh_api_graphql":
        m = re.search(r"pullRequestId[\"'"'"']?\s*[:=]\s*[\"'"'"']([^\"'"'"']+)[\"'"'"']", command)
        if not m:
            return unresolved_pr_reason(
                "could not extract the pullRequestId node id from this "
                "mutation.")
        owner_repo, ref = resolve_graphql_pr(m.group(1), exec_cwd)
        if not owner_repo or not ref:
            return unresolved_pr_reason(
                "could not resolve the pullRequestId node to a PR number via "
                "the GitHub API.")
    else:
        return unresolved_pr_reason("unrecognized merge-equivalent shape.")

    pr_json = fetch_reviews(owner_repo, ref, exec_cwd)
    if pr_json is None:
        return unresolved_pr_reason(
            "`gh pr view` failed while fetching reviews for verification.")
    ok, reason = verify_reviewer_approval(pr_json)
    return None if ok else reason


def enforce_merge_gate(shape, argv, exec_cwd, command, not_granted_reason, path_arg=None):
    """The single choke point every merge-equivalent shape below routes
    through: unchanged not-granted denial, unchanged waived-allow, and (only
    when granted-but-not-waived) the new review-evidence check."""
    if not allow_merge_granted():
        deny(not_granted_reason)
    if review_gate_waived():
        return
    reason = evidence_check(shape, argv, exec_cwd, command, path_arg)
    if reason:
        deny(reason)


def resolve_cd_target(base, arg):
    # Resolve a single `cd` argument against the currently tracked execution
    # directory. Returns the resolved absolute path, or None when the
    # argument cannot be resolved from the command text alone: a bare `cd`
    # with no argument (defaults to $HOME - not modeled), `cd -` (the
    # previous directory - not tracked), or an argument containing an
    # unexpanded `$VAR` (the hook sees the command before shell expansion
    # and has no reliable value for an arbitrary variable). A None return
    # leaves the previously tracked directory in place - the same
    # "cannot determine it, do not guess" stance current_branch() already
    # takes on a git failure.
    if not arg or arg == "-" or "$" in arg:
        return None
    return os.path.normpath(os.path.join(base, arg))


def current_branch(cwd):
    try:
        r = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5)
        if r.returncode == 0:
            return r.stdout.decode().strip()
    except Exception:
        pass
    return None


def default_branch_candidates(cwd):
    # Prefer the repo'"'"'s actual default branch (local, no network call); fall
    # back to the two conventional names if it cannot be resolved (e.g. no
    # origin/HEAD cached locally).
    try:
        r = subprocess.run(
            ["git", "-C", cwd, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5)
        if r.returncode == 0:
            name = r.stdout.decode().strip()
            if name.startswith("origin/"):
                name = name[len("origin/"):]
            if name:
                return {name}
    except Exception:
        pass
    return {"main", "master"}


PARSE_FAIL_REASON = (
    "This command could not be fully parsed - an unterminated quote, an "
    "unbalanced $(...)/`...`/<(...)/>(...) span, or a heredoc whose "
    "terminator line was never found - so it is denied rather than "
    "partially checked (issue #56). If this command embeds a heredoc to "
    "build up an argument (for example a PR body), quote its delimiter "
    "(<<'"'"'EOF'"'"' rather than <<EOF) unless bash must expand "
    "$(...)/`...` inside it; otherwise reformat it into well-formed shell "
    "syntax and retry."
)


def merge_reason():
    return (
        "Merging a PR is not yours to do from a crew session (issue #46): crew "
        "never merge without the pilot'"'"'s explicit, per-effort authorization. "
        "Leave this PR open - report --status review and let the pilot merge it "
        "(see playbooks/software-development/developer.md, \"Merge "
        "authorization\"). If the pilot HAS granted merge autonomy for this "
        "effort, it isn'"'"'t visible to this session yet: ask your owner "
        "(wingman, or your lead) to run $WINGMAN_STATE crew-set --id %s "
        "--allow-merge true - this can never be set by a crew member on itself "
        "- then retry." % (crew_id or "<this-crew-id>")
    )


def git_push_target_dir(argv, exec_cwd):
    # argv[0] resolves to git (b == "git"). Scans past any leading global
    # options for a `push` subcommand, tracking an explicit `-C <dir>` along
    # the way - the one global git option that redirects execution to a
    # different directory, exactly like a `cd` earlier in the same command
    # chain. Returns (push_index, target_dir): push_index is the index of
    # push in argv (None if this segment is not a push invocation at all);
    # target_dir is the directory THIS git invocation actually runs in - an
    # explicit `-C <dir>` if one was given (resolved against the directory
    # tracked so far, exactly like a `cd` argument - an unresolvable one,
    # e.g. containing an unexpanded $VAR, leaves target_dir where it already
    # was, the same fallback resolve_cd_target() gives a `cd` that cannot be
    # resolved), else exec_cwd itself unchanged. Resolving each `-C` against
    # the RUNNING target_dir, not the original exec_cwd, matches real git'"'"'s
    # own semantics for multiple `-C` flags in one invocation: each
    # subsequent non-absolute `-C <path>` is relative to the PRECEDING `-C`,
    # not to the process'"'"'s original cwd (`git -C a -C b push` lands in
    # `<cwd>/a/b`, not `<cwd>/b`) - so this loop compounds them the same way,
    # not just the common single-`-C` case. Only `-C` is unwrapped as a
    # directory-changing flag; every other leading global option (e.g.
    # `-c name=value`) is skipped as one opaque token - the same depth of
    # handling today'"'"'s code gives no global git options at all, so this is
    # a strict improvement, not a regression, and deliberately not
    # exhaustive (see cmd_match.py'"'"'s own "known caveats, both
    # false-negative-only" precedent for this kind of scope line).
    i = 1
    target_dir = exec_cwd
    while i < len(argv):
        tok = argv[i]
        if tok == "-C" and i + 1 < len(argv):
            resolved = resolve_cd_target(target_dir, argv[i + 1])
            if resolved:
                target_dir = resolved
            i += 2
            continue
        if tok.startswith("-"):
            i += 1
            continue
        break
    if i < len(argv) and argv[i] == "push":
        return i, target_dir
    return None, target_dir


def check_merge_paths():
    if not crew_id:
        return  # not a crew session - out of scope for this guard
    # No early return on allow_merge_granted() any more (issue #132): a grant
    # alone no longer means every merge-equivalent segment below is a no-op -
    # each one now routes through enforce_merge_gate(), which still returns
    # instantly for a granted-AND-waived record (unchanged from today'"'"'s
    # post-grant behavior) but otherwise requires the new evidence check.
    # Tracks the directory a `cd` segment earlier in this SAME command chain
    # switches into, so a later `git push` segment is evaluated against
    # where it actually runs - not the hook payload'"'"'s cwd, which can be an
    # unrelated checkout of the same repo (a worktree: multiple checkouts of
    # one repo, each potentially on a different branch - issue #117).
    # Starts at the payload cwd, exactly like today, when no `cd` precedes
    # the push.
    exec_cwd = cwd
    for seg in segments or []:
        b, argv = resolve_command(seg)
        if not argv:
            continue
        if b == "cd" and len(argv) > 1:
            target = resolve_cd_target(exec_cwd, argv[1])
            if target:
                exec_cwd = target
            continue
        if b == "gh" and len(argv) > 2 and argv[1] == "pr" and argv[2] == "merge":
            enforce_merge_gate("gh_pr_merge", argv, exec_cwd, command, merge_reason())
        if b == "gh" and len(argv) > 1 and argv[1] == "api":
            method = (flag_value(argv, "-X", "--method") or "GET").upper()
            path_arg = None
            i = 2
            skip_next = ("-X", "--method", "-f", "-F", "-H", "--header",
                         "--hostname", "-q", "--jq", "--template", "-p")
            while i < len(argv):
                tok = argv[i]
                if tok in skip_next:
                    i += 2
                    continue
                if tok.startswith("-"):
                    i += 1
                    continue
                path_arg = tok
                break
            if path_arg == "graphql":
                if re.search(r"mergePullRequest\s*\(", command):
                    enforce_merge_gate("gh_api_graphql", argv, exec_cwd, command, merge_reason())
            elif path_arg and method == "PUT":
                if re.search(r"^/?repos/[^/]+/[^/]+/pulls/\d+/merge/?$", path_arg):
                    enforce_merge_gate("gh_api_put", argv, exec_cwd, command, merge_reason(), path_arg=path_arg)
        if b == "git":
            push_index, target_dir = git_push_target_dir(argv, exec_cwd)
            if push_index is not None:
                positional = [t for t in argv[push_index + 1:] if not t.startswith("-")]
                refspec = positional[1] if len(positional) > 1 else None
                if refspec is None or refspec == "HEAD":
                    dest = current_branch(target_dir)
                    if dest is None:
                        # target_dir came from this SAME command'"'"'s cd/-C text
                        # (or, absent either, the payload cwd), and its
                        # destination could not be determined - target_dir is
                        # not a valid, accessible git checkout, or the git
                        # call otherwise failed. Before exec_cwd/target_dir
                        # tracking existed, cwd was always the hook payload'"'"'s
                        # own real working directory, so this failure was
                        # never reachable from the command text itself; now
                        # that a cd/-C argument can steer it, an unresolvable
                        # destination must deny (fail closed, matching
                        # issue #56'"'"'s precedent in this same hook) rather
                        # than silently skip the check - the skip-on-None
                        # fallback below is only safe for the OTHER refspec
                        # shapes, where dest comes directly from the command
                        # text, not from a git call that can be steered onto
                        # a bogus directory and made to fail.
                        deny(
                            "Could not determine the destination branch of "
                            "this git push - the directory it resolves to "
                            "(via a preceding cd or git -C in the same "
                            "command) is not a valid, accessible git "
                            "checkout, so whether it targets the default "
                            "branch cannot be verified. Denied out of "
                            "caution rather than silently allowed (issue "
                            "#117). Push from (or git -C into) a real "
                            "checkout of this repository."
                        )
                elif ":" in refspec:
                    dest = refspec.split(":", 1)[1] or None
                else:
                    dest = refspec
                if dest:
                    if dest.startswith("refs/heads/"):
                        dest = dest[len("refs/heads/"):]
                    if dest in default_branch_candidates(target_dir):
                        enforce_merge_gate(
                            "git_push", argv, exec_cwd, command,
                            "Pushing directly to the default branch (%s) from a crew "
                            "session is a merge-equivalent and is not yours to do "
                            "(issue #46) - same rule as gh pr merge. Push your own "
                            "branch and open/update a PR instead; leave landing it on "
                            "%s to the pilot." % (dest, dest)
                        )


def _is_self_target(target):
    # `--id "$WINGMAN_CREW_ID"` (the standard, documented self-report idiom -
    # see playbooks/_status-contract.md) arrives at this PreToolUse hook
    # UNEXPANDED, exactly like $WINGMAN_STATE itself (see this file'"'"'s header
    # comment on why) - so a literal string match of `target` against
    # `crew_id` alone would treat the DOCUMENTED, ordinary self-report form
    # as "a different id". That is not just a false-positive risk: read the
    # other way round, it would ALSO let a lead (or any grantor) self-target
    # THROUGH the variable form while a literal self-id string is correctly
    # caught - a lead typing `crew-add --id "$WINGMAN_CREW_ID" --allow-merge`
    # would slip past a bare `target != crew_id` check. Recognized as self
    # either way this token can spell "my own id".
    return bool(target) and target in (crew_id, "$WINGMAN_CREW_ID")


def _check_no_self_grant(flag_token, label):
    # Shared by check_allow_merge_grant() and check_review_gate_waiver_grant()
    # (issue #132): both fields carry the identical actor restriction - only
    # wingman'"'"'s own top-level session, or a lead granting one of its OWN
    # workers, may set either. Matched by token presence, not by resolving
    # argv[0] to wm-state.py - see this hook'"'"'s header comment on why
    # (issue #49'"'"'s $WINGMAN_STATE expansion gap).
    for seg in segments or []:
        if "crew-set" not in seg:
            continue
        if not any(t == flag_token or t.startswith(flag_token + "=") for t in seg):
            continue
        target = flag_value(seg, "--id") or ""
        if not crew_id:
            continue  # wingman'"'"'s own top-level session - always allowed
        if crew_type == "lead" and target and not _is_self_target(target):
            continue  # a lead granting one of its OWN workers - allowed
        deny(
            "Granting %s is not yours to set from a crew session, including "
            "on yourself (issue #46) - it must come from the pilot via "
            "wingman'"'"'s top-level session, or a lead relaying the pilot'"'"'s "
            "decision to one of its own workers. Report --status blocked if "
            "you believe this PR needs it, and let the pilot/lead grant it "
            "instead." % label
        )


def check_allow_merge_grant():
    _check_no_self_grant("--allow-merge", "merge autonomy (--allow-merge)")


def check_review_gate_waiver_grant():
    _check_no_self_grant(
        "--review-gate-waived",
        "the review-gate waiver (--review-gate-waived, issue #132)")


def check_regenerate_review_token_grant():
    # issue #135: --regenerate-review-token must never be settable by a crew
    # session on itself - a compromised or naive developer session could
    # otherwise overwrite the GENUINE reviewer'"'"'s commitment with one derived
    # from a token IT knows, then forge a matching proof. bin/crew-resume is
    # a wingman-/lead-side script, never invoked from inside a policed crew
    # session'"'"'s own Bash calls, so this is not reachable through any
    # legitimate flow - gated anyway for defense in depth, matching this
    # hook'"'"'s existing paranoid posture (every security-relevant roster field
    # gets an explicit restriction rather than relying on "nobody would call
    # this").
    _check_no_self_grant(
        "--regenerate-review-token",
        "review-token regeneration (issue #135)")


def check_crew_add_restriction():
    # PR #134 review, findings 1+2: `wm-state crew-add` dedups by id (re-
    # adding an existing id silently REPLACES the whole record - allow_
    # merge/review_gate_waived/type/delivery included), and it is called
    # from exactly one legitimate place in this codebase - bin/spawn-crew,
    # on behalf of wingman'"'"'s own top-level session or a lead spawning one of
    # its own NEW workers. No live crew session has any other legitimate
    # reason to call it: not on itself (that would silently replace allow_
    # merge/review_gate_waived wholesale, bypassing _check_no_self_grant
    # above entirely, since that check only ever inspects `crew-set`), and
    # not on a fresh id of its own choosing (that mints a roster record -
    # e.g. a fabricated `type: reviewer` entry - with no real, independently
    # spawned session behind it, defeating verify_reviewer_approval'"'"'s
    # roster cross-check at its root). So ANY crew-add from a policed
    # session is denied outright, regardless of which flags it carries.
    for seg in segments or []:
        if "crew-add" not in seg:
            continue
        target = flag_value(seg, "--id") or ""
        if not crew_id:
            continue  # wingman'"'"'s own top-level session - always allowed
        if crew_type == "lead" and target and not _is_self_target(target):
            continue  # a lead spawning one of its OWN new workers - allowed
        deny(
            "Creating or replacing a crew roster record (wm-state crew-add) "
            "is not yours to do from a crew session (issue #132) - it is "
            "called only by bin/spawn-crew, by wingman'"'"'s own top-level "
            "session or a lead spawning one of its own workers. A worker "
            "session can never call crew-add on itself (crew-add replaces "
            "the whole record, including allow_merge/review_gate_waived, "
            "silently bypassing the self-grant restriction) or on a fresh "
            "id (which would fabricate a roster record - e.g. a fake "
            "`reviewer` entry - with no real session behind it). Report "
            "--status blocked if you believe you genuinely need a new crew "
            "member spawned."
        )


def check_crew_set_delivery_restriction():
    # PR #134 review, finding 2 (the other half): verify_reviewer_approval()
    # trusts a roster record'"'"'s `delivery` field to decide whether a comment-
    # fallback approve names THIS PR - so `delivery` is exactly as security-
    # relevant as allow_merge/review_gate_waived, but crew-set never
    # restricted who could set it on which id. Every legitimate delivery
    # report in this codebase is self-targeted (`crew-set --id
    # "$WINGMAN_CREW_ID" --delivery ...` - see playbooks/_status-
    # contract.md); nothing here sets delivery on another crew id'"'"'s behalf,
    # so restricting it to "your own id, or wingman" breaks no legitimate
    # flow while closing the "repoint an existing reviewer'"'"'s delivery at
    # this PR" half of finding 2 (check_crew_add_restriction above already
    # closes the "mint a fresh one" half).
    for seg in segments or []:
        if "crew-set" not in seg:
            continue
        if not any(t == "--delivery" or t.startswith("--delivery=") for t in seg):
            continue
        if not crew_id:
            continue  # wingman'"'"'s own top-level session - always allowed
        target = flag_value(seg, "--id") or ""
        if _is_self_target(target):
            continue  # ordinary self-report - allowed
        deny(
            "Setting --delivery on a crew id other than your own "
            "($WINGMAN_CREW_ID) is not yours to do from a crew session "
            "(issue #132) - every legitimate delivery report is self-"
            "targeted, and this hook now trusts `delivery` as one of the "
            "review-evidence gate'"'"'s roster fields. Report --status blocked "
            "if you believe you genuinely need this."
        )


def check_crew_set_type_restriction():
    # issue #136 (round-2 review of PR #134'"'"'s issue #132 fix): verify_reviewer_
    # approval() also trusts a roster record'"'"'s `type` field (must equal
    # "reviewer") to accept a comment-fallback approve marker - exactly as
    # security-relevant as `delivery`, so it gets the identical self/wingman
    # restriction, not crew-add'"'"'s lead-non-self carve-out: there is no
    # legitimate flow that changes an existing id'"'"'s `type` after crew-add
    # time (crew-set does not even define a --type flag today - see this
    # file'"'"'s header - so this is pre-emptive: it keeps the hook'"'"'s own
    # restriction independent of whatever wm-state.py happens to accept,
    # rather than relying on argparse to reject an unrecognized flag).
    for seg in segments or []:
        if "crew-set" not in seg:
            continue
        if not any(t == "--type" or t.startswith("--type=") for t in seg):
            continue
        if not crew_id:
            continue  # wingman'"'"'s own top-level session - always allowed
        target = flag_value(seg, "--id") or ""
        if _is_self_target(target):
            continue  # ordinary self-report - allowed
        deny(
            "Setting --type on a crew id other than your own "
            "($WINGMAN_CREW_ID) is not yours to do from a crew session "
            "(issue #136) - every legitimate type assignment happens once, "
            "at crew-add time, and this hook now trusts `type` as one of "
            "the review-evidence gate'"'"'s roster fields (see issue #132). "
            "Report --status blocked if you believe you genuinely need this."
        )


check_allow_merge_grant()
check_review_gate_waiver_grant()
check_regenerate_review_token_grant()
check_crew_add_restriction()
check_crew_set_delivery_restriction()
check_crew_set_type_restriction()
check_merge_paths()

# Both known-shape checks above have already had their chance to deny (or,
# for wingman'"'"'s own top-level session, to no-op) on segments they could
# resolve. Only now, with neither having denied, does an unresolvable command
# reaching this hook'"'"'s pre-gate fail closed - and only for a crew session,
# matching this guard'"'"'s own scope (see check_merge_paths()'"'"'s identical
# `if not crew_id: return`).
if segments is None and crew_id:
    deny(PARSE_FAIL_REASON)

sys.exit(0)
' 2>/dev/null

exit 0
