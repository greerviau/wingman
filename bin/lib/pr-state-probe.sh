#!/usr/bin/env bash
# pr-state-probe.sh - forge-verified terminal state for a single PR, the
# probe behind bin/watch-fleet's forge-terminal nudge: a `review` member
# whose PR merged or closed with nothing polling it on its behalf.
#
# Reads ONLY the PR's `state` (with `mergedAt` as a defensive cross-check) -
# never `reviews`, `comments`, `statusCheckRollup`, `mergeable`, or
# `mergeStateStatus`, and never any other approval evidence. A PR that is
# green, approved, and mergeable is `OPEN` here, produces no result, and is
# nobody's terminal condition - this keeps this path from ever becoming a
# second, weaker route past the review-evidence gate, because there is no
# approval evidence anywhere in it to be stale.
#
# Usage:
#   pr-state-probe.sh <pr-url>
# Prints exactly one token to stdout and always exits 0:
#   MERGED   - the forge reports the PR merged
#   CLOSED   - closed without merging
#   OPEN     - still open
#   unknown  - not a canonical PR URL, gh failed or is absent, or the
#              response did not parse
set -u
. "$(dirname "$0")/common.sh"
GH="${WM_GH:-gh}"

# Matches wm-state.py's own PR_URL_RE (bin/lib/wm-state.py) - the two are
# hand-maintained copies for the same reason bin/lib/merge-block-diagnose.py's
# own PR_URL_RE is: a bare script cannot import from another bare script.
# Keep them in lockstep by hand; a divergence is a bug.
PR_URL_RE='^https://github\.com/[^/[:space:]]+/[^/[:space:]]+/pull/[0-9]+/?$'

_url="${1:-}"

# Re-validate even though the caller already filters (defence in depth): a
# mismatch prints unknown WITHOUT invoking $GH at all.
if ! printf '%s\n' "$_url" | grep -qE "$PR_URL_RE"; then
  echo unknown
  exit 0
fi

if wm_have timeout; then
  _json="$(timeout 20 "$GH" pr view "$_url" --json state,mergedAt 2>/dev/null)"
else
  _json="$("$GH" pr view "$_url" --json state,mergedAt 2>/dev/null)"
fi
_rc=$?
if [ "$_rc" -ne 0 ] || [ -z "$_json" ]; then
  echo unknown
  exit 0
fi

printf '%s' "$_json" | wm_py -c '
import json, sys

try:
    d = json.load(sys.stdin)
except ValueError:
    print("unknown")
    sys.exit(0)

state = str(d.get("state") or "").upper()
# Defensive only: state=CLOSED with mergedAt is not a combination the forge
# currently produces (a merged PR reports state=MERGED), and both values are
# terminal here regardless - this exists so a forge or CLI whose enum ever
# did collapse the two could not silently downgrade a merge to a close.
if state == "CLOSED" and d.get("mergedAt"):
    state = "MERGED"

print(state if state in ("MERGED", "CLOSED", "OPEN") else "unknown")
'
