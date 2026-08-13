"""guard_policy.py: transport-agnostic decision core for wingman's three
portable PreToolUse security guards (issue #25 stage 3, plan step 12a):
no-merge-guard (issue #46/#132/#135/#136/#138), no-direct-edit-guard (issue
#17/#171), and no-worker-spawn-guard (issue #212). Extracted from the three
claude-only shell hooks of the same name under hooks/ - this module carries
the DECISION logic only; the .sh files remain the actual Claude Code entry
points (stdin JSON in, env vars, PYTHONPATH, the deny JSON contract, and each
hook's own cheap bash pre-gate) and are now thin callers into the functions
below. See docs/plans/2026-08-11-issue-25-multi-cli-agent-adapter-
implementation-plan.md sections 2c/5 and the stage-3 design review
(docs/analysis/2026-08-11-issue-25-stage-3-guard-transport-design-review.md)
for why this module exists and the corrections applied here versus the
plan's original sketch.

Normalized input contract (GuardInput, below): the plan's own draft named
only {tool_name, command, cwd, crew_id}. The design review found four more
fields load-bearing in the actual hook logic and missing from that tuple:
crew_type (the whole lead/worker distinction in all three guards),
file_path/notebook_path (no-direct-edit-guard's Edit/Write/NotebookEdit
branch has no other source for its target path), project_dir (how no-direct-
edit-guard recognizes "wingman's own top-level session" - Claude-specific
today via $CLAUDE_PROJECT_DIR, but named generically here so a future
transport can supply its own equivalent), and home (WINGMAN_HOME, ambient in
the original hooks, made explicit here rather than read from the environment
by this module directly). Every field is required, with no field read from
os.environ or sys.stdin by this module - assembling a GuardInput from a
transport's own payload shape is that transport's job (see the three .sh
files' now-short python blocks for the Claude Code shape).

Two invariants this port is required to preserve, each covered by an
explicit test in tests/guard-policy.test.sh rather than left to incidental
fixture coverage:

  1. Two OPPOSITE fail-directions for the same absent crew_type. Given a
     crew session (crew_id set) whose crew_type is empty - a shape that
     should never happen post-spawn, but the original hooks each took a
     side deliberately rather than leaving it as an accident of code order:
     no-worker-spawn-guard denies (fails CLOSED: `caller_is_lead` is False
     for an empty string, and failing open here would mean "allow the
     spawn", exactly the gap that guard exists to close); no-direct-edit-
     guard allows (fails OPEN: an empty crew_type is not "lead", so this
     guard simply never activates, and failing closed here would mean
     blocking an ordinary worker's own Edit/Write calls - the opposite
     mistake). Kept as two independent functions below (never merged into
     one "resolve the default" helper) specifically so this asymmetry can
     never be accidentally homogenized.
  2. Decision equivalence with the pre-extraction hooks. Both guards are
     security-relevant enough that a subtle drift during this refactor -
     not a designed behavior change - is the real risk. tests/guard-
     policy.test.sh runs a corpus of real commands through both the pre-
     refactor hook scripts (read from the base branch this stage stacks
     on) and the post-refactor ones calling into this module, and asserts
     byte-identical verdicts, on top of the ~1,900 pre-existing lines of
     end-to-end coverage in tests/no-merge-guard.test.sh,
     tests/no-direct-edit-guard.test.sh, and tests/no-worker-spawn-
     guard.test.sh, which exercise the unchanged shell entry points
     directly and so continue to be the strongest drift net for everything
     they already cover.

Each evaluate_*() function below raises GuardDenied(reason) to deny (mirrors
the original hooks' print-JSON-and-exit(0) shape without this module ever
doing I/O or process control itself) or returns None to allow/no-op -
including for a tool_name this guard does not apply to, matching each
hook's own early "not my tool" exit.

Deliberately NOT built here (held for a later design-review pass per the
stage-3 review): a single evaluate() entry point running every applicable
check against one command (needed once a subprocess-based transport, 12d/
12e, wants to pay one subprocess hop instead of three), and any of the four
per-dialect transport shims (12b-12e) or the generation-token mechanism
(12f). This module's three separate evaluate_*() functions are shaped so
that an aggregate entry point can be added later as a thin, additive
wrapper around them, not a second extraction.
"""
import dataclasses
import hashlib
import json
import os
import re
import subprocess

from cmd_match import command_segments, redirect_write_targets, resolve_command

# hooks/lib/guard_policy.py -> repo root is two directories up (mirrors every
# hook .sh file's own `HERE="$(cd "$(dirname "$0")" && pwd -P)"; REPO="$(dirname
# "$HERE")"`, just computed once here from this module's own location instead
# of $0).
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


@dataclasses.dataclass(frozen=True)
class GuardInput:
    """The normalized 9-field input every evaluate_*() function below takes.
    All fields required and no field is ever read from the environment or
    stdin by this module - a transport's own entry point resolves every
    value from its own payload/env shape (see the .sh files for the Claude
    Code mapping) and passes a fully-populated GuardInput in. A field a
    given guard does not consume (e.g. cwd for no-worker-spawn-guard) is
    still required, for one uniform shape across all three guards rather
    than three bespoke tuples."""
    tool_name: str
    command: str
    cwd: str
    crew_id: str
    crew_type: str
    file_path: str
    notebook_path: str
    project_dir: str
    home: str


class GuardDenied(Exception):
    """Raised by an evaluate_*() function to deny. `reason` (also `str(e)`)
    is the exact text the original hook printed as
    hookSpecificOutput.permissionDecisionReason."""

    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


# PARSE_FAIL_REASON text is shared verbatim between no-merge-guard and
# no-direct-edit-guard (both hooks used byte-identical wording); no-worker-
# spawn-guard's own wording differs (see _PARSE_FAIL_REASON_SPAWN below) and
# is kept separate rather than forced to match.
_PARSE_FAIL_REASON_GENERIC = (
    "This command could not be fully parsed - an unterminated quote, an "
    "unbalanced $(...)/`...`/<(...)/>(...) span, or a heredoc whose "
    "terminator line was never found, including inside a `bash -c`/`eval` "
    "payload - so it is denied rather than "
    "partially checked. If this command embeds a heredoc to "
    "build up an argument (for example a PR body), quote its delimiter "
    "(<<'EOF' rather than <<EOF) unless bash must expand "
    "$(...)/`...` inside it; otherwise reformat it into well-formed shell "
    "syntax and retry."
)

_PARSE_FAIL_REASON_SPAWN = (
    "This command could not be fully parsed - an unterminated quote, an "
    "unbalanced $(...)/`...`/<(...)/>(...) span, or a heredoc whose "
    "terminator line was never found, including inside a `bash -c`/`eval` "
    "payload - so it is denied rather than partially checked, "
    "since this command mentions spawn-crew and could not be verified "
    "safe. Reformat it into well-formed shell syntax and retry."
)


# =============================================================================
# no-merge-guard (issue #46, #132, #135, #136, #138)
# =============================================================================

def evaluate_no_merge_guard(gi):
    """Port of hooks/no-merge-guard.sh's python block. See that file's own
    header comment for the full history (issue #46's original requirement,
    and the #132/#135/#136/#138 review-evidence hardening layered on top) -
    unchanged here, this is a decision-logic move, not a policy change."""
    if gi.tool_name != "Bash":
        return

    command = gi.command
    cwd = gi.cwd
    crew_id = gi.crew_id
    crew_type = gi.crew_type
    home = gi.home

    def deny(reason):
        raise GuardDenied(reason)

    # cmd_match.py fails CLOSED on a command it cannot fully lex (issue #56):
    # command_segments() returns None rather than a partial, truncated segment
    # list. Computed once, up front, and passed to check_allow_merge_grant()/
    # check_merge_paths() as `segments or []` so their own known-shape detection
    # (and early returns) run unchanged; only after BOTH have had their chance
    # to deny on a specific recognized shape does the fallback below deny
    # generically on an unresolvable command that reached this hook's
    # substring pre-gate.
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

    # -------------------------------------------------------------------
    # issue #132: verifiable evidence of a genuinely separate approving
    # review.
    # -------------------------------------------------------------------

    CREW_MARKER_RE = re.compile(r"^\s*<!--\s*wingman-crew:([A-Za-z0-9._-]+)\s*-->")
    VERDICT_RE = re.compile(r"VERDICT:\s*(approve|request changes)", re.IGNORECASE)
    # issue #135: the spawn-time hash-commitment proof a genuine reviewer
    # embeds alongside its marker (playbooks/software-development/
    # reviewer.md step 4, via `$WINGMAN_STATE review-sign --verdict ...`) - a
    # 64-hex-char sha256 preimage. Required on a VERDICT: approve comment
    # only when the resolved roster record carries a review_commit_approve
    # commitment (see the shape-2 loop below); absent entirely, this falls
    # through to the pre-issue-#135 marker-only check.
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
        argv += ["--json", "reviews,number,url,headRefOid"]
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
        # ...falling back to crew-archive.jsonl for a reviewer already stood
        # down and pruned. Append-only, one JSON object per line; the LAST
        # matching line wins (an id could in principle be reused across time).
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
            "found for %s - allow_merge alone no longer permits a "
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
        parts.append(
            "Note: review_gate_waived clears only THIS hook's own evidence "
            "check - if the repository's branch ruleset separately requires an "
            "approving review, the merge will still fail at GitHub regardless. "
            "Run $WINGMAN_BIN/lib/merge-block-diagnose.sh --pr "
            "<this PR URL> before escalating to find out whether one grant or "
            "two is actually needed."
        )
        return " ".join(parts)

    def unresolved_pr_reason(detail):
        return (
            "Could not verify review evidence for this merge attempt: %s "
            "Denied out of caution rather than allowed unchecked - this "
            "is a security-relevant gate, not a best-effort attribution comment. "
            "Retry once resolvable, or ask the requester/lead to grant "
            "review_gate_waived for this effort if no review round is actually "
            "wanted. Note: review_gate_waived clears only THIS hook's own "
            "evidence check - if the repository's branch ruleset separately "
            "requires an approving review, the merge will still fail at GitHub "
            "regardless. Run $WINGMAN_BIN/lib/merge-block-diagnose.sh "
            "--pr <this PR URL> before escalating to find out whether one grant "
            "or two is actually needed." % detail
        )

    def verify_reviewer_approval(pr_json):
        reviews = pr_json.get("reviews") or []
        pr_number = pr_json.get("number")
        pr_url = pr_json.get("url") or ""
        # issue #138: the PR's current head commit, used to reject evidence
        # that is genuinely valid but STALE relative to commits that landed
        # after it was produced. An unresolvable/empty value can never equal
        # a populated, real commit SHA, so every comparison below fails
        # closed by construction - no separate upfront gate is needed.
        head_ref_oid = (pr_json.get("headRefOid") or "").strip().lower()

        # Shape 1: a real APPROVED review, any author. GitHub refuses this
        # from the PR's own author, so an APPROVED/CHANGES_REQUESTED state
        # can only ever come from a genuinely different account already - no
        # marker/roster check needed. Only the LATEST state per author login
        # counts.
        latest_review_by_login = {}
        for r in reviews:
            st = str(r.get("state") or "").upper()
            if st not in ("APPROVED", "CHANGES_REQUESTED"):
                continue
            login = ((r.get("author") or {}).get("login")) or ""
            if not login:
                continue
            latest_review_by_login[login] = r  # gh returns chronological order; last wins

        stale_shape1 = []
        for login, r in latest_review_by_login.items():
            if str(r.get("state") or "").upper() != "APPROVED":
                continue
            commit_oid = ((r.get("commit") or {}).get("oid") or "").strip().lower()
            if commit_oid and commit_oid == head_ref_oid:
                return True, ""
            stale_shape1.append((login, commit_oid))

        issues = []
        for login, commit_oid in stale_shape1:
            issues.append(
                "%s's APPROVED review was submitted against commit %s, but the "
                "PR's current head is now %s - stale evidence"
                % (login, (commit_oid or "unknown")[:12], (head_ref_oid or "unknown")[:12]))

        # Shape 2: comment-fallback marker verdict. Only the LATEST verdict
        # per marked crew id counts - gh returns reviews in chronological
        # order, so a later entry for the same id simply overwrites an
        # earlier one in this dict.
        #
        # issue #304: a marked comment with NO parseable VERDICT: line is
        # skipped entirely rather than written as (None, body) - it says
        # nothing about this id's verdict, so it must not silently overwrite
        # (and thereby erase) a real verdict recorded earlier in the scan.
        latest_by_id = {}
        for r in reviews:
            if str(r.get("state") or "").upper() != "COMMENTED":
                continue
            body = r.get("body") or ""
            m = CREW_MARKER_RE.match(body)
            if not m:
                continue
            vm = VERDICT_RE.search(body)
            if vm is None:
                continue
            latest_by_id[m.group(1)] = (vm.group(1).lower(), body)

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
            # Match the base role name, not the full type string: a crew
            # type registered under a category directory is referenced as
            # `<category>/reviewer`, and its verdict must count as evidence
            # exactly like a bare `reviewer`'s (issue #166).
            rtype = record.get("type") or ""
            if rtype.rsplit("/", 1)[-1] != "reviewer":
                issues.append(
                    "crew `%s` posted VERDICT: approve but its roster record is "
                    "type `%s`, not `reviewer`" % (rid, rtype or "?"))
                continue
            if not delivery_matches_pr(record.get("delivery"), pr_number, pr_url):
                issues.append(
                    "crew `%s` (a reviewer) posted VERDICT: approve but its "
                    "delivery (%s) does not name this PR"
                    % (rid, record.get("delivery") or "none"))
                continue
            # issue #135: a reviewer record minted with a spawn-time token
            # carries a review_commit_approve commitment - require and
            # verify a matching proof marker before trusting this approve.
            commitment = record.get("review_commit_approve")
            if commitment:
                pm = PROOF_MARKER_RE.search(body)
                if not pm:
                    issues.append(
                        "crew `%s` posted VERDICT: approve but the comment "
                        "carries no wingman-review-proof marker, required "
                        "because this reviewer's roster record has a "
                        "review-token commitment on file" % rid)
                    continue
                if hashlib.sha256(bytes.fromhex(pm.group(1).lower())).hexdigest() != commitment:
                    issues.append(
                        "crew `%s` posted VERDICT: approve but its wingman-"
                        "review-proof marker does not match the commitment "
                        "recorded for this reviewer at spawn time - treating as "
                        "a forged approve" % rid)
                    continue
            # issue #138: even a genuine, verified proof can be a byte-for-
            # byte repost of OLD evidence - require the reviewer's LATEST
            # commit-bound sign to match the PR's CURRENT head.
            commit_sha = (record.get("review_commit_approve_sha") or "").strip().lower()
            if commit_sha and commit_sha != head_ref_oid:
                issues.append(
                    "crew `%s` posted VERDICT: approve but its latest signed "
                    "commit (%s) does not match the PR's current head (%s) - "
                    "stale evidence, likely because new commits landed after it "
                    "was signed"
                    % (rid, commit_sha[:12], (head_ref_oid or "unknown")[:12]))
                continue
            return True, ""

        return False, no_evidence_reason(pr_number, pr_url, issues)

    # `gh pr merge` flags that consume a following value token (from `gh
    # help pr merge`'s FLAGS + INHERITED FLAGS) - a naive "first token not
    # starting with -" scan would misread e.g. `--body "merge it"` as the PR
    # ref.
    GH_PR_MERGE_VALUE_FLAGS = (
        "-A", "--author-email", "-b", "--body", "-F", "--body-file",
        "--match-head-commit", "-t", "--subject", "-R", "--repo",
    )

    def gh_pr_merge_ref(argv):
        """The explicit PR ref argument to `gh pr merge argv[3:]`, or None if
        the command relies on the current branch's PR (no positional ref
        given)."""
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

    def evidence_check(shape, argv, exec_cwd, cmd_text, path_arg=None):
        """Returns None if this merge-equivalent segment may proceed (real
        APPROVED review, or a verified comment-fallback approve from a
        genuinely different, real reviewer crew member), else a denial
        reason."""
        if shape == "git_push":
            return no_evidence_reason(None, None, [
                "a direct push to the default branch has no PR to point review "
                "evidence against"])

        owner_repo = None
        if shape == "gh_pr_merge":
            ref = gh_pr_merge_ref(argv) or resolve_current_pr_ref(exec_cwd)
            if ref is None:
                return unresolved_pr_reason(
                    "could not resolve the current branch's PR (no ref given "
                    "and `gh pr view` failed).")
        elif shape == "gh_api_put":
            m = re.match(r"^/?repos/([^/]+)/([^/]+)/pulls/(\d+)/merge/?$", path_arg or "")
            if not m:
                return unresolved_pr_reason(
                    "could not parse the REST merge endpoint path.")
            owner, repo, number = m.groups()
            owner_repo, ref = "%s/%s" % (owner, repo), number
        elif shape == "gh_api_graphql":
            m = re.search(r"pullRequestId[\"']?\s*[:=]\s*[\"']([^\"']+)[\"']", cmd_text)
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

    def enforce_merge_gate(shape, argv, exec_cwd, cmd_text, not_granted_reason, path_arg=None):
        """The single choke point every merge-equivalent shape below routes
        through: unchanged not-granted denial, unchanged waived-allow, and
        (only when granted-but-not-waived) the new review-evidence check."""
        if not allow_merge_granted():
            deny(not_granted_reason)
        if review_gate_waived():
            return
        reason = evidence_check(shape, argv, exec_cwd, cmd_text, path_arg)
        if reason:
            deny(reason)

    def resolve_cd_target(base, arg):
        # Resolve a single `cd` argument against the currently tracked
        # execution directory. Returns None when the argument cannot be
        # resolved from the command text alone: a bare `cd` with no argument
        # (defaults to $HOME - not modeled), `cd -` (the previous directory -
        # not tracked), or an argument containing an unexpanded `$VAR` (the
        # hook sees the command before shell expansion and has no reliable
        # value for an arbitrary variable). A None return leaves the
        # previously tracked directory in place.
        if not arg or arg == "-" or "$" in arg:
            return None
        return os.path.normpath(os.path.join(base, arg))

    def current_branch(exec_cwd):
        try:
            r = subprocess.run(
                ["git", "-C", exec_cwd, "rev-parse", "--abbrev-ref", "HEAD"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5)
            if r.returncode == 0:
                return r.stdout.decode().strip()
        except Exception:
            pass
        return None

    def default_branch_candidates(exec_cwd):
        # Prefer the repo's actual default branch (local, no network call);
        # fall back to the two conventional names if it cannot be resolved.
        try:
            r = subprocess.run(
                ["git", "-C", exec_cwd, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
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

    def merge_reason():
        return (
            "Merging a PR is not yours to do from a crew session: crew "
            "never merge without the pilot's explicit, per-effort authorization. "
            "Leave this PR open - report --status review and let the pilot merge it "
            "(see playbooks/software-development/developer.md, \"Merge "
            "authorization\"). If the pilot HAS granted merge autonomy for this "
            "effort, it isn't visible to this session yet: ask your owner "
            "(wingman, or your lead) to run $WINGMAN_STATE crew-set --id %s "
            "--allow-merge true - this can never be set by a crew member on itself "
            "- then retry." % (crew_id or "<this-crew-id>")
        )

    def git_push_target_dir(argv, exec_cwd):
        # argv[0] resolves to git. Scans past any leading global options for
        # a `push` subcommand, tracking an explicit `-C <dir>` along the way.
        # Returns (push_index, target_dir): push_index is None if this
        # segment is not a push invocation at all; target_dir is the
        # directory THIS git invocation actually runs in.
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
        # Tracks the directory a `cd` segment earlier in this SAME command
        # chain switches into, so a later `git push` segment is evaluated
        # against where it actually runs - not the hook payload's own cwd,
        # which can be an unrelated checkout of the same repo (a worktree -
        # issue #117). Starts at the payload cwd when no `cd` precedes the
        # push.
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
                            # target_dir came from this SAME command's cd/-C
                            # text (or, absent either, the payload cwd), and
                            # its destination could not be determined -
                            # target_dir is not a valid, accessible git
                            # checkout. Fail closed (issue #56's precedent
                            # in this same hook) rather than silently skip.
                            deny(
                                "Could not determine the destination branch of "
                                "this git push - the directory it resolves to "
                                "(via a preceding cd or git -C in the same "
                                "command) is not a valid, accessible git "
                                "checkout, so whether it targets the default "
                                "branch cannot be verified. Denied out of "
                                "caution rather than silently allowed. Push "
                                "from (or git -C into) a real "
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
                                "- same rule as gh pr merge. Push your own "
                                "branch and open/update a PR instead; leave landing it on "
                                "%s to the pilot." % (dest, dest)
                            )

    def _is_self_target(target):
        # `--id "$WINGMAN_CREW_ID"` (the standard, documented self-report
        # idiom) arrives at this PreToolUse hook UNEXPANDED, exactly like
        # $WINGMAN_STATE itself - so a literal string match of `target`
        # against `crew_id` alone would treat the DOCUMENTED, ordinary
        # self-report form as "a different id". Recognized as self either
        # way this token can spell "my own id".
        return bool(target) and target in (crew_id, "$WINGMAN_CREW_ID")

    def _check_no_self_grant(flag_token, label):
        # Shared by check_allow_merge_grant() and
        # check_review_gate_waiver_grant() (issue #132): both fields carry
        # the identical actor restriction - only wingman's own top-level
        # session, or a lead granting one of its OWN workers, may set
        # either. Matched by token presence, not by resolving argv[0] to
        # wm-state.py (issue #49's $WINGMAN_STATE expansion gap).
        for seg in segments or []:
            if "crew-set" not in seg:
                continue
            if not any(t == flag_token or t.startswith(flag_token + "=") for t in seg):
                continue
            target = flag_value(seg, "--id") or ""
            if not crew_id:
                continue  # wingman's own top-level session - always allowed
            if crew_type == "lead" and target and not _is_self_target(target):
                continue  # a lead granting one of its OWN workers - allowed
            deny(
                "Granting %s is not yours to set from a crew session, including "
                "on yourself - it must come from the pilot via "
                "wingman's top-level session, or a lead relaying the pilot's "
                "decision to one of its own workers. Report --status blocked if "
                "you believe this PR needs it, and let the pilot/lead grant it "
                "instead." % label
            )

    def check_allow_merge_grant():
        _check_no_self_grant("--allow-merge", "merge autonomy (--allow-merge)")

    def check_review_gate_waiver_grant():
        _check_no_self_grant(
            "--review-gate-waived",
            "the review-gate waiver (--review-gate-waived)")

    def check_regenerate_review_token_grant():
        # issue #135: --regenerate-review-token must never be settable by a
        # crew session on itself.
        _check_no_self_grant(
            "--regenerate-review-token",
            "review-token regeneration")

    def check_crew_add_restriction():
        # PR #134 review, findings 1+2: `wm-state crew-add` dedups by id and
        # is called from exactly one legitimate place in this codebase -
        # bin/spawn-crew, on behalf of wingman's own top-level session or a
        # lead spawning one of its own NEW workers.
        for seg in segments or []:
            if "crew-add" not in seg:
                continue
            target = flag_value(seg, "--id") or ""
            if not crew_id:
                continue  # wingman's own top-level session - always allowed
            if crew_type == "lead" and target and not _is_self_target(target):
                continue  # a lead spawning one of its OWN new workers - allowed
            deny(
                "Creating or replacing a crew roster record (wm-state crew-add) "
                "is not yours to do from a crew session - it is "
                "called only by bin/spawn-crew, by wingman's own top-level "
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
        # PR #134 review, finding 2 (the other half): verify_reviewer_
        # approval() trusts a roster record's `delivery` field, so it gets
        # the same self/wingman restriction.
        for seg in segments or []:
            if "crew-set" not in seg:
                continue
            if not any(t == "--delivery" or t.startswith("--delivery=") for t in seg):
                continue
            if not crew_id:
                continue  # wingman's own top-level session - always allowed
            target = flag_value(seg, "--id") or ""
            if _is_self_target(target):
                continue  # ordinary self-report - allowed
            deny(
                "Setting --delivery on a crew id other than your own "
                "($WINGMAN_CREW_ID) is not yours to do from a crew session "
                "- every legitimate delivery report is self-"
                "targeted, and this hook now trusts `delivery` as one of the "
                "review-evidence gate's roster fields. Report --status blocked "
                "if you believe you genuinely need this."
            )

    def check_crew_set_type_restriction():
        # issue #136: verify_reviewer_approval() also trusts a roster
        # record's `type` field, so it gets the identical self/wingman
        # restriction.
        for seg in segments or []:
            if "crew-set" not in seg:
                continue
            if not any(t == "--type" or t.startswith("--type=") for t in seg):
                continue
            if not crew_id:
                continue  # wingman's own top-level session - always allowed
            target = flag_value(seg, "--id") or ""
            if _is_self_target(target):
                continue  # ordinary self-report - allowed
            deny(
                "Setting --type on a crew id other than your own "
                "($WINGMAN_CREW_ID) is not yours to do from a crew session "
                "- every legitimate type assignment happens once, "
                "at crew-add time, and this hook now trusts `type` as one of "
                "the review-evidence gate's roster fields. "
                "Report --status blocked if you believe you genuinely need this."
            )

    check_allow_merge_grant()
    check_review_gate_waiver_grant()
    check_regenerate_review_token_grant()
    check_crew_add_restriction()
    check_crew_set_delivery_restriction()
    check_crew_set_type_restriction()
    check_merge_paths()

    # Both known-shape checks above have already had their chance to deny
    # (or, for wingman's own top-level session, to no-op) on segments they
    # could resolve. Only now, with neither having denied, does an
    # unresolvable command reaching this guard's scope fail closed - and
    # only for a crew session, matching check_merge_paths()'s identical
    # `if not crew_id: return`.
    if segments is None and crew_id:
        deny(_PARSE_FAIL_REASON_GENERIC)


# =============================================================================
# no-direct-edit-guard (issue #17, #171)
# =============================================================================

_RUNNER_BINS = {"pytest", "rspec", "jest", "mocha"}
_SED_BOOL_SHORT = set("nrEsuz")     # no-argument short flags
_SED_SCRIPT_SHORT = set("ef")       # short flags supplying the script (glued or separate)
_SED_OTHER_VALUE_SHORT = set("l")   # other value-taking short flags (line-wrap length)


def no_direct_edit_guard_active(gi):
    """Whether no-direct-edit-guard applies to this session at all - active
    when crew_type is EXACTLY "lead" (unconditionally), or crew_id is unset
    AND project_dir resolves to this wingman checkout (wingman's own
    top-level session; for Claude Code, project_dir is $CLAUDE_PROJECT_DIR).
    Exported (not nested inside evaluate_no_direct_edit_guard) so it can be
    exercised directly by tests/guard-policy.test.sh's fail-direction
    invariant check, and so a future transport's own entry point can query
    it without duplicating the comparison logic. no-direct-edit-guard.sh's
    own bash pre-gate still performs this same check as a cheap, unchanged
    optimization (skip spinning up python at all for the common case of an
    ordinary worker session) - this function is the canonical decision the
    core itself also enforces, not merely relied upon from the transport.

    The "lead" comparison here is deliberately EXACT (`==`), not the
    base-role-name match (`crew_type.rsplit("/", 1)[-1] == "lead"`)
    evaluate_no_worker_spawn_guard uses for its own caller-is-lead check
    (PR #338 review round 1, should-fix: an earlier version of this
    function used the base-role-name form here too, silently widening
    activation to a category-qualified type like "common/lead" - a real
    policy change, not a faithful port, since the original bash pre-gate
    (`[ "${WINGMAN_CREW_TYPE:-}" = "lead" ]`) has never recognized anything
    but the bare string. 12a's mandate is a byte-faithful extraction; a
    category-qualified lead's own no-direct-edit-guard activation is a
    genuine, separate policy question for whoever owns that decision, not
    something this refactor gets to decide by accident)."""
    if gi.crew_type == "lead":
        return True
    if not gi.crew_id and gi.project_dir:
        return os.path.realpath(gi.project_dir) == os.path.realpath(_REPO_ROOT)
    return False


def _is_inside_git_repo(path):
    d = os.path.dirname(os.path.abspath(path)) or "/"
    while d != "/" and not os.path.isdir(d):
        d = os.path.dirname(d)
    try:
        r = subprocess.run(
            ["git", "-C", d, "rev-parse", "--is-inside-work-tree"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5,
        )
        return r.returncode == 0 and r.stdout.strip() == b"true"
    except Exception:
        return False


def _is_test_runner_segment(tokens):
    b, argv = resolve_command(tokens)
    if not argv:
        return False
    cmd = argv[0]
    if re.search(r"tests?/[^/\s]*\.test\.sh$", cmd) or re.search(r"tests?/run\.sh$", cmd):
        return True
    if b in ("python", "python3") and "-m" in argv:
        idx = argv.index("-m")
        return idx + 1 < len(argv) and argv[idx + 1] in ("pytest", "unittest")
    if b in ("npm", "yarn", "pnpm"):
        rest = [t for t in argv[1:] if t != "run"]
        return bool(rest) and rest[0] == "test"
    if b == "go" and len(argv) > 1 and argv[1] == "test":
        return True
    if b == "cargo" and len(argv) > 1 and argv[1] == "test":
        return True
    if b == "make" and "test" in argv[1:]:
        return True
    return b in _RUNNER_BINS


def _consume_short_cluster(tok):
    # Character-level parse of one '-xyz' short-option cluster token.
    # Returns (has_inplace, explicit_script, consumed_next).
    has_inplace = False
    explicit_script = False
    consumed_next = False
    k, n = 1, len(tok)
    while k < n:
        ch = tok[k]
        if ch == "i":
            has_inplace = True
            k = n  # everything after 'i' in this token is its backup suffix
            break
        if ch in _SED_SCRIPT_SHORT or ch in _SED_OTHER_VALUE_SHORT:
            if ch in _SED_SCRIPT_SHORT:
                explicit_script = True
            if k + 1 >= n:
                consumed_next = True  # no glued value - next token is the value
            k = n
            break
        k += 1  # an ordinary boolean flag char - keep scanning this cluster
    return has_inplace, explicit_script, consumed_next


def _sed_inplace_targets(argv):
    has_inplace = False
    explicit_script = False
    positional = []
    i, n = 1, len(argv)
    while i < n:
        tok = argv[i]
        if tok == "--":
            positional.extend(argv[i + 1:])
            break
        if tok.startswith("--in-place"):
            has_inplace = True
            i += 1
            continue
        if tok in ("--expression", "--file"):
            explicit_script = True
            i += 2  # long form always takes a separate-token value
            continue
        if tok == "--line-length":
            i += 2
            continue
        if tok.startswith("--expression=") or tok.startswith("--file="):
            explicit_script = True
            i += 1
            continue
        if tok.startswith("--line-length="):
            i += 1
            continue
        if tok.startswith("--"):
            # Any other GNU sed long flag is boolean - skipped as a flag,
            # never left to fall through to positional.
            i += 1
            continue
        if tok.startswith("-") and tok != "-" and not tok.startswith("--"):
            cl_inplace, cl_script, consumed_next = _consume_short_cluster(tok)
            has_inplace = has_inplace or cl_inplace
            explicit_script = explicit_script or cl_script
            i += 2 if consumed_next else 1
            continue
        positional.append(tok)
        i += 1
    if not has_inplace:
        return []
    # With no -e/-f, sed's own first positional argument is the SCRIPT, not
    # a file - strip it. With -e/-f already supplying the script, every
    # remaining positional is a file.
    if not explicit_script and positional:
        positional = positional[1:]
    return positional


def _cp_mv_targets(argv):
    positional = []
    target_dir = None
    i = 1
    n = len(argv)
    while i < n:
        tok = argv[i]
        if tok in ("-t", "--target-directory"):
            if i + 1 < n:
                target_dir = argv[i + 1]
            i += 2
            continue
        if tok.startswith("--target-directory="):
            target_dir = tok.split("=", 1)[1]
            i += 1
            continue
        if tok == "--":
            positional.extend(argv[i + 1:])
            break
        if tok.startswith("-") and tok != "-":
            i += 1
            continue
        positional.append(tok)
        i += 1
    if target_dir is not None:
        return [target_dir]
    if len(positional) >= 2:
        return [positional[-1]]
    return []


def evaluate_no_direct_edit_guard(gi):
    """Port of hooks/no-direct-edit-guard.sh's python block. See that file's
    own header comment for the full history (issue #17's original
    requirement, #171's Bash file-write extension)."""
    if not no_direct_edit_guard_active(gi):
        return

    def deny(reason):
        raise GuardDenied(reason)

    if gi.tool_name in ("Edit", "Write", "NotebookEdit"):
        path = gi.file_path or gi.notebook_path or ""
        if not path or _is_inside_git_repo(path):
            deny(
                "Direct %s calls are not yours to make here - you are acting as an "
                "orchestrator (wingman's top-level layer, or a lead), and CLAUDE.md's "
                "prime directive is \"never do heavy work yourself,\" no size exception. "
                "Spawn a developer crew member to make this change instead: "
                "bin/spawn-crew --type developer --repo <name> --objective \"<the "
                "change>\" (or --input <plan-path> if an analyst already produced a "
                "plan)." % gi.tool_name
            )
        return

    if gi.tool_name != "Bash":
        return

    command = gi.command
    segments = command_segments(command)
    if segments is None:
        deny(_PARSE_FAIL_REASON_GENERIC)

    if any(_is_test_runner_segment(seg) for seg in segments):
        deny(
            "Running the test suite directly is not yours to do here - you are "
            "acting as an orchestrator. Hand the change and its verification to "
            "a developer crew member via bin/spawn-crew instead of invoking the "
            "test runner yourself."
        )

    FILE_WRITE_DENY = (
        "This Bash command writes directly to %s inside a git repo (%s) - not "
        "yours to do here as an orchestrator, for the same reason a direct "
        "Edit/Write call is denied. This same guard covers shell-level "
        "writes: sed -i, output "
        "redirection (>, >>, &>, tee), and cp/mv are just as much \"heavy "
        "work\" as an Edit/Write call, and are now recognized the same way, "
        "no size exception. Spawn a developer crew member to make this change "
        "instead: bin/spawn-crew --type developer --repo <name> --objective "
        "\"<the change>\" (or --input <plan-path> if an analyst already "
        "produced a plan)."
    )

    def check_write_targets(targets, mechanism):
        for t in targets:
            if t and _is_inside_git_repo(t):
                deny(FILE_WRITE_DENY % (t, mechanism))

    redirect_targets = []
    for seg in segments:
        redirect_targets.extend(redirect_write_targets(seg))
    check_write_targets(redirect_targets, "output redirection")

    for seg in segments:
        b, argv = resolve_command(seg)
        if not argv:
            continue
        if b == "tee":
            check_write_targets(
                [t for t in argv[1:] if not t.startswith("-")], "tee"
            )
        elif b == "sed":
            check_write_targets(_sed_inplace_targets(argv), "sed -i")
        elif b in ("cp", "mv"):
            check_write_targets(_cp_mv_targets(argv), "%s" % b)


# =============================================================================
# no-worker-spawn-guard (issue #212, recommendation 3)
# =============================================================================

def _all_flag_values(argv, *names):
    # Every occurrence of a --type-shaped flag, not just the first -
    # bin/spawn-crew's own parsing loop is last-wins, so a single call can
    # legally carry more than one --type token. Collecting every occurrence
    # and denying if ANY resolves to "lead" is simpler than matching
    # spawn-crew's own precedence, and strictly safer.
    values = []
    i = 0
    while i < len(argv):
        tok = argv[i]
        if tok in names and i + 1 < len(argv):
            values.append(argv[i + 1])
            i += 2
            continue
        for name in names:
            if tok.startswith(name + "="):
                values.append(tok[len(name) + 1:])
                break
        i += 1
    return values


def evaluate_no_worker_spawn_guard(gi):
    """Port of hooks/no-worker-spawn-guard.sh's python block. See that
    file's own header comment for the full history (issue #212's depth-cap
    requirement). A crew session with crew_id set but crew_type empty/unset
    is treated as a worker, not exempted - fail CLOSED on this specific
    restriction (the opposite fail-direction from
    evaluate_no_direct_edit_guard's own missing-crew_type case; see this
    module's own docstring for why both are deliberate)."""
    if gi.tool_name != "Bash":
        return

    command = gi.command
    crew_type = gi.crew_type
    caller_is_lead = crew_type.rsplit("/", 1)[-1] == "lead"

    segments = command_segments(command)

    def deny(reason):
        raise GuardDenied(reason)

    if segments is None:
        deny(_PARSE_FAIL_REASON_SPAWN)

    for seg in segments:
        b, argv = resolve_command(seg)
        if not argv or b != "spawn-crew":
            continue

        if not caller_is_lead:
            deny(
                "Spawning crew is not yours to do from a %s session - "
                "bin/spawn-crew is restricted to orchestrator-type "
                "callers (wingman's own top-level session, or a lead) by "
                "CLAUDE.md's depth cap (pilot -> wingman -> lead -> worker). "
                "If this work genuinely needs another crew member (e.g. a "
                "reviewer for your PR), report --status blocked naming exactly "
                "what you need - your lead/owner spawns it as its own direct "
                "report instead." % (crew_type or "worker")
            )

        target_types = _all_flag_values(argv, "--type")
        if any(t.rsplit("/", 1)[-1] == "lead" for t in target_types):
            deny(
                "A lead may not spawn a further lead - CLAUDE.md's "
                "depth cap is \"a lead spawns workers but not further leads.\" "
                "Spawn a software-analyst/architect/developer/reviewer worker "
                "instead; deeper management nesting is a future opt-in (see "
                "playbooks/common/lead.md's Guardrails section), not something "
                "to reach for now."
            )
