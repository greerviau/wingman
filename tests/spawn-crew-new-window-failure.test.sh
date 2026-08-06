#!/usr/bin/env bash
# E2E: issue #179 - bin/spawn-crew must not report success when `tmux
# new-window` itself fails (e.g. the crew session dies between
# wm_tmux_ensure_session and this call - the TOCTOU issue #179 describes,
# reproduced end-to-end against the real tmux primitives in #218's own
# incident investigation). Before the fix, WINDOW_ID comes back empty,
# spawn-crew writes a roster record anyway (status "working", window_id
# ""), spends the full opening-objective send/poll budget probing a pane
# that was never created, and still prints "spawned ..." and exits 0 - a
# false-success report that later surfaces as a misleading `died`
# diagnosis on reconcile.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SPAWN="$TEST_REPO/bin/spawn-crew"

REPO="$(wm_mktemp_dir)/throwaway-repo"
mkdir -p "$REPO"
git -C "$REPO" init -q

test_new_home
wm_trust_repo "$REPO"

# PATH-prepended tmux shim: forwards every subcommand to the real tmux
# except new-window, which fails deterministically. command -v -p resolves
# against the default system PATH, not this shimmed one, so it reliably
# finds the real binary regardless of PATH ordering.
SHIM_DIR="$(wm_mktemp_dir)"
cat > "$SHIM_DIR/tmux" <<'EOF'
#!/usr/bin/env bash
REAL_TMUX="$(command -v -p tmux)"
if [ "${1:-}" = "new-window" ]; then
  echo "simulated new-window failure (test): can't find session" >&2
  exit 1
fi
exec "$REAL_TMUX" "$@"
EOF
chmod +x "$SHIM_DIR/tmux"

ID="spawn-179-newwin-fail"
out="$(PATH="$SHIM_DIR:$PATH" "$SPAWN" --type developer --repo "$REPO" --id "$ID" --objective "test" 2>&1)"
rc=$?

assert_true         "spawn-crew exits non-zero when tmux new-window fails" "[ $rc -ne 0 ]"
assert_not_contains  "output contains no 'spawned' success line" "$out" "spawned "
assert_false "no roster record was left behind for a window that was never created" \
  "wm_state crew-get --id '$ID' >/dev/null 2>&1"

test_summary
