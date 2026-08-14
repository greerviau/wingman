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
wm_backend_endpoint_for_member() {
  local id=$1 backend window
  backend="$(wm_backend_for_record "$id")"
  window="$(wm_backend_record_field "$id" window)"
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
