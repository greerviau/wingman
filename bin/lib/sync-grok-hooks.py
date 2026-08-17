#!/usr/bin/env python3
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""sync-grok-hooks: reconcile grok's PERSONAL-scope hooks file
($HOME/.grok/hooks/wingman.json) against bin/lib/user-hooks.json's
orchestrator-active, grok-portable subset (the orchestrator-guard-
transports plan, §5.4.3).

Unlike sync-user-hooks.py (which merges into a Claude Code settings.json
that also carries unrelated settings), this file is wingman's OWN - nothing
else writes to it - so the whole desired document is rendered fresh every
run and written only when it differs from what is already on disk, rather
than reconciled group-by-group. Personal scope only (no project-scoped
file): grok's own trust gate applies to PROJECT hooks
(<project>/.grok/hooks/*.json), never to $HOME/.grok/hooks/*.json (plan
§3.4), so there is no --trust machinery to route around here at all.

One combined PreToolUse entry, matcher `^(Bash|apply_patch|Edit|Write)$`
(the same tool-name set codex uses - grok "the same map applied inside the
dispatcher", plan §5.3), whose command is a single hooks/lib/
guard_dispatch.py --dialect grok --guards <all-portable-guard-names>
invocation - mirrors codex's own single-matcher-group shape (plan §5.4.2),
since both dialects only ever need one PreToolUse registration for the
whole guard set.

timeout is 30s, not grok's own 5s default: a cold `uv` start slower than 5s
would otherwise read as a hook failure, and grok is documented FAIL-OPEN on
exactly that (plan §3.4's own "everything else ... is fail-open" clause) -
so a too-short timeout is a silent, total loss of enforcement, not a merely
slow one. This is a mitigation, not a cure: grok itself cannot be made
fail-closed on a genuine crash/timeout/malformed-output case. The §5.4.0
self-test (bin/lib/guard-transport.sh) and the dispatcher's own dual
stdout+stderr deny channels are the other two mitigations for the same
documented residual.

Fails closed on every ambiguity, matching sync-user-hooks.py's own posture:
a missing/non-executable dispatcher script, an unparseable manifest, or an
unparseable existing wingman.json is a non-zero exit and writes nothing.
Concurrent writers are serialised via an flock on a sidecar lock file.
"""
import argparse
import fcntl
import json
import os
import stat
import sys

from hook_manifest import default_manifest, default_repo, load_manifest, portable_entries

DIALECT = "grok"
MATCHER = "^(Bash|apply_patch|Edit|Write)$"
TIMEOUT_SECONDS = 30


def default_settings_path():
    return os.path.join(os.path.expanduser("~"), ".grok", "hooks", "wingman.json")


def check_dispatcher(repo):
    # Existence only - the dispatcher is invoked as `uv run ... <path>`, not
    # executed directly, so unlike the .sh entry points hook_manifest.
    # check_scripts() checks, its own +x bit is irrelevant.
    dispatcher = os.path.join(repo, "hooks", "lib", "guard_dispatch.py")
    if not os.path.exists(dispatcher):
        print(f"error: dispatcher script not found: {dispatcher}", file=sys.stderr)
        sys.exit(2)
    return dispatcher


def guard_names(manifest, repo):
    names = sorted(set(
        hook["guard"] for _group, hook, _command, _event, _matcher in portable_entries(manifest, repo, DIALECT)
        if hook.get("guard")
    ))
    return names


def desired_document(manifest, repo, wm_uv):
    dispatcher = check_dispatcher(repo)
    names = guard_names(manifest, repo)
    command = "%s %s --dialect %s --guards %s" % (wm_uv, dispatcher, DIALECT, ",".join(names))
    return {
        "hooks": {
            "PreToolUse": [
                {
                    "matcher": MATCHER,
                    "hooks": [
                        {"type": "command", "command": command, "timeout": TIMEOUT_SECONDS},
                    ],
                }
            ]
        }
    }


def load_existing(path):
    if not os.path.exists(path):
        return None
    with open(path) as f:
        text = f.read()
    if not text.strip():
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError as e:
        print(f"error: could not parse existing {path}: {e}", file=sys.stderr)
        sys.exit(2)


def write_document(path, doc):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    mode = None
    if os.path.exists(path):
        mode = stat.S_IMODE(os.stat(path).st_mode)
    tmp_path = f"{path}.tmp-{os.getpid()}"
    with open(tmp_path, "w") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    if mode is not None:
        os.chmod(tmp_path, mode)
    os.replace(tmp_path, path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--settings", default=None, help="path to $HOME/.grok/hooks/wingman.json (default: real path)")
    ap.add_argument("--manifest", default=None, help="path to user-hooks.json (default: sibling of this script)")
    ap.add_argument("--repo", default=None, help="repo root the dispatcher command resolves against")
    ap.add_argument("--wm-uv", default="uv run --no-project --quiet", help="the uv invocation prefix to bake into the registered command")
    ap.add_argument("--check", action="store_true", help="report status only, never write")
    args = ap.parse_args()

    settings_path = args.settings or default_settings_path()
    manifest_path = args.manifest or default_manifest()
    repo = args.repo or default_repo()

    manifest = load_manifest(manifest_path)
    desired = desired_document(manifest, repo, args.wm_uv)
    existing = load_existing(settings_path)

    if existing == desired:
        sys.exit(0)

    if args.check:
        sys.exit(1)

    lock_path = f"{settings_path}.wm-lock"
    parent = os.path.dirname(settings_path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    try:
        lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
    except OSError as e:
        print(f"error: could not open lock file {lock_path}: {e}", file=sys.stderr)
        sys.exit(2)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        existing = load_existing(settings_path)
        if existing != desired:
            write_document(settings_path, desired)
            print(f"wrote grok hooks file: {settings_path}", file=sys.stderr)
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)

    sys.exit(0)


if __name__ == "__main__":
    main()
