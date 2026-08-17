#!/usr/bin/env python3
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""sync-user-skills: reconcile an agent CLI's user-level skills directory
against this repo's canonical .agents/skills/ tree (the portable crew
command vocabulary - see .agents/skills/ itself and CLAUDE.md/AGENTS.md's
"a portable crew command vocabulary" note).

codex, grok, and opencode have no per-launch flag for an arbitrary skills
directory (pi does; claude reaches the tree via --add-dir instead), so each
is served by installing a per-adapter, home-directory link set that mirrors
the repo's own wingman-<verb> skills. This runs from each of those three
descriptors' own WM_AGENT_PREFLIGHT, on every spawn and resume - modelled
directly on sync-user-hooks.py's own preflight-time reconciliation of
user-scope guard hooks, so a guard hook that has been merged and a skill
that has been added are both live the moment a session actually launches,
never dependent on someone remembering to run a separate install step - and
is also wired into bin/doctor so the installed state is inspectable and
repairable outside a spawn.

Two install modes:

  symlink (default) - `<target>/wingman-<verb>` is a symlink to
  `<repo>/.agents/skills/wingman-<verb>`. codex's own documentation confirms
  it follows a symlinked skill folder; grok's and opencode's do not document
  symlink behaviour either way, so this is a gated assumption for those two,
  hands-on verified per adapter before either one ships on this route - use
  --mode copy for either one if hands-on verification shows the symlink is
  not followed.

  copy - `<target>/wingman-<verb>/SKILL.md` is a real copy of the repo's
  file, alongside a sidecar `.wm-sync-hash` recording its content hash.
  Every subsequent run compares the hash and rewrites the copy whenever the
  repo's own file has changed, so drift is repaired on the next reconcile
  rather than merely detected. The sidecar is also what marks a directory as
  ours: a `wingman-<verb>` directory with no `.wm-sync-hash` inside is a
  human's own, never touched.

Idempotence and safety (identical in both modes): only `wingman-*` names are
ever created, replaced, or removed; a `wingman-*` entry this script did not
create (no matching symlink target inside this repo's own canonical tree,
and no `.wm-sync-hash` marker) is reported and left alone; a `wingman-<verb>`
entry whose verb no longer exists in the repo's own tree is removed, so a
retired command does not linger machine-wide; every other name under
`--target` is never touched, read, or considered.

Fails closed on an unwritable target: --check reports status only and never
writes; concurrent writers are serialised via a sidecar lock file (never on
any file under --target itself).
"""
import argparse
import fcntl
import hashlib
import os
import sys

MARKER = ".wm-sync-hash"


def default_repo():
    # bin/lib/sync-user-skills.py -> bin/lib -> bin -> repo root, the same
    # three-dirname walk sync-user-hooks.py does.
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def repo_skill_dirs(repo):
    """{verb: absolute path to <repo>/.agents/skills/wingman-<verb>} for every
    wingman-<verb>/SKILL.md actually present in the canonical tree - never a
    hardcoded verb list, so a verb added or removed there is picked up
    automatically with no change needed here."""
    skills_root = os.path.join(repo, ".agents", "skills")
    out = {}
    if not os.path.isdir(skills_root):
        return out
    for name in sorted(os.listdir(skills_root)):
        if not name.startswith("wingman-"):
            continue
        d = os.path.join(skills_root, name)
        if os.path.isfile(os.path.join(d, "SKILL.md")):
            out[name] = os.path.abspath(d)
    return out


def content_hash(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def is_managed(entry_path):
    """True if `entry_path` (a `<target>/wingman-<verb>` path) was created by
    this script in EITHER mode - a symlink shaped like one we create, or a
    directory carrying our `.wm-sync-hash` marker. Anything else (a plain
    file, a plain directory with no marker, a symlink pointing somewhere
    unrelated) is a human's own and is never touched, regardless of which
    mode this run was asked for.

    The symlink check is STRUCTURAL (does the target path end in
    `.agents/skills/<this-same-verb-name>`), not an equality check against
    the current repo root - deliberately, so a symlink this script created
    for a repository that has since moved (now broken: its old target no
    longer exists) is still recognised as ours and re-pointed, rather than
    misread as an unrelated human symlink because the paths no longer
    match."""
    verb = os.path.basename(entry_path)
    if os.path.islink(entry_path):
        try:
            raw_target = os.readlink(entry_path)
        except OSError:
            return False
        if not os.path.isabs(raw_target):
            raw_target = os.path.normpath(os.path.join(os.path.dirname(entry_path), raw_target))
        return raw_target.endswith(os.path.join(".agents", "skills", verb))
    if os.path.isdir(entry_path):
        return os.path.isfile(os.path.join(entry_path, MARKER))
    return False


def plan(target, repo, mode):
    """Compute (installs, removals, skipped) without touching disk.
    installs: list of (verb, desired_repo_path) needing install/update.
    removals: list of verb names to remove (managed, no longer in the repo).
    skipped: list of (verb, reason) for a `wingman-*` entry that exists but
    is not ours to touch."""
    desired = repo_skill_dirs(repo)

    installs = []
    skipped = []
    existing_names = set()
    if os.path.isdir(target):
        existing_names = {n for n in os.listdir(target) if n.startswith("wingman-")}

    for verb, desired_path in desired.items():
        entry = os.path.join(target, verb)
        if not os.path.exists(entry) and not os.path.islink(entry):
            installs.append((verb, desired_path))
            continue
        if not is_managed(entry):
            skipped.append((verb, "exists and is not managed by this installer (not a symlink into this repo, no .wm-sync-hash marker) - left untouched"))
            continue
        if mode == "symlink":
            if os.path.islink(entry) and os.path.realpath(entry) == os.path.realpath(desired_path):
                continue  # already correct
            installs.append((verb, desired_path))
        else:  # copy
            # A managed entry that is currently a SYMLINK (e.g. a mode
            # switch from a prior symlink-mode install) is never already
            # correct in copy mode, however its content compares - checked
            # first and unconditionally, the same symmetry the symlink
            # branch above already has for the reverse case. Without this,
            # `<entry>/SKILL.md` resolves THROUGH the symlink straight back
            # to the source, so the content comparison below would compare
            # the source against itself and silently treat a symlink as a
            # correct copy, never actually converting it.
            if os.path.islink(entry):
                installs.append((verb, desired_path))
                continue
            # Compares the COPY's actual live content against the SOURCE's
            # actual live content, every time - never the stored .wm-sync-hash
            # marker against the source alone. A marker-vs-source-only
            # comparison would miss drift in the copy itself (a hand-edit, a
            # bug elsewhere, filesystem corruption) as long as the marker
            # file happened to survive untouched alongside it - the marker
            # exists to mark ownership (is_managed above), never as the
            # source of truth for whether a reinstall is needed.
            skill_md = os.path.join(entry, "SKILL.md")
            src = os.path.join(desired_path, "SKILL.md")
            if os.path.isfile(skill_md) and content_hash(skill_md) == content_hash(src):
                continue  # already correct
            installs.append((verb, desired_path))

    removals = []
    for verb in sorted(existing_names - set(desired)):
        entry = os.path.join(target, verb)
        if is_managed(entry):
            removals.append(verb)
        # else: unmanaged and not desired - not ours, never touched, never
        # even worth reporting (nothing about it relates to this installer).

    return installs, removals, skipped


def apply_install(target, verb, desired_path, mode):
    entry = os.path.join(target, verb)
    if os.path.islink(entry) or os.path.isfile(entry):
        os.remove(entry)
    elif os.path.isdir(entry):
        # A managed copy-mode directory being replaced (mode switch, or a
        # stale copy) - remove its contents before recreating.
        for name in os.listdir(entry):
            os.remove(os.path.join(entry, name))
        os.rmdir(entry)

    if mode == "symlink":
        os.symlink(desired_path, entry)
    else:
        os.makedirs(entry, exist_ok=True)
        src = os.path.join(desired_path, "SKILL.md")
        with open(src, "rb") as f:
            data = f.read()
        with open(os.path.join(entry, "SKILL.md"), "wb") as f:
            f.write(data)
        with open(os.path.join(entry, MARKER), "w") as f:
            f.write(hashlib.sha256(data).hexdigest())


def apply_removal(target, verb):
    entry = os.path.join(target, verb)
    if os.path.islink(entry) or os.path.isfile(entry):
        os.remove(entry)
    elif os.path.isdir(entry):
        for name in os.listdir(entry):
            os.remove(os.path.join(entry, name))
        os.rmdir(entry)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", required=True, help="the adapter's user-level skills directory to reconcile (e.g. ~/.agents/skills, ~/.grok/skills, ~/.config/opencode/skills)")
    ap.add_argument("--repo", default=None, help="repo root the canonical .agents/skills/ tree lives under (default: this script's own repo)")
    ap.add_argument("--mode", choices=["symlink", "copy"], default="symlink", help="symlink (default) or copy-with-checksum reconcile (for an adapter that does not follow a symlinked skill folder)")
    ap.add_argument("--check", action="store_true", help="report status only, never write")
    ap.add_argument("--report", action="store_true", help="with --check, print what would change to stdout")
    args = ap.parse_args()

    repo = os.path.abspath(args.repo or default_repo())
    target = os.path.abspath(os.path.expanduser(args.target))

    installs, removals, skipped = plan(target, repo, args.mode)

    # --check and the no-op fast path both report from this one computation
    # and go no further - the warnings below are this run's only print of
    # them. The write path (below) does NOT print from this computation: it
    # re-plans under the lock instead (state may have moved since this read)
    # and reports from that authoritative recomputation, so a skipped-entry
    # warning is never printed twice in the same run.
    if args.check:
        for verb, reason in skipped:
            print(f"warning: {verb}: {reason}", file=sys.stderr)
        if args.report:
            for verb, _path in installs:
                print(f"install: {verb}")
            for verb in removals:
                print(f"remove: {verb}")
        sys.exit(1 if (installs or removals) else 0)

    if not installs and not removals:
        for verb, reason in skipped:
            print(f"warning: {verb}: {reason}", file=sys.stderr)
        sys.exit(0)

    # --- write mode: serialise via a sidecar lock, then re-plan under it -----
    parent = os.path.dirname(target) or "."
    try:
        os.makedirs(parent, exist_ok=True)
        lock_path = os.path.join(parent, f".{os.path.basename(target)}.wm-lock")
        lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
    except OSError as e:
        print(f"error: could not open lock file for {target}: {e}", file=sys.stderr)
        sys.exit(2)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        os.makedirs(target, exist_ok=True)

        installs, removals, skipped = plan(target, repo, args.mode)
        for verb, reason in skipped:
            print(f"warning: {verb}: {reason}", file=sys.stderr)

        for verb, desired_path in installs:
            apply_install(target, verb, desired_path, args.mode)
            print(f"installed: {target}/{verb}", file=sys.stderr)
        for verb in removals:
            apply_removal(target, verb)
            print(f"removed: {target}/{verb} (verb no longer in the repo's own .agents/skills/)", file=sys.stderr)
    except OSError as e:
        print(f"error: could not reconcile {target}: {e}", file=sys.stderr)
        sys.exit(2)
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)

    sys.exit(0)


if __name__ == "__main__":
    main()
