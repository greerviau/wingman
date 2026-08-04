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
are preserved untouched. Detected as "already registered" by matching the
hook command string in an existing group under the same event, plus - when
--async-rewake/--timeout/--rewake-summary are supplied - every attribute they
name (issue #231, via bin/lib/user_hook_entry.py's opt-in comparison): a
caller that supplies none of the three matches on command alone, exactly as
before. A same-command entry that mismatches on a supplied attribute (e.g. a
stale `timeout`) is rewritten in place rather than left alone or duplicated -
appending a second group for the same command would leave two live
registrations racing each other. Never overwrites the file if its existing
content is not valid JSON - that is the pilot's own file and may carry other
settings.

--async-rewake/--timeout/--rewake-summary (issue #199) mirror the
asyncRewake/timeout/rewakeSummary keys this repo's own project-scoped
.claude/settings.json already carries for hooks/stop-continuity.sh, so the
identical shape can be registered at user scope for
hooks/stop-continuity-crew.sh. A Stop event has no tool to match against, so
--event Stop omits the "matcher" key entirely rather than writing the
otherwise-default matcher string into an entry where it is meaningless.

--check reports registration status only (exit 0 registered, 1 not) and
never writes.
"""
import argparse
import json
import os
import sys

# Sibling import - both scripts live in bin/lib/, and `uv run script.py` puts
# the script's own directory at sys.path[0] automatically.
from user_hook_entry import desired_entry, entry_matches


def load_settings(path):
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        text = f.read()
    if not text.strip():
        return {}
    return json.loads(text)


def find_entry(settings, hook_command, event):
    """The hook dict registered for `hook_command` under `event`, or None if
    no entry names that command at all (regardless of its other
    attributes)."""
    groups = (settings.get("hooks") or {}).get(event) or []
    if not isinstance(groups, list):
        return None
    for group in groups:
        if not isinstance(group, dict):
            continue
        for h in group.get("hooks") or []:
            if isinstance(h, dict) and h.get("command") == hook_command:
                return h
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--settings", required=True, help="path to settings.json")
    ap.add_argument("--hook", required=True, help="absolute path to the hook script")
    ap.add_argument("--matcher", default="Edit|Write|NotebookEdit|Bash")
    ap.add_argument("--event", default="PreToolUse", help="hook event to register under")
    ap.add_argument("--check", action="store_true", help="report status only, never write")
    ap.add_argument("--async-rewake", action="store_true", help='set "asyncRewake": true on the entry')
    ap.add_argument("--timeout", type=int, default=None, help='set "timeout": <int> on the entry')
    ap.add_argument("--rewake-summary", default=None, help='set "rewakeSummary": <str> on the entry')
    args = ap.parse_args()

    try:
        settings = load_settings(args.settings)
    except (OSError, json.JSONDecodeError) as e:
        print(f"error: could not read {args.settings}: {e}", file=sys.stderr)
        sys.exit(2)

    # Opt-in attribute comparison (issue #231): entry_options only carries a
    # key for a flag the caller actually supplied, so a caller that supplies
    # none of the three (every call site but the fleet-continuity pair)
    # compares `command` alone, exactly as before.
    entry_options = {}
    if args.async_rewake:
        entry_options["asyncRewake"] = True
    if args.timeout is not None:
        entry_options["timeout"] = args.timeout
    if args.rewake_summary is not None:
        entry_options["rewakeSummary"] = args.rewake_summary

    existing = find_entry(settings, args.hook, args.event)
    registered = existing is not None and entry_matches(existing, args.hook, entry_options)

    if args.check:
        sys.exit(0 if registered else 1)

    if registered:
        print(f"already registered in {args.settings}")
        sys.exit(0)

    if existing is not None:
        # A same-command entry is already present but disagrees with the
        # given entry_options (e.g. a stale `timeout`) - rewrite it in place
        # rather than appending a duplicate group for the same command, which
        # would leave two live registrations racing each other. Merged, not
        # cleared-and-replaced: a key this call never named (a pilot's own
        # addition, a future Claude Code field) survives untouched.
        existing.update(desired_entry(args.hook, entry_options))
        with open(args.settings, "w") as f:
            json.dump(settings, f, indent=2)
            f.write("\n")
        print(f"updated in {args.settings}")
        sys.exit(0)

    hook_entry = desired_entry(args.hook, entry_options)

    group = {"hooks": [hook_entry]}
    # A Stop event has no tool to match against - the existing project-scoped
    # .claude/settings.json Stop entries carry no "matcher" key at all, so
    # writing one here would be a nonsensical key on a Stop entry.
    if args.event != "Stop":
        group["matcher"] = args.matcher

    settings.setdefault("hooks", {})
    settings["hooks"].setdefault(args.event, [])
    settings["hooks"][args.event].append(group)

    parent = os.path.dirname(args.settings)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(args.settings, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")

    print(f"registered in {args.settings}")


if __name__ == "__main__":
    main()
