#!/usr/bin/env bash
# E2E: a recycled crew id must not inherit stale sidecar files (issue #178).
# wm_state crew-derive-id disambiguates a candidate id slug against BOTH the
# live roster and the prune archive (crew.json only sees the former, so a
# pruned id was previously invisible and got handed out again) - all under
# one lock, in a single call, rather than the shell `while crew-get` loop
# bin/spawn-crew used to run (which shelled out twice and re-parsed the whole
# archive on every miss). Uses a stub agent (WM_AGENT) and an isolated tmux
# session for the end-to-end case, so no real agent launches and the live
# fleet is untouched.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SPAWN="$TEST_REPO/bin/spawn-crew"

test_new_home

# --- 1: no roster or archive entry -> base printed unchanged ------------------
id1="$(wm_state crew-derive-id --base fresh-slug)"
assert_eq "no collision prints the base unchanged" "$id1" "fresh-slug"

# --- 2: a roster entry matching the base -> base-2 (existing behavior) --------
wm_state crew-add --id roster-slug --type developer --objective x --repo /tmp \
  --window wm-roster-slug --session-id s1 >/dev/null
id2="$(wm_state crew-derive-id --base roster-slug)"
assert_eq "a live roster collision still derives base-2" "$id2" "roster-slug-2"

# --- 3: an archive-only entry (no roster entry) -> base-2 ---------------------
# This is the case that was previously invisible to the roster-only
# `crew-get` loop, and is the direct fix for issue #178.
wm_state crew-add --id archive-slug --type developer --objective x --repo /tmp \
  --window wm-archive-slug --session-id s2 >/dev/null
wm_state standdown --id archive-slug >/dev/null
n="$(wm_state prune)"
assert_eq "the fixture record was pruned (archived, removed from roster)" "$n" "1"
assert_false "the pruned id is no longer on the live roster" \
  "wm_state crew-get --id archive-slug >/dev/null 2>&1"
id3="$(wm_state crew-derive-id --base archive-slug)"
assert_eq "an archive-only collision now derives base-2, not the raw base" "$id3" "archive-slug-2"

# --- 4: archive entries for both base and base-2 -> base-3 --------------------
wm_state crew-add --id multi-slug   --type developer --objective x --repo /tmp \
  --window wm-multi-slug   --session-id s3 >/dev/null
wm_state crew-add --id multi-slug-2 --type developer --objective x --repo /tmp \
  --window wm-multi-slug-2 --session-id s4 >/dev/null
wm_state standdown --id multi-slug   >/dev/null
wm_state standdown --id multi-slug-2 >/dev/null
wm_state prune >/dev/null
id4="$(wm_state crew-derive-id --base multi-slug)"
assert_eq "both base and base-2 archived derives base-3" "$id4" "multi-slug-3"

# --- 5: a malformed archive line is skipped, not crashed -----------------------
# 5a: a malformed line that happens to contain the base as a raw substring,
# alongside a real (well-formed) match elsewhere in the file.
printf 'not json at all, but mentions malformed-slug raw\n{"id": "malformed-slug"}\n' \
  > "$WINGMAN_HOME/crew-archive.jsonl"
id5a="$(wm_state crew-derive-id --base malformed-slug)"; rc5a=$?
assert_eq "a malformed line does not crash derivation (exit 0)" "$rc5a" "0"
assert_eq "the real match alongside it still derives base-2" "$id5a" "malformed-slug-2"

# 5b: only a malformed, substring-matching line - no real match anywhere.
printf 'not json at all, but mentions nomatch-slug raw\n' > "$WINGMAN_HOME/crew-archive.jsonl"
id5b="$(wm_state crew-derive-id --base nomatch-slug)"; rc5b=$?
assert_eq "a malformed-only substring hit does not crash (exit 0)" "$rc5b" "0"
assert_eq "a malformed-only substring hit is not treated as a collision" "$id5b" "nomatch-slug"

# 5c: an undecodable byte (0xff) in the archive must not raise out of the
# scan, alongside a real match elsewhere in the file (round-1 review N2/N3).
uv run --no-project --quiet python -c '
import sys
with open(sys.argv[1], "wb") as fh:
    fh.write(b"not json, has a bad byte: \xff mentions badbyte-slug raw\n")
    fh.write(b"{\"id\": \"badbyte-slug\"}\n")
' "$WINGMAN_HOME/crew-archive.jsonl"
id5c="$(wm_state crew-derive-id --base badbyte-slug)"; rc5c=$?
assert_eq "an undecodable byte in the archive does not crash (exit 0)" "$rc5c" "0"
assert_eq "the real match survives an undecodable byte elsewhere in the file" "$id5c" "badbyte-slug-2"

# --- 6: end to end through bin/spawn-crew itself -------------------------------
# spawn -> stand down -> prune (archives it) -> spawn again with the identical
# objective+type -> the new member must NOT reuse the pruned id.
WS="$(wm_mktemp_dir)/workspace"
mkdir -p "$WS/repo"
git -C "$WS/repo" init -q
export WM_SPAWN_DELAY=0 WM_SUBMIT_DELAY=0 WM_READY_TRIES=4 WM_READY_POLL=0 \
  WM_SUBMIT_POLL=0.2 WM_SUBMIT_TRIES=1
wm_trust_repo "$WS/repo"

e2e_obj="issue 178 recycled id e2e"
eid1="$("$SPAWN" --type market-analyst --repo "$WS/repo" --objective "$e2e_obj" 2>/dev/null | tail -1)"
assert_true "the first e2e spawn succeeds" "[ -n '$eid1' ]"

wm_state standdown --id "$eid1" >/dev/null
wm_state prune >/dev/null
assert_false "the first e2e member is gone from the live roster after prune" \
  "wm_state crew-get --id '$eid1' >/dev/null 2>&1"

eid2="$("$SPAWN" --type market-analyst --repo "$WS/repo" --objective "$e2e_obj" 2>/dev/null | tail -1)"
assert_true "the second, identical-objective e2e spawn succeeds" "[ -n '$eid2' ]"
assert_eq "the recycled slug is disambiguated, not silently reused" "$eid2" "$eid1-2"

# --- 7: the collision warning fires exactly on a collision ---------------------
fresh_obj="issue 178 warning check $$"
fresh_err="$("$SPAWN" --type market-analyst --repo "$WS/repo" --objective "$fresh_obj" 2>&1 >/dev/null)"
assert_not_contains "no warning on a fresh, non-colliding spawn" "$fresh_err" "is already used"

collide_err="$("$SPAWN" --type market-analyst --repo "$WS/repo" --objective "$fresh_obj" 2>&1 >/dev/null)"
assert_contains "a collision (roster or archive) triggers the wm_warn diagnostic" "$collide_err" "is already used"

test_summary
