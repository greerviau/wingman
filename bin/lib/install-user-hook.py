#!/usr/bin/env python3
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""install-user-hook: idempotently register a hook entry in a user-level
Claude Code settings.json (default ~/.claude/settings.json), under the hook
event named by --event (default PreToolUse).

Used by bin/doctor to wire the hooks that must fire for sessions whose
project root is some other repo into user scope: hooks/no-direct-edit-guard.sh
(issue #17, covering a lead spawned with --repo <other-project> or --scope
global) and the Artifact-publish pair (hooks/artifact-publish-tracker.sh
under PostToolUse/PostToolUseFailure, hooks/artifact-link-guard.sh under
PreToolUse, covering crew sessions in any repo). A project-level entry in
this repo's .claude/settings.json never loads for those sessions.

Merges additively: existing hook groups (this tool's own or anyone else's)
are preserved untouched. Detected as "already registered" by an exact match
of the hook command string in an existing group under the same event, so
re-running is a no-op per event. Never overwrites the file if its existing
content is not valid JSON - that is the pilot's own file and may carry other
settings.

--check reports registration status only (exit 0 registered, 1 not) and
never writes.
"""
import argparse
import json
import os
import sys


def load_settings(path):
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        text = f.read()
    if not text.strip():
        return {}
    return json.loads(text)


def is_registered(settings, hook_command, event):
    groups = (settings.get("hooks") or {}).get(event) or []
    if not isinstance(groups, list):
        return False
    for group in groups:
        if not isinstance(group, dict):
            continue
        for h in group.get("hooks") or []:
            if isinstance(h, dict) and h.get("command") == hook_command:
                return True
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--settings", required=True, help="path to settings.json")
    ap.add_argument("--hook", required=True, help="absolute path to the hook script")
    ap.add_argument("--matcher", default="Edit|Write|NotebookEdit|Bash")
    ap.add_argument("--event", default="PreToolUse", help="hook event to register under")
    ap.add_argument("--check", action="store_true", help="report status only, never write")
    args = ap.parse_args()

    try:
        settings = load_settings(args.settings)
    except (OSError, json.JSONDecodeError) as e:
        print(f"error: could not read {args.settings}: {e}", file=sys.stderr)
        sys.exit(2)

    registered = is_registered(settings, args.hook, args.event)

    if args.check:
        sys.exit(0 if registered else 1)

    if registered:
        print(f"already registered in {args.settings}")
        sys.exit(0)

    settings.setdefault("hooks", {})
    settings["hooks"].setdefault(args.event, [])
    settings["hooks"][args.event].append({
        "matcher": args.matcher,
        "hooks": [{"type": "command", "command": args.hook}],
    })

    parent = os.path.dirname(args.settings)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(args.settings, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")

    print(f"registered in {args.settings}")


if __name__ == "__main__":
    main()
