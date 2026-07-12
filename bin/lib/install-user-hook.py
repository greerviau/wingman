#!/usr/bin/env python3
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""install-user-hook: idempotently register a PreToolUse hook entry in a
user-level Claude Code settings.json (default ~/.claude/settings.json).

Used by bin/doctor to wire hooks/no-direct-edit-guard.sh (issue #17) into
user scope, so it loads for every Claude Code session on the machine
regardless of which repo a session's project root is - the only way a lead
spawned with --repo <other-project> or --scope global is actually covered.

Merges additively: existing hook groups (this tool's own or anyone else's)
are preserved untouched. Detected as "already registered" by an exact match
of the hook command string in an existing PreToolUse group, so re-running is
a no-op. Never overwrites the file if its existing content is not valid JSON
- that is the pilot's own file and may carry other settings.

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


def is_registered(settings, hook_command):
    groups = (settings.get("hooks") or {}).get("PreToolUse") or []
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
    ap.add_argument("--check", action="store_true", help="report status only, never write")
    args = ap.parse_args()

    try:
        settings = load_settings(args.settings)
    except (OSError, json.JSONDecodeError) as e:
        print(f"error: could not read {args.settings}: {e}", file=sys.stderr)
        sys.exit(2)

    registered = is_registered(settings, args.hook)

    if args.check:
        sys.exit(0 if registered else 1)

    if registered:
        print(f"already registered in {args.settings}")
        sys.exit(0)

    settings.setdefault("hooks", {})
    settings["hooks"].setdefault("PreToolUse", [])
    settings["hooks"]["PreToolUse"].append({
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
