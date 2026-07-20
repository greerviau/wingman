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
  acked.json        the last (id -> announced) event SURFACED to wingman (by a
                    watcher fire or a Stop-hook block), so it does not re-fire on
                    every needs-attention poll while it is being handled
  handled.json      the last (id -> announced) event fully HANDLED (surfaced AND the
                    roster reported), set only by the Stop hook when it lets a stop
                    proceed. Distinct from acked so a surfaced-but-unhandled event
                    can still re-block instead of being permanently suppressed
  crew-archive.jsonl  append-only history of records removed by `prune`, one JSON
                    object per line, so pruning keeps crew.json lean without losing
                    the record of who ran
  preferences.json  the cached onboarding-preference answers, keyed by wingman run
                    id ({run_id: {key: value}}) so multiple concurrently-alive
                    runs each keep their own answers without clobbering each
                    other. Each answer is asked once via AskUserQuestion and
                    reused for the rest of its run - see
                    cmd_pref_get/cmd_pref_set/cmd_prefs_list
  api-outage-state.json  the persisted fleet-wide outage-state machine (issue
                    #23), written only by wingman's own top-level watch cycle
                    every poll: {"state": "clear"|"active", "since": <ts>,
                    "last_signal": <ts-or-null>, "signal_count": <int>}. See
                    cmd_outage_update. Read directly (not through this tool)
                    by hooks/api-outage-spawn-guard.sh and bin/crew-resume.
  usage-limit-state.json  the persisted fleet-wide usage-quota-approach
                    state machine (issue #24), written only by wingman's own
                    top-level watch cycle every poll from the CLI's own
                    statusline-derived rate_limits signal: {"state":
                    "clear"|"approaching"|"paused"|"acknowledged", "window":
                    "five_hour"|"seven_day"|null, "used_percentage":
                    <float-or-null>, "resets_at": <epoch-or-null>, "since":
                    <ts>, "decided_at": <ts-or-null>}. See cmd_usage_update
                    and cmd_usage_decide. Read directly (not through this
                    tool) by hooks/usage-limit-spawn-guard.sh.
  usage/<session-id>.json  one file per live session (wingman's own
                    top-level session and every crew member alike), written
                    by bin/lib/usage-statusline.py (the installed
                    statusLine command) every time Claude Code invokes it:
                    {"five_hour": {...}, "seven_day": {...}, "captured_at":
                    <ts>}. bin/watch-fleet aggregates these every poll
                    (owner "" only) into the usage-update call above.
  pane-tail-<id>.txt  the last WM_APIERR_TAIL lines of a live working/blocked
                    member's pane, overwritten every poll by bin/watch-fleet
                    (see wm_pane_snapshot). Consulted by cmd_reconcile at the
                    moment a member flips to `died`, to tag death_cause.
  orphan-candidates.json  {window_name: first_seen_iso_stamp} for a live wm-*
                    tmux window with no matching crew.json record, tracked by
                    cmd_reconcile's grace-period-gated orphan-adoption pass
                    (issue #79, owner == "" only) so a window still mid-spawn
                    is never mistaken for one whose record was truly lost.

The merged view of a crew member = its crew.json base record with the live
crew/<id>.json overlaid on top (status/summary/blocker/artifact/artifact_url/
delivery/updated).
crew.json is the roster of record; crew/<id>.json is the live signal. Wingman
reads the merge; it never ingests panes or transcripts.

All JSON is handled here in Python so the shell scripts stay bash-3.2-safe and the
tool works whether or not jq is installed.
"""
import argparse
import contextlib
import datetime
import hashlib
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time

try:
    import fcntl
except ImportError:  # non-POSIX platform; with_locked degrades to best-effort
    fcntl = None

STATUS_FIELDS = ("status", "summary", "blocker", "artifact", "artifact_url", "delivery", "updated", "announced")
# Display-only live-status fields (#155): never part of a member's own reported
# status surface (STATUS_FIELDS above), never iterated generically by
# cmd_crew_set, and carrying no gating weight anywhere - purely annotations a
# render step (merged/render_roster_text/render_tree_text/render_board) may
# show alongside a 'working' status. nudged_at (fix 1) is written by
# cmd_stall_check's --just-nudged (riding the same per-poll call bin/watch-
# fleet already makes for every candidate, rather than a second subprocess
# spawned just to persist a timestamp) and cleared by cmd_crew_set on the
# member's next self-report, or by cmd_stall_check itself on a genuine stall
# flip.
# long_shell_pid/long_shell_elapsed (fix 2) are written by cmd_stall_check's
# per-poll duration probe, independent of the idle-nomination gates.
DISPLAY_ONLY_LIVE_FIELDS = ("nudged_at", "long_shell_pid", "long_shell_elapsed")
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

# The API/connectivity-error pane signature (issue #23), duplicated here from
# bin/watch-fleet's own WM_APIERR_RE default (never imported - the shell and
# this file have no shared config loader; kept in sync with the portable-ERE
# form from #52) so a caller that omits --apierr-re (a direct `wm_state
# reconcile` call in a test, say) still gets sane matching. Production always
# passes the value explicitly from bin/watch-fleet's own $WM_APIERR_RE, so the
# two copies cannot silently drift apart in the path that matters.
DEFAULT_APIERR_RE = (
    r"rate.limit|rate_limit|(^|[^0-9A-Za-z_])429([^0-9A-Za-z_]|$)|"
    r"(^|[^0-9A-Za-z_])5[0-9][0-9] [Ee]rror|overloaded_error|"
    r"Internal Server Error|ECONNRESET|ETIMEDOUT|ENOTFOUND|[Nn]etwork error|"
    r"[Cc]onnection error|Connection refused|fetch failed|socket hang up|"
    r"Service Unavailable|Bad Gateway|Gateway Timeout|"
    r"usage limit reached|credit balance too low"
)


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


def preferences_path():
    return os.path.join(home(), "preferences.json")


def acked_path():
    return os.path.join(home(), "acked.json")


def handled_path():
    return os.path.join(home(), "handled.json")


def outage_state_path():
    return os.path.join(home(), "api-outage-state.json")


def usage_state_path():
    return os.path.join(home(), "usage-limit-state.json")


def orphan_candidates_path():
    return os.path.join(home(), "orphan-candidates.json")


def _sanitize_id(cid):
    """Filesystem-safe form of a crew id, matching bin/lib/common.sh's own
    `tr -c 'A-Za-z0-9._-' '_'` convention used for every other per-id
    sidecar file (pane-<id>.hash, stall-<id>.nudged, ...)."""
    return re.sub(r"[^A-Za-z0-9._-]", "_", cid or "")


def pane_tail_path(cid):
    return os.path.join(home(), "pane-tail-%s.txt" % _sanitize_id(cid))


def read_text(path):
    try:
        with open(path) as fh:
            return fh.read()
    except (FileNotFoundError, OSError):
        return ""


def _apierr_match(text, pattern):
    """True iff `pattern` (grep -qE semantics: ^/$ anchor to each LINE, not
    the whole capture) matches somewhere in `text`. re.MULTILINE reproduces
    that per-line anchoring for a Python re.search over a multi-line pane
    capture."""
    return bool(text) and re.search(pattern, text, re.MULTILINE) is not None


@contextlib.contextmanager
def with_locked(path):
    """Serialize a read-modify-write of a shared store across processes.

    write_json is atomic (os.replace), so no file is ever corrupted, but a
    whole-dict read-modify-write from two processes is last-writer-wins - a
    concurrent watcher fire()-and-ack and a Stop-hook ack can each discard the
    other's key. Holding an exclusive flock on <path>.lock across the entire
    read->modify->write closes that window. Best-effort only on a platform
    without fcntl (fcntl is None): there is no lock to take there, so it
    proceeds without one rather than hard-fail, since the atomic replace still
    prevents corruption. On a POSIX system where fcntl IS available, a
    flock() failure is never silently swallowed - it is re-raised so the
    caller sees a loud, actionable error instead of silently losing the very
    mutual exclusion this function exists to provide (issue #79)."""
    lock_path = path + ".lock"
    fh = None
    try:
        os.makedirs(os.path.dirname(lock_path), exist_ok=True)
        fh = open(lock_path, "w")
        if fcntl is not None:
            try:
                fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
            except OSError as e:
                raise OSError(
                    "with_locked: failed to acquire exclusive lock on %s (%s) - if "
                    "WINGMAN_HOME is on a network filesystem, confirm it supports "
                    "advisory (flock) locking" % (lock_path, e)
                ) from e
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
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".tmp.", dir=d)
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(obj, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


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
        for field in DISPLAY_ONLY_LIVE_FIELDS:
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


# ---------------------------------------------------------------------------
# Spawn-time per-verdict hash commitments for a `reviewer` member's
# comment-fallback verdict (issue #135). A random 32-byte token, generated at
# spawn time and held only in the reviewer's own process environment
# ($WM_REVIEW_TOKEN), never written to any file - see `review-sign` below and
# hooks/no-merge-guard.sh's shape-2 verification for how the derived
# commitments close the marker-impersonation gap this exists for.
# ---------------------------------------------------------------------------
def _verdict_label(verdict):
    v = (verdict or "").strip().lower()
    if v == "approve":
        return b"approve"
    if v in ("request changes", "request-changes", "request_changes"):
        return b"request_changes"
    raise ValueError("verdict must be 'approve' or 'request changes'")


def _review_preimage(token_bytes, crew_id, verdict):
    # crew_id binds the preimage to the specific roster record for defense in
    # depth; the actual security comes from token_bytes being an independent
    # 256-bit random value per reviewer, not from this.
    return hashlib.sha256(
        token_bytes + b"\x00" + crew_id.encode("utf-8") + b"\x00" + _verdict_label(verdict)
    ).digest()


def _review_commitment(preimage_bytes):
    return hashlib.sha256(preimage_bytes).hexdigest()


def _review_preimage_for_commit(token_bytes, crew_id, commit_sha):
    # issue #138: bound to a SPECIFIC PR head commit, unlike _review_preimage
    # (which is fixed per id+verdict forever). Used only for "approve" - the
    # only verdict this merge gate's staleness check consumes (see #135's
    # decision to leave request-changes unchecked).
    return hashlib.sha256(
        token_bytes + b"\x00" + crew_id.encode("utf-8") + b"\x00" +
        b"approve" + b"\x00" + commit_sha.strip().lower().encode("utf-8")
    ).digest()


def _apply_review_token(record, token_hex):
    """(Re)derive and store review_commit_approve/review_commit_request_changes
    from a raw hex token, discarding the raw value immediately - shared by the
    initial mint (cmd_crew_add), an explicit resume regeneration, and an
    automatic delivery-change regeneration (issue #135)."""
    token_bytes = bytes.fromhex(token_hex)
    record["review_commit_approve"] = _review_commitment(
        _review_preimage(token_bytes, record["id"], "approve"))
    record["review_commit_request_changes"] = _review_commitment(
        _review_preimage(token_bytes, record["id"], "request changes"))
    # issue #138: a delivery-change or resume regeneration replaces
    # review_commit_approve with a fresh, non-commit-bound legacy value -
    # any review_commit_approve_sha left over from before would now compare
    # a leftover, meaningless commit reference against whatever PR this
    # record is newly pointed at. Reset to None (the same "not yet
    # commit-bound" tier a never-signed reviewer already sits in) until the
    # reviewer re-signs.
    record["review_commit_approve_sha"] = None


def cmd_crew_add(args):
    ensure_home()
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
        "window_id": getattr(args, "window_id", "") or "",
        "session_id": args.session_id,
        "status": "working",
        "summary": "",
        "blocker": None,
        "artifact": None,
        "artifact_url": None,
        "delivery": None,
        # The git worktree this member works in, recorded at spawn (repo scope) so a
        # non-graceful exit (dead/orphaned member) can still be torn down by
        # crew-standdown. Empty when unknown at spawn (global scope self-registers it
        # later via crew-set --worktree).
        "worktree": getattr(args, "worktree", "") or "",
        # Explicit, per-effort merge autonomy (issue #46). False unless the spawn
        # itself requested it (bin/spawn-crew --allow-merge); a mid-session grant
        # goes through crew-set --allow-merge instead, never through here again.
        "allow_merge": bool(getattr(args, "allow_merge", False)),
        # Explicit, per-effort escape hatch from the review-evidence gate
        # hooks/no-merge-guard.sh now layers on top of allow_merge (issue #132):
        # False unless the spawn itself requested it (bin/spawn-crew
        # --waive-review-gate); a mid-session grant goes through crew-set
        # --review-gate-waived instead, never through here again. Gated by the
        # identical self-grant restriction allow_merge already carries - see
        # hooks/no-merge-guard.sh's check_review_gate_waiver_grant().
        "review_gate_waived": bool(getattr(args, "review_gate_waived", False)),
        # Spawn-time per-verdict hash commitments (issue #135), reviewer type
        # only: sha256(sha256(token || id || verdict)) for each of "approve"
        # and "request changes", derived below via _apply_review_token and
        # storing only the hashes - never the raw token itself, which lives
        # only in this member's own process environment (WM_REVIEW_TOKEN, see
        # bin/spawn-crew). None for every non-reviewer record, and for a
        # reviewer record with no token (a manual/legacy crew-add) - in
        # either case hooks/no-merge-guard.sh's shape-2 check falls straight
        # through to today's marker-only acceptance.
        "review_commit_approve": None,
        "review_commit_request_changes": None,
        # The commit SHA the CURRENT review_commit_approve commitment is
        # bound to (issue #138) - None until the reviewer has performed at
        # least one commit-bound sign (`review-sign --commit`, see
        # cmd_review_sign). This is the field hooks/no-merge-guard.sh's
        # shape-2 staleness check consults; reset to None alongside every
        # review_commit_approve regeneration by _apply_review_token.
        "review_commit_approve_sha": None,
        # A dedicated, monotonic marker of "the last non-empty delivery this
        # record was ever genuinely bound to" (issue #135, round 2) - see
        # cmd_crew_set's delivery-change regeneration trigger for why this
        # must never be inferred from the live, clearable `delivery` field
        # itself. None until a delivery is first set, for every reviewer
        # record regardless of whether it carries a token.
        "review_delivery_bound": None,
        # Remote Control visibility (issue #96): whether this member launched
        # Remote-Control-visible (bin/spawn-crew --remote-control), and
        # wingman's own best-known estimate of whether that connection is
        # still live. Launching with --remote-control starts a session
        # actively connected, so there is no ambiguity at spawn time; a
        # member that never had Remote Control enabled records `None` for
        # "not applicable/never tracked" rather than a misleading False.
        # bin/watch-fleet's regular poll is the only writer of
        # remote_control_connected afterward (via crew-set); a legacy record
        # predating this field reads both as absent, and every read site in
        # this codebase treats that absence as True (see bin/crew-standdown
        # and cmd_needs_attention/cmd_group_attention below) - WM_REMOTE_CONTROL
        # already defaults on, so absence is far more likely to mean "predates
        # this fix" than "deliberately off".
        "remote_control": bool(getattr(args, "remote_control", False)),
        "remote_control_connected": True if getattr(args, "remote_control", False) else None,
        # Git/PR-workflow determinant, a real tri-state (True/False/None), never a
        # string: None means "unknown at spawn time - detect it yourself" (global
        # scope, or a pre-change record), and must never be read as False. Only
        # ever passed for repo scope (bin/spawn-crew); mirrors the `allow_merge`
        # idiom just above (string arg -> real bool) rather than storing the raw
        # "true"/"false" string, which every downstream reader would misread as
        # truthy regardless of value.
        "is_git": None if getattr(args, "is_git", None) is None else args.is_git == "true",
        # Only meaningful when is_git is True; None otherwise (no remote to speak
        # of when there's no repo, or the repo-ness itself is undecided).
        "has_remote": None if getattr(args, "has_remote", None) is None else args.has_remote == "true",
        # The prior parent of a re-adopted orphan (set by reconcile's dead-owner
        # pass): standing down the dead owner still reaps a member whose
        # orphaned_from names it, even though its live parent was moved to the
        # grandparent. None until the member is orphaned.
        "orphaned_from": None,
        # Cause attribution for a `died` flip (issue #23), set only by
        # cmd_reconcile at the moment it flips this record - "api-outage" if
        # the member's cached pane tail (pane_tail_path) matched the
        # API-error signature just before its window disappeared, otherwise
        # left None (today's behavior: an ordinary death with no cause on
        # record, e.g. a tmux/host crash). Roster-only, like orphaned_from -
        # never mirrored into the live status file.
        "death_cause": None,
        # Immutable spawn stamp; never rewritten by crew-set (see the stamp comment
        # above). Consumed by the prompt-freeze liveness veto.
        "spawned_at": stamp,
        "updated": stamp,
    }
    if args.type == "reviewer" and getattr(args, "review_token", None):
        _apply_review_token(record, args.review_token)
    with with_locked(crew_json_path()):
        roster = load_roster()
        roster = [r for r in roster if r.get("id") != args.id]
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
            "artifact_url": None,
            "delivery": None,
            "updated": stamp,
        })
    render_board()
    print(args.id)


def _artifact_marker_url(member_id, artifact_path, cwd=None):
    """Look up the durable publish marker hooks/artifact-publish-tracker.sh
    wrote for this crew member's own Claude session id, and return the
    published URL only if its recorded sha256 still matches the artifact's
    current contents - mirroring the exact check
    hooks/artifact-link-guard.sh already performs to gate the crew-set call
    that triggers this lookup, so a stale marker (edited-but-not-republished
    file) yields no URL here either."""
    if not artifact_path:
        return None
    session_id = None
    for r in load_roster():
        if r.get("id") == member_id:
            session_id = r.get("session_id")
            break
    sid = _sanitize_id(session_id)
    if not sid:
        return None
    resolved = artifact_path
    if not os.path.isabs(resolved):
        resolved = os.path.join(cwd or os.getcwd(), resolved)
    resolved = os.path.realpath(resolved)
    store = read_json(os.path.join(home(), "artifact-markers", sid + ".json"), None)
    if not isinstance(store, dict):
        return None
    entry = store.get(resolved)
    if not isinstance(entry, dict) or entry.get("status") != "published":
        return None
    sha = entry.get("sha256")
    if not sha:
        return None
    try:
        with open(resolved, "rb") as fh:
            current_sha = hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        return None
    if sha != current_sha:
        return None
    return entry.get("url") or None


def cmd_crew_set(args):
    """Update a crew member's live status file (crew/<id>.json).

    This is what a crew member itself calls to report distilled status. Only
    provided fields change; the roster record is mirrored for the terminal fields.
    """
    ensure_home()
    if args.silent and args.status in ("blocked", "done"):
        sys.exit("wm-state: --silent may not be used with --status %s - "
                  "blocked/done are always genuine and must always announce" % args.status)
    live = read_json(status_path(args.id), {"id": args.id})
    live["id"] = args.id
    prev_status = live.get("status")
    prev_pointer = (live.get("artifact"), live.get("blocker"), live.get("delivery"))
    for field in STATUS_FIELDS[:-2]:  # everything but 'updated' and 'announced'
        val = getattr(args, field, None)
        if val is not None:
            live[field] = None if val == "" and field in ("blocker", "artifact", "artifact_url", "delivery") else val
    # nudged_at (#155 fix 1) is stamped elsewhere (cmd_stall_check's --just-
    # nudged, riding the existing per-poll stall-check call bin/watch-fleet
    # already makes for every candidate) - this function only ever CLEARS it,
    # on the member's own next self-report. A call that touches at least one
    # of the live-status fields below is exactly that (every self-report sets
    # at least --summary); a call that touches none of them (a pure
    # bookkeeping write - --worktree, --remote-control-connected, --window-id,
    # --allow-merge, --review-gate-waived, --regenerate-review-token) is not,
    # and must leave nudged_at alone: it comes from the watcher/orchestrator
    # tooling acting on the member's behalf, not from the member itself, so it
    # must never silently erase an in-progress nudge episode. cmd_stall_check
    # also clears nudged_at directly when it confirms a genuine stall - that
    # path writes the status file itself and never goes through here.
    if any(getattr(args, f, None) is not None for f in
           ("status", "summary", "blocker", "artifact", "artifact_url", "delivery")):
        live.pop("nudged_at", None)
    # Auto-derive artifact_url from the publish marker unless the caller passed an
    # explicit value (including an explicit clear, already applied above) - see
    # _artifact_marker_url. This removes the free-text "remember to report the URL"
    # step entirely (issue #110): the member never has to type the URL anywhere.
    if getattr(args, "artifact_url", None) is None:
        detected = _artifact_marker_url(args.id, live.get("artifact"))
        if detected:
            live["artifact_url"] = detected
    live["updated"] = now()
    # `announced` is the dedup key needs-attention actually watches (see its
    # docstring), and it must survive an intervening `working` dip untouched: a
    # developer's review -> working (fixing CI) -> review round trip must leave
    # `announced` exactly where it was before the dip, or the silent re-entry
    # below would find it already bumped by the plain `working` call and
    # wrongly surface. So it only ever advances on a call that both (a) is not
    # silent and (b) actually sets status to one of the attention states this
    # dedup key exists for (review/blocked/done - died/stalled are set directly
    # by reconcile/stall-check, not through here). For `review` specifically,
    # it advances only on a genuine transition into review from a different
    # prior status, or a material change to the artifact/blocker/delivery
    # pointer while already in review - a same-status call that only touches
    # `summary` (the documented anti-stall escape hatch) leaves `announced`
    # untouched, so a member sitting unchanged in `review` across many benign
    # refreshes is not re-surfaced on every one of them. `blocked` and `done`
    # are unscoped by this: `--silent` is already forbidden for them, so every
    # non-silent call is genuine and always announces, transition or not.
    # Every other call - a `working` transition, a mid-review summary refresh,
    # or an explicit `--silent` - leaves `announced` exactly as it was (seeded
    # via setdefault only if this is the very first write for this id, so a
    # record is never left without one). See playbooks/_status-contract.md,
    # "Re-entering review without re-announcing" - a genuine re-delivery must
    # dip through `working` first so this gate can tell it apart from churn.
    if not args.silent and args.status in ATTENTION_STATES:
        if args.status == "review":
            new_pointer = (live.get("artifact"), live.get("blocker"), live.get("delivery"))
            genuinely_new = (args.status != prev_status) or (new_pointer != prev_pointer)
        else:  # blocked/done: --silent is already forbidden, every call is genuine
            genuinely_new = True
        if genuinely_new:
            live["announced"] = live["updated"]
        else:
            live.setdefault("announced", live["updated"])
            print("wm-state: suppressed as a same-status review refresh (artifact/blocker/delivery "
                  "unchanged) - if this was meant as a re-delivery, dip through --status working "
                  "first; if it's routine self-managed churn (a summary refresh while parked), "
                  "this is expected and no action is needed", file=sys.stderr)
    else:
        live.setdefault("announced", live["updated"])
    write_json(status_path(args.id), live)

    # Mirror the durable fields back into the roster so a stale crew.json alone
    # still tells the truth if the status file is later removed.
    with with_locked(crew_json_path()):
        roster = load_roster()
        for r in roster:
            if r.get("id") == args.id:
                # --- issue #135: review-token commitment regeneration. Both
                # triggers live in this same per-record block (never a
                # separate pass appended after it) so they run atomically
                # with the rest of this record's write, under the single
                # with_locked(...) critical section already guarding this
                # whole function.
                #
                # 1. Delivery-change trigger: fires only when a non-empty
                # --delivery differs from a non-empty review_delivery_bound
                # already on an already-tokened `type == reviewer` record - a
                # live reviewer repointed at a different PR mid-session, the
                # exact scenario that would otherwise let a proof genuinely
                # posted for the OLD PR keep validating against the new one
                # (issue #135, round 1). review_delivery_bound is a
                # dedicated, monotonic field - unlike the live `delivery`
                # field, an intervening `--delivery ""` clear never resets it
                # (round 2), so however many clear-and-reassign steps
                # separate two real deliveries, the next non-empty
                # --delivery is always compared against the last one this
                # record was genuinely bound to. The far more common
                # first-ever delivery set (review_delivery_bound still None)
                # regenerates nothing - the commitment was never PR-specific
                # to begin with.
                if args.delivery is not None and r.get("type") == "reviewer" \
                        and r.get("review_commit_approve"):
                    bound = r.get("review_delivery_bound")
                    if args.delivery and bound and bound != args.delivery:
                        new_token_hex = secrets.token_hex(32)
                        _apply_review_token(r, new_token_hex)
                        print("review-token: %s" % new_token_hex)
                    if args.delivery:
                        r["review_delivery_bound"] = args.delivery
                # 2. Explicit resume regeneration: bin/crew-resume passes a
                # freshly generated token for every resumed `died` reviewer
                # (its stdout redirected to /dev/null - the token is never
                # echoed back to the invoking wingman/lead session, unlike
                # the internally-generated one printed just above, which has
                # no other holder that already knows it).
                if getattr(args, "regenerate_review_token", None):
                    _apply_review_token(r, args.regenerate_review_token)
                    # A freshly-minted commitment carries no evidence yet,
                    # regardless of what delivery this record already had
                    # going into the regeneration (issue #135, round 3):
                    # re-baseline review_delivery_bound to the CURRENT
                    # delivery so the next delivery CHANGE is correctly
                    # detected, rather than misread as a "first-ever"
                    # assignment. Reads `live`, not `r` (round 4 should-fix):
                    # `live` was already resolved from args.delivery earlier
                    # in this function, before this roster block even opens,
                    # so this is correct regardless of insertion order here
                    # and regardless of whether a future caller ever combines
                    # this flag with --delivery in the same call - the same
                    # convention several other fields in this block already
                    # follow (e.g. artifact_url below). A no-op when
                    # review_delivery_bound is already in sync (the common,
                    # already-tokened-reviewer-crashes-and-resumes case);
                    # only changes behavior for a reviewer gaining its
                    # first-ever commitment here.
                    r["review_delivery_bound"] = live.get("delivery")
                for field in ("status", "artifact", "delivery"):
                    if getattr(args, field, None) is not None:
                        r[field] = live.get(field)
                # artifact_url mirrors unconditionally, unlike status/artifact/delivery
                # above: it can change from auto-detection alone with no corresponding
                # CLI arg on this call, so gating the mirror on an explicit --artifact-url
                # would silently drop it from the roster (and the stale-status-file
                # fallback read) - exactly the gap this field exists to close.
                r["artifact_url"] = live.get("artifact_url")
                # worktree is a roster-only field (not a live-status field): a member
                # that creates its worktree after spawn (global scope) self-registers
                # the path here so a later teardown can find it.
                if getattr(args, "worktree", None) is not None:
                    r["worktree"] = args.worktree
                # allow_merge is likewise roster-only (issue #46): a grant/revoke is
                # never part of a member's own live-status report, so it never touches
                # crew/<id>.json - only the roster record hooks/no-merge-guard.sh reads.
                if getattr(args, "allow_merge", None) is not None:
                    r["allow_merge"] = args.allow_merge == "true"
                # review_gate_waived is likewise roster-only (issue #132): a grant/
                # revoke is never part of a member's own live-status report, so it
                # never touches crew/<id>.json - only the roster record
                # hooks/no-merge-guard.sh reads.
                if getattr(args, "review_gate_waived", None) is not None:
                    r["review_gate_waived"] = args.review_gate_waived == "true"
                # remote_control_connected is likewise roster-only (issue #96):
                # bin/watch-fleet's regular, stability-gated poll is the only
                # writer, so bin/crew-standdown can read a previously-vetted
                # value instead of taking its own single-shot, unguardable
                # pane read at standdown time.
                if getattr(args, "remote_control_connected", None) is not None:
                    r["remote_control_connected"] = args.remote_control_connected == "true"
                # window_id is likewise roster-only: crew-resume re-registers the id
                # of the replacement window it creates, so stray-window adoption
                # (wm_tmux_adopt_strays) keeps an exact identity to match on.
                if getattr(args, "window_id", None) is not None:
                    r["window_id"] = args.window_id
                r["updated"] = live["updated"]
        write_json(crew_json_path(), roster)
    render_board()
    print(args.id)


def cmd_review_sign(args):
    """Produce the preimage for a reviewer's own review-token commitment, to
    embed in a comment-fallback PR verdict (issue #135). Performs no file I/O
    and touches no roster field UNLESS --commit is given with --verdict
    approve (issue #138), in which case it also derives and persists a fresh,
    commit-bound commitment onto this session's OWN roster record before
    printing the preimage. Any crew session may call this - only a session
    that actually holds WM_REVIEW_TOKEN (a genuine reviewer, or one resumed
    via --regenerate-review-token) produces a preimage that matches anything
    a merge-gate check trusts."""
    token_hex = args.token or os.environ.get("WM_REVIEW_TOKEN", "")
    crew_id = os.environ.get("WINGMAN_CREW_ID", "")
    if not token_hex or not crew_id:
        sys.exit("wm-state: WM_REVIEW_TOKEN/WINGMAN_CREW_ID not set in this "
                  "session's environment - only a reviewer session spawned "
                  "with a review token has this")
    try:
        token_bytes = bytes.fromhex(token_hex)
    except ValueError:
        sys.exit("wm-state: WM_REVIEW_TOKEN/--token is not valid hex")

    if args.commit and args.verdict == "approve":
        # issue #138: derive a commitment bound to THIS commit and persist it
        # onto this session's OWN roster record before printing the preimage.
        # Self-scoped by construction - crew_id always comes from THIS
        # process's own environment, never a --id flag, so this write can
        # never target another crew member's record and needs no additional
        # hook-side gating (matches #135's reasoning for why review-sign
        # needed none).
        preimage = _review_preimage_for_commit(token_bytes, crew_id, args.commit)
        commitment = _review_commitment(preimage)
        ensure_home()
        with with_locked(crew_json_path()):
            roster = load_roster()
            for r in roster:
                if r.get("id") == crew_id:
                    r["review_commit_approve"] = commitment
                    r["review_commit_approve_sha"] = args.commit.strip().lower()
                    r["updated"] = now()
                    write_json(crew_json_path(), roster)
                    render_board()
                    break
    else:
        try:
            preimage = _review_preimage(token_bytes, crew_id, args.verdict)
        except ValueError as e:
            sys.exit("wm-state: %s" % e)
    print(preimage.hex())


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

    Cause attribution (issue #23): each flip also checks the member's cached
    pane-tail file (pane_tail_path, written every poll by bin/watch-fleet for
    a live working/blocked member) against --apierr-re; a match tags
    death_cause="api-outage" on the roster record, otherwise death_cause stays
    unset - see cmd_group_attention for how this feeds the correlated-batch
    split and cmd_outage_update for the fleet-wide signal it feeds.

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
    apierr_re = getattr(args, "apierr_re", None) or DEFAULT_APIERR_RE
    live_windows = set(w for w in (args.windows or "").split(",") if w)
    with with_locked(crew_json_path()):
        roster = load_roster()
        changed = []
        for r in roster:
            m = merged(r)
            if m.get("status") in LIVE_STATES and r.get("window") not in live_windows:
                r["status"] = "died"
                r["updated"] = now()
                if _apierr_match(read_text(pane_tail_path(r["id"])), apierr_re):
                    r["death_cause"] = "api-outage"
                # reflect into the status file too
                live = read_json(status_path(r["id"]), {"id": r["id"]})
                live["status"] = "died"
                live["updated"] = r["updated"]
                live["announced"] = live["updated"]  # a died event always announces
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
                live["announced"] = stamp  # re-fires the died event; always genuine
                write_json(status_path(dead_id), live)

        # Orphan-window adoption, wingman's watcher only (owner == ""), issue #79.
        # A live wm-*-prefixed tmux window with no matching roster record is
        # tracked - not immediately adopted - across polls in orphan-candidates.json,
        # so a window still mid-spawn (created a moment before crew-add lands, which
        # happens in every ordinary spawn) is never mistaken for one whose record was
        # genuinely lost (review finding MF-1). Only a window that stays unmatched
        # past --grace-seconds is adopted, as a roster-only `blocked` record (SF-2:
        # never a status file, so a delayed crew-add can still seed one cleanly).
        if owner == "":
            known_windows = set(r.get("window") for r in roster if r.get("window"))
            candidates = read_json(orphan_candidates_path(), {})
            if not isinstance(candidates, dict):
                candidates = {}
            grace = getattr(args, "grace_seconds", None)
            if grace is None:
                grace = 15
            stamp = now()
            live_unmatched = set(
                w for w in live_windows if w.startswith("wm-") and w not in known_windows
            )
            # Prune every candidate that's resolved: its window is no longer live
            # (the spawn never completed), or it now matches a roster record (the
            # ordinary case - crew-add landed before the grace period elapsed).
            for w in list(candidates.keys()):
                if w not in live_unmatched:
                    del candidates[w]
            for w in live_unmatched:
                first_seen = candidates.get(w)
                if first_seen is None:
                    candidates[w] = stamp
                    continue
                seen_dt = _parse_updated(first_seen)
                if seen_dt is None:
                    candidates[w] = stamp  # unparseable stamp; restart the clock
                    continue
                age = (datetime.datetime.now(datetime.timezone.utc) - seen_dt).total_seconds()
                if age < grace:
                    continue
                cid = w[len("wm-"):]  # strip only the leading prefix - ids contain hyphens
                blocker = (
                    "auto-adopted: this window was live with no matching crew.json "
                    "record for over %ss (issue #79) - verify its real state with "
                    "bin/crew-takeover %s before trusting it, or bin/crew-standdown %s "
                    "if it's stale" % (grace, cid, cid)
                )
                roster.append({
                    "id": cid,
                    "type": "unknown",
                    "objective": "",
                    "repo": "",
                    "scope": "repo",
                    "parent": "",
                    "window": w,
                    "window_id": "",
                    "session_id": "",
                    "status": "blocked",
                    "summary": "",
                    "blocker": blocker,
                    "artifact": None,
                    "artifact_url": None,
                    "delivery": None,
                    "worktree": "",
                    "allow_merge": False,
                    "review_gate_waived": False,
                    "is_git": None,
                    "has_remote": None,
                    "orphaned_from": None,
                    "death_cause": None,
                    "orphan_adopted": True,
                    "spawned_at": stamp,
                    "updated": stamp,
                })
                del candidates[w]
            write_json(orphan_candidates_path(), candidates)

        write_json(crew_json_path(), roster)
    render_board()
    print(" ".join(changed))


def cmd_standdown(args):
    """Mark a member stood-down, cascading to every member it owns so a lead's
    whole sub-crew is reaped with it (never orphaned). Prints each affected id
    (one per line) so the caller can close the corresponding tmux windows."""
    ensure_home()
    with with_locked(crew_json_path()):
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
    with with_locked(crew_json_path()):
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


def _longest_running_descendant(root_pid, root_grace):
    """Of root_pid's descendants that qualify as _probe_execution's branch (a)
    proof-of-life (started more than root_grace seconds after the root - the
    identical test, from a fresh ps sample), return the (pid, elapsed_seconds)
    of whichever has the largest OWN elapsed time - i.e. the single descendant
    that has itself been running longest, in absolute terms. None if the tree
    cannot be read or nothing qualifies.

    `elapsed` is always the kernel's own current reading for that pid, fetched
    fresh on every call - never accumulated or extrapolated locally - so pid
    reuse across polls can never inflate a duration: a reused pid simply
    reports whatever (short) elapsed time IT has actually been running the
    moment it is asked, regardless of what the previous occupant's elapsed was
    a poll ago."""
    tree = _ps_tree(root_pid)
    if not tree or root_pid not in tree:
        return None
    root_elapsed = tree[root_pid][1]
    best = None
    for pid, (_cpu, elapsed) in tree.items():
        if pid == root_pid:
            continue
        if (root_elapsed - elapsed) > root_grace and (best is None or elapsed > best[1]):
            best = (pid, elapsed)
    return best


def _track_long_running(cid, live, pane_pid, root_grace):
    """Persist the elapsed time of the single longest-lived qualifying
    descendant (see _longest_running_descendant) onto the member's own status
    JSON, so a render step (crew-list/board.md) can surface a 'been running
    longer than usual' annotation (#155 fix 2) without itself walking the
    process tree or needing to know the warn ceiling.

    Called on every cmd_stall_check invocation for a 'working' member with a
    resolvable pid - independent of the idle-nomination gates below it, since
    the scenario this exists to catch (a single long-outstanding tool call or
    background shell) keeps Claude Code's own pane repainting via its "N
    shell(s) still running" indicator, so pane_idle/status_idle may never
    cross STALL_IDLE and the rest of cmd_stall_check would otherwise never run
    at all for this member.

    Writes directly to disk (bypassing cmd_crew_set) and touches only
    long_shell_pid/long_shell_elapsed - never `updated`/`announced` - so this
    can never itself reset the staleness clock the rest of the stall-detection
    machinery depends on, and never fires the watcher/Stop-hook wake. Clears
    both fields the instant no qualifying descendant is found - a legitimately
    finished command, or the watcher's own next poll simply catching the
    process tree between two different qualifying descendants - so a stale
    annotation never lingers past the process it described.
    """
    found = _longest_running_descendant(pane_pid, root_grace)
    if found is None:
        if "long_shell_pid" in live or "long_shell_elapsed" in live:
            live.pop("long_shell_pid", None)
            live.pop("long_shell_elapsed", None)
            write_json(status_path(cid), live)
        return
    pid, elapsed = found
    if live.get("long_shell_pid") == pid and live.get("long_shell_elapsed") == elapsed:
        return  # unchanged since the last poll - nothing new to persist
    live["long_shell_pid"] = pid
    live["long_shell_elapsed"] = elapsed
    write_json(status_path(cid), live)


def cmd_stall_check(args):
    """Flag a WORKING crew member as 'stalled' iff it shows no external sign of life:
    BOTH staleness gates (pane_idle from the watcher, status_idle computed here) at
    or past --threshold, AND the execution probe over --pane-pid finds no evidence,
    AND (#61) a check-in nudge has already had a full cooldown window to work.

    --nudge-age is the age in seconds of the watcher's per-id nudge marker file, or
    -1 if no marker exists yet. A genuine stall only flips once --nudge-age is >= 0
    and >= --threshold - i.e. the watcher already sent one check-in nudge (the
    marker exists) and a full window has passed with no activity. On the first
    confirmed-idle poll (no marker yet, --nudge-age -1) or before the marker has
    aged past --threshold, this returns without flipping: the watcher sends (or
    already sent) the nudge and the flip is deferred to a later poll. A member that
    self-reports in the meantime never reaches this gate at all - the read-back
    re-check above already bails once status stops being 'working'.

    Prints 'stalled' if it flipped the member, nothing otherwise. Idempotent and safe
    to call every poll: gates fail fast, the probe runs only for nominated candidates,
    and once flipped, status != 'working' so subsequent calls skip.

    --api-error only changes which reason template a genuine stall is written with
    (an 'api-error:' prefix instead of the default) - it never changes the gates or
    the probe above, and does not by itself cause a flip.

    --just-nudged and the long-shell duration tracking below (#155 fixes 1/2) are
    unconditional side effects that run on every call regardless of the gates
    above - see their own inline comments for why - and never change whether or
    when a flip happens."""
    ensure_home()
    live = read_json(status_path(args.id), None)
    if not isinstance(live, dict) or live.get("status") != "working":
        return
    updated = _parse_updated(live.get("updated"))
    if updated is None:
        return

    # #155 fix 1: stamp nudged_at the moment bin/watch-fleet passes
    # --just-nudged 1 - the same poll it actually sent the check-in nudge.
    # Written directly (not through cmd_crew_set) so this never touches
    # summary/status/`updated`/`announced` or fires the watcher/Stop-hook
    # wake; cmd_crew_set clears it again on the member's own next self-report
    # (see there), and a genuine stall flip below clears it directly too.
    if getattr(args, "just_nudged", 0):
        live["nudged_at"] = now()
        write_json(status_path(args.id), live)

    # #155 fix 2: long-shell duration tracking runs unconditionally for every
    # 'working' member with a resolvable pid, independent of the idle-
    # nomination gates just below - see _track_long_running's docstring for
    # why it cannot wait for those gates to pass first.
    _track_long_running(args.id, live, args.pane_pid, args.root_grace)

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

    # #61: a genuine stall only flips once a check-in nudge has already had a full
    # cooldown window to produce activity - not on the very poll that first detects
    # it. No marker yet (-1) or too young (< threshold) means the watcher's nudge
    # hasn't had time to work yet; defer without mutating anything.
    nudge_age = getattr(args, "nudge_age", -1)
    if nudge_age < 0 or nudge_age < args.threshold:
        return

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
                  "for >%ds while status was 'working', even after a check-in nudge - the "
                  "agent likely errored or went idle. Inspect with `bin/crew-takeover %s` "
                  "or stand down with `bin/crew-standdown %s`."
                  % (int(args.threshold), args.id, args.id))
    if prior:
        reason += " (last summary: %s)" % prior

    live["status"] = "stalled"
    live["summary"] = reason
    live["updated"] = now()
    live["announced"] = live["updated"]  # a stall flip always announces
    # #155 fix 1: a genuine stall confirms the nudge did not work - clear the
    # nudge-in-progress annotation along with the flip itself, since `stalled`
    # (not a still-'working' render) is now the accurate signal to show.
    live.pop("nudged_at", None)
    write_json(status_path(args.id), live)

    # Mirror into the roster, as crew-set does, so a later loss of the status
    # file still tells the truth.
    with with_locked(crew_json_path()):
        roster = load_roster()
        for r in roster:
            if r.get("id") == args.id:
                r["status"] = "stalled"
                r["updated"] = live["updated"]
        write_json(crew_json_path(), roster)
    render_board()
    print("stalled")


def _attention_suppressed(rid, upd, suppress_on, only_acked, acked, handled):
    """Shared gate for needs-attention: True iff the (rid, upd) event should be
    withheld under the selector rules documented on cmd_needs_attention."""
    if suppress_on == "handled":
        if handled.get(rid) == upd:
            return True  # already fully handled
    else:  # "ack": suppress an event acked OR handled (watcher/fire gate)
        if acked.get(rid) == upd or handled.get(rid) == upd:
            return True
    if only_acked and acked.get(rid) != upd:
        return True  # restrict to currently-acked events
    return False


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
    carries a new `announced` and surfaces again.

    The dedup key is `announced` (falling back to `updated` for a record written
    before that field existed), not `updated` directly: a genuine `crew-set
    --status review` call - a transition into review from a different prior
    status, or a material change to the artifact/blocker/delivery pointer while
    already in review - bumps both `announced` and `updated`, so it surfaces
    normally, while a same-status review call that only touches `summary`, or an
    explicit `--silent` call, bumps only `updated` (see cmd_crew_set), so
    self-managed churn - the member cycling through `working` to resolve
    something that was its own to fix, or just refreshing its summary while
    parked in review - settles back into (or stays in) `review` without
    re-firing this loop, even though `updated` itself has visibly advanced for
    anyone who looks at the roster directly. This same-status suppression is
    scoped to `review` only: `blocked` and `done` always bump both fields on
    every non-silent call, since `--silent` is forbidden for them.

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
    roster = load_roster()
    for r in (merged(x) for x in roster):
        if owner is not None and parent_of(r) != owner:
            continue
        if r.get("status") in ATTENTION_STATES:
            rid = r["id"]
            upd = r.get("announced") or r.get("updated")
            if _attention_suppressed(rid, upd, suppress_on, only_acked, acked, handled):
                continue
            # The note is a short hint for wingman to relay; prefer the pointer the
            # pilot needs (the blocker to answer, the PR/branch delivered, the
            # hosted Artifact URL, or the local artifact path) over the free-text
            # summary. A hosted URL is a strictly more useful single-line pointer
            # than the local path when both are present.
            note = (r.get("blocker") or r.get("delivery")
                    or r.get("artifact_url") or r.get("artifact") or r.get("summary") or "")
            # Stale Remote Control caveat (issue #96): nothing can deregister a
            # died member's Remote Control entry after the fact (no mechanism
            # exists - see the plan), so make the staleness visible in the one
            # note every died relay already flows through, rather than relying
            # on prose discipline elsewhere. `remote_control` absent reads as
            # True - see cmd_crew_add's comment for why.
            if r.get("status") == "died" and r.get("remote_control", True):
                note = note + (" (Remote Control may still show 'wm-%s' as connected "
                                "- this is stale; disregard it.)" % rid)
            print("%s\t%s\t%s\t%s" % (
                rid, r["status"], upd or "", note))


def cmd_group_attention(args):
    """Read needs-attention's TSV from stdin (id, status, updated, note) and
    collapse fleet-wide correlated batches into one synthetic row each, passing
    every other row through unchanged. Three recognized patterns, all meaning
    "many crew show the same abnormal signal in one pass":
      - status == "died", death_cause != "api-outage"          -> key "mass-death"
      - status == "died", death_cause == "api-outage"           -> key "api-outage-death"
      - status == "stalled" and note startswith "api-error:"    -> key "api-outage"
    A group collapses only at or above --mass-min-count AND --mass-min-ratio (of
    the relevant live population - see below); below threshold its rows pass
    through individually, so one routine died/stalled member is untouched.

    The `died` batch is partitioned by death_cause (issue #23, item 1) BEFORE
    the threshold is applied, and each partition is evaluated independently: a
    minority of outage-tagged deaths inside a larger crash-caused batch is
    never silently absorbed into "likely a tmux/host crash" (which would wrongly
    invite an immediate resume into a still-live burst), and vice versa - a
    minority of ordinary crash deaths alongside a larger outage-tagged batch is
    never absorbed into the "wait for outage-cleared" message. death_cause is
    read fresh from the roster (merged view), not from the TSV note.

    Pure filter: recomputes the roster snapshot fresh on every call and writes
    nothing. A synthetic row's id ("correlated:mass-death"/"correlated:api-
    outage-death"/"correlated:api-outage") is not a real crew id - callers must
    ack/mark-handled from the ORIGINAL ungrouped needs-attention output, never
    from this filtered one. --owner scopes the ratio's denominator to the same
    cohort needs-attention was called with ("" = top level, matching a lead's
    own scope), so a lead's cycle judges "N of M" against its own team, not the
    whole fleet.

    Ratio denominators: a `died` member (either cause) has just left
    LIVE_STATES, so both death partitions share one denominator - (current live
    count for this owner) + (total died rows in this batch, both causes) -
    "how many were live a moment before this pass," not the post-death count,
    which would undercount and inflate the ratio. `stalled` is still a
    LIVE_STATES member, so api-outage's denominator is simply the current live
    count - no adjustment needed."""
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

    death_cause_by_id = {}
    # Same lookup pattern as death_cause_by_id, for the same reason (issue
    # #96): a mass-death batch is exactly the scenario (a host/tmux crash)
    # issue #96 was originally reported from, so the synthetic note needs the
    # same stale-Remote-Control caveat cmd_needs_attention already adds to a
    # single died row. Absent reads as True (see cmd_crew_add's comment).
    remote_control_by_id = {}
    for r in load_roster():
        death_cause_by_id[r.get("id")] = merged(r).get("death_cause")
        remote_control_by_id[r.get("id")] = merged(r).get("remote_control", True)

    died_rows = [r for r in rows if r[1] == "died"]
    outage_death_rows = [r for r in died_rows if death_cause_by_id.get(r[0]) == "api-outage"]
    crash_death_rows = [r for r in died_rows if death_cause_by_id.get(r[0]) != "api-outage"]
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

    crash_collapse = bool(crash_death_rows) and collapses(len(crash_death_rows), mass_denominator)
    outage_death_collapse = bool(outage_death_rows) and collapses(len(outage_death_rows), mass_denominator)
    outage_collapse = bool(outage_rows) and collapses(len(outage_rows), outage_denominator)
    crash_ids = set(r[0] for r in crash_death_rows)
    outage_death_ids = set(r[0] for r in outage_death_rows)
    outage_ids = set(r[0] for r in outage_rows)

    resume_cmd = "bin/crew-resume --all-died"
    if owner:
        resume_cmd += " --owner %s" % owner

    emitted_mass = False
    emitted_outage_death = False
    emitted_outage = False
    for rid, status, upd, note in rows:
        if crash_collapse and rid in crash_ids:
            if emitted_mass:
                continue
            emitted_mass = True
            names = ", ".join("`%s`" % i for i in (r[0] for r in crash_death_rows))
            synth_note = ("%d crew members died together (likely a tmux/host crash): %s. "
                          "Default remedy: `%s`." % (len(crash_death_rows), names, resume_cmd))
            if any(remote_control_by_id.get(i, True) for i in crash_ids):
                synth_note += (" Some of these may also still show as connected in "
                                "Remote Control; disregard any such entry.")
            print("%s\t%s\t%s\t%s" % ("correlated:mass-death", "died", now(), synth_note))
            continue
        if outage_death_collapse and rid in outage_death_ids:
            if emitted_outage_death:
                continue
            emitted_outage_death = True
            names = ", ".join("`%s`" % i for i in (r[0] for r in outage_death_rows))
            synth_note = ("%d crew members died together during a detected API outage: %s. "
                          "Do NOT resume yet - the same root cause as a correlated api-outage "
                          "stall (an Anthropic-side burst, not a tmux/host crash), so resuming "
                          "now risks immediate re-death. Once the outage clears, `%s` runs "
                          "automatically for these (pre-authorized auto-recovery, issue #23)."
                          % (len(outage_death_rows), names, resume_cmd))
            if any(remote_control_by_id.get(i, True) for i in outage_death_ids):
                synth_note += (" Some of these may also still show as connected in "
                                "Remote Control; disregard any such entry.")
            print("%s\t%s\t%s\t%s" % ("correlated:api-outage-death", "died", now(), synth_note))
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


def _default_outage_state():
    return {"state": "clear", "since": now(), "last_signal": None, "signal_count": 0}


def cmd_outage_update(args):
    """Advance the persisted fleet-wide outage-state machine by one poll
    (issue #23, item 0). Called every bin/watch-fleet iteration, but only from
    wingman's own top-level cycle (--owner "") - outage detection is
    fleet-wide, never per-lead-team.

    This poll's own signal count = --signal-working (members currently
    `working` whose pane tail matched the API-error signature THIS poll,
    counted by the caller) + however many of --died (a comma-separated list of
    ids wm-state reconcile just flipped to `died` THIS poll) carry
    death_cause == "api-outage" on the roster (looked up fresh here).

    clear -> active the moment that signal count is >= --mass-min-count AND
    >= --mass-min-ratio of the population that was live a moment before this
    poll (current live count for this owner + this poll's own died count,
    both causes) - the identical collapse condition cmd_group_attention
    applies to a batch, evaluated continuously here instead of only at fire
    time.

    active -> clear once --quiet-seconds elapse with a zero signal count on
    every intervening poll (tracked via `last_signal`, the timestamp of the
    most recent poll with a nonzero count).

    Every transition (never a same-state refresh) prints its own distinct
    token: "outage-detected", "outage-cleared", or "none". The caller
    (bin/watch-fleet) fires its own wake only on the two transition tokens,
    mirroring self_pane_check's fleet-scoped, non-per-id fire pattern."""
    ensure_home()
    owner = getattr(args, "owner", None) or ""
    died_ids = [d for d in (args.died or "").split(",") if d]

    roster = load_roster()
    death_cause_by_id = dict((r.get("id"), merged(r).get("death_cause")) for r in roster)
    outage_died = sum(1 for d in died_ids if death_cause_by_id.get(d) == "api-outage")

    current_live = 0
    for r in roster:
        if merged(r).get("status") not in LIVE_STATES:
            continue
        if parent_of(r) != owner:
            continue
        current_live += 1

    signal_count = args.signal_working + outage_died
    denominator = current_live + len(died_ids)

    state = read_json(outage_state_path(), None)
    if not isinstance(state, dict) or state.get("state") not in ("clear", "active"):
        state = _default_outage_state()

    stamp = now()
    transition = "none"
    if state["state"] == "clear":
        collapses = (signal_count >= args.mass_min_count and denominator > 0
                     and (signal_count / float(denominator)) >= args.mass_min_ratio)
        if collapses:
            state = {"state": "active", "since": stamp, "last_signal": stamp, "signal_count": signal_count}
            transition = "outage-detected"
        else:
            state["signal_count"] = signal_count
            if signal_count > 0:
                state["last_signal"] = stamp
    else:  # active
        if signal_count > 0:
            state["last_signal"] = stamp
            state["signal_count"] = signal_count
        else:
            last = _parse_updated(state.get("last_signal"))
            quiet_for = (
                (datetime.datetime.now(datetime.timezone.utc) - last).total_seconds()
                if last is not None else args.quiet_seconds + 1
            )
            if quiet_for >= args.quiet_seconds:
                state = {"state": "clear", "since": stamp, "last_signal": state.get("last_signal"), "signal_count": 0}
                transition = "outage-cleared"
            else:
                state["signal_count"] = 0

    write_json(outage_state_path(), state)
    print(transition)


def _default_usage_state():
    return {
        "state": "clear",
        "window": None,
        "used_percentage": None,
        "resets_at": None,
        "since": now(),
        "decided_at": None,
    }


def cmd_usage_update(args):
    """Advance the persisted fleet-wide usage-quota-approach state machine by
    one poll (issue #24). Called every bin/watch-fleet iteration, but only
    from wingman's own top-level cycle (--owner "") - the account's usage
    quota is fleet-wide, shared by every session under the same login, never
    per-lead-team.

    The caller (bin/watch-fleet) scans $WM_HOME/usage/<session-id>.json for
    each of the five_hour/seven_day windows, discards any reading whose
    captured_at is stale, and passes the max used_percentage (and its paired
    resets_at) per window still standing. Either window's pair of flags may
    be entirely absent this poll (no fresh file at all for it).

    States: clear -> approaching -> paused (wait) or acknowledged (continue)
    -> clear.

    clear -> approaching: the moment either window's used_percentage crosses
    --warn-threshold AND that window's resets_at is still in the future - a
    reading whose window has already reset describes a condition that no
    longer exists, no matter how fresh its captured_at looked to the caller.
    This state alone is what hooks/usage-limit-spawn-guard.sh reads to pause
    new spawns immediately - detection and pause are the same instant,
    before any pilot answer exists yet.

    approaching -> paused / approaching -> acknowledged: set by
    cmd_usage_decide, never by this function.

    approaching -> clear, paused -> clear, and acknowledged -> clear: all
    three are automatic, uniformly, the moment now() >= the resets_at of
    whichever window triggered the original crossing - checked FIRST, on
    EVERY call, regardless of which of the three non-clear states currently
    holds (this is more precise than the outage machine's quiet-seconds
    heuristic: there is an exact epoch to wait for). This is the fix for a
    slow pilot: if the reset epoch passes before the pilot ever answers the
    wait-vs-continue ask, the state clears on its own, spawns unpause, and
    the still-pending ask is moot (cmd_usage_decide reports as much if it is
    called anyway). Prints "usage-limit-reset" for the approaching->clear
    and paused->clear cases (a pause is being lifted, worth telling the
    pilot); the acknowledged->clear case resets the state silently (prints
    "none" - the fleet was never paused under "continue anyway", so there is
    nothing to announce) but still writes the state file.

    Every transition prints its own distinct token: "usage-limit-approaching",
    "usage-limit-reset", or "none". The caller fires its own wake only on the
    two transition tokens, mirroring cmd_outage_update's own pattern."""
    ensure_home()
    stamp = now()
    now_epoch = time.time()

    state = read_json(usage_state_path(), None)
    if not isinstance(state, dict) or state.get("state") not in (
        "clear", "approaching", "paused", "acknowledged",
    ):
        state = _default_usage_state()

    transition = "none"

    if state["state"] != "clear":
        resets_at = state.get("resets_at")
        if resets_at is not None and now_epoch >= resets_at:
            prev_state = state["state"]
            state = _default_usage_state()
            state["since"] = stamp
            if prev_state in ("approaching", "paused"):
                transition = "usage-limit-reset"
            write_json(usage_state_path(), state)
            print(transition)
            return

    if state["state"] == "clear":
        candidates = []
        if args.five_hour_pct is not None and args.five_hour_resets_at is not None:
            candidates.append(("five_hour", args.five_hour_pct, args.five_hour_resets_at))
        if args.seven_day_pct is not None and args.seven_day_resets_at is not None:
            candidates.append(("seven_day", args.seven_day_pct, args.seven_day_resets_at))
        crossing = [
            c for c in candidates
            if c[1] >= args.warn_threshold and c[2] > now_epoch
        ]
        if crossing:
            window, pct, resets_at = max(crossing, key=lambda c: c[1])
            state = {
                "state": "approaching",
                "window": window,
                "used_percentage": pct,
                "resets_at": resets_at,
                "since": stamp,
                "decided_at": None,
            }
            transition = "usage-limit-approaching"

    write_json(usage_state_path(), state)
    print(transition)


def cmd_usage_decide(args):
    """Record the pilot's wait-vs-continue decision on an approaching usage
    limit (issue #24), transitioning approaching -> paused (wait) or
    approaching -> acknowledged (continue), stamping decided_at.

    A decision recorded against any state OTHER than approaching - including
    clear (e.g. because the window auto-reset out from under a slow pilot
    answer, per cmd_usage_update's own uniform auto-clear) - is a no-op,
    defensively: the persisted state is left untouched and "no-op:<state>"
    is printed so the caller can tell the pilot the ask no longer applies."""
    ensure_home()
    state = read_json(usage_state_path(), None)
    if not isinstance(state, dict) or state.get("state") not in (
        "clear", "approaching", "paused", "acknowledged",
    ):
        state = _default_usage_state()

    if state["state"] != "approaching":
        print("no-op:%s" % state["state"])
        return

    new_state = "paused" if args.decision == "wait" else "acknowledged"
    state = dict(state)
    state["state"] = new_state
    state["decided_at"] = now()
    write_json(usage_state_path(), state)
    print(new_state)


def cmd_ack(args):
    """Record that the (id, announced) event has been surfaced to wingman, so
    needs-attention suppresses it until the crew's status changes (a new announced).

    Explicit and idempotent: the deliverer passes the exact tuple it surfaced, so
    the ack never races a state change between the read and the ack - a transition
    in that window produces a new `announced` that this ack does not cover, and it
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


# ---------------------------------------------------------------- preferences
# The per-run onboarding-preference store: a generic key/value cache of the
# pilot's answers to the required onboarding questions (`remote`,
# `artifact_linking`, `verbosity`, ... - the required set lives in
# hooks/lib/pilot-prefs.sh, not here). Each answer is asked once via
# AskUserQuestion and cached for every crew member and wingman itself to reuse
# for the rest of one wingman run - never per-deliverable, never per-crew-member
# (each crew member is an independent process with no shared memory of its own,
# so without this file every member would ask again).
#
# Invalidation is keyed to a wingman run, not a wall-clock TTL: wingman stamps a
# fresh WINGMAN_RUN_ID at its own startup and exports it to every crew member
# (alongside WINGMAN_HOME, in bin/spawn-crew's generated launch script). The
# store is a dict of run_id -> {key: value}, so multiple concurrently-alive
# wingman runs (e.g. a top-level session plus a lead's tree spawned by an
# earlier, since-restarted run) each keep their own cached answers without
# clobbering each other. A run_id with no entry means "not yet answered for
# this run" - the caller must ask again. Values are plain strings; the store
# is agnostic to what any given preference means.
def _load_prefs(run_id):
    """The prefs dict for run_id, or None if unanswered (missing entry, or the
    file/entry is malformed). Falls back to the pre-#85 legacy shape
    ({"wingman_run_id": ..., "prefs": {...}}) so a file not yet migrated by a
    pref-set call still answers correctly for the run id it names."""
    data = read_json(preferences_path(), None)
    if not isinstance(data, dict):
        return None
    if run_id in data:
        prefs = data.get(run_id)
        return prefs if isinstance(prefs, dict) else {}
    if data.get("wingman_run_id") == run_id and isinstance(data.get("prefs"), dict):
        return data["prefs"]
    return None


def cmd_pref_get(args):
    prefs = _load_prefs(args.run_id)
    if prefs is None or args.key not in prefs:
        sys.exit(1)  # unset for this run - the caller applies its own conservative default
    print(prefs[args.key])


def _coerced_slot(data, run_id):
    """The dict slot for run_id in data, replacing a corrupt (non-dict) entry
    with {} in place. Shared by the per-run set path and the legacy-migration
    path so both self-heal identically."""
    slot = data.get(run_id)
    if not isinstance(slot, dict):
        slot = {}
        data[run_id] = slot
    return slot


def cmd_pref_set(args):
    ensure_home()
    with with_locked(preferences_path()):
        data = read_json(preferences_path(), None)
        if not isinstance(data, dict):
            data = {}
        legacy_id = data.pop("wingman_run_id", None)
        legacy_prefs = data.pop("prefs", None)
        if isinstance(legacy_id, str) and isinstance(legacy_prefs, dict):
            _coerced_slot(data, legacy_id).update(legacy_prefs)
        _coerced_slot(data, args.run_id)[args.key] = args.value
        write_json(preferences_path(), data)


def cmd_prefs_list(args):
    """Every currently-set key<TAB>value pair for this run, one per line (nothing
    if unanswered). One call answers "are all N required preferences set" for the
    guard and nudge hooks - one subprocess, one file read, not N."""
    prefs = _load_prefs(args.run_id)
    if not prefs:
        return
    for key in sorted(prefs):
        print("%s\t%s" % (key, prefs[key]))


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


def _git_suffix(r):
    """Display-only annotation for is_git/has_remote - never feeds back into a
    member's own branch logic, which always re-detects for itself when the
    roster field is absent (global scope, or a pre-change record)."""
    is_git = r.get("is_git")
    if is_git is False:
        return " (no git)"
    if is_git is True and r.get("has_remote") is False:
        return " (git, no remote)"
    return ""


def _long_shell_warn_seconds():
    """WM_LONG_SHELL_WARN (seconds, default 1200 = 20 minutes) - the generous,
    configurable ceiling past which a single outstanding tool call/background
    shell earns a 'longer than usual' annotation (#155 fix 2). Purely a
    render-time threshold, read fresh on every render call so retuning it
    needs no watcher restart; it never gates a blocked/stalled flip."""
    try:
        return int(os.environ.get("WM_LONG_SHELL_WARN", "1200"))
    except ValueError:
        return 1200


def _human_duration(seconds):
    """'47s' / '22m' / '1h5m' - short, human-scale duration for the nudge and
    long-shell annotations."""
    seconds = max(0, int(seconds))
    if seconds < 60:
        return "%ds" % seconds
    minutes = seconds // 60
    if minutes < 60:
        return "%dm" % minutes
    hours, minutes = divmod(minutes, 60)
    return "%dh%dm" % (hours, minutes) if minutes else "%dh" % hours


def _stall_annotation(r):
    """Short parenthetical suffix for a 'working' member's status cell (#155):
    a self-heal nudge already sent and still within its cooldown window (fix
    1), and/or a single outstanding tool call/background shell that has been
    running far longer than usual (fix 2). Both are purely informational -
    they never change the status value itself - and both apply only while
    status is still 'working' (nudged_at/long_shell_* can briefly outlive that
    in the record, e.g. between a stalled flip and the next render, but a
    non-'working' status is never annotated). Returns "" when neither
    applies."""
    if r.get("status") != "working":
        return ""
    parts = []
    nudged_at = r.get("nudged_at")
    if nudged_at:
        parsed = _parse_updated(nudged_at)
        if parsed is not None:
            age = (datetime.datetime.now(datetime.timezone.utc) - parsed).total_seconds()
            if age >= 0:
                parts.append("self-heal nudge sent %s ago" % _human_duration(age))
    elapsed = r.get("long_shell_elapsed")
    if elapsed is not None and elapsed >= _long_shell_warn_seconds():
        parts.append("1 shell running %s, longer than usual" % _human_duration(elapsed))
    if not parts:
        return ""
    return " (%s)" % "; ".join(parts)


def render_roster_text(rows):
    if not rows:
        return "(no crew)"
    lines = []
    for r in rows:
        line = "  [%-10s] %-22s %-9s %s%s" % (
            r.get("type", "?"), r.get("id", "?"), r.get("status", "?") + _stall_annotation(r),
            (r.get("summary") or "").split("\n")[0][:60], _git_suffix(r),
        )
        lines.append(line)
        if r.get("status") == "blocked" and r.get("blocker"):
            lines.append("      blocker: %s" % r["blocker"])
        if r.get("delivery"):
            lines.append("      delivery: %s" % r["delivery"])
        if r.get("artifact_url"):
            lines.append("      artifact-url: %s" % r["artifact_url"])
        if r.get("allow_merge"):
            lines.append("      merge: AUTHORIZED for this effort (issue #46)")
        if r.get("review_gate_waived"):
            lines.append("      review gate: WAIVED for this effort (issue #132)")
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
            indent, r.get("type", "?"), r.get("id", "?"), r.get("status", "?") + _stall_annotation(r),
            (r.get("summary") or "").split("\n")[0][:50],
        )
        lines.append(line.rstrip())
        if r.get("status") == "blocked" and r.get("blocker"):
            lines.append("%s    blocker: %s" % (indent, r["blocker"]))
        if r.get("delivery"):
            lines.append("%s    delivery: %s" % (indent, r["delivery"]))
        if r.get("artifact_url"):
            lines.append("%s    artifact-url: %s" % (indent, r["artifact_url"]))
        if r.get("allow_merge"):
            lines.append("%s    merge: AUTHORIZED for this effort (issue #46)" % indent)
        if r.get("review_gate_waived"):
            lines.append("%s    review gate: WAIVED for this effort (issue #132)" % indent)
    return "\n".join(lines)


def render_board():
    rows = [merged(r) for r in load_roster()]
    active = [r for r in rows if r.get("status") in LIVE_STATES]
    done = [r for r in rows if r.get("status") not in LIVE_STATES]
    out = ["# Wingman crew board", "", "_Updated %s_" % now(), ""]
    out.append("## Active (%d)" % len(active))
    out.append("")
    if active:
        out.append("| type | id | status | window | repo | summary | blocker | delivery | artifact-url |")
        out.append("|---|---|---|---|---|---|---|---|---|")
        # Depth-first so each report sits under its owner, its id indented by depth,
        # letting a human read the org rather than a flat list.
        for r, depth in order_tree(active):
            marker = ("&nbsp;&nbsp;" * depth) + ("↳ " if depth else "")
            id_cell = r.get("id", "") + (" (merge-authorized)" if r.get("allow_merge") else "") + (" (review-waived)" if r.get("review_gate_waived") else "")
            repo_cell = (
                os.path.basename(r.get("repo", "") or "")
                + (" (global)" if r.get("scope") == "global" else "")
                + _git_suffix(r)
            )
            out.append("| %s | %s%s | %s | %s | %s | %s | %s | %s | %s |" % (
                r.get("type", ""), marker, id_cell, r.get("status", "") + _stall_annotation(r),
                r.get("window", ""), repo_cell,
                _cell(r.get("summary")), _cell(r.get("blocker")), _cell(r.get("delivery")),
                _cell(r.get("artifact_url")),
            ))
    else:
        out.append("_(none)_")
    out.append("")
    out.append("## Closed (%d)" % len(done))
    out.append("")
    if done:
        out.append("| type | id | status | delivery | artifact-url |")
        out.append("|---|---|---|---|---|")
        for r in done:
            out.append("| %s | %s | %s | %s | %s |" % (
                r.get("type", ""), r.get("id", ""), r.get("status", ""), _cell(r.get("delivery")),
                _cell(r.get("artifact_url")),
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
    # Explicit, per-effort merge authorization (issue #46): unset by default. Set
    # only via bin/spawn-crew --allow-merge at spawn time, or later via crew-set
    # --allow-merge (itself gated by hooks/no-merge-guard.sh so a crew member can
    # never grant this to itself). hooks/no-merge-guard.sh reads it fresh off this
    # roster record on every merge attempt, so a mid-session grant takes effect
    # without needing to respawn the member.
    a.add_argument("--allow-merge", action="store_true", dest="allow_merge")
    # Explicit, per-effort escape hatch from the review-evidence gate (issue #132):
    # unset by default. Set only via bin/spawn-crew --waive-review-gate at spawn
    # time, or later via crew-set --review-gate-waived (itself gated by
    # hooks/no-merge-guard.sh so a crew member can never grant this to itself).
    # Mirrors --allow-merge's shape exactly - see hooks/no-merge-guard.sh for how
    # the two combine.
    a.add_argument("--waive-review-gate", action="store_true", dest="review_gate_waived")
    # Remote-Control-visible at spawn (issue #96): mirrors bin/spawn-crew's own
    # --remote-control "wm-<id>" launch flag, gated on the same $REMOTE_CONTROL
    # variable. Drives both this record's own remote_control field and the
    # initial remote_control_connected value (see cmd_crew_add below).
    a.add_argument("--remote-control", action="store_true", dest="remote_control")
    # The tmux window id (@N) of the member's window, recorded at spawn so
    # stray-window adoption can match the exact window rather than a name.
    # Empty when the spawner could not capture it. Note: window ids restart
    # when the tmux server does, so this is an optional precision key, never
    # the primary identity (the window name is).
    a.add_argument("--window-id", default="", dest="window_id")
    # Git/PR-workflow determinant (repo scope only; bin/spawn-crew never passes
    # these for --scope global, leaving the roster field None/absent - "unknown,
    # detect yourself" rather than a false that would be wrong the instant the
    # member cds into a real repo). String-shaped only because a command-line
    # flag is typed as a string; cmd_crew_add converts to a real bool/None.
    a.add_argument("--is-git", default=None, choices=("true", "false"), dest="is_git")
    a.add_argument("--has-remote", default=None, choices=("true", "false"), dest="has_remote")
    # A random 32-byte hex token (bin/spawn-crew generates it), reviewer type
    # only (issue #135): derives the spawn-time per-verdict hash commitments
    # (see _apply_review_token) - the raw value itself is never stored, only
    # its derived hashes. Omitted (or on a non-reviewer type) leaves both
    # commitment fields None, the backward-compatible "no token on file"
    # case hooks/no-merge-guard.sh's shape-2 check falls through on.
    a.add_argument("--review-token", default=None, dest="review_token")
    a.set_defaults(fn=cmd_crew_add)

    a = sub.add_parser("crew-set")
    a.add_argument("--id", required=True)
    a.add_argument("--status")
    a.add_argument("--summary")
    a.add_argument("--blocker")
    a.add_argument("--artifact")
    # Explicit override for the auto-derived artifact_url (see _artifact_marker_url):
    # if passed, it wins outright over auto-detection, including "" to clear a stale
    # value. Left unset (None, not passed at all) is what lets auto-detection run.
    a.add_argument("--artifact-url", dest="artifact_url")
    a.add_argument("--delivery")
    # Self-register the worktree path after spawn (global scope, whose repo/path is
    # not knowable at spawn time). Roster-only field, not a live-status field.
    a.add_argument("--worktree", default=None)
    # Grant (or revoke) merge autonomy for this member's effort - roster-only
    # field, see crew-add's --allow-merge above. Never provided by the member on
    # its own --id; hooks/no-merge-guard.sh enforces that boundary.
    a.add_argument("--allow-merge", default=None, choices=("true", "false"), dest="allow_merge")
    # Grant (or revoke) the review-evidence-gate waiver for this member's effort -
    # roster-only field, see crew-add's --waive-review-gate above. Never provided
    # by the member on its own --id; hooks/no-merge-guard.sh enforces that
    # boundary identically to --allow-merge.
    a.add_argument("--review-gate-waived", default=None, choices=("true", "false"), dest="review_gate_waived")
    # Roster-only, single-field write (issue #96): bin/watch-fleet's own
    # regular, stability-gated poll is the only writer of this field - never a
    # crew member itself, and never bin/crew-standdown, which only reads it.
    # Mirrors --worktree's narrow self-registration shape exactly: touches only
    # this field plus `updated`, untouched by status/announced/dedup logic.
    a.add_argument("--remote-control-connected", default=None, choices=("true", "false"), dest="remote_control_connected")
    # Re-register the window id after crew-resume replaces the window. Roster-only.
    a.add_argument("--window-id", default=None, dest="window_id")
    # Roster-only, explicit-token write (issue #135): bin/crew-resume's own
    # relaunch of a died `reviewer` passes a freshly generated token here so
    # the resumed session's stale, pre-crash commitments are replaced before
    # it can post another comment-fallback verdict. Gated identically to
    # --allow-merge/--review-gate-waived (see
    # hooks/no-merge-guard.sh:check_regenerate_review_token_grant) - never
    # settable by a crew session on itself. Never echoed back to the caller
    # (bin/crew-resume redirects this call's stdout) - unlike the automatic
    # delivery-change regeneration below, which DOES print the new token
    # since nothing else in that path already holds it.
    a.add_argument("--regenerate-review-token", default=None, dest="regenerate_review_token")
    # Update status/summary/artifact/delivery without re-firing the watcher/Stop-
    # hook wake (see the `announced` field and playbooks/_status-contract.md,
    # "Re-entering review without re-announcing"). Refused with --status
    # blocked/done, which must always announce.
    a.add_argument("--silent", action="store_true")
    a.set_defaults(fn=cmd_crew_set)

    a = sub.add_parser("crew-get")
    a.add_argument("--id", required=True)
    a.set_defaults(fn=cmd_crew_get)

    # review-sign (issue #135): produces the preimage for a reviewer's own
    # review-token commitment, to embed in a comment-fallback PR verdict (see
    # playbooks/software-development/reviewer.md step 4). Unrestricted - see
    # cmd_review_sign's own docstring for why.
    a = sub.add_parser("review-sign")
    a.add_argument("--verdict", required=True, choices=("approve", "request changes"))
    # Optional override for the rare case a live reviewer's cached
    # $WM_REVIEW_TOKEN went stale mid-session (its own delivery-change
    # triggered regeneration) - see _apply_review_token's callers.
    a.add_argument("--token", default=None)
    # issue #138: the PR's current head commit SHA at post time. Only takes
    # effect for --verdict approve (see cmd_review_sign); omitted entirely,
    # this reproduces today's exact pre-#138 behavior byte for byte.
    a.add_argument("--commit", default=None)
    a.set_defaults(fn=cmd_review_sign)

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
    # API-error pane signature (issue #23) checked against a dying member's
    # cached pane tail to attribute death_cause. bin/watch-fleet always passes
    # its own $WM_APIERR_RE explicitly; the argparse default here (matching
    # that same regex) only covers a direct/test invocation that omits it.
    a.add_argument("--apierr-re", default=DEFAULT_APIERR_RE, dest="apierr_re")
    # Orphan-window adoption grace period in seconds (issue #79): a wm-*
    # window unmatched to any roster record for longer than this is adopted as
    # a blocked orphan (owner == "" only). Default 15s = 3x watch-fleet's own
    # 5s default poll interval, comfortably clearing crew-add's typical
    # sub-second latency and spawn-crew's WM_SPAWN_DELAY default of 2s.
    a.add_argument("--grace-seconds", type=int, default=15, dest="grace_seconds")
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
    # Age in seconds of the watcher's per-id check-in nudge marker, or -1 if no
    # marker exists yet (#61). Required to be >= 0 and >= --threshold before a
    # genuine stall is allowed to flip - see cmd_stall_check's docstring.
    a.add_argument("--nudge-age", type=int, default=-1, dest="nudge_age")
    # #155 fix 1: 1 iff bin/watch-fleet's check-in nudge was just sent to this
    # candidate THIS poll - stamps nudged_at (see cmd_stall_check) so a
    # render step can annotate a still-'working' member as mid-self-heal.
    # Rides this same per-poll call rather than a second subprocess spawned
    # just to persist a timestamp (that extra uv/python startup per nudged
    # member per poll was enough to visibly skew the tight multi-member
    # timing the outage-detection tests depend on).
    a.add_argument("--just-nudged", type=int, default=0, dest="just_nudged")
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

    # The persisted fleet-wide outage-state machine (issue #23, item 0).
    # Called every bin/watch-fleet iteration from wingman's own top-level
    # cycle only (--owner "").
    a = sub.add_parser("outage-update")
    a.add_argument("--owner", default="")
    a.add_argument("--signal-working", type=int, default=0, dest="signal_working")
    a.add_argument("--died", default="")
    a.add_argument("--mass-min-count", type=int, default=2, dest="mass_min_count")
    a.add_argument("--mass-min-ratio", type=float, default=0.5, dest="mass_min_ratio")
    a.add_argument("--quiet-seconds", type=int, default=15, dest="quiet_seconds")
    a.set_defaults(fn=cmd_outage_update)

    # The persisted fleet-wide usage-quota-approach state machine (issue #24).
    # Called every bin/watch-fleet iteration from wingman's own top-level
    # cycle only (--owner "" - the account's usage quota is shared fleet-
    # wide, never per-lead-team). --owner is accepted for shape-parity with
    # outage-update's own call signature but is not otherwise used here.
    a = sub.add_parser("usage-update")
    a.add_argument("--owner", default="")
    a.add_argument("--five-hour-pct", type=float, default=None, dest="five_hour_pct")
    a.add_argument("--five-hour-resets-at", type=float, default=None, dest="five_hour_resets_at")
    a.add_argument("--seven-day-pct", type=float, default=None, dest="seven_day_pct")
    a.add_argument("--seven-day-resets-at", type=float, default=None, dest="seven_day_resets_at")
    a.add_argument("--warn-threshold", type=float, default=80.0, dest="warn_threshold")
    a.set_defaults(fn=cmd_usage_update)

    a = sub.add_parser("usage-decide")
    a.add_argument("--decision", required=True, choices=("wait", "continue"))
    a.set_defaults(fn=cmd_usage_decide)

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

    a = sub.add_parser("pref-get")
    a.add_argument("--run-id", required=True, dest="run_id")
    a.add_argument("--key", required=True)
    a.set_defaults(fn=cmd_pref_get)

    a = sub.add_parser("pref-set")
    a.add_argument("--run-id", required=True, dest="run_id")
    a.add_argument("--key", required=True)
    a.add_argument("--value", required=True)
    a.set_defaults(fn=cmd_pref_set)

    a = sub.add_parser("prefs-list")
    a.add_argument("--run-id", required=True, dest="run_id")
    a.set_defaults(fn=cmd_prefs_list)

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
