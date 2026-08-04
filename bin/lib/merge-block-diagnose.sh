#!/usr/bin/env bash
# merge-block-diagnose.sh - the agent-facing entry point for issue #190's
# forge-vs-wingman merge-gate diagnostic. Classifies a blocked PR merge as
# wingman's own gate objecting (hooks/no-merge-guard.sh), the forge's own
# branch ruleset/classic protection objecting, both, or neither - see
# docs/guards.md's "Two merge gates, not one" for the distinction this exists
# to make visible before an escalation is sent.
#
# This file holds no logic of its own: it sources common.sh (the one place
# uv resolution lives, via wm_py) and runs the sibling merge-block-diagnose.py,
# which carries all classification logic and is stdlib-only. python3 is
# optional on a supported wingman install (bin/doctor registers it as such -
# uv provides the interpreter), so a mechanically-delivered instruction (this
# hook's own denial text, a playbook's escalation step) must never bake in
# `python3 merge-block-diagnose.py` directly; it invokes this bare
# `$WINGMAN_BIN/lib/...` path instead, mirroring git-freshness-check.sh's own
# established shape.
#
# Usage:
#   merge-block-diagnose.sh --pr <PR URL> [--repo <owner>/<name>]
#                           [--crew-id <id>] [--help]
# See merge-block-diagnose.py's own --help for the full flag list, including
# the fixture-injection flags (--pr-json/--rules-json/--rulesets-json/
# --protection-json/--crew-record/--me) the test suite drives it with.
set -u
. "$(dirname "$0")/common.sh"
wm_py "$WM_LIB/merge-block-diagnose.py" "$@"
