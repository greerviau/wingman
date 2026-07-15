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

# Root of the playbook library: category subdirectories of role files, plus the
# shared _status-contract.md partial at its own top level. Overridable (like
# WM_HOME above) so tests can point the resolver at an isolated fixture tree
# instead of mutating the live repo's playbook/ directory.
WM_PLAYBOOKS="${WM_PLAYBOOKS:-$WM_REPO/playbooks}"
export WM_PLAYBOOKS

# Python is run through uv, which manages the interpreter and (via --no-project)
# ignores any pyproject.toml in the current directory - important because crew
# run inside target repos that have their own projects. wm-state.py declares its
# requires-python inline (PEP 723), so uv needs no extra config.
WM_UV="${WM_UV:-uv run --no-project --quiet}"
WM_STATE_PY="$WM_LIB/wm-state.py"

# The state engine as a session-facing command string: the exact shape CLAUDE.md
# and playbooks/_status-contract.md tell every session to run ($WINGMAN_STATE
# prefs-list / pref-set / crew-set ...), and the exact shape hooks/lib/cmd_match.py
# resolves back to `wm-state.py`. Exported from the one file both launch paths
# already source, so wingman's own session (bin/wingman execs claude with this
# environment) and every crew session (bin/spawn-crew writes it into the generated
# launch script) carry one definition that cannot drift from the other. That
# single definition is what makes the preferences guard's activation condition
# safe: WINGMAN_RUN_ID (the only thing that turns the guard on) is set by
# bin/wingman, which cannot run without sourcing this file.
WINGMAN_STATE="$WM_UV $WM_STATE_PY"
export WINGMAN_STATE

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

# List available crew types: every playbook role file under $WM_PLAYBOOKS (at
# any category depth, including nested sub-domains like
# scientific-research/biological-research/), tracked <role>.md or gitignored
# <role>.local.md, excluding _-prefixed shared partials. Printed as
# category-qualified "category/role" lines; sorting also groups each
# category's roles together, which is the "grouped by category" contract.
# bash-3.2-safe: find + a while-read loop via process substitution (no
# globstar, no arrays, no mapfile). Crew types are open-ended - add a
# playbook and the type exists.
wm_crew_types() {
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    b="$(basename "$f")"
    case "$b" in _*) continue ;; esac
    b="${b%.local.md}"; b="${b%.md}"
    d="$(dirname "$f")"
    cat="${d#"$WM_PLAYBOOKS"/}"
    [ "$cat" = "$d" ] && continue  # file sits directly at $WM_PLAYBOOKS root (e.g. the partial, already filtered above)
    echo "$cat/$b"
  done < <(find "$WM_PLAYBOOKS" -type f \( -name '*.md' -o -name '*.local.md' \) 2>/dev/null) | sort -u
}

# Single-quote-escape an argument so it can be embedded safely in generated
# shell source. Portable to bash 3.2 (no ${var@Q}).
quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Escape find(1) -name glob metacharacters (\, *, ?, [, ]) so a crew type
# containing one of these is matched as a literal filename, not a pattern -
# find -name treats its argument as a shell glob, and an unescaped --type
# value could otherwise match far more files than the exact-name lookup the
# resolver's collision detection depends on.
wm_glob_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/\*/\\*/g' -e 's/?/\\?/g' -e 's/\[/\\[/g' -e 's/\]/\\]/g'
}

# Resolve a crew --type to a playbook file under $WM_PLAYBOOKS, local override
# (<type>.local.md) winning over the tracked <type>.md, and set PLAYBOOK to the
# result (or wm_die with a precise message). A bare name (e.g. "developer") is
# searched across every category directory - role names are kept unique across
# categories, so every shipped type resolves unambiguously; a
# category-qualified name ("software-development/developer") is accepted to
# break a genuine collision. Wrapped in its own function so its use of the
# script's positional parameters ($1, and no `set --` of the caller's argv) is
# scoped to this call and can never collide with the caller's own arguments.
wm_resolve_playbook() {
  _rp_type="$1"
  case "$_rp_type" in
    */*)
      # Category-qualified form: resolve directly, local override wins.
      PLAYBOOK="$WM_PLAYBOOKS/$_rp_type.md"
      [ -f "$WM_PLAYBOOKS/$_rp_type.local.md" ] && PLAYBOOK="$WM_PLAYBOOKS/$_rp_type.local.md"
      [ -f "$PLAYBOOK" ] || wm_die "no playbook for crew type '$_rp_type'. Available: $(wm_crew_types | tr '\n' ' ')- to add it, create $WM_PLAYBOOKS/$_rp_type.md (or $_rp_type.local.md)"
      ;;
    *)
      # Bare form: search every category directory for a role file named
      # $_rp_type. Collapse a .local.md onto its sibling .md in the same
      # directory (still one candidate directory - local override still wins
      # there); more than one distinct directory is a collision the caller
      # must disambiguate. Directories are collected newline-delimited (not
      # space-joined + `set --`) so a path containing a space is never
      # mis-split.
      _rp_esc="$(wm_glob_escape "$_rp_type")"
      _rp_dirs=$'\n'
      _rp_count=0
      while IFS= read -r _rp_f; do
        [ -n "$_rp_f" ] || continue
        _rp_d="$(dirname "$_rp_f")"
        case "$_rp_dirs" in
          *$'\n'"$_rp_d"$'\n'*) ;;
          *) _rp_dirs="$_rp_dirs$_rp_d"$'\n'; _rp_count=$((_rp_count+1)); _rp_only="$_rp_d" ;;
        esac
      done < <(find "$WM_PLAYBOOKS" -type f \( -name "$_rp_esc.md" -o -name "$_rp_esc.local.md" \) 2>/dev/null)
      case "$_rp_count" in
        0)
          wm_die "no playbook for crew type '$_rp_type'. Available: $(wm_crew_types | tr '\n' ' ')- to add it, create $WM_PLAYBOOKS/<category>/$_rp_type.md (or $_rp_type.local.md)"
          ;;
        1)
          _rp_d="$_rp_only"
          ;;
        *)
          _rp_qualified=""
          while IFS= read -r _rp_d2; do
            [ -n "$_rp_d2" ] || continue
            _rp_qualified="$_rp_qualified ${_rp_d2#"$WM_PLAYBOOKS"/}/$_rp_type"
          done <<<"$_rp_dirs"
          wm_die "crew type '$_rp_type' is ambiguous across categories: pick one of$_rp_qualified"
          ;;
      esac
      PLAYBOOK="$_rp_d/$_rp_type.md"
      [ -f "$_rp_d/$_rp_type.local.md" ] && PLAYBOOK="$_rp_d/$_rp_type.local.md"
      ;;
  esac
}

# --- team guardrail ---------------------------------------------------------
# Collaboration stays within a team: a caller may reach only its own direct
# reports, a sibling under the same lead, or its own lead. Print a verdict for
# whether <caller> may reach <target>:
#   ok        - target is a direct report of the caller, a sibling under the same
#               lead, or the caller's own lead
#   deny      - target exists but is outside the caller's team
#   no-target - no roster record for target
# Shared by crew-say (one-way inject) and crew-ask (ask-and-capture) so both
# honour one policy. The caller id is "" for wingman (the top orchestrator, which
# has no roster record); a member passes its own $WINGMAN_CREW_ID.
wm_team_guardrail() {
  _tg_caller="$1"; _tg_target="$2"
  wm_state crew-list --all --json 2>/dev/null | wm_py -c '
import sys, json
caller, target = sys.argv[1], sys.argv[2]
try:
    roster = json.load(sys.stdin)
except Exception:
    roster = []
by_id = dict((r.get("id"), r) for r in roster)
def parent(cid):
    r = by_id.get(cid)
    return (r.get("parent") or "") if r is not None else None
tgt = by_id.get(target)
if tgt is None:
    print("no-target"); sys.exit(0)
tp = tgt.get("parent") or ""
cp = parent(caller)  # None when the caller has no record (wingman itself)
ok = (tp == caller)                       # target is a direct report of the caller
ok = ok or (cp is not None and tp == cp)  # target is a sibling under the same lead
ok = ok or (cp is not None and target == cp)  # target is the caller own lead
print("ok" if ok else "deny")
' "$_tg_caller" "$_tg_target" 2>/dev/null
}

# --- tmux helpers -----------------------------------------------------------
# All tmux calls live behind this boundary so a future backend swap is localized.
WM_TMUX_SESSION="${WM_TMUX_SESSION:-wingman}"

# Exact-match target forms (issue #39). tmux resolves a bare `-t <name>` by
# exact name, then PREFIX, then fnmatch - so with no session literally named
# "wingman", every `-t wingman` silently binds to e.g. "wingman-main" or a
# user's own "wingman-server", and the whole crew layer follows the
# misresolution consistently (windows injected into wingman's own or an
# unrelated session, defeating the crew/orchestrator session separation).
# The "=" prefix disables prefix/fnmatch resolution for the part it precedes;
# every session or window target must be built from these forms, never from a
# bare "$WM_TMUX_SESSION".
WM_TMUX_TARGET="=$WM_TMUX_SESSION"
# Exact session:window target for one crew window.
wm_tmux_win_target() { printf '=%s:=%s' "$WM_TMUX_SESSION" "$1"; }

wm_tmux() { tmux "$@"; }

# Refuse to silently launch a real agent CLI into what looks like a test
# fixture. wm-test-* is the suite's own tmux-session naming convention
# (tests/lib.sh: WM_TMUX_SESSION="wm-test-${WM_TEST_RUN_ID:-x}-$$-$RANDOM");
# the wm-test. temp-dir prefix is the suite's own mktemp convention (see
# wm_mktemp_dir). Either match plus an unset WM_AGENT means nobody meant to
# launch anything real - a test that does mean to launch something always
# stubs WM_AGENT itself.
wm_guard_test_fixture_agent() {
  [ -n "${WM_AGENT:-}" ] && return 0
  case "$WM_TMUX_SESSION" in
    wm-test-*) wm_die "WM_TMUX_SESSION='$WM_TMUX_SESSION' looks like a test fixture and WM_AGENT is unset; refusing to launch a real '${1:-claude}'. Set WM_AGENT to a stub, or pass the real agent explicitly, before calling $(basename "$0")." ;;
  esac
  case "$WM_HOME" in
    "${TMPDIR:-/tmp}"/wm-test.*/*|"${TMPDIR:-/tmp}"/wm-test.*) wm_die "WINGMAN_HOME='$WM_HOME' looks like a test fixture and WM_AGENT is unset; refusing to launch a real '${1:-claude}'. Set WM_AGENT to a stub, or pass the real agent explicitly, before calling $(basename "$0")." ;;
  esac
}

# Run a tmux command that may fork a brand-new tmux server (the first tmux
# call on a machine, or after the server died). Such a call must not run
# directly in a mortal cgroup: under a systemd user service (e.g. a
# Type=oneshot boot-time starter), every process left in the service's cgroup
# is killed the instant the service's main process exits - the freshly-forked
# server dies within seconds, taking every session it hosts with it, silently
# (no stderr, no crash, and later spawns then prefix-match into the wrong
# session). A transient systemd scope detaches the server's lifetime from the
# caller's unit; when a server already exists the wrapped call is a mere
# client and the scope evaporates with it (--collect). Without systemd
# (macOS) the call runs plainly - the reap hazard is systemd-specific.
wm_tmux_scoped() {
  if wm_have systemd-run && [ -n "${XDG_RUNTIME_DIR:-}" ] \
     && [ -e "${XDG_RUNTIME_DIR}/systemd/private" ]; then
    systemd-run --user --scope --collect --quiet -- tmux "$@"
  else
    tmux "$@"
  fi
}

# Print the visible text of a target's active pane. Used by the watcher to detect
# a crew member frozen on an interactive prompt (a terminal-UI state that never
# reaches the status files).
wm_tmux_pane_text() { wm_tmux capture-pane -p -t "$1" 2>/dev/null; }

# Capture a window's pane text once per poll and compare it to the previous
# poll's capture, so every per-poll caller (the permission-freeze check, the
# API-error check) shares one capture+hash instead of each doing its own.
# Sets PANE_TEXT (the current capture) and PANE_STABLE (1 iff byte-identical to
# the previous poll's capture for this id, else 0). The per-id hash lives in
# $WM_HOME/pane-<id>.hash (the pidfile-naming pattern); a stale file is harmless.
wm_pane_snapshot() {
  _id="$1"; _win="$2"
  PANE_TEXT="$(wm_tmux_pane_text "$(wm_tmux_win_target "$_win")")"
  _hashfile="$WM_HOME/pane-$(printf '%s' "$_id" | tr -c 'A-Za-z0-9._-' '_').hash"
  _hash="$(printf '%s' "$PANE_TEXT" | cksum)"
  _prev="$(cat "$_hashfile" 2>/dev/null)"
  printf '%s\n' "$_hash" > "$_hashfile"
  if [ -n "$_prev" ] && [ "$_hash" = "$_prev" ]; then PANE_STABLE=1; else PANE_STABLE=0; fi
}

# Pid of the root process of a window's first pane (the agent CLI itself - spawn-crew
# execs it as the pane command). Empty if the window is unknown.
wm_tmux_pane_pid() {
  wm_tmux list-panes -t "$(wm_tmux_win_target "$1")" -F '#{pane_pid}' 2>/dev/null | head -1
}

# Seconds since the last output in a window's pane, from tmux's own
# #{window_activity} (epoch secs), which advances on any pane repaint and is
# independent of the monitor-activity option. Prints a large number if the window
# is unknown, so callers treat "can't tell" as "not stale enough to suppress a
# real flag" - the AND with status-idle guards the flag itself.
# Harness-neutral: any TUI that repaints while working keeps this fresh.
wm_tmux_window_activity_age() {
  _win="$1"
  _act="$(wm_tmux list-windows -t "$WM_TMUX_TARGET" \
            -F '#{window_name} #{window_activity}' 2>/dev/null \
          | awk -v w="$_win" '$1==w {print $2; exit}')"
  [ -n "$_act" ] || { echo 999999; return; }
  echo $(( $(date +%s) - _act ))
}

# Signature of an interactive prompt (a permission/confirmation dialog, the
# one-time workspace-trust dialog, the one-time Bypass Permissions acceptance) as
# opposed to a normal idle chat input box. Shared by watch-fleet's pane backstop
# (a member frozen on this) and wm_tmux_send_message below (about to type/submit
# into this) so both act on one detector instead of two independently-drifting
# copies. Covers the gates a crew can hit: every per-tool permission phrasing ("Do
# you want to proceed?", "Do you want to make this edit…?", "Do you want to
# create…?" - the case-sensitive prefix catches them all), the workspace-trust
# dialog (matched by its "Yes, I trust this folder" option row - the question text
# varies across CLI versions and sits outside the adjacency window; verified
# against a live capture, Claude Code v2.1.206), and the Bypass Permissions mode
# acceptance (likewise matched by its acceptance rows). Precision against pane
# content that merely *mentions* a prompt (a diff, a plan, a test fixture) is
# carried by the UI-shape adjacency and stability conditions in each caller, not
# by the phrase list. Overridable (e.g. for another harness).
# No path parameter is needed here, and none was added when issue #60 raised a
# worktree-specific freeze: this detector is purely content-based already, and
# a live repro (a developer crew member driven through `git worktree add` into
# a sibling directory, then a Write-tool touch inside that new worktree, both
# against a fresh, never-before-trusted scratch repo) rendered no dialog of any
# kind for either step - the sibling worktree path falls inside the session's
# already-granted access boundary. There is no distinct worktree dialog
# variant to add a phrase for (see tests/watch-fleet.test.sh's z15 case).
WM_PERM_PROMPT_RE="${WM_PERM_PROMPT_RE:-Do you want to |Yes, I trust this folder|Bypass Permissions mode|Yes, I accept|Yes, and don.t ask}"
# A real dialog pairs the question with a numbered options list rendered with it.
WM_PERM_OPTION_RE="${WM_PERM_OPTION_RE:-^[[:space:]]*(❯[[:space:]]*)?[0-9]+\.[[:space:]]}"
# The highlighted-option glyph, if the CLI renders one. Used ONLY to reject a
# block that carries more than one such row (a real dialog highlights at most one
# option; a loose verbatim quote may duplicate the glyph). It is never required to
# accept: real captures render none (the live workspace-trust dialog signals the
# selection by indentation, not a glyph), so requiring a marker would miss the
# highest-value freeze. See WM_PERM_MIN_OPTS for the actual content discriminator.
WM_PERM_MARK_RE="${WM_PERM_MARK_RE:-^[[:space:]]*❯[[:space:]]*[0-9]+\.[[:space:]]}"
# A real gate offers a choice, so its option block holds at least this many rows
# (counting the anchor row when the anchor is itself an option). This is the
# content discriminator: it rejects a single stray numbered item whose text merely
# begins with a question phrase (one row) while every true gate - per-tool,
# workspace-trust, Bypass - renders two or more.
WM_PERM_MIN_OPTS="${WM_PERM_MIN_OPTS:-2}"
# A real dialog renders at the bottom of the screen; only this many trailing
# lines of the capture are searched, so transcript content mid-screen never
# matches.
WM_PERM_TAIL="${WM_PERM_TAIL:-25}"
# ...and renders its options directly under the question: the option block must
# begin within this many lines after the phrase line. A quoted phrase in prose
# with an unrelated numbered list elsewhere in the tail stops matching.
WM_PERM_ADJ="${WM_PERM_ADJ:-3}"
# ...and renders the question as its own line: only non-alphanumeric characters
# (whitespace, border glyphs) and optionally an option-row prefix ("❯ 1. ", so
# the trust/Bypass acceptance rows - where the phrase IS an option row - still
# match) may precede the phrase. Transcript quotes and diff hunks carry prose
# before it and stop matching.
WM_PERM_LEAD_RE="${WM_PERM_LEAD_RE:-^[^[:alnum:]]*([0-9]+\.[[:space:]])?}"

# Shared engine behind prompt_shape_in (below) and resume_prompt_shape_in
# (issue #30): true iff `text` contains `lead_re`+`phrase_re` - the question
# phrase, rendered as its own line - anchoring a full contiguous option block
# of at least `min_opts` rows (matching `option_re`) bearing at most one
# selection marker (`mark_re`): the one-block shape a real dialog renders,
# which transcript prose about prompts almost never reproduces. Extracted as
# its own function (rather than duplicated per detector) so every caller gets
# the identical, already-hardened precision instead of a fresh, unaudited
# copy - see issue #30's PR review, which showed a bare two-string
# content-only check (no shape/adjacency requirement at all) is trivially
# defeated by a pane merely displaying this shape as static text. For each
# phrase hit the option block is found by scanning both directions from the
# anchor:
#   - if the anchor line itself is an option row (the trust/Bypass case, where
#     the matched phrase IS an option), the block starts at the anchor;
#   - otherwise (the per-tool case, where the phrase is a header) the block
#     starts at the first option row within `adj` lines below the anchor.
# From there it walks downward through consecutive option rows, tolerating
# blank lines between them (the live trust capture has a blank line before its
# footer), stopping at the first non-blank non-option line. The block is then
# accepted iff it holds >=min_opts option rows AND <=1 marker rows. The
# outward walk is capped at `tail` lines so a pathological pane cannot make it
# walk far. `text` must already be pre-trimmed to the caller's own tail window
# (callers do this themselves, since the trim source - PANE_TEXT vs. a
# one-off capture - varies per caller).
_dialog_shape_in() {
  _ds_text="$1" _ds_phrase_re="$2" _ds_option_re="$3" _ds_mark_re="$4"
  _ds_min_opts="$5" _ds_tail="$6" _ds_adj="$7" _ds_lead_re="$8"
  _ds_hits="$(printf '%s\n' "$_ds_text" \
    | grep -nE "${_ds_lead_re}(${_ds_phrase_re})" | cut -d: -f1)"
  [ -n "$_ds_hits" ] || return 1
  _ds_total="$(printf '%s\n' "$_ds_text" | grep -c '')"
  for _ds_n in $_ds_hits; do
    # Locate the first option row of the block (its start line).
    if printf '%s\n' "$_ds_text" | sed -n "${_ds_n}p" | grep -qE "$_ds_option_re"; then
      _ds_start="$_ds_n"                       # anchor is itself an option row
    else
      _ds_start=""
      _ds_j="$((_ds_n+1))"; _ds_jmax="$((_ds_n+_ds_adj))"
      while [ "$_ds_j" -le "$_ds_jmax" ] && [ "$_ds_j" -le "$_ds_total" ]; do
        if printf '%s\n' "$_ds_text" | sed -n "${_ds_j}p" | grep -qE "$_ds_option_re"; then
          _ds_start="$_ds_j"; break
        fi
        _ds_j="$((_ds_j+1))"
      done
      [ -n "$_ds_start" ] || continue
    fi
    # Walk downward to the last contiguous option row (blank lines tolerated),
    # capped at `tail` lines from the block start.
    _ds_end="$_ds_start"
    _ds_k="$((_ds_start+1))"; _ds_kmax="$((_ds_start+_ds_tail))"
    while [ "$_ds_k" -le "$_ds_kmax" ] && [ "$_ds_k" -le "$_ds_total" ]; do
      _ds_line="$(printf '%s\n' "$_ds_text" | sed -n "${_ds_k}p")"
      if printf '%s\n' "$_ds_line" | grep -qE "$_ds_option_re"; then
        _ds_end="$_ds_k"
      elif printf '%s\n' "$_ds_line" | grep -qE '^[[:space:]]*$'; then
        :                                      # blank line: tolerate, do not extend
      else
        break                                  # first non-blank non-option ends it
      fi
      _ds_k="$((_ds_k+1))"
    done
    _ds_block="$(printf '%s\n' "$_ds_text" | sed -n "${_ds_start},${_ds_end}p")"
    _ds_opts="$(printf '%s\n' "$_ds_block" | grep -cE "$_ds_option_re")"
    _ds_marks="$(printf '%s\n' "$_ds_block" | grep -cE "$_ds_mark_re")"
    if [ "$_ds_opts" -ge "$_ds_min_opts" ] && [ "$_ds_marks" -le 1 ]; then
      DIALOG_SHAPE_BLOCK="$_ds_block"
      return 0
    fi
  done
  return 1
}

# True if the given text contains the question phrase - rendered as its own line
# per WM_PERM_LEAD_RE - anchoring a full contiguous option block of at least
# WM_PERM_MIN_OPTS rows bearing at most one selection marker: the one-block shape a
# real dialog renders, which transcript prose about prompts almost never
# reproduces. See _dialog_shape_in above for the walking algorithm this wraps.
prompt_shape_in() {
  _dialog_shape_in "$1" "$WM_PERM_PROMPT_RE" "$WM_PERM_OPTION_RE" "$WM_PERM_MARK_RE" \
    "$WM_PERM_MIN_OPTS" "$WM_PERM_TAIL" "$WM_PERM_ADJ" "$WM_PERM_LEAD_RE"
}

# Signature of the CLI's "resume from summary?" dialog (issue #30): shown by
# `claude --resume` once a transcript's last message is both old enough and
# token-heavy enough to trip an internal size/age gate. Deliberately its own,
# separate detector from WM_PERM_PROMPT_RE/prompt_shape_in above, never folded
# into it: that detector's freeze is answered by flipping the member to
# `blocked` for a human to decide, which is right for a genuine
# permission/trust gate but wrong here - there is nothing to decide, "resume
# full session" is always the correct, safe answer for an unattended agent
# (see bin/watch-fleet's resume_prompt_freeze_check, which auto-dismisses
# rather than blocking).
#
# Shares _dialog_shape_in's UI-shape/adjacency walk with prompt_shape_in
# above, rather than a bare co-occurrence-anywhere-in-the-tail check: an
# earlier version of this detector required only that both option-row
# strings appear somewhere within the tail, with no adjacency or shape
# requirement at all, and issue #30's PR review demonstrated that is
# trivially false-positived by a pane merely displaying (e.g. `cat`-ing) text
# that reproduces the pair - including this very file's own test fixture,
# once it existed in the repo. WM_RESUME_PROMPT_RE anchors the phrase (also
# option row 1's own label, so it doubles as an option row like the
# trust/Bypass case); WM_RESUME_ROW_RE is the generic numbered-row shape
# (marker glyph unconfirmed - see WM_RESUME_MARK_RE below - so it tolerates
# any single leading symbol, not just a specific one); WM_RESUME_TEXT_RE is
# an additional content check requiring the block to also contain option row
# 2's exact label, so a coincidental unrelated numbered list sitting near an
# unrelated "resume from summary" mention still cannot match - shape alone
# proves "a numbered list is here," not "this specific dialog is here."
#
# Accepted residual, same class already accepted for WM_PERM_PROMPT_RE (see
# its own docs/analysis findings): a pane displaying a *verbatim, adjacent*
# reproduction of the real dialog's three lines - not a paraphrase or a
# mid-sentence mention, which the shape/adjacency requirement above already
# rejects - still matches, because the pane-capture pipeline
# (`tmux capture-pane -p`, no `-e`) carries no styling/liveness signal that
# could tell a live-rendered menu apart from static text faithfully
# reproducing the same shape. This is more likely to occur for this
# detector than for the permission dialog, precisely because this issue's
# own plan/PR/tests legitimately quote the real text verbatim - it is not
# hypothetical (docs/plans/2026-07-15-issue-30-resume-hang-recovery-plan.md
# itself contains this exact three-line block). Mitigated, not eliminated:
# this repo's own test fixtures for this detector (tests/resume-prompt-detector.test.sh)
# deliberately never reproduce the three lines as literal adjacent text in
# the checked-in source (see that file's own comment).
WM_RESUME_PROMPT_RE="${WM_RESUME_PROMPT_RE:-Resume from summary \\(recommended\\)}"
WM_RESUME_ROW_RE="${WM_RESUME_ROW_RE:-^[[:space:]]*[^[:alnum:][:space:]]?[[:space:]]*[0-9]+\\.[[:space:]]}"
WM_RESUME_MARK_RE="${WM_RESUME_MARK_RE:-^[[:space:]]*[>❯][[:space:]]*[0-9]+\\.}"
WM_RESUME_TEXT_RE="${WM_RESUME_TEXT_RE:-Resume full session as-is}"
WM_RESUME_MIN_OPTS="${WM_RESUME_MIN_OPTS:-2}"
WM_RESUME_TAIL="${WM_RESUME_TAIL:-25}"
WM_RESUME_ADJ="${WM_RESUME_ADJ:-3}"
# Same "own line" requirement as WM_PERM_LEAD_RE, so a phrase embedded
# mid-sentence ("the test fixture echoes: Resume from summary...") never
# anchors a block the way a genuinely rendered dialog's own line does.
WM_RESUME_LEAD_RE="${WM_RESUME_LEAD_RE:-^[^[:alnum:]]*([0-9]+\\.[[:space:]])?}"

# True iff the resume-summary dialog's UI shape is present: WM_RESUME_PROMPT_RE
# anchoring a contiguous >=WM_RESUME_MIN_OPTS-row option block (via
# _dialog_shape_in, shared with prompt_shape_in) that also contains option row
# 2's exact text. See the WM_RESUME_PROMPT_RE comment above for the full
# rationale and accepted residual.
resume_prompt_shape_in() {
  _dialog_shape_in "$1" "$WM_RESUME_PROMPT_RE" "$WM_RESUME_ROW_RE" "$WM_RESUME_MARK_RE" \
    "$WM_RESUME_MIN_OPTS" "$WM_RESUME_TAIL" "$WM_RESUME_ADJ" "$WM_RESUME_LEAD_RE" || return 1
  printf '%s\n' "$DIALOG_SHAPE_BLOCK" | grep -qE "$WM_RESUME_TEXT_RE"
}

# Wait until a target pane's interactive TUI has finished starting and is ready to
# accept input, rather than guessing with a fixed delay. A freshly launched agent
# paints a splash/prompt and connects MCP servers before it will honour keystrokes;
# keys sent into that window land but a submit can be swallowed by the startup
# transition. Readiness is inferred harness-neutrally: the pane is non-empty and
# byte-stable across two consecutive reads (startup paints, then settles at an idle
# prompt). An already-idle session (the crew-say path) satisfies this on the first
# check. Best-effort and bounded (WM_READY_TRIES polls of WM_READY_POLL seconds), so
# a pane that never settles still proceeds rather than hanging (returns 0, same as
# an ordinary ready pane - there is nothing more specific to report).
#
# A pane that settles stable but dialog-shaped (prompt_shape_in matches its tail)
# is NOT ready for chat text - it is a permission/confirmation/trust prompt, and
# byte-stability alone cannot tell that apart from an idle chat prompt (a frozen
# dialog is just as stable as a parked one). Returns 2 in that case so the caller
# refuses to type into it rather than guessing.
wm_tmux_pane_ready() {
  _pr_target="$1"
  _pr_prev=""; _pr_i=0
  _pr_max="${WM_READY_TRIES:-40}"
  while [ "$_pr_i" -lt "$_pr_max" ]; do
    _pr_text="$(wm_tmux_pane_text "$_pr_target")"
    _pr_cur="$(printf '%s' "$_pr_text" | cksum)"
    if [ -n "$_pr_text" ] && [ "$_pr_cur" = "$_pr_prev" ]; then
      if prompt_shape_in "$(printf '%s\n' "$_pr_text" | tail -n "$WM_PERM_TAIL")"; then
        return 2
      fi
      return 0
    fi
    _pr_prev="$_pr_cur"
    sleep "${WM_READY_POLL:-0.5}"
    _pr_i=$((_pr_i+1))
  done
  return 0
}

# Deliver a message into a live interactive session: wait for the TUI to be ready,
# type the (possibly large) text, submit with Enter, then confirm the submit
# actually registered and re-press Enter if it did not.
#
# Two failure modes motivate the confirm-and-retry: an interactive TUI (e.g.
# Claude Code) ingests a rapid bulk burst as a bracketed paste - the "[Pasted text
# #N]" placeholder - and an Enter fired in the same burst is absorbed as a newline
# inside that paste instead of submitting; the WM_SUBMIT_DELAY settle between the
# text and the Enter lets the paste finalize first. And during a freshly spawned
# session's startup the Enter can be swallowed by the startup transition even
# after the text lands, leaving the message unexecuted in the input box (a fixed
# delay cannot cover a variable startup). Submitting always consumes the input box
# and advances the pane, so the confirm loop compares the pane against its
# just-composed state and re-presses Enter until it advances (bounded by
# WM_SUBMIT_TRIES). Extra Enters against an already-submitted, empty prompt are
# inert, so the retry is safe for the already-reliable crew-say path too.
#
# A third failure mode motivates the dialog check below: a target pane can be
# sitting on a permission/confirmation dialog rather than an idle chat prompt -
# byte-stable, so wm_tmux_pane_ready alone cannot tell it apart from "ready". Text
# typed there lands as noise in front of the dialog and Enter (plus every retry)
# is consumed as that dialog's own "accept" rather than a chat submit - the exact
# mechanism that let a "do not reboot" crew-say land as an accepted reboot
# confirmation instead of reaching the chat input. So this function never blindly
# sends a keystroke into a pane that looks dialog-shaped: it checks before typing
# (via wm_tmux_pane_ready's own return) and again before every Enter (the initial
# one and each retry, since a dialog can appear in the gap between typing and
# submitting), and refuses - sending nothing further - the instant one matches.
# Returns 0 on a confirmed (or best-effort, unconfirmed-but-not-refused) delivery,
# 2 if refused because the pane looks dialog-shaped rather than a chat input.
wm_tmux_send_message() {
  _target="$1"; _text="$2"
  wm_tmux_pane_ready "$_target"
  [ $? -eq 2 ] && return 2
  wm_tmux send-keys -t "$_target" -l "$_text"
  sleep "${WM_SUBMIT_DELAY:-1}"
  # Snapshot the pane with the text composed in the input box, then submit -
  # unless a dialog has appeared in the delay above, in which case refuse instead
  # of pressing Enter into it.
  _sm_composed_text="$(wm_tmux_pane_text "$_target")"
  if prompt_shape_in "$(printf '%s\n' "$_sm_composed_text" | tail -n "$WM_PERM_TAIL")"; then
    return 2
  fi
  _sm_composed="$(printf '%s' "$_sm_composed_text" | cksum)"
  wm_tmux send-keys -t "$_target" Enter
  _sm_i=0
  _sm_max="${WM_SUBMIT_TRIES:-6}"
  while [ "$_sm_i" -lt "$_sm_max" ]; do
    sleep "${WM_SUBMIT_POLL:-0.8}"
    _sm_now_text="$(wm_tmux_pane_text "$_target")"
    _sm_now="$(printf '%s' "$_sm_now_text" | cksum)"
    # A registered submit clears the composed input and echoes/streams below it, so
    # any change from the composed snapshot means the Enter took.
    [ "$_sm_now" != "$_sm_composed" ] && return 0
    if prompt_shape_in "$(printf '%s\n' "$_sm_now_text" | tail -n "$WM_PERM_TAIL")"; then
      return 2
    fi
    wm_tmux send-keys -t "$_target" Enter
    _sm_i=$((_sm_i+1))
  done
  return 0
}

# Auto-dismiss the resume-from-summary dialog (issue #30) by selecting
# "Resume full session as-is" - option 2 of 3, never option 3 ("Don't ask me
# again"), which persists resumeReturnDismissed: true into the shared
# ~/.claude.json and would silently change behavior for the pilot's own
# interactive sessions too. Option 2 has no persisted side effect and is
# correct on every occurrence.
#
# The keystroke sequence (round 2, PR #106 review) is sending the digit "2"
# followed by Enter - not an arrow-key sequence. This is not a live screen
# capture (still not obtained - see the plan's own residual note), but it is
# verified against the shipped CLI's actual key-handling logic, traced via
# `strings` against the installed binary the same way the plan's own
# Investigation section located the gating function: the dialog is rendered
# by the CLI's shared numbered-option-list component, which ships as TWO
# alternate implementations selected by a runtime capability check.
#   - The arrow-navigable variant's key handler (minified as `Nhs` in
#     2.1.210) calls `r.onChange?.(x.value)` the instant a digit 1-9 is
#     pressed (`if (t!=="numeric" && /^[0-9]$/.test(v)) { ... r.onChange
#     ?.(x.value); return }`) - selection is immediate, no Enter required.
#   - The plain numeric-entry variant (`Tpo`) has no arrow-key handling at
#     all; it accumulates typed digits and only submits them
#     (`Number.parseInt(...)`) on a `return`/Enter keypress.
# Sending "2" then Enter is therefore correct under EITHER implementation:
# the arrow variant selects on the digit alone (the trailing Enter lands on
# whatever replaces the dialog, which - like every other Enter this file
# sends into a chat pane - is inert against an idle/empty input); the numeric
# variant needs the Enter to submit. An arrow-key sequence (the originally
# shipped `Down`+`Enter`) is correct only under the first variant and is a
# silent no-op under the second (that handler has no case for a bare arrow
# key when no digits have been typed, so neither key does anything and the
# dialog is left exactly as frozen as before - not correctness-destroying,
# but ineffective). Confirm against a live captured dialog if one becomes
# available; this remains inference from source, not a screen capture.
wm_tmux_dismiss_resume_prompt() {
  _target="$1"
  wm_tmux send-keys -t "$_target" -l "2"
  sleep "${WM_SUBMIT_DELAY:-1}"
  wm_tmux send-keys -t "$_target" Enter
}

# Ensure the shared tmux server + crew session exist (detached). The check is
# exact-match, so a prefix sibling ("wingman-main", a user's "wingman-server")
# never satisfies it, and the create is scope-wrapped so a server forked here
# outlives a mortal caller cgroup (see wm_tmux_scoped). Verified after the
# create: crew must land in a session wingman genuinely owns, or fail loudly -
# never silently fall through to a prefix-matched neighbour.
wm_tmux_ensure_session() {
  wm_tmux has-session -t "$WM_TMUX_TARGET" 2>/dev/null && return 0
  wm_tmux_scoped new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
  wm_tmux has-session -t "$WM_TMUX_TARGET" 2>/dev/null \
    || wm_die "failed to create tmux session '$WM_TMUX_SESSION'"
}

# List live window names in the crew session, one per line.
wm_tmux_windows() {
  wm_tmux list-windows -t "$WM_TMUX_TARGET" -F '#{window_name}' 2>/dev/null
}

# Adopt stray crew windows: a roster member's window found in some OTHER tmux
# session is moved into the crew session, process intact. That is the
# transitional shape left behind by bare-name prefix matching (issue #39): a
# member spawned while no exact-named crew session existed landed in a
# prefix-matched neighbour (e.g. wingman's own session), and the moment the
# real crew session appears, name-scoped liveness stops seeing it - the live
# member would be reported died and then reaped, leaving an unsupervised
# agent process running in the wrong session. Every reconcile caller runs
# this first, so liveness never declares a member dead while its window
# exists elsewhere on the server. A window is matched by its recorded
# window_id when one matches (exact identity), else by exact window name;
# the move targets the id, which tmux resolves without any name matching.
wm_tmux_adopt_strays() {
  wm_tmux has-session -t "$WM_TMUX_TARGET" 2>/dev/null || return 0
  _as_roster="$WM_HOME/crew.json"
  [ -s "$_as_roster" ] || return 0
  # Fast path: this runs on every watcher poll, so the steady state (every
  # roster window home in the crew session, or belonging to a stood-down
  # record whose window was deliberately closed) must cost one grep and one
  # list-windows, not a python interpreter and an all-sessions listing. The
  # grep keys on the exact field format wm-state.py's json.dump writes; if it
  # yields nothing despite a non-empty roster (format drift), fall through to
  # the authoritative pass rather than silently skipping adoption.
  _as_wins="$(grep -o '"window": *"[^"]*"' "$_as_roster" 2>/dev/null \
              | sed 's/.*: *"//; s/"$//')"
  if [ -n "$_as_wins" ]; then
    _as_live="$(wm_tmux_windows)"
    _as_missing=0
    for _as_w in $_as_wins; do
      printf '%s\n' "$_as_live" | grep -qx "$_as_w" && continue
      # A stood-down member's window is gone by design (window name is wm-<id>).
      grep -q '"status": "stood-down"' "$WM_HOME/crew/${_as_w#wm-}.json" 2>/dev/null && continue
      _as_missing=1; break
    done
    [ "$_as_missing" = 1 ] || return 0
  fi
  _as_known="$(wm_py -c '
import json, os
path = os.path.join(os.environ.get("WINGMAN_HOME", ""), "crew.json")
try:
    with open(path) as f:
        roster = json.load(f)
except Exception:
    roster = []
for r in roster if isinstance(roster, list) else []:
    if r.get("status") == "stood-down":
        continue
    w = r.get("window") or ""
    if w:
        print("%s\t%s" % (w, r.get("window_id") or ""))
' 2>/dev/null)"
  [ -n "$_as_known" ] || return 0
  _as_tab="$(printf '\t')"
  _as_all="$(wm_tmux list-windows -a \
    -F "#{session_name}${_as_tab}#{window_name}${_as_tab}#{window_id}" 2>/dev/null)"
  [ -n "$_as_all" ] || return 0
  printf '%s\n' "$_as_known" | while IFS="$_as_tab" read -r _as_w _as_id; do
    [ -n "$_as_w" ] || continue
    _as_src="$(printf '%s\n' "$_as_all" | awk -F "$_as_tab" \
      -v s="$WM_TMUX_SESSION" -v w="$_as_w" -v i="$_as_id" '
        $2==w && $1==s {home=1}
        $2==w && $1!=s && i!="" && $3==i && !srci {srci=$3}
        $2==w && $1!=s && !srcn {srcn=$3}
        END {if (!home) {if (srci) print srci; else if (srcn) print srcn}}')"
    [ -n "$_as_src" ] || continue
    wm_tmux move-window -d -s "$_as_src" -t "$WM_TMUX_TARGET:" 2>/dev/null || true
  done
  return 0
}

# Comma-joined window list (for wm-state reconcile --windows).
wm_tmux_windows_csv() {
  wm_tmux_windows | tr '\n' ',' | sed 's/,$//'
}
