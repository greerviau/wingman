#!/usr/bin/env bash
# E2E: issue #79 - bin/spawn-crew must not report success (or hand back a crew id)
# unless the roster write is confirmed. Proves both failure branches Fix 1 adds:
# (1) `wm_state crew-add` itself fails (exit status now checked, where it used to
# be silently discarded), and (2) crew-add reports success but the immediate
# verify-after-write `crew-get` read-back fails (the belt to #93's locking-fix
# suspenders). Either way: the transiently-created tmux window is torn down, no
# "spawned" success line or crew id is printed, and the caller gets a loud,
# non-zero-exit failure instead of a live, untracked session.
#
# WM_UV (bin/lib/common.sh:30, already env-overridable) is pointed at a small
# wrapper that forwards every wm-state subcommand to the real `uv run --no-project
# --quiet` except the one being deterministically poisoned - this fails only the
# load-bearing call, without corrupting anything else spawn-crew touches (a
# blanket-unwritable WINGMAN_HOME would also break the sysprompt/launch-script
# writes that happen earlier in the script).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SPAWN="$TEST_REPO/bin/spawn-crew"

REPO="$(wm_mktemp_dir)/throwaway-repo"
mkdir -p "$REPO"
git -C "$REPO" init -q

test_new_home

WRAP_DIR="$(wm_mktemp_dir)"

# Wrapper 1: crew-add itself fails deterministically, every other subcommand
# (the uniqueness-check crew-get loop, etc.) is forwarded unchanged.
WRAP_ADD="$WRAP_DIR/wm-uv-fail-add.sh"
cat > "$WRAP_ADD" <<'EOF'
#!/usr/bin/env bash
set -u
if [ "${2:-}" = "crew-add" ]; then
  echo "simulated crew-add failure (test)" >&2
  exit 1
fi
exec uv run --no-project --quiet "$@"
EOF
chmod +x "$WRAP_ADD"

# Wrapper 2: crew-add succeeds for real; only the immediately-following
# verify-after-write crew-get call fails.
WRAP_GET="$WRAP_DIR/wm-uv-fail-get.sh"
cat > "$WRAP_GET" <<'EOF'
#!/usr/bin/env bash
set -u
if [ "${2:-}" = "crew-get" ]; then
  echo "simulated crew-get failure (test)" >&2
  exit 1
fi
exec uv run --no-project --quiet "$@"
EOF
chmod +x "$WRAP_GET"

# --- scenario 1: crew-add itself fails ----------------------------------------
ID1="spawn-crew-fail-test"
out1="$(WM_UV="$WRAP_ADD" "$SPAWN" --type developer --repo "$REPO" --id "$ID1" --objective "test" 2>&1)"
rc1=$?
last1="$(printf '%s\n' "$out1" | tail -1)"
win1="$(tmux list-windows -t "=$WM_TMUX_SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "wm-$ID1" && echo present || echo absent)"

assert_true         "scenario 1: spawn-crew exits non-zero when crew-add fails" "[ $rc1 -ne 0 ]"
assert_not_contains  "scenario 1: output contains no 'spawned' success line" "$out1" "spawned "
if [ "$last1" != "$ID1" ]; then ok "scenario 1: the last output line is not the crew id"
else fail "scenario 1: the last output line is not the crew id"; fi
assert_false "scenario 1: no roster record was left behind" "wm_state crew-get --id '$ID1' >/dev/null 2>&1"
assert_eq "scenario 1: the transient window was torn down" "$win1" "absent"

# --- scenario 2: crew-add succeeds, the verify-after-write read-back fails ----
ID2="spawn-crew-fail-test-2"
out2="$(WM_UV="$WRAP_GET" "$SPAWN" --type developer --repo "$REPO" --id "$ID2" --objective "test" 2>&1)"
rc2=$?
last2="$(printf '%s\n' "$out2" | tail -1)"
win2="$(tmux list-windows -t "=$WM_TMUX_SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "wm-$ID2" && echo present || echo absent)"

assert_true        "scenario 2: spawn-crew exits non-zero when the read-back fails" "[ $rc2 -ne 0 ]"
assert_not_contains "scenario 2: output contains no 'spawned' success line" "$out2" "spawned "
if [ "$last2" != "$ID2" ]; then ok "scenario 2: the last output line is not the crew id"
else fail "scenario 2: the last output line is not the crew id"; fi
assert_eq "scenario 2: the transient window was torn down" "$win2" "absent"

test_summary
