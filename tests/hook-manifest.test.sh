#!/usr/bin/env bash
# E2E: bin/lib/hook_manifest.py - the shared manifest reader factored out of
# bin/lib/sync-user-hooks.py (the orchestrator-guard-transports plan, step
# 3) so bin/lib/sync-codex-hooks.py and bin/lib/sync-grok-hooks.py do not
# duplicate it. tests/sync-user-hooks.test.sh and tests/doctor.test.sh's
# manifest/doctor equality test are the drift net proving this factoring
# left sync-user-hooks.py's own behaviour unchanged; this file covers the
# NEW portable_entries() helper directly.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

out="$(uv run --no-project --quiet python -c '
import sys
sys.path.insert(0, "'"$TEST_REPO"'/bin/lib")
from hook_manifest import default_manifest, default_repo, load_manifest, portable_entries

m = load_manifest(default_manifest())
r = default_repo()

for dialect in ("codex", "grok", "opencode", "pi"):
    entries = list(portable_entries(m, r, dialect))
    guards = sorted(set(h.get("guard") for _, h, _, _, _ in entries))
    print("%s:%d:%s" % (dialect, len(entries), ",".join(guards)))

# A dialect with no portable hooks at all (a made-up name) yields nothing -
# proves the filter genuinely filters rather than defaulting to "everything".
bogus = list(portable_entries(m, r, "not-a-real-dialect"))
print("bogus:%d" % len(bogus))
')"

assert_contains "codex sees exactly the 6 orchestrator-active portable hooks" "$out" "codex:6:direct-edit,foreground-poll-loop,foreground-watcher,spawn-pause,watcher-kill"
assert_contains "grok sees the identical set" "$out" "grok:6:direct-edit,foreground-poll-loop,foreground-watcher,spawn-pause,watcher-kill"
assert_contains "opencode sees the identical set" "$out" "opencode:6:direct-edit,foreground-poll-loop,foreground-watcher,spawn-pause,watcher-kill"
assert_contains "pi sees the identical set" "$out" "pi:6:direct-edit,foreground-poll-loop,foreground-watcher,spawn-pause,watcher-kill"
assert_contains "an unrecognized dialect name finds nothing (no accidental catch-all)" "$out" "bogus:0"

# Every entry portable_entries() ever yields also appears in the plain
# flat_entries() walk (portable_entries is a strict filter, not a separate
# source of truth that could drift from the manifest's own hook list).
subset_out="$(uv run --no-project --quiet python -c '
import sys
sys.path.insert(0, "'"$TEST_REPO"'/bin/lib")
from hook_manifest import default_manifest, default_repo, flat_entries, load_manifest, portable_entries

m = load_manifest(default_manifest())
r = default_repo()
all_commands = set(c for _, _, c, _, _ in flat_entries(m, r))
portable_commands = set(c for _, _, c, _, _ in portable_entries(m, r, "pi"))
print("subset" if portable_commands <= all_commands else "NOT-A-SUBSET")
')"
assert_eq "portable_entries is always a subset of flat_entries" "$subset_out" "subset"

# check_scripts() (also relocated) still fails closed on a missing script -
# proves the relocation preserved this behaviour, not just the happy path.
FAKE_MANIFEST="$(wm_mktemp_file)"
cat > "$FAKE_MANIFEST" <<EOF
{"groups": [{"id": "x", "hooks": [{"script": "hooks/does-not-exist.sh", "event": "PreToolUse", "matcher": "Bash"}]}]}
EOF
err="$(uv run --no-project --quiet python -c '
import sys
sys.path.insert(0, "'"$TEST_REPO"'/bin/lib")
from hook_manifest import check_scripts, load_manifest
m = load_manifest("'"$FAKE_MANIFEST"'")
check_scripts(m, "'"$TEST_REPO"'")
' 2>&1)"; rc=$?
assert_true "check_scripts fails closed on a missing script" "[ $rc -ne 0 ]"
assert_contains "the failure names the missing script" "$err" "does-not-exist.sh"

test_summary
