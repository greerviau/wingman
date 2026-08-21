"""guard_policy.py: transport-agnostic decision core for wingman's portable
PreToolUse security guards - no-merge-guard, no-direct-edit-guard, no-worker-
spawn-guard, no-watcher-kill-guard, the shared spawn-pause machinery behind
api-outage-spawn-guard/usage-limit-spawn-guard, no-foreground-watcher-guard,
and no-foreground-poll-loop-guard. Extracted from the claude-only shell hooks
of the same name under hooks/ - this module carries the DECISION logic only;
the .sh files remain the actual Claude Code entry points (stdin JSON in, env
vars, PYTHONPATH, the deny JSON contract, and each hook's own cheap bash
pre-gate) and are thin callers into the functions below, and hooks/lib/
guard_dispatch.py is the equivalent thin caller for the four non-Claude
dialects.

Normalized input contract (GuardInput, below): the plan's own draft named
only {tool_name, command, cwd, crew_id}. The design review found five more
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
import glob
import hashlib
import json
import os
import re
import subprocess
import time

from cmd_match import basename, command_segments, redirect_write_targets, resolve_command

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
    # list. Computed once, up front, and read as `segments or []` by every
    # check below, so their own known-shape detection (and early returns) run
    # unchanged on an unlexable command; only after all of them have had their
    # chance to deny on a specific recognized shape does the fallback at the
    # end of this function deny generically.
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

    # Every known-shape check above has already had its chance to deny (or,
    # for wingman's own top-level session, to no-op) on segments it could
    # resolve. Only now, with none of them having denied, does an
    # unresolvable command reaching this guard's scope fail closed - and
    # only for a crew session, matching check_merge_paths()'s identical
    # `if not crew_id: return`.
    if segments is None and crew_id:
        deny(_PARSE_FAIL_REASON_GENERIC)


# =============================================================================
# no-direct-edit-guard (issue #17, #171)
# =============================================================================

_RUNNER_BINS = {"pytest", "rspec", "jest", "mocha"}
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


# =============================================================================
# no-watcher-kill-guard
# =============================================================================

def evaluate_no_watcher_kill_guard(gi):
    """Port of hooks/no-watcher-kill-guard.sh's python block. See that file's
    own header comment for the full history and the false-deny-only tradeoffs
    it documents (pkill comm-vs-args conservatism, the tmux process-tree walk,
    and fail-closed on a dynamic/unresolvable kill/pkill/tmux target) -
    unchanged here, this is a decision-logic move, not a policy change.

    Active for EVERY session, crew and top-level alike (no crew_id/crew_type
    gating at all, matching the original hook) - so gi.crew_id/gi.crew_type
    are simply unused by this guard, the same "required but not consumed"
    shape evaluate_no_worker_spawn_guard already has for gi.cwd.

    WM_WATCH_HARD_GRACE is read directly from os.environ, not threaded
    through GuardInput: it is a fleet-wide tuning knob, not a per-request
    field any transport's own payload shape could supply, so it stays an
    ambient default exactly as the original hook read it."""
    if gi.tool_name != "Bash":
        return

    command = gi.command
    home = gi.home
    try:
        hard_grace = int(os.environ.get("WM_WATCH_HARD_GRACE") or "300")
    except ValueError:
        hard_grace = 300

    def deny(reason):
        raise GuardDenied(reason)

    def watcher_kill_reason(pid):
        return (
            "Killing a live watch-fleet cycle (pid %d) is never something to do "
            "from a session: its liveness is the only channel "
            "that lets a wake reach an idle orchestrator, and this exact shape - "
            "a session misreading the pid as an instruction to stop it - has "
            "happened before. Leave it running; it exits on its own the instant "
            "there is an actionable event. If you genuinely need to stop this "
            "cycle for manual testing (rare - normal operation never requires "
            "it), use `bin/watch-fleet --stop` instead of killing the pid "
            "directly." % pid
        )

    DYNAMIC_TARGET_REASON = (
        "This command's kill/pkill/tmux target is not a literal value - it is "
        "built via command substitution ($(...)/`...`) or a shell variable "
        "($VAR/${VAR}), so this hook cannot statically verify it will not "
        "resolve to the live watch-fleet cycle (pid %d) once bash actually "
        "expands it. Denied conservatively rather than risk "
        "a missed deny: resolve it to a literal pid or pattern first and retry - "
        "a literal value that genuinely targets something unrelated to the "
        "watcher passes through untouched."
    )

    def is_dynamic_token(tok):
        if tok in ("$(...)", "`...`", "<(...)", ">(...)"):
            return True
        return "$" in tok

    def deny_dynamic(protected):
        deny(DYNAMIC_TARGET_REASON % sorted(protected)[0])

    def protected_pids():
        pids = set()
        for ownerlock in glob.glob(os.path.join(home, "watch*.pid.owner")):
            if not ownerlock.endswith(".pid.owner"):
                continue
            ownerfile = os.path.join(ownerlock, "owner")
            try:
                with open(ownerfile) as fh:
                    lines = fh.read().splitlines()
                pid = int(lines[0])
                stamped_start = lines[1] if len(lines) > 1 else ""
                marker = lines[2] if len(lines) > 2 else ""
            except (OSError, ValueError, IndexError):
                continue
            if pid <= 0:
                continue
            try:
                os.kill(pid, 0)
            except OSError:
                continue
            if marker == "lstart-utc":
                try:
                    cur_start = subprocess.check_output(
                        ["ps", "-o", "lstart=", "-p", str(pid)],
                        stderr=subprocess.DEVNULL, timeout=5,
                        env={**os.environ, "TZ": "UTC", "LC_ALL": "C"}).decode().strip()
                except Exception:
                    continue
                if not stamped_start or stamped_start != cur_start:
                    continue
            else:
                try:
                    args = subprocess.check_output(
                        ["ps", "-o", "args=", "-p", str(pid)],
                        stderr=subprocess.DEVNULL, timeout=5,
                        env={**os.environ, "LC_ALL": "C"}).decode()
                except Exception:
                    continue
                if "watch-fleet" not in args:
                    continue
            beatfile = ownerlock[: -len(".pid.owner")] + ".beat"
            try:
                mtime = os.path.getmtime(beatfile)
            except OSError:
                continue
            if (time.time() - mtime) < hard_grace:
                pids.add(pid)
        return pids

    def parse_kill(argv):
        args = argv[1:]
        if not args:
            return False, None, []
        if args[0] in ("-l", "-L"):
            return True, None, []
        tok0 = args[0]
        signal = None
        idx = 0
        if tok0 == "-s":
            signal = args[1] if len(args) > 1 else None
            idx = 2
        elif tok0.startswith("-s") and len(tok0) > 2:
            signal = tok0[2:]
            idx = 1
        elif tok0 == "-n":
            signal = args[1] if len(args) > 1 else None
            idx = 2
        elif tok0.startswith("-n") and len(tok0) > 2:
            signal = tok0[2:]
            idx = 1
        elif tok0.startswith("-") and tok0 != "-":
            signal = tok0[1:]
            idx = 1
        return False, signal, args[idx:]

    def is_null_signal(signal):
        if signal is None:
            return False
        s = signal.strip()
        if s.upper().startswith("SIG"):
            s = s[3:]
        return s == "0"

    def check_kill(argv, protected):
        if not protected:
            return
        listmode, signal, targets = parse_kill(argv)
        if listmode or is_null_signal(signal):
            return
        for tok in targets:
            t = tok[1:] if tok.startswith("-") else tok
            try:
                val = int(t)
            except ValueError:
                if is_dynamic_token(t):
                    deny_dynamic(protected)
                continue
            if abs(val) in protected:
                deny(watcher_kill_reason(abs(val)))

    _PKILL_BOOL_FLAGS = ("-f", "-x", "-v", "-n", "-o")
    _PKILL_VALUE_FLAGS = ("-s", "--signal", "-P", "-u", "-U", "-g", "-G", "-t")

    def extract_pkill_pattern(argv):
        args = argv[1:]
        pattern = None
        i = 0
        while i < len(args):
            tok = args[i]
            if tok in _PKILL_VALUE_FLAGS:
                i += 2
                continue
            if tok.startswith("--signal="):
                i += 1
                continue
            if tok in _PKILL_BOOL_FLAGS:
                i += 1
                continue
            if tok.startswith("-") and tok != "-":
                i += 1
                continue
            pattern = tok
            i += 1
        return pattern

    def ps_identity(pid):
        try:
            out = subprocess.check_output(
                ["ps", "-p", str(pid), "-o", "comm=,args="],
                stderr=subprocess.DEVNULL, timeout=5).decode()
        except Exception:
            return None, None
        line = out.strip("\n")
        if not line.strip():
            return None, None
        parts = line.split(None, 1)
        comm = parts[0] if parts else ""
        args_str = parts[1] if len(parts) > 1 else ""
        return comm, args_str

    def check_pkill(argv, protected):
        if not protected:
            return
        pattern = extract_pkill_pattern(argv)
        if pattern is None:
            return
        if is_dynamic_token(pattern):
            deny_dynamic(protected)
        try:
            rx = re.compile(pattern)
        except re.error:
            deny(watcher_kill_reason(sorted(protected)[0]))
            return
        for pid in protected:
            comm, args_str = ps_identity(pid)
            if comm is None:
                continue
            if rx.search(comm) or rx.search(args_str):
                deny(watcher_kill_reason(pid))

    def tmux_target_value(rest):
        for i, tok in enumerate(rest):
            if tok == "-t" and i + 1 < len(rest):
                return rest[i + 1]
            if tok.startswith("-t") and len(tok) > 2:
                return tok[2:]
        return None

    _TMUX_KILL_FULL_NAMES = {"kill-window", "kill-session"}
    _TMUX_KILL_FALLBACK_NAMES = {"kill-window", "kill-session"}
    _TMUX_KILL_FALLBACK_ALIASES = {"killw": "kill-window"}

    def tmux_command_catalog():
        try:
            out = subprocess.check_output(
                ["tmux", "list-commands", "-F",
                 "#{command_list_name}|#{command_list_alias}"],
                stderr=subprocess.DEVNULL, timeout=5).decode()
        except Exception:
            return set(), {}
        names = set()
        aliases = {}
        for line in out.splitlines():
            parts = line.split("|", 1)
            name = parts[0] if parts else ""
            if not name:
                continue
            names.add(name)
            alias = parts[1] if len(parts) > 1 else ""
            if alias:
                aliases[alias] = name
        return names, aliases

    def resolve_tmux_subcommand(token, names, aliases):
        if token in names:
            return token
        if token in aliases:
            return aliases[token]
        candidates = [n for n in names if n.startswith(token)]
        if len(candidates) == 1:
            return candidates[0]
        return None

    def tmux_kill_subcommand_index(args, names, aliases):
        for i, tok in enumerate(args):
            resolved = resolve_tmux_subcommand(tok, names, aliases)
            if resolved in _TMUX_KILL_FULL_NAMES:
                return i, resolved
        return len(args), None

    def resolve_pane_pids(kind, target):
        cmd = ["tmux", "list-panes"]
        if kind == "kill-session":
            cmd.append("-s")
        if target:
            cmd += ["-t", target]
        cmd += ["-F", "#{pane_pid}"]
        try:
            out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, timeout=5).decode()
        except Exception:
            return []
        return [int(ln.strip()) for ln in out.splitlines() if ln.strip().isdigit()]

    def ps_tree_descendants(root_pids):
        try:
            out = subprocess.check_output(
                ["ps", "-ax", "-o", "pid=,ppid="],
                stderr=subprocess.DEVNULL, timeout=5).decode()
        except Exception:
            return set()
        children = {}
        known = set()
        for line in out.splitlines():
            parts = line.split()
            if len(parts) != 2:
                continue
            try:
                pid, ppid = int(parts[0]), int(parts[1])
            except ValueError:
                continue
            children.setdefault(ppid, []).append(pid)
            known.add(pid)
        result = set()
        stack = list(root_pids)
        while stack:
            p = stack.pop()
            if p in result:
                continue
            if p in known or p in root_pids:
                result.add(p)
            stack.extend(children.get(p, []))
        return result

    def check_tmux_kill(argv, protected):
        if not protected:
            return
        kind = argv[1]
        target = tmux_target_value(argv[2:])
        if target is not None and is_dynamic_token(target):
            deny_dynamic(protected)
        root_pids = resolve_pane_pids(kind, target)
        if not root_pids:
            return
        hit = protected & ps_tree_descendants(root_pids)
        if hit:
            deny(watcher_kill_reason(sorted(hit)[0]))

    def check_tmux(argv, protected):
        args = argv[1:]
        names, aliases = tmux_command_catalog()
        if not names:
            names, aliases = _TMUX_KILL_FALLBACK_NAMES, _TMUX_KILL_FALLBACK_ALIASES
        idx, kind = tmux_kill_subcommand_index(args, names, aliases)
        if idx >= len(args):
            return
        check_tmux_kill(["tmux", kind] + args[idx + 1:], protected)

    segments = command_segments(command)
    if segments is None:
        deny(_PARSE_FAIL_REASON_GENERIC)

    protected = protected_pids()
    if protected:
        for seg in segments:
            b, argv = resolve_command(seg)
            if not argv:
                continue
            if b == "kill":
                check_kill(argv, protected)
            elif b == "pkill":
                check_pkill(argv, protected)
            elif b == "tmux":
                check_tmux(argv, protected)


# =============================================================================
# spawn-pause guards (api-outage-spawn-guard, usage-limit-spawn-guard) -
# shared machinery
# =============================================================================

_PARSE_FAIL_REASON_SPAWN_PAUSE = (
    "This command could not be fully parsed - an unterminated quote, an "
    "unbalanced $(...)/`...`/<(...)/>(...) span, or a heredoc whose "
    "terminator line was never found, including inside a `bash -c`/`eval` "
    "payload - so it is denied rather than "
    "partially checked, the same posture hooks/no-merge-guard.sh "
    "takes on this shape. Reformat it into well-formed shell syntax and "
    "retry."
)


def _spawn_calls_and_force(segments, override_flag):
    calls = []
    force = False
    for seg in segments or []:
        b, argv = resolve_command(seg)
        if not argv or b != "spawn-crew":
            continue
        calls.append(seg)
        if any(t == override_flag for t in argv):
            force = True
    return calls, force


def evaluate_spawn_pause_guards(gi, state_path, is_blocking_state, override_flag, build_message):
    """Port of hooks/lib/spawn_pause_guard.py's run(), minus the stdin
    reading and printing it used to own directly - that module's own run()
    is now a thin wrapper delegating here (see its own docstring), which
    keeps its existing external contract (and tests/spawn-pause-guard.test.sh,
    which exercises it via a throwaway fixture hook independent of either
    real guard) unchanged.

    A single (state_path, is_blocking_state, override_flag, build_message)
    tuple describes ONE pause condition - this function checks exactly one,
    not both api-outage and usage-limit at once, so hooks/api-outage-spawn-
    guard.sh and hooks/usage-limit-spawn-guard.sh each keep evaluating only
    their own state file (no policy change to either individually), and
    hooks/lib/guard_dispatch.py's combined "spawn-pause" dispatcher guard
    (for codex/grok, which have no separate registration per condition) calls
    this twice - api-outage first, then usage-limit, matching the manifest's
    own group order - denying on whichever fires first."""
    if gi.tool_name != "Bash":
        return

    def deny(reason):
        raise GuardDenied(reason)

    segments = command_segments(gi.command)
    calls, forced = _spawn_calls_and_force(segments, override_flag)

    if not calls:
        if segments is None:
            deny(_PARSE_FAIL_REASON_SPAWN_PAUSE)
        return

    if forced:
        return

    try:
        with open(state_path) as fh:
            state = json.load(fh)
    except (OSError, ValueError):
        state = {}

    if not isinstance(state, dict) or not is_blocking_state(state):
        return

    deny(build_message(state))


# =============================================================================
# no-foreground-watcher-guard
# =============================================================================

_ARM_DENY_FLAGS = {
    "watch-fleet": ("--status", "--stop", "--classify", "--clear-standdown", "-h", "--help"),
    "pr-watch": ("--once", "-h", "--help"),
}
_LAUNCHER_WRAPPERS = ("nohup", "setsid", "timeout", "nice", "ionice", "stdbuf")
_DETACHED_LAUNCHERS = ("nohup", "setsid")
_SAFE_AMP_RE = re.compile(r"&&|[0-9]*>&[0-9]*|&>|<&")


def _foreground_watcher_denial_reason(dialect):
    """The DENIAL_REASON text below is byte-identical to the original
    claude-only hook's for dialect=="claude" (or unset - claude's own
    default), preserving decision equivalence exactly. Every other dialect
    gets a dialect-aware variant stating the truth (plan §5.2): none of the
    four non-Claude CLIs has a background tool-call mode for a MODEL-ISSUED
    call (the pi-extension continuity probe at docs/analysis/2026-08-17-pi-
    wake-loop-probe/ shows an EXTENSION can hold a blocking wait - a
    different thing entirely, see that probe's own README), so telling the
    model to "reissue with run_in_background: true" would be actively wrong
    there - there is no such flag for it to set."""
    if not dialect or dialect == "claude":
        return (
            "bin/watch-fleet blocks until an event fires - that is the entire "
            "wake mechanism - so running it any way other than as a "
            "harness-tracked background task wedges this session indefinitely "
            "- a session that does this sits wedged indefinitely, invisible to "
            "the stall detector. Re-issue this as a Bash call with "
            "run_in_background: true, on its own, not bundled onto another "
            "command. Never foreground, and never detached (nohup, setsid, a "
            "trailing &) - a detached watcher's exit cannot wake anyone, so "
            "it is not a watcher. If you cannot arm it as a background task, arm "
            "nothing: no watcher at all is strictly better than a foreground "
            "one, because a missing watcher is recoverable and a wedged session "
            "is not. Read-only forms (--status, --stop, --classify, and pr-watch "
            "--once) are unaffected, including under a timeout/nice wrapper. To "
            "watch a cycle's behaviour interactively, run it from your own "
            "terminal, not through a tool call."
        )
    return (
        "bin/watch-fleet blocks until an event fires - that is the entire "
        "wake mechanism - so running it any way other than as a "
        "harness-tracked background task wedges this session indefinitely, "
        "invisible to the stall detector. This CLI (%s) has no background "
        "tool-call mode for a model-issued call, unlike Claude Code's own "
        "run_in_background flag - so there is no way to arm this from a tool "
        "call at all here. Arm nothing: no watcher at all is strictly better "
        "than a foreground one, because a missing watcher is recoverable and "
        "a wedged session is not. Never foreground, and never detached "
        "(nohup, setsid, a trailing &) - a detached watcher's exit cannot "
        "wake anyone, so it is not a watcher. Read-only forms (--status, "
        "--stop, --classify, and pr-watch --once) are unaffected, including "
        "under a timeout/nice wrapper." % dialect
    )


def _wm_effective_run_id():
    """The run id this guard's own ownership checks compare against:
    $WINGMAN_RUN_ID when genuinely set (a settable override), else
    $WM_EFFECTIVE_RUN_ID when a shallow entry point has already resolved it
    (hooks/no-foreground-watcher-guard.sh in bash, hooks/lib/
    guard_dispatch.py in Python - both call bin/lib/harness-identity.sh's
    wm_harness_process_identity at their OWN natural depth from the harness
    and export/set the result, even when empty, so its mere presence in
    os.environ means "already resolved, trust it"), else this module's own
    fallback shell-out (review round 2: measured live at 6 hops from HERE
    when this fallback fires - bash -c the walk spawns -> python3 -> uv ->
    the command-substitution subshell -> the hook script -> claude's own
    sh -c wrapper -> claude - one more than the walk's own bound, which is
    why the two shallow entry points now pre-resolve instead of ever
    reaching this branch in production; this remains only for a caller that
    invokes evaluate_no_foreground_watcher_guard directly, bypassing both).
    Empty when nothing resolves (e.g. the helper script is missing, or no
    recognizable harness ancestor is found within its own bounded walk).
    """
    run_id = os.environ.get("WINGMAN_RUN_ID") or ""
    if run_id:
        return run_id
    if "WM_EFFECTIVE_RUN_ID" in os.environ:
        return os.environ["WM_EFFECTIVE_RUN_ID"]
    helper = os.path.join(_REPO_ROOT, "bin", "lib", "harness-identity.sh")
    try:
        # No stderr handling needed: wm_harness_process_identity traces its
        # own reason to a log file, never stderr (bin/lib/harness-
        # identity.sh) - nothing here to suppress or preserve either way.
        r = subprocess.run(
            ["bash", "-c", '. "$1" && wm_harness_process_identity', "harness-identity", helper],
            stdout=subprocess.PIPE, timeout=5)
        if r.returncode == 0:
            return r.stdout.decode().strip()
    except Exception:
        pass
    return ""


def evaluate_no_foreground_watcher_guard(gi, run_in_background=False, dialect="claude"):
    """Port of hooks/no-foreground-watcher-guard.sh's python block. See that
    file's own header comment for the full history and the false-deny-only
    tradeoffs it documents - unchanged
    here for dialect=="claude", a decision-logic move, not a policy change.

    run_in_background is a separate parameter, not a GuardInput field: it
    models a Claude-Code-specific Bash tool_input attribute (plan §5.2), not
    a general per-request fact every dialect can supply - none of the four
    non-Claude CLIs has an analogous concept at all (pi's own bash tool
    schema is `{command, timeout}` - no such field, confirmed in plan §3.2),
    so a non-claude caller simply never passes True here, which correctly
    makes every arming call deny unconditionally for those dialects.

    Active for EVERY session (no crew_id/crew_type gating), matching the
    original hook - gi.crew_type is unused (gi.crew_id is read only for the
    standdown-marker owner fallback below, mirroring the original hook's own
    $WINGMAN_CREW_ID read)."""
    if gi.tool_name != "Bash":
        return

    raw_command = gi.command
    command_text = raw_command if isinstance(raw_command, str) else str(raw_command)

    def deny(reason):
        raise GuardDenied(reason)

    def is_relevant(text):
        return "watch-fleet" in text or "pr-watch" in text

    if not is_relevant(command_text):
        return

    if not isinstance(raw_command, str):
        deny(
            "This command mentions watch-fleet/pr-watch but could not be "
            "verified safe - an unexpected tool_input shape - so it is "
            "denied rather than partially checked, since silence is this "
            "guard's own allow signal and a failure is not silence. If this "
            "is a legitimate arming call, reissue it as a plain "
            "bin/watch-fleet or bin/pr-watch invocation on its own, not "
            "bundled onto another command."
        )

    command = raw_command
    segments = command_segments(command)
    if segments is None:
        deny(
            "This command could not be fully parsed - an unterminated quote, an "
            "unbalanced $(...)/`...`/<(...)/>(...) span, or a heredoc whose "
            "terminator line was never found, including inside a `bash -c`/`eval` "
            "payload - so it is denied rather than partially checked, "
            "since this command mentions watch-fleet/pr-watch and could not be "
            "verified safe. Reformat it into well-formed shell syntax and retry."
        )

    DENIAL_REASON = _foreground_watcher_denial_reason(dialect)

    def is_arming(target, target_argv):
        deny_flags = _ARM_DENY_FLAGS.get(target)
        if deny_flags is None:
            return False
        return not any(f in target_argv for f in deny_flags)

    def find_watcher_invocation(b, argv):
        if b in ("watch-fleet", "pr-watch"):
            return None, 0
        if b in _LAUNCHER_WRAPPERS:
            for i, tok in enumerate(argv):
                if basename(tok) in ("watch-fleet", "pr-watch"):
                    return b, i
        return None, None

    def extract_owner_flag(target_argv):
        for i, tok in enumerate(target_argv):
            if tok == "--owner":
                return target_argv[i + 1] if i + 1 < len(target_argv) else ""
        return None

    arming_found = False
    watch_fleet_arming = False
    watch_fleet_owner_argv = None
    for seg in segments:
        b, argv = resolve_command(seg)
        if not argv:
            continue
        launcher, idx = find_watcher_invocation(b, argv)
        if idx is None:
            continue
        target_argv = argv[idx:]
        target = basename(target_argv[0])
        if not is_arming(target, target_argv):
            continue
        if launcher in _DETACHED_LAUNCHERS:
            deny(DENIAL_REASON)
        arming_found = True
        if target == "watch-fleet":
            watch_fleet_arming = True
            watch_fleet_owner_argv = target_argv

    if arming_found:
        if watch_fleet_arming:
            _owner_flag = extract_owner_flag(watch_fleet_owner_argv or [])

            def read_standdown_marker(path):
                try:
                    with open(path) as f:
                        return f.read()
                except FileNotFoundError:
                    return None

            _owner = _owner_flag if _owner_flag is not None else (gi.crew_id or "")
            _okey = re.sub(r"[^A-Za-z0-9._-]", "_", _owner) if _owner else ""
            _marker_name = "watch-%s.suppressed" % _okey if _okey else "watch.suppressed"
            _marker_path = os.path.join(gi.home, _marker_name)
            _marker_content = read_standdown_marker(_marker_path)
            if _marker_content is not None:
                _marker_lines = _marker_content.split("\n", 1)
                _stamp = _marker_lines[0] if _marker_lines else ""
                _body = _marker_lines[1] if len(_marker_lines) > 1 else ""
                _run_id = _wm_effective_run_id()
                if not _run_id or not _stamp or _stamp == _run_id:
                    _count_match = re.search(r"died (\d+) times", _body)
                    _count_clause = " (%s deaths in a row)" % _count_match.group(1) if _count_match else ""
                    deny(
                        "A spurious-repeated failure-budget standdown is in force "
                        "for this session" + _count_clause + ": the "
                        "watcher has died repeatedly with no successful cycle in "
                        "between, and the failure budget is deliberately refusing "
                        "further arms until a human intervenes. Arming now would "
                        "clear the standdown, which is exactly the re-arm churn "
                        "the budget exists to prevent. Lifting the standdown is "
                        "up to the pilot, not a tool call: once the cause is "
                        "understood, run bin/watch-fleet --clear-standdown, then "
                        "fleet continuity re-arms automatically on the next Stop "
                        "event."
                    )
        if "&" in _SAFE_AMP_RE.sub("", command_text):
            deny(DENIAL_REASON)
        if not run_in_background:
            deny(DENIAL_REASON)


# =============================================================================
# no-foreground-poll-loop-guard
# =============================================================================

_LOOP_KEYWORDS = ("while", "until")
_LEADING_KEYWORDS = ("do", "then", "else", "elif")


def _foreground_poll_loop_denial_reason(loop_kind, loop_text, sleep_text, dialect):
    """Byte-identical to the original claude-only hook's wording for
    dialect=="claude" (or unset); a dialect-aware variant for every other
    dialect, same reasoning as _foreground_watcher_denial_reason above -
    none of the four non-Claude CLIs has a background tool-call mode for a
    model-issued call, so "reissue with run_in_background: true" would be
    actively wrong there."""
    if not dialect or dialect == "claude":
        return (
            "This command runs an unbounded %s loop with a sleep in its body in "
            "the FOREGROUND of a Bash tool call - a hand-rolled polling wait with "
            "no independent timeout. Two crew sessions hard-"
            "deadlocked exactly this way and cost roughly four hours combined: "
            "one ran `until ! pgrep -f \"tests/run.sh\" ...; do sleep 5; done` "
            "and never noticed that `pgrep -f` matches its OWN command line (a "
            "permanent self-match, since the pattern text is also part of the "
            "waiting shell's own -c payload); the other waited on a sentinel "
            "file a different process never wrote. Neither loop's exit "
            "condition could ever become true, and neither session could read "
            "incoming messages, self-diagnose, or be woken by anything except an "
            "external kill, while blocked inside the foreground tool call. "
            "Reissue the IDENTICAL command with run_in_background: true - the "
            "harness tracks it and notifies this session on completion, so no "
            "polling loop is needed at all. To stream output from an already-"
            "backgrounded process instead of polling it, use the Monitor tool. "
            "Matched loop: `%s`; matched sleep: `%s`."
        ) % (loop_kind, loop_text, sleep_text)
    return (
        "This command runs an unbounded %s loop with a sleep in its body in "
        "the FOREGROUND of a Bash tool call - a hand-rolled polling wait with "
        "no independent timeout. Two crew sessions on Claude Code hard-"
        "deadlocked exactly this way and cost roughly four hours combined - "
        "one matched its own command line via `pgrep -f`, the other waited on "
        "a sentinel file nobody wrote; neither loop's exit condition could "
        "ever become true. This CLI (%s) has no background tool-call mode for "
        "a model-issued call, so there is no run_in_background flag to set "
        "here - arm nothing instead: rerun this command later after the "
        "condition it is waiting on has already been confirmed true some "
        "other way, rather than polling for it in the foreground. "
        "Matched loop: `%s`; matched sleep: `%s`."
    ) % (loop_kind, dialect, loop_text, sleep_text)


def evaluate_no_foreground_poll_loop_guard(gi, run_in_background=False, dialect="claude"):
    """Port of hooks/no-foreground-poll-loop-guard.sh's python block. See
    that file's own header comment for the full history - unchanged here
    for dialect=="claude", a
    decision-logic move, not a policy change.

    run_in_background: see evaluate_no_foreground_watcher_guard's own
    docstring - identical reasoning, not a GuardInput field.

    Active for EVERY session (no crew_id/crew_type gating), matching the
    original hook - gi.crew_id/gi.crew_type are unused."""
    if gi.tool_name != "Bash":
        return

    raw_command = gi.command
    command_text = raw_command if isinstance(raw_command, str) else str(raw_command)

    def deny(reason):
        raise GuardDenied(reason)

    def is_relevant(text):
        return "sleep" in text and ("while" in text or "until" in text)

    if not is_relevant(command_text):
        return

    if not isinstance(raw_command, str):
        deny(
            "This command mentions a while/until loop and sleep but could not be "
            "verified safe - an unexpected tool_input shape - so it is "
            "denied rather than partially checked, since silence is this "
            "guard's own allow signal and a failure is not silence. If this "
            "is a legitimate polling wait, reissue the identical command "
            "with run_in_background: true."
        )

    command = raw_command
    segments = command_segments(command)
    if segments is None:
        deny(
            "This command could not be fully parsed - an unterminated quote, an "
            "unbalanced $(...)/`...`/<(...)/>(...) span, or a heredoc whose "
            "terminator line was never found, including inside a `bash -c`/`eval` "
            "payload - so it is denied rather than partially checked, "
            "since this command mentions a while/until loop and sleep and could "
            "not be verified safe. Reformat it into well-formed shell syntax and "
            "retry."
        )

    loop_opener = None
    sleep_invocation = None

    for seg in segments:
        if not seg:
            continue
        body = seg[1:] if seg[0] in _LEADING_KEYWORDS else seg
        body_head = basename(body[0]) if body else ""
        opener_tok = body_head if body_head in _LOOP_KEYWORDS else basename(seg[0])
        if loop_opener is None and opener_tok in _LOOP_KEYWORDS:
            loop_opener = (opener_tok, " ".join(seg))
        if not body:
            continue
        resolved_b, _resolved_argv = resolve_command(body)
        if sleep_invocation is None and resolved_b == "sleep":
            sleep_invocation = " ".join(seg)

    if loop_opener is not None and sleep_invocation is not None:
        if not run_in_background:
            deny(_foreground_poll_loop_denial_reason(
                loop_opener[0], loop_opener[1], sleep_invocation, dialect))
