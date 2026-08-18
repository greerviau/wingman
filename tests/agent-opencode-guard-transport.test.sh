#!/usr/bin/env bash
# E2E: the opencode-plugin guard transport (the orchestrator-guard-
# transports plan, step 8) - bin/lib/guard-transport.sh's opencode branch,
# and the rendered plugin's own tool.execute.before handler exercised
# directly in a bare Node harness (no live opencode session, no network,
# no credentials needed for THIS file - the real, live, credentialed model
# turn that also confirmed this end to end was run manually during
# development and is recorded in full in bin/lib/agents/opencode.sh's own
# WM_AGENT_VERIFIED comment, not repeated here for CI reliability/network
# independence).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$TEST_REPO/bin/lib/common.sh"
. "$TEST_REPO/bin/lib/agent.sh"
. "$TEST_REPO/bin/lib/guard-transport.sh"

test_new_home
export WINGMAN_HOME

# =============================================================================
# (1) bin/lib/guard-transport.sh's opencode branch, against a fixture $HOME
# =============================================================================
OC_HOME_1="$(wm_mktemp_dir)"
out="$(HOME="$OC_HOME_1" wm_guard_transport_sync opencode-plugin "$TEST_REPO")"; rc=$?
assert_true "opencode-plugin: a healthy repo syncs and self-tests" "[ $rc -eq 0 ]"
assert_eq "opencode-plugin: success prints nothing" "$out" ""
PLUGIN_PATH="$OC_HOME_1/.config/opencode/plugins/wingman-guard.js"
assert_true "the plugin was rendered to the global plugins directory" "[ -f '$PLUGIN_PATH' ]"
assert_false "nothing was written to a project-scoped plugin dir" "[ -d '$TEST_REPO/.opencode' ]"

# Re-sync SELF-HEALS a hand-tampered installed file (sync-opencode-
# plugin.py's own reconcile step rewrites it back to the correct render,
# same as any other reconciler in this plan) - the byte-identical re-render
# check inside wm_guard_transport_sync then verifies THAT succeeded, rather
# than ever having a tampered file to compare against.
printf '// tampered\n' >> "$PLUGIN_PATH"
out="$(HOME="$OC_HOME_1" wm_guard_transport_sync opencode-plugin "$TEST_REPO")"; rc=$?
assert_true "a hand-tampered installed plugin is self-healed, not refused" "[ $rc -eq 0 ]"
assert_not_contains "the tampering is gone after resync" "$(cat "$PLUGIN_PATH")" "tampered"

# =============================================================================
# (2) a missing dispatcher refuses
# =============================================================================
BAD_REPO="$(wm_mktemp_dir)/no-dispatcher"
mkdir -p "$BAD_REPO"
OC_HOME_2="$(wm_mktemp_dir)"
out="$(HOME="$OC_HOME_2" wm_guard_transport_sync opencode-plugin "$BAD_REPO")"; rc=$?
assert_true "a repo with no dispatcher refuses" "[ $rc -ne 0 ]"
assert_contains "the refusal names the missing dispatcher" "$out" "guard_dispatch.py"

# =============================================================================
# (3) the rendered plugin's own tool.execute.before handler, exercised
# directly - no live opencode session needed, the handler is pure: stdin
# JSON in (via the dispatcher subprocess), a throw/no-throw verdict out.
# =============================================================================
OC_HOME_3="$(wm_mktemp_dir)"
uv run --no-project --quiet "$TEST_REPO/bin/lib/sync-opencode-plugin.py" \
  --plugin-path "$OC_HOME_3/wingman-guard.js" --repo "$TEST_REPO" >/dev/null 2>&1

HARNESS="$(wm_mktemp_file).mjs"
cat > "$HARNESS" <<EOF
import { WingmanGuard } from "$OC_HOME_3/wingman-guard.js";
const hooks = await WingmanGuard({ directory: process.cwd() });

async function tryCall(tool, args) {
  try {
    await hooks["tool.execute.before"]({ tool, sessionID: "s1", callID: "c1" }, { args });
    return "ALLOWED";
  } catch (e) {
    return "BLOCKED:" + e.message;
  }
}

console.log("DENY:" + await tryCall("bash", { command: "bin/watch-fleet" }));
console.log("ALLOW:" + await tryCall("bash", { command: "ls" }));
EOF
out="$(node "$HARNESS" 2>&1)"
assert_contains "the deny fixture is blocked (thrown)" "$out" "DENY:BLOCKED:bin/watch-fleet blocks until an event fires"
assert_contains "the allow fixture is not blocked" "$out" "ALLOW:ALLOWED"

# --- fail-closed: a broken WM_UV blocks BOTH fixtures, including allow ---
out_broken="$(WM_UV=/no/such/uv node "$HARNESS" 2>&1)"
# The template bakes WM_UV in at render time (not read from the environment
# at call time), so this needs a re-render with a broken uv baked in to
# actually exercise the fail-closed path realistically.
BROKEN_UV_PATH="$OC_HOME_3/wingman-guard-broken.js"
uv run --no-project --quiet "$TEST_REPO/bin/lib/sync-opencode-plugin.py" \
  --plugin-path "$BROKEN_UV_PATH" --repo "$TEST_REPO" --wm-uv "/no/such/uv" >/dev/null 2>&1
HARNESS2="$(wm_mktemp_file).mjs"
cat > "$HARNESS2" <<EOF
import { WingmanGuard } from "$BROKEN_UV_PATH";
const hooks = await WingmanGuard({ directory: process.cwd() });
async function tryCall(tool, args) {
  try {
    await hooks["tool.execute.before"]({ tool, sessionID: "s1", callID: "c1" }, { args });
    return "ALLOWED";
  } catch (e) {
    return "BLOCKED:" + e.message;
  }
}
console.log("ALLOW:" + await tryCall("bash", { command: "ls" }));
EOF
out2="$(node "$HARNESS2" 2>&1)"
assert_contains "a broken uv blocks the ALLOW fixture too (fail closed, not fail open)" "$out2" "ALLOW:BLOCKED"
rm -f "$HARNESS" "$HARNESS2"

test_summary
