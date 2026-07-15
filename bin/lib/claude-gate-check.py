#!/usr/bin/env python3
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""claude-gate-check: non-interactively read the two persisted signals that
say whether a Claude Code gate is already cleared for this machine/repo, so
bin/doctor and bin/spawn-crew can detect a frozen-dialog-in-waiting before it
ever happens, rather than reactively via bin/watch-fleet's stall detection
(issue #16).

- `bypass-status --settings <path>`: exit 0 if the one-time,
  once-per-user Bypass-Permissions dialog has been accepted
  (skipDangerousModePermissionPrompt is true in the user settings file),
  exit 1 otherwise.
- `bypass-set --settings <path>`: idempotently merges
  {"skipDangerousModePermissionPrompt": true} into the settings file,
  preserving every other key - only ever invoked after explicit consent
  (bin/doctor's own y/N or -y gate). Refuses (exit 2) if the existing file
  content is not valid JSON, exactly like install-user-hook.py's own rule.
- `trust-status --config <path> --repo <abs-path>`: exit 0 if the one-time,
  per-directory workspace-trust dialog has been accepted for <abs-path>
  (projects[<abs-path>].hasTrustDialogAccepted is true in the main config
  file), exit 1 otherwise. Read-only: there is deliberately no `trust-set`
  (see the plan's "Why the trust gate is detect-and-block, not auto-clear").

Every subcommand treats a missing file, missing key, or invalid JSON as "not
accepted" (exit 1) rather than erroring - a corrupt or absent file must never
be read as a false "accepted".
"""
import argparse
import json
import os
import sys


def load_json(path):
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        text = f.read()
    if not text.strip():
        return {}
    try:
        return json.loads(text)
    except ValueError:
        return None  # invalid JSON, distinguished from "absent" for bypass-set's exit 2


def cmd_bypass_status(args):
    data = load_json(args.settings)
    if data is None:
        sys.exit(1)
    sys.exit(0 if data.get("skipDangerousModePermissionPrompt") is True else 1)


def cmd_bypass_set(args):
    data = load_json(args.settings)
    if data is None:
        print(f"error: {args.settings} exists but is not valid JSON; refusing to overwrite", file=sys.stderr)
        sys.exit(2)

    data["skipDangerousModePermissionPrompt"] = True

    parent = os.path.dirname(args.settings)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(args.settings, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")

    print(f"skipDangerousModePermissionPrompt set in {args.settings}")


def cmd_trust_status(args):
    data = load_json(args.config)
    if data is None:
        sys.exit(1)
    projects = data.get("projects")
    if not isinstance(projects, dict):
        sys.exit(1)
    entry = projects.get(args.repo)
    if not isinstance(entry, dict):
        sys.exit(1)
    sys.exit(0 if entry.get("hasTrustDialogAccepted") is True else 1)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("bypass-status")
    p.add_argument("--settings", required=True, help="path to the user settings.json")
    p.set_defaults(func=cmd_bypass_status)

    p = sub.add_parser("bypass-set")
    p.add_argument("--settings", required=True, help="path to the user settings.json")
    p.set_defaults(func=cmd_bypass_set)

    p = sub.add_parser("trust-status")
    p.add_argument("--config", required=True, help="path to the main config (~/.claude.json)")
    p.add_argument("--repo", required=True, help="physically-normalized absolute repo path")
    p.set_defaults(func=cmd_trust_status)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
