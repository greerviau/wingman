#!/usr/bin/env python3
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""hook_manifest: manifest reading and script existence/executability
checking, shared by every reconciler that reads bin/lib/user-hooks.json -
bin/lib/sync-user-hooks.py (claude-json) and, per the orchestrator-guard-
transports plan, bin/lib/sync-codex-hooks.py and bin/lib/sync-grok-hooks.py.
Factored out of sync-user-hooks.py's own original functions of the same name
(issue #241) so the manifest-parsing/script-checking logic lives once rather
than drifting across three reconcilers - sync-user-hooks.py's own behaviour
is unchanged by this factoring (a decision-logic move, not a policy change);
it now imports these four functions rather than defining them itself.
"""
import json
import os
import sys


def default_repo():
    # bin/lib/hook_manifest.py -> bin/lib -> bin -> repo root, the same
    # three-dirname walk bin/lib/common.sh does (WM_LIB -> WM_BIN -> WM_REPO).
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def default_manifest():
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "user-hooks.json")


def load_manifest(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"error: could not read manifest {path}: {e}", file=sys.stderr)
        sys.exit(2)


def flat_entries(manifest, repo):
    """Yield (group, hook_dict, command, event, matcher_or_None) for every
    hook entry in the manifest, with `command` resolved to an absolute path
    under `repo`."""
    for group in manifest.get("groups", []):
        for hook in group.get("hooks", []):
            command = os.path.join(repo, hook["script"])
            event = hook["event"]
            matcher = None if event == "Stop" else hook.get("matcher", "Edit|Write|NotebookEdit|Bash")
            yield group, hook, command, event, matcher


def check_scripts(manifest, repo):
    """Fail closed on any manifest script that does not exist or is not
    executable. Returns nothing; exits 2 (printing every failure) if any."""
    failures = []
    for _group, _hook, command, _event, _matcher in flat_entries(manifest, repo):
        if not os.path.exists(command):
            failures.append(f"hook script not found: {command}")
        elif not os.access(command, os.X_OK):
            failures.append(f"hook script not executable: {command}")
    if failures:
        for f in failures:
            print(f"error: {f}", file=sys.stderr)
        sys.exit(2)


def portable_entries(manifest, repo, dialect):
    """Yield (group, hook_dict, command, event, matcher_or_None) for every
    hook entry whose own 'portable' array names `dialect` - the orchestrator-
    active subset a non-Claude reconciler (sync-codex-hooks.py,
    sync-grok-hooks.py) or the opencode/pi shim templates render, without any
    of them hard-coding which hooks that is (plan §5.2's own triage lives
    once, in the manifest, via this field - see user-hooks.json's own
    top-level _comment)."""
    for group, hook, command, event, matcher in flat_entries(manifest, repo):
        if dialect in (hook.get("portable") or []):
            yield group, hook, command, event, matcher
