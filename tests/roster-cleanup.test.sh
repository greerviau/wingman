#!/usr/bin/env bash
# E2E: roster views and cleanup. crew-list hides fully-closed (stood-down) records
# by default and reveals them with --all / --status; crew-prune archives and removes
# terminal records, deletes their status files, and cleans their acked entries. No
# real crew/tmux/claude needed.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# --- crew-list default hides stood-down --------------------------------------
test_new_home
wm_state crew-add --id a1 --type build --objective x --repo /tmp --window wm-a1 --session-id s1 >/dev/null
wm_state crew-add --id a2 --type spec  --objective y --repo /tmp --window wm-a2 --session-id s2 >/dev/null
wm_state crew-add --id a3 --type build --objective z --repo /tmp --window wm-a3 --session-id s3 >/dev/null
wm_state standdown --id a1 >/dev/null
wm_state crew-set --id a3 --status died >/dev/null

def="$(wm_state crew-list)"
case "$def" in *a1*) fail "default crew-list hides a stood-down member" ;; *) ok "default crew-list hides a stood-down member" ;; esac
assert_contains "default crew-list still shows a working member"  "$def" "a2"
assert_contains "default crew-list still shows a died member"     "$def" "a3"

assert_contains "crew-list --all reveals the stood-down member"   "$(wm_state crew-list --all)" "a1"
assert_contains "crew-list --status stood-down lists it on request" "$(wm_state crew-list --status stood-down)" "a1"
assert_contains "crew-list --active still works"                  "$(wm_state crew-list --active --json)" '"id": "a2"'

# --- prune --dry-run reports but changes nothing -----------------------------
dry="$(wm_state prune --dry-run)"
assert_contains "dry-run names the stood-down member" "$dry" "a1"
assert_contains "dry-run still shows it after (nothing removed)" "$(wm_state crew-list --all)" "a1"

# --- prune archives + removes the stood-down record --------------------------
wm_state ack --id a1 --updated "2026-01-01T00:00:00.000000Z" >/dev/null  # seed an acked entry to prove it is cleaned
assert_true "a1 has an acked entry before prune" "grep -q a1 '$WINGMAN_HOME/acked.json'"
n="$(wm_state prune)"
assert_eq "prune removes exactly the one stood-down record" "$n" "1"
case "$(wm_state crew-list --all)" in *a1*) fail "pruned member is gone from the roster" ;; *) ok "pruned member is gone from the roster" ;; esac
assert_true  "the pruned record is archived" "grep -q '\"id\": \"a1\"' '$WINGMAN_HOME/crew-archive.jsonl'"
assert_false "the pruned member's status file is deleted" "test -f '$WINGMAN_HOME/crew/a1.json'"
assert_false "the pruned member's acked entry is cleaned" "grep -q a1 '$WINGMAN_HOME/acked.json'"

# died survives a default prune, goes on --all-terminal ------------------------
assert_contains "a died member survives a default prune" "$(wm_state crew-list --all)" "a3"
m="$(wm_state prune --all-terminal)"
assert_eq "prune --all-terminal removes the died member too" "$m" "1"
case "$(wm_state crew-list --all)" in *a3*) fail "died member removed by --all-terminal" ;; *) ok "died member removed by --all-terminal" ;; esac

# --- --older-than-days keeps fresh records -----------------------------------
wm_state standdown --id a2 >/dev/null
assert_eq "prune --older-than-days 1 keeps a freshly-closed record" "$(wm_state prune --older-than-days 1)" "0"

test_summary
