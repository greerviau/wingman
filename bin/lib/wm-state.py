#!/usr/bin/env python3
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""wm-state: the single reader/writer for wingman's machine-local state home.

State home (default ~/.wingman, override with $WINGMAN_HOME):
  crew.json         the roster wingman maintains at spawn time (a list of records)
  crew/<id>.json    the distilled status each crew member keeps current itself
  board.md          the human-readable render of the merged roster
  projects.json     the discovered-projects cache: {"name": "path"}
  acked.json        the last (id -> updated) event SURFACED to wingman (by a
                    watcher fire or a Stop-hook block), so it does not re-fire on
                    every needs-attention poll while it is being handled
  handled.json      the last (id -> updated) event fully HANDLED (surfaced AND the
                    roster reported), set only by the Stop hook when it lets a stop
                    proceed. Distinct from acked so a surfaced-but-unhandled event
                    can still re-block instead of being permanently suppressed
  crew-archive.jsonl  append-only history of records removed by `prune`, one JSON
                    object per line, so pruning keeps crew.json lean without losing
                    the record of who ran

The merged view of a crew member = its crew.json base record with the live
crew/<id>.json overlaid on top (status/summary/blocker/artifact/delivery/updated).
crew.json is the roster of record; crew/<id>.json is the live signal. Wingman
reads the merge; it never ingests panes or transcripts.

All JSON is handled here in Python so the shell scripts stay bash-3.2-safe and the
tool works whether or not jq is installed.
"""
import argparse
import contextlib
import datetime
import json
import os
import subprocess
import sys
import time

try:
    import fcntl
except ImportError:  # non-POSIX platform; with_locked degrades to best-effort
    fcntl = None

STATUS_FIELDS = ("status", "summary", "blocker", "artifact", "delivery", "updated")
# Live = the member is still in flight and stays on the board's Active list.
# `review` means "a deliverable is ready and in review" - it is announced to
# wingman once (like `blocked`) but the member keeps running, shepherding that
# deliverable to its final disposition (a build member watching its PR to
# merge/close; a spec member awaiting the pilot's review of its plan).
# `stalled` is externally observed and supervisor-flagged (never self-reported):
# the member shows no sign of life on any channel while claiming `working`; it is
# an unresolved problem, not a closed engagement - the remedy is takeover or
# stand-down.
LIVE_STATES = ("working", "blocked", "review", "stalled")
# Terminal = the engagement is complete and the member is safe to reap. A ready
# deliverable is `review`, never `done`; `done` is reached only at the natural end
# (PR merged/closed) or the pilot's explicit disposition.
TERMINAL_STATES = ("done", "died", "stood-down")
# States that wake wingman (surfaced by needs-attention, deduped per (id,updated)
# via the ack store). `review`, `blocked`, and `stalled` are both live AND
# surfaced: the pilot is pinged once, but the member stays in flight until
# someone disposes of it.
ATTENTION_STATES = ("blocked", "review", "done", "died", "stalled")


def home():
    return os.path.expanduser(os.environ.get("WINGMAN_HOME", "~/.wingman"))


def crew_json_path():
    return os.path.join(home(), "crew.json")


def crew_dir():
    return os.path.join(home(), "crew")


def status_path(cid):
    return os.path.join(crew_dir(), cid + ".json")


def board_path():
    return os.path.join(home(), "board.md")


def projects_path():
    return os.path.join(home(), "projects.json")


def acked_path():
    return os.path.join(home(), "acked.json")


def handled_path():
    return os.path.join(home(), "handled.json")


@contextlib.contextmanager
def with_locked(path):
    """Serialize a read-modify-write of a shared store across processes.

    write_json is atomic (os.replace), so no file is ever corrupted, but a
    whole-dict read-modify-write from two processes is last-writer-wins - a
    concurrent watcher fire()-and-ack and a Stop-hook ack can each discard the
    other's key. Holding an exclusive flock on <path>.lock across the entire
    read->modify->write closes that window. Best-effort: on a platform without
    fcntl (or if the lock cannot be taken) it proceeds without the lock rather than
    hard-fail, since the atomic replace still prevents corruption."""
    lock_path = path + ".lock"
    fh = None
    try:
        os.makedirs(os.path.dirname(lock_path), exist_ok=True)
        fh = open(lock_path, "w")
        if fcntl is not None:
            try:
                fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
            except OSError:
                pass  # best-effort
        yield
    finally:
        if fh is not None:
            if fcntl is not None:
                try:
                    fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
                except OSError:
                    pass
            fh.close()


def archive_path():
    return os.path.join(home(), "crew-archive.jsonl")


def ask_dir():
    return os.path.join(home(), "ask")


def ask_path(req):
    return os.path.join(ask_dir(), req + ".json")


def now():
    # UTC, microsecond precision, ISO-8601 with a trailing Z. Microsecond
    # precision makes `updated` a reliable per-event version stamp for the ack
    # store: two writes within the same wall-clock second get distinct stamps, so
    # acking one never suppresses the other.
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def ensure_home():
    os.makedirs(crew_dir(), exist_ok=True)
    os.makedirs(ask_dir(), exist_ok=True)
    if not os.path.exists(crew_json_path()):
        write_json(crew_json_path(), [])
    if not os.path.exists(projects_path()):
        write_json(projects_path(), {})


def read_json(path, default):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (FileNotFoundError, ValueError):
        return default


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(obj, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)


def load_roster():
    data = read_json(crew_json_path(), [])
    return data if isinstance(data, list) else []


def merged(record):
    """Overlay the live crew/<id>.json status file onto a roster record."""
    out = dict(record)
    live = read_json(status_path(record["id"]), None)
    if isinstance(live, dict):
        for field in STATUS_FIELDS:
            if field in live and live[field] is not None:
                out[field] = live[field]
    return out


def parent_of(record):
    """The owner id of a record ("" for a top-level, wingman-spawned member).
    Tolerates records written before `parent` existed (treated as top level)."""
    return record.get("parent") or ""


def descendants_inclusive(roster, root_id):
    """The set of ids for `root_id` and every member transitively owned by it.
    Following the `parent` chain, so standing down a lead reaps its whole
    sub-crew. `root_id` is always included even if it has no children.

    A member is also treated as a descendant of X if its `orphaned_from` names X:
    when a dead owner's workers are re-adopted (reconcile moves their live `parent`
    to the grandparent so they stay watched), `orphaned_from` preserves the original
    ownership, so `crew-standdown <dead-owner>` still cascades to them instead of
    leaving them - and their worktrees - behind."""
    result = set([root_id])
    changed = True
    while changed:
        changed = False
        for r in roster:
            rid = r.get("id")
            if rid is None or rid in result:
                continue
            orphaned_from = r.get("orphaned_from") or ""
            if parent_of(r) in result or (orphaned_from and orphaned_from in result):
                result.add(rid)
                changed = True
    return result


def order_tree(rows):
    """Return (record, depth) pairs in depth-first order - each parent
    immediately before its children - so a flat render still reads as the org.
    Records whose parent is absent from `rows` are treated as roots, so an
    owner-filtered slice still renders."""
    by_id = dict((r.get("id"), r) for r in rows)
    children = {}
    roots = []
    for r in rows:
        p = parent_of(r)
        if p and p in by_id:
            children.setdefault(p, []).append(r)
        else:
            roots.append(r)
    ordered = []

    def visit(rec, depth):
        ordered.append((rec, depth))
        for child in sorted(children.get(rec.get("id"), []), key=lambda x: x.get("id") or ""):
            visit(child, depth + 1)

    for root in sorted(roots, key=lambda x: x.get("id") or ""):
        visit(root, 0)
    return ordered


# ---------------------------------------------------------------- commands


def cmd_init(_args):
    ensure_home()
    print(home())


def cmd_crew_add(args):
    ensure_home()
    roster = load_roster()
    roster = [r for r in roster if r.get("id") != args.id]
    # One stamp for the spawn: the roster `updated`, the immutable `spawned_at`, and
    # the seeded status file's `updated` all take this identical value, so at spawn
    # time status.updated == spawned_at exactly. The prompt-freeze liveness veto
    # (bin/watch-fleet) relies on that equality to tell a member still frozen on the
    # one-time startup gate (never ran crew-set, so status.updated is still the spawn
    # stamp) from one that has genuinely self-reported (status.updated advanced past
    # spawned_at).
    stamp = now()
    record = {
        "id": args.id,
        "type": args.type,
        "objective": args.objective,
        "repo": args.repo,
        "scope": getattr(args, "scope", "repo") or "repo",
        # Owner: the crew id that spawned this member ("" = top level, spawned by
        # wingman itself). spawn-crew stamps it from $WINGMAN_CREW_ID, so ownership
        # falls out of who is spawning - a lead's spawns carry the lead's id.
        "parent": getattr(args, "parent", "") or "",
        "window": args.window,
        "session_id": args.session_id,
        "status": "working",
        "summary": "",
        "blocker": None,
        "artifact": None,
        "delivery": None,
        # The git worktree this member works in, recorded at spawn (repo scope) so a
        # non-graceful exit (dead/orphaned member) can still be torn down by
        # crew-standdown. Empty when unknown at spawn (global scope self-registers it
        # later via crew-set --worktree).
        "worktree": getattr(args, "worktree", "") or "",
        # The prior parent of a re-adopted orphan (set by reconcile's dead-owner
        # pass): standing down the dead owner still reaps a member whose
        # orphaned_from names it, even though its live parent was moved to the
        # grandparent. None until the member is orphaned.
        "orphaned_from": None,
        # Immutable spawn stamp; never rewritten by crew-set (see the stamp comment
        # above). Consumed by the prompt-freeze liveness veto.
        "spawned_at": stamp,
        "updated": stamp,
    }
    roster.append(record)
    write_json(crew_json_path(), roster)
    # Seed the crew member's own status file so the watcher has something to read.
    if not os.path.exists(status_path(args.id)):
        write_json(status_path(args.id), {
            "id": args.id,
            "status": "working",
            "summary": "",
            "blocker": None,
            "artifact": None,
            "delivery": None,
            "updated": stamp,
        })
    render_board()
    print(args.id)


def cmd_crew_set(args):
    """Update a crew member's live status file (crew/<id>.json).

    This is what a crew member itself calls to report distilled status. Only
    provided fields change; the roster record is mirrored for the terminal fields.
    """
    ensure_home()
    live = read_json(status_path(args.id), {"id": args.id})
    live["id"] = args.id
    for field in STATUS_FIELDS[:-1]:  # everything but 'updated'
        val = getattr(args, field, None)
        if val is not None:
            live[field] = None if val == "" and field in ("blocker", "artifact", "delivery") else val
    live["updated"] = now()
    write_json(status_path(args.id), live)

    # Mirror the durable fields back into the roster so a stale crew.json alone
    # still tells the truth if the status file is later removed.
    roster = load_roster()
    for r in roster:
        if r.get("id") == args.id:
            for field in ("status", "artifact", "delivery"):
                if getattr(args, field, None) is not None:
                    r[field] = live.get(field)
            # worktree is a roster-only field (not a live-status field): a member
            # that creates its worktree after spawn (global scope) self-registers
            # the path here so a later teardown can find it.
            if getattr(args, "worktree", None) is not None:
                r["worktree"] = args.worktree
            r["updated"] = live["updated"]
    write_json(crew_json_path(), roster)
    render_board()
    print(args.id)


def cmd_crew_get(args):
    roster = load_roster()
    for r in roster:
        if r.get("id") == args.id:
            print(json.dumps(merged(r), indent=2, sort_keys=True))
            return
    sys.exit("wm-state: no crew member '%s'" % args.id)


def cmd_crew_list(args):
    rows = [merged(r) for r in load_roster()]
    # Owner scope: with --owner, show only that manager's direct reports ("" = top
    # level). --tree ignores it and renders the whole hierarchy. Without --owner,
    # no owner filter (a flat view of every layer).
    owner = getattr(args, "owner", None)
    if owner is not None and not args.tree:
        rows = [r for r in rows if parent_of(r) == owner]
    if args.status:
        # An explicit status filter is honored verbatim, so `--status stood-down`
        # is the deliberate way to inspect closed history.
        rows = [r for r in rows if r.get("status") == args.status]
    elif args.active:
        rows = [r for r in rows if r.get("status") in LIVE_STATES]
    elif not args.all:
        # Default view: current crew only. `stood-down` is fully-closed history and
        # is noise on the live roster; pass --all (or --status stood-down) for it.
        rows = [r for r in rows if r.get("status") != "stood-down"]
    if args.tree:
        print(render_tree_text(rows))
    elif args.json:
        print(json.dumps(rows, indent=2, sort_keys=True))
    else:
        print(render_roster_text(rows))


def cmd_render_board(_args):
    print(render_board())


def cmd_reconcile(args):
    """Mark live-but-windowless crew as 'died'. Given the current tmux windows,
    any crew member still in a live state whose window is gone is flagged.

    Dead-owner re-adopt (Fix B / #11), run ONLY under wingman's watcher
    (--owner ""): after the death flip, any still-live worker whose window is alive
    but whose owner is now terminal (died/stood-down) is re-parented to the dead
    owner's own parent (the grandparent, always "" = wingman under the depth-2 cap),
    with the prior parent recorded in `orphaned_from`. Re-parenting immediately
    restores a live watcher (wingman now sees the worker as a direct report), and
    the dead owner's `died` event is enriched to enumerate the re-adopted workers and
    the dispositions. The orphan mutation is scoped to owner "" so the enlarged
    read-modify-write of crew.json stays single-writer (N4)."""
    ensure_home()
    owner = getattr(args, "owner", None)
    live_windows = set(w for w in (args.windows or "").split(",") if w)
    roster = load_roster()
    changed = []
    for r in roster:
        m = merged(r)
        if m.get("status") in LIVE_STATES and r.get("window") not in live_windows:
            r["status"] = "died"
            r["updated"] = now()
            # reflect into the status file too
            live = read_json(status_path(r["id"]), {"id": r["id"]})
            live["status"] = "died"
            live["updated"] = r["updated"]
            write_json(status_path(r["id"]), live)
            changed.append(r["id"])

    # Dead-owner re-adopt, wingman's watcher only (owner == "").
    if owner == "":
        by_id = dict((r.get("id"), r) for r in roster)
        orphans_by_owner = {}
        for r in roster:
            if merged(r).get("status") not in LIVE_STATES:
                continue
            if r.get("window") not in live_windows:
                continue  # its own window is gone; the death flip already handled it
            p = parent_of(r)
            if not p:
                continue  # top-level: owned by wingman, which never dies
            owner_rec = by_id.get(p)
            if owner_rec is None:
                continue
            if merged(owner_rec).get("status") in ("died", "stood-down"):
                r["orphaned_from"] = p
                r["parent"] = parent_of(owner_rec)  # grandparent ("" = wingman)
                orphans_by_owner.setdefault(p, []).append(r.get("id"))
        # Enrich each dead owner's `died` event to carry the orphan surface. Bump its
        # `updated` so the event re-fires (unacked) even if the death itself was
        # already surfaced on an earlier cycle; it fires once, because after
        # re-parenting the workers are no longer detected as this owner's orphans.
        for dead_id, workers in orphans_by_owner.items():
            owner_rec = by_id.get(dead_id)
            if owner_rec is None:
                continue
            names = ", ".join("`%s`" % w for w in workers)
            msg = ("lead `%s` died; its %d live worker(s) (%s) were re-adopted to you "
                   "and are now visible. Choose: keep supervising them; "
                   "`bin/crew-standdown %s` to cascade-stand-down the whole sub-crew; "
                   "or `bin/crew-takeover <worker>` to hand one off."
                   % (dead_id, len(workers), names, dead_id))
            stamp = now()
            owner_rec["summary"] = msg
            owner_rec["updated"] = stamp
            live = read_json(status_path(dead_id), {"id": dead_id})
            live["summary"] = msg
            live["updated"] = stamp
            write_json(status_path(dead_id), live)

    write_json(crew_json_path(), roster)
    render_board()
    print(" ".join(changed))


def cmd_standdown(args):
    """Mark a member stood-down, cascading to every member it owns so a lead's
    whole sub-crew is reaped with it (never orphaned). Prints each affected id
    (one per line) so the caller can close the corresponding tmux windows."""
    ensure_home()
    roster = load_roster()
    targets = descendants_inclusive(roster, args.id)
    affected = []
    stamp = now()
    for r in roster:
        if r.get("id") in targets:
            r["status"] = "stood-down"
            r["updated"] = stamp
            affected.append(r["id"])
            live = read_json(status_path(r["id"]), {"id": r["id"]})
            live["status"] = "stood-down"
            live["updated"] = stamp
            write_json(status_path(r["id"]), live)
    write_json(crew_json_path(), roster)
    render_board()
    # Deterministic order (target first, then its reports) for a readable report.
    for cid in sorted(affected, key=lambda c: (c != args.id, c)):
        print(cid)


def _parse_updated(stamp):
    """Parse an `updated` timestamp (ISO-8601, trailing Z) into an aware datetime,
    or None if it is missing/unparseable. Tolerates stamps with or without
    fractional seconds."""
    if not stamp:
        return None
    s = stamp[:-1] + "+00:00" if stamp.endswith("Z") else stamp
    for fmt in ("%Y-%m-%dT%H:%M:%S.%f%z", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            return datetime.datetime.strptime(s, fmt)
        except ValueError:
            continue
    return None


def cmd_prune(args):
    """Remove terminal crew records from the roster, archiving them first.

    Default target is `stood-down` (fully-closed); `--all-terminal` also sweeps
    `died`. `--older-than-days N` restricts removal to records last updated more
    than N days ago. `--dry-run` reports what would go without touching anything.

    For each removed record: append the merged view to crew-archive.jsonl, delete
    its crew/<id>.json status file, and drop its acked.json and handled.json
    entries. `done` is never
    a prune target - wingman reaps it to `stood-down` the moment it appears, so a
    live `done` on the roster is a fresh event, not history."""
    ensure_home()
    targets = {"stood-down", "died"} if args.all_terminal else {"stood-down"}
    cutoff = None
    if args.older_than_days is not None:
        cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=args.older_than_days)

    owner = getattr(args, "owner", None)
    roster = load_roster()
    remove, keep = [], []
    for r in roster:
        m = merged(r)
        if owner is not None and parent_of(r) != owner:
            keep.append(r)  # outside the requested owner scope
            continue
        if m.get("status") not in targets:
            keep.append(r)
            continue
        if cutoff is not None:
            ts = _parse_updated(m.get("updated"))
            if ts is None or ts >= cutoff:
                keep.append(r)  # too recent (or undatable) to prune
                continue
        remove.append(m)

    if args.dry_run:
        if not remove:
            print("prune (dry-run): nothing to remove")
        else:
            print("prune (dry-run): would remove %d record(s):" % len(remove))
            for m in remove:
                print("  %s\t%s\t%s" % (m.get("id", "?"), m.get("status", "?"), m.get("updated", "")))
        return

    if not remove:
        print("0")
        return

    # Archive first, so a crash mid-prune never loses a record.
    with open(archive_path(), "a") as fh:
        for m in remove:
            fh.write(json.dumps(m, sort_keys=True) + "\n")

    removed_ids = set()
    for m in remove:
        cid = m.get("id")
        removed_ids.add(cid)
        try:
            os.remove(status_path(cid))
        except FileNotFoundError:
            pass

    write_json(crew_json_path(), keep)

    for store_path in (acked_path(), handled_path()):
        with with_locked(store_path):
            store = read_json(store_path, {})
            if isinstance(store, dict):
                for cid in removed_ids:
                    store.pop(cid, None)
                write_json(store_path, store)

    render_board()
    print(len(remove))


def _parse_ps_seconds(field):
    """Seconds from a ps TIME/ETIME field. Handles both formats a single
    `ps -o time=,etime=` can emit: BSD/macOS 'MM:SS.cc' and procps/Linux
    '[[DD-]HH:]MM:SS'. Raises ValueError on anything else."""
    days = 0
    if "-" in field:
        d, field = field.split("-", 1)
        days = int(d)
    secs = 0.0
    for part in field.split(":"):
        secs = secs * 60 + float(part)
    return days * 86400 + secs


def _ps_tree(root_pid):
    """{pid: (cputime_secs, elapsed_secs)} for root_pid and its descendants, from
    one `ps -ax -o pid=,ppid=,time=,etime=` pass. Empty dict if the root is gone
    or ps cannot be read."""
    try:
        out = subprocess.check_output(
            ["ps", "-ax", "-o", "pid=,ppid=,time=,etime="],
            stderr=subprocess.DEVNULL, universal_newlines=True)
    except Exception:
        return {}
    rows = {}
    children = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) != 4:
            continue
        try:
            pid, ppid = int(parts[0]), int(parts[1])
            cpu = _parse_ps_seconds(parts[2])
            elapsed = _parse_ps_seconds(parts[3])
        except ValueError:
            continue
        rows[pid] = (cpu, elapsed)
        children.setdefault(ppid, []).append(pid)
    if root_pid not in rows:
        return {}
    tree = {}
    stack = [root_pid]
    while stack:
        pid = stack.pop()
        if pid in tree:
            continue
        tree[pid] = rows[pid]
        stack.extend(children.get(pid, []))
    return tree


def _probe_execution(root_pid, root_grace, gap, eps):
    """True if the pane's process tree shows positive evidence of execution or an
    armed wake source: (a) any descendant whose start lags the root's by more than
    root_grace seconds (an in-flight tool shell, or an armed background watcher
    that will exit and wake the session; launch-time children like MCP servers
    start with the root and do not count), else (b) summed cputime delta over pids
    present in two samples `gap` seconds apart >= eps. If the tree cannot be read
    at all, returns False (fall back to the staleness verdict; window liveness is
    reconcile's job)."""
    first = _ps_tree(root_pid)
    if not first:
        return False
    root_elapsed = first[root_pid][1]
    for pid, (_cpu, elapsed) in first.items():
        # etime arithmetic (root_elapsed - descendant_elapsed), never wall-clock
        # start-time parsing, so the comparison is locale-safe.
        if pid != root_pid and (root_elapsed - elapsed) > root_grace:
            return True
    time.sleep(gap)
    second = _ps_tree(root_pid)
    if not second:
        return False
    delta = 0.0
    for pid in set(first) & set(second):
        delta += max(0.0, second[pid][0] - first[pid][0])
    return delta >= eps


def cmd_stall_check(args):
    """Flag a WORKING crew member as 'stalled' iff it shows no external sign of life:
    BOTH staleness gates (pane_idle from the watcher, status_idle computed here) at
    or past --threshold, AND the execution probe over --pane-pid finds no evidence.

    Prints 'stalled' if it flipped the member, nothing otherwise. Idempotent and safe
    to call every poll: gates fail fast, the probe runs only for nominated candidates,
    and once flipped, status != 'working' so subsequent calls skip.

    --api-error only changes which reason template a genuine stall is written with
    (an 'api-error:' prefix instead of the default) - it never changes the gates or
    the probe above, and does not by itself cause a flip."""
    ensure_home()
    live = read_json(status_path(args.id), None)
    if not isinstance(live, dict) or live.get("status") != "working":
        return
    updated = _parse_updated(live.get("updated"))
    if updated is None:
        return
    status_idle = (datetime.datetime.now(datetime.timezone.utc) - updated).total_seconds()
    if args.pane_idle < args.threshold or status_idle < args.threshold:
        return
    if _probe_execution(args.pane_pid, args.root_grace, args.probe_gap, args.cpu_eps):
        return
    # The probe slept for the sampling gap; a member that self-reported during it
    # (a flip to review with an artifact, a real blocker) must win over the
    # pre-gap snapshot. Re-read and bail unless nothing changed.
    current = read_json(status_path(args.id), None)
    if (not isinstance(current, dict) or current.get("status") != "working"
            or current.get("updated") != live.get("updated")):
        return
    live = current

    prior = (live.get("summary") or "").split("\n")[0][:80]
    if getattr(args, "api_error", 0):
        reason = ("api-error: the pane shows an API/connectivity-error signature (rate "
                  "limit, connection error, 5xx, overloaded_error, or similar) and then "
                  "went quiet for >%ds while status was 'working' - the CLI's own retry/"
                  "backoff appears exhausted. Likely a local network blip or an Anthropic-"
                  "side outage, not a broken agent. Already nudged once; if it does not "
                  "recover, resume it with `bin/crew-resume %s`."
                  % (int(args.threshold), args.id))
    else:
        reason = ("no pane output, status update, running child process, or CPU activity "
                  "for >%ds while status was 'working'; the agent likely errored or went "
                  "idle. Inspect with `bin/crew-takeover %s` or stand down with "
                  "`bin/crew-standdown %s`." % (int(args.threshold), args.id, args.id))
    if prior:
        reason += " (last summary: %s)" % prior

    live["status"] = "stalled"
    live["summary"] = reason
    live["updated"] = now()
    write_json(status_path(args.id), live)

    # Mirror into the roster, as crew-set does, so a later loss of the status
    # file still tells the truth.
    roster = load_roster()
    for r in roster:
        if r.get("id") == args.id:
            r["status"] = "stalled"
            r["updated"] = live["updated"]
    write_json(crew_json_path(), roster)
    render_board()
    print("stalled")


def cmd_needs_attention(args):
    """Print crew that need their owner: blocked, review, done, died, or stalled, excluding
    any whose current (id, updated) event has already been acked. Used by the watcher
    and the Stop hook to decide whether to wake the owner; each deliverer acks what it
    surfaces (via `ack`), so an event fires once instead of on every poll.

    With --owner, emit only that owner's direct reports ("" = top level, the members
    wingman spawned). This is what scopes each layer to its own crew: wingman's
    watcher runs --owner "" and never sees a lead's workers, while a lead's watcher
    runs --owner <lead-id> and sees only its own. Without --owner, every layer.

    `review` (a deliverable ready for the pilot) surfaces the same way: a member
    enters it once at delivery, so the pilot is pinged once; the member then does
    its steady watch/revision work under `working` (not surfaced), so refreshes
    never re-announce. A genuine new event (a later `blocked`, or terminal `done`)
    carries a new `updated` and surfaces again.

    Output is tab-separated: id, status, updated, note. The `updated` column lets a
    deliverer ack the exact tuple it surfaced. Stays a pure read (no side effects).

    The suppression selector distinguishes the two deliverers (Fix A / #8):
      --suppress-on ack (default): the watcher / fire() gate. Suppress an event that
        is either already acked (surfaced and being handled) OR already handled, so
        a freshly-armed cycle does not re-fire an event currently in flight.
      --suppress-on handled: the Stop-hook gate. Suppress only a fully-handled
        event, so an acked-but-unhandled one is still visible and still blocks once
        (guaranteeing the roster report) before the owner may stop.
      --only-acked: additionally restrict to events currently in acked.json;
        `--suppress-on handled --only-acked` therefore enumerates exactly the set
        acked-minus-handled."""
    owner = getattr(args, "owner", None)
    suppress_on = getattr(args, "suppress_on", None) or "ack"
    only_acked = getattr(args, "only_acked", False)
    acked = read_json(acked_path(), {})
    if not isinstance(acked, dict):
        acked = {}
    handled = read_json(handled_path(), {})
    if not isinstance(handled, dict):
        handled = {}
    for r in (merged(x) for x in load_roster()):
        if owner is not None and parent_of(r) != owner:
            continue
        if r.get("status") in ATTENTION_STATES:
            rid = r["id"]
            upd = r.get("updated")
            if suppress_on == "handled":
                if handled.get(rid) == upd:
                    continue  # already fully handled
            else:  # "ack": suppress an event acked OR handled (watcher/fire gate)
                if acked.get(rid) == upd or handled.get(rid) == upd:
                    continue
            if only_acked and acked.get(rid) != upd:
                continue  # restrict to currently-acked events
            # The note is a short hint for wingman to relay; prefer the pointer the
            # pilot needs (the blocker to answer, the PR/branch delivered, or the
            # artifact produced) over the free-text summary.
            note = (r.get("blocker") or r.get("delivery")
                    or r.get("artifact") or r.get("summary") or "")
            print("%s\t%s\t%s\t%s" % (
                rid, r["status"], upd or "", note))


def cmd_group_attention(args):
    """Read needs-attention's TSV from stdin (id, status, updated, note) and
    collapse fleet-wide correlated batches into one synthetic row each, passing
    every other row through unchanged. Two recognized patterns, both meaning
    "many crew show the same abnormal signal in one pass":
      - status == "died"                                     -> key "mass-death"
      - status == "stalled" and note startswith "api-error:"  -> key "api-outage"
    A group collapses only at or above --mass-min-count AND --mass-min-ratio (of
    the relevant live population - see below); below threshold its rows pass
    through individually, so one routine died/stalled member is untouched.

    Pure filter: recomputes the roster snapshot fresh on every call and writes
    nothing. The synthetic row's id ("correlated:mass-death"/"correlated:api-
    outage") is not a real crew id - callers must ack/mark-handled from the
    ORIGINAL ungrouped needs-attention output, never from this filtered one.
    --owner scopes the ratio's denominator to the same cohort needs-attention
    was called with ("" = top level, matching a lead's own scope), so a lead's
    cycle judges "N of M" against its own team, not the whole fleet.

    Ratio denominators: a `died` member has just left LIVE_STATES, so
    mass-death's denominator is (current live count for this owner) + (number
    of died rows in this batch) - "how many were live a moment before this
    pass," not the post-death count, which would undercount and inflate the
    ratio. `stalled` is still a LIVE_STATES member, so api-outage's denominator
    is simply the current live count - no adjustment needed."""
    owner = getattr(args, "owner", None)
    min_count = args.mass_min_count
    min_ratio = args.mass_min_ratio

    rows = []
    for line in sys.stdin:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t", 3)
        while len(parts) < 4:
            parts.append("")
        rows.append(tuple(parts))  # (id, status, updated, note)

    died_rows = [r for r in rows if r[1] == "died"]
    outage_rows = [r for r in rows if r[1] == "stalled" and r[3].startswith("api-error:")]

    current_live = 0
    for r in load_roster():
        m = merged(r)
        if m.get("status") not in LIVE_STATES:
            continue
        if owner is not None and parent_of(r) != owner:
            continue
        current_live += 1
    mass_denominator = current_live + len(died_rows)
    outage_denominator = current_live

    def collapses(n, denom):
        return n >= min_count and denom > 0 and (n / float(denom)) >= min_ratio

    mass_collapse = bool(died_rows) and collapses(len(died_rows), mass_denominator)
    outage_collapse = bool(outage_rows) and collapses(len(outage_rows), outage_denominator)
    died_ids = set(r[0] for r in died_rows)
    outage_ids = set(r[0] for r in outage_rows)

    resume_cmd = "bin/crew-resume --all-died"
    if owner:
        resume_cmd += " --owner %s" % owner

    emitted_mass = False
    emitted_outage = False
    for rid, status, upd, note in rows:
        if mass_collapse and rid in died_ids:
            if emitted_mass:
                continue
            emitted_mass = True
            names = ", ".join("`%s`" % i for i in (r[0] for r in died_rows))
            synth_note = ("%d crew members died together (likely a tmux/host crash): %s. "
                          "Default remedy: `%s`." % (len(died_rows), names, resume_cmd))
            print("%s\t%s\t%s\t%s" % ("correlated:mass-death", "died", now(), synth_note))
            continue
        if outage_collapse and rid in outage_ids:
            if emitted_outage:
                continue
            emitted_outage = True
            names = ", ".join("`%s`" % i for i in (r[0] for r in outage_rows))
            synth_note = ("%d crew members hit an API/connectivity error together (likely an "
                          "outage): %s. Already nudged once each; escalate with "
                          "`bin/crew-resume <id>` if one does not recover."
                          % (len(outage_rows), names))
            print("%s\t%s\t%s\t%s" % ("correlated:api-outage", "stalled", now(), synth_note))
            continue
        print("%s\t%s\t%s\t%s" % (rid, status, upd, note))


def cmd_ack(args):
    """Record that the (id, updated) event has been surfaced to wingman, so
    needs-attention suppresses it until the crew's status changes (a new updated).

    Explicit and idempotent: the deliverer passes the exact tuple it surfaced, so
    the ack never races a state change between the read and the ack - a transition
    in that window produces a new `updated` that this ack does not cover, and it
    correctly re-surfaces. The read-modify-write is serialized (with_locked) so a
    concurrent watcher-fire ack and Stop-hook ack cannot lose each other's key."""
    ensure_home()
    with with_locked(acked_path()):
        acked = read_json(acked_path(), {})
        if not isinstance(acked, dict):
            acked = {}
        acked[args.id] = args.updated
        write_json(acked_path(), acked)
    print(args.id)


def cmd_mark_handled(args):
    """Record that the (id, updated) event has been fully HANDLED by the owner -
    surfaced AND the roster reported - distinct from `ack` (merely surfaced).

    Only the Stop hook sets this, and only for the exact set of events its block
    enumerated this turn (its per-turn scratch set), when it lets a stop proceed.
    Marking handled only that captured set - never a set re-derived from the stores
    at allow-time - is what prevents a mid-turn new transition (or a mid-turn
    watcher ack) from being marked handled and silently dropped (#8). The
    read-modify-write is serialized (with_locked) like `ack`."""
    ensure_home()
    with with_locked(handled_path()):
        handled = read_json(handled_path(), {})
        if not isinstance(handled, dict):
            handled = {}
        handled[args.id] = args.updated
        write_json(handled_path(), handled)
    print(args.id)


def cmd_projects_set(args):
    ensure_home()
    obj = json.loads(sys.stdin.read()) if args.stdin else json.loads(args.data)
    write_json(projects_path(), obj)
    print(len(obj))


def cmd_projects_get(_args):
    print(json.dumps(read_json(projects_path(), {}), indent=2, sort_keys=True))


def cmd_projects_lookup(args):
    projects = read_json(projects_path(), {})
    if args.name in projects:
        print(projects[args.name])
    else:
        sys.exit(1)


# ---------------------------------------------------------------- ask channel
# A dedicated request/response channel, parallel to (not overloading) the status
# channel: a caller poses a direct question to one of its delegates and captures
# a bounded, distilled answer back into its own context, without scraping panes.
# Each ask is one file under ~/.wingman/ask/<req>.json. It never touches a
# delegate's crew/<id>.json status, needs-attention, acked.json, or board.md - an
# answer to a side question is orthogonal to the delegate's own lifecycle (it stays
# `working`; it merely replies on the side). See bin/crew-ask for the send/reply/
# await flow and the ask docs/plan for the rationale.

ASK_STATES = ("pending", "answered", "timeout", "undeliverable")


def cmd_ask_new(args):
    """Mint a pending ask record. Refuses to overwrite an existing one, so a
    double-send (or a restarted sender) never clobbers an in-flight request."""
    ensure_home()
    path = ask_path(args.id)
    if os.path.exists(path):
        sys.exit("wm-state: ask '%s' already exists" % args.id)
    record = {
        "id": args.id,
        "from": args.sender or "",
        "to": args.to,
        "question": args.question,
        "status": "pending",
        "answer": None,
        "answer_file": None,
        "responder": None,
        "created": now(),
        "answered": None,
    }
    write_json(path, record)
    print(args.id)


def cmd_ask_reply(args):
    """Record a delegate's bounded answer. Refuses a missing/closed request, a
    responder that is not the addressed delegate (anti-spoof), and an answer over
    the cap (reject, never silently truncate - forces a real distillation). An
    --answer-file is stored as an absolute-path pointer; its bytes never enter
    state."""
    ensure_home()
    record = read_json(ask_path(args.id), None)
    if not isinstance(record, dict):
        sys.exit("wm-state: no ask '%s'" % args.id)
    if record.get("status") != "pending":
        sys.exit("wm-state: ask '%s' is already %s, not open for a reply"
                 % (args.id, record.get("status")))
    if args.responder != record.get("to"):
        sys.exit("wm-state: responder '%s' is not the addressed delegate '%s' "
                 "for ask '%s' (a reply must come from the delegate that was asked)"
                 % (args.responder, record.get("to"), args.id))
    max_chars = args.max_chars
    if max_chars is None:
        try:
            max_chars = int(os.environ.get("WM_ASK_MAX_CHARS", "4000"))
        except ValueError:
            max_chars = 4000
    if len(args.answer) > max_chars:
        sys.exit("wm-state: answer is %d chars, over the %d-char cap. Summarize it, "
                 "or move the detail into a file and pass --answer-file <path> while "
                 "keeping --answer short." % (len(args.answer), max_chars))
    answer_file = None
    if args.answer_file:
        if not os.path.exists(args.answer_file):
            sys.exit("wm-state: --answer-file '%s' does not exist" % args.answer_file)
        answer_file = os.path.abspath(args.answer_file)
    record["status"] = "answered"
    record["answer"] = args.answer
    record["answer_file"] = answer_file
    record["responder"] = args.responder
    record["answered"] = now()
    write_json(ask_path(args.id), record)
    print(args.id)


def cmd_ask_get(args):
    record = read_json(ask_path(args.id), None)
    if not isinstance(record, dict):
        sys.exit("wm-state: no ask '%s'" % args.id)
    print(json.dumps(record, indent=2, sort_keys=True))


def cmd_ask_resolve(args):
    """Terminal non-answer transition set by the await watcher (timeout or
    undeliverable). Compare-and-set on `pending`: an answer that landed in the
    same tick wins, so a resolve never clobbers a real reply. Prints the resulting
    status (the request's current status if it was already closed)."""
    ensure_home()
    record = read_json(ask_path(args.id), None)
    if not isinstance(record, dict):
        sys.exit("wm-state: no ask '%s'" % args.id)
    if record.get("status") == "pending":
        record["status"] = args.status
        record["answered"] = now()
        if args.note:
            record["note"] = args.note
        write_json(ask_path(args.id), record)
    print(record.get("status"))


def cmd_ask_list(args):
    """Print matching ask records, tab-separated `id status from to created`. Used
    by the Stop-hook guard (pending asks needing a live waiter) and by cleanup."""
    ensure_home()
    rows = []
    for name in sorted(os.listdir(ask_dir())):
        if not name.endswith(".json"):
            continue
        record = read_json(os.path.join(ask_dir(), name), None)
        if not isinstance(record, dict):
            continue
        if args.sender is not None and (record.get("from") or "") != args.sender:
            continue
        if args.status is not None and record.get("status") != args.status:
            continue
        rows.append(record)
    rows.sort(key=lambda r: r.get("created") or "")
    for r in rows:
        print("%s\t%s\t%s\t%s\t%s" % (
            r.get("id", ""), r.get("status", ""), r.get("from") or "",
            r.get("to") or "", r.get("created") or ""))


def cmd_ask_prune(args):
    """Best-effort, time-based cleanup of closed ask records (answered/timeout/
    undeliverable) older than --older-than-hours. Deletion is time-based, never
    event-based, so it can never race a caller reading a just-landed answer.
    Pending asks are always kept. Prints the number removed."""
    ensure_home()
    cutoff = None
    if args.older_than_hours is not None:
        cutoff = (datetime.datetime.now(datetime.timezone.utc)
                  - datetime.timedelta(hours=args.older_than_hours))
    removed = 0
    for name in os.listdir(ask_dir()):
        if not name.endswith(".json"):
            continue
        path = os.path.join(ask_dir(), name)
        record = read_json(path, None)
        if not isinstance(record, dict):
            continue
        if record.get("status") == "pending":
            continue
        if cutoff is not None:
            ts = _parse_updated(record.get("answered") or record.get("created"))
            if ts is None or ts >= cutoff:
                continue
        try:
            os.remove(path)
            removed += 1
        except FileNotFoundError:
            pass
    print(removed)


# ---------------------------------------------------------------- rendering


def render_roster_text(rows):
    if not rows:
        return "(no crew)"
    lines = []
    for r in rows:
        line = "  [%-10s] %-22s %-9s %s" % (
            r.get("type", "?"), r.get("id", "?"), r.get("status", "?"),
            (r.get("summary") or "").split("\n")[0][:60],
        )
        lines.append(line)
        if r.get("status") == "blocked" and r.get("blocker"):
            lines.append("      blocker: %s" % r["blocker"])
        if r.get("delivery"):
            lines.append("      delivery: %s" % r["delivery"])
    return "\n".join(lines)


def render_tree_text(rows):
    """Indented depth-first render of the org, each report nested under its owner."""
    ordered = order_tree(rows)
    if not ordered:
        return "(no crew)"
    lines = []
    for r, depth in ordered:
        indent = "  " * depth
        line = "%s[%s] %s %s %s" % (
            indent, r.get("type", "?"), r.get("id", "?"), r.get("status", "?"),
            (r.get("summary") or "").split("\n")[0][:50],
        )
        lines.append(line.rstrip())
        if r.get("status") == "blocked" and r.get("blocker"):
            lines.append("%s    blocker: %s" % (indent, r["blocker"]))
        if r.get("delivery"):
            lines.append("%s    delivery: %s" % (indent, r["delivery"]))
    return "\n".join(lines)


def render_board():
    rows = [merged(r) for r in load_roster()]
    active = [r for r in rows if r.get("status") in LIVE_STATES]
    done = [r for r in rows if r.get("status") not in LIVE_STATES]
    out = ["# Wingman crew board", "", "_Updated %s_" % now(), ""]
    out.append("## Active (%d)" % len(active))
    out.append("")
    if active:
        out.append("| type | id | status | window | repo | summary | blocker | delivery |")
        out.append("|---|---|---|---|---|---|---|---|")
        # Depth-first so each report sits under its owner, its id indented by depth,
        # letting a human read the org rather than a flat list.
        for r, depth in order_tree(active):
            marker = ("&nbsp;&nbsp;" * depth) + ("↳ " if depth else "")
            out.append("| %s | %s%s | %s | %s | %s | %s | %s | %s |" % (
                r.get("type", ""), marker, r.get("id", ""), r.get("status", ""),
                r.get("window", ""),
                os.path.basename(r.get("repo", "") or "") + (" (global)" if r.get("scope") == "global" else ""),
                _cell(r.get("summary")), _cell(r.get("blocker")), _cell(r.get("delivery")),
            ))
    else:
        out.append("_(none)_")
    out.append("")
    out.append("## Closed (%d)" % len(done))
    out.append("")
    if done:
        out.append("| type | id | status | delivery |")
        out.append("|---|---|---|---|")
        for r in done:
            out.append("| %s | %s | %s | %s |" % (
                r.get("type", ""), r.get("id", ""), r.get("status", ""), _cell(r.get("delivery")),
            ))
    else:
        out.append("_(none)_")
    text = "\n".join(out) + "\n"
    with open(board_path(), "w") as fh:
        fh.write(text)
    return text


def _cell(val):
    if not val:
        return ""
    return str(val).replace("\n", " ").replace("|", "\\|")[:80]


# ---------------------------------------------------------------- cli


def build_parser():
    p = argparse.ArgumentParser(prog="wm-state")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("init").set_defaults(fn=cmd_init)

    a = sub.add_parser("crew-add")
    a.add_argument("--id", required=True)
    a.add_argument("--type", required=True)
    a.add_argument("--objective", default="")
    a.add_argument("--repo", required=True)
    a.add_argument("--window", required=True)
    a.add_argument("--session-id", required=True, dest="session_id")
    # "repo" (default): grounded in one git checkout. "global": grounded at the
    # workspace root with every discovered repo added, so the member works across
    # repos and picks its target(s) itself.
    a.add_argument("--scope", default="repo")
    # The spawning crew's id ("" = wingman, the top orchestrator). Stamps ownership.
    a.add_argument("--parent", default="")
    # The git worktree the member works in, recorded at spawn (repo scope) for
    # teardown; empty when unknown at spawn (global scope self-registers via crew-set).
    a.add_argument("--worktree", default="")
    a.set_defaults(fn=cmd_crew_add)

    a = sub.add_parser("crew-set")
    a.add_argument("--id", required=True)
    a.add_argument("--status")
    a.add_argument("--summary")
    a.add_argument("--blocker")
    a.add_argument("--artifact")
    a.add_argument("--delivery")
    # Self-register the worktree path after spawn (global scope, whose repo/path is
    # not knowable at spawn time). Roster-only field, not a live-status field.
    a.add_argument("--worktree", default=None)
    a.set_defaults(fn=cmd_crew_set)

    a = sub.add_parser("crew-get")
    a.add_argument("--id", required=True)
    a.set_defaults(fn=cmd_crew_get)

    a = sub.add_parser("crew-list")
    a.add_argument("--json", action="store_true")
    a.add_argument("--status")
    a.add_argument("--active", action="store_true")
    # Include fully-closed `stood-down` records (hidden by default).
    a.add_argument("--all", action="store_true")
    # Owner scope: show only this manager's direct reports ("" = top level).
    a.add_argument("--owner", default=None)
    # Render the whole hierarchy as an indented tree (ignores --owner).
    a.add_argument("--tree", action="store_true")
    a.set_defaults(fn=cmd_crew_list)

    sub.add_parser("render-board").set_defaults(fn=cmd_render_board)

    a = sub.add_parser("reconcile")
    a.add_argument("--windows", default="")
    # The watcher's owner scope. The dead-owner re-adopt pass runs only for "" (N4);
    # omit or pass a lead id to keep reconcile to the global death-flip only.
    a.add_argument("--owner", default=None)
    a.set_defaults(fn=cmd_reconcile)

    a = sub.add_parser("standdown")
    a.add_argument("--id", required=True)
    a.set_defaults(fn=cmd_standdown)

    a = sub.add_parser("prune")
    a.add_argument("--all-terminal", action="store_true", dest="all_terminal")
    a.add_argument("--older-than-days", type=int, dest="older_than_days")
    a.add_argument("--dry-run", action="store_true", dest="dry_run")
    # Restrict pruning to a given owner's direct reports ("" = top level).
    a.add_argument("--owner", default=None)
    a.set_defaults(fn=cmd_prune)

    # The watcher's silent-stall backstop: supplies the two signals Python cannot
    # observe cheaply (the pane-idle age and the pane root pid); all policy,
    # timestamp math, and process-tree probing stay here.
    a = sub.add_parser("stall-check")
    a.add_argument("--id", required=True)
    a.add_argument("--pane-idle", type=int, required=True, dest="pane_idle")
    a.add_argument("--pane-pid", type=int, required=True, dest="pane_pid")
    a.add_argument("--threshold", type=int, default=180)
    a.add_argument("--root-grace", type=int, default=30, dest="root_grace")
    a.add_argument("--probe-gap", type=int, default=10, dest="probe_gap")
    a.add_argument("--cpu-eps", type=float, default=0.5, dest="cpu_eps")
    # Set by the watcher when the pane tail matches an API/connectivity-error
    # signature (#23); changes only which reason template a genuine stall gets,
    # never the gates or probe above.
    a.add_argument("--api-error", type=int, default=0, dest="api_error")
    a.set_defaults(fn=cmd_stall_check)

    a = sub.add_parser("needs-attention")
    # Emit only this owner's direct reports ("" = top level). Omit for every layer.
    a.add_argument("--owner", default=None)
    # Suppression selector (Fix A / #8): "ack" (default) is the watcher/fire gate
    # (suppress acked OR handled); "handled" is the Stop-hook gate (suppress only
    # handled). --only-acked restricts to currently-acked events.
    a.add_argument("--suppress-on", default="ack", choices=("ack", "handled"), dest="suppress_on")
    a.add_argument("--only-acked", action="store_true", dest="only_acked")
    a.set_defaults(fn=cmd_needs_attention)

    # Pure display filter over needs-attention's TSV: collapses a fleet-wide
    # correlated batch (mass death, correlated API outage) into one synthetic
    # row. Never call ack/mark-handled against its output - those must always
    # target the real ids from the original needs-attention call.
    a = sub.add_parser("group-attention")
    a.add_argument("--owner", default=None)
    a.add_argument("--mass-min-count", type=int, default=2, dest="mass_min_count")
    a.add_argument("--mass-min-ratio", type=float, default=0.5, dest="mass_min_ratio")
    a.set_defaults(fn=cmd_group_attention)

    a = sub.add_parser("ack")
    a.add_argument("--id", required=True)
    a.add_argument("--updated", required=True)
    a.set_defaults(fn=cmd_ack)

    a = sub.add_parser("mark-handled")
    a.add_argument("--id", required=True)
    a.add_argument("--updated", required=True)
    a.set_defaults(fn=cmd_mark_handled)

    a = sub.add_parser("projects-set")
    a.add_argument("--data")
    a.add_argument("--stdin", action="store_true")
    a.set_defaults(fn=cmd_projects_set)

    sub.add_parser("projects-get").set_defaults(fn=cmd_projects_get)

    a = sub.add_parser("projects-lookup")
    a.add_argument("--name", required=True)
    a.set_defaults(fn=cmd_projects_lookup)

    # --- ask channel: request/response between a caller and its delegate -------
    a = sub.add_parser("ask-new")
    a.add_argument("--id", required=True)
    # `--from` is a Python keyword, so it lands in args.sender.
    a.add_argument("--from", default="", dest="sender")
    a.add_argument("--to", required=True)
    a.add_argument("--question", required=True)
    a.set_defaults(fn=cmd_ask_new)

    a = sub.add_parser("ask-reply")
    a.add_argument("--id", required=True)
    a.add_argument("--responder", required=True)
    a.add_argument("--answer", required=True)
    a.add_argument("--answer-file", default=None, dest="answer_file")
    a.add_argument("--max-chars", type=int, default=None, dest="max_chars")
    a.set_defaults(fn=cmd_ask_reply)

    a = sub.add_parser("ask-get")
    a.add_argument("--id", required=True)
    a.set_defaults(fn=cmd_ask_get)

    a = sub.add_parser("ask-resolve")
    a.add_argument("--id", required=True)
    a.add_argument("--status", required=True, choices=("timeout", "undeliverable"))
    a.add_argument("--note", default=None)
    a.set_defaults(fn=cmd_ask_resolve)

    a = sub.add_parser("ask-list")
    a.add_argument("--from", default=None, dest="sender")
    a.add_argument("--status", default=None)
    a.set_defaults(fn=cmd_ask_list)

    a = sub.add_parser("ask-prune")
    a.add_argument("--older-than-hours", type=int, default=None, dest="older_than_hours")
    a.set_defaults(fn=cmd_ask_prune)

    return p


def main():
    args = build_parser().parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
