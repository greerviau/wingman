#!/usr/bin/env bash
# E2E: bin/lib/sync-codex-hooks.py - the codex-json guard transport's
# reconciler (the orchestrator-guard-transports plan, step 7). Mirrors
# tests/sync-grok-hooks.test.sh's own coverage shape, plus codex's own two
# extra hazards: the [features].hooks probe and the foreign-hook-source
# refusal (both required because bin/lib/agents/codex.sh's launch line
# carries --dangerously-bypass-hook-trust, which un-gates every hook source,
# not only wingman's own).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SYNC="$TEST_REPO/bin/lib/sync-codex-hooks.py"
WORK="$(wm_mktemp_dir)"
NO_REQ="$WORK/no-such-requirements.toml"

run_sync() {
  # run_sync <codex-home> <repo> [extra args...]
  _rs_home="$1"; _rs_repo="$2"; shift 2
  uv run --no-project --quiet "$SYNC" --codex-home "$_rs_home" --repo "$_rs_repo" --requirements-toml "$NO_REQ" "$@"
}

# =============================================================================
# fresh install
# =============================================================================
CH1="$WORK/home1"
out="$(run_sync "$CH1" "$TEST_REPO" 2>&1)"; rc=$?
assert_true "fresh install exits 0" "[ $rc -eq 0 ]"
assert_true "the file was written to \$CODEX_HOME/hooks.json" "[ -f '$CH1/hooks.json' ]"

content="$(cat "$CH1/hooks.json")"
assert_contains "the matcher covers Bash/apply_patch/Edit/Write" "$content" '"^(Bash|apply_patch|Edit|Write)$"'
assert_contains "the command targets the real dispatcher" "$content" "hooks/lib/guard_dispatch.py"
assert_contains "the dialect is codex" "$content" "--dialect codex"
assert_contains "the timeout is raised to 30" "$content" '"timeout": 30'
assert_contains "the guards list names direct-edit" "$content" "direct-edit"
assert_not_contains "crew-only merge is NOT in the guards list" "$content" ",merge,"

# =============================================================================
# idempotent re-run
# =============================================================================
mtime_before="$(stat -c %Y "$CH1/hooks.json" 2>/dev/null || stat -f %m "$CH1/hooks.json")"
sleep 1
out="$(run_sync "$CH1" "$TEST_REPO" --check 2>&1)"; rc=$?
assert_true "--check reports already up to date" "[ $rc -eq 0 ]"
mtime_after="$(stat -c %Y "$CH1/hooks.json" 2>/dev/null || stat -f %m "$CH1/hooks.json")"
assert_eq "the file was not rewritten" "$mtime_after" "$mtime_before"

# =============================================================================
# a stale file is updated in place
# =============================================================================
cat > "$CH1/hooks.json" <<'EOF'
{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "stale", "timeout": 5}]}]}}
EOF
out="$(run_sync "$CH1" "$TEST_REPO" 2>&1)"; rc=$?
assert_true "a stale file is rewritten" "[ $rc -eq 0 ]"
assert_not_contains "the stale command is gone" "$(cat "$CH1/hooks.json")" '"command": "stale"'

# =============================================================================
# fail-closed: missing dispatcher
# =============================================================================
BAD_REPO="$(wm_mktemp_dir)/no-dispatcher"
mkdir -p "$BAD_REPO"
CH2="$WORK/home2"
out="$(run_sync "$CH2" "$BAD_REPO" 2>&1)"; rc=$?
assert_true "a missing dispatcher refuses" "[ $rc -ne 0 ]"
assert_contains "the failure names the missing dispatcher" "$out" "guard_dispatch.py"
assert_false "nothing was written" "[ -f '$CH2/hooks.json' ]"

# =============================================================================
# fail-closed: unparseable existing file
# =============================================================================
CH3="$WORK/home3"
mkdir -p "$CH3"
printf 'not json' > "$CH3/hooks.json"
out="$(run_sync "$CH3" "$TEST_REPO" 2>&1)"; rc=$?
assert_true "an unparseable existing file refuses" "[ $rc -ne 0 ]"
assert_eq "the broken file is left untouched" "$(cat "$CH3/hooks.json")" "not json"

# =============================================================================
# [features].hooks = false in $CODEX_HOME/config.toml refuses
# =============================================================================
CH4="$WORK/home4"
mkdir -p "$CH4"
cat > "$CH4/config.toml" <<'EOF'
[features]
hooks = false
EOF
out="$(run_sync "$CH4" "$TEST_REPO" 2>&1)"; rc=$?
assert_true "[features].hooks = false refuses" "[ $rc -ne 0 ]"
assert_contains "the refusal names the config file" "$out" "$CH4/config.toml"
assert_false "nothing was written" "[ -f '$CH4/hooks.json' ]"

# The deprecated codex_hooks alias, also under [features], refuses too.
CH5="$WORK/home5"
mkdir -p "$CH5"
cat > "$CH5/config.toml" <<'EOF'
[features]
codex_hooks = false
EOF
out="$(run_sync "$CH5" "$TEST_REPO" 2>&1)"; rc=$?
assert_true "the deprecated codex_hooks alias also refuses" "[ $rc -ne 0 ]"

# hooks = true (explicit) proceeds normally - absence is not required.
CH6="$WORK/home6"
mkdir -p "$CH6"
cat > "$CH6/config.toml" <<'EOF'
[features]
hooks = true
EOF
out="$(run_sync "$CH6" "$TEST_REPO" 2>&1)"; rc=$?
assert_true "hooks = true (explicit) proceeds" "[ $rc -eq 0 ]"

# An UNRELATED false under [features] (some other flag) does not trip this.
CH7="$WORK/home7"
mkdir -p "$CH7"
cat > "$CH7/config.toml" <<'EOF'
[features]
some_unrelated_flag = false
EOF
out="$(run_sync "$CH7" "$TEST_REPO" 2>&1)"; rc=$?
assert_true "an unrelated false flag does not trip the probe" "[ $rc -eq 0 ]"

# The admin-managed requirements.toml layer refuses too, independent of the
# user's own config.toml.
CH8="$WORK/home8"
REQ8="$WORK/requirements8.toml"
cat > "$REQ8" <<'EOF'
[features]
hooks = false
EOF
out="$(uv run --no-project --quiet "$SYNC" --codex-home "$CH8" --repo "$TEST_REPO" --requirements-toml "$REQ8" 2>&1)"; rc=$?
assert_true "requirements.toml [features].hooks=false refuses (admin layer, no user override)" "[ $rc -ne 0 ]"
assert_contains "the refusal names the requirements.toml layer" "$out" "$REQ8"

# =============================================================================
# foreign hook source: <repo>/.codex/hooks.json refuses
# =============================================================================
FOREIGN_REPO="$WORK/foreign-repo"
mkdir -p "$FOREIGN_REPO/.codex"
echo '{}' > "$FOREIGN_REPO/.codex/hooks.json"
CH9="$WORK/home9"
out="$(run_sync "$CH9" "$FOREIGN_REPO" 2>&1)"; rc=$?
assert_true "a foreign <repo>/.codex/hooks.json refuses" "[ $rc -ne 0 ]"
assert_contains "the refusal names the foreign source" "$out" "$FOREIGN_REPO/.codex/hooks.json"
assert_false "nothing was written" "[ -f '$CH9/hooks.json' ]"

# foreign hook source: inline [hooks] in <repo>/.codex/config.toml refuses
FOREIGN_REPO2="$WORK/foreign-repo2"
mkdir -p "$FOREIGN_REPO2/.codex"
cat > "$FOREIGN_REPO2/.codex/config.toml" <<'EOF'
[hooks]
PreToolUse = []
EOF
CH10="$WORK/home10"
out="$(run_sync "$CH10" "$FOREIGN_REPO2" 2>&1)"; rc=$?
assert_true "inline [hooks] in <repo>/.codex/config.toml refuses" "[ $rc -ne 0 ]"
assert_contains "the refusal names the config.toml source" "$out" "$FOREIGN_REPO2/.codex/config.toml"

# foreign hook source: inline [hooks] in \$CODEX_HOME/config.toml refuses
CH11="$WORK/home11"
mkdir -p "$CH11"
cat > "$CH11/config.toml" <<'EOF'
[hooks]
PreToolUse = []
EOF
out="$(run_sync "$CH11" "$TEST_REPO" 2>&1)"; rc=$?
assert_true "inline [hooks] in \$CODEX_HOME/config.toml refuses" "[ $rc -ne 0 ]"

# a repo with NO foreign sources at all proceeds normally.
CH12="$WORK/home12"
out="$(run_sync "$CH12" "$TEST_REPO" 2>&1)"; rc=$?
assert_true "no foreign sources: proceeds normally" "[ $rc -eq 0 ]"

test_summary
