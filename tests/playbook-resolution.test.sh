#!/usr/bin/env bash
# E2E: playbook resolution across playbooks/<category>/<role>.md. Proves bare
# unique names resolve via recursive search, category-qualified names resolve
# directly, .local.md wins over its sibling .md, unknown types are rejected, a
# --type containing find(1) glob metacharacters is matched literally rather
# than as a pattern, cross-category name collisions error out deterministically
# listing the qualified forms, --list-types emits category-qualified names and
# excludes _-prefixed partials, and the shared status contract is still
# concatenated onto a spawned member's system prompt. Uses a stub agent
# (WM_AGENT), an isolated tmux session, and an isolated WM_PLAYBOOKS fixture
# tree (WM_PLAYBOOKS is override-friendly, like WM_HOME) so this suite never
# reads or writes the live repo's own playbooks/ directory - resolution
# against the real tree is exercised implicitly by every other test that
# spawns a real crew type without overriding WM_PLAYBOOKS.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SPAWN="$TEST_REPO/bin/spawn-crew"

REPO_DIR="$(wm_mktemp_dir)/repo"
mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init -q

STUB="$(wm_mktemp_dir)/stub.sh"
printf '#!/usr/bin/env bash\nexec sleep 60\n' > "$STUB"
chmod +x "$STUB"

# Isolated fixture tree mirroring the real playbooks/ layout with minimal
# stand-in content.
PB="$(wm_mktemp_dir)/playbooks"
mkdir -p "$PB/common" "$PB/software-development"
printf '# Crew status contract (all crew types)\n\nFixture status contract text.\n' > "$PB/_status-contract.md"
printf '# Playbook: `lead` crew member\n\nFixture lead playbook.\n' > "$PB/common/lead.md"
printf '# Playbook: `developer` crew member\n\nFixture developer playbook.\n' > "$PB/software-development/developer.md"

export WM_AGENT="$STUB" WM_SPAWN_DELAY=0 WM_SUBMIT_DELAY=0 WM_PLAYBOOKS="$PB" \
  WM_SUBMIT_POLL=0.2 WM_SUBMIT_TRIES=1
test_new_home
wm_trust_repo "$REPO_DIR"

# --- bare unique name resolves to the correct category file ------------------
id1="$("$SPAWN" --type developer --repo "$REPO_DIR" --objective "bare name" 2>/dev/null | tail -1)"
assert_true "bare --type developer spawns" "[ -n '$id1' ]"
sp1="$WINGMAN_HOME/crew/$id1.sysprompt.md"
assert_true "sysprompt file exists" "[ -f '$sp1' ]"
assert_true "resolves to software-development/developer.md content" \
  "grep -q 'Playbook: \`developer\` crew member' '$sp1'"

# --- category-qualified name resolves directly --------------------------------
id2="$("$SPAWN" --type common/lead --repo "$REPO_DIR" --objective "qualified name" 2>/dev/null | tail -1)"
assert_true "qualified --type common/lead spawns" "[ -n '$id2' ]"
sp2="$WINGMAN_HOME/crew/$id2.sysprompt.md"
assert_true "resolves to common/lead.md content" \
  "grep -q 'Playbook: \`lead\` crew member' '$sp2'"

# --- .local.md wins over its sibling .md --------------------------------------
LOCAL="$PB/software-development/developer.local.md"
echo "local override marker" > "$LOCAL"
id3="$("$SPAWN" --type developer --repo "$REPO_DIR" --objective "local override" 2>/dev/null | tail -1)"
sp3="$WINGMAN_HOME/crew/$id3.sysprompt.md"
assert_true "local override content wins over the tracked default" \
  "grep -q 'local override marker' '$sp3'"
rm -f "$LOCAL"

# --- unknown type is rejected --------------------------------------------------
if "$SPAWN" --type nonexistent-role --repo "$REPO_DIR" --objective x >/dev/null 2>&1; then rc=0; else rc=$?; fi
assert_true "unknown type is rejected with non-zero exit" "[ $rc -ne 0 ]"

# --- a glob-metacharacter type is matched literally, not as a pattern --------
ERR0="$(wm_mktemp_file)"
if "$SPAWN" --type '*' --repo "$REPO_DIR" --objective x >/dev/null 2>"$ERR0"; then rc=0; else rc=$?; fi
assert_true "'*' as --type is rejected rather than matching everything" "[ $rc -ne 0 ]"
assert_contains "'*' is reported as an unknown type, not an ambiguous collision across every fixture playbook" \
  "$(cat "$ERR0")" "no playbook for crew type '*'"
rm -f "$ERR0"

# --- cross-category collision errors deterministically ------------------------
COL_NAME="zzz-collision-fixture"
COL_A="$PB/software-development/$COL_NAME.md"
COL_B="$PB/common/$COL_NAME.md"
echo "# fixture A" > "$COL_A"
echo "# fixture B" > "$COL_B"
ERR="$(wm_mktemp_file)"
if "$SPAWN" --type "$COL_NAME" --repo "$REPO_DIR" --objective collide >/dev/null 2>"$ERR"; then rc=0; else rc=$?; fi
assert_true "cross-category collision is rejected" "[ $rc -ne 0 ]"
assert_contains "collision error names the software-development form" "$(cat "$ERR")" "software-development/$COL_NAME"
assert_contains "collision error names the common form" "$(cat "$ERR")" "common/$COL_NAME"
rm -f "$COL_A" "$COL_B" "$ERR"

# --- --list-types emits category-qualified names, excludes partials -----------
LIST="$("$SPAWN" --list-types)"
assert_contains "list-types includes common/lead" "$LIST" "common/lead"
assert_contains "list-types includes software-development/developer" "$LIST" "software-development/developer"
assert_false "list-types excludes the _status-contract partial" \
  "printf '%s\n' \"$LIST\" | grep -q '_status-contract'"

# --- the shared status contract is still concatenated onto the sysprompt ------
assert_true "sysprompt carries the crew status contract" \
  "grep -q 'Crew status contract' '$sp1'"

test_summary
