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
  per-directory workspace-trust dialog has been accepted for <abs-path> or
  some ancestor of it (projects[<path>].hasTrustDialogAccepted is true in
  the main config file for <abs-path> itself or an ancestor), exit 1
  otherwise. The ancestor walk stops at the nearest enclosing git repository
  root, inclusive - it never crosses out of a git working tree to consult
  something above it. Hands-on verified (2026-08-18) against real Claude
  Code v2.1.234, launched in detached tmux panes with a scrubbed environment
  (`env -i`, no inherited CLAUDECODE/CLAUDE_CODE_CHILD_SESSION - an
  unscrubbed launch is not a fresh process and isn't admissible evidence
  either way), keying on the version-stable "Yes, I trust this folder"
  option row: a non-git directory inherits trust from any accepted ancestor
  up to `/` (confirmed 3 levels deep and with files already present, to rule
  out an empty-directory confound, against a positive control that renders
  the dialog with no trusted ancestor at all); a git repository's own root
  never inherits trust from anything above it, only from its own entry or a
  path inside the same working tree at or below that root. This is why a
  fresh `git init` repo under an already-trusted parent still renders the
  dialog (the incident this fix addresses), while a plain subdirectory of
  that same trusted parent does not, and a subdirectory of a *trusted* git
  repo inherits from the repo root the way a non-git directory inherits from
  a trusted ancestor. An explicit `hasTrustDialogAccepted: false` at some
  path along the walk does not itself block inheritance from beyond it - it
  only matters when the walk stops there (a git root behaves like an
  exact-match lookup precisely because the walk cannot go further). <abs-path>
  is expected to already be physically normalized (no trailing slash,
  symlinks resolved) by the caller; ancestors are derived from it by walking
  `os.path.dirname`, which stays physically normalized for every prefix of
  an already-resolved path. Read-only: there is deliberately no `trust-set`
  (see the plan's "Why the trust gate is detect-and-block, not auto-clear").

Every subcommand treats a missing file, missing key, or invalid JSON as "not
accepted" (exit 1) rather than erroring - a corrupt or absent file must never
be read as a false "accepted".
"""
import argparse
import json
import os
import subprocess
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


def git_toplevel(path):
    """Return the physically-resolved root of the git working tree enclosing
    <path>, or None if <path> is not inside one. A missing/broken git
    invocation degrades the same way as "not inside a git working tree" -
    the unbounded ancestor walk that falls out of that is the direction that
    was already correct before this repo boundary was known, not a new
    risk."""
    try:
        proc = subprocess.run(
            ["git", "-C", path, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True,
        )
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    toplevel = proc.stdout.strip()
    return os.path.realpath(toplevel) if toplevel else None


def path_and_ancestors(path, boundary=None):
    """Yield <path> itself, then each ancestor up to and including
    <boundary> if given, else up to and including '/'."""
    path = path.rstrip("/") or "/"
    yield path
    while path != "/" and path != boundary:
        path = os.path.dirname(path)
        yield path


def cmd_trust_status(args):
    data = load_json(args.config)
    if data is None:
        sys.exit(1)
    projects = data.get("projects")
    if not isinstance(projects, dict):
        sys.exit(1)
    boundary = git_toplevel(args.repo)
    for candidate in path_and_ancestors(args.repo, boundary):
        entry = projects.get(candidate)
        if isinstance(entry, dict) and entry.get("hasTrustDialogAccepted") is True:
            sys.exit(0)
    sys.exit(1)


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
