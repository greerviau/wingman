#!/usr/bin/env python3
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""parse-open-questions: extract and validate a crew deliverable's structured
open-questions block.

Design: docs/plans/2026-07-14-structured-open-questions-convention.md. A crew
member (typically a `software-analyst`) may embed one fenced ```wingman-questions
code block under its deliverable's "Open Questions" heading, containing a small
JSON schema of closed-set (`choice`) and open-ended (`open`) decisions for the
requester. This script is the deterministic parser wingman runs against that
block INSTEAD OF reading the deliverable itself - the same "small script, not an
LLM re-read" shape as bin/lib/artifact-scan.sh.

Usage:
  uv run --no-project --quiet parse-open-questions.py <path>

Extraction is a plain regex over the raw file text, never a full markdown parse,
so a heading-wording mismatch or surrounding prose never affects the result -
the parser scans the whole file for the fenced tag regardless of which heading
(if any) it sits under.

Prints one JSON object to stdout and exits accordingly:
  {"found": false}                          - no fence found. exit 0. The
                                               common case for the bulk of
                                               plans and any deliverable with
                                               no closed-set decisions.
  {"found": true, "questions": [...]}        - fence found, schema-valid. exit 0.
  {"found": true, "error": "<reason>"}       - fence found, invalid. exit 1.
"""
import json
import re
import sys

FENCE_RE = re.compile(r"```wingman-questions\n(.*?)\n```", re.DOTALL)


def _validate_choice(q):
    """Return an error string, or None if q's 'choice' fields are valid."""
    options = q.get("options")
    if not isinstance(options, list) or not (2 <= len(options) <= 4):
        return "question %r: 'choice' requires 2-4 options" % q.get("id")
    recommended_count = 0
    for opt in options:
        if not isinstance(opt, dict):
            return "question %r: each option must be an object" % q.get("id")
        if "label" not in opt or "detail" not in opt:
            return "question %r: each option needs 'label' and 'detail'" % q.get("id")
        if opt.get("recommended"):
            recommended_count += 1
    if recommended_count != 1:
        return ("question %r: exactly one option must have 'recommended': true (found %d)"
                % (q.get("id"), recommended_count))
    return None


def _validate_open(q):
    """Return an error string, or None if q's 'open' fields are valid."""
    if "options" in q:
        return "question %r: type 'open' must not have an 'options' field" % q.get("id")
    return None


def parse(text):
    """Parse the wingman-questions fence out of text.

    Returns (result_dict, error_string). Exactly one of the two is None:
    error_string is set for any schema violation, result_dict otherwise.
    Caller has already confirmed the fence exists.
    """
    m = FENCE_RE.search(text)
    try:
        data = json.loads(m.group(1))
    except ValueError as e:
        return None, "malformed JSON in wingman-questions block: %s" % e

    if not isinstance(data, dict) or not isinstance(data.get("questions"), list):
        return None, "top-level must be an object with a 'questions' array"

    questions = data["questions"]
    if not (1 <= len(questions) <= 8):
        return None, "'questions' must have 1-8 entries (found %d)" % len(questions)

    seen_ids = set()
    for q in questions:
        if not isinstance(q, dict):
            return None, "each question must be an object"
        qid = q.get("id")
        if not qid or not isinstance(qid, str):
            return None, "every question needs a non-empty 'id'"
        if qid in seen_ids:
            return None, "duplicate question id: %r" % qid
        seen_ids.add(qid)
        if not q.get("question"):
            return None, "question %r: missing 'question' text" % qid

        qtype = q.get("type")
        if qtype == "choice":
            err = _validate_choice(q)
        elif qtype == "open":
            err = _validate_open(q)
        else:
            err = "question %r: unknown type %r (must be 'choice' or 'open')" % (qid, qtype)
        if err:
            return None, err

    return {"found": True, "questions": questions}, None


def main():
    if len(sys.argv) != 2:
        print(json.dumps({"found": True, "error": "usage: parse-open-questions.py <path>"}))
        sys.exit(1)

    path = sys.argv[1]
    try:
        with open(path, "r") as fh:
            text = fh.read()
    except OSError as e:
        print(json.dumps({"found": True, "error": "cannot read %s: %s" % (path, e)}))
        sys.exit(1)

    if not FENCE_RE.search(text):
        print(json.dumps({"found": False}))
        sys.exit(0)

    result, error = parse(text)
    if error:
        print(json.dumps({"found": True, "error": error}))
        sys.exit(1)

    print(json.dumps(result))
    sys.exit(0)


if __name__ == "__main__":
    main()
