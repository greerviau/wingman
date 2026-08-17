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

# wm_launch_failure <component> <reason> - record why a launch refused to
# proceed, durably. bin/wingman's own stderr goes to a tmux pane that is
# destroyed moments later (its systemd unit is Type=oneshot/RemainAfterExit
# with ExecStart=`tmux new-session -d`, which returns before bin/wingman ever
# runs, so a wm_die message alone reaches nobody once the pane closes);
# bin/doctor surfaces this file on its next run instead. Overwrites, never
# appends - it answers exactly one question, "did the most recent launch
# attempt refuse, and why?" - and every internal failure path returns 0
# rather than let a diagnostic aid fail a launch of its own accord.
wm_launch_failure() {
  mkdir -p "$WM_HOME" 2>/dev/null || return 0
  { printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1"
    printf '%s\n' "$2"
  } > "$WM_HOME/last-launch-failure" 2>/dev/null || return 0
}

# --- the settings file ------------------------------------------------------
# config.local.toml: wingman's one configuration file - declarative, gitignored,
# templated by config.example.toml, read by bin/lib/wm_config.py. Overridable so
# tests point at a fixture instead of a developer's real file.
WM_CONFIG_TOML="${WM_CONFIG_TOML:-$WM_REPO/config.local.toml}"
export WM_CONFIG_TOML

# Apply the file's environment-backed settings to this process, so every bin/
# script picks them up: the typed settings (models/effort defaults, project
# discovery, harness knobs) plus the [env] table's raw WM_* passthrough, which is
# what reaches the tuning knobs the typed schema does not model.
# wm_config.py emits an `export` line only for a variable the environment does
# not already carry - which is what places the file BELOW an explicit
# `WM_MODEL=x bin/spawn-crew ...`.
#
# Skipped entirely when there is no file, so the common case costs no subprocess.
# A file that exists but cannot be parsed is announced rather than silently
# ignored: its own error goes to stderr from wm_config.py, and none of its
# settings take effect - a typo must never quietly drop a setting the pilot
# believes is in force.
if [ -f "$WM_CONFIG_TOML" ]; then
  if _wm_cfg_env="$($WM_UV "$WM_LIB/wm_config.py" env-exports)"; then
    eval "$_wm_cfg_env"
  else
    wm_warn "$WM_CONFIG_TOML is unusable (see the error above), so NONE of its settings are in effect - check it with 'bin/config --check'"
  fi
  unset _wm_cfg_env
fi

# The [models]/[effort] value the settings file names for one crew type, or
# empty when it names none (no file, no table, no matching key). A per-type
# entry is consulted BEFORE $WM_MODEL/$WM_EFFORT on purpose: the file's own
# `default` is exactly what those variables carry by the time this runs, so it
# is specificity that decides, not which layer a value came from.
# Usage: wm_config_for_type <models|effort> <category-qualified-crew-type>
wm_config_for_type() {
  [ -f "$WM_CONFIG_TOML" ] || return 0
  $WM_UV "$WM_LIB/wm_config.py" for-type --table "$1" --type "$2" 2>/dev/null || return 0
}

# Print each entry of a WM_ROOTS/WM_IGNORE-style list on its own line.
# Newline-separated when the value contains a newline - the shape the settings
# file's TOML arrays export, where an entry may legitimately contain spaces -
# else whitespace-separated, the shape these variables have always used when set
# straight in the environment (WM_ROOTS="$HOME/dev $HOME/code"), which stays
# supported.
_WM_NL=$'\n'
wm_split_list() {
  # The unquoted $1 in the second branch is deliberate: word-splitting IS the
  # whitespace shape's parse. The directive below must sit in front of the whole
  # `case` - attached to an individual branch it is rejected (SC1124) as a parse
  # error, which silently stops the linter analyzing the rest of this file.
  # shellcheck disable=SC2086
  case "$1" in
    *"$_WM_NL"*) printf '%s\n' "$1" ;;
    *) printf '%s\n' $1 ;;
  esac
}

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

# The claudeMdExcludes payload every crew launch, every printed resume
# command, and every unattended relaunch must carry so wingman's own root
# CLAUDE.md never loads for anyone but the orchestrator (issue #213). A pure
# function of $WM_REPO, so it needs no crew id or objective - one source of
# truth for bin/spawn-crew's generated launch script, bin/crew-takeover's
# printed --resume command, and bin/crew-resume's generated relaunch script
# alike (all three source this file already; bin/wingman's own launch is the
# one site that must NOT call this).
# Excludes the repo root's own memory/rules files, and the same set again
# under a $WM_REPO-* glob for a crew member's own worktree checkout (git
# worktree add copies CLAUDE.md verbatim into that sibling directory; the
# on-demand loader only reaches it when the sibling is itself a subdirectory
# of the session's primary cwd - true for a global-scope spawn, never true
# for a repo-scope one, whose primary cwd is $REPO exactly. See
# docs/plans/2026-07-30-mechanical-claude-md-crew-exclusion.md for the full
# grounding). claudeMdExcludes (confirmed in the shipped 2.1.220 settings
# schema, not only in docs) is the one version-stable, memory-file-only
# opt-out - unlike --bare/--safe-mode it never touches hooks, LSP, skills, or
# plugins, and unlike --setting-sources (which also works, but drops
# wingman's own project-level hooks AND every target repo's own legitimate
# CLAUDE.md) it touches only the files named here.
# Also excludes AGENTS.md (root and worktree-glob): CLAUDE.md is a symlink to
# it (issue #351), and while Claude Code doesn't discover AGENTS.md on its
# own today, excluding it now means a future Claude Code version that starts
# reading it natively can't silently reopen this same hazard.
wm_claude_md_excludes() {
  printf '{"claudeMdExcludes":["%s/CLAUDE.md","%s/CLAUDE.local.md","%s/.claude/CLAUDE.md","%s/.claude/rules/**","%s/AGENTS.md","%s-*/CLAUDE.md","%s-*/CLAUDE.local.md","%s-*/.claude/CLAUDE.md","%s-*/.claude/rules/**","%s-*/AGENTS.md"]}' \
    "$WM_REPO" "$WM_REPO" "$WM_REPO" "$WM_REPO" "$WM_REPO" "$WM_REPO" "$WM_REPO" "$WM_REPO" "$WM_REPO" "$WM_REPO"
}

# wm_compose_crew_sysprompt <out-file> <id> <type> <repo-or-workspace-root> \
#   <scope> <constraints-newline-separated> <target-is-wm-repo:0|1> \
#   <input-path-or-empty> <playbook-path> <include-pr-delivery:0|1> <agent-name>
#
# Writes the crew-facing assignment header + playbook + status contract that
# both a fresh spawn (bin/spawn-crew) and a relaunch (bin/crew-resume's
# relaunch mode, plan §4.8) deliver as this member's own persona/brief -
# extracted here (issue #25) so the two call sites can never drift apart on
# what "the crew brief" actually contains. A caller that wants relaunch-only
# content (the progress note) appends it to the same file afterward, rather
# than this function trying to grow a mode flag for it.
#
# <agent-name> is the RESOLVED descriptor name (e.g. "claude", "pi") - not read from
# $WM_AGENT_BIN, which a test's WM_AGENT_BIN_OVERRIDE can point at a stub
# binary while the resolved descriptor is still genuinely "claude". It is
# what lets the vocabulary block below render claude's own bare-filename
# form ("/status") instead of the "wingman-status" every other adapter
# actually needs, without this function re-deriving the resolved adapter
# itself. $WM_AGENT_SKILL_FORM is read as the ambient global
# wm_agent_resolve already set in the caller's own process (both call sites
# resolve the adapter before composing this brief) - not passed
# positionally, since only the ONE field this block needs is worth reading
# this way; every other WM_AGENT_* value stays out of this function's
# concern entirely.
wm_compose_crew_sysprompt() {
  _wcs_out="$1"; _wcs_id="$2"; _wcs_type="$3"; _wcs_repo="$4"; _wcs_scope="$5"
  _wcs_constraints="$6"; _wcs_target_is_wm_repo="$7"; _wcs_input="$8"
  _wcs_playbook="$9"; _wcs_include_pr_delivery="${10}"; _wcs_agent="${11}"
  {
    printf '# Your assignment\n\n'
    if [ "$_wcs_scope" = global ]; then
      printf 'Crew id: **%s**  |  Type: **%s**  |  Scope: **global project scope**\n\n' "$_wcs_id" "$_wcs_type"
      printf 'You are grounded at the workspace root `%s`, with every discovered repo available. ' "$_wcs_repo"
      printf 'This work is not tied to one repo: **determine the target repo(s) yourself** from the objective, and `cd` into a specific repo for any repo-local work (branches, commits, PRs). If it turns out the work belongs to a single repo, just operate there.\n\n'
    else
      printf 'Crew id: **%s**  |  Type: **%s**  |  Repo: `%s`\n\n' "$_wcs_id" "$_wcs_type" "$_wcs_repo"
    fi
    if [ -n "$_wcs_constraints" ]; then
      printf '**Standing constraints from the human, for this whole effort - do not relax any of these without a fresh, explicit instruction from the human (see CLAUDE.md, "A pilot constraint is not yours to relax"):**\n\n'
      while IFS= read -r _wcs_cline; do
        [ -n "$_wcs_cline" ] && printf -- '- %s\n' "$_wcs_cline"
      done <<<"$_wcs_constraints"
      printf '\n'
    fi
    if [ "$_wcs_target_is_wm_repo" -eq 1 ]; then
      printf '**About this repo'"'"'s CLAUDE.md/AGENTS.md:** the file `CLAUDE.md` at this repo'"'"'s root (also present as `AGENTS.md` - same content, kept in sync) - if either is anywhere in your context, whether your harness loaded it automatically or you opened it yourself - is written entirely in first person for the **wingman orchestrator** role - the top-level session the pilot starts directly, not this session. Nothing in it is a rule for you. You are a **%s** crew member: your role, permissions, and instructions are the playbook below and the objective above - follow those. Where CLAUDE.md/AGENTS.md says "you" (e.g. "you never edit playbooks yourself," "never do heavy work yourself"), it describes the orchestrator session'"'"'s own behavior, not a restriction on this one; treat CLAUDE.md/AGENTS.md only as optional background reading about how wingman is built, useful if it helps your actual task.\n\n' "$_wcs_type"
    fi
    if [ -n "$_wcs_input" ]; then
      printf 'Input handoff: read the plan/spec at `%s` and follow it.\n\n' "$_wcs_input"
    fi
    # The portable crew command vocabulary. Without this block a crew
    # member has no way to learn that seven skills describing $WINGMAN_BIN's
    # own scripts are loaded alongside it, or how its own CLI invokes one -
    # on the four non-claude adapters they would be reachable only by the
    # model spontaneously matching a skill's description. Rendered once,
    # adapter-agnostically, from $WM_AGENT_SKILL_FORM (set by
    # wm_agent_resolve in the caller's own process before this function
    # runs).
    if [ -n "${WM_AGENT_SKILL_FORM:-}" ]; then
      if [ "$_wcs_agent" = claude ]; then
        # claude's own command files keep their bare filenames (the
        # linchpin of the whole design: Claude Code ignores a command
        # file's `name` frontmatter and resolves by filename instead) -
        # "/status", not "/wingman-status" - even though the underlying
        # skill's own `name` frontmatter is wingman-status like everywhere
        # else.
        _wcs_skill_example="/status"
      else
        _wcs_skill_example="${WM_AGENT_SKILL_FORM/<skill>/wingman-status}"
      fi
      printf '**The crew command vocabulary.** Seven of wingman'"'"'s crew commands - `ask`, `blocked`, `prune`, `say`, `status`, `takeover`, `watch` - are also loaded as skills named `wingman-<verb>`, e.g. `%s` invokes the same body as running `$WINGMAN_BIN/crew-list` (the `status` command) directly. Deliberately absent: `spawn` and `standdown` are never exported as skills on any adapter, so do not go looking for a `wingman-spawn` or `wingman-standdown` skill here. Invoking a skill is never required - running `$WINGMAN_BIN/<script>` directly, as the playbook below already directs, remains the documented path everywhere, including for the two withheld verbs.\n\n' "$_wcs_skill_example"
    else
      printf '**The crew command vocabulary.** The same seven crew commands - `ask`, `blocked`, `prune`, `say`, `status`, `takeover`, `watch` - are loaded as skills named `wingman-<verb>`, reachable through your own CLI'"'"'s `skill` tool (this adapter has no typed slash form for them). Deliberately absent: `spawn` and `standdown` are never exported as skills on any adapter. Invoking a skill is never required - running `$WINGMAN_BIN/<script>` directly, as the playbook below already directs, remains the documented path everywhere, including for the two withheld verbs.\n\n'
    fi
    printf -- '---\n\n'
    cat "$_wcs_playbook"
    if [ "$_wcs_include_pr_delivery" -eq 1 ]; then
      printf '\n\n---\n\n'
      cat "$WM_PLAYBOOKS/_delivery.md"
    fi
    printf '\n\n---\n\n'
    cat "$WM_PLAYBOOKS/_status-contract.md"
  } > "$_wcs_out"
  unset _wcs_out _wcs_id _wcs_type _wcs_repo _wcs_scope _wcs_constraints \
    _wcs_target_is_wm_repo _wcs_input _wcs_playbook _wcs_include_pr_delivery \
    _wcs_agent _wcs_skill_example _wcs_cline
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
#   error     - the roster could not be read at all (state engine broken,
#               crew.json unreadable): the policy could not run. Callers must
#               refuse loudly on this - distinctly from `deny` - rather than
#               silently skipping the guardrail (fail closed, never open;
#               --force remains the human override). An empty verdict (the
#               python itself failing) is treated identically by callers.
# Shared by crew-say (one-way inject) and crew-ask (ask-and-capture) so both
# honour one policy. The caller id is "" for wingman (the top orchestrator, which
# has no roster record); a member passes its own $WINGMAN_CREW_ID.
wm_team_guardrail() {
  _tg_caller="$1"; _tg_target="$2"
  # The roster read's success is captured separately from its output: a failed
  # read must yield `error`, never be silently parsed as an empty roster
  # (which would resolve to `no-target` and let a broken install skip the
  # policy with no signal at all).
  _tg_roster="$(wm_state crew-list --all --json 2>/dev/null)" || { echo error; return; }
  printf '%s' "$_tg_roster" | wm_py -c '
import sys, json
caller, target = sys.argv[1], sys.argv[2]
try:
    roster = json.load(sys.stdin)
except Exception:
    print("error"); sys.exit(0)
if not isinstance(roster, list):
    print("error"); sys.exit(0)
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
# wm_mktemp_dir). Either match plus no configured stub override means nobody
# meant to launch anything real - a test that does mean to launch something
# always stubs it itself.
#
# Checks WM_AGENT_BIN_OVERRIDE (issue #25): since the adapter port, $WM_AGENT
# selects a DESCRIPTOR (claude/pi/codex/...), not a binary path directly, so
# its mere presence no longer reliably signals "a stub was configured" -
# claude is WM_AGENT's own built-in default and is exactly the real thing
# this guard exists to catch. WM_AGENT_BIN_OVERRIDE is the variable that
# actually redirects the exec target (bin/lib/agent.sh's wm_agent_resolve
# applies it to WM_AGENT_BIN), used by every launch point now that
# bin/spawn-crew and bin/crew-resume are both descriptor-driven (plan steps 3
# and 5) - its presence is the real "a test opted in" signal.
wm_guard_test_fixture_agent() {
  [ -n "${WM_AGENT_BIN_OVERRIDE:-}" ] && return 0
  case "$WM_TMUX_SESSION" in
    wm-test-*) wm_die "WM_TMUX_SESSION='$WM_TMUX_SESSION' looks like a test fixture and no stub is configured; refusing to launch a real '${1:-claude}'. Set WM_AGENT_BIN_OVERRIDE to a stub, or pass the real agent explicitly, before calling $(basename "$0")." ;;
  esac
  case "$WM_HOME" in
    "${TMPDIR:-/tmp}"/wm-test.*/*|"${TMPDIR:-/tmp}"/wm-test.*) wm_die "WINGMAN_HOME='$WM_HOME' looks like a test fixture and no stub is configured; refusing to launch a real '${1:-claude}'. Set WM_AGENT_BIN_OVERRIDE to a stub, or pass the real agent explicitly, before calling $(basename "$0")." ;;
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
#
# Optional $3 namespaces the hash file (pane-<id>-<ns>.hash) for a caller that
# must never contend with the shared per-id capture above - the whole-fleet
# outbox backstop (issue #169, piece 1): a nested member's own lead may be
# polling the SAME id's shared pane-<id>.hash at a different phase of its own
# interval, and two independent processes racing that one file would degrade
# not just outbox retry but prompt_freeze_check/the RC-drop check/the stall
# nudge for exactly the nested members the backstop exists to help.
wm_pane_snapshot() {
  _id="$1"; _win="$2"; _ns="${3:-}"
  PANE_TEXT="$(wm_tmux_pane_text "$(wm_tmux_win_target "$_win")")"
  _hashfile="$WM_HOME/pane-$(printf '%s' "$_id" | tr -c 'A-Za-z0-9._-' '_')${_ns:+-$_ns}.hash"
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

# Signature of the CLI's "resume from summary?" menu (issue #30): shown by
# `claude --resume` once a transcript's last message is both old enough and
# token-heavy enough to trip an internal size/age gate - exactly the shape a
# long-transcript session (a lead, worst case per issue #23's own comment) is
# most likely to hit on an auto-recovery resume. A distinct, separately-named
# regex from WM_PERM_PROMPT_RE (never folded permanently into that default)
# so the caller can tell which dialog actually froze the pane and choose
# different --blocker wording accordingly - see prompt_freeze_check below and
# bin/watch-fleet's use of it. Matches either of the menu's own option-row
# phrasings; prompt_shape_in's existing generic UI-shape detector (a phrase
# anchoring a numbered-options block) recognizes this exactly like the
# trust/Bypass acceptance rows, where the matched phrase IS itself an option
# row rather than a header above one.
WM_RESUME_PROMPT_RE="${WM_RESUME_PROMPT_RE:-[Rr]esuming from a summary|Resume from summary|Resume full session as-is}"

# True if the given text contains the question phrase - rendered as its own line
# per WM_PERM_LEAD_RE - anchoring a full contiguous option block of at least
# WM_PERM_MIN_OPTS rows bearing at most one selection marker: the one-block shape a
# real dialog renders, which transcript prose about prompts almost never
# reproduces. For each phrase hit the option block is found by scanning both
# directions from the anchor:
#   - if the anchor line itself is an option row (the trust/Bypass case, where the
#     matched phrase IS an option), the block starts at the anchor;
#   - otherwise (the per-tool case, where the phrase is a header) the block starts
#     at the first option row within WM_PERM_ADJ lines below the anchor.
# From there it walks downward through consecutive option rows, tolerating blank
# lines between them (the live trust capture has a blank line before its footer),
# stopping at the first non-blank non-option line. The block is then accepted iff
# it holds >=WM_PERM_MIN_OPTS option rows AND <=1 marker rows. The outward walk is
# capped at WM_PERM_TAIL lines so a pathological pane cannot make it walk far.
#
# Optional 2nd arg overrides the phrase alternation to scan for (defaults to
# $WM_PERM_PROMPT_RE, every existing caller's behavior unchanged) - used by
# bin/watch-fleet's prompt_freeze_check to also recognize WM_RESUME_PROMPT_RE
# in the same scan, so a session frozen on the resume-from-summary menu is
# caught by the identical, already-generic shape detector rather than a
# second bespoke one.
prompt_shape_in() {
  _ps_text="$1"
  _ps_phrase_re="${2:-$WM_PERM_PROMPT_RE}"
  _ps_hits="$(printf '%s\n' "$_ps_text" \
    | grep -nE "${WM_PERM_LEAD_RE}(${_ps_phrase_re})" | cut -d: -f1)"
  [ -n "$_ps_hits" ] || return 1
  _ps_total="$(printf '%s\n' "$_ps_text" | grep -c '')"
  for _ps_n in $_ps_hits; do
    # Locate the first option row of the block (its start line).
    if printf '%s\n' "$_ps_text" | sed -n "${_ps_n}p" | grep -qE "$WM_PERM_OPTION_RE"; then
      _ps_start="$_ps_n"                       # anchor is itself an option row
    else
      _ps_start=""
      _ps_j="$((_ps_n+1))"; _ps_jmax="$((_ps_n+WM_PERM_ADJ))"
      while [ "$_ps_j" -le "$_ps_jmax" ] && [ "$_ps_j" -le "$_ps_total" ]; do
        if printf '%s\n' "$_ps_text" | sed -n "${_ps_j}p" | grep -qE "$WM_PERM_OPTION_RE"; then
          _ps_start="$_ps_j"; break
        fi
        _ps_j="$((_ps_j+1))"
      done
      [ -n "$_ps_start" ] || continue
    fi
    # Walk downward to the last contiguous option row (blank lines tolerated),
    # capped at WM_PERM_TAIL lines from the block start.
    _ps_end="$_ps_start"
    _ps_k="$((_ps_start+1))"; _ps_kmax="$((_ps_start+WM_PERM_TAIL))"
    while [ "$_ps_k" -le "$_ps_kmax" ] && [ "$_ps_k" -le "$_ps_total" ]; do
      _ps_line="$(printf '%s\n' "$_ps_text" | sed -n "${_ps_k}p")"
      if printf '%s\n' "$_ps_line" | grep -qE "$WM_PERM_OPTION_RE"; then
        _ps_end="$_ps_k"
      elif printf '%s\n' "$_ps_line" | grep -qE '^[[:space:]]*$'; then
        :                                      # blank line: tolerate, do not extend
      else
        break                                  # first non-blank non-option ends it
      fi
      _ps_k="$((_ps_k+1))"
    done
    _ps_block="$(printf '%s\n' "$_ps_text" | sed -n "${_ps_start},${_ps_end}p")"
    _ps_opts="$(printf '%s\n' "$_ps_block" | grep -cE "$WM_PERM_OPTION_RE")"
    _ps_marks="$(printf '%s\n' "$_ps_block" | grep -cE "$WM_PERM_MARK_RE")"
    if [ "$_ps_opts" -ge "$WM_PERM_MIN_OPTS" ] && [ "$_ps_marks" -le 1 ]; then
      return 0
    fi
  done
  return 1
}

# Signature of the CLI's own chat composer, structurally rather than by
# string-matching whatever was typed into it (issue #188): a "rule" line is a
# LEADING RUN of at least WM_COMPOSER_RULE_MIN box-drawing horizontal
# characters (─, U+2500) - a leading-run anchor, not a whole-line one,
# because the top rule embeds a centered window label after its opening dash
# run and a whole-line "^─+$" pattern would never match it. Scanning the
# trailing WM_COMPOSER_TAIL lines of a capture, the composer region is
# whatever sits strictly between the LAST two such rule lines; everything at
# or after the bottom rule (a "/rc" line, the bypass-permissions status row,
# an attachment chip - all of which mutate on their own clock, independent
# of the composer) is excluded by construction, never read as "content".
# Verified against a live pane, both an empty composer (captured on a busy,
# mid-turn target - the state this detector's confirm loop actually reads,
# not merely an idle fresh session, which can render a dim placeholder hint
# that would otherwise be misread as pending) and a pending one (unsubmitted
# text sitting in another crew member's composer), Claude Code v2.1.220,
# 2026-08-02: a mid-turn empty composer - the only state this detector's
# confirm loop ever actually reads back as "empty" - renders exactly the
# anchor glyph "❯" (U+276F HEAVY RIGHT-POINTING ANGLE QUOTATION MARK
# ORNAMENT) followed by one NBSP (U+00A0) and nothing else, byte-exact
# e2 9d af c2 a0. There are no vertical border glyphs at all - the region is
# bounded top and bottom by horizontal rules only. This does NOT hold for an
# idle, nothing-yet-typed composer: v2.1.220 can render a contextual
# suggestion into it (e.g. "❯ Try 'edit <file>' to...", or a per-session hint
# observed live as "❯ keep going"/"❯ check on CI status"), which
# wm_composer_is_empty correctly classifies as pending, not empty - harmless
# here since a misread only pushes a delivery toward rc 3/5, never toward a
# false "confirmed" (see wm_composer_is_empty's own design-property note
# below), but real enough that "empty renders as the bare anchor" must not be
# read as an unconditional claim about every idle composer, only the
# post-submit one. wm_composer_is_empty's trailing-whitespace strip is
# deliberately restricted to the literal ASCII space byte rather than a
# POSIX class, specifically so it never strips this anchor's own NBSP under
# a locale that classifies U+00A0 as whitespace - see the comment on that
# function for the mechanism (issue #279).
WM_COMPOSER_RULE_MIN="${WM_COMPOSER_RULE_MIN:-20}"
WM_COMPOSER_TAIL="${WM_COMPOSER_TAIL:-15}"
WM_COMPOSER_RULE_CHAR="─"
WM_COMPOSER_ANCHOR="❯$(printf '\xc2\xa0')"
# Deliberately portable ERE (#52, see tests/detector-regex-portability.test.sh
# and bin/watch-fleet's own WM_APIERR_RE comment): a {n} interval is rejected
# outright by BSD grep -E in some combinations ("invalid repetition
# count(s)"), which makes grep -qE exit 2 (error, silently read as "no
# match" by every caller here) instead of 0/1 - silently disabling this
# whole detector on macOS. WM_COMPOSER_RULE_MIN copies of the rule character
# are spelled out literally below, followed by a plain `*` for "or more" -
# functionally identical to "${WM_COMPOSER_RULE_CHAR}{$WM_COMPOSER_RULE_MIN,}"
# but built from only literal concatenation and the portable `*` operator,
# computed once here rather than per-poll since the knob is fixed for the
# life of the process, like every other detector constant in this file.
WM_COMPOSER_RULE_RE="^"
_wm_ct_i=0
while [ "$_wm_ct_i" -lt "$WM_COMPOSER_RULE_MIN" ]; do
  WM_COMPOSER_RULE_RE="${WM_COMPOSER_RULE_RE}${WM_COMPOSER_RULE_CHAR}"
  _wm_ct_i=$((_wm_ct_i+1))
done
WM_COMPOSER_RULE_RE="${WM_COMPOSER_RULE_RE}${WM_COMPOSER_RULE_CHAR}*"
unset _wm_ct_i

# Extracts the composer region from a pane capture and prints it (which may
# itself be an empty string - not the same as "not recognized" below).
# Returns 0 when a rule pair is found in the trailing WM_COMPOSER_TAIL lines
# of the given text, 1 ("not recognized", nothing printed) when fewer than
# two rule lines are found there, OR when the two rule lines found are
# adjacent with no content line at all between them - left entirely to the
# caller, which reverts to the pre-#188 whole-pane-checksum behavior rather
# than treating "not recognized" as any kind of refusal.
#
# Two rule lines with no content line between them are "not recognized",
# never "recognized, empty": for an adapter whose real empty-composer
# anchor IS the empty string (WM_AGENT_COMPOSER_ANCHOR_EMPTY, pi), an empty
# extraction would byte-match that anchor and produce a false "confirmed"
# for a pane whose content was never inspected at all.
wm_composer_text_in() {
  _ct_tail="$(printf '%s\n' "$1" | tail -n "$WM_COMPOSER_TAIL")"
  _ct_idxs="$(printf '%s\n' "$_ct_tail" | grep -nE "$WM_COMPOSER_RULE_RE" | cut -d: -f1)"
  [ -n "$_ct_idxs" ] || return 1
  [ "$(printf '%s\n' "$_ct_idxs" | grep -c '')" -ge 2 ] || return 1
  _ct_bottom="$(printf '%s\n' "$_ct_idxs" | tail -n1)"
  _ct_top="$(printf '%s\n' "$_ct_idxs" | tail -n2 | head -n1)"
  _ct_start=$((_ct_top+1))
  _ct_end=$((_ct_bottom-1))
  [ "$_ct_start" -le "$_ct_end" ] || return 1
  printf '%s\n' "$_ct_tail" | sed -n "${_ct_start},${_ct_end}p"
  return 0
}

# True (rc 0) iff a wm_composer_text_in extraction is empty - reduces to the
# anchor glyph + NBSP alone, no other text. False (rc 1, "pending") for
# anything else. Strips only the literal ASCII space byte (0x20), NEVER a
# POSIX class like [[:space:]] - under a BSD libc UTF-8 locale, [[:space:]]
# classifies the anchor's own NBSP (U+00A0, c2 a0) as whitespace and strips
# it along with any trailing padding, which makes this equality permanently
# fail (issue #279). tmux capture-pane never emits a tab or other whitespace
# byte at a line's end, only literal spaces, so this is not a narrowing of
# real input, and matching a literal byte (rather than a named class) has no
# locale dependency to reintroduce. A misread here can only push a delivery
# toward "not yet confirmed", never toward a false 0 - consistent with this
# whole detector's design property (see _wm_tmux_send_message_locked below):
# every failure mode degrades toward a false negative, never a false
# "confirmed".
wm_composer_is_empty() {
  [ "$(printf '%s' "$1" | sed -e 's/ *$//')" = "$WM_COMPOSER_ANCHOR" ]
}

# wm_ps_lstart <pid>
# Prints <pid>'s process start time via `ps -o lstart=`, trimmed of the
# leading/trailing whitespace ps pads the field with. Pinned to
# TZ=UTC LC_ALL=C: unpinned, `ps -o lstart=` renders an absolute instant into
# the CALLING process's own local time, so a stamping process and a later
# comparing process running under different $TZ would render the very same
# live process's start time as two different strings and misread a live
# holder as dead/reused (issue #298 round-1 MF1, and the same defect
# independently in bin/watch-fleet's owner_lock_alive() - issue #303). Used
# by owner_lock_alive() so a new pid+lstart identity comparison never has to
# hand-copy the pin. It is the only remaining consumer: wm_tmux_send_lock's
# own liveness predicate was replaced by a kernel flock() (issue #302) and
# reads no process start time at all.
# An empty result means unknown (no such pid, or ps itself unavailable) -
# never treat it as a match against anything, including another empty
# string.
wm_ps_lstart() {
  TZ=UTC LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//'
}

# Acquire / release the per-pane send lock that serializes every keystroke aimed
# at one pane. Extracted verbatim from wm_tmux_send_message's own body (issue
# #236) so a caller that sends keystrokes WITHOUT going through the full
# type-and-submit path - today wm_tmux_clear_pending_composer below - takes the
# identical lock instead of racing it.
#
# Backed by a kernel flock() on a reserved file descriptor (issue #302),
# replacing the earlier mkdir+pid-stamp reclaim scheme (issue #298 / PR #301
# round-trip). The lock is released by the KERNEL the instant every fd
# referencing its open file description closes - including on an uncatchable
# SIGKILL of the holder - with no reliance on a contender's own polling or
# process-identity heuristics. That earlier scheme's whole liveness predicate
# (pid+lstart stamping, zombie-state detection, TZ/LC_ALL pinning, a
# pid-reuse comparison, a ps-availability fallback) is gone: there is no
# identity left to infer, because the kernel is the single source of truth
# for "is this still held."
#
# fd 200 is reserved for this lock alone across this entire codebase (grep
# confirms no other `exec N<>`/`exec N>` use anywhere in bin/ or tests/) -
# chosen for headroom under macOS's historical default soft RLIMIT_NOFILE of
# 256, where a higher number would risk "Bad file descriptor" under any
# tighter limit (a capped CI runner or container is not exotic even though it
# wouldn't show up on a permissive host).
#
# MUST be called directly in the caller's own shell process, never from a
# $( ) command substitution or an & subshell, in BOTH directions: the fd must
# outlive this single function call and remain open until
# wm_tmux_send_unlock runs, AND nothing spawned while the lock is held may
# itself outlive wm_tmux_send_unlock - every child forked while fd 200 is
# open inherits a reference to the same open file description (bash does not
# mark user-opened fds close-on-exec by default), so a long-lived child would
# keep the flock held with no reclaim path at all. The one concrete way this
# could happen in this codebase - a tmux server autostarting while the lock
# is held - was checked directly and is not reachable: only a
# `new-session`-class tmux command triggers a fresh server fork (verified
# against a scratch socket - `list-sessions` and `send-keys` both fail
# outright with no server running, never starting one), and every tmux call
# the locked bodies below actually make (`wm_tmux_pane_ready`, `send-keys`,
# `capture-pane`) is in that never-autostarts category. The codebase's one
# `new-session`-class call (wm_tmux_ensure_session, above) runs outside any
# locked body; a future call site that needs one from inside a lock must
# close fd 200 first (`200<&-`) - enforced by review, not a runtime guard.
#
# The lock file itself (send-<id>.flock) is created once and NEVER unlinked
# by any code path here. flock is per-inode: removing the file while a
# holder still has it open would let a contender that reopens the path
# create a fresh inode and acquire it immediately - two processes then both
# believe they hold the lock, and keystrokes from both interleave into one
# pane. This is a stricter requirement than the mkdir directory it replaces,
# which self-healed if deleted; a leftover .flock file is never safe to
# remove while wingman is running. A leftover pre-upgrade send-*.lock
# DIRECTORY, by contrast, is simply inert under this code (never opened,
# never checked) and remains harmless to remove or leave.
#
# Return codes, the complete set spanning both this function and
# wm_tmux_send_message (which propagates this function's rc verbatim
# whenever the lock itself fails): 0 = acquired/confirmed delivery.
# "Nothing was typed" family: 2 = dialog-shaped pane refusal, 4 = lock
# contended past WM_SEND_LOCK_WAIT (ordinary contention - expected to clear
# on its own), 6 = busy pane with pending composer, 7 = the flock helper
# itself failed for a reason OTHER than ordinary contention (a broken
# uv/python/fcntl in this environment, or the reserved fd could not even be
# opened - NOT expected to clear on its own; distinct from 4 on purpose so a
# caller never conflates a transient refusal with a broken toolchain),
# 8 = reentrant acquisition refused (this process already holds fd 200 for a
# different target - a programming error, since no call site is meant to
# ever nest two targets' locks). "Typed but submit unconfirmed" family
# (wm_tmux_send_message only, unaffected by this change): 3, 5.
wm_tmux_send_lock() {
  # Reentrant-acquisition guard, checked first: refuse immediately if fd 200
  # is already open in this process (a second target's lock, or a bug
  # re-entering this function) rather than silently reassigning fd 200 out
  # from under whatever the first acquire is still doing. No call site is
  # meant to ever do this, so a runtime refusal surfaces the bug loudly the
  # instant it happens instead of corrupting an unrelated lock silently.
  if { true >&200; } 2>/dev/null; then
    wm_err "send lock: fd 200 is already held in this process (attempted reentrant acquisition for pane '$1') - this is a bug, not contention; nothing was sent"
    return 8
  fi
  # The lock's parent must exist or opening the lockfile below fails and
  # reads as a helper failure; callers can legitimately run before wm_state
  # init.
  mkdir -p "$WM_HOME" 2>/dev/null
  _sl_lockfile="$WM_HOME/send-$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_').flock"
  _sl_wait="${WM_SEND_LOCK_WAIT:-45}"
  # A budget of 0 (or less) must never reach signal.alarm(): alarm(0) CANCELS
  # any pending alarm rather than firing immediately, so an unclamped 0 would
  # leave the blocking flock() call with no timeout at all - an unbounded
  # hang on the central send path, in place of the old code's immediate
  # rc-4 refusal at a 0 budget. No caller sets 0 today, but 0 is the natural
  # thing to write meaning "don't wait", so it is guarded here rather than
  # left as a latent hang.
  [ "$_sl_wait" -lt 1 ] 2>/dev/null && _sl_wait=1
  if ! exec 200<>"$_sl_lockfile"; then
    wm_err "send lock for pane '$1': could not open $_sl_lockfile - nothing was sent; this is NOT ordinary contention"
    return 7
  fi
  # A single blocking fcntl.flock() call under a SIGALRM-based timeout: no
  # bash-side sleep/retry loop, no ps forks, no polling granularity - the
  # kernel wakes this the instant the lock frees up, or the alarm cleanly
  # raises at the budget. A bare signal.alarm() with no handler installed
  # would NOT give a catchable timeout (the OS default action terminates the
  # interpreter, and PEP 475 additionally retries an interrupted syscall
  # unless the handler raises) - the explicit raising handler below is
  # required, not decorative.
  #
  # The timeout outcome is signalled by a MARKER STRING printed to stdout,
  # not by an exit code - deliberately, because $WM_UV is `uv run ...`, and
  # `uv` itself exits 2 on its OWN failures (a bad --python spec, an
  # unrecognized flag - verified directly), before python ever runs. An
  # earlier version of this helper used exit code 2 for the timeout and
  # anything-else for "the helper broke"; that made an uv-level failure
  # indistinguishable from ordinary contention, misreporting a permanently
  # broken toolchain as "retry shortly" - exactly the outcome rc 7 exists to
  # prevent. No exit code below is load-bearing: the marker is checked
  # first, unconditionally, and only its absence falls through to the
  # exit-code check for the (already unambiguous) success/failure split.
  _sl_helper_out="$(wm_py -c '
import fcntl, signal, sys

class _Timeout(Exception):
    pass

def _on_alarm(signum, frame):
    raise _Timeout()

try:
    fd, budget = int(sys.argv[1]), int(sys.argv[2])
    signal.signal(signal.SIGALRM, _on_alarm)
    signal.alarm(budget)
    fcntl.flock(fd, fcntl.LOCK_EX)
    signal.alarm(0)
    sys.exit(0)
except _Timeout:
    print("WM_SEND_LOCK_TIMEOUT")
    sys.exit(2)
except Exception as e:
    print("wm_tmux_send_lock helper error: %s" % e, file=sys.stderr)
    sys.exit(3)
' 200 "$_sl_wait" 2>&1)"
  _sl_hrc=$?
  case "$_sl_helper_out" in
    *WM_SEND_LOCK_TIMEOUT*)
      exec 200<&-
      wm_err "send lock for pane '$1' held by another delivery for ${_sl_wait}s+ - nothing was sent; retry shortly"
      return 4
      ;;
    *)
      if [ "$_sl_hrc" -eq 0 ]; then
        return 0
      fi
      exec 200<&-
      wm_err "send lock for pane '$1': the lock helper failed unexpectedly ($_sl_helper_out) - nothing was sent; this is NOT ordinary contention - check that 'uv' and python's fcntl module work in this environment"
      return 7
      ;;
  esac
}

wm_tmux_send_unlock() {
  exec 200<&-
  return 0
}

# Best-effort cleanup for a delivery that typed into a composer but could never
# confirm the submit (wm_tmux_send_message rc 3/5): if <target>'s composer
# region is recognized AND still holds unsubmitted text, clear it once so the
# stray text cannot later concatenate onto a human's next message. Holds the
# per-pane send lock for the duration, exactly as wm_tmux_send_message does, so
# this never interleaves with a concurrent crew-say/crew-ask delivery. Guarded
# three further ways so it can never fire a keystroke somewhere it does not
# belong: an unrecognized composer (a non-Claude-Code pane) is left alone, an
# already-empty one is left alone, and a dialog-shaped pane is refused outright
# by the same prompt_shape_in check every other keystroke in this file passes
# first. BEST-EFFORT, and named so deliberately: the clear is sent but never
# verified to have landed, so no caller may report the composer as clean.
# rc 0 if there was nothing to do or the clear was sent, 1 if the composer was
# not recognized, 2 if refused as dialog-shaped, 4 if the send lock could not
# be acquired (nothing sent - the next poll can try again). This collapses
# wm_tmux_send_lock's own 4/7/8 into a single 4 deliberately: this is a
# best-effort background cleanup, not a human-facing delivery, so which of
# "contended", "helper broke", or "reentrancy bug" occurred is not
# actionable for this caller - any of them means "couldn't get the lock this
# poll, try again next time" the same way.
wm_tmux_clear_pending_composer() {
  _cc_target="$1"
  wm_tmux_send_lock "$_cc_target" || return 4
  _cc_rc=0
  _cc_text="$(wm_tmux_pane_text "$_cc_target")"
  if prompt_shape_in "$(printf '%s\n' "$_cc_text" | tail -n "$WM_PERM_TAIL")"; then
    _cc_rc=2
  elif ! _cc_region="$(wm_composer_text_in "$_cc_text")"; then
    _cc_rc=1
  elif ! wm_composer_is_empty "$_cc_region"; then
    _cc_keys="${WM_CLEAR_KEYS-C-c}"
    # shellcheck disable=SC2086
    [ -n "$_cc_keys" ] && wm_tmux send-keys -t "$_cc_target" $_cc_keys
  fi
  wm_tmux_send_unlock "$_cc_target"
  return "$_cc_rc"
}

# Wait until a target pane's interactive TUI has finished starting and is ready to
# accept input, rather than guessing with a fixed delay. A freshly launched agent
# paints a splash/prompt and connects MCP servers before it will honour keystrokes;
# keys sent into that window land but a submit can be swallowed by the startup
# transition. Readiness is inferred harness-neutrally: the pane must hold
# byte-identical for WM_READY_QUIET seconds (startup paints, then settles at an
# idle prompt) - a duration, not a fixed capture count, so lowering WM_READY_POLL
# cannot silently shrink the guarantee (issue #214). An already-idle session (the
# crew-say path) satisfies this well within the bound. Bounded by WM_READY_TRIES
# polls of WM_READY_POLL seconds each.
#
# A pane that settles stable but dialog-shaped (prompt_shape_in matches its tail)
# is NOT ready for chat text - it is a permission/confirmation/trust prompt, and
# byte-stability alone cannot tell that apart from an idle chat prompt (a frozen
# dialog is just as stable as a parked one). Returns 2 in that case so the caller
# refuses to type into it rather than guessing.
#
# A pane that never settles within the budget is NOT ready either - it is not an
# ambiguous signal to be waved through, it is the strongest available evidence
# that the target's own turn is actively running (issue #214). Returns 6 in that
# case rather than falling open to 0; the caller treats 6 as busy, not as ready.
#
# Returns: 0 ready and idle, 2 dialog-shaped, 6 never settled (busy).

# Seconds of byte-identical pane required before a pane counts as idle. THE
# LOAD-BEARING INVARIANT of issue #214's fix: a Claude Code turn never leaves
# its pane byte-identical this long. Measured on 2.1.220 - a turn-active pane's
# longest quiet window is ~0.5s (100 samples at 0.5s, longest identical run 2);
# an idle pane, with or without background work, holds still indefinitely
# (100/100 and 40/40 identical). 1.5s is 3x that margin. Re-measure before
# lowering it; see issue #214.
WM_READY_QUIET="${WM_READY_QUIET:-1.5}"

wm_tmux_pane_ready() {
  _pr_target="$1"
  _pr_prev=""; _pr_i=0; _pr_run=0
  _pr_max="${WM_READY_TRIES:-40}"
  _pr_poll="${WM_READY_POLL:-0.5}"
  # Captures needed to span WM_READY_QUIET: n-1 gaps of _pr_poll each, so
  # n = 1 + ceil(quiet/poll), floored at 2. A zero poll interval (stub-driven
  # tests) cannot express a duration at all, so it falls back to 4 captures.
  _pr_need="$(awk -v q="$WM_READY_QUIET" -v p="$_pr_poll" 'BEGIN{
    if (p+0 <= 0) { print 4; exit }
    n = q/p; m = int(n); if (m < n) m++; m++; if (m < 2) m = 2; print m }')"
  while [ "$_pr_i" -lt "$_pr_max" ]; do
    _pr_text="$(wm_tmux_pane_text "$_pr_target")"
    _pr_cur="$(printf '%s' "$_pr_text" | cksum)"
    if [ -z "$_pr_text" ]; then
      _pr_run=0
    elif [ "$_pr_cur" = "$_pr_prev" ]; then
      _pr_run=$((_pr_run+1))
    else
      _pr_run=1
    fi
    if [ "$_pr_run" -ge "$_pr_need" ]; then
      if prompt_shape_in "$(printf '%s\n' "$_pr_text" | tail -n "$WM_PERM_TAIL")"; then
        return 2
      fi
      return 0
    fi
    _pr_prev="$_pr_cur"
    sleep "$_pr_poll"
    _pr_i=$((_pr_i+1))
  done
  return 6
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
# See the full return-code list below for what this function actually returns;
# refusing rather than typing into a dialog-shaped pane is rc 2.
#
# A fourth failure mode motivates the defensive clear below: the target's chat
# input can already hold unsubmitted composed text (left over from a direct
# Remote Control interaction, or any other stray typing) when this function
# types into it - the input box only ever appends, so the new text would land
# after the old and submit as one garbled, concatenated message instead of
# replacing it. WM_CLEAR_KEYS (default C-c) is sent once, before typing,
# specifically to clear that box: verified against a live Claude Code pane, a
# single Ctrl-C clears the composer's current text without exiting (exiting
# needs a second Ctrl-C within a short grace window, which one press never
# reaches, and a lone Ctrl-C against an already-empty box is a harmless no-op).
# This runs only after the dialog check above has already cleared the pane as
# non-dialog-shaped, so it never fires a keystroke into a permission/trust
# prompt. Set WM_CLEAR_KEYS empty to skip this for a harness whose composer
# does not clear on Ctrl-C.
#
# A fifth failure mode - issue #188 - motivates the composer-region check
# below: on a BUSY target (a Claude Code pane mid-turn, repainting on its
# own clock - the elapsed-time line, streaming tokens, "N shell(s) still
# running") the whole pane changes on the very first poll after Enter
# regardless of whether the Enter itself registered, so the whole-pane
# checksum this loop otherwise relies on cannot tell a genuine delivery from
# a message still sitting, unsubmitted, in the composer. wm_composer_text_in
# (above) reads the composer's OWN region instead, classified structurally
# (empty vs. pending) rather than by matching $_text against it - a message
# long/multi-line enough to wrap or paste-placeholder past any literal
# match still confirms correctly. Engaging this composer-mode check is
# strictly additive: an unrecognized region, or one already empty on the
# just-composed snapshot, falls straight through to the whole-pane-checksum
# behavior below, unchanged, for the rest of this call. Once engaged, any
# poll that sees the whole pane change while the composer is still pending
# sets a sticky "busy" flag for the remainder of this call, so a busy pane
# is polled but never re-Entered again - repeated Enters into a pane whose
# Enter may already be queued behind the current turn risk stacking
# duplicate submits once the turn ends. The dialog check above still runs on
# every poll of the composer-mode loop exactly as it does in the fallback
# loop below, unaffected by the busy branch, and still takes priority (rc 2)
# over everything else here.
#
# Returns: 0 on a CONFIRMED delivery (the composer region went empty, or -
# when composer mode never engaged - the pane advanced past its composed
# snapshot), 2 if refused because the pane looks dialog-shaped, 3 if the
# submit could never be confirmed within WM_SUBMIT_TRIES and the pane was
# idle throughout (typed, Enter sent, but nothing ever visibly advanced -
# probably-not-delivered, previously indistinguishable from success), 5 if
# the submit could never be confirmed AND the pane was busy (repainting on
# its own clock) at some point during the confirm loop - probably queued
# behind the current turn rather than lost outright, 6 if refused because the
# target's own turn was running and its composer already held unsubmitted
# text (issue #214) - like rc 2 and rc 4, nothing was typed. rc 5 is only
# reachable once composer mode has engaged; the whole-pane-checksum fallback
# can still only ever return 0 or 3. Callers treating only "nonzero" as
# failure keep working; callers that care can tell an idle-genuine-swallow
# (3) apart from a busy-likely-queued one (5).
#
# wm_tmux_send_message itself (the wrapper below, not the _locked body these
# rcs describe) can also surface 4, 7, or 8 - wm_tmux_send_lock's own rcs,
# propagated verbatim when the lock itself could not be acquired at all
# (see that function's doc comment above for what each means). Every rc this
# whole call chain can produce falls into exactly one of two families:
# "nothing was typed" (2, 4, 6, 7, 8) or "typed but submit unconfirmed"
# (3, 5) - never both.
#
# Concurrency: the whole type-and-submit sequence holds a kernel flock()
# (issue #302) on a per-pane lock file (send-<target>.flock under
# $WM_HOME, fd 200 - see wm_tmux_send_lock's own doc comment for the full
# design). Multiple writers genuinely target one pane at once - crew-say
# from wingman, a sibling's crew-say, a crew-ask send, watch-fleet's stall
# nudge and /remote-control retry - and unserialized send-keys bursts can
# interleave into one garbled submission, or let one sender's
# pane-advanced confirm read another sender's typing as its own success.
# The lock is held for the duration of one delivery (seconds); a waiter
# blocks (no polling) for up to WM_SEND_LOCK_WAIT seconds before giving up
# with rc 4. Release is kernel-guaranteed: the flock frees the instant
# every fd on it closes, including on an uncatchable SIGKILL of the
# holder - there is no separate reclaim path to describe, because there is
# nothing left that can go stale.

# wm_crew_agent_name <id>
#
# The target crew member's own recorded WM_AGENT descriptor name (crew.json's
# `agent` field, issue #25 §5 step 4), defaulting to "claude" when absent or
# unreadable - the same default wm-state.py's crew-add and bin/crew-resume
# already use for an unset field. Every wm_tmux_send_message call aimed at a
# specific crew member's pane must supply that call's own $3 with this, or
# every pane silently falls back to claude's own ambient composer rule/anchor
# regardless of which adapter is actually resolved for that member (issue #25
# stage 4 review finding, PR #348 MF1): a non-claude pane's composer can
# byte-match claude's WM_COMPOSER_RULE_RE by coincidence (pi's rule character
# is identical) while never matching its WM_COMPOSER_ANCHOR, so
# wm_composer_is_empty never reports empty and every delivery is treated as
# unconfirmed and endlessly re-sent.
wm_crew_agent_name() {
  _wcan_agent="$(wm_state crew-get --id "$1" 2>/dev/null | wm_py -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(d.get("agent") or "")' 2>/dev/null)"
  printf '%s' "${_wcan_agent:-claude}"
  unset _wcan_agent
}

wm_tmux_send_message() {
  wm_tmux_send_lock "$1" || return $?
  # $3 (issue #25, optional): a resolved agent NAME (not a crew id - the
  # caller's own job to resolve, since it usually already has it cheaply,
  # e.g. bin/watch-fleet's own per-member loop), used to temporarily swap
  # WM_COMPOSER_RULE_RE/WM_COMPOSER_ANCHOR/WM_COMPOSER_TAIL/WM_CLEAR_KEYS to
  # THIS member's own descriptor values for the duration of this one send,
  # restored unconditionally afterward. Every non-test caller now passes it
  # (wm_crew_agent_name, PR #348): spawn-crew, crew-say, crew-ask,
  # crew-resume, crew-standdown, watch-fleet, and wm_outbox_try_redeliver
  # all resolve the target's own recorded adapter and supply this rather
  # than silently classifying every pane against claude's own ambient
  # values regardless of which adapter is actually running there - see
  # pi.sh's own WM_AGENT_COMPOSER_ANCHOR_EMPTY for the first adapter this
  # now genuinely changes behavior for. Every composer-mode call site
  # inside _wm_tmux_send_message_locked below inherits the swap for free
  # (they already read these globals directly, never a parameter of their
  # own).
  _wtsm_saved_rule_re="$WM_COMPOSER_RULE_RE"
  _wtsm_saved_anchor="$WM_COMPOSER_ANCHOR"
  _wtsm_saved_tail="$WM_COMPOSER_TAIL"
  _wtsm_saved_clear="${WM_CLEAR_KEYS-C-c}"
  if [ -n "${3:-}" ] && [ "${3:-}" != claude ] && [ -f "$WM_LIB/agents/$3.sh" ]; then
    wm_agent_resolve "$3"
    # An adapter whose real, live-verified empty-composer signature IS the
    # literal empty string (pi, confirmed live - issue #25 stage 4, PR #348)
    # cannot express that through WM_AGENT_COMPOSER_ANCHOR alone: an empty
    # shell variable is indistinguishable from "field never populated,"
    # which is exactly the OTHER, far more common case this same emptiness
    # already has to mean (every adapter whose anchor is still genuinely "not
    # yet characterized"). WM_AGENT_COMPOSER_ANCHOR_EMPTY is the explicit,
    # affirmative escape hatch: set only once a live pane has actually
    # confirmed the emptied composer renders as nothing at all, never
    # inferred or guessed.
    if [ -n "$WM_AGENT_COMPOSER_RULE_RE" ] \
       && { [ -n "$WM_AGENT_COMPOSER_ANCHOR" ] || [ "$WM_AGENT_COMPOSER_ANCHOR_EMPTY" = 1 ]; }; then
      WM_COMPOSER_RULE_RE="$WM_AGENT_COMPOSER_RULE_RE"
      WM_COMPOSER_ANCHOR="$WM_AGENT_COMPOSER_ANCHOR"
    else
      # Not yet characterized for this adapter (plan §4.3's documented gap:
      # "composer-based confirm is skipped"). WM_COMPOSER_TAIL=0 makes
      # wm_composer_text_in's own `tail -n 0` scan zero lines, so it always
      # reports "not recognized" and every caller falls through to the
      # whole-pane-checksum confirm path below - never claude's own
      # rule/anchor pattern matched against a different CLI's pane, which
      # could false-positive/negative in an undefined way.
      WM_COMPOSER_TAIL=0
    fi
    WM_CLEAR_KEYS="$WM_AGENT_CLEAR_KEYS"
  fi
  _wm_tmux_send_message_locked "$1" "$2"
  _sm_lrc=$?
  WM_COMPOSER_RULE_RE="$_wtsm_saved_rule_re"
  WM_COMPOSER_ANCHOR="$_wtsm_saved_anchor"
  WM_COMPOSER_TAIL="$_wtsm_saved_tail"
  WM_CLEAR_KEYS="$_wtsm_saved_clear"
  wm_tmux_send_unlock "$1"
  return "$_sm_lrc"
}

_wm_tmux_send_message_locked() {
  _target="$1"; _text="$2"
  wm_tmux_pane_ready "$_target"
  _sm_ready=$?
  [ "$_sm_ready" -eq 2 ] && return 2
  _sm_clear_keys="${WM_CLEAR_KEYS-C-c}"
  if [ "$_sm_ready" -eq 6 ]; then
    # The target's own turn is running. The clear-keystroke would land as a
    # live interrupt of whatever tool call is in flight (issue #214), so it is
    # never sent here. The text and the Enter are safe: verified against a live
    # 2.1.220 pane with a foreground tool call in flight, they queue behind the
    # current turn and are answered when it ends, with no denial recorded.
    _sm_busy_text="$(wm_tmux_pane_text "$_target")"
    # The dialog check cannot be skipped just because the pane never settled -
    # an animated or repainting dialog would otherwise be typed into, which is
    # the exact failure the rc-2 refusal exists to prevent.
    if prompt_shape_in "$(printf '%s\n' "$_sm_busy_text" | tail -n "$WM_PERM_TAIL")"; then
      return 2
    fi
    # A composer that already holds text cannot be cleared (that needs the
    # keystroke we just ruled out) and must not be typed into (the two messages
    # would concatenate into one garbled submit - issue #157). Refuse; the
    # caller queues and the watcher retries.
    if _sm_busy_region="$(wm_composer_text_in "$_sm_busy_text")" \
       && ! wm_composer_is_empty "$_sm_busy_region"; then
      return 6
    fi
    _sm_clear_keys=""
  elif [ -n "$_sm_clear_keys" ]; then
    # Idle: send the clear-keystroke only if there may be something to clear.
    # A recognized-and-empty composer has nothing to clear, so the keystroke is
    # pure downside - it is the one keystroke that can abort a turn if this
    # pane was mis-read as idle.
    _sm_idle_text="$(wm_tmux_pane_text "$_target")"
    if _sm_idle_region="$(wm_composer_text_in "$_sm_idle_text")" \
       && wm_composer_is_empty "$_sm_idle_region"; then
      _sm_clear_keys=""
    fi
  fi
  if [ -n "$_sm_clear_keys" ]; then
    wm_tmux send-keys -t "$_target" $_sm_clear_keys
    sleep "${WM_CLEAR_DELAY:-0.3}"
  fi
  wm_tmux send-keys -t "$_target" -l "$_text"
  sleep "${WM_SUBMIT_DELAY:-1}"
  # Snapshot the pane with the text composed in the input box, then submit -
  # unless a dialog has appeared in the delay above, in which case refuse instead
  # of pressing Enter into it.
  _sm_composed_text="$(wm_tmux_pane_text "$_target")"
  if prompt_shape_in "$(printf '%s\n' "$_sm_composed_text" | tail -n "$WM_PERM_TAIL")"; then
    return 2
  fi
  # Composer mode (issue #188) engages iff the composer's own region is
  # recognized AND still pending on this just-composed snapshot - never a
  # stricter gate than the whole-pane-checksum fallback below: "not
  # recognized" or "recognized but already empty" (a race/anomaly) both fall
  # straight through to that fallback, unchanged, for the rest of this call.
  _sm_composer_mode=0
  if _sm_region="$(wm_composer_text_in "$_sm_composed_text")" && ! wm_composer_is_empty "$_sm_region"; then
    _sm_composer_mode=1
  fi
  _sm_composed="$(printf '%s' "$_sm_composed_text" | cksum)"
  wm_tmux send-keys -t "$_target" Enter
  _sm_i=0
  _sm_max="${WM_SUBMIT_TRIES:-6}"

  if [ "$_sm_composer_mode" -eq 1 ]; then
    # Confirm on the composer going empty, never on a whole-pane byte change.
    # _sm_busy is sticky for the rest of this loop once tripped by a whole-
    # pane change seen while the composer is still pending, so a busy pane
    # is polled but never re-Entered again. The dialog check still runs
    # every poll and still takes priority (rc 2) over everything below it.
    _sm_busy=0
    _sm_prev_text="$_sm_composed_text"
    while [ "$_sm_i" -lt "$_sm_max" ]; do
      sleep "${WM_SUBMIT_POLL:-0.8}"
      _sm_now_text="$(wm_tmux_pane_text "$_target")"
      if prompt_shape_in "$(printf '%s\n' "$_sm_now_text" | tail -n "$WM_PERM_TAIL")"; then
        return 2
      fi
      if _sm_region="$(wm_composer_text_in "$_sm_now_text")" && wm_composer_is_empty "$_sm_region"; then
        return 0
      fi
      [ "$_sm_now_text" != "$_sm_prev_text" ] && _sm_busy=1
      _sm_prev_text="$_sm_now_text"
      [ "$_sm_busy" -eq 0 ] && wm_tmux send-keys -t "$_target" Enter
      _sm_i=$((_sm_i+1))
    done
    # Exhausted every confirm retry without the composer ever going empty.
    # _sm_busy=1 means the pane was actively repainting at some point while
    # still pending - most likely a queued Enter, not a lost one (rc 5).
    # _sm_busy=0 means the pane sat genuinely idle the whole time - the
    # original genuine-swallow meaning of rc 3, unchanged.
    [ "$_sm_busy" -eq 1 ] && return 5
    return 3
  fi

  # Fallback: today's exact whole-pane-checksum behavior, unchanged.
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
  # Exhausted every confirm retry without the pane ever advancing: the text
  # was typed and Enter pressed, but delivery cannot be confirmed. Distinct
  # from 0 so a caller never reports "delivered" for a submit that probably
  # never registered.
  return 3
}

# Ensure the shared tmux server + crew session exist (detached). The check is
# exact-match, so a prefix sibling ("wingman-main", a user's "wingman-server")
# never satisfies it, and the create is scope-wrapped so a server forked here
# outlives a mortal caller cgroup (see wm_tmux_scoped). Verified after the
# create: crew must land in a session wingman genuinely owns, or fail loudly -
# never silently fall through to a prefix-matched neighbour.
#
# The trailing `200<&-` is defensive, not required by any call site today
# (this function is never called from inside a wm_tmux_send_lock-held
# region): `new-session` is the one tmux command class that autostarts a
# fresh server, and a server autostarted while fd 200 happened to be open
# would inherit it, pinning the send lock's flock open for that server's
# entire lifetime with no reclaim path at all (see wm_tmux_send_lock's own
# doc comment). Closing fd 200 for just this one command is a no-op when it
# is not open (verified), so it costs nothing today and removes the
# possibility entirely if this function is ever called from a locked body
# in the future.
wm_tmux_ensure_session() {
  wm_tmux has-session -t "$WM_TMUX_TARGET" 2>/dev/null && return 0
  wm_tmux_scoped new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle 200<&-
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

# Comma-joined list of every live wm-* window name in the crew session AND
# any session whose name is prefixed by it - the #39/#44 stray shape
# (e.g. "wingman" vs "wingman-main") - not the whole tmux server. This is
# the reconcile DEATH-CHECK input #209's fix needs, deliberately narrower
# than a truly server-wide scan: cmd_reconcile (bin/lib/wm-state.py) also
# uses this same --windows set to drive issue #79's orphan-window adoption
# and the dead-owner re-adopt pass (both owner "" only), and a genuinely
# unscoped scan would fabricate roster records for any wm-* window
# anywhere on the machine - a different wingman home, a concurrent test
# file's fixture - not just the crew's own (see #209's plan, "Chosen
# approach", for the demonstrated cross-home hazard this avoids). A stray
# parked in a session that does NOT share the crew session's name prefix is
# not covered by this - see the plan's stated tradeoff before changing this
# scope.
wm_tmux_prefix_windows_csv() {
  _wpc_tab="$(printf '\t')"
  wm_tmux list-windows -a -F "#{session_name}${_wpc_tab}#{window_name}" 2>/dev/null \
    | awk -F "$_wpc_tab" -v s="$WM_TMUX_SESSION" 'index($1, s) == 1 { print $2 }' \
    | tr '\n' ',' | sed 's/,$//'
}

# True (0) if the tmux server can be talked to at all. tmux's server process
# exits once its last session closes, so "no server currently running" is the
# ordinary cold-start/all-crew-died state, not a fault - and depending on
# exactly why it's not running, `tmux list-sessions` (exit 1) reports it one
# of two ways: "no server running on <socket>" when the socket file exists
# but nothing is listening (an ordinary kill-server), or "error connecting to
# <socket> (No such file or directory)" when the socket file itself is
# absent (a fresh boot, a wiped /tmp - the "host reset" shape #209 names
# explicitly). Both must be treated as reachable-with-nothing-running, not
# unreachable - measured directly against tmux 3.6, a genuine environment
# fault (e.g. a permission-denied socket directory) produces a third,
# different message ("couldn't create directory ... (Permission denied)"),
# which is what still falls through to unreachable. Getting this right is
# what lets #209's fix treat "nothing is alive" as safely reconcilable
# (correctly flips every live-state record to died) while still skipping
# reconcile - as the old has-session guard did - on a genuine environment
# fault, so a transient tmux problem can never mass-flag a healthy fleet.
wm_tmux_reachable() {
  _wtr_out="$(wm_tmux list-sessions 2>&1)" && return 0
  case "$_wtr_out" in
    "no server running"*) return 0 ;;
    "error connecting to "*"No such file or directory"*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- outbox helpers (issue #169) ---------------------------------------------
# bin/crew-say, bin/crew-ask, and bin/spawn-crew each queue a message under
# outbox/<id>/ when a delivery cannot be confirmed. The helpers below service
# that queue for every member, live or terminal: a sender sidecar, two terminal
# predicates, a sweep that archives an abandoned message and notifies its
# sender, and the shared redelivery path. A message whose sender is itself
# notice-routing-terminal is archived and logged but never announced (issue
# #230): nobody involved could act on it.

# Recover the stable stem of an outbox/<id>/ entry across whatever claim-
# protocol prefix it currently carries (today, only the redelivery path's own
# "sent-" rename) - so a sidecar written under outbox-meta/<id>/ by base
# filename can still be found once the entry has claimed itself.
wm_outbox_basename() {
  _ob_bn="$(basename "$1")"
  case "$_ob_bn" in
    sent-*) printf '%s' "${_ob_bn#sent-}" ;;
    *) printf '%s' "$_ob_bn" ;;
  esac
}

# True (rc 0) iff $1 must go through a pointer file rather than being typed (or
# retyped) raw into a pane: an embedded newline, or longer than
# WM_SAY_INLINE_MAX chars. One definition shared by bin/crew-say's send path and
# the redelivery branch, so the two cannot drift (issue #169, M5).
wm_needs_pointer() {
  case "$1" in
    *$'\n'*) return 0 ;;
  esac
  [ "${#1}" -gt "${WM_SAY_INLINE_MAX:-500}" ]
}

# Two related predicates, deliberately not one (see the plan, "Two related
# predicates"). Both take a pre-fetched `crew-list --all --json` payload
# (never fetched here) so a caller testing many ids pays for exactly one
# roster read, however many ids it tests.
#
# Delivery-reachability: "can this member still be delivered to?" - true (rc
# 0, i.e. TERMINAL - cannot be delivered to) iff the record is missing, its
# status is stood-down/died, or its status is done with no currently-live
# window (a done member with a live pane is still exactly what the done-loop
# exists to service). $3/$4 are a comma-joined live-window-name snapshot and
# whether that snapshot should be trusted for the done-with-no-window clause
# (1 = yes; 0 = the poll's own wm_tmux_reachable read was ambiguous - MF-1 -
# so a pending done target's window judgment defers to the next poll rather
# than guessing; the stood-down/died/missing-record clauses need no window
# data and are unaffected). Defaults $4 to 1 for a caller with a trustworthy
# one-shot snapshot (crew-prune, crew-standdown) that never checked
# wm_tmux_reachable itself.
wm_outbox_delivery_terminal() {
  _dt_id="$1"; _dt_roster_json="$2"; _dt_windows_csv="$3"; _dt_windows_valid="${4:-1}"
  printf '%s' "$_dt_roster_json" | wm_py -c '
import json, sys
target = sys.argv[1]
windows = set(w for w in sys.argv[2].split(",") if w)
windows_valid = sys.argv[3] == "1"
try:
    roster = json.load(sys.stdin)
except Exception:
    roster = []
rec = None
for r in roster if isinstance(roster, list) else []:
    if r.get("id") == target:
        rec = r
        break
if rec is None:
    sys.exit(0)
status = rec.get("status")
if status in ("stood-down", "died"):
    sys.exit(0)
if status == "done":
    if not windows_valid:
        sys.exit(1)
    win = rec.get("window") or ""
    sys.exit(0 if win not in windows else 1)
sys.exit(1)
' "$_dt_id" "$_dt_windows_csv" "$_dt_windows_valid"
}

# Notice-routing: "will this member's own watcher ever surface a notice?" -
# true (rc 0, TERMINAL) iff the record is missing, or its status is
# stood-down, died, or done - no window qualifier at all, because a done
# member's own watcher arms nothing further regardless of whether its window
# happens to still be alive at the instant a notice-routing walk runs (and
# wingman reaps a done member to stood-down in the same turn it observes the
# done). Used only by wm_outbox_resolve_notice_owner's own parent-chain walk
# below, which inlines the identical check itself (avoiding one subprocess
# per hop); kept as its own callable predicate for direct testability and
# because it names a genuinely distinct question from delivery-reachability.
wm_outbox_notice_terminal() {
  _nt_id="$1"; _nt_roster_json="$2"
  printf '%s' "$_nt_roster_json" | wm_py -c '
import json, sys
target = sys.argv[1]
try:
    roster = json.load(sys.stdin)
except Exception:
    roster = []
for r in roster if isinstance(roster, list) else []:
    if r.get("id") == target:
        sys.exit(0 if r.get("status") in ("stood-down", "died", "done") else 1)
sys.exit(0)
' "$_nt_id"
}

# Resolve who should be told about <id>'s outbox being swept: walk the parent
# chain, skipping every notice-routing-terminal ancestor, floored at wingman
# ("") - the one process guaranteed to outlive a tmux-server loss. Guarded at
# 5 hops as a safety fallback against a corrupt/cyclic parent chain (the
# architecture's own depth cap makes a real chain far shorter). Prints the
# resolved owner id, or empty for wingman.
wm_outbox_resolve_notice_owner() {
  _rno_id="$1"; _rno_roster_json="$2"
  printf '%s' "$_rno_roster_json" | wm_py -c '
import json, sys
cid = sys.argv[1]
try:
    roster = json.load(sys.stdin)
except Exception:
    roster = []
by_id = dict((r.get("id"), r) for r in roster if isinstance(r, dict))
def terminal(i):
    rec = by_id.get(i)
    if rec is None:
        return True
    return rec.get("status") in ("stood-down", "died", "done")
guard = 0
while guard < 5:
    rec = by_id.get(cid)
    if rec is None:
        print("")
        sys.exit(0)
    parent = rec.get("parent") or ""
    if parent == "":
        print("")
        sys.exit(0)
    if terminal(parent):
        cid = parent
        guard += 1
        continue
    print(parent)
    sys.exit(0)
print("")
' "$_rno_id"
}

# Sweep every pending (non-sent-) message under outbox/<id>/ as abandoned.
# <id> is a member the caller has ALREADY determined is delivery-terminal (or,
# for crew-standdown's cascade, one that was just stood down); this function
# never re-tests <id> itself. <reason> is a short human-readable phrase for
# the notice/log line. <notify-mode> is "stdout" (crew-standdown/crew-prune:
# print the notice directly in the command's own output) or "wake" (the
# per-poll scan: route it into the resolved notice owner's own wake channel).
# <roster-json>/<windows-csv>/<windows-valid> are a pre-fetched snapshot (see
# the predicates above) used only for the SENDER's own delivery-reachability
# check below - never re-fetched here, so a caller iterating many ids pays for
# one roster read/tmux snapshot regardless of how many ids it sweeps.
#
# Runs unconditionally in every watcher, so more than one process can reach
# the same pending file in the same poll window: the move to
# outbox-abandoned/<id>/ IS the claim (mirroring exactly how the existing
# redelivery block resolves the analogous race for its own sent- rename) -
# only the process whose mv succeeds composes a notice or writes a log line;
# a losing process (source already gone) does nothing further for that file.
wm_outbox_sweep_abandoned() {
  _sw_id="$1"; _sw_reason="$2"; _sw_notify="$3"
  _sw_roster_json="$4"; _sw_windows_csv="$5"; _sw_windows_valid="${6:-1}"
  _sw_dir="$WM_HOME/outbox/$_sw_id"
  _sw_metadir="$WM_HOME/outbox-meta/$_sw_id"
  [ -d "$_sw_dir" ] || return 0
  for _sw_f in "$_sw_dir"/*; do
    [ -e "$_sw_f" ] || continue
    case "$(basename "$_sw_f")" in sent-*) continue ;; esac
    _sw_stem="$(wm_outbox_basename "$_sw_f")"
    _sw_sidecar="$_sw_metadir/$_sw_stem"

    # 1. sender lookup via the sidecar: content (possibly empty = wingman) if
    # the sidecar exists, else "no sidecar at all" (a pre-existing queued file
    # from before this fix, or an unattributable write).
    _sw_sender=""
    _sw_sender_known=0
    if [ -f "$_sw_sidecar" ]; then
      _sw_sender="$(cat "$_sw_sidecar" 2>/dev/null)"
      _sw_sender_known=1
    fi
    _sw_sender_label="unknown"
    [ "$_sw_sender_known" = 1 ] && _sw_sender_label="${_sw_sender:-wingman}"

    # 2/3. claim the file atomically - only the winning mv proceeds further.
    mkdir -p "$WM_HOME/outbox-abandoned/$_sw_id" 2>/dev/null
    _sw_claimed="$WM_HOME/outbox-abandoned/$_sw_id/$_sw_stem"
    mv "$_sw_f" "$_sw_claimed" 2>/dev/null || continue

    # 4. compose the notice: pointer, not payload, for anything crew-say's own
    # rule would also route to a file.
    _sw_queued_at="$(wm_py -c 'import datetime,os,sys;print(datetime.datetime.fromtimestamp(os.path.getmtime(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$_sw_claimed" 2>/dev/null)"
    _sw_body="$(cat "$_sw_claimed" 2>/dev/null)"
    if wm_needs_pointer "$_sw_body"; then
      _sw_content="(long/multi-line message - read $_sw_claimed)"
    else
      _sw_content="$_sw_body"
    fi
    _sw_notice="Abandoned outbox message for '$_sw_id' from $_sw_sender_label (queued ${_sw_queued_at:-at an unknown time}, swept because $_sw_reason): $_sw_content [durable copy: $_sw_claimed]"

    # 5. durable audit trail - always, winning process only.
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_sw_id" "$_sw_sender_label" "$_sw_reason" "$_sw_claimed" \
      >> "$WM_HOME/outbox-abandoned.log"

    # 6. notify: a known, non-empty, non-terminal sender is itself still
    # reachable and is always queued into its OWN outbox - never a direct
    # send (no PANE_STABLE gate here, no per-poll bound on
    # WM_SEND_LOCK_WAIT, and this scan is fleet-wide while every real send
    # site is owner-scoped - see the plan for the full reasoning). Wingman
    # (an empty, known sender), unknown (no sidecar), or a terminal sender
    # all route through <notify-mode> instead - wingman is not itself an
    # outbox this mechanism ever delivers into, only a routing floor for the
    # notice-routing walk below.
    _sw_sender_reachable=0
    if [ "$_sw_sender_known" = 1 ] && [ -n "$_sw_sender" ] \
       && ! wm_outbox_delivery_terminal "$_sw_sender" "$_sw_roster_json" "$_sw_windows_csv" "$_sw_windows_valid"; then
      _sw_sender_reachable=1
    fi

    if [ "$_sw_sender_reachable" = 1 ]; then
      mkdir -p "$WM_HOME/outbox/$_sw_sender" "$WM_HOME/outbox-meta/$_sw_sender" 2>/dev/null
      # The swept id/stem (never reused - each queued file is claimed at
      # most once, ever) make this unique even across separate calls to this
      # function in the same process within the same second, unlike a
      # per-call counter reset at every invocation - watch-fleet's own scan
      # calls this once per terminal id per poll, and crew-standdown/
      # crew-prune each call it once per cascaded/swept id too.
      _sw_outfile="$WM_HOME/outbox/$_sw_sender/$(date +%s)-$$-$(printf '%s-%s' "$_sw_id" "$_sw_stem" | tr -c 'A-Za-z0-9._-' '_').msg"
      printf '' > "$WM_HOME/outbox-meta/$_sw_sender/$(basename "$_sw_outfile")"
      printf '%s\n' "$_sw_notice" > "$_sw_outfile"
    else
      case "$_sw_notify" in
        stdout)
          printf '%s\n' "$_sw_notice"
          ;;
        wake)
          # Dead-to-dead residue never manufactures a wake (issue #230). The
          # recipient is terminal by this function's own contract, and a
          # KNOWN, non-empty sender that reached this branch is terminal too -
          # so nobody involved can act, and appending here would be enough on
          # its own to fire a full attention wake (bin/watch-fleet fires on a
          # non-empty $NOTICEFILE alone), framed as live actionable state. The
          # durable record above - the outbox-abandoned.log line and the
          # archived payload - is deliberately unconditional and is the whole
          # trail #169 guarantees; only the ANNOUNCEMENT is suppressed.
          # Wingman (a known, empty sender) and unknown (no sidecar) are
          # unaffected and still wake: neither is evidence that the party who
          # sent this is gone. notice-terminality is asserted explicitly
          # rather than inferred from "we reached this branch" - today
          # wm_outbox_delivery_terminal implies it for every case, but that is
          # an invariant of the two predicates' current bodies, not of their
          # contracts, and this decision must not silently ride on it.
          #
          # What makes suppressing safe is that the RECIPIENT is already
          # terminal here: `wake` has exactly one caller (bin/watch-fleet's
          # per-poll scan), whose own classifier only ever emits a
          # delivery-terminal id. A second `wake` caller passing a live
          # recipient would silently drop a notice someone could have acted
          # on - so anything adding one must re-establish that precondition.
          _sw_dead_to_dead=0
          if [ "$_sw_sender_known" = 1 ] && [ -n "$_sw_sender" ] \
             && wm_outbox_notice_terminal "$_sw_sender" "$_sw_roster_json"; then
            _sw_dead_to_dead=1
          fi
          if [ "$_sw_dead_to_dead" = 0 ]; then
            _sw_owner="$(wm_outbox_resolve_notice_owner "$_sw_id" "$_sw_roster_json")"
            if [ -n "$_sw_owner" ]; then
              _sw_key="$(printf '%s' "$_sw_owner" | tr -c 'A-Za-z0-9._-' '_')"
              _sw_noticefile="$WM_HOME/pending-notices-$_sw_key"
            else
              _sw_noticefile="$WM_HOME/pending-notices"
            fi
            printf '%s\n' "$_sw_notice" >> "$_sw_noticefile"
          fi
          ;;
      esac
    fi

    # 7. sidecar + rmdir cleanup - the payload itself already moved in step 3.
    rm -f "$_sw_sidecar"
  done
  rmdir "$_sw_dir" 2>/dev/null
  rmdir "$_sw_metadir" 2>/dev/null
  return 0
}

# Attempt to redeliver the oldest pending (non-sent-) message under
# outbox/<id>/ into a live pane. Extracted from bin/watch-fleet's own
# per-member loop (piece 1) so both that owner-scoped loop and the top-level
# whole-fleet backstop share one implementation; <pane-stable> is the
# caller's own already-captured PANE_STABLE value for this id this poll
# (never captured here), so a caller with the shared per-id hash file (the
# owner-scoped loop) and one with a namespaced capture (the backstop) both
# use this without contending over $WM_HOME/pane-<id>.hash.
#
# One line per attempt to $WM_HOME/outbox-retry.log (timestamp, id, outcome),
# EXCEPT the no-pending-file case, which is never logged - it fires every poll
# for every member regardless of whether anything is queued and would
# otherwise flood the log (issue #169, M1). empty-file is checked before the
# PANE_STABLE branch: it is the more specific diagnosis (a permanently wedged
# queue, independent of pane state), so it wins over pane-unstable when both
# apply.
wm_outbox_try_redeliver() {
  _tr_id="$1"; _tr_target="$2"; _tr_pane_stable="$3"; _tr_backend="${4:-tmux}"
  _tr_obdir="$WM_HOME/outbox/$_tr_id"
  [ -d "$_tr_obdir" ] || return 0
  _tr_obfile="$(ls "$_tr_obdir" 2>/dev/null | grep -v '^sent-' | sort | head -1)"
  [ -n "$_tr_obfile" ] || return 0
  _tr_obpath="$_tr_obdir/$_tr_obfile"
  _tr_obsent="$_tr_obdir/sent-$_tr_obfile"
  # Sender lookup via the sidecar (issue #194), mirroring the pattern
  # wm_outbox_sweep_abandoned already uses: $_tr_obfile still holds the
  # un-prefixed name at this point (before the pointer-path mv to sent-*
  # below), matching exactly what bin/crew-say writes. No sidecar, or an
  # empty one, both mean "wingman/unattributable" and are recorded as "".
  _tr_sidecar="$WM_HOME/outbox-meta/$_tr_id/$_tr_obfile"
  _tr_sender=""
  [ -f "$_tr_sidecar" ] && _tr_sender="$(cat "$_tr_sidecar" 2>/dev/null)"
  _tr_obmsg="$(cat "$_tr_obpath" 2>/dev/null)"
  if [ -z "$_tr_obmsg" ]; then
    printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_tr_id" empty-file >> "$WM_HOME/outbox-retry.log"
    return 0
  fi
  if [ "$_tr_pane_stable" != 1 ]; then
    printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_tr_id" pane-unstable >> "$WM_HOME/outbox-retry.log"
    return 0
  fi
  if wm_needs_pointer "$_tr_obmsg"; then
    # Rename BEFORE sending so the pointer names the path the file will
    # actually live at; a failed send renames it back into the queue for the
    # next poll.
    mv "$_tr_obpath" "$_tr_obsent" 2>/dev/null
    wm_backend_send_message "$_tr_backend" "$_tr_target" \
      "Queued message for you: read $_tr_obsent and act on it now - it is a direct message to you, not background material." \
      "$(wm_crew_agent_name "$_tr_id")"
    _tr_rc=$?
    [ "$_tr_rc" -ne 0 ] && mv "$_tr_obsent" "$_tr_obpath" 2>/dev/null
  else
    wm_backend_send_message "$_tr_backend" "$_tr_target" "$_tr_obmsg" "$(wm_crew_agent_name "$_tr_id")"
    _tr_rc=$?
    [ "$_tr_rc" -eq 0 ] && { mv "$_tr_obpath" "$_tr_obsent" 2>/dev/null || rm -f "$_tr_obpath"; }
  fi
  case "$_tr_rc" in
    0) _tr_outcome=sent ;;
    2) _tr_outcome=dialog-refused ;;
    3|5) _tr_outcome=unconfirmed ;;
    4) _tr_outcome=lock-contended ;;
    6) _tr_outcome=busy ;;
    7) _tr_outcome=lock-helper-failed ;;
    8) _tr_outcome=lock-reentrant-bug ;;
    *) _tr_outcome=unconfirmed ;;
  esac
  if [ "$_tr_outcome" = sent ]; then
    # Confirmed redelivery (issue #194) - same record-delivery call bin/crew-say
    # makes on its own confirmed-immediate-send path. Best-effort, never gates
    # the retry itself, which has already succeeded by this point.
    wm_state record-delivery --to "$_tr_id" --from "$_tr_sender" >/dev/null 2>&1
  fi
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_tr_id" "$_tr_outcome" >> "$WM_HOME/outbox-retry.log"
}

# Capture/hash one backend-owned endpoint. The watcher keeps this state shape
# backend-neutral while adapters own endpoint syntax and CLI details.
wm_backend_pane_snapshot() {
  local id=$1 backend=$2 target=$3 ns=${4:-}
  PANE_TEXT="$(wm_backend_capture "$backend" "$target" "${WM_APIERR_TAIL:-80}")"
  local hashfile hash previous
  hashfile="$WM_HOME/pane-$(printf '%s' "$id" | tr -c 'A-Za-z0-9._-' '_')${ns:+-$ns}.hash"
  hash="$(printf '%s' "$PANE_TEXT" | cksum)"
  previous="$(cat "$hashfile" 2>/dev/null)"
  printf '%s\n' "$hash" > "$hashfile"
  [ -n "$previous" ] && [ "$hash" = "$previous" ] && PANE_STABLE=1 || PANE_STABLE=0
}

# Runtime backend dispatcher. It is sourced after the tmux helpers so the
# default adapter can delegate without changing their byte-level behavior.
. "$WM_LIB/backend.sh"
