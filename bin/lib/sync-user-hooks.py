#!/usr/bin/env python3
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""sync-user-hooks: reconcile bin/lib/user-hooks.json (the declarative
manifest of every guard hook that needs USER-scope registration) against a
Claude Code user-level settings.json, registering whatever is missing.

Exists because bin/doctor - the only thing that has ever written these
registrations - only runs when a human remembers to run it. A guard hook
that has been merged is not a guard hook that is active until this
reconciles, so bin/wingman, bin/spawn-crew, and bin/crew-resume all run this
(fail-closed) immediately before a Claude Code session starts, at every one
of wingman's three session-creation choke points (issue #241).

Fails closed on every ambiguity - a missing or non-executable hook script, an
unparseable manifest, or an unparseable settings file is a non-zero exit and
writes nothing, never a partial registration. The common case (nothing
missing) exits 0 having done a single read and no write at all, since this
now runs on every crew spawn.

--check reports status only (exit 0 fully registered, 1 something missing)
and never writes; --report additionally lists what's missing, one per line,
to stdout. Concurrent writers are serialised via an flock on a sidecar lock
file (never on settings.json itself, which this replaces by rename) - this
does not serialise against Claude Code's own writes to the same file, a
pre-existing hazard this change does not widen.
"""
import argparse
import fcntl
import json
import os
import stat
import sys

# Sibling import - both scripts live in bin/lib/, and `uv run script.py` puts
# the script's own directory at sys.path[0] automatically.
from user_hook_entry import desired_entry, entry_matches


def default_repo():
    # bin/lib/sync-user-hooks.py -> bin/lib -> bin -> repo root, the same
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


def load_settings(path):
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        text = f.read()
    if not text.strip():
        return {}
    return json.loads(text)


def find_entry(settings, command, event):
    """The hook dict registered for `command` under `event`, or None if no
    entry names that command at all (regardless of its other attributes)."""
    groups = (settings.get("hooks") or {}).get(event) or []
    if not isinstance(groups, list):
        return None
    for group in groups:
        if not isinstance(group, dict):
            continue
        for h in group.get("hooks") or []:
            if isinstance(h, dict) and h.get("command") == command:
                return h
    return None


def compute_changes(manifest, repo, settings):
    """(missing, stale) - `missing` entries need a brand-new group appended;
    `stale` entries already exist (same command) but disagree with the
    manifest on an attribute the manifest's own entry_options names (e.g. an
    older `timeout`), so they need updating in place rather than duplicated.
    A hook whose manifest entry carries no entry_options at all can never be
    stale (entry_matches then compares `command` alone), matching the
    pre-#231 behavior for every hook but the fleet-continuity pair."""
    missing = []
    stale = []
    for _group, hook, command, event, matcher in flat_entries(manifest, repo):
        entry_options = hook.get("entry_options", {})
        existing = find_entry(settings, command, event)
        if existing is None:
            missing.append((hook, command, event, matcher))
        elif not entry_matches(existing, command, entry_options):
            stale.append((hook, command, event, existing))
    return missing, stale


def apply_changes(settings, missing, stale):
    """Append one new group per missing hook entry, and rewrite each stale
    entry's dict in place (never appending a duplicate group for a command
    already present) - a same-command entry read as "missing" just because
    an old `timeout` didn't match would otherwise leave two Stop groups both
    invoking the same script, the shorter-timeout one of which is the one
    that kills continuity. Mutates `settings` (and, for `stale`, the entry
    dicts nested inside it) in place."""
    for hook, command, event, matcher in missing:
        entry_options = hook.get("entry_options", {})
        hook_entry = desired_entry(command, entry_options)

        group = {"hooks": [hook_entry]}
        if event != "Stop":
            group["matcher"] = matcher

        settings.setdefault("hooks", {})
        settings["hooks"].setdefault(event, [])
        settings["hooks"][event].append(group)

    for hook, command, _event, existing in stale:
        entry_options = hook.get("entry_options", {})
        existing.clear()
        existing.update(desired_entry(command, entry_options))


def write_settings(path, settings):
    # The caller (main's write-mode block) has already created the parent
    # directory before opening the sidecar lock, so this only writes the file.
    mode = None
    if os.path.exists(path):
        mode = stat.S_IMODE(os.stat(path).st_mode)

    tmp_path = f"{path}.tmp-{os.getpid()}"
    with open(tmp_path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    if mode is not None:
        os.chmod(tmp_path, mode)
    os.replace(tmp_path, path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--settings", required=True, help="path to the user-level settings.json to reconcile")
    ap.add_argument("--manifest", default=None, help="path to user-hooks.json (default: sibling of this script)")
    ap.add_argument("--repo", default=None, help="repo root relative script paths resolve against (default: this script's own repo)")
    ap.add_argument("--check", action="store_true", help="report status only, never write")
    ap.add_argument("--report", action="store_true", help="with --check, print missing registrations to stdout")
    args = ap.parse_args()

    manifest_path = args.manifest or default_manifest()
    repo = args.repo or default_repo()

    manifest = load_manifest(manifest_path)
    check_scripts(manifest, repo)

    try:
        settings = load_settings(args.settings)
    except (OSError, json.JSONDecodeError) as e:
        print(f"error: could not read {args.settings}: {e}", file=sys.stderr)
        sys.exit(2)

    missing, stale = compute_changes(manifest, repo, settings)

    if not missing and not stale:
        sys.exit(0)

    if args.check:
        if args.report:
            for _hook, command, event, _matcher in missing:
                print(f"{event}: {command}")
            for _hook, command, event, _existing in stale:
                print(f"{event}: {command} (stale)")
        sys.exit(1)

    # --- write mode: serialise via a sidecar lock, then re-check under it ----
    lock_path = f"{args.settings}.wm-lock"
    try:
        parent = os.path.dirname(args.settings)
        if parent:
            os.makedirs(parent, exist_ok=True)
        lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
    except OSError as e:
        print(f"error: could not open lock file {lock_path}: {e}", file=sys.stderr)
        sys.exit(2)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)

        try:
            settings = load_settings(args.settings)
        except (OSError, json.JSONDecodeError) as e:
            print(f"error: could not read {args.settings}: {e}", file=sys.stderr)
            sys.exit(2)

        missing, stale = compute_changes(manifest, repo, settings)
        if missing or stale:
            apply_changes(settings, missing, stale)
            write_settings(args.settings, settings)
            for _hook, command, event, _matcher in missing:
                print(f"registered {event} hook: {command}", file=sys.stderr)
            for _hook, command, event, _existing in stale:
                print(f"updated {event} hook: {command}", file=sys.stderr)
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)

    sys.exit(0)


if __name__ == "__main__":
    main()
