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
FIXDIR="$(wm_mktemp_dir)"
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

# --- issue #205: a lead's own handoff destination is a distinct allowed
# location, anchored on $WINGMAN_HOME rather than folded into ALLOWLIST_RE ----
HANDOFF_HOME="$FIXDIR/wm-home"
mkdir -p "$HANDOFF_HOME/handoff"
HANDOFF_CLEAN="$HANDOFF_HOME/handoff/x.md"
printf '# Handoff\nJust prose, no secrets, no internal hosts.\n' > "$HANDOFF_CLEAN"
if wm_have gitleaks; then
  out="$(WINGMAN_HOME="$HANDOFF_HOME" "$SCRIPT" "$HANDOFF_CLEAN")"; rc=$?
  assert_eq "a clean file under \$WINGMAN_HOME/handoff/ passes the location gate" "$rc" "0"
  assert_eq "the verdict is a bare pass" "$out" "pass"
fi

# The location-gate acceptance above is gated on gitleaks being installed, so
# it never runs in an environment without it (this repo's own CI job marks
# gitleaks optional). Assert the location gate itself unconditionally, using
# the no-gitleaks stub PATH built above: a file under $WINGMAN_HOME/handoff/
# must clear the location gate and fail closed at the *missing-gitleaks*
# check specifically, not at the location gate - distinguishable from a
# rejected path, which fails closed at the location gate instead (asserted
# right below, in the MF1 regression case).
out="$(env PATH="$NOGL_BIN" WINGMAN_HOME="$HANDOFF_HOME" "$SCRIPT" "$HANDOFF_CLEAN")"; rc=$?
assert_eq "a file under \$WINGMAN_HOME/handoff/ clears the location gate even without gitleaks" "$rc" "1"
assert_contains "it fails closed on the missing dependency, not the location gate" "$out" "fail:gitleaks not installed"

# MF1 regression: a directory literally named "handoff" that is NOT under
# $WINGMAN_HOME must still be rejected - proves the fix is an anchored prefix
# test against the resolved $WINGMAN_HOME, not an unanchored /handoff/ regex
# alternative that would whitelist the word "handoff" anywhere on disk.
FAKE_REPO_HANDOFF="$FIXDIR/some-other-repo/handoff/x.md"
mkdir -p "$(dirname "$FAKE_REPO_HANDOFF")"
printf 'clean content\n' > "$FAKE_REPO_HANDOFF"
out="$(WINGMAN_HOME="$HANDOFF_HOME" "$SCRIPT" "$FAKE_REPO_HANDOFF")"; rc=$?
assert_eq "a handoff/ dir outside \$WINGMAN_HOME is still rejected (MF1 regression)" "$rc" "1"
assert_contains "the reason still names the location" "$out" "fail:not under a crew-deliverable directory"

# --- issue #207: a <name>.<suffix>.<ext> filename is not an internal hostname -
# config.local.toml (this repo's own settings file), settings.local.json
# (Claude Code's own per-project settings file), and developer.local.md (the
# playbooks/<type>.local.md override convention) must all pass; a bare
# hostname suffix (nas.local, db.internal, foo.corp) and a real multi-label
# domain (db1.corp.example.com) must still fail - the false positive was
# `[A-Za-z0-9.-]+\.(internal|corp|local)\b` matching the filename stem, since
# \b is satisfied by the dot that starts a following extension.
#
# Round-1 plan review (MUST-FIX 1/2/3/4): every case above is also exercised
# sentence-final (a trailing period, the ordinary way a filename or hostname
# ends a sentence in prose), because the tokenizer's own char class
# ([A-Za-z0-9.-]+) absorbs a trailing period into the token - proven live to
# flip BOTH directions if the fix omits the sub(/[.-]+$/, "", tok) strip:
# "config.local.toml." wrongly failed, and "nas.local."/"db.internal."/
# "foo.corp." wrongly passed (the more serious direction - a silently
# weakened true positive).
MF207_1="$ALLOWED_DIR/mf207-config-local-toml.md"
printf 'config.local.toml is this repo own settings file, committed in template form as config.example.toml\n' > "$MF207_1"
MF207_2="$ALLOWED_DIR/mf207-settings-local-json.md"
printf 'Claude Code reads its own per-project settings.local.json\n' > "$MF207_2"
MF207_3="$ALLOWED_DIR/mf207-developer-local-md.md"
printf 'the override convention is playbooks/developer.local.md\n' > "$MF207_3"
MF207_4="$ALLOWED_DIR/mf207-domain-chain.md"
printf 'reach it at db1.corp.example.com\n' > "$MF207_4"
MF207_5="$ALLOWED_DIR/mf207-bare-corp.md"
printf 'hosted internally at foo.corp\n' > "$MF207_5"

# Sentence-final variants (MUST-FIX 4) - both directions.
MF207_SF1="$ALLOWED_DIR/mf207-sf-config-local-toml.md"
printf 'Settings live in config.local.toml.\n' > "$MF207_SF1"
MF207_SF2="$ALLOWED_DIR/mf207-sf-settings-local-json.md"
printf 'Claude Code reads settings.local.json.\n' > "$MF207_SF2"
MF207_SF3="$ALLOWED_DIR/mf207-sf-developer-local-md.md"
printf 'See playbooks/developer.local.md.\n' > "$MF207_SF3"
MF207_SF4="$ALLOWED_DIR/mf207-sf-nas-local.md"
printf 'The NAS is reachable at nas.local.\n' > "$MF207_SF4"
MF207_SF5="$ALLOWED_DIR/mf207-sf-db-internal.md"
printf 'The service lives at db.internal.\n' > "$MF207_SF5"
MF207_SF6="$ALLOWED_DIR/mf207-sf-foo-corp.md"
printf 'It is hosted at foo.corp.\n' > "$MF207_SF6"
MF207_SF7="$ALLOWED_DIR/mf207-sf-domain-chain.md"
printf 'Reach it at db1.corp.example.com.\n' > "$MF207_SF7"

if wm_have gitleaks; then
  out="$("$SCRIPT" "$MF207_1")"; rc=$?
  assert_eq "config.local.toml (issue #207) is not flagged as an internal hostname" "$rc" "0"
  assert_eq "the verdict is a bare pass" "$out" "pass"

  out="$("$SCRIPT" "$MF207_2")"; rc=$?
  assert_eq "settings.local.json (issue #207) is not flagged as an internal hostname" "$rc" "0"

  out="$("$SCRIPT" "$MF207_3")"; rc=$?
  assert_eq "developer.local.md (issue #207) is not flagged as an internal hostname" "$rc" "0"

  out="$("$SCRIPT" "$MF207_4")"; rc=$?
  assert_eq "a real multi-label domain (db1.corp.example.com) still fails despite issue #207's fix" "$rc" "1"
  assert_contains "the reason still names the infra pattern" "$out" "fail:matches an internal IP/hostname pattern"

  out="$("$SCRIPT" "$MF207_5")"; rc=$?
  assert_eq "a bare .corp hostname still fails (MUST-FIX 5: .corp had no bare-suffix fixture anywhere)" "$rc" "1"

  out="$("$SCRIPT" "$MF207_SF1")"; rc=$?
  assert_eq "config.local.toml still passes when it ends a sentence (MUST-FIX 1/3)" "$rc" "0"
  out="$("$SCRIPT" "$MF207_SF2")"; rc=$?
  assert_eq "settings.local.json still passes when it ends a sentence" "$rc" "0"
  out="$("$SCRIPT" "$MF207_SF3")"; rc=$?
  assert_eq "developer.local.md still passes when it ends a sentence" "$rc" "0"

  out="$("$SCRIPT" "$MF207_SF4")"; rc=$?
  assert_eq "nas.local still fails when it ends a sentence (MUST-FIX 2/3: must not be weakened)" "$rc" "1"
  out="$("$SCRIPT" "$MF207_SF5")"; rc=$?
  assert_eq "db.internal still fails when it ends a sentence" "$rc" "1"
  out="$("$SCRIPT" "$MF207_SF6")"; rc=$?
  assert_eq "foo.corp still fails when it ends a sentence" "$rc" "1"
  out="$("$SCRIPT" "$MF207_SF7")"; rc=$?
  assert_eq "db1.corp.example.com still fails when it ends a sentence" "$rc" "1"
fi

# --- usage errors ---------------------------------------------------------------
out="$("$SCRIPT" 2>&1)"; rc=$?
assert_eq "no argument is a usage error" "$rc" "1"
out="$("$SCRIPT" "$FIXDIR/does-not-exist.md" 2>&1)"; rc=$?
assert_eq "a missing file is an error" "$rc" "1"

rm -rf "$FIXDIR"
test_summary
