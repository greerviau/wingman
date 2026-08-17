#!/usr/bin/env bash
# E2E: liveness reconciliation across a mixed tmux + Herdr fleet.
#
# Proves a live member of either backend survives a roster read, and pins the
# defects whose composition flips every live member of BOTH backends to
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
#   4. wm_backend_herdr_inventory's three API reads (workspace list, tab
#      list, pane list) must each fail the read on an exit-0 response whose
#      body isn't the shape they parse, not silently empty it - an
#      unreadable response and a genuinely empty workspace/tab/pane list are
#      otherwise indistinguishable to reconcile. The inventory line itself is
#      built by jq from parsed JSON, not raw printf interpolation, so a
#      label containing a quote can never emit a line reconcile's own
#      json.loads would silently drop.
#   5. Both bin/crew-list and bin/watch-fleet must gather Herdr inventory from
#      every session a live member actually names, not just their own ambient
#      $HERDR_SESSION - a member spawned under a different session than the
#      one polling it is an ordinary path, not a misconfiguration.
#   6. The dead-owner re-adopt pass must not skip a live worker just because
#      its endpoint is not a tmux window name - that mismatch is expected for
#      every non-tmux backend and proves nothing about the worker's liveness.
#      Nor is it gated to the tmux windows-scoped reconcile call: it must
#      also fire from a herdr-scoped call, since a fleet with no reachable
#      tmux server never issues the windows-scoped call at all.
#   7. The multi-session gather itself must not defer the whole pass just
#      because one session is unreachable - a permanently unreachable
#      session (its member writes nothing further once it's gone) would
#      otherwise mask every OTHER session's own genuine deaths forever. A
#      failed session is dropped from the gather; the sessions actually
#      covered are what reconcile is scoped to via --inventory-sessions.
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
# "wingman" workspace per session holding its own task tabs, each with its own
# root pane. Session-aware ($HERDR_SESSION), so a test can prove a live member
# spawned under a SECOND session is real evidence a reconcile pass must also
# gather, not treated as absent because only the ambient session was ever
# read. The primary session's tab list carries a third, non-"wm-"-labeled tab
# (a manually opened shell, not a wingman task) - the inventory is unfiltered
# by label and list_live is not, so this keeps their agreement assertion
# below honest instead of holding only because every fixture label happened
# to start with "wm-".
# WM_FAKE_HERDR_PANE_LIST_FAILS=1 makes `pane list` fail so the unreadable-API
# path can be exercised without touching the rest of the fixture.
# WM_FAKE_HERDR_TABLIST_MALFORMED=1 / WM_FAKE_HERDR_WORKSPACELIST_MALFORMED=1
# make `tab list` / `workspace list` answer an error object AT EXIT STATUS 0 -
# a real herdr failure mode (protocol drift, a busy workspace) that must fail
# the inventory read rather than silently emptying it. WM_FAKE_HERDR_TABLIST_
# EMPTY=1 / WM_FAKE_HERDR_WORKSPACELIST_EMPTY=1 answer a well-shaped but
# genuinely empty result, the positive control proving the malformed-response
# check above does not also reject a workspace that legitimately holds none.
# WM_FAKE_HERDR_TABLIST_QUOTED_LABEL=1 answers a single tab whose label
# carries a literal double quote, a real operator-chosen label the inventory
# must still be able to emit as valid JSON.
fake="$(wm_mktemp_dir)"
cat > "$fake/herdr" <<EOF
#!/usr/bin/env bash
sess="\${HERDR_SESSION:-default}"
case "\$sess" in
  "$WM_TEST_HERDR_SESSION")
    case "\$1 \$2" in
      "status --json") printf '%s\n' '{"client":{"protocol":14,"version":"0.7.1"},"server":{"running":true}}' ;;
      "workspace list")
        [ "\${WM_FAKE_HERDR_WORKSPACELIST_MALFORMED:-0}" = 1 ] && { printf '%s\n' '{"error":{"code":-32001,"message":"workspace busy"}}'; exit 0; }
        [ "\${WM_FAKE_HERDR_WORKSPACELIST_EMPTY:-0}" = 1 ] && { printf '%s\n' '{"result":{"workspaces":[]}}'; exit 0; }
        printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"ws1","label":"wingman"}]}}' ;;
      "tab list")
        [ "\${WM_FAKE_HERDR_TABLIST_MALFORMED:-0}" = 1 ] && { printf '%s\n' '{"error":{"code":-32001,"message":"workspace busy"}}'; exit 0; }
        [ "\${WM_FAKE_HERDR_TABLIST_EMPTY:-0}" = 1 ] && { printf '%s\n' '{"result":{"tabs":[]}}'; exit 0; }
        [ "\${WM_FAKE_HERDR_TABLIST_QUOTED_LABEL:-0}" = 1 ] && { printf '%s\n' '{"result":{"tabs":[{"tab_id":"tab1","label":"wm-quote\"here"}]}}'; exit 0; }
        printf '%s\n' '{"result":{"tabs":[{"tab_id":"tab1","label":"wm-alpha"},{"tab_id":"tab2","label":"wm-beta"},{"tab_id":"tab-other","label":"shell"}]}}' ;;
      "pane list")
        [ "\${WM_FAKE_HERDR_PANE_LIST_FAILS:-0}" = 1 ] && exit 1
        [ "\${WM_FAKE_HERDR_PANELIST_MALFORMED:-0}" = 1 ] && { printf '%s\n' '{"error":{"code":-32001,"message":"workspace busy"}}'; exit 0; }
        [ "\${WM_FAKE_HERDR_PANELIST_EMPTY:-0}" = 1 ] && { printf '%s\n' '{"result":{"panes":[]}}'; exit 0; }
        printf '%s\n' '{"result":{"panes":[{"tab_id":"tab1","pane_id":"p:1"},{"tab_id":"tab2","pane_id":"p:2"},{"tab_id":"tab-other","pane_id":"p:9"}]}}' ;;
      *) exit 1 ;;
    esac
    ;;
  "${WM_TEST_HERDR_SESSION}-b")
    case "\$1 \$2" in
      "status --json") printf '%s\n' '{"client":{"protocol":14,"version":"0.7.1"},"server":{"running":true}}' ;;
      "workspace list") printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"ws2","label":"wingman"}]}}' ;;
      "tab list") printf '%s\n' '{"result":{"tabs":[{"tab_id":"tab3","label":"wm-gamma"}]}}' ;;
      "pane list") printf '%s\n' '{"result":{"panes":[{"tab_id":"tab3","pane_id":"p:3"}]}}' ;;
      *) exit 1 ;;
    esac
    ;;
  "${WM_TEST_HERDR_SESSION}-c")
    # An entirely unreachable session (server down / never started): every
    # call fails, standing in for a session whose member the roster still
    # names but that can no longer be reached at all.
    exit 1
    ;;
  "${WM_TEST_HERDR_SESSION},comma")
    # A session name containing a comma - unvalidated operator input via
    # HERDR_SESSION, and nothing stops it from holding one.
    case "\$1 \$2" in
      "status --json") printf '%s\n' '{"client":{"protocol":14,"version":"0.7.1"},"server":{"running":true}}' ;;
      "workspace list") printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"ws5","label":"wingman"}]}}' ;;
      "tab list") printf '%s\n' '{"result":{"tabs":[{"tab_id":"tab5","label":"wm-comma"}]}}' ;;
      "pane list") printf '%s\n' '{"result":{"panes":[{"tab_id":"tab5","pane_id":"p:5"}]}}' ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$fake/herdr"
export PATH="$fake:$PATH"

# --- defect 1: the inventory reads the same tab list list_live already reads ---
# Sourced into this shell so the two functions are compared directly on one
# fixture. Endpoints, not whole lines: list_live emits "<endpoint>\t<label>"
# while the inventory emits JSON, and agreement on the endpoint set is the
# property reconcile actually depends on. WM_LIB is set by hand (rather than
# sourcing lib/common.sh) so backend.sh's own wm_backend_source lazy-loads
# find herdr.sh, without pulling in common.sh's own env/state setup here.
WM_LIB="$TEST_REPO/bin/lib"
. "$TEST_REPO/bin/lib/backend.sh"
. "$TEST_REPO/bin/lib/backends/herdr.sh"

inventory="$(wm_backend_herdr_inventory "$HERDR_SESSION")"
inv_rc=$?
assert_eq "the inventory read succeeds" "$inv_rc" 0
assert_contains "the inventory interpolates the first tab" "$inventory" \
  '{"backend":"herdr","endpoint":"'"$HERDR_SESSION"':p:1","physical_id":"tab1","label":"wm-alpha","workspace_id":"ws1","tab_id":"tab1","pane_id":"p:1"}'
assert_contains "the inventory interpolates the second tab" "$inventory" \
  '{"backend":"herdr","endpoint":"'"$HERDR_SESSION"':p:2","physical_id":"tab2","label":"wm-beta","workspace_id":"ws1","tab_id":"tab2","pane_id":"p:2"}'
# The third, non-"wm-"-labeled tab proves the inventory is unfiltered by
# label - it must appear here even though list_live (below) excludes it.
assert_contains "the inventory includes a non-wm-* tab too" "$inventory" \
  '{"backend":"herdr","endpoint":"'"$HERDR_SESSION"':p:9","physical_id":"tab-other","label":"shell","workspace_id":"ws1","tab_id":"tab-other","pane_id":"p:9"}'
assert_eq "one inventory line per live pane, wm-labeled or not" "$(printf '%s\n' "$inventory" | grep -c .)" 3

# Only the "wm-"-prefixed subset should agree with list_live's own filtered
# output - a fixture where every label happened to start with "wm-" would let
# this assertion pass even if the inventory forgot to include an unfiltered
# tab, or if list_live forgot to filter one out.
endpoints_from_inventory_wm="$(printf '%s\n' "$inventory" | jq -r 'select(.label | startswith("wm-")) | .endpoint' | sort | tr '\n' ' ')"
endpoints_from_list_live="$(wm_backend_herdr_list_live "$HERDR_SESSION" | cut -f1 | sort | tr '\n' ' ')"
assert_eq "the inventory's wm-* subset agrees with list_live's own endpoints" \
  "$endpoints_from_inventory_wm" "$endpoints_from_list_live"
assert_not_contains "list_live excludes the non-wm-* tab" "$endpoints_from_list_live" "$HERDR_SESSION:p:9"

# An unreadable API aborts the whole read rather than emitting a partial
# inventory: reconcile treats a returned inventory as authoritative for death,
# so a partial one would flag a live member dead, while a failed read makes
# both callers defer the pass.
partial="$(WM_FAKE_HERDR_PANE_LIST_FAILS=1 wm_backend_herdr_inventory "$HERDR_SESSION")"
assert_false "an unreadable pane list fails the inventory read" \
  'WM_FAKE_HERDR_PANE_LIST_FAILS=1 wm_backend_herdr_inventory "$HERDR_SESSION"'
assert_eq "an unreadable pane list emits no partial inventory" "$partial" ""

# An exit-0 response whose body is not the shape this parses - an error
# object at exit status 0, protocol drift, a busy workspace - must fail the
# read too, not silently empty it: jq's own `?` would otherwise swallow it
# into zero extracted tabs, indistinguishable from a workspace that genuinely
# holds none.
malformed_tabs="$(WM_FAKE_HERDR_TABLIST_MALFORMED=1 wm_backend_herdr_inventory "$HERDR_SESSION")"
assert_false "a malformed tab-list response fails the inventory read" \
  'WM_FAKE_HERDR_TABLIST_MALFORMED=1 wm_backend_herdr_inventory "$HERDR_SESSION"'
assert_eq "a malformed tab-list response emits no partial inventory" "$malformed_tabs" ""

malformed_ws="$(WM_FAKE_HERDR_WORKSPACELIST_MALFORMED=1 wm_backend_herdr_inventory "$HERDR_SESSION")"
assert_false "a malformed workspace-list response fails the inventory read" \
  'WM_FAKE_HERDR_WORKSPACELIST_MALFORMED=1 wm_backend_herdr_inventory "$HERDR_SESSION"'
assert_eq "a malformed workspace-list response emits no partial inventory" "$malformed_ws" ""

# Positive control: a well-shaped but genuinely empty response is NOT the
# malformed case above - it must succeed with an empty inventory, not fail.
empty_tabs="$(WM_FAKE_HERDR_TABLIST_EMPTY=1 wm_backend_herdr_inventory "$HERDR_SESSION")"
assert_true "a genuinely empty tab list still succeeds" \
  'WM_FAKE_HERDR_TABLIST_EMPTY=1 wm_backend_herdr_inventory "$HERDR_SESSION"'
assert_eq "a genuinely empty tab list emits an empty inventory" "$empty_tabs" ""

empty_ws="$(WM_FAKE_HERDR_WORKSPACELIST_EMPTY=1 wm_backend_herdr_inventory "$HERDR_SESSION")"
assert_true "a genuinely empty workspace list still succeeds" \
  'WM_FAKE_HERDR_WORKSPACELIST_EMPTY=1 wm_backend_herdr_inventory "$HERDR_SESSION"'
assert_eq "a genuinely empty workspace list emits an empty inventory" "$empty_ws" ""

# The pane-list read gets the identical malformed/empty treatment: it is the
# third and last API read the inventory depends on, and a malformed response
# here is just as capable of silently emptying the inventory as the other two.
malformed_panes="$(WM_FAKE_HERDR_PANELIST_MALFORMED=1 wm_backend_herdr_inventory "$HERDR_SESSION")"
assert_false "a malformed pane-list response fails the inventory read" \
  'WM_FAKE_HERDR_PANELIST_MALFORMED=1 wm_backend_herdr_inventory "$HERDR_SESSION"'
assert_eq "a malformed pane-list response emits no partial inventory" "$malformed_panes" ""

empty_panes="$(WM_FAKE_HERDR_PANELIST_EMPTY=1 wm_backend_herdr_inventory "$HERDR_SESSION")"
assert_true "a genuinely empty pane list still succeeds" \
  'WM_FAKE_HERDR_PANELIST_EMPTY=1 wm_backend_herdr_inventory "$HERDR_SESSION"'
# Every tab in the fixture's tab list fails to pair with any pane once the
# pane list is empty - dropped from the inventory, not a read failure: the
# pane list is authoritative for which tabs currently have a live root pane.
assert_eq "no matching pane for any tab drops every tab, not the whole read" "$empty_panes" ""

# A label containing a quote must still round-trip as valid JSON: the
# inventory is built by jq from --argjson, not raw printf interpolation, so
# a quote can never emit a line reconcile's own json.loads would silently
# drop - which would read as that member being absent.
quoted_label_inventory="$(WM_FAKE_HERDR_TABLIST_QUOTED_LABEL=1 wm_backend_herdr_inventory "$HERDR_SESSION")"
assert_true "an inventory line with a quoted label is valid JSON" \
  'printf "%s" "$quoted_label_inventory" | jq -e . >/dev/null'
assert_contains "the quoted label round-trips with its quote intact" "$quoted_label_inventory" \
  '"label":"wm-quote\"here"'

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

# --- defect 5: the Herdr pass must cover every session a live member actually -
# names, not just this shell's own ambient $HERDR_SESSION. HERDR_SESSION is
# ambient operator selection by design (herdr.sh:45-51, mirroring tmux's
# $TMUX), so a member spawned under a different session than the one polling
# it is an ordinary, not a misconfigured, path.
new_home
WM_TEST_HERDR_SESSION_B="${HERDR_SESSION}-b"
wm_state crew-add --id herdr-session-a --type developer --objective A --repo /tmp \
  --window "$HERDR_SESSION:p:1" --session-id sa --backend herdr >/dev/null
wm_state crew-add --id herdr-session-b --type developer --objective B --repo /tmp \
  --window "$WM_TEST_HERDR_SESSION_B:p:3" --session-id sb --backend herdr >/dev/null

"$TEST_REPO/bin/crew-list" >/dev/null 2>&1
assert_eq "a live member in the ambient session survives a roster read" \
  "$(field_of herdr-session-a status)" working
assert_eq "a live member spawned under a DIFFERENT session survives too" \
  "$(field_of herdr-session-b status)" working

# --- defect 8: one permanently unreachable session must not mask every other -
# session's own deaths forever. A member whose session goes away writes
# nothing further, so its record keeps naming that dead session on every
# future read too - an all-or-nothing gather across sessions (not just per
# session) would therefore defer this pass, and every OTHER session's genuine
# deaths right along with it, indefinitely.
new_home
WM_TEST_HERDR_SESSION_C="${HERDR_SESSION}-c"
wm_state crew-add --id herdr-live-a --type developer --objective LA --repo /tmp \
  --window "$HERDR_SESSION:p:1" --session-id la --backend herdr >/dev/null
wm_state crew-add --id herdr-dead-a --type developer --objective DA --repo /tmp \
  --window "$HERDR_SESSION:p:404" --session-id da --backend herdr >/dev/null
wm_state crew-add --id herdr-unreachable-c --type developer --objective UC --repo /tmp \
  --window "$WM_TEST_HERDR_SESSION_C:p:1" --session-id uc --backend herdr >/dev/null

for _i in 1 2 3; do
  "$TEST_REPO/bin/crew-list" >/dev/null 2>&1
done
assert_eq "a live member in a reachable session survives despite another unreachable session" \
  "$(field_of herdr-live-a status)" working
assert_eq "a genuinely dead member in a reachable session is still flagged" \
  "$(field_of herdr-dead-a status)" died
assert_eq "a member whose own session is unreachable is deferred, not flipped" \
  "$(field_of herdr-unreachable-c status)" working

# --- defect 10: a session name containing a comma must not desync from its --
# own entry in the covered-sessions set. A session name is unvalidated
# operator input (HERDR_SESSION echoed verbatim, herdr.sh:49-51), and a
# comma-joined encoding split back on commas breaks apart a comma-containing
# session name into pieces that never match the whole - every member of that
# session then reads as permanently uncovered, with no way to clear since the
# session name itself never changes. A plain-named session pair is the
# control: it must keep working exactly as defect 8 already proved.
new_home
WM_TEST_HERDR_SESSION_COMMA="${HERDR_SESSION},comma"
wm_state crew-add --id herdr-plain-live --type developer --objective PL --repo /tmp \
  --window "$HERDR_SESSION:p:1" --session-id pl --backend herdr >/dev/null
wm_state crew-add --id herdr-plain-dead --type developer --objective PD --repo /tmp \
  --window "$HERDR_SESSION:p:404" --session-id pd --backend herdr >/dev/null
wm_state crew-add --id herdr-comma-live --type developer --objective CL --repo /tmp \
  --window "$WM_TEST_HERDR_SESSION_COMMA:p:5" --session-id cl --backend herdr >/dev/null
wm_state crew-add --id herdr-comma-dead --type developer --objective CD --repo /tmp \
  --window "$WM_TEST_HERDR_SESSION_COMMA:p:404" --session-id cd --backend herdr >/dev/null

for _i in 1 2 3; do
  "$TEST_REPO/bin/crew-list" >/dev/null 2>&1
done
assert_eq "the plain-named session's live member survives (control)" \
  "$(field_of herdr-plain-live status)" working
assert_eq "the plain-named session's dead member is flagged (control)" \
  "$(field_of herdr-plain-dead status)" died
assert_eq "the comma-named session's live member survives" \
  "$(field_of herdr-comma-live status)" working
assert_eq "the comma-named session's dead member is flagged too" \
  "$(field_of herdr-comma-dead status)" died

# --- defect 6: a live Herdr worker with a dead owner must still be re-adopted -
# not silently left unwatched. A tmux worker in the same shape is the
# positive control: it was already re-adopted correctly before this fix.
new_home
wm_state crew-add --id lead1 --type lead --objective L --repo /tmp \
  --window "wm-lead1" --session-id sl >/dev/null
wm_state crew-add --id tmux-worker --type developer --objective TW --repo /tmp \
  --window "wm-tmux-worker" --session-id stw --parent lead1 >/dev/null
wm_state crew-add --id herdr-worker --type developer --objective HW --repo /tmp \
  --window "$HERDR_SESSION:p:1" --session-id shw --backend herdr --parent lead1 >/dev/null

# lead1's own window is gone (omitted from --windows); the death flip judges
# it dead. Its workers' windows ARE both live: the tmux worker's is named
# explicitly, and the Herdr worker's endpoint can never appear in a tmux
# --windows list regardless of its own real liveness - that mismatch is
# exactly what must NOT be read as "this worker already died too".
wm_state reconcile --windows "wm-tmux-worker" --owner "" >/dev/null
assert_eq "the dead lead is flipped" "$(field_of lead1 status)" died
assert_eq "the tmux worker is re-adopted to wingman" "$(field_of tmux-worker parent)" ""
assert_eq "the tmux worker stays working" "$(field_of tmux-worker status)" working
assert_eq "the Herdr worker is re-adopted to wingman too" "$(field_of herdr-worker parent)" ""
assert_eq "the Herdr worker stays working, not silently unwatched" "$(field_of herdr-worker status)" working

# --- defect 9: dead-owner re-adopt must fire from a herdr-scoped call too, ---
# not only the tmux windows-scoped one - on a fleet with no reachable tmux
# server, bin/watch-fleet's windows pass never runs at all, and the herdr
# pass (which still passes --owner "") is the only trigger left. No --windows
# call happens anywhere in this scenario at all.
new_home
wm_state crew-add --id herdr-lead --type lead --objective HL --repo /tmp \
  --window "$HERDR_SESSION:p:404" --session-id hl --backend herdr >/dev/null
wm_state crew-add --id herdr-lead-worker --type developer --objective HLW --repo /tmp \
  --window "$HERDR_SESSION:p:1" --session-id hlw --backend herdr --parent herdr-lead >/dev/null

# herdr-lead's own endpoint (p:404) is absent from the fixture, so this one
# herdr-scoped call both flips it dead and re-adopts its live worker.
wm_backend_herdr_reconcile_inventory "$(wm_state crew-list --all --json)"
wm_state reconcile --inventory "$WM_HERDR_RECONCILE_INVENTORY" --inventory-backends herdr \
  --inventory-sessions "$WM_HERDR_RECONCILE_SESSIONS" --owner "" >/dev/null
assert_eq "the dead herdr lead is flipped by its own herdr-scoped call" \
  "$(field_of herdr-lead status)" died
assert_eq "its herdr worker is re-adopted by that same herdr-scoped call" \
  "$(field_of herdr-lead-worker parent)" ""
assert_eq "the re-adopted worker stays working" "$(field_of herdr-lead-worker status)" working

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
