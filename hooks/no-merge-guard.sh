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
# contain "merge"; git push contains "push"; the grant-guard needs
# "allow-merge"). Precise matching happens in the python block.
case "$INPUT" in
  *merge*|*push*|*allow-merge*) ;;
  *) exit 0 ;;
esac

printf '%s' "$INPUT" | \
  WINGMAN_HOME="${WINGMAN_HOME:-$HOME/.wingman}" \
  WINGMAN_CREW_ID="${WINGMAN_CREW_ID:-}" \
  WINGMAN_CREW_TYPE="${WINGMAN_CREW_TYPE:-}" \
  PYTHONPATH="$HERE/lib${PYTHONPATH:+:$PYTHONPATH}" $WM_UV python -c '
import json, os, re, subprocess, sys

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


def allow_merge_granted():
    if not crew_id:
        return False
    try:
        with open(os.path.join(home, "crew.json")) as fh:
            roster = json.load(fh)
    except (OSError, ValueError):
        return False
    if not isinstance(roster, list):
        return False
    for r in roster:
        if r.get("id") == crew_id:
            return bool(r.get("allow_merge"))
    return False


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
    if allow_merge_granted():
        return
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
            deny(merge_reason())
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
                    deny(merge_reason())
            elif path_arg and method == "PUT":
                if re.search(r"^/?repos/[^/]+/[^/]+/pulls/\d+/merge/?$", path_arg):
                    deny(merge_reason())
        if b == "git":
            push_index, target_dir = git_push_target_dir(argv, exec_cwd)
            if push_index is not None:
                positional = [t for t in argv[push_index + 1:] if not t.startswith("-")]
                refspec = positional[1] if len(positional) > 1 else None
                if refspec is None or refspec == "HEAD":
                    dest = current_branch(target_dir)
                elif ":" in refspec:
                    dest = refspec.split(":", 1)[1] or None
                else:
                    dest = refspec
                if dest:
                    if dest.startswith("refs/heads/"):
                        dest = dest[len("refs/heads/"):]
                    if dest in default_branch_candidates(target_dir):
                        deny(
                            "Pushing directly to the default branch (%s) from a crew "
                            "session is a merge-equivalent and is not yours to do "
                            "(issue #46) - same rule as gh pr merge. Push your own "
                            "branch and open/update a PR instead; leave landing it on "
                            "%s to the pilot." % (dest, dest)
                        )


def check_allow_merge_grant():
    for seg in segments or []:
        # Matched by token presence, not by resolving argv[0] to wm-state.py -
        # see this hook'"'"'s header comment on why (issue #49'"'"'s $WINGMAN_STATE
        # expansion gap).
        if "crew-set" not in seg:
            continue
        if not any(t == "--allow-merge" or t.startswith("--allow-merge=") for t in seg):
            continue
        target = flag_value(seg, "--id") or ""
        if not crew_id:
            continue  # wingman'"'"'s own top-level session - always allowed
        if crew_type == "lead" and target and target != crew_id:
            continue  # a lead granting one of its OWN workers - allowed
        deny(
            "Granting merge autonomy (--allow-merge) is not yours to set from a "
            "crew session, including on yourself (issue #46) - it must come from "
            "the pilot via wingman'"'"'s top-level session, or a lead relaying the "
            "pilot'"'"'s decision to one of its own workers. Report --status blocked "
            "if you believe this PR needs it, and let the pilot/lead grant it "
            "instead."
        )


check_allow_merge_grant()
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
