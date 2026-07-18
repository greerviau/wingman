#!/usr/bin/env bash
# pr-open-marker-tracker.sh - a Claude Code PostToolUse hook (matcher "Bash").
# Closes issue #50's remaining "beyond merges" gap: every PR a crew member
# opens is authored under the human's own GitHub credentials, so a PR opened
# by an agent and one written by hand are otherwise indistinguishable.
#
# Reuses the exact marker convention issue #118 (PR #121) already shipped for
# pr-watch's self-filter - an invisible GitHub HTML comment,
# `<!-- wingman-crew:<crew-id> -->`, anchored to the start of the body - so
# there is only ever one marker format in this repo, not a second one
# invented for PR bodies specifically. A PR body has no functional
# interaction with bin/lib/pr-eval.py's self-filter today (that filter only
# ever inspects comments/reviews, a distinct field from the body), so this
# hook exists purely to record provenance, not to change pr-watch behavior.
#
# Fires automatically, as a side effect the agent cannot skip - never an
# instruction in a playbook a member has to remember to follow (this repo has
# been burned repeatedly by exactly that failure shape: see #39, #44, and
# #43's own history). Modeled directly on hooks/merge-attribution-tracker.sh:
# same cmd_match usage, same best-effort/silent-failure posture, same
# WINGMAN_CREW_ID guard.
#
# Trigger: a Bash tool call that SUCCEEDED (PostToolUse only fires on a
# zero-exit Bash command) from a crew session (WINGMAN_CREW_ID set - a bare
# human session has no crew id and needs no marker, since there is no agent
# identity to disclose) whose command resolves to `gh pr create` - AND the
# pr_comments run preference is `on`. Writing anything to a PR is opt-in
# (default off): when the human keeps review feedback on wingman's own channel
# and off the forge, this hook leaves the PR body untouched. The marker's only
# consumer is the GitHub review/merge machinery, which is exactly the
# pr_comments=on case, so gating it here breaks nothing while respecting "do
# not write in my PR."
#
# Resolving the just-opened PR: preferred, `gh pr create`'s own stdout is the
# created PR's URL, and PostToolUse's hook payload exposes the command's
# output via `tool_response` - the URL is regex-matched out of it directly
# (the same "dump to text, regex the URL out" approach
# hooks/artifact-publish-tracker.sh already uses for an Artifact publish
# URL), which is exact regardless of the command's `cwd` or an explicit
# `--head <branch>` flag. Fallback, if no URL is found there: `gh pr view
# --json number,body` in the tool call's `cwd` - correct for the common case
# (a worktree developer whose cwd is on the branch it just opened a PR for)
# but not for an out-of-band `--head`.
#
# Idempotency: if the fetched body already starts with a
# `<!-- wingman-crew:... -->` marker (any id - covers a retried/resumed
# session that already ran this hook once), nothing is edited.
#
# Best-effort throughout: any failure (auth, network, an unresolvable PR, gh
# not authenticated in this call context) is swallowed silently, never
# surfaced as a tool error - the PR already opened; a hook must not turn a
# missed marker into a crashed turn.
#
# Registered user-level by bin/doctor (crew sessions have their project root
# in other repos, where this repo's project settings never load) - same
# reasoning as hooks/no-merge-guard.sh, hooks/merge-attribution-tracker.sh,
# and the Artifact-publish contract hooks.
# bash-3.2-safe.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(dirname "$HERE")"
STATE_PY="$REPO/bin/lib/wm-state.py"
WM_UV="${WM_UV:-uv run --no-project --quiet}"

INPUT="$(cat)"

# Cheap no-op gate before invoking Python: the raw command must contain both
# "gh" and "create" to possibly match. Deliberately loose - it also matches
# `gh repo create`/`gh gist create`/`gh issue create` - this only exists to
# skip Python-launch cost on commands that obviously can't match; the precise
# `argv[1] == "pr" and argv[2] == "create"` check below (not this gate) is
# what actually excludes those other create shapes.
case "$INPUT" in
  *gh*create*) ;;
  *) exit 0 ;;
esac

printf '%s' "$INPUT" | \
  WINGMAN_HOME="${WINGMAN_HOME:-$HOME/.wingman}" \
  WINGMAN_CREW_ID="${WINGMAN_CREW_ID:-}" \
  WINGMAN_RUN_ID="${WINGMAN_RUN_ID:-}" \
  WM_MARK_STATE_PY="$STATE_PY" \
  WM_MARK_UV="$WM_UV" \
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
if not crew_id:
    sys.exit(0)  # a bare human session opened this - no agent identity to disclose

# Writing anything to a PR (including this invisible provenance marker) is
# opt-in per the pr_comments run preference: when it is off/unanswered/
# unaskable the crew respects "do not write in my PR", so this hook leaves the
# body untouched. Provenance is only load-bearing when the GitHub review/merge
# machinery is in use, which is exactly the pr_comments=on case. Conservative
# default (no run id, unset pref, unreadable engine) is "do not mark".
run_id = os.environ.get("WINGMAN_RUN_ID") or ""
if not run_id:
    sys.exit(0)
try:
    _pref = subprocess.run(
        os.environ["WM_MARK_UV"].split() + [os.environ["WM_MARK_STATE_PY"],
            "pref-get", "--run-id", run_id, "--key", "pr_comments"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30)
    _pr_comments = _pref.stdout.decode().strip() if _pref.returncode == 0 else ""
except Exception:
    _pr_comments = ""
if _pr_comments != "on":
    sys.exit(0)

tool_input = data.get("tool_input", {}) or {}
command = tool_input.get("command", "") or ""
cwd = data.get("cwd") or os.getcwd()

MARKER = "<!-- wingman-crew:%s -->" % crew_id
CREW_MARKER_RE = re.compile(r"^\s*<!--\s*wingman-crew:([A-Za-z0-9._-]+)\s*-->")

# Same "serialize tool_response to text, regex the URL out" approach
# hooks/artifact-publish-tracker.sh already uses for an Artifact publish URL
# - robust to the exact tool_response field shape, which was never confirmed
# for a Bash call specifically.
_resp = data.get("tool_response")
_resp_text = _resp if isinstance(_resp, str) else (json.dumps(_resp) if _resp is not None else "")
_m = re.search(r"https://github\.com/[^/\s\"\x27\\\\]+/[^/\s\"\x27\\\\]+/pull/\d+", _resp_text)
NEW_PR_URL = _m.group(0) if _m else None


def run(argv, timeout=30):
    try:
        return subprocess.run(argv, cwd=cwd, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, timeout=timeout)
    except Exception:
        return None


def fetch_pr(ref):
    view_argv = ["gh", "pr", "view"]
    if ref:
        view_argv.append(ref)
    view_argv += ["--json", "number,body"]
    r = run(view_argv)
    if not r or r.returncode != 0:
        return None
    try:
        pr = json.loads(r.stdout.decode())
    except Exception:
        return None
    return pr if isinstance(pr, dict) else None


def mark_new_pr():
    pr = fetch_pr(NEW_PR_URL)
    if not pr:
        return
    number = pr.get("number")
    if not number:
        return
    body = pr.get("body") or ""
    if CREW_MARKER_RE.match(body):
        return  # already marked - a retried/resumed session ran this hook before
    new_body = MARKER + "\n\n" + body
    run(["gh", "pr", "edit", str(number), "--body", new_body])


# cmd_match.py fails CLOSED on a command it cannot fully lex (issue #56),
# returning None rather than a partial segment list; this is a best-effort
# PostToolUse recorder (not a deny-gate), so an unresolvable command just
# means nothing to mark - `or []`, not a crash.
for seg in command_segments(command) or []:
    b, argv = resolve_command(seg)
    if not argv:
        continue
    if b == "gh" and len(argv) > 2 and argv[1] == "pr" and argv[2] == "create":
        mark_new_pr()

sys.exit(0)
' 2>/dev/null

exit 0
