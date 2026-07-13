#!/usr/bin/env bash
# artifact-link-guard.sh - a Claude Code PreToolUse hook (matcher "Bash").
# Mechanically enforces the crew status contract's Artifact-publish condition
# (playbooks/_status-contract.md, condition B) at the moment it can be
# skipped: a crew member reporting a markdown deliverable via `crew-set
# --status review` or `--status done` while the pilot's cached
# `artifact_linking` preference for this run is `artifact`. The prose version
# of this check was observed silently skipped in practice (see
# docs/plans/2026-07-13-onboarding-preferences-hook-enforcement.md, section
# 6), so the report call itself is gated instead.
#
# Trigger: any Bash segment resolving to `wm-state.py crew-set` carrying
# `--status review` or `--status done` - with or without an `--artifact` on
# the same call, since the contract's own "only pass the flags that changed"
# convention makes a bare re-entry the normal shape, and a reviewer-type
# member's delivery is a terminal `--status done` that never passes through
# `review`. The artifact to check is the call's own `--artifact` value, else
# the `artifact` field already on this member's crew record.
#
# Allowed without any check: no artifact resolvable at all, a non-markdown
# artifact (approximated by the .md extension - coarser than condition A's
# "has headers/tables/code fences" test, deliberately), or `artifact_linking`
# not cached as `artifact` for this run (condition B does not call for
# publishing; this includes WINGMAN_RUN_ID being unset, e.g. after a resume
# performed outside a wingman run).
#
# Otherwise the call is allowed only if $WINGMAN_HOME/artifact-markers/
# <session_id>.json (written by hooks/artifact-publish-tracker.sh, never by
# the agent) holds a record for the resolved path that is one of:
#   - "published" whose sha256 matches the file's current contents;
#   - "publish-failed" whose sha256 matches (a real attempt was made and
#     failed - one recorded, escapable attempt, not a permanent block);
#   - "scan-failed" (artifact-scan.sh said not to publish - correctly skipped).
# A missing or stale record (the file changed since) is denied, with every
# legitimate next step named in the reason.
#
# Registered user-level by bin/doctor (crew sessions have their project root
# in other repos, where this repo's project settings never load). Active only
# when WINGMAN_CREW_ID is set - any crew type, any repo; this is the crew
# contract's own gate, not wingman's onboarding gate. The no-op path for
# every other Bash call is one substring check.
# bash-3.2-safe.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(dirname "$HERE")"
STATE_PY="$REPO/bin/lib/wm-state.py"
WM_UV="${WM_UV:-uv run --no-project --quiet}"

[ -n "${WINGMAN_CREW_ID:-}" ] || exit 0

INPUT="$(cat)"

# Cheap no-op gate: only a crew-set call can possibly be gated.
case "$INPUT" in
  *crew-set*) ;;
  *) exit 0 ;;
esac

printf '%s' "$INPUT" | \
  WINGMAN_HOME="${WINGMAN_HOME:-$HOME/.wingman}" \
  WM_LINK_STATE_PY="$STATE_PY" \
  WM_LINK_UV="$WM_UV" \
  PYTHONPATH="$HERE/lib${PYTHONPATH:+:$PYTHONPATH}" $WM_UV python -c '
import hashlib, json, os, re, subprocess, sys

from cmd_match import command_segments, resolve_command

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

if data.get("tool_name") != "Bash":
    sys.exit(0)
tool_input = data.get("tool_input", {}) or {}
command = tool_input.get("command", "") or ""
cwd = data.get("cwd") or os.getcwd()
sid = re.sub(r"[^A-Za-z0-9._-]", "_", data.get("session_id") or "")
home = os.path.expanduser(os.environ["WINGMAN_HOME"])


def flag_value(argv, name):
    for i, tok in enumerate(argv):
        if tok == name and i + 1 < len(argv):
            return argv[i + 1]
        if tok.startswith(name + "="):
            return tok[len(name) + 1:]
    return None


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
# list. This hook has a cheap substring pre-gate above (only a *crew-set*
# call reaches here at all), but once past it, a genuinely malformed
# crew-set call must still be denied rather than silently let through.
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


# Find the first crew-set segment reporting review/done.
segments = command_segments(command)
if segments is None:
    deny(PARSE_FAIL_REASON)

gated = None
for seg in segments:
    b, argv = resolve_command(seg)
    if b == "wm-state.py" and len(argv) > 1 and argv[1] == "crew-set":
        if flag_value(argv, "--status") in ("review", "done"):
            gated = argv
            break
if gated is None:
    sys.exit(0)

# Resolve the artifact to check: this call, else the crew record.
artifact = flag_value(gated, "--artifact")
if not artifact:
    member = flag_value(gated, "--id") or ""
    member = re.sub(r"[^A-Za-z0-9._-]", "_", member)
    if member:
        try:
            with open(os.path.join(home, "crew", member + ".json")) as fh:
                artifact = (json.load(fh) or {}).get("artifact") or ""
        except (OSError, ValueError):
            artifact = ""
if not artifact:
    sys.exit(0)  # never reported one - nothing to gate
if not artifact.endswith(".md"):
    sys.exit(0)  # not a rendering-sensitive deliverable
if not os.path.isabs(artifact):
    artifact = os.path.join(cwd, artifact)
artifact = os.path.realpath(artifact)

# Condition B applies only when the pilot cached artifact_linking=artifact for
# this run; unset (including no run id at all) defaults to local-only, which
# the contract resolves with its own fallback ask, not this gate.
run_id = os.environ.get("WINGMAN_RUN_ID") or ""
if not run_id:
    sys.exit(0)
try:
    pref = subprocess.run(
        os.environ["WM_LINK_UV"].split() + [os.environ["WM_LINK_STATE_PY"],
            "pref-get", "--run-id", run_id, "--key", "artifact_linking"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30)
    linking = pref.stdout.decode().strip() if pref.returncode == 0 else ""
except Exception:
    linking = ""
if linking != "artifact":
    sys.exit(0)


def sha256_of(path):
    try:
        with open(path, "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        return None


entry = None
if sid:
    try:
        with open(os.path.join(home, "artifact-markers", sid + ".json")) as fh:
            store = json.load(fh)
        if isinstance(store, dict):
            entry = store.get(artifact)
    except (OSError, ValueError):
        pass

if isinstance(entry, dict):
    status = entry.get("status")
    if status == "scan-failed":
        sys.exit(0)
    if status in ("published", "publish-failed") and entry.get("sha256") \
            and entry.get("sha256") == sha256_of(artifact):
        sys.exit(0)

stale = " (or was edited since the last publish/attempt)" if isinstance(entry, dict) else ""
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": (
            "You are reporting a markdown deliverable (%s) while the pilot'"'"'s "
            "cached artifact_linking preference for this run is `artifact`, but "
            "it has not been published as an Artifact%s (see "
            "playbooks/_status-contract.md, condition B). Do ONE of these, then "
            "re-run this exact crew-set - it will then succeed:\n"
            "1. Run $WINGMAN_BIN/lib/artifact-scan.sh %s and, if it passes, "
            "publish exactly that path via the Artifact tool (report the URL "
            "alongside the local path).\n"
            "2. If the Artifact call fails, retry once; a failed attempt is "
            "recorded automatically, so you can then report local-only and say "
            "the publish failed.\n"
            "3. If artifact-scan.sh returned fail:, that verdict is recorded "
            "automatically - report local-only and say plainly why publishing "
            "was skipped.\n"
            "4. If the Artifact tool is not available in this session at all, "
            "report --status blocked instead of retrying indefinitely."
            % (artifact, stale, artifact)
        ),
    }
}))
sys.exit(0)
' 2>/dev/null

exit 0
