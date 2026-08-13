#!/usr/bin/env bash
# The tmux runtime backend.  The adapter keeps the existing tmux primitives
# byte-compatible while the dispatcher gives callers a backend-neutral seam.

wm_backend_tmux_validate() { wm_have tmux; }
wm_backend_tmux_required_tools() { printf '%s\n' tmux; }
wm_backend_tmux_create_container() {
  wm_tmux_ensure_session
  printf '%s\n' "$WM_TMUX_SESSION"
}
wm_backend_tmux_create_member() {
  local container=$1 label=$2 cwd=$3 launch=$4 id
  id="$(wm_tmux new-window -d -PF '#{window_id}' -t "$WM_TMUX_TARGET:" -n "$label" "bash $(quote "$launch")")" || return 1
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}
wm_backend_tmux_start_member() { :; }
wm_backend_tmux_capture() { wm_tmux_pane_text "$1"; }
wm_backend_tmux_send_message() { wm_tmux_send_message "$@"; }
wm_backend_tmux_send_key() {
  local target=$1 key=$2
  case "$key" in
    Enter|Escape|C-c) wm_tmux send-keys -t "$target" "$key" ;;
    *) wm_die "unsupported tmux key '$key'" ;;
  esac
}
wm_backend_tmux_busy_state() { printf '%s\n' unknown; }
wm_backend_tmux_endpoint_state() {
  local target="$1"
  [ -n "$target" ] || { printf 'ambiguous\n'; return 0; }
  # The recorded target includes exact session and window selectors. Query it
  # directly so a duplicate window label cannot make another endpoint appear
  # alive. Cold-start errors mean missing; other errors are unreadable.
  local output
  output="$(wm_tmux list-windows -t "$target" -F '#{window_name}' 2>&1)" && { printf 'alive\n'; return 0; }
  case "$output" in
    no\ server\ running*|error\ connecting\ to*"No such file or directory"*|*"can't find session"*|*"can't find window"*) printf 'missing\n' ;;
    *) printf 'unreadable\n' ;;
  esac
}
wm_backend_tmux_list_live() {
  wm_tmux list-windows -t "$WM_TMUX_TARGET" -F '#{window_name}\t#{window_id}' 2>/dev/null
}
wm_backend_tmux_inventory() {
  wm_tmux list-windows -t "$WM_TMUX_TARGET" -F '#{window_name}\t#{window_id}' 2>/dev/null |
    while IFS="$(printf '\t')" read -r label physical_id; do
      [ -n "$label" ] || continue
      printf '{"backend":"tmux","endpoint":"%s","physical_id":"%s","label":"%s"}\n' "$label" "$physical_id" "$label"
    done
}
wm_backend_tmux_close() { wm_tmux kill-window -t "$1" 2>/dev/null; }
wm_backend_tmux_attach_hint() { printf 'tmux attach -t %s \\; select-window -t %s\n' "$WM_TMUX_TARGET" "$1"; }
wm_backend_tmux_reachable() { wm_tmux_reachable; }
wm_backend_tmux_adopt_strays() { wm_tmux_adopt_strays; }
wm_backend_tmux_prefix_inventory() { wm_tmux_prefix_windows_csv; }
