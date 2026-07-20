#!/usr/bin/env bash
# E2E: bin/lib/claude-gate-check.py's trust-status subcommand, and
# bin/spawn-crew's preflight workspace-trust / Bypass-Permissions checks
# (issue #16). Proves the two gates are detected non-interactively BEFORE any
# tmux window or crew record is created - a hard, fail-fast refusal exactly
# like the existing software-development/non-git-checkout check - rather than
# ever letting the window open and freeze on a dialog for watch-fleet's
# reactive stall detection to eventually catch. bypass-status/bypass-set are
# covered separately in tests/doctor.test.sh, alongside bin/doctor's own
# wiring of the acceptance check.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

CHECK="$TEST_REPO/bin/lib/claude-gate-check.py"
run_check() { uv run --no-project --quiet "$CHECK" "$@"; }
SPAWN="$TEST_REPO/bin/spawn-crew"

WORK="$(wm_mktemp_dir)"

# --- trust-status: unit-level ---------------------------------------------------
CONFIG="$WORK/claude.json"

if run_check trust-status --config "$CONFIG" --repo "/no/such/repo" >/dev/null 2>&1; then
  fail "missing config file: trust-status reports accepted"
else
  ok "missing config file: trust-status reports not accepted"
fi

printf '{"projects": {}}\n' > "$CONFIG"
if run_check trust-status --config "$CONFIG" --repo "/no/such/repo" >/dev/null 2>&1; then
  fail "missing entry: trust-status reports accepted"
else
  ok "missing entry: trust-status reports not accepted"
fi

printf '{"projects": {"/home/x/repo": {"hasTrustDialogAccepted": false}}}\n' > "$CONFIG"
if run_check trust-status --config "$CONFIG" --repo "/home/x/repo" >/dev/null 2>&1; then
  fail "hasTrustDialogAccepted: false: trust-status reports accepted"
else
  ok "hasTrustDialogAccepted: false: trust-status reports not accepted"
fi

printf '{"projects": {"/home/x/repo": {"hasTrustDialogAccepted": true}}}\n' > "$CONFIG"
if run_check trust-status --config "$CONFIG" --repo "/home/x/repo" >/dev/null 2>&1; then
  ok "hasTrustDialogAccepted: true: trust-status reports accepted"
else
  fail "hasTrustDialogAccepted: true: trust-status reports accepted"
fi
if run_check trust-status --config "$CONFIG" --repo "/home/x/other" >/dev/null 2>&1; then
  fail "a different repo path in the same config: trust-status reports accepted"
else
  ok "a different repo path in the same config: trust-status reports not accepted"
fi

# Invalid JSON degrades safely: fails closed (not accepted), never crashes -
# this is the regression test for the torn-read risk the plan's Risks section
# rules out (Claude Code's own config writes are lock-protected and atomic),
# independent of whether that specific race could ever actually happen.
printf 'not valid json{' > "$CONFIG"
if run_check trust-status --config "$CONFIG" --repo "/home/x/repo" >/dev/null 2>&1; then
  fail "invalid JSON: trust-status reports accepted"
else
  ok "invalid JSON: trust-status fails closed (reports not accepted)"
fi

# Ancestor-inherited trust (issue #147): trust is hierarchical in Claude Code -
# accepting it for a directory trusts every descendant, so a repo nested under
# an already-trusted parent never gets its own exact-path entry set. Checking
# only the exact path false-negatives here; trust-status must walk ancestors.
printf '{"projects": {"/home/x": {"hasTrustDialogAccepted": true}}}\n' > "$CONFIG"
if run_check trust-status --config "$CONFIG" --repo "/home/x/repo" >/dev/null 2>&1; then
  ok "ancestor trusted, exact repo entry absent: trust-status reports accepted"
else
  fail "ancestor trusted, exact repo entry absent: trust-status reports accepted"
fi
if run_check trust-status --config "$CONFIG" --repo "/home/x/repo/nested/deep" >/dev/null 2>&1; then
  ok "trust inherits through multiple levels of nesting"
else
  fail "trust inherits through multiple levels of nesting"
fi
if run_check trust-status --config "$CONFIG" --repo "/home/y/repo" >/dev/null 2>&1; then
  fail "unrelated repo under a different, untrusted parent: trust-status reports accepted"
else
  ok "unrelated repo under a different, untrusted parent: trust-status reports not accepted"
fi

# An ancestor entry present but explicitly false must not short-circuit a
# deeper trusted ancestor, and must not itself grant trust.
printf '{"projects": {"/home/x": {"hasTrustDialogAccepted": false}, "/home/x/repo": {"hasTrustDialogAccepted": true}}}\n' > "$CONFIG"
if run_check trust-status --config "$CONFIG" --repo "/home/x/repo" >/dev/null 2>&1; then
  ok "exact repo trusted despite an untrusted ancestor above it"
else
  fail "exact repo trusted despite an untrusted ancestor above it"
fi
if run_check trust-status --config "$CONFIG" --repo "/home/x" >/dev/null 2>&1; then
  fail "untrusted ancestor entry alone does not grant trust"
else
  ok "untrusted ancestor entry alone does not grant trust"
fi

# --- bin/spawn-crew: preflight wiring --------------------------------------------
REPO="$(wm_mktemp_dir)/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q

export WM_SPAWN_DELAY=0 WM_SUBMIT_DELAY=0 WM_READY_TRIES=1 WM_READY_POLL=0 \
  WM_SUBMIT_POLL=0.2 WM_SUBMIT_TRIES=1
test_new_home

no_window_or_record() {
  # <id> -> "ok" iff no tmux window and no roster record exist for it - the
  # "no tmux window, no crew record, no worktree path reservation" contract
  # a hard preflight failure must uphold, exactly like the existing
  # non-git-checkout refusal.
  _id="$1"
  if tmux list-windows -t "=$WM_TMUX_SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "wm-$_id"; then
    echo "window-present"; return
  fi
  if wm_state crew-get --id "$_id" >/dev/null 2>&1; then
    echo "record-present"; return
  fi
  echo "ok"
}

# --- trust accepted, bypass accepted, default permission mode: proceeds ------
# (regression check against the existing default spawn-crew behavior)
wm_trust_repo "$REPO"
GID1="trust-ok-1"
"$SPAWN" --type software-analyst --repo "$REPO" --id "$GID1" --objective "trust accepted" >/dev/null 2>&1
rc1=$?
assert_true "trust + bypass both accepted: spawn succeeds" "[ $rc1 -eq 0 ]"
assert_true "trust + bypass both accepted: roster record exists" "wm_state crew-get --id '$GID1' >/dev/null 2>&1"

# --- trust NOT accepted for $REPO: hard refusal, no window, no record -------
UNTRUSTED_REPO="$(wm_mktemp_dir)/untrusted-repo"
mkdir -p "$UNTRUSTED_REPO"
git -C "$UNTRUSTED_REPO" init -q
GID2="trust-missing"
out2="$("$SPAWN" --type software-analyst --repo "$UNTRUSTED_REPO" --id "$GID2" --objective "trust missing" 2>&1)"
rc2=$?
assert_true "trust not accepted: spawn-crew exits non-zero" "[ $rc2 -ne 0 ]"
assert_contains "trust not accepted: message names the repo path" "$out2" "$UNTRUSTED_REPO"
assert_contains "trust not accepted: message names the remedy" "$out2" "accept the trust dialog"
assert_eq "trust not accepted: no window and no roster record" "$(no_window_or_record "$GID2")" "ok"

# --- ancestor-inherited trust (issue #147): trust granted on the parent, not
# the repo itself - spawn-crew must still proceed, end to end -----------------
ANCESTOR_PARENT="$(wm_mktemp_dir)/ancestor-parent"
NESTED_REPO="$ANCESTOR_PARENT/nested-repo"
mkdir -p "$NESTED_REPO"
git -C "$NESTED_REPO" init -q
wm_trust_repo "$ANCESTOR_PARENT"
GID2B="trust-inherited"
out2b="$("$SPAWN" --type software-analyst --repo "$NESTED_REPO" --id "$GID2B" --objective "trust inherited from ancestor" 2>&1)"
rc2b=$?
assert_true "ancestor-inherited trust: spawn succeeds (issue #147)" "[ $rc2b -eq 0 ]"
assert_true "ancestor-inherited trust: roster record exists" "wm_state crew-get --id '$GID2B' >/dev/null 2>&1"

# --- bypass NOT accepted, trust fine, default permission mode ---------------
# Default permission mode resolves PERM_MODE=bypassPermissions (WM_PERMISSION_MODE
# unset), so the bypass re-check is in effect and must fire.
NOBYPASS_SETTINGS="$WORK/no-bypass-settings.json"
printf '{}\n' > "$NOBYPASS_SETTINGS"
GID3="bypass-missing"
out3="$(WM_CLAUDE_USER_SETTINGS="$NOBYPASS_SETTINGS" "$SPAWN" --type software-analyst --repo "$REPO" --id "$GID3" --objective "bypass missing" 2>&1)"
rc3=$?
assert_true "bypass not accepted: spawn-crew exits non-zero" "[ $rc3 -ne 0 ]"
assert_contains "bypass not accepted: message names bin/doctor -y as the remedy" "$out3" "bin/doctor -y"
assert_eq "bypass not accepted: no window and no roster record" "$(no_window_or_record "$GID3")" "ok"

# --- WM_PERMISSION_MODE= (empty): bypass mode disabled, its re-check is skipped
# entirely, even with bypass unaccepted - the dialog it guards against never
# appears in this configuration (round-1 review finding #1).
GID4="bypass-mode-disabled"
WM_CLAUDE_USER_SETTINGS="$NOBYPASS_SETTINGS" WM_PERMISSION_MODE= "$SPAWN" --type software-analyst --repo "$REPO" --id "$GID4" --objective "interactive mode" >/dev/null 2>&1
rc4=$?
assert_true "WM_PERMISSION_MODE= with bypass unaccepted: spawn still succeeds" "[ $rc4 -eq 0 ]"
assert_true "WM_PERMISSION_MODE= with bypass unaccepted: roster record exists" "wm_state crew-get --id '$GID4' >/dev/null 2>&1"

# --- global scope: the trust check runs against the discovered, -P-normalized
# workspace root (not any individual --add-dir target) -----------------------
WS="$(wm_mktemp_dir)/workspace"
mkdir -p "$WS/subrepo"
git -C "$WS/subrepo" init -q
CFG="$TEST_REPO/config.local.sh"
if [ -e "$CFG" ]; then
  echo "SKIP: $CFG exists; not overwriting - global-scope cases skipped"
else
  printf 'WM_ROOTS=%q\n' "$WS" > "$CFG"
  wm_on_exit "rm -f '$CFG'"

  GID5="global-untrusted"
  out5="$("$SPAWN" --type software-analyst --scope global --id "$GID5" --objective "global untrusted" 2>&1)"
  rc5=$?
  assert_true "global scope, workspace root not trusted: spawn-crew exits non-zero" "[ $rc5 -ne 0 ]"
  assert_contains "global scope, not trusted: message names the workspace root" "$out5" "$WS"
  assert_eq "global scope, not trusted: no window and no roster record" "$(no_window_or_record "$GID5")" "ok"
  assert_false "global scope, not trusted: the check never treats subrepo as the target" \
    "printf '%s' '$out5' | grep -q '$WS/subrepo'"

  wm_trust_repo "$WS"
  GID6="global-trusted"
  "$SPAWN" --type software-analyst --scope global --id "$GID6" --objective "global trusted" >/dev/null 2>&1
  rc6=$?
  assert_true "global scope, workspace root trusted: spawn succeeds" "[ $rc6 -eq 0 ]"
  assert_true "global scope, workspace root trusted: roster record exists" "wm_state crew-get --id '$GID6' >/dev/null 2>&1"
fi

# --- worktree-adjacent regression: the preflight check reads $REPO only -----
# (there is no worktree path to check yet at this point in spawn-crew - a
# developer-type spawn against an already-trusted repo succeeds and records
# a worktree path without any separate trust check against it, matching the
# existing z15 finding that a worktree carved out of a trusted repo needs no
# trust dialog of its own).
GID7="worktree-adjacent"
"$SPAWN" --type developer --repo "$REPO" --id "$GID7" --objective "worktree adjacent" >/dev/null 2>&1
rc7=$?
assert_true "developer spawn against a trusted repo succeeds" "[ $rc7 -eq 0 ]"
wt7="$(wm_state crew-get --id "$GID7" | uv run --no-project --quiet python -c 'import sys,json; print(json.load(sys.stdin).get("worktree") or "")')"
assert_contains "the record carries a worktree path, never separately trust-checked" "$wt7" "$GID7"

test_summary
