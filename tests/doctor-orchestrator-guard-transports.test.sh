#!/usr/bin/env bash
# E2E: bin/doctor's orchestrator guard-transport reconcile section (docs/
# analysis/2026-08-18-remove-bin-wingman-launcher-spec.md, §4.5) - the
# interactive, no-tool-call-needed path that installs and self-tests each of
# codex/grok/opencode/pi's own guard transport, closing the gap this
# migration's own research found: bin/lib/guard-transport.sh's
# wm_guard_transport_sync existed before this, but its only caller was
# bin/wingman's own orchestrator launch, itself gated behind a continuity-
# transport refusal that ran BEFORE the guard-transport install for every
# non-claude agent - so the install code was live but genuinely unreachable
# on a real machine (confirmed: bin/doctor never called it either). This
# file is the dedicated, unskipped coverage for that section; every OTHER
# test that calls `bin/doctor -y` sets WM_DOCTOR_SKIP_ORCH_GUARD_TRANSPORTS=1
# to avoid paying a real per-transport self-test subprocess on every call
# for a section unrelated to what it is actually testing.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

DOCTOR="$TEST_REPO/bin/doctor"

# tests/lib.sh's default WM_AGENT_BIN_OVERRIDE (a harmless stub with no
# --dangerously-bypass-hook-trust in its own --help, and no real pi
# extension loading) would otherwise win over the real codex/pi binaries
# this whole file needs - see tests/agent-pi-guard-transport.test.sh's
# identical unset for the same reason.
unset WM_AGENT_BIN_OVERRIDE

# =============================================================================
# (a) a healthy repo: each of the four transports installs and self-tests -
# or, for whichever of the four have no real binary on THIS machine's PATH
# (grok/opencode need none of their own; codex/pi's own reconcile steps
# genuinely require the real binary to exist, exactly like claude's own
# required-dependency check above in bin/doctor's output), names that
# missing-binary reason specifically rather than some OTHER failure. Doctor's
# own overall exit code is NOT asserted here - it reflects the FULL
# dependency check (including claude itself, which a CI runner need not
# have installed at all to run this suite), unrelated to what this file
# tests.
# =============================================================================
test_new_home
FAKEHOME_A="$(wm_mktemp_dir)"
out_a="$(HOME="$FAKEHOME_A" CODEX_HOME="$FAKEHOME_A/.codex" "$DOCTOR" -y < /dev/null 2>&1)"
for agent in codex grok opencode pi; do
  assert_contains "doctor reports $agent's guard transport installed and self-tested, OR names a missing binary" \
    "$out_a" "$agent's guard transport"
done
# A "hard failure" here means "still could not register... " for a reason
# OTHER than the binary genuinely being absent - that specific, expected
# reason is not itself a bug.
offending="$(printf '%s\n' "$out_a" | grep 'still could not register' | grep -v 'is not on PATH' || true)"
assert_eq "no transport reports a hard failure other than a missing binary" "$offending" ""

# =============================================================================
# (b) a broken repo: doctor names the problem and (AUTO_YES) cannot fix a
# genuinely broken reconciler on its own - a missing hook script it has no
# install step for, unlike a merely-unregistered-but-installable state.
#
# bin/lib/common.sh derives $WM_REPO/$WM_BIN/$WM_LIB unconditionally from
# ${BASH_SOURCE[0]} (no env-var override honored) - so the only way to make
# `bin/doctor` itself operate against a broken checkout is to invoke it FROM
# a mirror whose own bin/ is symlinked in whole, exactly the same pattern
# tests/session-guard-hook-sync.test.sh already uses for the identical
# reason. `cd && pwd` (no -P) is LOGICAL, so $WM_LIB resolves to the
# mirror's own path as navigated, not the real checkout's physical path.
# =============================================================================
test_new_home
MIRROR_B="$(wm_mktemp_dir)/mirror-bad"
mkdir -p "$MIRROR_B/hooks"
ln -s "$TEST_REPO/bin" "$MIRROR_B/bin"
# guard_dispatch.py itself (portable across all four dialects) is the
# reconcile target here, not a per-dialect script - break it so every
# transport's own self-test fails identically, regardless of dialect.
mkdir -p "$MIRROR_B/hooks/lib"
for f in "$TEST_REPO"/hooks/lib/*; do
  base="$(basename "$f")"
  [ "$base" = "guard_dispatch.py" ] && continue
  ln -s "$f" "$MIRROR_B/hooks/lib/$base"
done
for f in "$TEST_REPO"/hooks/*; do
  [ -f "$f" ] || continue
  ln -s "$f" "$MIRROR_B/hooks/$(basename "$f")"
done
FAKEHOME_B="$(wm_mktemp_dir)"
out_b="$(HOME="$FAKEHOME_B" CODEX_HOME="$FAKEHOME_B/.codex" "$MIRROR_B/bin/doctor" -y < /dev/null 2>&1)"
assert_contains "doctor names the guard-transport problem for at least one non-claude agent" \
  "$out_b" "is not installed/verified"

# =============================================================================
# (c) fixing a previously-broken transport clears the orchestrator-bootstrap
# cache, so the very next tool call re-bootstraps clean rather than replaying
# a stale "fail" outcome from before the fix
# =============================================================================
test_new_home
FAKEHOME_C="$(wm_mktemp_dir)"
STALE_ID="doctor-clears-stale-cache"
mkdir -p "$WINGMAN_HOME/orchestrator-bootstrap"
printf 'fail\n' > "$WINGMAN_HOME/orchestrator-bootstrap/$STALE_ID.outcome"
printf 'a stale failure from before doctor fixed it\n' > "$WINGMAN_HOME/orchestrator-bootstrap/$STALE_ID.reason"
HOME="$FAKEHOME_C" CODEX_HOME="$FAKEHOME_C/.codex" "$DOCTOR" -y < /dev/null >/dev/null 2>&1
assert_false "doctor clears the stale orchestrator-bootstrap cache after reconciling" \
  "[ -d '$WINGMAN_HOME/orchestrator-bootstrap' ]"

test_summary
