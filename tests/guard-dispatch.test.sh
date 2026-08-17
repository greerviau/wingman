#!/usr/bin/env bash
# E2E: hooks/lib/guard_dispatch.py - the single entry point every non-Claude
# guard transport (codex-json, grok-json, opencode-plugin, pi-extension)
# invokes (the orchestrator-guard-transports plan, §5.1/§5.3). Table-driven,
# no real CLI involved: each case feeds a fixture in one dialect's own
# payload shape and asserts the dialect's own deny/allow contract.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

DISPATCH="$TEST_REPO/hooks/lib/guard_dispatch.py"
ALL_GUARDS="direct-edit,watcher-kill,spawn-pause,merge,worker-spawn,foreground-watcher,foreground-poll-loop"

run_dispatch() {
  # run_dispatch <dialect> <guards> <payload-json>
  printf '%s' "$3" | uv run --no-project --quiet "$DISPATCH" --dialect "$1" --guards "$2"
}

test_new_home
export WINGMAN_HOME
unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

# =============================================================================
# (a) deny form + exit status per dialect, both channels where documented
# =============================================================================
DENY_CMD='bin/watch-fleet'

codex_payload() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }
grok_payload()  { printf '{"toolName":"Bash","toolInput":{"command":"%s"}}' "$1"; }
opencode_payload() { printf '{"tool":"bash","args":{"command":"%s"}}' "$1"; }
pi_payload() { printf '{"toolName":"bash","input":{"command":"%s"}}' "$1"; }

out_codex="$(run_dispatch codex foreground-watcher "$(codex_payload "$DENY_CMD")" 2>/tmp/wm-gd-stderr-codex)"
rc_codex=$?
assert_eq "codex: deny exits 2" "$rc_codex" "2"
assert_contains "codex: deny stdout carries hookSpecificOutput" "$out_codex" '"permissionDecision": "deny"'
assert_contains "codex: deny reason also lands on stderr" "$(cat /tmp/wm-gd-stderr-codex)" "bin/watch-fleet blocks until an event fires"

out_grok="$(run_dispatch grok foreground-watcher "$(grok_payload "$DENY_CMD")" 2>/tmp/wm-gd-stderr-grok)"
rc_grok=$?
assert_eq "grok: deny exits 2" "$rc_grok" "2"
assert_contains "grok: deny stdout carries decision:deny" "$out_grok" '"decision": "deny"'
assert_contains "grok: deny reason also lands on stderr" "$(cat /tmp/wm-gd-stderr-grok)" "bin/watch-fleet blocks until an event fires"

out_opencode="$(run_dispatch opencode foreground-watcher "$(opencode_payload "$DENY_CMD")" 2>/tmp/wm-gd-stderr-opencode)"
rc_opencode=$?
assert_eq "opencode: deny exits 2" "$rc_opencode" "2"
assert_contains "opencode: deny stdout carries decision:deny" "$out_opencode" '"decision": "deny"'
assert_eq "opencode: nothing on stderr (shim reads stdout only)" "$(cat /tmp/wm-gd-stderr-opencode)" ""

out_pi="$(run_dispatch pi foreground-watcher "$(pi_payload "$DENY_CMD")" 2>/tmp/wm-gd-stderr-pi)"
rc_pi=$?
assert_eq "pi: deny exits 2" "$rc_pi" "2"
assert_contains "pi: deny stdout carries decision:deny" "$out_pi" '"decision": "deny"'
assert_eq "pi: nothing on stderr (shim reads stdout only)" "$(cat /tmp/wm-gd-stderr-pi)" ""
rm -f /tmp/wm-gd-stderr-codex /tmp/wm-gd-stderr-grok /tmp/wm-gd-stderr-opencode /tmp/wm-gd-stderr-pi

# =============================================================================
# (b) allow: silence + exit 0 for the two file-based dialects; an explicit
# allow verdict + exit 0 for the two shim dialects
# =============================================================================
out_codex="$(run_dispatch codex foreground-watcher "$(codex_payload "ls")")"; rc_codex=$?
assert_eq "codex: allow is silence" "$out_codex" ""
assert_eq "codex: allow exits 0" "$rc_codex" "0"

out_grok="$(run_dispatch grok foreground-watcher "$(grok_payload "ls")")"; rc_grok=$?
assert_eq "grok: allow is silence" "$out_grok" ""
assert_eq "grok: allow exits 0" "$rc_grok" "0"

out_opencode="$(run_dispatch opencode foreground-watcher "$(opencode_payload "ls")")"; rc_opencode=$?
assert_eq "opencode: allow is an explicit verdict" "$out_opencode" '{"decision": "allow"}'
assert_eq "opencode: allow exits 0" "$rc_opencode" "0"

out_pi="$(run_dispatch pi foreground-watcher "$(pi_payload "ls")")"; rc_pi=$?
assert_eq "pi: allow is an explicit verdict" "$out_pi" '{"decision": "allow"}'
assert_eq "pi: allow exits 0" "$rc_pi" "0"

# =============================================================================
# (c) malformed payload takes the PER-GUARD fail direction, not a blanket rule
# =============================================================================
# A malformed (non-JSON) stdin payload degrades to an empty {} object - the
# identical json.load(sys.stdin) except-Exception-then-{} pattern every real
# claude .sh entry point already uses (e.g. hooks/no-worker-spawn-guard.sh),
# which reads as tool_name="" and so no guard applies (allow) - proven
# against the real .sh directly below, not merely asserted about the
# dispatcher in isolation.
export WINGMAN_CREW_ID=dev1 WINGMAN_CREW_TYPE=developer
real_hook_out="$(printf 'not json at all' | bash "$TEST_REPO/hooks/no-worker-spawn-guard.sh")"; real_hook_rc=$?
assert_eq "reference: the real claude .sh also allows on malformed stdin" "$real_hook_rc" "0"
out="$(printf 'not json at all' | uv run --no-project --quiet "$DISPATCH" --dialect codex --guards worker-spawn)"; rc=$?
assert_eq "codex: malformed stdin degrades like the real hook does (allow)" "$rc" "0"
assert_eq "codex: malformed-stdin output matches the real hook's (silence)" "$out" "$real_hook_out"
unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

# spawn-pause fails OPEN on a missing/malformed STATE FILE (not the payload
# itself) - matching hooks/lib/guard_policy.py's evaluate_spawn_pause_guards
# and its own upstream hooks' documented fail-open-on-missing-state posture.
rm -f "$WINGMAN_HOME/api-outage-state.json" "$WINGMAN_HOME/usage-limit-state.json"
out="$(run_dispatch codex spawn-pause "$(codex_payload "bin/spawn-crew --type developer --repo x --objective y")")"; rc=$?
assert_eq "codex: spawn-pause with no state files present fails open (allow)" "$rc" "0"
assert_eq "codex: spawn-pause allow is silence too" "$out" ""

# =============================================================================
# (d) run_in_background-absent denies for the two wake-loop guards, with a
# dialect-aware reason (none of the four non-Claude CLIs has a background
# tool-call mode for a model-issued call)
# =============================================================================
for D in codex grok opencode pi; do
  case "$D" in
    codex) P="$(codex_payload "$DENY_CMD")" ;;
    grok) P="$(grok_payload "$DENY_CMD")" ;;
    opencode) P="$(opencode_payload "$DENY_CMD")" ;;
    pi) P="$(pi_payload "$DENY_CMD")" ;;
  esac
  out="$(run_dispatch "$D" foreground-watcher "$P")"
  assert_contains "$D: foreground-watcher denial names this CLI has no background tool-call mode" \
    "$out" "This CLI ($D) has no background tool-call mode for a model-issued call"
done

POLL_LOOP_CMD='while true; do sleep 5; done'
for D in codex grok opencode pi; do
  case "$D" in
    codex) P="$(codex_payload "$POLL_LOOP_CMD")" ;;
    grok) P="$(grok_payload "$POLL_LOOP_CMD")" ;;
    opencode) P="$(opencode_payload "$POLL_LOOP_CMD")" ;;
    pi) P="$(pi_payload "$POLL_LOOP_CMD")" ;;
  esac
  out="$(run_dispatch "$D" foreground-poll-loop "$P")"
  assert_contains "$D: foreground-poll-loop denial names this CLI has no background tool-call mode" \
    "$out" "This CLI ($D) has no background tool-call mode for a model-issued call"
done

# =============================================================================
# guard ordering: --guards lists guards in a NON-canonical order; the fixed
# canonical order (worker-spawn before foreground-watcher) still decides
# which denial wins - proves the dispatcher does not simply honor flag order.
# =============================================================================
export WINGMAN_CREW_ID=dev1 WINGMAN_CREW_TYPE=developer
out="$(run_dispatch codex "foreground-watcher,worker-spawn" "$(codex_payload "bin/spawn-crew --type developer --repo x --objective y")")"
assert_contains "canonical order wins over flag order: worker-spawn (not foreground-watcher) denies a spawn-crew call" \
  "$out" "Spawning crew is not yours to do"
unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

# =============================================================================
# tool-name mapping: codex's apply_patch and opencode/pi's lowercase names
# both resolve to the guards' own Claude-shaped Edit/Bash expectations
# =============================================================================
export WINGMAN_CREW_TYPE=lead
EDIT_REPO="$(wm_mktemp_dir)/edit-repo"
mkdir -p "$EDIT_REPO"
git -C "$EDIT_REPO" init -q
out="$(printf '{"tool_name":"apply_patch","tool_input":{"file_path":"%s/x.py"}}' "$EDIT_REPO" | \
  uv run --no-project --quiet "$DISPATCH" --dialect codex --guards direct-edit)"
assert_contains "codex: apply_patch maps to Edit for the direct-edit guard" "$out" "Direct Edit calls are not yours to make"

out="$(printf '{"tool":"edit","args":{"filePath":"%s/x.py"}}' "$EDIT_REPO" | \
  uv run --no-project --quiet "$DISPATCH" --dialect opencode --guards direct-edit)"
assert_contains "opencode: lowercase edit maps to Edit for the direct-edit guard" "$out" "Direct Edit calls are not yours to make"
unset WINGMAN_CREW_TYPE

# =============================================================================
# --emit-fixture: deterministic, dialect-shaped, and round-trips through this
# same module's own parser
# =============================================================================
for D in codex grok opencode pi; do
  deny_fx="$(uv run --no-project --quiet "$DISPATCH" --emit-fixture "$D" --case deny)"
  allow_fx="$(uv run --no-project --quiet "$DISPATCH" --emit-fixture "$D" --case allow)"
  assert_contains "$D: deny fixture mentions watch-fleet" "$deny_fx" "watch-fleet"
  out="$(printf '%s' "$deny_fx" | uv run --no-project --quiet "$DISPATCH" --dialect "$D" --guards foreground-watcher)"; rc=$?
  assert_eq "$D: deny fixture, run through this dialect's own foreground-watcher guard, denies" "$rc" "2"
  out="$(printf '%s' "$allow_fx" | uv run --no-project --quiet "$DISPATCH" --dialect "$D" --guards "$ALL_GUARDS")"; rc=$?
  assert_eq "$D: allow fixture, run through every guard, allows" "$rc" "0"
done

# =============================================================================
# an unknown --guards entry is a hard error, not silently ignored
# =============================================================================
out="$(printf '{}' | uv run --no-project --quiet "$DISPATCH" --dialect codex --guards bogus-guard 2>&1)"; rc=$?
assert_true "an unknown guard name fails" "[ $rc -ne 0 ]"
assert_contains "the failure names the unknown guard" "$out" "bogus-guard"

# =============================================================================
# a payload shape none of the parsers expect (tool_input/toolInput/args/input
# is a string, not an object) never reaches an uncaught exception - it takes
# the SAME per-dialect fail direction an uncaught crash would produce
# externally (codex/grok fail-open on a crashed hook, matching claude's own
# equivalent .sh hooks for this exact shape; opencode/pi's own shims fail
# closed on any dispatcher failure), but as a deliberate, tested branch
# rather than an accident of exception propagation.
# =============================================================================
MALFORMED_CODEX='{"tool_name":"Bash","tool_input":"rm -rf /"}'
MALFORMED_GROK='{"toolName":"Bash","toolInput":"rm -rf /"}'
MALFORMED_OPENCODE='{"tool":"bash","args":"rm -rf /"}'
MALFORMED_PI='{"toolName":"bash","input":"rm -rf /"}'

out="$(printf '%s' "$MALFORMED_CODEX" | uv run --no-project --quiet "$DISPATCH" --dialect codex --guards direct-edit)"; rc=$?
assert_eq "codex: a malformed tool_input allows (fail-open, matching claude's own equivalent hooks)" "$rc" "0"
assert_eq "codex: ...and prints nothing" "$out" ""

out="$(printf '%s' "$MALFORMED_GROK" | uv run --no-project --quiet "$DISPATCH" --dialect grok --guards direct-edit)"; rc=$?
assert_eq "grok: a malformed toolInput allows (fail-open)" "$rc" "0"

out="$(printf '%s' "$MALFORMED_OPENCODE" | uv run --no-project --quiet "$DISPATCH" --dialect opencode --guards direct-edit)"; rc=$?
assert_eq "opencode: a malformed args denies (the shim's own fail-closed posture)" "$rc" "2"
assert_contains "opencode: the denial names the parse failure" "$out" "could not parse this payload"

out="$(printf '%s' "$MALFORMED_PI" | uv run --no-project --quiet "$DISPATCH" --dialect pi --guards direct-edit)"; rc=$?
assert_eq "pi: a malformed input denies (the shim's own fail-closed posture)" "$rc" "2"
assert_contains "pi: the denial names the parse failure" "$out" "could not parse this payload"

test_summary
