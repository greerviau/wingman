# common.sh - shared helpers for wingman's bin/ scripts.
# Sourced, never executed. Must run on stock macOS bash 3.2:
#   no associative arrays, no ${x,,}, no mapfile/readarray. POSIX-safe where practical.

# Resolve the wingman repo root from this file's location (bin/lib/common.sh).
_wm_lib_dir() {
  # $BASH_SOURCE points at this file even when sourced.
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}
WM_LIB="$(_wm_lib_dir)"
WM_BIN="$(dirname "$WM_LIB")"
WM_REPO="$(dirname "$WM_BIN")"
export WM_REPO WM_BIN WM_LIB

# Machine-local state home. Overridable for tests.
WM_HOME="${WINGMAN_HOME:-$HOME/.wingman}"
export WINGMAN_HOME="$WM_HOME"

# Python is run through uv, which manages the interpreter and (via --no-project)
# ignores any pyproject.toml in the current directory - important because crew
# run inside target repos that have their own projects. wm-state.py declares its
# requires-python inline (PEP 723), so uv needs no extra config.
WM_UV="${WM_UV:-uv run --no-project --quiet}"
WM_STATE_PY="$WM_LIB/wm-state.py"

# wm_py runs an inline snippet or `python ...` under the managed interpreter.
wm_py() { $WM_UV python "$@"; }
# wm_state runs the state engine.
wm_state() { $WM_UV "$WM_STATE_PY" "$@"; }

# --- output helpers ---------------------------------------------------------
if [ -t 1 ]; then
  _WM_R=$'\033[31m'; _WM_G=$'\033[32m'; _WM_Y=$'\033[33m'; _WM_B=$'\033[34m'; _WM_0=$'\033[0m'
else
  _WM_R=; _WM_G=; _WM_Y=; _WM_B=; _WM_0=
fi
wm_info()  { printf '%s%s%s\n' "$_WM_B" "$*" "$_WM_0"; }
wm_ok()    { printf '%s\xe2\x9c\x93 %s%s\n' "$_WM_G" "$*" "$_WM_0"; }
wm_warn()  { printf '%s! %s%s\n' "$_WM_Y" "$*" "$_WM_0" >&2; }
wm_err()   { printf '%s\xe2\x9c\x97 %s%s\n' "$_WM_R" "$*" "$_WM_0" >&2; }
wm_die()   { wm_err "$*"; exit 1; }

# --- platform ---------------------------------------------------------------
wm_platform() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux)  echo linux ;;
    *)      echo unknown ;;
  esac
}

# Print the install command for a package on this platform, or empty if unknown.
wm_install_cmd() {
  pkg="$1"
  case "$(wm_platform)" in
    macos) echo "brew install $pkg" ;;
    linux)
      if command -v apt-get >/dev/null 2>&1; then echo "sudo apt-get install -y $pkg"
      elif command -v dnf >/dev/null 2>&1; then echo "sudo dnf install -y $pkg"
      elif command -v pacman >/dev/null 2>&1; then echo "sudo pacman -S --noconfirm $pkg"
      else echo ""; fi ;;
    *) echo "" ;;
  esac
}

wm_have() { command -v "$1" >/dev/null 2>&1; }

# List available crew types: every playbook basename in crew/ (tracked
# <type>.md or gitignored <type>.local.md), excluding _-prefixed shared partials.
# Crew types are open-ended - add a playbook and the type exists.
wm_crew_types() {
  for f in "$WM_REPO"/crew/*.md "$WM_REPO"/crew/*.local.md; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"; b="${b%.local.md}"; b="${b%.md}"
    case "$b" in _*) continue ;; esac
    echo "$b"
  done | sort -u
}

# Single-quote-escape an argument so it can be embedded safely in generated
# shell source. Portable to bash 3.2 (no ${var@Q}).
quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# --- tmux helpers -----------------------------------------------------------
# All tmux calls live behind this boundary so a future backend swap is localized.
WM_TMUX_SESSION="${WM_TMUX_SESSION:-wingman}"

wm_tmux() { tmux "$@"; }

# Deliver a message into a live interactive session: type the (possibly large)
# text, then submit with Enter. The two keystrokes are split by a short settle
# delay on purpose. An interactive TUI (e.g. Claude Code) ingests a rapid bulk
# burst as a bracketed paste - the "[Pasted text #N]" placeholder - and an Enter
# fired in the same burst is absorbed as a newline inside that paste instead of
# submitting it, leaving the message sitting unexecuted in the input box. The
# delay lets the paste finalize so the following Enter is seen as a submit.
# Override the settle time (seconds) with WM_SUBMIT_DELAY.
wm_tmux_send_message() {
  _target="$1"; _text="$2"
  wm_tmux send-keys -t "$_target" -l "$_text"
  sleep "${WM_SUBMIT_DELAY:-1}"
  wm_tmux send-keys -t "$_target" Enter
}

# Ensure the shared tmux server + wingman session exist (detached).
wm_tmux_ensure_session() {
  if ! wm_tmux has-session -t "$WM_TMUX_SESSION" 2>/dev/null; then
    wm_tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
  fi
}

# List live window names in the wingman session, one per line.
wm_tmux_windows() {
  wm_tmux list-windows -t "$WM_TMUX_SESSION" -F '#{window_name}' 2>/dev/null
}

# Comma-joined window list (for wm-state reconcile --windows).
wm_tmux_windows_csv() {
  wm_tmux_windows | tr '\n' ',' | sed 's/,$//'
}
