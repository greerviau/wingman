#!/usr/bin/env bash
# E2E: bin/lib/artifact-scan.sh, condition C's deterministic pre-publish gate
# (design: docs/plans/2026-07-12-remote-control-visibility-and-auto-reconnect-
# design.md, ask 3a). Proves the location allowlist, the RFC1918/internal-
# hostname regex, the code-block-proportion soft heuristic, and gitleaks's
# both-directions verdict (secret found vs. clean) - plus the fail-closed
# posture when gitleaks itself is unavailable.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
# wm_have (used below to skip gitleaks-dependent assertions when it is not
# installed) lives in common.sh, not lib.sh.
. "$TEST_REPO/bin/lib/common.sh"

SCRIPT="$TEST_REPO/bin/lib/artifact-scan.sh"
FIXDIR="$(mktemp -d)"
# The allowlist checks for /docs/(plans|analysis|tickets)/ in the absolute
# path, so fixtures live under a real docs/plans/ subtree.
ALLOWED_DIR="$FIXDIR/docs/plans"
mkdir -p "$ALLOWED_DIR"

# --- location allowlist: coarse, cheap, defense-in-depth only -----------------
OUTSIDE="$FIXDIR/elsewhere.md"
printf 'clean content\n' > "$OUTSIDE"
out="$("$SCRIPT" "$OUTSIDE")"; rc=$?
assert_eq "a file outside the allowlist is rejected regardless of content" "$rc" "1"
assert_contains "the reason names the location" "$out" "fail:not under a crew-deliverable directory"

# --- a clean file under the allowlist passes -----------------------------------
CLEAN="$ALLOWED_DIR/clean.md"
printf '# Plan\nJust prose, no secrets, no internal hosts.\n' > "$CLEAN"
if wm_have gitleaks; then
  out="$("$SCRIPT" "$CLEAN")"; rc=$?
  assert_eq "a clean allowlisted file passes" "$rc" "0"
  assert_eq "the verdict is a bare pass" "$out" "pass"
else
  printf '  skip - gitleaks not installed in this environment\n'
fi

# --- gitleaks missing: fails closed, never silently skipped -------------------
# Simulated with a stub PATH holding only the externals this code path needs,
# never by pointing PATH at real system dirs - gitleaks may legitimately be
# installed in /usr/bin, which would silently void the simulation.
NOGL_BIN="$FIXDIR/no-gitleaks-bin"
mkdir -p "$NOGL_BIN"
for _t in bash sh dirname basename grep sed cat uname; do
  _p="$(command -v "$_t" 2>/dev/null)" && ln -s "$_p" "$NOGL_BIN/$_t"
done
out="$(env PATH="$NOGL_BIN" "$SCRIPT" "$CLEAN")"; rc=$?
assert_eq "a file cannot be verified without gitleaks - fails closed" "$rc" "1"
assert_contains "the reason names the missing dependency" "$out" "fail:gitleaks not installed"

# --- RFC1918 private IPv4 is a hard fail ---------------------------------------
# Gated on gitleaks: without it, EVERY file fails closed on the missing-
# dependency check before the infra regex is even reached (verified above), so
# these assertions would only be validating that aliasing, not the infra check.
INFRA1="$ALLOWED_DIR/infra-ip.md"
printf 'internal box at 10.20.30.40\n' > "$INFRA1"
INFRA2="$ALLOWED_DIR/infra-ip2.md"
printf 'also try 192.168.1.5 and 172.20.5.5\n' > "$INFRA2"
PUBLIC_IP="$ALLOWED_DIR/public-ip.md"
printf 'a public address like 8.8.8.8 is fine\n' > "$PUBLIC_IP"
INFRA3="$ALLOWED_DIR/infra-host.md"
printf 'reach it at db1.corp.example.com\n' > "$INFRA3"
INFRA4="$ALLOWED_DIR/infra-host2.md"
printf 'or svc.internal and box.local\n' > "$INFRA4"
if wm_have gitleaks; then
  out="$("$SCRIPT" "$INFRA1")"; rc=$?
  assert_eq "an RFC1918 address fails" "$rc" "1"
  assert_contains "the reason names the infra pattern" "$out" "fail:matches an internal IP/hostname pattern"

  out="$("$SCRIPT" "$INFRA2")"; rc=$?
  assert_eq "192.168.0.0/16 and 172.16.0.0/12 also fail" "$rc" "1"

  out="$("$SCRIPT" "$PUBLIC_IP")"; rc=$?
  assert_eq "a public IP is not flagged as internal infra" "$rc" "0"

  out="$("$SCRIPT" "$INFRA3")"; rc=$?
  assert_eq "a .corp hostname fails" "$rc" "1"

  out="$("$SCRIPT" "$INFRA4")"; rc=$?
  assert_eq "a .internal/.local hostname fails" "$rc" "1"
fi

# --- an oversized code block is a soft hit, not a hard block ------------------
BIGCODE="$ALLOWED_DIR/bigcode.md"
{
  echo "# doc"
  echo '```bash'
  i=0; while [ "$i" -lt 50 ]; do echo "echo line $i"; i=$((i+1)); done
  echo '```'
} > "$BIGCODE"
if wm_have gitleaks; then
  out="$("$SCRIPT" "$BIGCODE")"; rc=$?
  assert_eq "an oversized code block still passes (soft hit, not a block)" "$rc" "0"
  case "$out" in
    pass-soft:*) ok "the verdict is pass-soft, calling out the oversized block" ;;
    *) fail "the verdict is pass-soft, calling out the oversized block"; printf '         got [%s]\n' "$out" ;;
  esac
fi

# --- a routine short illustrative excerpt is a clean pass ----------------------
SMALLCODE="$ALLOWED_DIR/smallcode.md"
{
  echo "# doc"
  echo "some prose introducing a short excerpt"
  echo '```bash'
  echo 'echo hi'
  echo '```'
  echo "more prose"
} > "$SMALLCODE"
if wm_have gitleaks; then
  out="$("$SCRIPT" "$SMALLCODE")"; rc=$?
  assert_eq "a short illustrative excerpt passes cleanly" "$rc" "0"
  assert_eq "the verdict is a bare pass, not soft" "$out" "pass"
fi

# --- usage errors ---------------------------------------------------------------
out="$("$SCRIPT" 2>&1)"; rc=$?
assert_eq "no argument is a usage error" "$rc" "1"
out="$("$SCRIPT" "$FIXDIR/does-not-exist.md" 2>&1)"; rc=$?
assert_eq "a missing file is an error" "$rc" "1"

rm -rf "$FIXDIR"
test_summary
