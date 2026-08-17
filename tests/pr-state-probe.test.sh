#!/usr/bin/env bash
# E2E: bin/lib/pr-state-probe.sh, the forge-verified PR-state probe behind
# bin/watch-fleet's forge-terminal nudge. Drives it with a FAKE forge CLI (via
# WM_GH) so no real gh/GitHub is needed, and proves: the MERGED/CLOSED/OPEN/
# unknown mapping, the non-zero-exit and malformed-output fallbacks, the
# defensive CLOSED+mergedAt collapse to MERGED, that a non-canonical PR
# reference never even invokes the forge CLI, and - the review-evidence-gate
# test - that the `gh pr view` call requests exactly `state,mergedAt` and
# nothing else, so no approval evidence is ever even requested on this path.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SCRIPT="$TEST_REPO/bin/lib/pr-state-probe.sh"
FIXDIR="$(wm_mktemp_dir)"

PR_URL="https://github.com/owner/repo/pull/42"

# A fake `gh`: records its own full argv (one line per call) to
# $FAKE_GH_MARKER when set, and on `pr view` serves $FAKE_PR verbatim - THEN,
# only after writing that output, exits $FAKE_GH_RC (default 0). Emitting
# content before the failing exit (rather than failing before any output) is
# deliberate: it is what makes the rc check in pr-state-probe.sh load-bearing
# on its own, distinctly from the JSON-parse guard - a stub that fails empty
# is already caught by the parser, but one that fails after emitting valid,
# parseable content can only be caught by trusting the exit code over the
# content (see the #3 fixture below).
make_fake_gh() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
if [ -n "${FAKE_GH_MARKER:-}" ]; then
  printf '%s\n' "$*" >> "$FAKE_GH_MARKER"
fi
case "$1 $2" in
  "pr view") cat "${FAKE_PR:-/dev/null}" ;;
  *)         echo "" ;;
esac
if [ "${FAKE_GH_RC:-0}" != 0 ]; then
  exit "${FAKE_GH_RC}"
fi
SH
  chmod +x "$1"
}

GH="$FIXDIR/gh"; make_fake_gh "$GH"
export WM_GH="$GH"
FAKE_PR="$FIXDIR/pr.json"
MARKER="$FIXDIR/gh-argv.log"

run() { FAKE_PR="$FAKE_PR" FAKE_GH_MARKER="$MARKER" "$SCRIPT" "$1"; }

# --- #1: state mapping ---------------------------------------------------------
rm -f "$MARKER"
printf '{"state":"MERGED"}' > "$FAKE_PR"
assert_eq "state=MERGED prints MERGED" "$(run "$PR_URL")" "MERGED"

printf '{"state":"CLOSED"}' > "$FAKE_PR"
assert_eq "state=CLOSED (no mergedAt) prints CLOSED" "$(run "$PR_URL")" "CLOSED"

printf '{"state":"OPEN"}' > "$FAKE_PR"
assert_eq "state=OPEN prints OPEN" "$(run "$PR_URL")" "OPEN"

# --- #2: runs at all as an ordinary subprocess invocation ----------------------
# FAKE_PR must be a real fixture with non-empty content and exported into the
# child's own environment (not routed through run()'s inline override, and not
# left to an ambient/unset value) - otherwise the fake gh returns empty
# output, the script's own empty-JSON fallback prints "unknown" without ever
# reaching wm_py, and the missing-common.sh mutation this case exists to catch
# goes undetected (it only breaks the wm_have/wm_py path, both reached only
# once gh has returned real content).
printf '{"state":"OPEN"}' > "$FAKE_PR"
out="$(FAKE_PR="$FAKE_PR" "$SCRIPT" "$PR_URL")"
case "$out" in
  MERGED|CLOSED|OPEN|unknown) ok "invoked as its own process, prints one of the four tokens" ;;
  *) fail "invoked as its own process, prints one of the four tokens"; printf '         got [%s]\n' "$out" ;;
esac

# --- #3: a stub that exits non-zero -> unknown, exit 0 -------------------------
rm -f "$MARKER"
printf '{"state":"MERGED"}' > "$FAKE_PR"
out="$(FAKE_PR="$FAKE_PR" FAKE_GH_RC=1 "$SCRIPT" "$PR_URL")"; rc=$?
assert_eq "a failing gh call prints unknown" "$out" "unknown"
assert_eq "a failing gh call still exits 0" "$rc" "0"

# --- #4: malformed (non-JSON) output -> unknown --------------------------------
printf 'not json at all' > "$FAKE_PR"
assert_eq "malformed gh output prints unknown" "$(run "$PR_URL")" "unknown"

# --- #5: the review-evidence-gate test - the --json list is exactly
# state,mergedAt, nothing more --------------------------------------------------
rm -f "$MARKER"
printf '{"state":"OPEN"}' > "$FAKE_PR"
run "$PR_URL" >/dev/null
assert_contains "the gh call's argv carries --json state,mergedAt" "$(cat "$MARKER")" "--json state,mergedAt"
case "$(cat "$MARKER")" in
  *statusCheckRollup*|*reviews*|*comments*|*mergeable*|*mergeStateStatus*)
    fail "the --json list requests no approval-evidence fields" ;;
  *) ok "the --json list requests no approval-evidence fields" ;;
esac

# --- #6: defensive CLOSED+mergedAt collapses to MERGED --------------------------
printf '{"state":"CLOSED","mergedAt":"2026-08-01T00:00:00Z"}' > "$FAKE_PR"
assert_eq "CLOSED with a non-empty mergedAt prints MERGED" "$(run "$PR_URL")" "MERGED"

# --- #7: a non-canonical argument -> unknown, and gh is never invoked ----------
for bad in "42" "#42" "https://gitlab.com/o/r/pull/3"; do
  rm -f "$MARKER"
  out="$(run "$bad")"
  assert_eq "non-canonical ref [$bad] prints unknown" "$out" "unknown"
  if [ -f "$MARKER" ]; then
    fail "non-canonical ref [$bad] never invokes the forge CLI"
  else
    ok "non-canonical ref [$bad] never invokes the forge CLI"
  fi
done

rm -rf "$FIXDIR"
test_summary
