#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
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
                    reused for the rest of its run. Read through the settings
                    file's persistent `[prefs]` layer underneath it (see
                    _pref_layers) - cmd_pref_get/cmd_pref_set/cmd_prefs_list
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
crew/<id>.json overlaid on top (status/summary/blocker/parked/artifact/
artifact_url/delivery/updated).
crew.json is the roster of record; crew/<id>.json is the live signal. Wingman
reads the merge; it never ingests panes or transcripts - the one exception is
is_resumable() below, which checks a died member's transcript for existence
only, never content (issue #251).

All JSON is handled here in Python so the shell scripts stay bash-3.2-safe and the
tool works whether or not jq is installed.
"""
import argparse
import contextlib
import datetime
import glob
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

# wingman's settings file reader, for the [prefs] layer under the per-run
# preference store (see _config_prefs). This script's own directory is added to
# sys.path rather than relied on already being there: `uv run --no-project` does
# put it first, but the hooks that invoke this file set their own PYTHONPATH, so
# saying it explicitly makes the import independent of both. APPENDED, not
# inserted at 0 - a sibling helper here must never be able to shadow a stdlib
# module for this script. A missing module leaves the settings layer simply
# absent; it must never stop the state engine from running.
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
try:
    import wm_config
except ImportError:
    wm_config = None

STATUS_FIELDS = ("status", "summary", "blocker", "artifact", "artifact_url", "delivery", "updated", "announced")
# Display-only live-status fields (#155): never part of a member's own reported
# status surface (STATUS_FIELDS above), never iterated generically by
# cmd_crew_set, and carrying no gating weight anywhere - purely annotations a
# render step (merged/render_roster_text/render_tree_text/render_board) may
# show alongside a 'working' status - with one exception: parked (#203) feeds
# the auto-composed blocker text on a --status blocked transition (see
# cmd_crew_set), but is otherwise display-only like the rest of this tuple,
# never itself gating announced/dedup. nudged_at (fix 1) is written by
# cmd_stall_check's --just-nudged (riding the same per-poll call bin/watch-
# fleet already makes for every candidate, rather than a second subprocess
# spawned just to persist a timestamp) and cleared by cmd_crew_set on the
# member's next self-report, or by cmd_stall_check itself on a genuine stall
# flip.
# long_shell_pid/long_shell_elapsed (fix 2) are written by wm_state
# wedge-check's per-poll duration probe (relocated from cmd_stall_check by
# issue #202, which also widened it to 'blocked' members), independent of
# every gate.
# parked (#203) is a list of {"ref", "note", "since"} annotations - a unit of
# work needing a decision, independent of this record's own status.
# stall (issue #235) is the provenance object _impose_stall writes on every
# 'stalled' flip - {"source", "since", "prev_status", "prev_summary",
# "prev_blocker", ...} - so cmd_stall_recheck can later re-run the imposing
# detector's own evidence and, on a sustained contradiction, revert the
# record losslessly. Listed here so merged() carries it to the render layer
# (_stalled_annotation reads it off a merged row) - but that is DISPLAY only:
# cmd_stall_recheck itself never reads it through merged(), always via a
# direct read_json(status_path(cid)) of the live status file, so the "no
# gating weight" contract above still holds through this tuple - the gating
# happens entirely inside cmd_stall_recheck's own direct read/write, not
# through this overlay. cmd_crew_set pops it on the member's own next
# self-report, exactly like nudged_at.
DISPLAY_ONLY_LIVE_FIELDS = ("nudged_at", "long_shell_pid", "long_shell_elapsed", "parked", "stall")
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


def claude_projects_dir():
    """Root of Claude Code's OWN per-project transcript store - a different
    tree than $WINGMAN_HOME entirely. Honors $CLAUDE_CONFIG_DIR (confirmed
    against the shipped CLI: `join(env.CLAUDE_CONFIG_DIR ?? join(homedir(),
    ".claude"), "projects")` - review round 1, MF-3) the same way the CLI
    itself does, so a machine that relocates its Claude Code home is not
    silently read against the wrong (default) one. Override for tests via
    $WM_CLAUDE_PROJECTS_DIR, the same per-test isolation convention
    $WM_CLAUDE_USER_SETTINGS already uses for ~/.claude/settings.json - this
    one wins outright, even over $CLAUDE_CONFIG_DIR, so a test's isolation
    can never be defeated by a stray CLAUDE_CONFIG_DIR in its environment."""
    if os.environ.get("WM_CLAUDE_PROJECTS_DIR"):
        return os.environ["WM_CLAUDE_PROJECTS_DIR"]
    claude_home = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    return os.path.join(claude_home, "projects")


def _claude_project_slug(path):
    """Mirror the Claude Code CLI's own project-directory naming for a cwd:
    the REAL (symlink-resolved) path with every character that is not
    alphanumeric or '-' replaced by '-' (confirmed against this machine's own
    ~/.claude/projects entries - e.g. /home/greer/.treehouse/x ->
    -home-greer--treehouse-x, the dot becoming a second dash alongside the
    slash). realpath, not abspath (review round 1, MF-3): the CLI derives its
    project directory from the process's own cwd, and getcwd(3) - what both
    Node's process.cwd() and Python's os.getcwd() report - resolves symlinks,
    which abspath does not; a `repo` that reaches its checkout through a
    symlink would otherwise slug to a directory that never exists."""
    return re.sub(r"[^A-Za-z0-9-]", "-", os.path.realpath(path))


def crew_transcript_path(record):
    """The DERIVED path to a crew record's Claude Code session transcript -
    i.e. the one candidate wm-state can compute directly from (repo,
    session_id), without touching the filesystem beyond the one exact-path
    check is_resumable() makes. Not the sole source of truth: is_resumable()
    also falls back to a glob scan when this exact path misses (review round
    1, MF-3 - the CLI truncates+hashes a slug past 200 chars, which this
    function has no equivalent for). Returns None when either input is
    missing (a pre-session-id record, or one with no repo - review round 1,
    MF-2's orphan-adoption case)."""
    repo = record.get("repo")
    session_id = record.get("session_id")
    if not repo or not session_id:
        return None
    return os.path.join(claude_projects_dir(), _claude_project_slug(repo), session_id + ".jsonl")


def is_resumable(record):
    """True iff record's Claude Code session transcript still exists on disk -
    the resumability signal for a `died` member (issue #251): crew.json
    already stores session_id, and the transcript survives independent of
    the worktree, so `claude --resume <session_id>` recovers it regardless of
    whether the worktree is still around. Shared by crew-list/crew-tree
    rendering, crew-get's JSON (consumed by bin/crew-takeover), and the
    death-flip notification text.

    Two checks, in order (review round 1, MF-3): the exact derived path
    first (cheap, no directory scan), then - only on a miss, and only when a
    session_id is present at all - a glob for `<projects>/*/<session_id>.jsonl`.
    Session ids are UUIDs, so a match is unambiguous. The fallback exists
    because the derivation above has known blind spots even after the
    realpath/CLAUDE_CONFIG_DIR fixes above: the CLI's own 200-char slug
    truncation+hash has no equivalent here, and any future change to the
    CLI's own naming scheme would otherwise silently read as "not
    resumable" - which, per this same review round, is exactly the failure
    mode issue #251 itself was filed over. A `bin/crew-takeover` degraded
    branch never trusts a bare `False` from this function alone to withhold
    the resume command outright - see its own comment for why."""
    session_id = record.get("session_id")
    if not session_id:
        return False
    path = crew_transcript_path(record)
    if path and os.path.isfile(path):
        return True
    return bool(glob.glob(os.path.join(glob.escape(claude_projects_dir()), "*", session_id + ".jsonl")))


def _clear_stall_nudge_sidecars(cid):
    """Delete bin/watch-fleet's stall-<id>.nudged and stall-<id>.nudge-refused
    sidecars for cid, if present (issue #214, §3.6 step 5). Both are
    $WM_HOME files the watcher alone creates and reads (never through
    wm_state) to track one stall episode's check-in nudge; nothing ever
    unlinked either before this, so a counter or marker from a resolved
    episode survived into the next one, misleading a later flip's reason
    text. Called at the two points an episode is known to be over: here
    (a member self-reported - cmd_crew_set) and by cmd_stall_check on a
    genuine flip - attached to the event rather than to a watcher poll,
    since a poll-keyed clear would silently not happen while no watcher is
    running, which is exactly when a stale counter would survive."""
    sid = _sanitize_id(cid)
    for _suffix in (".nudged", ".nudge-refused"):
        try:
            os.unlink(os.path.join(home(), "stall-%s%s" % (sid, _suffix)))
        except OSError:
            pass


def review_resurfaced_path():
    return os.path.join(home(), "review-resurfaced.json")


def forward_motion_path():
    return os.path.join(home(), "forward-motion.json")


def wedge_anchor_path():
    return os.path.join(home(), "wedge-anchor.json")


def pr_watch_beat_path(cid):
    return os.path.join(home(), "pr-watch-%s.beat" % _sanitize_id(cid))


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


def _active_reports(cid):
    """cid's direct reports currently live (merged status in LIVE_STATES) -
    the same population cmd_forward_motion_check selects for its own
    candidacy test (see its `children` filter) and cmd_stall_recheck's
    forward-motion clearing predicate re-reads to test whether any of them
    has since moved (issue #235). The single shared read both now use, so the
    'active report' definition can no longer drift between call sites the way
    _active_report_count's own docstring used to flag as a live risk.

    Today only a `lead` ever has reports at all (the depth cap in
    playbooks/common/lead.md forbids spawning managers), so this is the
    type-free way to ask 'is this a manager with work in flight' - and it stays
    correct if that cap is ever relaxed."""
    out = []
    for r in load_roster():
        if parent_of(r) != cid:
            continue
        m = merged(r)
        if m.get("status") in LIVE_STATES:
            out.append(m)
    return out


def _active_report_count(cid):
    """How many of cid's direct reports are currently live. See
    _active_reports."""
    return len(_active_reports(cid))


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


def type_base(type_name):
    """The bare role name of a (possibly category-namespaced) crew type.

    A crew type may be registered under a category directory and referenced as
    `<category>/<role>` (e.g. `software-development/reviewer` for
    playbooks/software-development/reviewer.md). Everything that keys off a
    role by name - the review-token machinery here, the merge-evidence gate in
    hooks/no-merge-guard.sh - must match the base name, not the full namespaced
    string (issue #166), so a namespaced reviewer's verdict counts as evidence
    exactly like a bare `reviewer`'s. Returns the part after the last `/`, or
    the whole string when there is no `/`.
    """
    return (type_name or "").rsplit("/", 1)[-1]


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
    if type_base(args.type) == "reviewer" and getattr(args, "review_token", None):
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
    # #155 review fix: the read-modify-write below is now shared with
    # cmd_stall_check's own side-effect write (--just-nudged) and wm_state
    # wedge-check's long-shell tracker (relocated from cmd_stall_check by
    # issue #202) onto this SAME file from a different process (the
    # watcher) - a
    # write_json is a full-file replace, not a merge, so two unlocked writers
    # can silently clobber each other (a self-report landing between this
    # function's read and write would be reverted by whichever wrote last).
    # with_locked(status_path(...)) - the identical pattern crew_json_path()
    # already uses below for the roster - serializes this against every other
    # writer of this file; the read happens INSIDE the lock so prev_status/
    # prev_pointer/the nudged_at check below all see the freshest possible
    # on-disk state, not a snapshot that might already be stale by the time
    # the lock is acquired.
    status_file = status_path(args.id)
    with with_locked(status_file):
        live = read_json(status_file, {"id": args.id})
        live["id"] = args.id
        prev_status = live.get("status")
        prev_pointer = (live.get("artifact"), live.get("blocker"), live.get("delivery"))
        for field in STATUS_FIELDS[:-2]:  # everything but 'updated' and 'announced'
            val = getattr(args, field, None)
            if val is not None:
                live[field] = None if val == "" and field in ("blocker", "artifact", "artifact_url", "delivery") else val
        # parked (#203) - independent of STATUS_FIELDS/announced, so this runs
        # regardless of what --status was passed this call. A role owning several
        # independent units of work (a lead) uses this to record "this one unit
        # needs a decision" without flipping its own status to blocked.
        if args.parked_clear:
            live["parked"] = []
        if args.unpark:
            remove = set(args.unpark)
            live["parked"] = [p for p in live.get("parked") or [] if p.get("ref") not in remove]
        if args.park:
            by_ref = dict((p.get("ref"), p) for p in live.get("parked") or [])
            for item in args.park:
                if ":" not in item:
                    sys.exit("wm-state: --park expects 'ref:note' (ref may not itself "
                              "contain a colon), got %r" % item)
                ref, note = item.split(":", 1)
                ref, note = ref.strip(), note.strip()
                if not note:
                    sys.exit("wm-state: --park %r has an empty note" % item)
                by_ref[ref] = {
                    "ref": ref,
                    "note": note,
                    # preserve the original park time across a re-park that only updates the note
                    "since": (by_ref.get(ref) or {}).get("since") or now(),
                }
            live["parked"] = list(by_ref.values())
        # Compose `blocker` deterministically from (lead-in, current parked list) on
        # every touch while status is blocked, so re-deriving the same inputs always
        # yields byte-identical output (#203). blocker_note/blocker_composed are
        # composition inputs only - deliberately not in DISPLAY_ONLY_LIVE_FIELDS, so
        # merged()/crew-get/crew-list never surface them; the visible `blocker` field
        # already carries their effect. See docs/plans/2026-08-03-issue-203-per-issue-
        # blocking-plan.md for why a naive "compose into blocker and read it back"
        # approach is non-idempotent and leaks stale parked items across escalations.
        if args.blocker is not None:
            live["blocker_note"] = args.blocker or None
        if live.get("status") == "blocked":
            parked_items = live.get("parked") or []
            lead_in = live.get("blocker_note")
            if parked_items:
                rendered = "; ".join(
                    "[%s] %s" % (p.get("ref", "?"), p.get("note", "")) for p in parked_items
                )
                live["blocker"] = (
                    "%s | parked: %s" % (lead_in, rendered) if lead_in else "parked: %s" % rendered
                )
                live["blocker_composed"] = True
            else:
                live["blocker"] = lead_in
                live.pop("blocker_composed", None)
        else:
            live.pop("blocker_note", None)
            if live.pop("blocker_composed", None) and args.blocker is None:
                live["blocker"] = None
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
            # The member self-reported, so any stall episode in progress is
            # over - drop its provenance object too (issue #235), or a later
            # render would annotate a status that is no longer 'stalled', and
            # clear the watcher's own stall-<id>.nudged/.nudge-refused
            # sidecars (issue #214, §3.6 step 5), or a later episode would
            # inherit a stale refused-nudge count and flip claiming a nudge
            # attempt that never happened.
            live.pop("stall", None)
            _clear_stall_nudge_sidecars(args.id)
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
        write_json(status_file, live)

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
                if args.delivery is not None and type_base(r.get("type")) == "reviewer" \
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
                # Roster-only (issue #251): a successful resume clears the WIP-anchor
                # pointer/error from the death it just recovered from.
                if getattr(args, "clear_wip_anchor", False):
                    r.pop("wip_ref_sha", None)
                    r.pop("wip_anchor_error", None)
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
            m = merged(r)
            # Computed, not persisted: freshest at read time, and meaningful only
            # for a died member (bin/crew-takeover's own consumer of this field).
            if m.get("status") == "died":
                m["resumable"] = is_resumable(m)
            print(json.dumps(m, indent=2, sort_keys=True))
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
    elif args.parked:
        # --parked is status-independent by design (#203) - a record can be
        # working or blocked and still carry parked items - so it does not
        # compose with --status/--active in the same call. The explicit
        # != "stood-down" guard is required: this elif bypasses the default
        # branch's own "elif not args.all" clause below, which is the only
        # thing that otherwise drops stood-down records from the live roster
        # view, and cmd_crew_standdown leaves `parked` untouched when it flips
        # status to stood-down.
        rows = [r for r in rows if r.get("parked") and r.get("status") != "stood-down"]
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


# Wall-clock ceiling for each git subprocess _anchor_died_worktree runs
# (review round 1, nice-to-have 1): this executes inline under cmd_reconcile's
# global roster flock, so a git call that hangs (a network filesystem, lock
# contention with something else touching the same worktree) would otherwise
# block every other wm-state caller fleet-wide - and a correlated mass death
# multiplies that by N. 30s is generous for a purely local git operation
# regardless of worktree size (no network I/O, no object transfer); a hang
# past that is itself surfaced as the anchor's own failure reason (MF-4)
# rather than silently propagating as a wedged reconcile call.
_WIP_ANCHOR_TIMEOUT = 30


def _anchor_died_worktree(record_id, worktree):
    """update-ref refs/wip/<id> to a snapshot commit of a died member's dirty
    worktree (issue #251, generalizing the by-hand salvage done for issue #198
    during the 2026-08-04 fleet-loss incident: refs/wip/issue-198-fleet-loss-
    salvage - see review round 1 for why that precedent does not actually
    establish "untracked files are fine to drop": 3b6c694 has none only
    because they happened to already be staged).

    Returns (sha, None) on a successful anchor, (None, None) when there was
    genuinely nothing to anchor (no worktree, not a git checkout, or a
    confirmed-clean tree), and (None, "<reason>") when an anchor was
    ATTEMPTED and failed - review round 1, MF-4: the two None cases used to
    be indistinguishable, which silently hid the single likeliest real-world
    failure (a stale .git/index.lock left by the very crash this function
    exists to survive) behind the exact same signal as "nothing was dirty".
    The caller (cmd_reconcile) records the reason on the roster so
    bin/crew-takeover can surface it instead of reading as a clean death.

    Captures the WHOLE dirty state, tracked and untracked alike (review round
    1, MF-1): `git stash create` - this function's first implementation -
    silently drops any file never `git add`ed, with no `-u` equivalent, which
    made the notification text's own claim of "your uncommitted work was
    anchored" false for exactly the files an agent killed mid-task is most
    likely to still be holding (a new module, a new test, not yet staged).
    Built through a SCRATCH index instead of the real one - GIT_INDEX_FILE
    points every index-touching command below at a throwaway file for this
    call only - so the zero-disruption property still holds exactly as
    before: neither the working tree, the real index, nor HEAD is ever
    touched. `git add -A` still respects .gitignore, matching ordinary `git
    add -A` behavior (an ignored build artifact is not "uncommitted work").

    A tree that comes back identical to HEAD's own tree (nothing staged in
    the scratch index differs from a clean checkout, tracked or untracked) is
    the genuine "nothing to anchor" case - no ref is created or moved for it,
    so a member that dies clean twice in a row does not spuriously overwrite
    an otherwise-meaningful ref with a no-op commit.

    `refs/wip/` sits outside `refs/heads/`, so it is invisible to branch
    listings and never pollutes commit history; overwriting the ref on a
    repeat, genuinely-dirty death (a resumed-then-died-again member) is fine
    - it is always meant to reflect the LATEST anchored state, not a history
    of every death.

    Every git call is subprocess-timeout-bounded (see _WIP_ANCHOR_TIMEOUT);
    this runs inline in the death-flip path under the roster lock and must
    never itself hang or fail a reconcile call - any exception (a timeout, a
    stale index.lock, git not on PATH) is caught and reported as a failure
    reason, never raised."""
    if not worktree or not os.path.isdir(worktree):
        return None, None
    tmp_index = None
    try:
        fd, tmp_index = tempfile.mkstemp(prefix="wm-wip-index-")
        os.close(fd)
        os.remove(tmp_index)  # git read-tree creates it fresh; a pre-existing empty file is not a valid index
        env = dict(os.environ, GIT_INDEX_FILE=tmp_index)
        _run = lambda args, **kw: subprocess.run(  # noqa: E731
            args, cwd=worktree, env=env, timeout=_WIP_ANCHOR_TIMEOUT,
            check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            universal_newlines=True, **kw)
        head_tree = subprocess.run(
            ["git", "rev-parse", "--verify", "HEAD^{tree}"],
            cwd=worktree, timeout=_WIP_ANCHOR_TIMEOUT, check=True,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True,
        ).stdout.strip()
        _run(["git", "read-tree", "HEAD"])
        _run(["git", "add", "-A", "."])
        new_tree = _run(["git", "write-tree"]).stdout.strip()
        if new_tree == head_tree:
            return None, None  # genuinely clean: tracked and untracked alike
        sha = subprocess.run(
            ["git", "commit-tree", new_tree, "-p", "HEAD", "-m", "wip anchor: %s" % record_id],
            cwd=worktree, timeout=_WIP_ANCHOR_TIMEOUT, check=True,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True,
        ).stdout.strip()
        subprocess.run(
            ["git", "update-ref", "refs/wip/%s" % _sanitize_id(record_id), sha],
            cwd=worktree, timeout=_WIP_ANCHOR_TIMEOUT, check=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        return sha, None
    except Exception as e:
        return None, str(e) or e.__class__.__name__
    finally:
        if tmp_index:
            try:
                os.remove(tmp_index)
            except OSError:
                pass


def cmd_reconcile(args):
    """Mark live-but-windowless crew as 'died'. Given the current tmux windows,
    any crew member still in a live state whose window is gone is flagged.

    Cause attribution (issue #23): each flip also checks the member's cached
    pane-tail file (pane_tail_path, written every poll by bin/watch-fleet for
    a live working/blocked member) against --apierr-re; a match tags
    death_cause="api-outage" on the roster record, otherwise death_cause stays
    unset - see cmd_group_attention for how this feeds the correlated-batch
    split and cmd_outage_update for the fleet-wide signal it feeds.

    Uncommitted-work anchor (issue #251): each flip also attempts
    _anchor_died_worktree against the record's own `worktree` - a dirty
    worktree gets snapshotted and pointed at by refs/wip/<id> before the flip
    is written, so a died member's uncommitted work (tracked, staged, AND
    untracked - review round 1, MF-1) is never one `rm -rf`/disk-cleanup pass
    from gone (see that function's own docstring). Unconditional (not
    owner-scoped): whichever caller's reconcile call happens to observe the
    death first performs the anchor, exactly like the death flip itself. A
    failed anchor attempt (as opposed to nothing to anchor) is recorded on
    the roster as `wip_anchor_error` (review round 1, MF-4) rather than
    silently reading identically to a clean tree.

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
                wip_sha, wip_error = _anchor_died_worktree(r["id"], r.get("worktree"))
                if wip_sha:
                    r["wip_ref_sha"] = wip_sha
                    r.pop("wip_anchor_error", None)
                elif wip_error:
                    # A genuine attempt failed (review round 1, MF-4) - never
                    # overwrite a still-valid PRIOR wip_ref_sha with this
                    # failure; the earlier anchor is still real and reachable.
                    r["wip_anchor_error"] = wip_error
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
    """{pid: (cputime_secs, elapsed_secs, args)} for root_pid and its
    descendants, from one `ps -ax -ww -o pid=,ppid=,time=,etime=,args=` pass.
    `args` (the full command line) is last so the existing whitespace-split
    parse of the first four whitespace-separated fields stays correct via a
    bounded `split(None, 4)` - added for wm_state wedge-check (issue #202),
    which needs the command line to recognize a watch-fleet/pr-watch
    descendant; every other caller (_probe_execution,
    _longest_running_descendant) ignores the third element. `-ww` (doubled,
    both GNU/Linux and BSD/macOS `ps` accept it identically) requests
    unlimited-width output - without it, a `ps` whose stdout is not a
    terminal still defaults to a fixed column width on BSD/macOS and would
    silently truncate a long command line, defeating `--proc-re` with no
    error. Empty dict if the root is gone or ps cannot be read."""
    try:
        out = subprocess.check_output(
            ["ps", "-ax", "-ww", "-o", "pid=,ppid=,time=,etime=,args="],
            stderr=subprocess.DEVNULL, universal_newlines=True)
    except Exception:
        return {}
    rows = {}
    children = {}
    for line in out.splitlines():
        parts = line.split(None, 4)
        if len(parts) != 5:
            continue
        try:
            pid, ppid = int(parts[0]), int(parts[1])
            cpu = _parse_ps_seconds(parts[2])
            elapsed = _parse_ps_seconds(parts[3])
        except ValueError:
            continue
        args = parts[4]
        rows[pid] = (cpu, elapsed, args)
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


def _probe_cpu_delta(root_pid, gap, eps):
    """True iff root_pid's process tree shows summed cputime delta >= eps
    over a `gap`-second sampling window - _probe_execution's branch (b),
    extracted as its own callable (issue #244) so a caller that wants ONLY
    this evidence can get it without branch (a) (any descendant that
    started after root_grace - see _probe_execution's own docstring)
    short-circuiting first. cmd_forward_motion_check is exactly such a
    caller: branch (a) alone would read a child merely parked on its own
    idle armed watcher as "alive" for free (an armed watcher is itself a
    late-started descendant), silently defeating that detector for its most
    ordinary population - see the "Flip-time liveness probe" comment ahead
    of cmd_forward_motion_check's call site for the full reasoning.
    _probe_execution calls this for its own branch (b) below, so the two
    can never drift apart. False if either sample is unreadable (the tree
    vanished, or ps could not be read) - the same fail-open contract
    _probe_execution itself already has."""
    first = _ps_tree(root_pid)
    if not first:
        return False
    time.sleep(gap)
    second = _ps_tree(root_pid)
    if not second:
        return False
    delta = 0.0
    for pid in set(first) & set(second):
        delta += max(0.0, second[pid][0] - first[pid][0])
    return delta >= eps


def _probe_execution(root_pid, root_grace, gap, eps):
    """True if the pane's process tree shows positive evidence of execution or an
    armed wake source: (a) any descendant whose start lags the root's by more than
    root_grace seconds (an in-flight tool shell, or an armed background watcher
    that will exit and wake the session; launch-time children like MCP servers
    start with the root and do not count), else (b) summed cputime delta over pids
    present in two samples `gap` seconds apart >= eps (see _probe_cpu_delta). If
    the tree cannot be read at all, returns False (fall back to the staleness
    verdict; window liveness is reconcile's job)."""
    first = _ps_tree(root_pid)
    if not first:
        return False
    root_elapsed = first[root_pid][1]
    for pid, (_cpu, elapsed, _args) in first.items():
        # etime arithmetic (root_elapsed - descendant_elapsed), never wall-clock
        # start-time parsing, so the comparison is locale-safe.
        if pid != root_pid and (root_elapsed - elapsed) > root_grace:
            return True
    return _probe_cpu_delta(root_pid, gap, eps)


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
    for pid, (_cpu, elapsed, _args) in tree.items():
        if pid == root_pid:
            continue
        if (root_elapsed - elapsed) > root_grace and (best is None or elapsed > best[1]):
            best = (pid, elapsed)
    return best


def cmd_liveness_probe(args):
    """Print 'alive' iff --pane-pid's process tree holds a descendant that
    started more than --root-grace seconds after the root - _probe_execution's
    branch (a), exposed as a standalone read-only question so bin/watch-fleet
    can ask it BEFORE deciding to type a check-in nudge into a pane (issue
    #234), instead of only afterwards via cmd_stall_check's own probe.

    Deliberately branch (a) only: branch (b) (summed cputime delta over a
    --probe-gap sleep) would make this call block for seconds inside the
    watcher's per-member loop, and the population it alone would catch - a
    member burning CPU with no late-started descendant - repaints its pane and
    so never reaches the idle threshold that nominates a nudge candidate in the
    first place. The consequence is that this answers 'alive' for a strict
    SUBSET of the members cmd_stall_check refuses to flip, which is the
    property the caller depends on: suppressing a nudge can never suppress an
    escalation that would otherwise have happened.

    Takes no --id: the question is about a process tree, not a crew record, and
    nothing here reads or writes any state file."""
    print("alive" if _longest_running_descendant(args.pane_pid, args.root_grace) else "", end="")


def _stamp_nudged_at(cid):
    """Stamp nudged_at = now() onto cid's status file the moment bin/watch-
    fleet passes --just-nudged 1 to cmd_stall_check (#155 fix 1) - the same
    poll it actually sent the check-in nudge.

    Re-reads the status file fresh under with_locked(...) immediately before
    writing, rather than trusting any dict a caller might have read earlier
    (#155 review fix - see _track_long_running's docstring for the full
    rationale, which applies identically here): cmd_stall_check's own entry
    read happens before this is called, and writing that back verbatim later
    would risk silently reverting a genuine self-report that landed on disk
    in between. A no-op once the member is no longer 'working' by the time
    the lock is acquired. Touches only nudged_at - never summary/status/
    `updated`/`announced` - so this can never itself fire the watcher/Stop-
    hook wake; cmd_crew_set clears it again on the member's own next self-
    report (same lock), and a genuine stall flip clears it directly too."""
    path = status_path(cid)
    with with_locked(path):
        current = read_json(path, None)
        if isinstance(current, dict) and current.get("status") == "working":
            current["nudged_at"] = now()
            write_json(path, current)


def _track_long_running(cid, pane_pid, root_grace):
    """Persist the elapsed time of the single longest-lived qualifying
    descendant (see _longest_running_descendant) onto the member's own status
    JSON, so a render step (crew-list/board.md) can surface a 'been running
    longer than usual' annotation (#155 fix 2) without itself walking the
    process tree or needing to know the warn ceiling.

    Called on every wm_state wedge-check invocation (issue #202) for a
    'working' OR 'blocked' member with a resolvable pid - independent of every
    gate below it, since the scenario this exists to catch (a single
    long-outstanding tool call or background shell) keeps Claude Code's own
    pane repainting via its "N shell(s) still running" indicator, so
    pane-liveness alone may never nominate this member for anything else.
    Relocated here from cmd_stall_check (which only ever ran for 'working'
    members) so the annotation is maintained for a 'blocked' member too - see
    _stall_annotation's own docstring for the same widening on the render
    side.

    Takes no `live` snapshot from its caller (#155 review fix): the process-
    tree probe below can take a moment, and cmd_stall_check's own initial read
    happens even earlier - writing back a dict read that long ago would risk
    silently reverting a genuine self-report (a status/blocker/summary change)
    that landed on disk in the meantime, since write_json is a full-file
    replace, not a merge. Instead this re-reads the status file itself, fresh,
    inside a with_locked(...) critical section immediately before writing, and
    merges in only long_shell_pid/long_shell_elapsed - never touching
    `status`/`summary`/`blocker`/`updated`/`announced`, so it can never itself
    fire the watcher/Stop-hook wake or clobber a concurrent self-report made
    by the member's own `crew-set` (which takes the identical lock). Clears
    both fields the instant no qualifying descendant is found - a legitimately
    finished command, or the watcher's own next poll simply catching the
    process tree between two different qualifying descendants - so a stale
    annotation never lingers past the process it described. A no-op once the
    member is no longer 'working' or 'blocked' by the time the lock is
    acquired (a self-report to review/done raced this same call, or a
    'blocked' member answered its blocker and resumed 'working' - either way
    the ordinary status change already covers what happens next) - rendering
    already gates on the same pair, so there's nothing left to track.
    """
    found = _longest_running_descendant(pane_pid, root_grace)
    path = status_path(cid)
    with with_locked(path):
        current = read_json(path, None)
        if not isinstance(current, dict) or current.get("status") not in ("working", "blocked"):
            return
        if found is None:
            if "long_shell_pid" in current or "long_shell_elapsed" in current:
                current.pop("long_shell_pid", None)
                current.pop("long_shell_elapsed", None)
                write_json(path, current)
            return
        pid, elapsed = found
        if current.get("long_shell_pid") == pid and current.get("long_shell_elapsed") == elapsed:
            return  # unchanged since the last poll - nothing new to persist
        current["long_shell_pid"] = pid
        current["long_shell_elapsed"] = elapsed
        write_json(path, current)


def _impose_stall(cid, status_file, live, source, reason, clear_blocker=False, extra=None):
    """The single write that imposes 'stalled' onto `live` (the current
    on-disk dict for `cid`), shared by cmd_stall_check, cmd_wedge_check and
    cmd_forward_motion_check (issue #235). Caller holds with_locked(status_file)
    and has already re-checked the record (re-read fresh, status/updated still
    match this call's own snapshot) before calling this - it performs the
    write itself, matching every one of the three call sites' own prior
    inline write_json(status_file, live).

    Records the provenance cmd_stall_recheck needs to re-run THIS detector's
    own evidence later (`source`, plus whatever per-source identifying data
    the caller passes as `extra` - `wedge_pid` for a wedge flip, `children_sig`
    for a forward-motion one), and the pre-flip (status, summary, blocker)
    triple - captured from `live` BEFORE any of the mutations below, so a
    revert can restore it losslessly. `prev_summary` is stored UNTRUNCATED
    (the reason text passed in by the caller may itself carry only an
    80-character prefix of it, which is fine for a human reading the fire but
    would be lossy for a restore). `prev_blocker` exists because
    `clear_blocker=True` (wedge only) pops the `blocker` FIELD below, after
    this function has already captured its text - reverting without restoring
    it would destroy an open question.

    `stall.since` and `live["updated"]` are stamped from the SAME now() call,
    so the flip instant recorded in the provenance and the record's own
    version stamp are always identical, never a poll apart.

    Every existing reason-string caller passes in unchanged (`reason` is
    accepted, not composed here) - this only changes what gets WRITTEN onto
    the record, not the text of any of the three flip reasons."""
    stall = {
        "source": source,
        "since": now(),
        "prev_status": live.get("status"),
        "prev_summary": live.get("summary"),
        "prev_blocker": live.get("blocker"),
    }
    if extra:
        stall.update(extra)
    live["stall"] = stall
    live["status"] = "stalled"
    live["summary"] = reason
    live["updated"] = stall["since"]
    live["announced"] = live["updated"]  # a stall flip always announces
    live.pop("nudged_at", None)
    if clear_blocker:
        live.pop("blocker", None)
    write_json(status_file, live)


def cmd_stall_check(args):
    """Flag a WORKING crew member as 'stalled' iff it shows no external sign of life:
    BOTH staleness gates (pane_idle from the watcher, status_idle computed here) at
    or past --threshold, AND the execution probe over --pane-pid finds no evidence,
    AND (#61) a check-in nudge has already had a full cooldown window to work.

    --nudge-age is the age in seconds of the watcher's per-id nudge marker file, or
    -1 if no marker exists yet or the marker is still 'pending' (a nudge attempt is
    in flight or awaiting retry). A genuine stall only flips once --nudge-age is >= 0
    and >= --threshold. A non-negative age means one of two things: either a
    confirmed nudge has had its cooldown, or (issue #236) the watcher exhausted its
    bounded retry budget without ever confirming a submit - --nudge-confirmed is
    what tells the reason text which of the two actually happened. On the first
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

    --just-nudged (#155 fix 1) is an unconditional side effect that runs on every
    call regardless of the gates above - see its own inline comment for why - and
    never changes whether or when a flip happens. The long-shell duration tracking
    #155 fix 2 originally added here (_track_long_running) has since been
    relocated to wm_state wedge-check (issue #202), which runs for both
    'working' and 'blocked' members every poll - this call only ever ran for
    'working' ones, so lifting it out (rather than duplicating it) is what let
    the annotation start covering 'blocked' members too, with no coverage lost
    for 'working' ones: wedge-check's own call site in bin/watch-fleet sits
    strictly above both the blocked skip and this call's own PFC_SHAPE skip,
    so it runs at least as often as this command did."""
    ensure_home()
    live = read_json(status_path(args.id), None)
    if not isinstance(live, dict) or live.get("status") != "working":
        return
    updated = _parse_updated(live.get("updated"))
    if updated is None:
        return

    # #155 fix 1: see _stamp_nudged_at's own docstring for why this reads
    # fresh under a lock rather than reusing `live` from just above.
    if getattr(args, "just_nudged", 0):
        _stamp_nudged_at(args.id)

    status_idle = (datetime.datetime.now(datetime.timezone.utc) - updated).total_seconds()
    if args.pane_idle < args.threshold or status_idle < args.threshold:
        return
    if _probe_execution(args.pane_pid, args.root_grace, args.probe_gap, args.cpu_eps):
        return
    # The probe slept for the sampling gap; a member that self-reported during it
    # (a flip to review with an artifact, a real blocker) must win over the
    # pre-gap snapshot. Re-read and bail unless nothing changed - and hold the
    # SAME per-member lock the other writers of this file take (#155 review
    # fix) across that re-read and the eventual write below, closing the
    # remaining TOCTOU window a bare re-read-then-write-later still leaves
    # open for a self-report landing in between.
    status_file = status_path(args.id)
    with with_locked(status_file):
        current = read_json(status_file, None)
        if (not isinstance(current, dict) or current.get("status") != "working"
                or current.get("updated") != live.get("updated")):
            return
        live = current

        # #61: a genuine stall only flips once a check-in nudge has already had a
        # full cooldown window to produce activity - not on the very poll that
        # first detects it. No marker yet (-1) or too young (< threshold) means
        # the watcher's nudge hasn't had time to work yet; defer without
        # mutating anything.
        nudge_age = getattr(args, "nudge_age", -1)
        if nudge_age < 0 or nudge_age < args.threshold:
            return

        prior = (live.get("summary") or "").split("\n")[0][:80]
        nudge_confirmed = getattr(args, "nudge_confirmed", 1)
        nudge_attempts = getattr(args, "nudge_attempts", 0)
        if getattr(args, "nudge_undelivered", 0):
            # issue #214, §3.6: the watcher could never actually TYPE a
            # check-in nudge into this pane (busy with a pending composer,
            # dialog-shaped, or lock-contended, WM_NUDGE_REFUSED_MAX
            # consecutive polls in a row) and stamped the marker anyway so
            # this flip could still happen - a member nobody can reach is
            # more in need of surfacing, not less. Checked first, ahead of
            # both api_error and nudge_confirmed (#236): if a nudge was never
            # typed at all, that dominates whatever the pane tail shows and
            # whatever an earlier, unrelated attempt's own confirm state was.
            reason = ("could not deliver a check-in nudge in %d attempts - the pane is busy, "
                      "dialog-shaped or locked, and the member has been idle for >%ds while "
                      "status was 'working'. Inspect with `bin/crew-takeover %s` or stand down "
                      "with `bin/crew-standdown %s`."
                      % (int(os.environ.get("WM_NUDGE_REFUSED_MAX", "3")), int(args.threshold),
                         args.id, args.id))
        elif getattr(args, "api_error", 0):
            if nudge_confirmed:
                reason = ("api-error: the pane shows an API/connectivity-error signature (rate "
                          "limit, connection error, 5xx, overloaded_error, or similar) and then "
                          "went quiet for >%ds while status was 'working' - the CLI's own retry/"
                          "backoff appears exhausted. Likely a local network blip or an Anthropic-"
                          "side outage, not a broken agent. Already nudged once; if it does not "
                          "recover, resume it with `bin/crew-resume %s`."
                          % (int(args.threshold), args.id))
            else:
                reason = ("api-error: the pane shows an API/connectivity-error signature (rate "
                          "limit, connection error, 5xx, overloaded_error, or similar) and then "
                          "went quiet for >%ds while status was 'working' - the CLI's own retry/"
                          "backoff appears exhausted. Likely a local network blip or an Anthropic-"
                          "side outage, not a broken agent. A check-in nudge was typed into its "
                          "pane %d time(s) but the submit was never confirmed - its input may be "
                          "wedged, so it most likely never saw the nudge at all. If it does not "
                          "recover, resume it with `bin/crew-resume %s`."
                          % (int(args.threshold), nudge_attempts, args.id))
        else:
            if nudge_confirmed:
                reason = ("no pane output, status update, running child process, or CPU activity "
                          "for >%ds while status was 'working', even after a check-in nudge - the "
                          "agent likely errored or went idle. Inspect with `bin/crew-takeover %s` "
                          "or stand down with `bin/crew-standdown %s`."
                          % (int(args.threshold), args.id, args.id))
            else:
                reason = ("no pane output, status update, running child process, or CPU activity "
                          "for >%ds while status was 'working'. A check-in nudge was typed into "
                          "its pane %d time(s) but the submit was never confirmed - its input may "
                          "be wedged, so it most likely never saw the nudge at all. Inspect with "
                          "`bin/crew-takeover %s` or stand down with `bin/crew-standdown %s`."
                          % (int(args.threshold), nudge_attempts, args.id, args.id))
        # issue #234: the templates above all describe a member whose own agent
        # is the suspect. For a member that still owns live reports that
        # diagnosis is very likely wrong - the observed silence is its own wake
        # chain (its armed watcher, its Stop-hook re-arm) having died over a
        # sub-crew nobody has closed out - and so is the takeover/stand-down
        # remedy they name: a crew-say nudge makes it re-arm and pick its own
        # crew back up, with no session lost. Appended to whichever template was
        # chosen, rather than added as further template variants, so this
        # composes with the api-error and undelivered-nudge wordings instead of
        # multiplying them.
        #
        # "live", never "running"/"progressing": LIVE_STATES spans working,
        # blocked, review and stalled, so a report counted here may be parked
        # awaiting a verdict rather than doing anything. This clause exists to
        # stop a reason text asserting more than the evidence supports; it must
        # not commit the same error one level down.
        _reports = _active_report_count(args.id)
        if _reports:
            reason += (" It still owns %d live report(s) that nobody has closed "
                       "out: the likely failure is this member's own wake chain "
                       "(a dead watcher or a missed re-arm), not its agent - try "
                       "`bin/crew-say %s <nudge>` first, which makes it re-arm and "
                       "resume supervising them." % (_reports, args.id))
        if prior:
            reason += " (last summary: %s)" % prior

        _impose_stall(args.id, status_file, live, "liveness", reason)
    # This stall episode is over (flipped) - clear the watcher's own sidecars
    # too, or a future episode's first flip would inherit a stale refused-nudge
    # count (or a stale delivered-nudge marker) from this one (issue #214, §3.6
    # step 5).
    _clear_stall_nudge_sidecars(args.id)

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


def _wedge_descendant(pane_pid, proc_re, threshold):
    """Of pane_pid's descendants (never pane_pid itself), return
    (pid, args, elapsed_seconds) for whichever has both: `args` matching
    `proc_re` (a plain re.search, not anchored) AND its own elapsed time
    >= threshold - preferring the longest-elapsed qualifying descendant if
    more than one matches. None if the tree cannot be read, `proc_re` fails
    to compile, or nothing qualifies. This is the wm_state wedge-check
    instrument (issue #202, plan section 2.6): a matching, long-lived
    descendant is what a watch-fleet/pr-watch cycle blocking in the
    FOREGROUND of this pane looks like from outside it - necessary evidence,
    never sufficient alone (see cmd_wedge_check's own docstring for why pane
    continuity must accompany it)."""
    tree = _ps_tree(pane_pid)
    if not tree:
        return None
    try:
        rx = re.compile(proc_re)
    except re.error:
        return None
    best = None
    for pid, (_cpu, elapsed, proc_args) in tree.items():
        if pid == pane_pid or elapsed < threshold:
            continue
        if not rx.search(proc_args):
            continue
        if best is None or elapsed > best[2]:
            best = (pid, proc_args, elapsed)
    return best


def cmd_wedge_check(args):
    """Flag a WORKING or BLOCKED crew member 'stalled' iff it shows the
    signature of a watch-fleet/pr-watch cycle blocking in the FOREGROUND of
    its own session (issue #202): its pane has repainted continuously - never
    idle at a prompt - for --threshold seconds of genuinely OBSERVED
    continuity, its own record has gone unwritten for the same window, AND a
    descendant matching --proc-re (default 'watch-fleet|pr-watch') has itself
    been running >= --threshold seconds. All three must hold together -
    pane continuity alone would flip any legitimately long foreground task,
    and the descendant duration alone would flip a lead whose own
    correctly-armed background watcher is simply blocking on a quiet crew
    (see docs/plans/2026-08-03-issue-202-foreground-watcher-wedge-plan.md,
    section 2.6): only the combination is specific to a wedge.

    Widened to 'blocked' (not just 'working', unlike cmd_stall_check) because
    the wedge this is named for happens exactly as easily while answering a
    blocker as it does mid-task - a delegate that receives its answer,
    reports back once, and then foregrounds its own re-arm is wedged whether
    its status says 'working' or 'blocked' at that moment.

    Called per member per bin/watch-fleet poll (both statuses), unlike
    cmd_stall_check (working only, and only once the blocked skip has
    already excluded a blocked member for that poll) - see the call site
    comment in bin/watch-fleet for why this one sits ABOVE that skip.

    --root-grace is passed straight through to the relocated
    _track_long_running call (#155 fix 2, issue #202) - see its own
    docstring; it never gates a flip here, exactly as it never did in
    cmd_stall_check.

    Anchor store (wedge-anchor.json): {"<id>": {"since": <iso>,
    "last_seen": <iso>, "pid": <pane_pid>}}, read-modify-written under
    with_locked, matching forward-motion.json. `since` is the moment
    continuity was last (re-)established; `last_seen` is the moment
    continuity was last CONFIRMED, and is what makes the anchor require
    genuinely OBSERVED continuity rather than merely "no poll has yet
    observed a quiet pane since `since`" - a watcher outage spanning two
    live observations would otherwise read as continuous coverage across the
    whole gap it never actually watched. Three resets, in order, before the
    update:
      1. --pane-idle >= --pane-gap: the pane has fallen silent at its
         prompt (a correctly-armed background watcher, or simply idle).
         Drop the entry and return - nothing to anchor.
      2. An entry exists and now - last_seen > --pane-gap: coverage was
         lost (no poll observed this member across that stretch). Drop the
         entry and re-anchor (create a fresh one), exactly as an observed
         quiet pane does, so a genuine outage never accumulates credit for
         the gap it did not watch.
      3. An entry exists and its pid differs from --pane-pid: the session's
         tmux pane was restarted. Drop the entry and re-anchor.
    Otherwise the pane is live and observed: create the entry if absent, or
    advance last_seen on the existing one. No entry-removal sweep for a
    member that leaves working/blocked (matching forward-motion.json's own
    practice - cmd_prune sweeps only acked/handled records) - noted, not
    fixed, here.

    On a genuine flip: `blocker` (if any) is cleared from the field but its
    text is copied into the new `summary` first - a false positive must
    never destroy an open question (the #202 plan's own must-fix over its
    first revision, which discarded it). Re-reads and bails under
    with_locked(status_path(id)) unless status is still working/blocked and
    `updated` still matches this call's own initial snapshot - the same
    TOCTOU guard cmd_forward_motion_check uses, so a genuine self-report
    landing in the meantime always wins over a stale nomination.

    Prints 'stalled <id>' on a flip, nothing otherwise. Idempotent and safe
    to call every poll for every working/blocked member."""
    ensure_home()
    cid = args.id
    status_file = status_path(cid)
    live = read_json(status_file, None)
    if not isinstance(live, dict) or live.get("status") not in ("working", "blocked"):
        return
    updated_snapshot = live.get("updated")
    updated_dt = _parse_updated(updated_snapshot)

    # Unconditional side effect (#155 fix 2, relocated here by issue #202) -
    # independent of every gate below. See _track_long_running's own
    # docstring for why it cannot wait for those gates to pass first.
    _track_long_running(cid, args.pane_pid, args.root_grace)

    stamp = now()
    stamp_dt = _parse_updated(stamp)

    anchor_path = wedge_anchor_path()
    with with_locked(anchor_path):
        store = read_json(anchor_path, {})
        if not isinstance(store, dict):
            store = {}
        entry = store.get(cid)

        if args.pane_idle >= args.pane_gap:
            if cid in store:
                del store[cid]
                write_json(anchor_path, store)
            return

        reanchor = not isinstance(entry, dict)
        if not reanchor:
            last_seen_dt = _parse_updated(entry.get("last_seen"))
            if (last_seen_dt is None or stamp_dt is None
                    or (stamp_dt - last_seen_dt).total_seconds() > args.pane_gap):
                reanchor = True  # coverage lost
            elif entry.get("pid") != args.pane_pid:
                reanchor = True  # pane restarted

        if reanchor:
            store[cid] = {"since": stamp, "last_seen": stamp, "pid": args.pane_pid}
        else:
            entry["last_seen"] = stamp
            store[cid] = entry
        write_json(anchor_path, store)
        since = store[cid]["since"]

    since_dt = _parse_updated(since)
    if since_dt is None or stamp_dt is None or (stamp_dt - since_dt).total_seconds() < args.threshold:
        return
    if updated_dt is None or (stamp_dt - updated_dt).total_seconds() < args.threshold:
        return

    proc_re = getattr(args, "proc_re", None) or os.environ.get("WM_WEDGE_PROC_RE") or "watch-fleet|pr-watch"
    found = _wedge_descendant(args.pane_pid, proc_re, args.threshold)
    if found is None:
        return
    desc_pid, desc_args, desc_elapsed = found

    with with_locked(status_file):
        current = read_json(status_file, None)
        if (not isinstance(current, dict) or current.get("status") not in ("working", "blocked")
                or current.get("updated") != updated_snapshot):
            return
        live = current

        reason = (
            "wedged mid-turn for over %s: its pane has repainted "
            "continuously the whole time (never idle at a prompt) while its "
            "own record has not been written, and `%s` (pid %d) has been "
            "running as a descendant of its pane for %s. That is the "
            "signature of a blocking watcher started in the FOREGROUND of "
            "its own session (issue #202) - a correctly backgrounded one "
            "leaves the session idle at its prompt. It will not resume on "
            "its own: inspect with `bin/crew-takeover %s`, or stand it down "
            "with `bin/crew-standdown %s`."
            % (_human_duration(args.threshold), desc_args, desc_pid,
               _human_duration(desc_elapsed), cid, cid)
        )
        blocker = live.get("blocker")
        if blocker:
            reason += " (unanswered question was: %s)" % blocker
        prior = (live.get("summary") or "").split("\n")[0][:80]
        if prior:
            reason += " (last summary: %s)" % prior

        # clear_blocker=True: the FIELD is popped only after its text has
        # already been copied into `reason` above AND captured as
        # `prev_blocker` by _impose_stall itself (from `live`, before the
        # pop) - a false positive must never destroy an open question, and a
        # revert must be able to restore it losslessly. Leaving the field set
        # would also make cmd_needs_attention's `blocker or delivery or
        # artifact_url or artifact or summary` note surface the stale
        # question instead of this stall reason.
        _impose_stall(cid, status_file, live, "wedge", reason,
                       clear_blocker=True, extra={"wedge_pid": desc_pid})

    with with_locked(crew_json_path()):
        roster = load_roster()
        for r in roster:
            if r.get("id") == cid:
                r["status"] = "stalled"
                r["updated"] = live["updated"]
        write_json(crew_json_path(), roster)
    render_board()
    print("stalled %s" % cid)


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
            # Resumability (issue #251): a died member's session_id and transcript
            # survive independent of its worktree - lead with recovery rather than
            # letting a bare "died" read as a dead end (the exact misreading the
            # 2026-08-04 postmortem documents). Checked fresh, not cached: cheap
            # (existence-only, see is_resumable), and correct even for a record
            # written before this field existed.
            if r.get("status") == "died":
                if is_resumable(r):
                    note = note + (" Session state survived and is resumable: "
                                    "`bin/crew-takeover %s` or `bin/crew-resume %s`."
                                    % (rid, rid))
                if r.get("wip_ref_sha"):
                    note = note + (" Uncommitted worktree changes were auto-anchored "
                                    "at `refs/wip/%s`." % _sanitize_id(rid))
            # Stale Remote Control caveat (issue #96): nothing can deregister a
            # died member's Remote Control entry after the fact (no mechanism
            # exists - see the plan), so make the staleness visible in the one
            # note every died relay already flows through, rather than relying
            # on prose discipline elsewhere. `remote_control` absent reads as
            # True - see cmd_crew_add's comment for why.
            if r.get("status") == "died" and r.get("remote_control", True):
                note = note + (" (Remote Control may still show 'wm-%s' as connected "
                                "- this is stale; disregard it.)" % rid)
            # A leading space would otherwise appear whenever the base note (the
            # blocker/delivery/artifact_url/artifact/summary chain above) is
            # empty and only an appended clause (resumability, wip-ref, stale-RC)
            # follows it (review round 1, nice-to-have 6).
            note = note.strip()
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
    # merged() view by id, so resumability (below) can be looked up WITHOUT a
    # second load_roster() pass - this dict itself costs nothing extra (every
    # record here was already being merged() for the two lookups above, on
    # every group-attention call, before issue #251 touched this function).
    roster_by_id = {}
    for r in load_roster():
        m = merged(r)
        rid = r.get("id")
        death_cause_by_id[rid] = m.get("death_cause")
        remote_control_by_id[rid] = m.get("remote_control", True)
        roster_by_id[rid] = m

    def _resumable_count(ids):
        # Resumability (issue #251): the exact scenario this batch collapses -
        # many members dying together, most plausibly a tmux/host crash - is the
        # incident this issue was written from, where the correlated note's own
        # "resume" framing was the one place resumability was NOT actually in
        # doubt (session transcripts survive independent of the crash), yet
        # nothing said so explicitly. is_resumable() stats a file on disk, unlike
        # every other per-record lookup in this function (roster-JSON-only) - so
        # this is called ONLY for the ids of a batch that is actually about to be
        # reported (from inside a collapse block below), never eagerly for the
        # whole roster on every group-attention call regardless of whether any
        # died row exists at all.
        return sum(1 for i in ids if is_resumable(roster_by_id.get(i, {})))

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
            resumable_count = _resumable_count(crash_ids)
            synth_note = ("%d crew members died together (likely a tmux/host crash): %s. "
                          "This is not lost work: %d/%d still have an intact session transcript "
                          "on disk and are resumable regardless of worktree state. "
                          "Default remedy: `%s`." % (len(crash_death_rows), names, resumable_count,
                                                      len(crash_death_rows), resume_cmd))
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
            resumable_count = _resumable_count(outage_death_ids)
            synth_note = ("%d crew members died together during a detected API outage: %s. "
                          "%d/%d already have an intact, resumable session transcript on disk - "
                          "the work is not lost, only paused. Do NOT resume yet, though - the "
                          "same root cause as a correlated api-outage "
                          "stall (an Anthropic-side burst, not a tmux/host crash), so resuming "
                          "now risks immediate re-death. Once the outage clears, `%s` runs "
                          "automatically for these (pre-authorized auto-recovery, issue #23)."
                          % (len(outage_death_rows), names, resumable_count,
                             len(outage_death_rows), resume_cmd))
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

    SINGLE WRITER by design: the owner-"" watcher's singleton guard makes it
    the only process advancing this state file, which is why the
    read-modify-write below carries no with_locked(). Adding a second caller
    (another owner scope, a manual CLI invocation in automation) requires
    adding the lock first.

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

    SINGLE WRITER by design: the owner-"" watcher's singleton guard makes it
    the only process advancing this state file (usage-decide, the one other
    writer, is a pilot-driven CLI call against a settled state, not a per-poll
    racer), which is why there is no with_locked() here. A second automated
    caller requires adding the lock first.

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


def _review_has_live_waker(cid, grace_secs):
    """True iff bin/pr-watch's blocking loop is actively polling on this
    member's behalf right now: its beacon file exists and was touched within
    the last grace_secs. No beacon at all (never armed --once was used
    exclusively) or a stale one (the loop exited or the process died) both
    read as "no live waker" - see cmd_review_resurface_check."""
    try:
        age = time.time() - os.path.getmtime(pr_watch_beat_path(cid))
    except OSError:
        return False
    return age < grace_secs


def cmd_review_resurface_check(args):
    """Advance the bounded-resurface check for every `review` member with no
    live dependency watcher (issue #187): a `review` member surfaces once, on
    entry (cmd_needs_attention) - correct for one being actively shepherded by
    something pollable (a developer's PR under bin/pr-watch), but silent
    forever for one with nothing polling on its behalf (an analyst idling for
    pilot feedback, a developer whose delivery has no forge signal, or one
    that simply isn't currently running pr-watch). This adds exactly one
    bounded reminder per --window-secs, scoped narrowly to that population.

    Reads/writes its OWN store (review-resurfaced.json: {"<id>": {"announced":
    "<iso>", "at": "<iso>"}}) - never acked.json/handled.json, and never the
    member's own `announced` field - so firing a reminder cannot interact with
    the #57 once-only dedup a live-watcher member still relies on, and the
    resurface cadence is not derived from WM_WATCH_INTERVAL.

    Called every bin/watch-fleet iteration but only ever *fires* (emits a row
    and writes the store) once the wall-clock window has elapsed for a given
    id, so poll cadence and resurface cadence stay fully decoupled. --owner
    scopes exactly like cmd_needs_attention, so a lead's own watch-fleet cycle
    bounded-resurfaces only its own team.

    For each status == "review" record with no live waker
    (_review_has_live_waker false, checked against --waker-grace):
      - announced = the member's current announced (falling back to updated).
      - If the store already has an entry for this id AND that entry's
        recorded `announced` still matches the member's current `announced`,
        the anchor is that entry's `at` (the last time this exact standing
        review was resurfaced). Otherwise - no entry yet, or `announced` has
        since moved (a genuine new `review` transition, already re-announced
        via the normal #57 path) - the anchor is `announced` itself, and any
        stale entry is discarded. A genuine re-announce therefore resets the
        resurface clock for free, with no extra bookkeeping.
      - If now - anchor >= --window-secs: emit one TSV row (id, "review",
        announced, note) and write store[id] = {"announced": announced, "at":
        now}. This is the ONLY place the store is written - a check that
        doesn't cross the window touches nothing on disk, so a watch-fleet
        restart or re-arm mid-window never resets the countdown; the
        persisted (announced, at) pair, not any in-memory state, gates it.

    The note is deliberately distinct from cmd_needs_attention's own note:
    "REMINDER (no live watcher, unchanged for <window>): <pointer>", using the
    same pointer priority (blocker/delivery/artifact_url/artifact/summary).
    The leading "REMINDER (" token is the machine-checkable marker that
    distinguishes a standing-work reminder from a fresh delivery event.

    The read-modify-write is wrapped in with_locked, matching cmd_ack/
    cmd_mark_handled - watch-fleet cycles for different owners share this one
    file. Prints the TSV rows emitted; pure side effect otherwise (a check
    that fires nothing touches no disk state at all)."""
    ensure_home()
    owner = getattr(args, "owner", None)
    window_secs = args.window_secs
    waker_grace = args.waker_grace

    with with_locked(review_resurfaced_path()):
        store = read_json(review_resurfaced_path(), {})
        if not isinstance(store, dict):
            store = {}
        changed = False
        stamp = now()
        stamp_dt = _parse_updated(stamp)

        for r in (merged(x) for x in load_roster()):
            if owner is not None and parent_of(r) != owner:
                continue
            if r.get("status") != "review":
                continue
            rid = r["id"]
            if _review_has_live_waker(rid, waker_grace):
                continue
            announced = r.get("announced") or r.get("updated")
            if not announced:
                continue

            entry = store.get(rid)
            if isinstance(entry, dict) and entry.get("announced") == announced:
                anchor = entry.get("at")
            else:
                anchor = announced
                if rid in store:
                    del store[rid]
                    changed = True

            anchor_dt = _parse_updated(anchor)
            if anchor_dt is None or stamp_dt is None:
                continue
            elapsed = (stamp_dt - anchor_dt).total_seconds()
            if elapsed < window_secs:
                continue

            note = (r.get("blocker") or r.get("delivery")
                    or r.get("artifact_url") or r.get("artifact") or r.get("summary") or "")
            note = "REMINDER (no live watcher, unchanged for %s): %s" % (
                _human_duration(window_secs), note)
            print("%s\t%s\t%s\t%s" % (rid, "review", announced, note))
            store[rid] = {"announced": announced, "at": stamp}
            changed = True

        if changed:
            write_json(review_resurfaced_path(), store)


def _child_tuples(children):
    """Sorted (child_id, child_status, child_announced) tuple for every one of
    `children` (already filtered to LIVE_STATES by the caller). `announced`
    (falling back to `updated` only when absent) is used for each child - not
    `updated` - matching the exact idiom cmd_review_resurface_check/
    cmd_needs_attention already use elsewhere in this file: `updated` bumps on
    every routine same-status summary refresh, so keying on it would let an
    actively-narrating-but-not-actually-progressing report reset the
    staleness clock forever. Extracted out of _forward_motion_signature
    (issue #235) so cmd_stall_recheck's forward-motion clearing predicate can
    hash just the reports half on its own - see _children_signature - without
    duplicating this construction."""
    return sorted(
        (c["id"], c.get("status"), c.get("announced") or c.get("updated"))
        for c in children
    )


def _children_signature(children):
    """Hash of _child_tuples(children) alone - the reports half of
    _forward_motion_signature, with none of the candidate's own (summary,
    blocker, artifact, delivery, parked). While a member is latched
    'stalled', nothing writes ITS OWN summary/blocker/artifact/delivery (that
    is the latch), so the only half of the flip's signature that CAN move is
    the reports half - this is what cmd_stall_recheck's forward-motion
    clearing predicate compares against the `children_sig` recorded at flip
    time (see _impose_stall)."""
    payload = json.dumps(_child_tuples(children), sort_keys=True, default=str)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _forward_motion_signature(candidate, children):
    """Hash of the candidate's own (summary, blocker, artifact, delivery,
    parked) plus _child_tuples(children) (see its own docstring for why
    `announced`, not `updated`, is the per-child key). `parked` (#203) is
    included so parking or unparking an item resets the staleness clock
    directly - a lead now spends materially more time sitting in `working`
    with active reports (it no longer flips to `blocked` for a single parked
    item), which is exactly the shape this check polices. Output is
    byte-identical to before _child_tuples was extracted out of this
    function (issue #235) - the construction moved, not the shape."""
    own = (candidate.get("summary"), candidate.get("blocker"),
           candidate.get("artifact"), candidate.get("delivery"),
           tuple(sorted((p.get("ref"), p.get("note")) for p in candidate.get("parked") or [])))
    payload = json.dumps([own, _child_tuples(children)], sort_keys=True, default=str)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _read_pane_pid_map(args):
    """{crew_id: pid} parsed from --pane-pids-stdin's 'wm-<id> <pid>' lines
    (bin/watch-fleet's own window-naming convention: tmux list-panes -s -F
    '#{window_name} #{pane_pid}', one line per pane in the session). {} if
    the flag was not passed - opt-in only, so a caller with nothing to probe
    (every existing test, and any invocation with no working children in
    scope) never blocks reading stdin.

    A line that does not split into exactly two whitespace-separated fields,
    whose first field does not start with 'wm-', or whose second field is
    not an integer, is silently dropped. A crew id absent from the resulting
    map - whether because its line was dropped, or bin/watch-fleet's tmux
    snapshot simply had nothing for it - is indistinguishable from one this
    caller was never told about at all: cmd_forward_motion_check treats a
    missing id exactly like _probe_execution/_probe_cpu_delta already treat
    an unreadable process tree, failing open toward a flip rather than
    inferring liveness from the absence of contrary evidence. First-wins on
    a duplicate window name (setdefault, not overwrite), matching
    wm_tmux_pane_pid's own head -1 convention - tmux does not enforce unique
    window names."""
    if not getattr(args, "pane_pids_stdin", False):
        return {}
    out = {}
    for line in sys.stdin.read().splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].startswith("wm-"):
            try:
                out.setdefault(parts[0][len("wm-"):], int(parts[1]))
            except ValueError:
                pass
    return out


def cmd_forward_motion_check(args):
    """Flip a WORKING candidate with active reports to 'stalled' the moment
    its own situation has shown no forward motion for --window-secs, even
    with a fully healthy, armed watcher cycle (issue #199, Gap B) - a
    structural stall the liveness-only cmd_stall_check cannot see, since a
    lead correctly running its own watch-fleet loop always shows a live
    process tree and therefore never trips that check.

    MUST be invoked by the CANDIDATE'S OWN PARENT's watch-fleet cycle, never
    the candidate's own: to evaluate whether `lead1` (parent == "") is
    stalled, this is called with --owner "" - wingman's own top-level
    cycle - examining lead1 as one of ITS OWN candidate rows and, for each,
    looking at lead1's own reports. A lead's own self-scoped cycle (--owner
    <lead-id>) never evaluates whether IT ITSELF is stalled this way - only
    something one layer up can see both sides of the relationship this check
    needs (recursively, a lead's own cycle evaluating one of ITS sub-
    managers, if the depth cap on spawning managers is ever relaxed). Easy
    to misplace inside the wrong owner's loop; see bin/watch-fleet's own
    call site comment.

    Candidates: any record with status == "working", scoped by --owner
    exactly like cmd_needs_attention/cmd_review_resurface_check, that
    currently has at least one ACTIVE report (a child whose merged status is
    in LIVE_STATES). This naturally selects only members capable of showing
    this failure (today, only a `lead`-type member ever has reports at all -
    the depth cap in playbooks/common/lead.md forbids spawning managers)
    without special-casing on the `type` field, and stays correct if that
    cap is ever relaxed.

    Signature: see _forward_motion_signature. If ANYTHING about it changes -
    a child's status flips, a new child appears (e.g. a reviewer finally
    gets spawned), the candidate edits its own summary/blocker/artifact/
    delivery - the staleness clock resets. This is deliberately more general
    than testing "a review worker with no reviewer sibling" specifically: it
    requires no new schema (there is no field anywhere linking a developer's
    record to a reviewer's), and uniformly covers every "any wait" shape the
    issue names (a dropped usage-limit-reset fire, a reviewer verdict nobody
    ever requested, a CI run nobody is watching) rather than special-casing
    each one. Once a candidate's elapsed time reaches --window-secs, its
    `working` children (only) are probed via _probe_cpu_delta - deliberately
    branch (b) only, never _probe_execution (issue #244; see _probe_cpu_delta's
    own docstring, and the "Flip-time liveness probe" comment ahead of its
    call site below, for why branch (a) alone is the wrong tool here) - using
    pane pids supplied by the caller via --pane-pids-stdin, before it is added
    to the flip set; a live probe resets the anchor exactly like a genuine
    signature change, deferring re-evaluation another full window rather
    than skipping just this poll.

    Anchor/reset persistence (mirrors cmd_review_resurface_check's own
    pattern) in a new store, forward-motion.json: {"<id>": {
    "episode_announced": <str>, "signature": <str>, "since": <iso>}}. For
    each candidate:
      - if the stored entry's episode_announced matches the candidate's
        CURRENT announced (falling back to updated) AND its signature
        matches the current computed signature, reuse the stored anchor
        (`since`);
      - otherwise (no entry yet, a genuinely fresh working episode started,
        or the roster/summary shape changed within the same episode), reset
        the anchor to NOW - not to `announced`, unlike
        cmd_review_resurface_check's own first-encounter behavior: there is
        no meaningful "this shape has already been stale since X" to
        inherit here, so a candidate seen for the first time (e.g. right
        after this feature ships) never flips before a full fresh window
        elapses, rather than potentially firing immediately off an old
        `announced` timestamp it never had a chance to keep fresh against.

    Keying the anchor to episode_announced in addition to signature is what
    prevents a "resume from a previous flip, then immediately re-flip"
    thrash: a genuine stall flip below always writes a fresh `announced`
    (mirroring cmd_stall_check's own write shape), so the very next cycle
    after a resume already sees a changed `announced` relative to whatever
    was stored before the flip, forcing a reset - even though the plain
    `--status working` resume call itself never advances `announced` any
    further on its own (cmd_crew_set only advances it for a call whose
    status is one of ATTENTION_STATES, which 'working' is not). Without this
    key, a lead resumed with an otherwise-unchanged shape would find its OLD
    stored anchor still >= window_secs in the past and re-flip on the very
    next cycle.

    Firing: if now - since >= --window-secs for a still-'working' candidate,
    flip it directly to 'stalled' - a single stage, no courtesy nudge (unlike
    cmd_stall_check's liveness path): a 30-minute-plus signature-staleness
    reading on an armed, healthy watcher already has a much lower false-
    positive rate than a liveness blip, so the added complexity of a second
    nudge stage is not justified for this initial version. Reuses
    cmd_stall_check's exact write shape: a with_locked re-check that the
    record is still 'working' with the same `updated` immediately before
    writing (closing the same self-report race window cmd_stall_check
    closes), write status/summary/updated/announced, mirror into the
    roster, render_board().

    Once flipped, the candidate's status is no longer 'working', so it is
    not re-examined by this check again until a human/owner resumes it -
    this is a repeating STATE (like cmd_stall_check's own 'stalled'), not
    (unlike cmd_review_resurface_check) a repeating REMINDER note.

    Known, accepted false positive: a candidate that is genuinely, correctly
    heads-down for longer than --window-secs with no report changing state
    and no working child measurably spending CPU either flips too. This is
    self-healing by construction: the candidate's own next routine crew-set
    call is itself a genuine transition out of 'stalled', clearing the flag
    immediately - the cost is one avoidable board line, not a stuck or
    corrupted state.

    Prints 'stalled <id>' for each candidate flipped this cycle, one per
    line; pure side effect otherwise (a candidate whose anchor has not yet
    reached the window touches no disk state beyond its own anchor entry in
    forward-motion.json)."""
    ensure_home()
    owner = getattr(args, "owner", None)
    window_secs = args.window_secs
    pane_pids = _read_pane_pid_map(args)

    at_window = []

    with with_locked(forward_motion_path()):
        store = read_json(forward_motion_path(), {})
        if not isinstance(store, dict):
            store = {}
        changed = False
        stamp = now()
        stamp_dt = _parse_updated(stamp)

        rows = [merged(r) for r in load_roster()]
        by_parent = {}
        for r in rows:
            by_parent.setdefault(parent_of(r), []).append(r)

        for r in rows:
            if owner is not None and parent_of(r) != owner:
                continue
            if r.get("status") != "working":
                continue
            rid = r["id"]
            children = [c for c in by_parent.get(rid, []) if c.get("status") in LIVE_STATES]
            if not children:
                continue

            announced = r.get("announced") or r.get("updated")
            if not announced:
                continue
            signature = _forward_motion_signature(r, children)

            entry = store.get(rid)
            if (isinstance(entry, dict) and entry.get("episode_announced") == announced
                    and entry.get("signature") == signature):
                anchor = entry.get("since")
            else:
                anchor = stamp
                store[rid] = {"episode_announced": announced, "signature": signature, "since": stamp}
                changed = True

            anchor_dt = _parse_updated(anchor)
            if anchor_dt is None or stamp_dt is None:
                continue
            elapsed = (stamp_dt - anchor_dt).total_seconds()
            if elapsed >= window_secs:
                # children_sig (issue #235): the reports-only half of this
                # candidate's own signature, captured now (the same children
                # list just used above) so cmd_stall_recheck's forward-motion
                # clearing predicate has a baseline to compare a later,
                # freshly-recomputed children list against. Liveness (issue
                # #244) is probed AFTER this lock releases (the probe can
                # sleep; nothing may hold forward_motion_path()'s lock across
                # that), so this candidate is only staged here, not yet
                # queued to flip.
                at_window.append((rid, children, announced, signature, len(children),
                                   r.get("summary"), r.get("updated"), _children_signature(children)))

        if changed:
            write_json(forward_motion_path(), store)

    # Flip-time liveness probe (issue #244): a candidate that has genuinely
    # reached --window-secs is reprieved if any of its `working` children's
    # process trees (resolved via --pane-pids-stdin) shows a genuine CPU
    # spend over the sample window - deliberately _probe_cpu_delta only,
    # never _probe_execution, so a child merely parked on an idle armed
    # watcher (which always has a late-started descendant) cannot
    # short-circuit past branch (a) and read "alive" for free; see
    # _probe_cpu_delta's own docstring for why branch (a) is the wrong tool
    # for this question. Only `working` children are probed - a report
    # parked in review/blocked/stalled is supposed to be idle, and a
    # `review` member parked on its own live pr-watch would show genuine CPU
    # delta from that watcher's own polling too. `break` on the first
    # reprieving child - one live child is sufficient evidence, and the
    # probe is not cheap to run N times once it reaches its own sleep.
    #
    # Three known, narrower residual gaps, all self-correcting rather than
    # designed around: (1) _probe_cpu_delta sums cputime only over pids
    # present in BOTH samples, so a delegate whose spend is dominated by
    # short-lived tool subprocesses that start and exit inside the gap - the
    # same fork-churn shape issue #244's own reproduction used - has no
    # remaining evidence in its favor here, since branch (a) is deliberately
    # excluded; (2) this probe widens the pre-existing TOCTOU window between
    # reading `children` above and this candidate's actual current state - a
    # concurrent genuine change is caught by the re-check against
    # (episode_announced, signature) just below, but a change that lands
    # AFTER that re-check is not; (3) a reprieve resets the anchor rather
    # than merely skipping one poll, so a delegate that burns CPU
    # indefinitely without its roster signature ever otherwise changing
    # reprieves its lead forever - this is the fix issue #244 asked for, not
    # a defect, and a lead genuinely wedged underneath such a delegate stays
    # covered by that DELEGATE's own wedge-check, not lost. All three are
    # bounded the same way the "Known, accepted false positive" above
    # already is: a spurious flip here still clears on the candidate's own
    # next crew-set call, or via cmd_stall_recheck's children_sig baseline.
    to_flip = []
    for rid, children, announced, signature, n_reports, prior_summary, updated_snapshot, children_sig in at_window:
        reprieved = False
        for c in children:
            if c.get("status") != "working":
                continue
            pid = pane_pids.get(c["id"])
            if pid and _probe_cpu_delta(pid, args.probe_gap, args.cpu_eps):
                reprieved = True
                break
        if reprieved:
            with with_locked(forward_motion_path()):
                store2 = read_json(forward_motion_path(), {})
                cur = store2.get(rid) if isinstance(store2, dict) else None
                # Re-check the SAME episode/signature we evaluated above - a
                # concurrent genuine reported-state change already reset this
                # entry between the two locks and must not be clobbered by a
                # now-stale reprieve.
                if isinstance(cur, dict) and cur.get("episode_announced") == announced \
                        and cur.get("signature") == signature:
                    store2[rid] = {"episode_announced": announced, "signature": signature, "since": now()}
                    write_json(forward_motion_path(), store2)
            continue
        to_flip.append((rid, n_reports, prior_summary, updated_snapshot, children_sig))

    for rid, n_reports, prior_summary, updated_snapshot, children_sig in to_flip:
        status_file = status_path(rid)
        with with_locked(status_file):
            current = read_json(status_file, None)
            if (not isinstance(current, dict) or current.get("status") != "working"
                    or current.get("updated") != updated_snapshot):
                continue
            live = current

            reason = (
                "no forward motion for over %s despite %d active report(s) - status, "
                "summary, and every report's own status/announced have been unchanged "
                "the whole time. Inspect with `bin/crew-takeover %s` or resume it with "
                "`bin/crew-say %s <nudge>`."
                % (_human_duration(window_secs), n_reports, rid, rid)
            )
            prior = (prior_summary or "").split("\n")[0][:80]
            if prior:
                reason += " (last summary: %s)" % prior

            _impose_stall(rid, status_file, live, "forward-motion", reason,
                           extra={"children_sig": children_sig})

        with with_locked(crew_json_path()):
            roster = load_roster()
            for r in roster:
                if r.get("id") == rid:
                    r["status"] = "stalled"
                    r["updated"] = live["updated"]
            write_json(crew_json_path(), roster)
        render_board()
        print("stalled %s" % rid)


def _valid_stall(stall):
    """Whole-object validation gating cmd_stall_recheck (issue #235) - guard
    #1 of the governing fail-closed invariant. True iff `stall` is a dict,
    its `source` is one of the three known detectors, `since` parses, and
    `prev_status` is a status a revert could legally restore. Anything else
    (absent, malformed, or a legacy 'stalled' record flipped before this
    feature shipped, so with no `stall` object at all) makes the record
    UNREVERTABLE by this mechanism - it exits the same way it always did:
    the member's own next self-report (cmd_crew_set), or a human via
    bin/crew-takeover/bin/crew-standdown. Checked once, up front, before any
    evidence is even read - a record that fails this is never touched, no
    streak started, no write made."""
    return (
        isinstance(stall, dict)
        and stall.get("source") in ("liveness", "wedge", "forward-motion")
        and _parse_updated(stall.get("since")) is not None
        and stall.get("prev_status") in ("working", "blocked")
    )


def _stall_contradicted(stall, pane_changed, pane_pid, root_grace, cid):
    """True iff the evidence THIS stall's own imposing detector would use to
    flip again no longer supports the classification (issue #235) - guard #2
    of the governing fail-closed invariant, dispatching on stall['source'].
    The caller (cmd_stall_recheck) has already validated the whole object via
    _valid_stall before this is ever called.

    Every branch is written evidence-first: it returns False - 'not
    contradicted' - the instant the evidence it needs is missing, malformed,
    or unreadable, rather than treating that absence as a reason to revert.
    A false 'not contradicted' costs one extra poll of latency (self-
    correcting); a false 'contradicted' reverts the record AND rewrites
    `updated`, closing the detector's own re-flip gate for a full
    WM_WEDGE_SECS/WM_FORWARD_MOTION_SECS (30 minutes by default) - see the
    plan's "The governing invariant: fail closed" for why this asymmetry
    makes fail-open unacceptable here even as a rare edge case.

    source == 'liveness': contradicted iff `pane_changed` (the caller's own
    PANE_STABLE-derived snapshot - never absent) OR
    _longest_running_descendant(pane_pid, root_grace) is not None. Both terms
    are POSITIVE evidence of life, so this branch needs no extra guard: an
    unreadable/pid-0 process tree makes _longest_running_descendant return
    None on its own (already 'not contradicted'), never something that reads
    as 'dead'.

    source == 'wedge': contradicted iff `_ps_tree(pane_pid)` is non-empty AND
    the recorded `wedge_pid` is absent from it. The non-emptiness check is
    the fail-closed guard and is load-bearing: an EMPTY tree is what
    `--pane-pid 0`, an unreadable `ps`, or a momentarily unresolvable pane
    all look like, and none of them may ever be read as 'the wedging process
    is gone' - _ps_tree returns {} for all three, indistinguishable from a
    genuinely dead tree, which is exactly why membership alone (the naive,
    fail-open spelling) is wrong. A `stall` with no integer `wedge_pid` is
    not contradicted at all - there is no recorded process to look for.

    source == 'forward-motion': contradicted iff the roster read is
    trustworthy AND `children_sig` was recorded AND the freshly recomputed
    live-children signature differs from it. Two guards: a `stall` with no
    `children_sig` is never contradicted (no baseline). And - the subtle
    one - `load_roster()` returns [] both for a candidate whose every report
    has genuinely finished (real forward motion) AND for an unreadable/
    truncated crew.json (indistinguishable from the former by emptiness
    alone) - so the discriminator is not 'are there zero live children' but
    'is cid ITSELF present in this roster read'. If the roster does not even
    contain the record being rechecked, the read is untrustworthy and this
    returns False; if it does, an empty live-children list is genuine.

    Unknown/absent `source` (defensive only - the caller already rejects
    this via _valid_stall): never contradicted."""
    source = stall.get("source")

    if source == "liveness":
        if pane_changed:
            return True
        return _longest_running_descendant(pane_pid, root_grace) is not None

    if source == "wedge":
        wedge_pid = stall.get("wedge_pid")
        if not isinstance(wedge_pid, int):
            return False
        tree = _ps_tree(pane_pid)
        if not tree:
            return False
        return wedge_pid not in tree

    if source == "forward-motion":
        children_sig = stall.get("children_sig")
        if not isinstance(children_sig, str):
            return False
        roster = load_roster()
        if not any(r.get("id") == cid for r in roster):
            return False
        children = []
        for r in roster:
            if parent_of(r) != cid:
                continue
            m = merged(r)
            if m.get("status") in LIVE_STATES:
                children.append(m)
        return _children_signature(children) != children_sig

    return False


_STALL_CLEAR_EVIDENCE = {
    "liveness": "its pane is repainting again and/or its process tree holds a late-started descendant",
    "forward-motion": "at least one of its reports has changed state",
}


def _stall_clear_evidence(stall):
    """The per-source evidence phrase for cmd_stall_recheck's clear reason
    text (see "The revert" in the plan for the exact three wordings). wedge
    is composed here (it needs the recorded pid), the other two are a plain
    lookup."""
    source = stall.get("source")
    if source == "wedge":
        return ("the foreground process (pid %s) that wedged it is gone from "
                "its pane's process tree" % stall.get("wedge_pid"))
    return _STALL_CLEAR_EVIDENCE.get(source, "")


def cmd_stall_recheck(args):
    """Re-evaluate a 'stalled' record against ONLY the evidence its own
    imposing detector recorded at flip time (issue #235): before this,
    'stalled' was a one-way latch - nothing ever re-ran the probe that
    produced it, so a member that resumed activity stayed flagged until a
    human noticed. Dispatches via _stall_contradicted on stall['source'] so a
    wedge-stalled (#202) or forward-motion-stalled (#199) member - both of
    which have a live process tree BY CONSTRUCTION - can never be cleared by
    a uniform liveness check; only its OWN evidence can clear it. See the
    plan's "The central principle" for why a naive uniform liveness revert
    would silently delete both of those mechanisms outright.

    Whole-object validation (_valid_stall) gates everything up front: an
    absent or malformed `stall` object - including a pre-migration 'stalled'
    record flipped before this feature shipped, so with no `stall` object at
    all - is never reverted by any number of calls; see "Migration".

    A single contradicting poll never reverts. `stall.clear_polls` increments
    on each consecutive contradicting poll and is deleted the moment a poll
    agrees with the classification again; the revert fires once it reaches
    max(2, --confirmations) - the floor is HARD-CLAMPED in code, not merely
    defaulted, because a watcher's very first poll for any member always
    reads PANE_STABLE=0 (no prior hash), which reads as pane_changed - a
    --confirmations of 1 would let every watcher restart clear every
    liveness stall. See the plan's "The confirmation gate".

    The evidence probe (a process-tree walk, a roster read) runs OUTSIDE the
    status-file lock - it can take a moment - then the actual read-modify-
    write re-validates status/stall.since fresh under with_locked(status_
    path(cid)), the identical TOCTOU guard every flip site already uses, so
    a self-report landing in between always wins over a stale nomination.

    On a revert: status/summary/blocker are restored from the stall object's
    own prev_* triple - `blocker` losslessly, even though a wedge flip
    cleared the FIELD (the TEXT survived in `prev_blocker`). `announced`
    advances ONLY when prev_status == 'blocked' (a genuinely open question
    nobody answered re-surfaces exactly once through the ordinary
    needs-attention path); reverting to 'working' leaves `announced`
    untouched, since 'working' is not an ATTENTION_STATE and the record
    simply drops off needs-attention with no wake possible - the silence is
    structural, not something this function has to suppress. This is
    deliberately silent on the wake channel: an auto-clear corrects the
    supervisor's OWN prior conclusion, so it owes nobody a notification - the
    caller (bin/watch-fleet) logs this call's stdout to stall-recheck.log and
    fires nothing. See the plan's "The revert".

    Prints '<id> <source> cleared after <N> polls' on a revert - exactly the
    three fields the call site's log line and the E2E test consume - nothing
    otherwise. Idempotent and safe to call every poll for every 'stalled'
    member."""
    ensure_home()
    cid = args.id
    status_file = status_path(cid)
    live = read_json(status_file, None)
    if not isinstance(live, dict) or live.get("status") != "stalled":
        return
    stall = live.get("stall")
    if not _valid_stall(stall):
        return
    since_snapshot = stall["since"]

    contradicted = _stall_contradicted(stall, args.pane_changed, args.pane_pid, args.root_grace, cid)
    confirmations = max(2, args.confirmations)

    with with_locked(status_file):
        current = read_json(status_file, None)
        if not isinstance(current, dict) or current.get("status") != "stalled":
            return
        cur_stall = current.get("stall")
        if not _valid_stall(cur_stall) or cur_stall.get("since") != since_snapshot:
            return  # the record moved under us since the snapshot above - a fresh flip, not this one

        if not contradicted:
            if "clear_polls" in cur_stall or "clear_since" in cur_stall:
                cur_stall.pop("clear_polls", None)
                cur_stall.pop("clear_since", None)
                current["stall"] = cur_stall
                write_json(status_file, current)
            return

        polls = cur_stall.get("clear_polls", 0) + 1
        if polls < confirmations:
            cur_stall["clear_polls"] = polls
            cur_stall.setdefault("clear_since", now())
            current["stall"] = cur_stall
            write_json(status_file, current)
            return

        # Confirmed across `confirmations` consecutive contradicting polls - revert.
        source = cur_stall["source"]
        prev_status = cur_stall["prev_status"]
        stamp = now()
        since_dt = _parse_updated(cur_stall["since"])
        stamp_dt = _parse_updated(stamp)
        age = (stamp_dt - since_dt).total_seconds() if since_dt is not None and stamp_dt is not None else 0

        clear_reason = (
            "'stalled' auto-cleared by the supervisor's own re-probe: %s, sustained "
            "across %d consecutive polls. The classification was imposed %s ago by "
            "%s and is no longer supported by the evidence that produced it."
            % (_stall_clear_evidence(cur_stall), polls, _human_duration(age), source)
        )
        prev_summary = cur_stall.get("prev_summary")
        if prev_summary:
            clear_reason += " (last self-reported summary: %s)" % prev_summary

        current["status"] = prev_status
        current["summary"] = clear_reason
        current["blocker"] = cur_stall.get("prev_blocker")
        current["updated"] = stamp
        if prev_status == "blocked":
            current["announced"] = stamp
        current.pop("stall", None)
        write_json(status_file, current)

    with with_locked(crew_json_path()):
        roster = load_roster()
        for r in roster:
            if r.get("id") == cid:
                r["status"] = prev_status
                r["updated"] = stamp
        write_json(crew_json_path(), roster)
    render_board()
    print("%s %s cleared after %d polls" % (cid, source, polls))


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
#
# Underneath that per-run store sits a second, persistent layer: the `[prefs]`
# table of wingman's settings file (config.local.toml, read by
# bin/lib/wm_config.py). A pilot who has answered a preference there is never
# asked it again, on this run or any future one, because every reader below sees
# a file-provided answer exactly as if it had just been cached - which is what
# makes the preferences guard stop gating, the nudge stop nudging, and /prefs
# stop asking, with no change to any of them. The per-run store still wins on
# top, so an answer given interactively mid-run (/prefs) overrides the file for
# the rest of that run without editing it.
def _config_prefs():
    """The settings file's `[prefs]` table, or {} when there is no file, no
    table, or the file is unusable.

    A broken settings file must never brick the state engine, so it degrades to
    "no file-provided answers" - which leaves those preferences unanswered and
    makes wingman ask, the conservative direction. `bin/config` and `bin/doctor`
    are where a malformed file gets reported loudly.
    """
    if wm_config is None:
        return {}
    try:
        return wm_config.prefs()
    except Exception:
        return {}


def _pref_layers(run_id):
    """`(file_prefs, run_prefs)` - the two layers _load_prefs merges, kept apart
    for the callers that must report WHICH one an answer came from (prefs-list
    --with-source, and through it hooks/lib/pilot-prefs.sh and bin/config).

    run_prefs falls back to the pre-#85 legacy shape ({"wingman_run_id": ...,
    "prefs": {...}}) so a file not yet migrated by a pref-set call still answers
    correctly for the run id it names.
    """
    data = read_json(preferences_path(), None)
    run_prefs = {}
    if isinstance(data, dict):
        if run_id in data:
            slot = data.get(run_id)
            run_prefs = slot if isinstance(slot, dict) else {}
        elif (data.get("wingman_run_id") == run_id
              and isinstance(data.get("prefs"), dict)):
            run_prefs = data["prefs"]
    return _config_prefs(), run_prefs


def _load_prefs(run_id):
    """The effective preference answers for run_id - the settings file's
    `[prefs]` table with this run's own cached answers layered on top - or None
    when neither layer has answered anything at all."""
    file_prefs, run_prefs = _pref_layers(run_id)
    if not file_prefs and not run_prefs:
        return None
    merged = dict(file_prefs)
    merged.update(run_prefs)
    return merged


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
    guard and nudge hooks - one subprocess, one file read, not N.

    --with-source appends a third column naming the layer each value came from:
    `run` for an answer cached during this run, `config.local.toml` for one the
    settings file supplied. hooks/lib/pilot-prefs.sh needs the distinction to
    validate a file-provided value against its key's vocabulary while leaving a
    pilot-given one alone (see its wm_prefs_missing); bin/config renders it.
    """
    file_prefs, run_prefs = _pref_layers(args.run_id)
    merged = dict(file_prefs)
    merged.update(run_prefs)
    for key in sorted(merged):
        if args.with_source:
            source = "run" if key in run_prefs else "config.local.toml"
            print("%s\t%s\t%s" % (key, merged[key], source))
        else:
            print("%s\t%s" % (key, merged[key]))


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
    state.

    The whole read-check-write runs under with_locked(ask_path(...)): a reply
    and an await watcher's ask-resolve (timeout/undeliverable) genuinely race,
    and without the lock a resolve that read `pending` could write its stale
    record back over a just-landed answer, destroying it. Same store-locking
    pattern as every other shared store here.

    A late reply to a request already resolved `timeout` is still accepted
    (recorded as answered with `late: true`): the delegate has already spent
    the turn authoring the answer, and refusing it would discard that work
    with no recovery path. The asker's await has already fired `unanswered`
    by then, so the refusal path below tells the delegate to also surface the
    answer over the ordinary channel."""
    ensure_home()
    path = ask_path(args.id)
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
    with with_locked(path):
        record = read_json(path, None)
        if not isinstance(record, dict):
            sys.exit("wm-state: no ask '%s'" % args.id)
        status = record.get("status")
        late = False
        if status == "timeout":
            late = True
        elif status != "pending":
            sys.exit("wm-state: ask '%s' is already %s, not open for a reply. "
                     "Your answer was NOT recorded - surface it to the asker over "
                     "the ordinary channel instead (e.g. crew-say '%s')."
                     % (args.id, status, record.get("from") or "wingman"))
        if args.responder != record.get("to"):
            sys.exit("wm-state: responder '%s' is not the addressed delegate '%s' "
                     "for ask '%s' (a reply must come from the delegate that was asked)"
                     % (args.responder, record.get("to"), args.id))
        record["status"] = "answered"
        record["answer"] = args.answer
        record["answer_file"] = answer_file
        record["responder"] = args.responder
        record["answered"] = now()
        if late:
            record["late"] = True
        write_json(path, record)
    if late:
        print("%s (late: the asker's wait already timed out - also surface this "
              "answer to '%s' over the ordinary channel, e.g. crew-say, so it is "
              "actually seen)" % (args.id, record.get("from") or "wingman"))
    else:
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
    status (the request's current status if it was already closed).

    The compare-and-set is made real by with_locked(ask_path(...)): without the
    lock, a resolve that read `pending` could race a landing reply and write
    `timeout` over the answered record, destroying the answer."""
    ensure_home()
    path = ask_path(args.id)
    with with_locked(path):
        record = read_json(path, None)
        if not isinstance(record, dict):
            sys.exit("wm-state: no ask '%s'" % args.id)
        if record.get("status") == "pending":
            record["status"] = args.status
            record["answered"] = now()
            if args.note:
                record["note"] = args.note
            write_json(path, record)
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
    """'47s' / '22m' / '1h5m' - short, human-scale duration, used across the
    nudge/long-shell annotations, the wedge/forward-motion/review-resurface
    reason text, and cmd_stall_recheck's own clear reason and age
    annotation (_stalled_annotation). The only definition in the module -
    an earlier, shadowed duplicate at what was line 2472 (coarsest-exact-
    unit only, no callers actually reached it since a later definition of
    the same name always wins at call time) was removed rather than kept
    as a second source of truth."""
    seconds = max(0, int(seconds))
    if seconds < 60:
        return "%ds" % seconds
    minutes = seconds // 60
    if minutes < 60:
        return "%dm" % minutes
    hours, minutes = divmod(minutes, 60)
    return "%dh%dm" % (hours, minutes) if minutes else "%dh" % hours


def _stall_annotation(r):
    """Short parenthetical suffix for a crew member's status cell (#155): a
    self-heal nudge already sent and still within its cooldown window (fix
    1), and/or a single outstanding tool call/background shell that has been
    running far longer than usual (fix 2). Both are purely informational -
    they never change the status value itself.

    The two halves are gated DIFFERENTLY, on purpose. Fix 1 (the nudge
    annotation) stays 'working'-only, unchanged: only cmd_stall_check ever
    stamps `nudged_at`, and it only ever nudges a 'working' member, so a
    'blocked' record showing it would only ever be leftover/synthetic state,
    never a live nudge episode. Fix 2 (the long-shell annotation) is WIDENED
    to 'working' OR 'blocked' by issue #202, since `_track_long_running` now
    maintains `long_shell_pid`/`long_shell_elapsed` for both statuses (see its
    own docstring) - a CONTRACT CHANGE, not a pure extension: this half used
    to be a strict subset of 'working' status, and is now also a strict
    subset of 'blocked'. This means the SAME long-shell annotation now
    renders next to every 'blocked' member holding a qualifying long-running
    descendant - most commonly a lead whose own watch-fleet cycle is
    correctly armed as a background task and has simply been blocking on a
    quiet crew for a while (WM_LONG_SHELL_WARN's default 1200s ceiling is far
    shorter than a routine parked wait). This is EVIDENCE, not a wedge
    indicator: it is exactly the duration signal that, alone, cannot
    discriminate a wedge from a healthy backgrounded watcher (see
    docs/plans/2026-08-03-issue-202-foreground-watcher-wedge-plan.md, section
    2.6, conclusion 2) - the actual wedge indicator is the 'stalled' flip
    wm_state wedge-check performs, which additionally requires continuous
    pane liveness. Read this annotation as "something has been running a
    while", never as "this member is wedged". Returns "" when neither half
    applies, and unconditionally for any status other than 'working'/
    'blocked' (nudged_at/long_shell_* can briefly outlive either in the
    record, e.g. between a stalled flip and the next render, but any OTHER
    status is never annotated) - EXCEPT 'stalled' itself, which gets its own
    dedicated annotation via _stalled_annotation (issue #235): the gate below
    is restructured, not widened, so these two existing halves stay exactly
    as they were for 'working'/'blocked'."""
    if r.get("status") == "stalled":
        return _stalled_annotation(r)
    if r.get("status") not in ("working", "blocked"):
        return ""
    parts = []
    nudged_at = r.get("nudged_at")
    if r.get("status") == "working" and nudged_at:
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


def _stalled_annotation(r):
    """Short parenthetical suffix for a 'stalled' status cell (issue #235).
    Unlike _stall_annotation's two halves above, the first half here is
    ALWAYS shown, not gated on anything: `flagged <duration> ago`, anchored
    on stall.since - or, for a pre-migration record with no `stall` object at
    all (see "Migration"), falling back to the record's own `updated`. This
    half needs no probe and no live watcher to be correct: it renders
    straight from whatever is already on disk, which is exactly what makes
    it trustworthy even for a fleet whose watcher has itself died - precisely
    when a stale classification is most likely to mislead a pilot glancing at
    the board.

    The second half - `showing activity for <duration> - classification may
    be stale` - appears only while cmd_stall_recheck has a recovery streak in
    progress (stall.clear_since is set), i.e. the classification has been
    CONTRADICTED at least once but not yet for enough consecutive polls to
    auto-revert. This is the render-side half of the R6 mitigation the plan
    documents: a pilot about to act on a stale 'stalled' report sees the
    warning before attaching, rather than discovering after the fact that the
    member had already recovered."""
    stall = r.get("stall")
    since = (stall or {}).get("since") or r.get("updated")
    parts = []
    since_dt = _parse_updated(since)
    if since_dt is not None:
        age = (datetime.datetime.now(datetime.timezone.utc) - since_dt).total_seconds()
        if age >= 0:
            parts.append("flagged %s ago" % _human_duration(age))
    if isinstance(stall, dict):
        clear_since_dt = _parse_updated(stall.get("clear_since"))
        if clear_since_dt is not None:
            clear_age = (datetime.datetime.now(datetime.timezone.utc) - clear_since_dt).total_seconds()
            if clear_age >= 0:
                parts.append("showing activity for %s - classification may be stale" % _human_duration(clear_age))
    if not parts:
        return ""
    return " (%s)" % "; ".join(parts)


def _died_annotation(r):
    """' (resumable)' for a `died` member whose Claude Code session transcript
    still exists on disk (issue #251) - a bare `died` status otherwise reads
    as a dead end even when `claude --resume <session_id>` would recover it
    in full, independent of whether the worktree survived. "" for every other
    status, and for a died member whose transcript is genuinely gone."""
    if r.get("status") != "died":
        return ""
    return " (resumable)" if is_resumable(r) else ""


def render_roster_text(rows):
    if not rows:
        return "(no crew)"
    lines = []
    for r in rows:
        line = "  [%-10s] %-22s %-9s %s%s" % (
            r.get("type", "?"), r.get("id", "?"), r.get("status", "?") + _stall_annotation(r) + _died_annotation(r),
            (r.get("summary") or "").split("\n")[0][:60], _git_suffix(r),
        )
        lines.append(line)
        if r.get("status") == "blocked" and r.get("blocker"):
            lines.append("      blocker: %s" % r["blocker"])
        if r.get("parked"):
            for p in r["parked"]:
                lines.append("      parked[%s]: %s" % (p.get("ref", "?"), p.get("note", "")))
        if r.get("delivery"):
            lines.append("      delivery: %s" % r["delivery"])
        if r.get("artifact_url"):
            lines.append("      artifact-url: %s" % r["artifact_url"])
        if r.get("wip_ref_sha"):
            lines.append("      wip-ref: refs/wip/%s (%s)" % (_sanitize_id(r.get("id", "")), r["wip_ref_sha"]))
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
            indent, r.get("type", "?"), r.get("id", "?"), r.get("status", "?") + _stall_annotation(r) + _died_annotation(r),
            (r.get("summary") or "").split("\n")[0][:50],
        )
        lines.append(line.rstrip())
        if r.get("status") == "blocked" and r.get("blocker"):
            lines.append("%s    blocker: %s" % (indent, r["blocker"]))
        if r.get("parked"):
            for p in r["parked"]:
                lines.append("%s    parked[%s]: %s" % (indent, p.get("ref", "?"), p.get("note", "")))
        if r.get("delivery"):
            lines.append("%s    delivery: %s" % (indent, r["delivery"]))
        if r.get("artifact_url"):
            lines.append("%s    artifact-url: %s" % (indent, r["artifact_url"]))
        if r.get("wip_ref_sha"):
            lines.append("%s    wip-ref: refs/wip/%s (%s)" % (indent, _sanitize_id(r.get("id", "")), r["wip_ref_sha"]))
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
        out.append("| type | id | status | window | repo | summary | blocker | parked | delivery | artifact-url |")
        out.append("|---|---|---|---|---|---|---|---|---|---|")
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
            parked_cell = "; ".join(
                "[%s] %s" % (p.get("ref", "?"), p.get("note", "")) for p in (r.get("parked") or [])
            )
            out.append("| %s | %s%s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
                r.get("type", ""), marker, id_cell, r.get("status", "") + _stall_annotation(r),
                r.get("window", ""), repo_cell,
                _cell(r.get("summary")), _cell(r.get("blocker")), _cell(parked_cell), _cell(r.get("delivery")),
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
                r.get("type", ""), r.get("id", ""), r.get("status", "") + _died_annotation(r), _cell(r.get("delivery")),
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
    # Roster-only (issue #251, review round 1, nice-to-have 3): a successful
    # bin/crew-resume clears a died member's WIP-anchor pointer/error, since
    # both describe a death that is now over - a live `working` member should
    # not keep rendering `wip-ref: refs/wip/<id> (<sha>)` for a crash it just
    # recovered from.
    a.add_argument("--clear-wip-anchor", action="store_true", dest="clear_wip_anchor")
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
    # Per-issue blocking (#203): park a unit needing a decision without flipping
    # this record's own status - see cmd_crew_set's parked-mutation block.
    a.add_argument("--park", action="append", default=None,
                    help="park a unit needing a decision: 'ref:note' (repeatable)")
    a.add_argument("--unpark", action="append", default=None,
                    help="clear a parked unit by ref (repeatable)")
    a.add_argument("--parked-clear", action="store_true", dest="parked_clear")
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
    # Per-issue blocking (#203): show only records with one or more parked
    # items, regardless of status - a record can be working or blocked and
    # still carry parked items. Status-independent by design; does not compose
    # with --status/--active in the same call.
    a.add_argument("--parked", action="store_true")
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
    # 1 iff the watcher's persisted refused-nudge counter for this candidate
    # (bin/watch-fleet's stall-<id>.nudge-refused sidecar) has reached
    # WM_NUDGE_REFUSED_MAX (issue #214, §3.6): a check-in nudge that a busy,
    # dialog-shaped, or lock-contended pane refuses outright must not exempt
    # the member from stall escalation forever, so the watcher stamps the
    # ordinary nudged marker anyway once the refusal count crosses the max
    # (without --just-nudged - nothing was actually delivered) and passes
    # this flag on EVERY poll from then on, derived fresh from the persisted
    # counter each time, not only on the poll that stamped it - the poll that
    # stamps is never the poll that flips (--nudge-age must still age past
    # --threshold first), so a flag set only at stamping time would never be
    # set on the flipping poll.
    a.add_argument("--nudge-undelivered", type=int, default=0, dest="nudge_undelivered")
    # #236: 1 (default) iff the age reported by --nudge-age comes from a
    # CONFIRMED nudge's cooldown clock; 0 iff it instead comes from a 'pending'
    # marker that exhausted its retry budget without ever confirming a submit.
    # Changes only which reason template a genuine stall is written with -
    # never the gates or probe above - exactly like --api-error. Defaults to 1
    # so every pre-#236 caller (and every existing test) keeps today's wording.
    # Ignored when --nudge-undelivered is set (that check runs first).
    a.add_argument("--nudge-confirmed", type=int, default=1, dest="nudge_confirmed")
    # #236: display-only count of composer-leaving nudge attempts (rc 3/5),
    # rendered into the unconfirmed reason templates so the operator sees how
    # many times a submit was attempted, not just that one was.
    a.add_argument("--nudge-attempts", type=int, default=0, dest="nudge_attempts")
    a.set_defaults(fn=cmd_stall_check)

    # Read-only exposure of cmd_stall_check's own branch-(a) proof-of-life
    # probe (issue #234), so bin/watch-fleet can ask the same question BEFORE
    # typing a check-in nudge into a pane, not only afterwards via stall-check.
    a = sub.add_parser("liveness-probe")
    a.add_argument("--pane-pid", type=int, required=True, dest="pane_pid")
    a.add_argument("--root-grace", type=int, default=30, dest="root_grace")
    a.set_defaults(fn=cmd_liveness_probe)

    # Foreground-watcher wedge detection (issue #202, layer B): flips a
    # 'working' OR 'blocked' member to 'stalled' once its pane has repainted
    # continuously (never idle at a prompt) for --threshold seconds of
    # genuinely observed coverage, its own record has gone unwritten for the
    # same window, and a --proc-re-matching descendant has itself been
    # running that long. Called per member per bin/watch-fleet poll, ABOVE
    # the blocked skip (see the call site comment in bin/watch-fleet) - see
    # cmd_wedge_check's own docstring for the full design.
    a = sub.add_parser("wedge-check")
    a.add_argument("--id", required=True)
    a.add_argument("--pane-idle", type=int, required=True, dest="pane_idle")
    a.add_argument("--pane-pid", type=int, required=True, dest="pane_pid")
    a.add_argument("--root-grace", type=int, required=True, dest="root_grace")
    a.add_argument("--threshold", type=int, required=True)
    a.add_argument("--pane-gap", type=int, required=True, dest="pane_gap")
    # Overridable via WM_WEDGE_PROC_RE (read directly by cmd_wedge_check when
    # this is omitted) so an operator can widen the instrument without a code
    # change - see the plan's "Residual gap" risk.
    a.add_argument("--proc-re", default=None, dest="proc_re")
    a.set_defaults(fn=cmd_wedge_check)

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

    # Bounded resurface for a `review` member with no live dependency watcher
    # (issue #187). Called every bin/watch-fleet iteration, owner-scoped like
    # needs-attention; only ever fires (writes review-resurfaced.json) once
    # --window-secs has elapsed for a given id with no fresh pr-watch beacon.
    a = sub.add_parser("review-resurface-check")
    a.add_argument("--owner", default=None)
    a.add_argument("--window-secs", type=int, default=21600, dest="window_secs")  # 6h, generous default
    a.add_argument("--waker-grace", type=int, default=120, dest="waker_grace")
    a.set_defaults(fn=cmd_review_resurface_check)

    # Structural forward-motion / logical-stall detection (issue #199, Gap
    # B): flips a WORKING candidate with active reports to 'stalled' once its
    # own roster-shape signature has shown no change for --window-secs, even
    # with a fully healthy, armed watcher cycle. Called every bin/watch-fleet
    # iteration BY THE CANDIDATE'S OWN PARENT's cycle (see
    # cmd_forward_motion_check's own docstring for why) - --owner "" is
    # wingman's own top-level cycle, examining its own direct reports as
    # candidates. Liveness-aware since issue #244: once a candidate reaches
    # --window-secs, its working children's pane pids (from
    # --pane-pids-stdin) are probed via _probe_cpu_delta before flipping -
    # see cmd_forward_motion_check's own docstring. No --root-grace: that
    # parameter is _probe_execution's branch (a) alone, which this call path
    # never reaches.
    a = sub.add_parser("forward-motion-check")
    a.add_argument("--owner", default=None)
    a.add_argument("--window-secs", type=int, default=1800, dest="window_secs")  # 30 min default
    a.add_argument("--probe-gap", type=int, default=10, dest="probe_gap")
    a.add_argument("--cpu-eps", type=float, default=0.5, dest="cpu_eps")
    a.add_argument("--pane-pids-stdin", action="store_true", dest="pane_pids_stdin")
    a.set_defaults(fn=cmd_forward_motion_check)

    # The stalled re-evaluation (issue #235): re-runs the SAME detector's own
    # evidence recorded on a 'stalled' record's `stall` object at flip time
    # (see _stall_contradicted), and reverts the record only on a sustained
    # (--confirmations, hard-floored to 2) contradiction. Called once per
    # member per bin/watch-fleet poll, immediately before the
    # `review|stalled) continue` that used to make 'stalled' a one-way latch.
    # --pane-pid 0 is a valid, deliberate "cannot tell" (a pane whose pid did
    # not resolve this poll), not an error - every branch of
    # _stall_contradicted must still answer correctly for it.
    a = sub.add_parser("stall-recheck")
    a.add_argument("--id", required=True)
    a.add_argument("--pane-pid", type=int, default=0, dest="pane_pid")
    a.add_argument("--pane-changed", type=int, default=0, dest="pane_changed")
    a.add_argument("--root-grace", type=int, required=True, dest="root_grace")
    a.add_argument("--confirmations", type=int, default=2)
    a.set_defaults(fn=cmd_stall_recheck)

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
    a.add_argument("--with-source", action="store_true", dest="with_source",
                   help="append the layer each value came from "
                        "(run | config.local.toml)")
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
