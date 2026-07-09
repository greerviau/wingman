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
  acked.json        the last (id -> updated) event surfaced to wingman, so a
                    terminal state does not re-surface on every needs-attention poll

The merged view of a crew member = its crew.json base record with the live
crew/<id>.json overlaid on top (status/summary/blocker/artifact/delivery/updated).
crew.json is the roster of record; crew/<id>.json is the live signal. Wingman
reads the merge; it never ingests panes or transcripts.

All JSON is handled here in Python so the shell scripts stay bash-3.2-safe and the
tool works whether or not jq is installed.
"""
import argparse
import datetime
import json
import os
import sys

STATUS_FIELDS = ("status", "summary", "blocker", "artifact", "delivery", "updated")
LIVE_STATES = ("working", "blocked")
TERMINAL_STATES = ("done", "died", "stood-down")


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


def now():
    # UTC, microsecond precision, ISO-8601 with a trailing Z. Microsecond
    # precision makes `updated` a reliable per-event version stamp for the ack
    # store: two writes within the same wall-clock second get distinct stamps, so
    # acking one never suppresses the other.
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def ensure_home():
    os.makedirs(crew_dir(), exist_ok=True)
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


# ---------------------------------------------------------------- commands


def cmd_init(_args):
    ensure_home()
    print(home())


def cmd_crew_add(args):
    ensure_home()
    roster = load_roster()
    roster = [r for r in roster if r.get("id") != args.id]
    record = {
        "id": args.id,
        "type": args.type,
        "objective": args.objective,
        "repo": args.repo,
        "scope": getattr(args, "scope", "repo") or "repo",
        "window": args.window,
        "session_id": args.session_id,
        "status": "working",
        "summary": "",
        "blocker": None,
        "artifact": None,
        "delivery": None,
        "updated": now(),
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
            "updated": now(),
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
    if args.status:
        rows = [r for r in rows if r.get("status") == args.status]
    if args.active:
        rows = [r for r in rows if r.get("status") in LIVE_STATES]
    if args.json:
        print(json.dumps(rows, indent=2, sort_keys=True))
    else:
        print(render_roster_text(rows))


def cmd_render_board(_args):
    print(render_board())


def cmd_reconcile(args):
    """Mark live-but-windowless crew as 'died'. Given the current tmux windows,
    any crew member still in a live state whose window is gone is flagged."""
    ensure_home()
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
    write_json(crew_json_path(), roster)
    render_board()
    print(" ".join(changed))


def cmd_standdown(args):
    ensure_home()
    roster = load_roster()
    for r in roster:
        if r.get("id") == args.id:
            r["status"] = "stood-down"
            r["updated"] = now()
    write_json(crew_json_path(), roster)
    live = read_json(status_path(args.id), {"id": args.id})
    live["status"] = "stood-down"
    live["updated"] = now()
    write_json(status_path(args.id), live)
    render_board()
    print(args.id)


def cmd_needs_attention(_args):
    """Print crew that need wingman: blocked, done, or died, excluding any whose
    current (id, updated) event has already been acked. Used by the watcher and the
    Stop hook to decide whether to wake wingman; each deliverer acks what it
    surfaces (via `ack`), so a terminal state fires once instead of on every poll.

    Output is tab-separated: id, status, updated, note. The `updated` column lets a
    deliverer ack the exact tuple it surfaced. Stays a pure read (no side effects)."""
    acked = read_json(acked_path(), {})
    if not isinstance(acked, dict):
        acked = {}
    for r in (merged(x) for x in load_roster()):
        if r.get("status") in ("blocked", "done", "died"):
            if acked.get(r["id"]) == r.get("updated"):
                continue  # already surfaced this exact event
            print("%s\t%s\t%s\t%s" % (
                r["id"], r["status"], r.get("updated") or "",
                r.get("blocker") or r.get("summary") or ""))


def cmd_ack(args):
    """Record that the (id, updated) event has been surfaced to wingman, so
    needs-attention suppresses it until the crew's status changes (a new updated).

    Explicit and idempotent: the deliverer passes the exact tuple it surfaced, so
    the ack never races a state change between the read and the ack - a transition
    in that window produces a new `updated` that this ack does not cover, and it
    correctly re-surfaces."""
    ensure_home()
    acked = read_json(acked_path(), {})
    if not isinstance(acked, dict):
        acked = {}
    acked[args.id] = args.updated
    write_json(acked_path(), acked)
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
        for r in active:
            out.append("| %s | %s | %s | %s | %s | %s | %s | %s |" % (
                r.get("type", ""), r.get("id", ""), r.get("status", ""),
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
    a.set_defaults(fn=cmd_crew_add)

    a = sub.add_parser("crew-set")
    a.add_argument("--id", required=True)
    a.add_argument("--status")
    a.add_argument("--summary")
    a.add_argument("--blocker")
    a.add_argument("--artifact")
    a.add_argument("--delivery")
    a.set_defaults(fn=cmd_crew_set)

    a = sub.add_parser("crew-get")
    a.add_argument("--id", required=True)
    a.set_defaults(fn=cmd_crew_get)

    a = sub.add_parser("crew-list")
    a.add_argument("--json", action="store_true")
    a.add_argument("--status")
    a.add_argument("--active", action="store_true")
    a.set_defaults(fn=cmd_crew_list)

    sub.add_parser("render-board").set_defaults(fn=cmd_render_board)

    a = sub.add_parser("reconcile")
    a.add_argument("--windows", default="")
    a.set_defaults(fn=cmd_reconcile)

    a = sub.add_parser("standdown")
    a.add_argument("--id", required=True)
    a.set_defaults(fn=cmd_standdown)

    sub.add_parser("needs-attention").set_defaults(fn=cmd_needs_attention)

    a = sub.add_parser("ack")
    a.add_argument("--id", required=True)
    a.add_argument("--updated", required=True)
    a.set_defaults(fn=cmd_ack)

    a = sub.add_parser("projects-set")
    a.add_argument("--data")
    a.add_argument("--stdin", action="store_true")
    a.set_defaults(fn=cmd_projects_set)

    sub.add_parser("projects-get").set_defaults(fn=cmd_projects_get)

    a = sub.add_parser("projects-lookup")
    a.add_argument("--name", required=True)
    a.set_defaults(fn=cmd_projects_lookup)

    return p


def main():
    args = build_parser().parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
