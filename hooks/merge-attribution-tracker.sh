#!/usr/bin/env bash
# merge-attribution-tracker.sh - a Claude Code PostToolUse hook (matcher
# "Bash"). The other half of issue #46's requirement: "if an agent IS
# authorized to merge, it must leave an attribution marker" - because a crew
# session acts under the human's own GitHub credentials, `mergedBy`/`author`
# report the human for every crew action (issue #50), so an agent merge and a
# genuine human merge are otherwise indistinguishable forever after.
#
# Fires automatically, as a side effect the agent cannot skip - never an
# instruction in a playbook a member has to remember to follow (this repo has
# been burned repeatedly by exactly that failure shape: see #39, #44, and
# #43's own history).
#
# Trigger: a Bash tool call that SUCCEEDED (PostToolUse only fires on a
# zero-exit Bash command - a failing one fires PostToolUseFailure instead;
# see hooks/artifact-publish-tracker.sh's header for the same confirmed
# wiring) from a crew session (WINGMAN_CREW_ID set - a bare human session has
# no crew id and needs no attribution comment, since there is no agent
# identity to disclose) whose command matched one of the merge shapes
# hooks/no-merge-guard.sh gates:
#   - `gh pr merge [<ref>] [flags]` - <ref> (number/URL/branch) if given,
#     else resolved via `gh pr view` in the command's cwd (the current
#     branch's PR).
#   - `gh api -X PUT repos/{owner}/{repo}/pulls/{number}/merge` - owner,
#     repo, and number parsed straight out of the REST path.
#   - `gh api graphql` carrying a `mergePullRequest(` mutation - best effort:
#     the mutation's `pullRequestId` (a GraphQL node id) is extracted from the
#     raw command text and used directly as the `addComment` mutation's
#     `subjectId`, sidestepping the need to resolve it to a PR number at all.
#     A mutation that supplies the id some other way (a shell variable, a
#     file-sourced query) is not recognized - a known, documented gap, not a
#     silent guarantee.
#
# Posts one PR comment identifying the crew member (id + type) that merged
# it, via `gh pr comment`/`gh api graphql addComment`. The comment opens with
# the same `<!-- wingman-crew:<id> -->` marker hooks/pr-open-marker-tracker.sh
# prepends to a PR's body - one marker convention, not two - so every
# crew-authored PR write in the repo carries it with no carve-out. Best-effort:
# any failure (gh not authenticated in this exact call context, network
# hiccup, an unresolvable PR reference) is swallowed silently rather than
# surfaced as a tool error - the merge already happened, and a hook must not
# turn a missed comment into a crashed turn.
#
# On a merge commit trailer instead of/in addition to a comment: deliberately
# NOT implemented. This hook runs PostToolUse - after gh has already created
# the merge/squash commit - so the only way to add a trailer at this point
# would be rewriting the commit and force-pushing over the just-landed ref on
# the shared default branch, which trades a comment (durable, visible,
# reversible) for a history rewrite (exactly the class of destructive
# operation this project's own git safety protocol reserves for explicit,
# one-off human requests). The PR comment is the durable marker; it survives
# in the PR's own history even if the thread is later collapsed.
#
# Registered user-level by bin/doctor (crew sessions have their project root
# in other repos, where this repo's project settings never load) - same
# reasoning as hooks/no-merge-guard.sh and the Artifact-publish contract
# hooks.
# bash-3.2-safe.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
WM_UV="${WM_UV:-uv run --no-project --quiet}"

INPUT="$(cat)"

# Cheap no-op gate: only a command mentioning "merge" can possibly match.
case "$INPUT" in
  *merge*) ;;
  *) exit 0 ;;
esac

printf '%s' "$INPUT" | \
  WINGMAN_CREW_ID="${WINGMAN_CREW_ID:-}" \
  WINGMAN_CREW_TYPE="${WINGMAN_CREW_TYPE:-}" \
  PYTHONPATH="$HERE/lib${PYTHONPATH:+:$PYTHONPATH}" $WM_UV python -c '
import json, os, re, subprocess, sys

from cmd_match import command_segments, resolve_command

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

if data.get("hook_event_name") != "PostToolUse" or data.get("tool_name") != "Bash":
    sys.exit(0)

crew_id = os.environ.get("WINGMAN_CREW_ID", "")
crew_type = os.environ.get("WINGMAN_CREW_TYPE", "") or "?"
if not crew_id:
    sys.exit(0)  # a bare human session merged this - no agent identity to disclose

tool_input = data.get("tool_input", {}) or {}
command = tool_input.get("command", "") or ""
cwd = data.get("cwd") or os.getcwd()

COMMENT_BODY = (
    "<!-- wingman-crew:%s -->\n"
    "Merged by wingman crew `%s` (type: `%s`), not by the human - see issue #46."
    % (crew_id, crew_id, crew_type)
)


def flag_value(tokens, *names):
    for i, tok in enumerate(tokens):
        if tok in names and i + 1 < len(tokens):
            return tokens[i + 1]
        for name in names:
            if tok.startswith(name + "="):
                return tok[len(name) + 1:]
    return None


def run(argv, timeout=30):
    try:
        return subprocess.run(argv, cwd=cwd, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, timeout=timeout)
    except Exception:
        return None


def post_comment_on(ref):
    run(["gh", "pr", "comment", ref, "--body", COMMENT_BODY])


def resolve_current_pr():
    r = run(["gh", "pr", "view", "--json", "number", "-q", ".number"])
    if r and r.returncode == 0:
        out = r.stdout.decode().strip()
        if out:
            return out
    return None


def handle_gh_pr_merge(argv):
    positional = [t for t in argv[3:] if not t.startswith("-")]
    ref = positional[0] if positional else resolve_current_pr()
    if ref:
        post_comment_on(ref)


def handle_gh_api(argv):
    method = (flag_value(argv, "-X", "--method") or "GET").upper()
    path_arg = None
    i = 2
    skip_next = ("-X", "--method", "-f", "-F", "-H", "--header", "--hostname",
                 "-q", "--jq", "--template", "-p")
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
        if not re.search(r"mergePullRequest\s*\(", command):
            return
        m = re.search(r"pullRequestId[\"\x27]?\s*[:=]\s*[\"\x27]([^\"\x27]+)[\"\x27]", command)
        if not m:
            return  # known gap - see header comment
        node_id = m.group(1)
        mutation = (
            "mutation($id:ID!,$body:String!){addComment(input:"
            "{subjectId:$id,body:$body}){clientMutationId}}"
        )
        run(["gh", "api", "graphql", "-f", "query=" + mutation,
             "-f", "id=" + node_id, "-f", "body=" + COMMENT_BODY])
        return

    if path_arg and method == "PUT":
        m = re.match(r"^/?repos/([^/]+)/([^/]+)/pulls/(\d+)/merge/?$", path_arg)
        if m:
            owner, repo, number = m.groups()
            post_comment_on("https://github.com/%s/%s/pull/%s" % (owner, repo, number))


# cmd_match.py fails CLOSED on a command it cannot fully lex (issue #56),
# returning None rather than a partial segment list; this is a best-effort
# PostToolUse recorder (not a deny-gate), so an unresolvable command just
# means nothing to attribute - `or []`, not a crash.
for seg in command_segments(command) or []:
    b, argv = resolve_command(seg)
    if not argv:
        continue
    if b == "gh" and len(argv) > 2 and argv[1] == "pr" and argv[2] == "merge":
        handle_gh_pr_merge(argv)
    elif b == "gh" and len(argv) > 1 and argv[1] == "api":
        handle_gh_api(argv)

sys.exit(0)
' 2>/dev/null

exit 0
