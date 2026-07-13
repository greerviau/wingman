#!/usr/bin/env bash
# artifact-publish-tracker.sh - a Claude Code PostToolUse + PostToolUseFailure
# hook (matcher "Artifact|Bash"). Records, as an automatic side effect the
# agent can never skip, the facts hooks/artifact-link-guard.sh gates on: has
# the Artifact tool published (or failed to publish) a given file, and has
# bin/lib/artifact-scan.sh returned a fail: verdict for it.
#
# Markers live in $WINGMAN_HOME/artifact-markers/<session_id>.json, a dict
# keyed by the resolved (realpath) file path:
#   {"status": "published",      "url": <URL>,    "sha256": <content hash>}
#   {"status": "publish-failed", "reason": <msg>, "sha256": <content hash>}
#   {"status": "scan-failed"}
# The sha256 is the file's content hash at the moment of the attempt, so a
# later edit without republishing is detectable as stale by the guard.
# Entries accumulate per path (a member may publish several deliverables, or
# revise and republish one) rather than overwriting the file wholesale.
#
# Event wiring, confirmed empirically against the installed CLI build: a
# non-zero-exit Bash command or an errored/refused Artifact call fires
# PostToolUseFailure (whose input carries the failure text in an `error`
# string field), never PostToolUse - so the failure-side markers are recorded
# from that event. On PostToolUse (success), an Artifact call records
# "published"; a Bash artifact-scan.sh call needs no record, since its exit-0
# verdicts (pass/pass-soft) leave the publish decision to the subsequent
# Artifact call. On PostToolUseFailure, an Artifact call records
# "publish-failed", and a Bash artifact-scan.sh call whose error text carries
# a fail: verdict records "scan-failed" - a legitimate, recorded reason to
# skip publishing, so the guard never deadlocks on it.
#
# Registered user-level by bin/doctor (like the delegation guard): it must
# fire inside crew sessions whose project root is some other repo entirely,
# which a project-level entry in this repo's settings never covers. It
# therefore runs for every session on the machine - the no-op path below is
# one substring check, before any JSON parsing or python startup.
# bash-3.2-safe.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
WM_UV="${WM_UV:-uv run --no-project --quiet}"

INPUT="$(cat)"

# Cheap no-op gate: only an Artifact call or a command mentioning
# artifact-scan.sh can possibly need recording (false positives just fall
# through to the precise python check below).
case "$INPUT" in
  *'"Artifact"'*|*artifact-scan.sh*) ;;
  *) exit 0 ;;
esac

printf '%s' "$INPUT" | \
  WINGMAN_HOME="${WINGMAN_HOME:-$HOME/.wingman}" \
  PYTHONPATH="$HERE/lib${PYTHONPATH:+:$PYTHONPATH}" $WM_UV python -c '
import hashlib, json, os, re, sys

from cmd_match import command_segments, resolve_command

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

event = data.get("hook_event_name", "")
tool = data.get("tool_name", "")
tool_input = data.get("tool_input", {}) or {}
cwd = data.get("cwd") or os.getcwd()
sid = re.sub(r"[^A-Za-z0-9._-]", "_", data.get("session_id") or "")
if not sid or event not in ("PostToolUse", "PostToolUseFailure"):
    sys.exit(0)

home = os.path.expanduser(os.environ["WINGMAN_HOME"])
markers = os.path.join(home, "artifact-markers", sid + ".json")


def resolved(path):
    if not os.path.isabs(path):
        path = os.path.join(cwd, path)
    return os.path.realpath(path)


def sha256_of(path):
    try:
        with open(path, "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        return None


def record(path, entry):
    try:
        os.makedirs(os.path.dirname(markers), exist_ok=True)
        try:
            with open(markers) as fh:
                store = json.load(fh)
        except (OSError, ValueError):
            store = {}
        if not isinstance(store, dict):
            store = {}
        store[path] = entry
        tmp = markers + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(store, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.replace(tmp, markers)
    except OSError:
        pass


if tool == "Artifact":
    fp = tool_input.get("file_path") or ""
    if not fp:
        sys.exit(0)
    fp = resolved(fp)
    if event == "PostToolUse":
        resp = data.get("tool_response")
        url = ""
        if isinstance(resp, dict):
            url = resp.get("url") or ""
        if not url:
            text = resp if isinstance(resp, str) else json.dumps(resp)
            m = re.search(r"https://[^\s\"\\\\]+", text or "")
            url = m.group(0) if m else ""
        record(fp, {"status": "published", "url": url, "sha256": sha256_of(fp)})
    else:
        reason = str(data.get("error") or "")[:500]
        record(fp, {"status": "publish-failed", "reason": reason, "sha256": sha256_of(fp)})
    sys.exit(0)

if tool == "Bash":
    command = tool_input.get("command", "") or ""
    for seg in command_segments(command):
        b, argv = resolve_command(seg)
        if b != "artifact-scan.sh" or len(argv) < 2:
            continue
        args = [t for t in argv[1:] if not t.startswith("-")]
        if not args:
            continue
        target = resolved(args[0])
        if event == "PostToolUseFailure":
            # A fail: verdict exits 1, so it arrives here; the error field
            # carries the exit code line plus the scan
            # stdout/stderr, including the verdict line.
            error = str(data.get("error") or "")
            if re.search(r"^fail:", error, re.MULTILINE):
                record(target, {"status": "scan-failed"})
        # PostToolUse (exit 0) means pass/pass-soft: nothing to record - the
        # subsequent Artifact call (if made) records its own outcome.

sys.exit(0)
' 2>/dev/null

exit 0
