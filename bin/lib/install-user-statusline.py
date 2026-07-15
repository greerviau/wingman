#!/usr/bin/env python3
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""install-user-statusline: idempotently register wingman's usage-quota
capture script (bin/lib/usage-statusline.py, issue #24) as the user-level
Claude Code `statusLine` command in a settings.json (default
~/.claude/settings.json).

Modeled directly on install-user-hook.py: same idempotent-merge posture,
same --check/install split, same "never touch a file that isn't valid JSON"
safety rule.

Three cases, distinguished by the existing `statusLine` key (if any):

  - unset: write {"type": "command", "command": "uv run --no-project
    --quiet <script>"}.
  - set to something else (the pilot configured a custom statusline, e.g.
    via /statusline): rewrite to {"type": "command", "command": "uv run
    --no-project --quiet <script> --chain <original command, shell-quoted>"}
    - this preserves the pilot's own visual statusline byte-for-byte (our
    script chains to it, passing its stdout straight through) while adding
    the capture side effect. `refreshInterval`/`padding`, if present on the
    statusLine object, are left untouched.
  - already pointing at our own script (a re-run of doctor): no-op, exactly
    like the hook installer's existing-entry detection.

--check reports registration status only (exit 0 registered, 1 not) and
never writes.
"""
import argparse
import json
import os
import shlex
import sys


def load_settings(path):
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        text = f.read()
    if not text.strip():
        return {}
    return json.loads(text)


def our_command_prefix(script):
    return "uv run --no-project --quiet %s" % script


def is_registered(settings, script):
    """True iff statusLine.command already invokes our own script (as
    either the direct command or the --chain wrapper around some other
    command - either way, our capture side effect is already wired in)."""
    status_line = settings.get("statusLine")
    if not isinstance(status_line, dict):
        return False
    command = status_line.get("command")
    if not isinstance(command, str):
        return False
    return our_command_prefix(script) in command


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--settings", required=True, help="path to settings.json")
    ap.add_argument("--script", required=True, help="absolute path to usage-statusline.py")
    ap.add_argument("--check", action="store_true", help="report status only, never write")
    args = ap.parse_args()

    try:
        settings = load_settings(args.settings)
    except (OSError, json.JSONDecodeError) as e:
        print("error: could not read %s: %s" % (args.settings, e), file=sys.stderr)
        sys.exit(2)

    registered = is_registered(settings, args.script)

    if args.check:
        sys.exit(0 if registered else 1)

    if registered:
        print("already registered in %s" % args.settings)
        sys.exit(0)

    status_line = settings.get("statusLine")
    prior_command = None
    if isinstance(status_line, dict) and isinstance(status_line.get("command"), str):
        prior_command = status_line["command"]

    our_command = our_command_prefix(args.script)
    if prior_command:
        our_command += " --chain " + shlex.quote(prior_command)

    new_status_line = dict(status_line) if isinstance(status_line, dict) else {}
    new_status_line["type"] = "command"
    new_status_line["command"] = our_command
    settings["statusLine"] = new_status_line

    parent = os.path.dirname(args.settings)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(args.settings, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")

    if prior_command:
        print("registered in %s (chained to prior statusLine command)" % args.settings)
    else:
        print("registered in %s" % args.settings)


if __name__ == "__main__":
    main()
