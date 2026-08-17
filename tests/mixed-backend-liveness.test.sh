#!/usr/bin/env bash
# E2E: liveness reconciliation across a mixed tmux + Herdr fleet (issue #370).
#
# Proves a live member of either backend survives a roster read, and pins the
# three defects whose composition flips every live member of BOTH backends to
# 'died' on every read once any Herdr member is on the roster:
#
#   1. wm_backend_herdr_inventory's jq filter must interpolate its fields.
#      Doubled backslashes emit the literal text "\(.tab_id)\t\(.label)"
#      instead, leaving the inventory empty. Its sibling
#      wm_backend_herdr_list_live reads the same JSON, so the two are asserted
#      to agree rather than against a hand-written expected endpoint set.
#   2. cmd_reconcile must read --inventory-backends whether or not --inventory
#      is empty. Reading it only for a non-empty inventory turns the empty case
#      into an unscoped reconciliation against an empty liveness set.
#   3. cmd_reconcile's window pass must be scoped to tmux. Unscoped, tmux window
#      names decide the liveness of Herdr members whose endpoint
#      ("<session>:<pane-id>") can never appear in that list.
#
# A fake herdr CLI keeps the whole file independent of a running Herdr session.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

field_of() { wm_state crew-get --id "$1" | uv run --no-project --quiet python -c 'import sys,json
print(json.load(sys.stdin).get(sys.argv[1]) or "")' "$2"; }

# One Herdr session name for the whole file, so the inventory captured once
# below matches the endpoints recorded on the roster afterwards. test_new_home
# mints its own per-test name, so restore this one after every call to it -
# never "default", which is the pilot's own live session.
WM_TEST_HERDR_SESSION="wm-test-herdr-mbl-${WM_TEST_RUN_ID:-x}-$$"
export HERDR_SESSION="$WM_TEST_HERDR_SESSION"
new_home() { test_new_home; export HERDR_SESSION="$WM_TEST_HERDR_SESSION"; }

# A fake herdr answering the read-only calls both liveness functions make: one
# "wingman" workspace holding two task tabs, each with its own root pane.
# WM_FAKE_HERDR_PANE_LIST_FAILS=1 makes `pane list` fail so the unreadable-API
# path can be exercised without touching the rest of the fixture.
fake="$(wm_mktemp_dir)"
cat > "$fake/herdr" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "status --json") printf '%s\n' '{"client":{"protocol":14,"version":"0.7.1"},"server":{"running":true}}' ;;
  "workspace list") printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"ws1","label":"wingman"}]}}' ;;
  "tab list") printf '%s\n' '{"result":{"tabs":[{"tab_id":"tab1","label":"wm-alpha"},{"tab_id":"tab2","label":"wm-beta"}]}}' ;;
  "pane list")
    [ "${WM_FAKE_HERDR_PANE_LIST_FAILS:-0}" = 1 ] && exit 1
    printf '%s\n' '{"result":{"panes":[{"tab_id":"tab1","pane_id":"p:1"},{"tab_id":"tab2","pane_id":"p:2"}]}}' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$fake/herdr"
export PATH="$fake:$PATH"

# --- defect 1: the inventory reads the same tab list list_live already reads ---
# Sourced into this shell so the two functions are compared directly on one
# fixture. Endpoints, not whole lines: list_live emits "<endpoint>\t<label>"
# while the inventory emits JSON, and agreement on the endpoint set is the
# property reconcile actually depends on.
. "$TEST_REPO/bin/lib/backends/herdr.sh"

inventory="$(wm_backend_herdr_inventory "$HERDR_SESSION")"
inv_rc=$?
assert_eq "the inventory read succeeds" "$inv_rc" 0
assert_contains "the inventory interpolates the first tab" "$inventory" \
  '{"backend":"herdr","endpoint":"'"$HERDR_SESSION"':p:1","physical_id":"tab1","label":"wm-alpha","workspace_id":"ws1","tab_id":"tab1","pane_id":"p:1"}'
assert_contains "the inventory interpolates the second tab" "$inventory" \
  '{"backend":"herdr","endpoint":"'"$HERDR_SESSION"':p:2","physical_id":"tab2","label":"wm-beta","workspace_id":"ws1","tab_id":"tab2","pane_id":"p:2"}'
assert_not_contains "no jq interpolation is emitted literally" "$inventory" '\(.tab_id)'
assert_eq "one inventory line per live pane" "$(printf '%s\n' "$inventory" | grep -c .)" 2

endpoints_from_inventory="$(printf '%s\n' "$inventory" | jq -r '.endpoint' | sort | tr '\n' ' ')"
endpoints_from_list_live="$(wm_backend_herdr_list_live "$HERDR_SESSION" | cut -f1 | sort | tr '\n' ' ')"
assert_eq "the inventory and list_live agree on the live endpoints" \
  "$endpoints_from_inventory" "$endpoints_from_list_live"

# An unreadable API aborts the whole read rather than emitting a partial
# inventory: reconcile treats a returned inventory as authoritative for death,
# so a partial one would flag a live member dead, while a failed read makes
# both callers defer the pass.
partial="$(WM_FAKE_HERDR_PANE_LIST_FAILS=1 wm_backend_herdr_inventory "$HERDR_SESSION")"
assert_false "an unreadable pane list fails the inventory read" \
  'WM_FAKE_HERDR_PANE_LIST_FAILS=1 wm_backend_herdr_inventory "$HERDR_SESSION"'
assert_eq "an unreadable pane list emits no partial inventory" "$partial" ""

# --- defects 2 and 3: each reconcile pass is scoped to its own backend ---------
new_home
wm_state crew-add --id tmux-member --type developer --objective T --repo /tmp \
  --window "wm-tmux-member" --session-id s1 >/dev/null
wm_state crew-add --id herdr-member --type developer --objective H --repo /tmp \
  --window "$HERDR_SESSION:p:1" --session-id s2 --backend herdr >/dev/null

# Defect 3: the window pass sees the tmux member's window and nothing else. The
# Herdr member's endpoint is not a tmux window name and must be left alone.
wm_state reconcile --windows "wm-tmux-member" >/dev/null
assert_eq "the window pass keeps the live tmux member" "$(field_of tmux-member status)" working
assert_eq "the window pass does not judge the Herdr member" "$(field_of herdr-member status)" working

# Defect 2: an authoritatively empty Herdr inventory kills the Herdr member and
# only the Herdr member - the tmux member is outside this pass's evidence.
wm_state reconcile --inventory "" --inventory-backends herdr >/dev/null
assert_eq "an empty Herdr inventory does not touch the tmux member" "$(field_of tmux-member status)" working
assert_eq "an empty Herdr inventory flips the absent Herdr member" "$(field_of herdr-member status)" died

# A populated inventory keeps a Herdr member whose endpoint it lists.
wm_state crew-set --id herdr-member --status working >/dev/null
wm_state reconcile --inventory "$inventory" --inventory-backends herdr >/dev/null
assert_eq "a listed Herdr endpoint stays live" "$(field_of herdr-member status)" working
assert_eq "the Herdr pass leaves the tmux member live" "$(field_of tmux-member status)" working

# The Herdr pass is still authoritative for a Herdr member the inventory omits.
wm_state crew-add --id herdr-gone --type developer --objective G --repo /tmp \
  --window "$HERDR_SESSION:p:99" --session-id s3 --backend herdr >/dev/null
wm_state reconcile --inventory "$inventory" --inventory-backends herdr >/dev/null
assert_eq "an unlisted Herdr endpoint is flipped" "$(field_of herdr-gone status)" died

# --- E2E: the roster read itself no longer reports a live member dead ----------
# bin/crew-list runs both passes in one read, which is where the three defects
# composed. A real tmux window backs the tmux member; the fake herdr above backs
# the Herdr member.
new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n "wm-tmux-member" "trap '' INT; sleep 300"
wm_state crew-add --id tmux-member --type developer --objective T --repo /tmp \
  --window "wm-tmux-member" --session-id s1 >/dev/null
wm_state crew-add --id herdr-member --type developer --objective H --repo /tmp \
  --window "$HERDR_SESSION:p:1" --session-id s2 --backend herdr >/dev/null

"$TEST_REPO/bin/crew-list" >/dev/null 2>&1
assert_eq "crew-list keeps the live tmux member working" "$(field_of tmux-member status)" working
assert_eq "crew-list keeps the live Herdr member working" "$(field_of herdr-member status)" working

# A member's own self-report survives the next read, which is the symptom an
# operator sees: a plausible working summary rendered under a 'died' status.
wm_state crew-set --id herdr-member --status working --summary "probe" >/dev/null
"$TEST_REPO/bin/crew-list" >/dev/null 2>&1
assert_eq "a self-written status survives a roster read" "$(field_of herdr-member status)" working
assert_eq "the summary written alongside it is intact" "$(field_of herdr-member summary)" "probe"

test_summary
