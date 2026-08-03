"""denial_report_guard: shared implementation behind hooks/denial-report-guard.sh
(issue #214, Defect B's mechanical backstop). See that file's own header for
the full design and registration; this module holds the transcript-scanning,
denial-resolution, and dedup logic so it stays independently testable.

The harness stamps an exact, unambiguous field on a denied tool call -
`toolDenialKind` - so this needs zero heuristics over pane content, unlike
the pane-content detection issue #214 explicitly ruled out. `user-rejected`
is the one denial kind that carries no remedy of its own (a `permission-rule`
denial carries the denying hook's own text; `automode-blocked` carries "try
other tools ... if essential, STOP and explain to the user") and covers both
flavours a crew session can hit: a live interrupt of an in-flight tool call,
and an ungranted permission in an unattended session. Both are exactly the
"denied, and I have no documented path" case this hook exists to surface.

Fails open (returns None from run()) on any parse/IO problem, by design -
this gates ending a turn, not an action that must not happen, so a hook that
fails closed here would wedge every crew session's Stop indefinitely.
"""
import collections
import json
import os
import re


def _sanitize_id(cid):
    """Filesystem-safe form of a crew id, matching bin/lib/wm-state.py's own
    _sanitize_id / bin/lib/common.sh's `tr -c 'A-Za-z0-9._-' '_'` convention
    used for every other per-id sidecar file."""
    return re.sub(r"[^A-Za-z0-9._-]", "_", cid or "")


def _read_json_lines_tail(path, max_records):
    """The last (up to) max_records lines of a JSONL file, each parsed as
    JSON - read sequentially (bounded memory via a deque, not a bounded
    read) so a torn or malformed line anywhere in the file never sinks
    every other record; a line that fails to parse is simply skipped."""
    records = collections.deque(maxlen=max_records)
    try:
        with open(path, "r") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    records.append(json.loads(line))
                except ValueError:
                    continue
    except OSError:
        return []
    return list(records)


def _find_last_denial(records):
    """The most recent record (scanning from the end) whose own
    toolDenialKind == 'user-rejected'. None if none found in this tail."""
    for rec in reversed(records):
        if isinstance(rec, dict) and rec.get("toolDenialKind") == "user-rejected":
            return rec
    return None


def _denied_tool_use_id(record):
    """The tool_use_id the denial's own tool_result content names, if any."""
    msg = record.get("message") or {}
    for item in msg.get("content") or []:
        if isinstance(item, dict) and item.get("type") == "tool_result":
            tid = item.get("tool_use_id")
            if tid:
                return tid
    return None


def _resolve_denied_command(records, tool_use_id):
    """Find the matching tool_use record (it precedes the denial in the
    transcript) and describe the command it ran, or None if it cannot be
    resolved (a missing/rotated tool_use_id, or a tool with no obvious
    command-shaped input)."""
    if not tool_use_id:
        return None
    for rec in reversed(records):
        msg = rec.get("message") if isinstance(rec, dict) else None
        content = (msg or {}).get("content") if isinstance(msg, dict) else None
        for item in content or []:
            if not (isinstance(item, dict) and item.get("type") == "tool_use"
                    and item.get("id") == tool_use_id):
                continue
            name = item.get("name") or "a tool"
            tool_input = item.get("input") or {}
            cmd = tool_input.get("command") if isinstance(tool_input, dict) else None
            return "%s: %s" % (name, cmd) if cmd else name
    return None


def _record_text(rec):
    """Flatten a record's assistant text content (if any) into one string,
    for the interrupt-signature substring check below."""
    if not isinstance(rec, dict):
        return ""
    msg = rec.get("message") or {}
    content = msg.get("content") if isinstance(msg, dict) else None
    if isinstance(content, str):
        return content
    out = []
    for item in content or []:
        if isinstance(item, dict) and item.get("type") == "text":
            out.append(item.get("text") or "")
    return "\n".join(out)


def _was_interrupt(records, denial_record):
    """True iff the denial is followed (within the tail already read) by the
    harness's own interrupt marker - a record carrying interruptedMessageId,
    or the literal text '[Request interrupted by user for tool use]' (the
    exact signature the incident's own reproduction recorded, one
    millisecond after the denial). False - an ungranted permission - if
    neither is found before the tail ends."""
    seen_denial = False
    for rec in records:
        if rec is denial_record:
            seen_denial = True
            continue
        if not seen_denial or not isinstance(rec, dict):
            continue
        if rec.get("interruptedMessageId"):
            return True
        if "interrupted by user" in _record_text(rec):
            return True
    return False


def _block_reason(command_desc, was_interrupt):
    flavor = ("a live interrupt of an in-flight tool call" if was_interrupt
              else "an ungranted permission in this unattended session")
    cmd_clause = ("`%s`" % command_desc) if command_desc else "a tool call"
    return (
        "%s was denied (%s) and no rule anywhere tells you what to do about "
        "it. The harness's own denial text (\"...STOP what you are doing and "
        "wait for the user to tell you how to proceed\") is written for an "
        "attended, interactive session; a crew session is never attended "
        "that way, so report `blocked` NOW with the literal command and the "
        "literal denial text as the blocker - unless you already recovered, "
        "in which case say so in your status summary and stop again. Never "
        "silently retry it or work around it, and never ask about it into "
        "your own pane and wait - nobody is watching your pane. This is a "
        "fallback, not an override: where your own playbook already "
        "documents a specific remedy for this exact denial, follow that "
        "instead."
        % (cmd_clause, flavor)
    )


def _seen_path(wm_home, crew_id):
    return os.path.join(wm_home, "denial-seen-%s.json" % _sanitize_id(crew_id))


def _already_seen(wm_home, crew_id, uuid):
    try:
        with open(_seen_path(wm_home, crew_id), "r") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return False
    return isinstance(data, dict) and data.get("uuid") == uuid


def _mark_seen(wm_home, crew_id, uuid):
    try:
        with open(_seen_path(wm_home, crew_id), "w") as fh:
            json.dump({"uuid": uuid}, fh)
    except OSError:
        pass


def run(input_json, crew_id, wm_home, max_records=300):
    """Returns a dict to print as the Stop decision ({"decision": "block",
    "reason": ...}), or None to allow silently. See the module docstring for
    the fail-open posture."""
    try:
        payload = json.loads(input_json)
    except ValueError:
        return None
    if not isinstance(payload, dict):
        return None
    if payload.get("stop_hook_active"):
        return None

    transcript_path = payload.get("transcript_path")
    if not transcript_path or not isinstance(transcript_path, str):
        return None

    records = _read_json_lines_tail(transcript_path, max_records)
    if not records:
        return None

    denial = _find_last_denial(records)
    if denial is None:
        return None

    uuid = denial.get("uuid")
    if not uuid:
        return None
    if _already_seen(wm_home, crew_id, uuid):
        return None

    tool_use_id = _denied_tool_use_id(denial)
    command_desc = _resolve_denied_command(records, tool_use_id)
    was_interrupt = _was_interrupt(records, denial)

    _mark_seen(wm_home, crew_id, uuid)
    return {"decision": "block", "reason": _block_reason(command_desc, was_interrupt)}
