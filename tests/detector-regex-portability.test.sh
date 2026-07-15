#!/usr/bin/env bash
# E2E: issue #52 - bin/watch-fleet's pane-text detector regexes (WM_APIERR_RE,
# WM_RC_DROPPED_RE) must be plain, portable extended-regex syntax: no \b
# word-boundary escapes (a GNU extension BSD grep -E rejects outright when
# combined with an {n} interval - "invalid repetition count(s)") and no {n}
# intervals at all, since either alone is enough to make `grep -qE` exit 2
# (error) instead of 0/1 (match/no-match) on a stricter ERE implementation.
# grep -qE exiting 2 is exactly how this bug went unnoticed on Linux/GNU grep:
# the detector silently never fired and stderr got spammed every cycle, but the
# suite never caught it because nothing exercised the regex against a grep
# invocation at all. This file is the regression test the issue's own
# "Follow-up" section asks for: it does not attempt to run a BSD grep (none is
# available in this environment), so it cannot reproduce exit 2 directly, but
# it does assert the two structural properties that caused it (no \b, no {n})
# and drives each regex through this platform's own grep -E across a fixture
# of representative pane-text lines, asserting the exit status is always 0 or 1.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WF="$TEST_REPO/bin/watch-fleet"

# Pull a variable's shell-default value out of the script itself (rather than
# hardcoding a copy here) so this test always exercises the regex actually
# shipped in bin/watch-fleet, not a stale duplicate that could drift from it.
extract_default() {
  _ed_var="$1" _ed_file="$2"
  _ed_line="$(grep -m1 "^${_ed_var}=\"\\\${${_ed_var}:-" "$_ed_file")"
  [ -n "$_ed_line" ] || return 1
  ( unset "$_ed_var"; eval "$_ed_line"; eval "printf '%s' \"\$$_ed_var\"" )
}

APIERR_RE="$(extract_default WM_APIERR_RE "$WF")"
RC_DROPPED_RE="$(extract_default WM_RC_DROPPED_RE "$WF")"

assert_true "WM_APIERR_RE extracted a non-empty default" "[ -n '$APIERR_RE' ]"
assert_true "WM_RC_DROPPED_RE extracted a non-empty default" "[ -n '$RC_DROPPED_RE' ]"

# --- structural checks: the two features that made BSD grep -E reject the
#     pattern outright must both be absent, not just "happen not to trigger
#     exit 2 on this platform's grep" -----------------------------------------
case "$APIERR_RE" in
  *'\b'*) fail "WM_APIERR_RE must not use GNU-only \\b word boundaries" ;;
  *) ok "WM_APIERR_RE has no \\b word boundaries" ;;
esac
case "$APIERR_RE" in
  *'{'*) fail "WM_APIERR_RE must not use {n} interval syntax" ;;
  *) ok "WM_APIERR_RE has no {n} intervals" ;;
esac

# --- behavioral smoke test: every detector regex must exit 0 (match) or 1
#     (no match) on representative pane-text fixture lines, never 2 (grep
#     error) - this is the exact defect: a malformed ERE makes grep -qE exit 2,
#     and the caller in api_error_check/remote_control_dropped_check treats any
#     nonzero exit as "no match", so an error is silently indistinguishable
#     from a clean miss until you check the exit code itself, as this does ----
check_regex_exit_codes() {
  _cr_name="$1" _cr_re="$2"
  shift 2
  for _cr_line in "$@"; do
    printf '%s\n' "$_cr_line" | grep -qE "$_cr_re"
    _cr_rc=$?
    if [ "$_cr_rc" -eq 0 ] || [ "$_cr_rc" -eq 1 ]; then
      ok "$_cr_name: grep -qE exits 0/1 (got $_cr_rc) on: $_cr_line"
    else
      fail "$_cr_name: grep -qE exited $_cr_rc (expected 0 or 1) on: $_cr_line"
    fi
  done
}

check_regex_exit_codes "WM_APIERR_RE" "$APIERR_RE" \
  "429" \
  "HTTP 429 Too Many Requests" \
  "502 Error" \
  "500 Error" \
  "rate limit exceeded" \
  "overloaded_error" \
  "Internal Server Error" \
  "ECONNRESET" \
  "socket hang up" \
  "Service Unavailable" \
  "" \
  "an ordinary line with no signature at all" \
  "the number 4299 is not a status code" \
  "assistant: I hit a 429 mid-turn, retrying"

check_regex_exit_codes "WM_RC_DROPPED_RE" "$RC_DROPPED_RE" \
  "Remote Control disconnected" \
  "Transport closed" \
  "Transport recovery exhausted" \
  "" \
  "an ordinary line with no signature at all"

# --- correctness smoke test: the boundary-free rewrite must still actually
#     match the API-error signatures it is meant to catch, and still leave
#     ordinary/adjacent-digit text alone (the two failure modes the issue's
#     "false negatives at line start/end" caution calls out) ------------------
assert_true "WM_APIERR_RE matches a bare 429" \
  "printf '%s\n' '429' | grep -qE \"\$APIERR_RE\""
assert_true "WM_APIERR_RE matches 429 embedded in a sentence" \
  "printf '%s\n' 'HTTP 429 Too Many Requests' | grep -qE \"\$APIERR_RE\""
assert_true "WM_APIERR_RE matches a 5xx ' Error' line" \
  "printf '%s\n' '502 Error' | grep -qE \"\$APIERR_RE\""
assert_false "WM_APIERR_RE does not match an unrelated 4-digit number" \
  "printf '%s\n' 'the number 4299 is not a status code' | grep -qE \"\$APIERR_RE\""

test_summary
