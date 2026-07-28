# pilot-prefs.sh - the single source of truth for wingman's required
# onboarding preferences: the ordered key list, a one-line human-readable
# prompt per key, and the expected value vocabulary per key. Sourced by
# hooks/pilot-preferences-guard.sh and hooks/pilot-preferences-nudge.sh so
# both enforce/name exactly the same set.
#
# Adding preference #N later means: one word in WM_PREF_KEYS, one case arm in
# each function below, one question in CLAUDE.md's "Confirm onboarding
# preferences" section, and one commented line in config.example.toml - never a
# change to the guard's or nudge's own logic, and never a change to wm-state.py
# or bin/lib/wm_config.py (both treat the pref store as a generic key/value
# cache and neither knows what a key means).
# bash-3.2-safe. Sourced, never executed.

WM_PREF_KEYS="remote artifact_linking verbosity direct_spawn_visibility pr_comments"

wm_pref_prompt() {
  case "$1" in
    remote)                  echo "Are you watching this session locally, or over Remote Control right now?" ;;
    artifact_linking)        echo "For markdown deliverables (plans/reports), also publish as a hosted Artifact link, or local file path only?" ;;
    verbosity)               echo "How much should I narrate my own reasoning/routing as I work - concise, or more detailed explanations?" ;;
    direct_spawn_visibility) echo "For work you spawn directly (not through a lead), see each round of a revise loop as it happens, or just the terminal outcome?" ;;
    pr_comments)             echo "May crew write to GitHub PRs (reviews, thread replies, provenance markers), or keep all inter-agent review feedback on wingman's own channel?" ;;
  esac
}

wm_pref_values() {
  case "$1" in
    remote)                  echo "true|false" ;;
    artifact_linking)        echo "artifact|local" ;;
    verbosity)               echo "concise|detailed" ;;
    direct_spawn_visibility) echo "each-round|summary-only" ;;
    pr_comments)             echo "on|off" ;;
  esac
}

# True iff <value> is one of the values <key>'s vocabulary allows. The
# vocabulary is a "|"-joined alternation, so both sides are wrapped in
# delimiters before the fixed-string match - "true" must not match inside
# "untrue", and an empty value must never match at all.
# Usage: wm_pref_value_ok <key> <value>
wm_pref_value_ok() {
  [ -n "$2" ] || return 1
  printf '%s' "|$(wm_pref_values "$1")|" | grep -qF "|$2|"
}

# Compute the still-missing required keys for one run, in one prefs-list call:
# sets WM_PREFS_MISSING_KEYS (space-separated key names, empty when fully
# answered), WM_PREFS_MISSING_LINES ("- <key> (<values>): <prompt>" lines), and
# WM_PREFS_ENGINE_OK (1/0).
#
# WM_PREFS_ENGINE_OK distinguishes "the pilot has answered nothing" from "the
# state engine cannot tell us anything": it is 0 when wm-state.py is missing or
# unreadable, or when prefs-list exits non-zero. Both used to be
# indistinguishable from a fully-unanswered run, which is what let a broken
# install put hooks/pilot-preferences-guard.sh into permanent deny with no
# runnable way out. The missing-key outputs stay populated with the full
# required set when the engine is unusable, so a caller that only wants the
# question list is unaffected.
#
# prefs-list is asked --with-source because the two layers it merges are not
# equally trustworthy. An answer the settings file supplied (config.local.toml)
# is unvalidated hand-edited text, so a value outside the key's own vocabulary
# counts as MISSING and is called out by name in the question line - a typo
# there must surface as a question, never silently propagate as though the pilot
# had chosen it. An answer cached during this run is left alone whatever it
# says: it came from an AskUserQuestion the pilot answered, whose "Other" option
# can legitimately produce free text, and treating that as missing would strand
# the guard in a deny loop no answer could ever clear.
# Usage: wm_prefs_missing <wm-state.py path> <run-id>
wm_prefs_missing() {
  _pm_state_py="$1"; _pm_run_id="$2"
  _pm_uv="${WM_UV:-uv run --no-project --quiet}"
  WM_PREFS_ENGINE_OK=1
  if [ -r "$_pm_state_py" ]; then
    if ! _pm_prefs="$($_pm_uv "$_pm_state_py" prefs-list --run-id "$_pm_run_id" --with-source 2>/dev/null)"; then
      WM_PREFS_ENGINE_OK=0
      _pm_prefs=""
    fi
  else
    WM_PREFS_ENGINE_OK=0
    _pm_prefs=""
  fi
  _pm_tab="$(printf '\t')"
  WM_PREFS_MISSING_KEYS=""
  WM_PREFS_MISSING_LINES=""
  for _pm_k in $WM_PREF_KEYS; do
    _pm_row="$(printf '%s\n' "$_pm_prefs" \
      | awk -F"$_pm_tab" -v k="$_pm_k" '$1==k {print $2 "\t" $3; exit}')"
    _pm_val="${_pm_row%%"$_pm_tab"*}"
    _pm_src="${_pm_row#*"$_pm_tab"}"
    _pm_why=""
    if [ -z "$_pm_row" ]; then
      _pm_why=""                                  # simply unanswered
    elif [ "$_pm_src" = "config.local.toml" ] && ! wm_pref_value_ok "$_pm_k" "$_pm_val"; then
      _pm_why=" [config.local.toml sets '$_pm_val', which is not one of these - answer it here, or fix the file]"
    else
      continue                                    # answered, and acceptably so
    fi
    WM_PREFS_MISSING_KEYS="${WM_PREFS_MISSING_KEYS:+$WM_PREFS_MISSING_KEYS }$_pm_k"
    WM_PREFS_MISSING_LINES="$WM_PREFS_MISSING_LINES- $_pm_k ($(wm_pref_values "$_pm_k")): $(wm_pref_prompt "$_pm_k")$_pm_why
"
  done
}
