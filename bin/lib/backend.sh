#!/usr/bin/env bash
# Backend selection and dispatch for crew terminal endpoints.

wm_backend_known() {
  case "$1" in tmux|herdr) return 0 ;; *) return 1 ;; esac
}
wm_backend_validate() {
  wm_backend_known "$1" || wm_die "unknown runtime backend '$1' (expected tmux or herdr)"
  if [ "$1" = herdr ]; then
    wm_backend_source herdr || return 1
    wm_backend_herdr_tool_check
  fi
}
wm_backend_select() {
  local explicit="${1:-}" selected=""
  if [ -n "$explicit" ]; then selected="$explicit"
  elif [ -n "${WM_BACKEND:-}" ]; then selected="$WM_BACKEND"
  elif [ -n "${TMUX:-}" ]; then selected=tmux
  elif [ "${HERDR_ENV:-}" = 1 ]; then
    selected=herdr
    wm_info "auto-detected Herdr; new crew members use the experimental herdr backend" >&2
  else selected=tmux
  fi
  wm_backend_validate "$selected" || return 1
  printf '%s\n' "$selected"
}
wm_backend_source() {
  case "$1" in
    tmux) [ -n "${_WM_BACKEND_TMUX_SOURCED:-}" ] || { . "$WM_LIB/backends/tmux.sh"; _WM_BACKEND_TMUX_SOURCED=1; } ;;
    herdr) [ -n "${_WM_BACKEND_HERDR_SOURCED:-}" ] || { . "$WM_LIB/backends/herdr.sh"; _WM_BACKEND_HERDR_SOURCED=1; } ;;
    *) wm_backend_validate "$1" || return 1 ;;
  esac
}
wm_backend_record_field() {
  local id=$1 field=$2
  wm_state crew-get --id "$id" 2>/dev/null | wm_py -c 'import json,sys; d=json.load(sys.stdin); print(d.get(sys.argv[1]) or "")' "$field" 2>/dev/null
}
wm_backend_for_record() {
  local backend
  backend="$(wm_backend_record_field "$1" backend)"
  printf '%s\n' "${backend:-tmux}"
}
# Endpoint from already-known fields, for a caller that has just read this
# member's record for other reasons (bin/watch-fleet's terminal-condition
# checks). wm_backend_endpoint_for_member is this same function preceded by
# two record reads; keeping one implementation means the two can never
# disagree about how an endpoint is formed.
wm_backend_endpoint_from_fields() {
  local backend=$1 id=$2 window=$3
  # Legacy fixtures and records may omit the compatibility display field; tmux
  # can recover its historical endpoint from the stable member id. Herdr never
  # guesses an endpoint because its pane identity is opaque and non-derivable.
  if [ "$backend" = tmux ]; then
    [ -n "$window" ] || window="wm-$id"
    wm_tmux_win_target "$window"
  else
    printf '%s\n' "$window"
  fi
}
wm_backend_endpoint_for_member() {
  local id=$1 backend window
  backend="$(wm_backend_for_record "$id")"
  window="$(wm_backend_record_field "$id" window)"
  wm_backend_endpoint_from_fields "$backend" "$id" "$window"
}
wm_backend_create_container() {
  local backend=$1 cwd=$2
  wm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) wm_backend_tmux_create_container "$cwd" ;;
    herdr) wm_backend_herdr_container_ensure "$cwd" ;;
  esac
}
wm_backend_create_member() {
  local backend=$1 container=$2 label=$3 cwd=$4 launch=$5
  wm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) wm_backend_tmux_create_member "$container" "$label" "$cwd" "$launch" ;;
    herdr)
      local result session workspace tab pane
      result="$(wm_backend_herdr_create_task "$container" "$label" "$cwd")" || return 1
      session="${container%%:*}"; workspace="${container#*:}"
      tab="${result%% *}"; pane="${result#* }"
      printf '%s\t%s\t%s\t%s\t%s\n' "$session" "$workspace" "$tab" "$pane" "$session:$pane"
      ;;
  esac
}
wm_backend_start_member() {
  local backend=$1 target=$2 launch=$3
  wm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) : ;;
    herdr) wm_backend_herdr_send_text_line "$target" "bash $(quote "$launch")" ;;
  esac
}
wm_backend_capture() {
  local backend=$1 target=$2 lines=${3:-200}
  wm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) wm_backend_tmux_capture "$target" ;;
    herdr) wm_backend_herdr_capture "$target" "$lines" ;;
  esac
}
wm_backend_send_message() {
  local backend=$1 target=$2 text=$3 agent=${4:-claude}
  wm_backend_source "$backend" || return 1
  case "$backend" in
    tmux) wm_tmux_send_message "$target" "$text" "$agent" ;;
    herdr)
      local verdict
      verdict="$(wm_backend_herdr_send_text_submit "$target" "$text" "${WM_SUBMIT_TRIES:-3}" "${WM_SUBMIT_RETRY_DELAY:-0.5}" "${WM_SUBMIT_DELAY:-1}")"
      case "$verdict" in empty) return 0 ;; pending|unknown|send-failed) return 3 ;; *) return 3 ;; esac
      ;;
  esac
}
wm_backend_send_for_member() {
  local id=$1 text=$2 agent=${3:-} backend target
  backend="$(wm_backend_for_record "$id")"
  target="$(wm_backend_endpoint_for_member "$id")"
  [ -n "$agent" ] || agent="$(wm_crew_agent_name "$id")"
  wm_backend_send_message "$backend" "$target" "$text" "$agent"
}
wm_backend_send_key() {
  local backend=$1 target=$2 key=$3
  wm_backend_source "$backend" || return 1
  case "$backend" in tmux) wm_backend_tmux_send_key "$target" "$key" ;; herdr) wm_backend_herdr_send_key "$target" "$key" ;; esac
}
wm_backend_busy_state() {
  local backend=$1 target=$2
  wm_backend_source "$backend" || { printf 'unknown\n'; return 0; }
  case "$backend" in tmux) wm_backend_tmux_busy_state "$target" ;; herdr) wm_backend_herdr_busy_state "$target" ;; esac
}
wm_backend_endpoint_state() {
  local backend=$1 target=$2
  wm_backend_source "$backend" || { printf 'unreadable\n'; return 0; }
  case "$backend" in tmux) wm_backend_tmux_endpoint_state "$target" ;; herdr) wm_backend_herdr_endpoint_state "$target" ;; esac
}
wm_backend_list_live() {
  local backend=$1
  wm_backend_source "$backend" || return 1
  case "$backend" in tmux) wm_backend_tmux_list_live ;; herdr) wm_backend_herdr_list_live "${2:-${HERDR_SESSION:-default}}" ;; esac
}
wm_backend_live_inventory() {
  local backend=$1
  wm_backend_source "$backend" || return 1
  case "$backend" in tmux) wm_backend_tmux_inventory ;; herdr) wm_backend_herdr_inventory "${2:-${HERDR_SESSION:-default}}" ;; esac
}
# wm_backend_herdr_reconcile_inventory <roster-json>: the merged Herdr
# liveness inventory across every session any LIVE Herdr roster record
# actually names, not just the caller's own ambient $HERDR_SESSION -
# HERDR_SESSION is one operator's own selection (herdr.sh:45-51, mirroring
# tmux's $TMUX), so a member spawned under a different session is real
# evidence this pass must also gather, never an absence to judge it dead by.
#
# Each session's OWN read stays all-or-nothing (wm_backend_live_inventory
# either returns that session's full inventory or fails outright), but a
# session that fails is DROPPED from the gather rather than aborting the
# whole call: a permanently unreachable session would otherwise defer this
# pass forever on every future call too (a member whose session died writes
# nothing further, so its own record keeps naming that same dead session),
# masking every other session's genuine deaths right along with it - a new
# failure mode this exists to rule out, not the one --inventory-sessions
# already exists to catch.
#
# Two results, not one, so this is called plainly (never via `$(...)` - a
# command substitution forks a subshell, and everything this sets would be
# lost the instant it exits): $WM_HERDR_RECONCILE_INVENTORY (the merged
# inventory) and $WM_HERDR_RECONCILE_SESSIONS (NEWLINE-separated, the
# sessions actually covered - pass it to `reconcile --inventory-sessions`,
# which leaves a record in an uncovered session alone instead of comparing
# it against a gather that was never authoritative for it). Newline, not
# comma: a session name is raw operator input (wm_backend_herdr_session
# echoes $HERDR_SESSION verbatim, herdr.sh:49-51) with nothing validating
# its characters, and a comma-joined encoding split back on commas silently
# desyncs a session name that itself contains a comma from its own entry in
# the covered set - every member of that session then reads as permanently
# uncovered, with no way to clear since the session name never changes.
# Both reset on every call, empty when no Herdr member is currently live -
# the caller still calls reconcile in that case (an empty
# --inventory-sessions judges every herdr record as outside the covered
# set, so it is a harmless no-op call, not a skipped one).
wm_backend_herdr_reconcile_inventory() {
  local roster_json=$1 sessions session one
  WM_HERDR_RECONCILE_SESSIONS=""
  WM_HERDR_RECONCILE_INVENTORY=""
  sessions="$(printf '%s' "$roster_json" | jq -r \
    '.[] | select(.backend == "herdr") | select(.status == "working" or .status == "blocked" or .status == "review" or .status == "stalled") | (.window // "") | split(":")[0] | select(length > 0)' \
    2>/dev/null | sort -u)"
  [ -n "$sessions" ] || return 0
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    one="$(wm_backend_live_inventory herdr "$session" 2>/dev/null)" || continue
    WM_HERDR_RECONCILE_SESSIONS="$WM_HERDR_RECONCILE_SESSIONS
$session"
    [ -n "$one" ] && WM_HERDR_RECONCILE_INVENTORY="$WM_HERDR_RECONCILE_INVENTORY
$one"
  done <<EOF
$sessions
EOF
}
wm_backend_close() {
  local backend=$1 target=$2
  wm_backend_source "$backend" || return 1
  case "$backend" in tmux) wm_backend_tmux_close "$target" ;; herdr) wm_backend_herdr_close "$target" ;; esac
}
wm_backend_attach_hint() {
  local backend=$1 target=$2
  wm_backend_source "$backend" || return 1
  case "$backend" in tmux) wm_backend_tmux_attach_hint "$target" ;; herdr) wm_backend_herdr_attach_hint "$target" ;; esac
}
wm_backend_reachable() {
  local backend=$1
  wm_backend_source "$backend" || return 1
  case "$backend" in tmux) wm_backend_tmux_reachable ;; herdr) wm_backend_herdr_reachable "${2:-${HERDR_SESSION:-default}}" ;; esac
}
wm_backend_adopt_strays() {
  local backend=$1
  wm_backend_source "$backend" || return 1
  case "$backend" in tmux) wm_backend_tmux_adopt_strays ;; herdr) : ;; esac
}
