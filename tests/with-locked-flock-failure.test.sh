#!/usr/bin/env bash
# E2E: issue #79, Fix 2 - with_locked must not silently swallow a real flock()
# OSError on a POSIX system where fcntl IS available (only the genuinely
# platform-limited "no fcntl at all" case may degrade to lock-free). Before this
# fix, `except OSError: pass` inside with_locked absorbed ANY flock() failure with
# zero trace, silently reopening the exact lost-update race issue #93 closed.
# Proves: (1) with_locked itself now re-raises a loud, actionable OSError instead
# of completing silently, and (2) a real caller (cmd_crew_add) that hits this
# failure propagates it rather than reporting a false success - the composition
# that, together with test 1's exit-status check in bin/spawn-crew, closes the
# whole silent-failure chain end to end.
#
# A small, targeted unit-style test (not a new heavy concurrency harness):
# monkeypatches fcntl.flock on the already-imported wm-state module to raise
# OSError, then exercises with_locked directly and cmd_crew_add through it.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

test_new_home

OUT="$(uv run --no-project --quiet python - "$TEST_REPO/bin/lib/wm-state.py" "$WINGMAN_HOME" <<'PYEOF'
import sys, importlib.util

wm_state_path, home = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("wm_state_mod", wm_state_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

import os
os.environ["WINGMAN_HOME"] = home

def _boom(*a, **kw):
    raise OSError(5, "simulated flock failure (test)")

assert mod.fcntl is not None, "test requires a POSIX fcntl module to be present"
mod.fcntl.flock = _boom

# --- 1: with_locked itself re-raises, loudly and actionably -------------------
raised = None
try:
    with mod.with_locked(mod.crew_json_path()):
        pass
except OSError as e:
    raised = e

if raised is None:
    print("FAIL: with_locked silently swallowed the flock() OSError")
    sys.exit(1)
msg = str(raised)
if "with_locked" not in msg or "advisory" not in msg:
    print("FAIL: with_locked raised %r but not the actionable wrapped message" % (raised,))
    sys.exit(1)
print("PASS: with_locked propagates a loud, actionable OSError")

# --- 2: a real caller (cmd_crew_add) propagates the failure, not a false success
mod.ensure_home()
before = mod.load_roster()

class Args:
    id = "flock-fail-test"
    type = "developer"
    objective = "o"
    repo = "/tmp"
    scope = "repo"
    parent = ""
    window = "wm-flock-fail-test"
    window_id = ""
    session_id = "s1"
    worktree = ""
    allow_merge = False
    is_git = None
    has_remote = None

raised2 = None
try:
    mod.cmd_crew_add(Args())
except OSError as e:
    raised2 = e

if raised2 is None:
    print("FAIL: cmd_crew_add completed despite the flock() failure - a false success")
    sys.exit(1)
after = mod.load_roster()
if len(after) != len(before):
    print("FAIL: cmd_crew_add left a partial roster write behind despite raising")
    sys.exit(1)
print("PASS: cmd_crew_add propagates the with_locked failure with no partial write")
PYEOF
)"
rc=$?

assert_true "the flock-failure script ran to completion" "[ $rc -eq 0 ]"
assert_contains "with_locked propagates a loud, actionable OSError" "$OUT" "PASS: with_locked propagates"
assert_contains "cmd_crew_add propagates the failure with no partial write" "$OUT" "PASS: cmd_crew_add propagates"
assert_not_contains "no FAIL line anywhere in the script output" "$OUT" "FAIL:"

test_summary
