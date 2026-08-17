#!/usr/bin/env bash
# E2E: the pi-extension guard transport (the orchestrator-guard-transports
# plan, step 5 - built first because pi is the only transport hands-on
# verifiable today). Exercises bin/lib/agents/pi/wingman-guard-extension.js
# directly (its tool_call handler, without needing a real pi model turn -
# see this file's own header on why that gate stays out of reach here) and
# bin/lib/guard-transport.sh's pi-extension branch against the REAL
# installed pi binary this environment happens to have.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$TEST_REPO/bin/lib/common.sh"
. "$TEST_REPO/bin/lib/agent.sh"
. "$TEST_REPO/bin/lib/guard-transport.sh"

EXT="$TEST_REPO/bin/lib/agents/pi/wingman-guard-extension.js"

# =============================================================================
# (1) the extension file itself is well-formed, plain ESM JavaScript
# =============================================================================
assert_true "the extension file exists" "[ -f '$EXT' ]"
assert_true "node --check passes (plain JS, no TypeScript syntax)" "node --check '$EXT'"

# =============================================================================
# (2) the tool_call handler, exercised directly in a bare Node harness - no
# live pi session or model credential needed, since the handler is pure:
# stdin JSON in (via the dispatcher subprocess), a block/allow verdict out.
# =============================================================================
HARNESS="$(wm_mktemp_file).mjs"
cat > "$HARNESS" <<EOF
import * as mod from "$EXT";
const handlers = {};
const flags = {};
const fakePi = {
  registerFlag: (name, opts) => { flags[name] = opts; },
  on: (event, handler) => { handlers[event] = handler; },
};
mod.default(fakePi);

const denyEvent = { toolName: "bash", input: { command: "bin/watch-fleet" } };
const allowEvent = { toolName: "bash", input: { command: "ls" } };

const deny = await handlers.tool_call(denyEvent, {});
const allow = await handlers.tool_call(allowEvent, {});

console.log("FLAG_REGISTERED:" + ("wingman-guard-active" in flags));
console.log("FLAG_TYPE:" + (flags["wingman-guard-active"] || {}).type);
console.log("DENY_BLOCK:" + JSON.stringify(deny && deny.block));
console.log("DENY_REASON_HAS_TEXT:" + Boolean(deny && deny.reason && deny.reason.length > 0));
console.log("ALLOW_RESULT:" + JSON.stringify(allow));
EOF

out="$(node "$HARNESS" 2>&1)"
assert_contains "registerFlag was called for wingman-guard-active" "$out" "FLAG_REGISTERED:true"
assert_contains "the registered flag is boolean-typed" "$out" "FLAG_TYPE:boolean"
assert_contains "the deny fixture (bin/watch-fleet) is blocked" "$out" "DENY_BLOCK:true"
assert_contains "the deny verdict carries a reason" "$out" "DENY_REASON_HAS_TEXT:true"
assert_contains "the allow fixture (ls) is NOT blocked (undefined result = no comment)" "$out" "ALLOW_RESULT:undefined"

# --- fail-closed: a broken WM_UV (dispatcher cannot even spawn) blocks BOTH
# fixtures, including the allow one - the shim's own core inversion.
out_broken="$(WM_UV=/no/such/uv node "$HARNESS" 2>&1)"
assert_contains "a spawn failure blocks the deny fixture too" "$out_broken" "DENY_BLOCK:true"
assert_contains "a spawn failure blocks the ALLOW fixture as well (fail closed, not fail open)" "$out_broken" 'ALLOW_RESULT:{"block":true'
rm -f "$HARNESS"

# =============================================================================
# (3) bin/lib/guard-transport.sh's pi-extension branch, against the real
# installed pi binary (this environment has one - /home/*/.local/bin/pi)
# =============================================================================
if ! wm_have pi; then
  echo "SKIP: no real pi binary on PATH in this environment - skipping the guard-transport.sh integration checks"
else
  test_new_home
  export WINGMAN_HOME
  . "$TEST_REPO/bin/lib/common.sh"
  # tests/lib.sh's default WM_AGENT_BIN_OVERRIDE (a harmless stub) would
  # otherwise win over pi's own real WM_AGENT_BIN - unset it here, the same
  # pattern tests/orchestrator-guard-sync-gate.test.sh uses for a real launch.
  unset WM_AGENT_BIN_OVERRIDE
  wm_agent_resolve pi

  out="$(wm_guard_transport_sync pi-extension "$TEST_REPO")"; rc=$?
  assert_true "pi-extension: a healthy repo syncs and self-tests against the real binary" "[ $rc -eq 0 ]"
  assert_eq "pi-extension: success prints nothing" "$out" ""

  # --wingman-guard-active is observable, offline, credential-free
  help_out="$(timeout 20 pi --offline -e "$EXT" --no-extensions --help 2>&1)"
  flag_count=$(printf '%s' "$help_out" | grep -c -- --wingman-guard-active)
  assert_eq "pi --help shows --wingman-guard-active exactly once when loaded" "$flag_count" "1"

  help_out_noext="$(timeout 20 pi --offline --no-extensions --help 2>&1)"
  flag_count_noext=$(printf '%s' "$help_out_noext" | grep -c -- --wingman-guard-active)
  assert_eq "pi --help shows it zero times when NOT loaded" "$flag_count_noext" "0"

  # A missing extension file refuses.
  BADREPO="$(wm_mktemp_dir)"
  out="$(wm_guard_transport_sync pi-extension "$BADREPO")"; rc=$?
  assert_true "pi-extension: a repo missing the extension file refuses" "[ $rc -ne 0 ]"
  assert_contains "the refusal names the missing extension path" "$out" "wingman-guard-extension.js"
fi

test_summary
