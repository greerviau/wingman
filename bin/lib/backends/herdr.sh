#!/usr/bin/env bash
# Herdr runtime backend adapter (experimental).
# Herdr owns terminal endpoint operations only; Wingman continues to own
# orchestration, roster state, worktrees, and supervision policy.
#
# A Herdr container is one workspace labeled "wingman" per named session, with
# one tab per crew member. Stored targets use "<session>:<pane-id>". Pane IDs
# may contain colons, so target parsing always splits on the first colon.
#
# Requires herdr and jq. These dependencies are checked only when this backend
# is selected.

WM_BACKEND_HERDR_MIN_PROTOCOL=14
WM_BACKEND_HERDR_WORKSPACE_LABEL="wingman"

# wm_backend_herdr_tool_check: refuse loudly if herdr or jq is missing.
wm_backend_herdr_tool_check() {
  command -v herdr >/dev/null 2>&1 || { echo "error: backend=herdr selected but the 'herdr' CLI is not installed (https://herdr.dev)" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: backend=herdr selected but 'jq' is not installed (required to parse herdr's JSON output)" >&2; return 1; }
  return 0
}

# wm_backend_herdr_version_check: refuse loudly on a missing/incompatible
# herdr client. Verified locally: v0.7.1, protocol 14 (herdr status --json's
# .client.protocol; client info is session-independent, unlike .server).
wm_backend_herdr_version_check() {
  wm_backend_herdr_tool_check || return 1
  local status protocol version
  status=$(herdr status --json 2>/dev/null) || { echo "error: 'herdr status --json' failed; is herdr installed correctly?" >&2; return 1; }
  protocol=$(printf '%s' "$status" | jq -r '.client.protocol // empty' 2>/dev/null)
  version=$(printf '%s' "$status" | jq -r '.client.version // empty' 2>/dev/null)
  case "$protocol" in
    ''|*[!0-9]*)
      echo "error: could not read herdr client protocol from 'herdr status --json'; refusing to use an unverified herdr build" >&2
      return 1
      ;;
  esac
  if [ "$protocol" -lt "$WM_BACKEND_HERDR_MIN_PROTOCOL" ]; then
    echo "error: herdr protocol $protocol (version ${version:-unknown}) is older than the verified minimum $WM_BACKEND_HERDR_MIN_PROTOCOL; update herdr (herdr update) before using backend=herdr" >&2
    return 1
  fi
  return 0
}

# wm_backend_herdr_session: resolve which named herdr session this spawn/op
# uses. HERDR_SESSION mirrors tmux's $TMUX ambient-selection: an operator (or
# wingman's own isolated test harness) sets it explicitly; absent means
# herdr's own "default" session.
wm_backend_herdr_session() {
  printf '%s' "${HERDR_SESSION:-default}"
}

# wm_backend_herdr_server_ensure: start the herdr server for <session>
# headless (no TUI client) if not already running, mirroring tmux's `tmux
# has-session || tmux new-session -d`. Verified: a bare socket CLI call does
# NOT auto-start the server, so this must run before any workspace/tab/pane
# call. Bounded poll for the server to report running.
wm_backend_herdr_server_ensure() {  # <session>
  local session=$1 running out i
  running=$(HERDR_SESSION="$session" herdr status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null)
  [ "$running" = "true" ] && return 0
  ( HERDR_SESSION="$session" herdr server >/dev/null 2>&1 & ) || return 1
  for i in $(seq 1 20); do
    running=$(HERDR_SESSION="$session" herdr status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null)
    [ "$running" = "true" ] && return 0
    sleep 0.5
  done
  echo "error: herdr server for session '$session' did not report running within 10s" >&2
  return 1
}

# wm_backend_herdr_workspace_find: the "wingman" workspace's id inside
# <session>, or empty (never creates). Read-only, safe for recovery/list paths.
# A response whose exit status is 0 but whose body isn't the shape this
# parses (an error object, protocol drift, a truncated payload) is validated
# before extraction rather than left to jq's `?` to silently swallow into an
# empty result indistinguishable from "the workspace genuinely doesn't
# exist" - the empty case is authoritative for every caller here
# (wm_backend_herdr_inventory treats it as proof of zero live panes), so a
# merely-unreadable response must fail loudly instead.
wm_backend_herdr_workspace_find() {  # <session>
  local session=$1 list ids count
  list=$(HERDR_SESSION="$session" herdr workspace list 2>/dev/null) || return 1
  printf '%s' "$list" | jq -e '(.result.workspaces | type) == "array"' >/dev/null 2>&1 || return 1
  if [ -n "${HERDR_WORKSPACE_ID:-}" ]; then
    ids=$(printf '%s' "$list" | jq -r --arg id "$HERDR_WORKSPACE_ID" \
      '.result.workspaces[]? | select(.workspace_id == $id) | .workspace_id' 2>/dev/null)
    [ -n "$ids" ] && printf '%s' "$ids" && return 0
  fi
  ids=$(printf '%s' "$list" | jq -r --arg label "$WM_BACKEND_HERDR_WORKSPACE_LABEL" \
    '.result.workspaces[]? | select(.label == $label) | .workspace_id' 2>/dev/null)
  count=$(printf '%s\n' "$ids" | grep -c .)
  [ "$count" -le 1 ] || {
    echo "error: Herdr workspace label '$WM_BACKEND_HERDR_WORKSPACE_LABEL' is ambiguous in session '$session'" >&2
    return 1
  }
  printf '%s' "$ids"
}

# wm_backend_herdr_workspace_ensure: the persistent "wingman" workspace
# inside <session>, creating it in <cwd> if absent. Echoes its workspace_id.
wm_backend_herdr_workspace_ensure() {  # <session> <cwd>
  local session=$1 cwd=$2 wsid out
  wsid=$(wm_backend_herdr_workspace_find "$session") || return 1
  if [ -n "$wsid" ]; then
    printf '%s' "$wsid"
    return 0
  fi
  out=$(HERDR_SESSION="$session" herdr workspace create --cwd "$cwd" --label "$WM_BACKEND_HERDR_WORKSPACE_LABEL" 2>/dev/null) || return 1
  wsid=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  [ -n "$wsid" ] || return 1
  printf '%s' "$wsid"
}

# wm_backend_herdr_container_ensure: the full spawn-time container-ensure
# sequence (version gate, server, workspace). Echoes "<session>:<workspace_id>"
# for wm_backend_herdr_create_task.
wm_backend_herdr_container_ensure() {  # <cwd-for-a-fresh-workspace>
  local cwd=${1:-$PWD} session wsid
  wm_backend_herdr_version_check || return 1
  session=$(wm_backend_herdr_session)
  wm_backend_herdr_server_ensure "$session" || return 1
  wsid=$(wm_backend_herdr_workspace_ensure "$session" "$cwd") || { echo "error: failed to ensure herdr workspace '$WM_BACKEND_HERDR_WORKSPACE_LABEL' in session '$session'" >&2; return 1; }
  printf '%s:%s' "$session" "$wsid"
}

# wm_backend_herdr_create_task: create the task's tab (one pane) in
# <container> ("session:workspace_id"), refusing an existing <label>. Herdr
# does NOT enforce label uniqueness itself (verified: two tabs can share a
# label), so the duplicate check is ours, mirroring tmux's manual check.
# Echoes "<tab_id> <pane_id>" on success.
wm_backend_herdr_create_task() {  # <container> <label> <cwd>
  local container=$1 label=$2 cwd=$3 session wsid list dup out tab_id pane_id
  session=${container%%:*}
  wsid=${container#*:}
  list=$(HERDR_SESSION="$session" herdr tab list --workspace "$wsid" 2>/dev/null) || return 1
  dup=$(printf '%s' "$list" | jq -r --arg label "$label" '.result.tabs[]? | select(.label == $label) | .tab_id' 2>/dev/null | head -1)
  if [ -n "$dup" ]; then
    echo "error: herdr tab '$label' already exists in workspace $wsid (session $session)" >&2
    return 1
  fi
  out=$(HERDR_SESSION="$session" herdr tab create --workspace "$wsid" --cwd "$cwd" --label "$label" 2>/dev/null) || return 1
  tab_id=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  pane_id=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -z "$tab_id" ] || [ -z "$pane_id" ]; then
    echo "error: could not parse tab/pane id from herdr tab create output" >&2
    return 1
  fi
  printf '%s %s' "$tab_id" "$pane_id"
}

# wm_backend_herdr_parse_target: split "<session>:<pane_id>" (pane_id itself
# contains a colon, e.g. "w1:p2") on the FIRST colon only. Sets
# WM_BACKEND_HERDR_SESSION and WM_BACKEND_HERDR_PANE for the caller.
wm_backend_herdr_parse_target() {  # <target>
  local target=$1
  WM_BACKEND_HERDR_SESSION=${target%%:*}
  WM_BACKEND_HERDR_PANE=${target#*:}
  [ -n "$WM_BACKEND_HERDR_SESSION" ] && [ -n "$WM_BACKEND_HERDR_PANE" ] && [ "$WM_BACKEND_HERDR_PANE" != "$target" ]
}

wm_backend_herdr_target_ready() {  # <target>
  wm_backend_herdr_parse_target "$1" || return 1
  wm_backend_herdr_server_ensure "$WM_BACKEND_HERDR_SESSION" || return 1
}

# wm_backend_herdr_current_path: the live FOREGROUND process's cwd, or empty on
# any error. Mirrors tmux's pane_current_path poll used for worktree-path
# discovery after `treehouse get`.
#
# Verified pitfall: `pane get`'s `.result.pane.cwd` is the pane's cwd AT
# CREATION TIME - the top-level shell's cwd - and does NOT update when that
# shell `cd`s or enters a subshell (as `treehouse get` does). Reading it here
# would make the spawn worktree-discovery poll never see the pane "leave"
# the project directory, since `cwd` stays frozen at the original path forever.
# `.result.pane.foreground_cwd` tracks the ACTUALLY RUNNING foreground
# process's cwd instead, which is what changes when `treehouse get` enters its
# worktree subshell - confirmed live against a real treehouse acquisition.
wm_backend_herdr_current_path() {  # <target>
  wm_backend_herdr_target_ready "$1" || return 0
  HERDR_SESSION="$WM_BACKEND_HERDR_SESSION" herdr pane get "$WM_BACKEND_HERDR_PANE" 2>/dev/null \
    | jq -r '.result.pane.foreground_cwd // empty' 2>/dev/null
}

# wm_backend_herdr_send_text_line: send one line of TEXT then submit,
# ATOMICALLY - mirrors tmux's `send-keys -t T text Enter`. Used for the fixed
# spawn-time commands (treehouse get, the GOTMPDIR export). `pane run` types
# the command and submits it in one call (verified).
wm_backend_herdr_send_text_line() {  # <target> <text>
  wm_backend_herdr_target_ready "$1" || return 1
  HERDR_SESSION="$WM_BACKEND_HERDR_SESSION" herdr pane run "$WM_BACKEND_HERDR_PANE" "$2" >/dev/null 2>&1
}

# wm_backend_herdr_send_literal: send TEXT as literal, UNSUBMITTED input - the
# caller sends Enter separately. Mirrors tmux's `send-keys -t T -l text`.
# Verified: `pane send-text` does NOT auto-submit (contrary to the addendum's
# original guess); it behaves exactly like tmux's `-l` literal send.
wm_backend_herdr_send_literal() {  # <target> <text>
  wm_backend_herdr_target_ready "$1" || return 1
  HERDR_SESSION="$WM_BACKEND_HERDR_SESSION" herdr pane send-text "$WM_BACKEND_HERDR_PANE" "$2" >/dev/null 2>&1
}

# wm_backend_herdr_normalize_key: map wingman's key vocabulary (Enter,
# Escape, C-c, as used by Wingman's key-send and recovery paths) onto
# herdr's `pane send-keys` names. Verified empirically: enter, escape/esc, and
# both ctrl+c/C-c all work (case-insensitive on herdr's side, but normalize
# explicitly rather than relying on that).
wm_backend_herdr_normalize_key() {  # <key>
  case "$1" in
    Enter|enter) printf 'enter' ;;
    Escape|escape|Esc|esc) printf 'escape' ;;
    C-c|c-c|ctrl+c|Ctrl+C) printf 'ctrl+c' ;;
    *) return 1 ;;
  esac
}

# wm_backend_herdr_send_key: one named special key. Mirrors Wingman's key-send
# path (tmux's `send-keys -t T key`).
wm_backend_herdr_send_key() {  # <target> <key>
  wm_backend_herdr_target_ready "$1" || return 1
  local key
  key=$(wm_backend_herdr_normalize_key "$2") || {
    echo "error: unsupported Herdr key '$2'" >&2
    return 1
  }
  HERDR_SESSION="$WM_BACKEND_HERDR_SESSION" herdr pane send-keys "$WM_BACKEND_HERDR_PANE" "$key" >/dev/null 2>&1
}

# wm_backend_herdr_capture: bounded plain-text pane capture. Mirrors
# pane capture's `tmux capture-pane -p -t T -S -N` shape. --source recent
# is the closest herdr analogue to tmux's scrollback-bounded capture.
#
# Verified CLI quirk (herdr-verification-p2.md "pane read --lines bug", v0.7.1):
# `pane read --source recent --lines N` returns COMPLETELY EMPTY output when N
# is smaller than the pane's current viewport height (observed threshold ~23
# rows for a default-sized pane), instead of clamping to the last N lines - it
# does not merely ignore the bound, it drops the read entirely. This silently
# broke exactly the small bounded reads this adapter relies on most (a 6-line
# composer-verification read in send_text_submit). Workaround: always request
# a generous fetch far above any realistic viewport height, then trim to the
# caller's requested bound ourselves with `tail`.
wm_backend_herdr_capture() {  # <target> <lines>
  wm_backend_herdr_target_ready "$1" || return 1
  local lines=${2:-200} fetch out
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  fetch=$lines
  case "$fetch" in ''|*[!0-9]*) fetch=200 ;; *) [ "$fetch" -ge 200 ] || fetch=200 ;; esac
  out=$(HERDR_SESSION="$WM_BACKEND_HERDR_SESSION" herdr pane read "$WM_BACKEND_HERDR_PANE" --source recent --lines "$fetch" 2>/dev/null) || return 1
  printf '%s' "$out" | tail -n "$lines"
}

# wm_backend_herdr_send_text_submit: type <text> into <target> once (raw,
# unsubmitted, via send_literal), then submit with a named Enter key, retried
# (Enter only, never retyped) until the pane visibly changes. Verified hazard
# (herdr-verification-p2.md "slash/$ autocomplete popup"): a `/`- or
# `$`-prefixed send opens a completion popup within ~0.1s, exactly like tmux's
# claude/codex popups, so the caller's <settle> before the first Enter matters
# here the same way it does for tmux.
#
# Verification strategy differs from tmux's ANSI-ghost-aware composer read
# (herdr's CLI has no cursor-row/ANSI capture primitive exposed): capture the
# pane right after typing (before any Enter) as the TYPED baseline, then after
# each Enter attempt capture again - if the capture is UNCHANGED from the typed
# baseline, nothing happened (Enter was swallowed) and we retry; the moment the
# capture changes (output appeared, prompt cleared, a popup closed and text
# resolved), the send is considered submitted. Echoes empty|pending|unknown|
# send-failed, the same vocabulary the shared delivery path uses for tmux.
wm_backend_herdr_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 typed after i=0
  wm_backend_herdr_parse_target "$target" || { printf 'unknown'; return 0; }
  wm_backend_herdr_send_literal "$target" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  typed=$(wm_backend_herdr_capture "$target" 6) || { printf 'unknown'; return 0; }
  while :; do
    wm_backend_herdr_send_key "$target" Enter || true
    sleep "$sleep_s"
    after=$(wm_backend_herdr_capture "$target" 6) || { printf 'unknown'; return 0; }
    if [ "$after" != "$typed" ]; then
      printf 'empty'
      return 0
    fi
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

# wm_backend_herdr_kill: remove the task's pane, best-effort (mirrors
# tmux-kill-window's `|| true` contract). Verified: closing a tab's only pane
# closes the tab too, so a separate tab close is unnecessary.
wm_backend_herdr_kill() {  # <target>
  wm_backend_herdr_target_ready "$1" || return 0
  HERDR_SESSION="$WM_BACKEND_HERDR_SESSION" herdr pane close "$WM_BACKEND_HERDR_PANE" >/dev/null 2>&1 || true
}

# wm_backend_herdr_busy_state: semantic busy state from herdr's native
# agent-state detection (agent.get), the "first backend where fm_session_busy_state
# gets real semantics" per the design report. working -> busy (actively
# generating); idle/done -> idle; blocked -> idle (a blocked agent is stuck
# waiting on the human, not grinding - the watcher should treat it like a
# stale pane needing attention, not suppress it as busy); unknown/unparseable
# -> unknown, the caller's cue to fall back to pane-regex detection.
wm_backend_herdr_busy_state() {  # <target>
  wm_backend_herdr_target_ready "$1" || { printf 'unknown'; return 0; }
  local out status
  out=$(HERDR_SESSION="$WM_BACKEND_HERDR_SESSION" herdr agent get "$WM_BACKEND_HERDR_PANE" 2>/dev/null) || { printf 'unknown'; return 0; }
  status=$(printf '%s' "$out" | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
  case "$status" in
    working) printf 'busy' ;;
    idle|done) printf 'idle' ;;
    blocked) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

# wm_backend_herdr_pane_for_tab: the root pane id for <tab_id> in <workspace_id>
# of <session>, via one pane list call filtered by tab_id (never assumes a
# tab-number/pane-number correspondence - herdr numbers them independently).
wm_backend_herdr_pane_for_tab() {  # <session> <workspace_id> <tab_id>
  local session=$1 wsid=$2 tab_id=$3 panes
  panes=$(HERDR_SESSION="$session" herdr pane list --workspace "$wsid" 2>/dev/null) || return 1
  printf '%s' "$panes" | jq -r --arg tab "$tab_id" \
    '.result.panes[]? | select(.tab_id == $tab) | .pane_id' 2>/dev/null | head -1
}

# wm_backend_herdr_resolve_bare_selector: the live-tab-listing fallback for an
# ad hoc selector with no meta (mirrors tmux's list-windows grep). Searches
# every RUNNING named herdr session (herdr session list) for a tab whose label
# matches <name>, since herdr sessions are not addressed by one ambient
# server the way a single tmux server is. Rare path in practice (herdr tasks
# normally carry meta), best-effort.
wm_backend_herdr_resolve_bare_selector() {  # <name>
  local name=$1 sessions session tabs tab_id wsid pane_id
  sessions=$(herdr session list --json 2>/dev/null | jq -r '.sessions[]? | select(.running == true) | .name' 2>/dev/null)
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    tabs=$(HERDR_SESSION="$session" herdr tab list 2>/dev/null) || continue
    tab_id=$(printf '%s' "$tabs" | jq -r --arg label "$name" \
      '.result.tabs[]? | select(.label == $label) | .tab_id' 2>/dev/null | head -1)
    [ -n "$tab_id" ] || continue
    wsid=$(printf '%s' "$tabs" | jq -r --arg tab "$tab_id" '.result.tabs[]? | select(.tab_id == $tab) | .workspace_id' 2>/dev/null | head -1)
    [ -n "$wsid" ] || continue
    pane_id=$(wm_backend_herdr_pane_for_tab "$session" "$wsid" "$tab_id") || continue
    [ -n "$pane_id" ] || continue
    printf '%s:%s' "$session" "$pane_id"
    return 0
  done <<EOF
$sessions
EOF
  echo "error: no herdr tab named $name in any running session" >&2
  return 1
}

# wm_backend_herdr_list_live: recovery/orphan discovery. Lists every tab whose
# label looks like a Wingman task window (wm-<id>) in <session>'s
# "wingman" workspace, by LABEL - never by trusting a stored pane id, since
# ids are not guaranteed stable across every server lifecycle (see
# herdr-verification-p2.md "ID stability"). Read-only: a session/workspace
# that does not exist yet simply lists nothing. One
# "<session>:<pane_id>\t<label>" line per live task tab.
wm_backend_herdr_list_live() {  # <session>
  local session=$1 wsid tabs tab_id label pane_id
  wsid=$(wm_backend_herdr_workspace_find "$session") || return 1
  [ -n "$wsid" ] || return 0
  tabs=$(HERDR_SESSION="$session" herdr tab list --workspace "$wsid" 2>/dev/null) || return 1
  while IFS=$'\t' read -r tab_id label; do
    [ -n "$tab_id" ] || continue
    pane_id=$(wm_backend_herdr_pane_for_tab "$session" "$wsid" "$tab_id") || continue
    [ -n "$pane_id" ] || continue
    printf '%s:%s\t%s\n' "$session" "$pane_id" "$label"
  done < <(printf '%s' "$tabs" | jq -r '.result.tabs[]? | select(.label | startswith("wm-")) | "\(.tab_id)\t\(.label)"' 2>/dev/null)
}

# Endpoint checks never start a server. Passive callers use this operation so
# an unavailable Herdr API cannot be mistaken for an empty fleet.
wm_backend_herdr_endpoint_state() {
  local target=$1 session pane status running out panes found
  wm_backend_herdr_parse_target "$target" || { printf 'ambiguous\n'; return 0; }
  session="$WM_BACKEND_HERDR_SESSION"; pane="$WM_BACKEND_HERDR_PANE"
  out="$(HERDR_SESSION="$session" herdr pane get "$pane" 2>/dev/null)" && {
    printf '%s' "$out" | jq -e '.result.pane.pane_id // .result.pane.id' >/dev/null 2>&1 && printf 'alive\n' || printf 'unreadable\n'
    return 0
  }
  # A failed exact read is missing only when a successful inventory proves the
  # server is readable and the pane is absent. A failed inventory remains
  # unreadable, so passive callers never relaunch or close an uncertain target.
  panes="$(HERDR_SESSION="$session" herdr pane list 2>/dev/null)" || {
    status="$(HERDR_SESSION="$session" herdr status --json 2>/dev/null)" || { printf 'unreadable\n'; return 0; }
    running="$(printf '%s' "$status" | jq -r '.server.running // false' 2>/dev/null)"
    [ "$running" = false ] && printf 'missing\n' || printf 'unreadable\n'
    return 0
  }
  found="$(printf '%s' "$panes" | jq -r --arg pane "$pane" '.result.panes[]? | select(.pane_id == $pane) | .pane_id' 2>/dev/null)"
  [ "$found" = "$pane" ] && printf 'alive\n' || printf 'missing\n'
}
wm_backend_herdr_reachable() {
  local session=${1:-default} out running
  out="$(HERDR_SESSION="$session" herdr status --json 2>/dev/null)" || return 1
  running="$(printf '%s' "$out" | jq -r '.server.running // false' 2>/dev/null)"
  [ "$running" = true ]
}
# wm_backend_herdr_inventory: one JSON line per live pane in <session>'s
# "wingman" workspace, for reconcile's liveness pass. This read is
# authoritative for death - reconcile flips every Herdr member whose endpoint
# is absent from it - so every failure to read the API aborts the whole
# function (return 1) rather than emitting a partial inventory: a partial
# inventory silently omitting a live pane would flag that live member dead,
# while an aborted read makes the caller defer the pass entirely. That is the
# one deliberate difference from wm_backend_herdr_list_live above, which
# only ever finds panes and so can afford to skip an unreadable one.
#
# Reads "tab list" and "pane list" once each (not once per tab via
# wm_backend_herdr_pane_for_tab) and validates the shape of both before
# joining them in jq: an exit-0 response whose body isn't the shape this
# parses (an error object, protocol drift, an unparseable payload) must fail
# the read too - jq's own `?` would otherwise swallow it into zero matches,
# indistinguishable from a workspace that genuinely holds none. One call per
# API instead of N also narrows the tab-list/pane-list race window to a
# single pair of reads, and lets jq build each line's JSON from `--argjson`
# instead of raw printf interpolation, so a label containing a quote or
# backslash can never emit a line json.loads on the reading side would
# silently drop - which would read as that member being absent, the same
# failure shape this function exists to rule out.
#
# A tab jq cannot pair with any pane in this same pane-list read (checked
# once the shape validation above has passed) is dropped from the inventory,
# not treated as a read failure: the workspace's pane list is itself
# authoritative for which tabs currently have a live root pane, exactly as
# the tab list is authoritative for which tabs currently exist - an absence
# there is real, current evidence, not an unreadable response.
wm_backend_herdr_inventory() {
  local session=$1 wsid tabs panes
  wsid="$(wm_backend_herdr_workspace_find "$session")" || return 1
  [ -n "$wsid" ] || return 0
  tabs="$(HERDR_SESSION="$session" herdr tab list --workspace "$wsid" 2>/dev/null)" || return 1
  printf '%s' "$tabs" | jq -e '(.result.tabs | type) == "array"' >/dev/null 2>&1 || return 1
  panes="$(HERDR_SESSION="$session" herdr pane list --workspace "$wsid" 2>/dev/null)" || return 1
  printf '%s' "$panes" | jq -e '(.result.panes | type) == "array"' >/dev/null 2>&1 || return 1
  jq -n -c --arg session "$session" --arg wsid "$wsid" --argjson tabs "$tabs" --argjson panes "$panes" '
    ($panes.result.panes // []) as $panes
    | ($tabs.result.tabs // [])[] as $t
    | select(($t.tab_id // "") != "")
    | ([$panes[] | select(.tab_id == $t.tab_id) | .pane_id] | .[0]) as $pane_id
    | select($pane_id != null and $pane_id != "")
    | {
        backend: "herdr",
        endpoint: ($session + ":" + $pane_id),
        physical_id: $t.tab_id,
        label: ($t.label // ""),
        workspace_id: $wsid,
        tab_id: $t.tab_id,
        pane_id: $pane_id
      }
  ' 2>/dev/null
}
wm_backend_herdr_close() {
  local target=$1
  wm_backend_herdr_parse_target "$target" || return 1
  HERDR_SESSION="$WM_BACKEND_HERDR_SESSION" herdr pane close "$WM_BACKEND_HERDR_PANE" >/dev/null 2>&1
}
wm_backend_herdr_attach_hint() {
  local target=$1
  wm_backend_herdr_parse_target "$target" || return 1
  printf 'herdr --session %s  # select pane %s in the Wingman workspace\n' "$WM_BACKEND_HERDR_SESSION" "$WM_BACKEND_HERDR_PANE"
}
