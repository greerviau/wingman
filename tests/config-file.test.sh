#!/usr/bin/env bash
# E2E: wingman's settings file, config.local.toml (issue #184). Proves the whole
# chain a pilot actually exercises:
#
#   - with no file, nothing changes: every preference is unanswered and a spawn
#     carries no --model/--effort;
#   - [prefs] answers a preference permanently - pref-get/prefs-list see it, and
#     hooks/lib/pilot-prefs.sh (what the PreToolUse guard enforces) counts it
#     answered - while an answer cached during the run still wins on top;
#   - a [prefs] value outside its key's vocabulary counts as UNANSWERED and says
#     so by name, rather than silently propagating as the pilot's choice;
#   - [models]/[effort] reach a real spawn's launch script, most-specific-first:
#     the flag, then the per-type entry, then the file's default / the WM_*
#     environment;
#   - [projects] and [harness] land in the WM_* environment, with ~ expanded;
#   - the environment outranks the file, which is what keeps an explicit
#     `WM_MODEL=x bin/spawn-crew ...` and the whole test suite working;
#   - bin/config names the source of every resolved value, and --check (and
#     therefore bin/doctor) rejects a typo instead of ignoring it;
#   - a malformed file is announced and applies nothing, rather than half-applying.
#
# Uses a stub agent (WM_AGENT) and an isolated tmux session, so no real claude
# launches and the live fleet is untouched.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SPAWN="$TEST_REPO/bin/spawn-crew"
CONFIG="$TEST_REPO/bin/config"
DISCOVER="$TEST_REPO/bin/discover-projects"
WM_CONFIG_PY="$TEST_REPO/bin/lib/wm_config.py"
STATE_PY="$TEST_REPO/bin/lib/wm-state.py"

wm_cfg() { uv run --no-project --quiet "$WM_CONFIG_PY" "$@"; }

# The model/effort flags a spawn's generated launch script actually carries -
# the closest observable stand-in for "what the crew session was launched with".
launch_flag() { grep -o -- "--$2 '[^']*'" "$WINGMAN_HOME/crew/$1.launch.sh" 2>/dev/null | head -1; }

# The still-missing preference set exactly as hooks/pilot-preferences-guard.sh
# computes it, by sourcing the very file the guard sources. This is what makes
# the assertions below about "the guard stops gating" real rather than inferred.
missing_keys() {
  WM_UV="uv run --no-project --quiet" bash -c '
    . "'"$TEST_REPO"'/hooks/lib/pilot-prefs.sh"
    wm_prefs_missing "'"$STATE_PY"'" "$1"
    printf "%s" "$WM_PREFS_MISSING_KEYS"' _ "$1"
}
missing_lines() {
  WM_UV="uv run --no-project --quiet" bash -c '
    . "'"$TEST_REPO"'/hooks/lib/pilot-prefs.sh"
    wm_prefs_missing "'"$STATE_PY"'" "$1"
    printf "%s" "$WM_PREFS_MISSING_LINES"' _ "$1"
}

# Isolated workspace: a non-git root holding two git repos, plus a third whose
# name the ignore list will exclude.
WS="$(wm_mktemp_dir)/workspace"
mkdir -p "$WS/repoA" "$WS/repoB" "$WS/ignored-repo"
for r in repoA repoB ignored-repo; do
  git -C "$WS/$r" init -q
  git -C "$WS/$r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
done
cp "$TEST_REPO/tests/fixtures/stub-agent.sh" "$WS/stub.sh"
chmod +x "$WS/stub.sh"

export WM_AGENT="$WS/stub.sh" WM_SPAWN_DELAY=0 WM_SUBMIT_DELAY=0 WM_READY_TRIES=1 \
  WM_READY_POLL=0 WM_SUBMIT_POLL=0.2 WM_SUBMIT_TRIES=1
test_new_home           # also points WM_CONFIG_TOML at this test's own file
wm_trust_repo "$WS"
wm_trust_repo "$WS/repoA"
wm_trust_repo "$WS/repoB"

RUN=run-cfg

# --- baseline: no settings file ----------------------------------------------
wm_rm_config
assert_false "no settings file exists to begin with" "[ -f '$WM_CONFIG_TOML' ]"
assert_eq "with no file, every preference is unanswered" \
  "$(missing_keys "$RUN")" "remote artifact_linking verbosity direct_spawn_visibility pr_comments"
assert_eq "with no file, prefs-list is empty" \
  "$(wm_state prefs-list --run-id "$RUN")" ""
assert_true "with no file, bin/config --check is green" "'$CONFIG' --check"
assert_contains "with no file, bin/config says so" "$("$CONFIG" --check 2>&1)" "no settings file"

baseid="$("$SPAWN" --type software-analyst --repo "$WS/repoA" --objective "baseline" 2>/dev/null | tail -1)"
assert_true "baseline spawn succeeds" "[ -n '$baseid' ]"
assert_eq "with no file, a spawn carries no --model" "$(launch_flag "$baseid" model)" ""
assert_eq "with no file, a spawn carries no --effort" "$(launch_flag "$baseid" effort)" ""

# --- [prefs]: a file-provided answer is a real answer ------------------------
wm_write_config <<'EOF'
[prefs]
remote = true
artifact_linking = "artifact"
verbosity = "detailed"
EOF
assert_eq "[prefs] answers leave only the unset keys missing" \
  "$(missing_keys "$RUN")" "direct_spawn_visibility pr_comments"
assert_eq "pref-get reads a file-provided answer" \
  "$(wm_state pref-get --run-id "$RUN" --key verbosity)" "detailed"
assert_eq "a TOML boolean reads as the true/false vocabulary" \
  "$(wm_state pref-get --run-id "$RUN" --key remote)" "true"
assert_false "pref-get still fails for a key the file does not set" \
  "wm_state pref-get --run-id '$RUN' --key pr_comments"
assert_contains "prefs-list --with-source attributes it to the file" \
  "$(wm_state prefs-list --run-id "$RUN" --with-source)" "verbosity	detailed	config.local.toml"

# The file answers every run, not just this one - that is the whole point.
assert_eq "a different run id reads the same file-provided answers" \
  "$(wm_state pref-get --run-id some-other-run --key verbosity)" "detailed"

# --- the per-run store wins on top -------------------------------------------
wm_state pref-set --run-id "$RUN" --key verbosity --value concise
assert_eq "an answer cached during the run overrides the file" \
  "$(wm_state pref-get --run-id "$RUN" --key verbosity)" "concise"
assert_contains "prefs-list --with-source attributes that one to the run" \
  "$(wm_state prefs-list --run-id "$RUN" --with-source)" "verbosity	concise	run"
assert_eq "overriding one key leaves the file answering the others" \
  "$(wm_state pref-get --run-id "$RUN" --key artifact_linking)" "artifact"
assert_eq "a run override does not reach a different run" \
  "$(wm_state pref-get --run-id some-other-run --key verbosity)" "detailed"

# --- an out-of-vocabulary [prefs] value counts as unanswered -----------------
# Hand-edited text, so a typo must surface as a question rather than propagate
# as though the pilot had chosen it. A fresh run id, since $RUN now has a cached
# verbosity of its own that would mask the file's value entirely.
BADRUN=run-cfg-invalid
wm_write_config <<'EOF'
[prefs]
remote = true
verbosity = "verbose"
EOF
assert_contains "an invalid file value leaves that key missing" \
  " $(missing_keys "$BADRUN") " " verbosity "
assert_contains "the question line names the offending value" \
  "$(missing_lines "$BADRUN")" "config.local.toml sets 'verbose'"
assert_not_contains "a valid file value in the same file is still answered" \
  " $(missing_keys "$BADRUN") " " remote "
# ...but a run-cached value is never second-guessed: AskUserQuestion's "Other"
# can legitimately produce free text, and treating that as missing would strand
# the guard in a deny loop no answer could clear.
wm_state pref-set --run-id "$BADRUN" --key verbosity --value "something freeform"
assert_not_contains "a run-cached value outside the vocabulary is left alone" \
  " $(missing_keys "$BADRUN") " " verbosity "

# --- [models] / [effort] reach a real spawn ----------------------------------
wm_write_config <<'EOF'
[models]
default = "cfg-default-model"
developer = "cfg-developer-model"
"software-development/reviewer" = "cfg-reviewer-model"

[effort]
default = "high"
reviewer = "low"
EOF
unset WM_MODEL WM_EFFORT

did="$("$SPAWN" --type software-analyst --repo "$WS/repoA" --objective "default model" 2>/dev/null | tail -1)"
assert_eq "[models].default reaches a spawn with no per-type entry" \
  "$(launch_flag "$did" model)" "--model 'cfg-default-model'"
assert_eq "[effort].default reaches that spawn too" \
  "$(launch_flag "$did" effort)" "--effort 'high'"

bid="$("$SPAWN" --type developer --repo "$WS/repoA" --objective "per-type model" 2>/dev/null | tail -1)"
assert_eq "a bare per-type [models] key beats default" \
  "$(launch_flag "$bid" model)" "--model 'cfg-developer-model'"
assert_eq "that spawn still takes [effort].default, having no per-type entry" \
  "$(launch_flag "$bid" effort)" "--effort 'high'"

qid="$("$SPAWN" --type reviewer --repo "$WS/repoA" --objective "qualified model" 2>/dev/null | tail -1)"
assert_eq "a category-qualified [models] key resolves for a bare --type" \
  "$(launch_flag "$qid" model)" "--model 'cfg-reviewer-model'"
assert_eq "per-type [effort] resolves independently of [models]" \
  "$(launch_flag "$qid" effort)" "--effort 'low'"

# The same crew type asked for by its qualified name lands on the same entry.
q2id="$("$SPAWN" --type software-development/reviewer --repo "$WS/repoA" --objective "qualified --type" 2>/dev/null | tail -1)"
assert_eq "a qualified --type resolves the same per-type entry" \
  "$(launch_flag "$q2id" model)" "--model 'cfg-reviewer-model'"

# --- precedence --------------------------------------------------------------
fid="$("$SPAWN" --type developer --repo "$WS/repoA" --objective "explicit flag" --model flag-model --effort max 2>/dev/null | tail -1)"
assert_eq "an explicit --model beats a per-type entry" \
  "$(launch_flag "$fid" model)" "--model 'flag-model'"
assert_eq "an explicit --effort beats a per-type entry" \
  "$(launch_flag "$fid" effort)" "--effort 'max'"

eid="$(WM_MODEL=env-model "$SPAWN" --type software-analyst --repo "$WS/repoA" --objective "env beats default" 2>/dev/null | tail -1)"
assert_eq "\$WM_MODEL beats [models].default" \
  "$(launch_flag "$eid" model)" "--model 'env-model'"

# ...but NOT a per-type entry: specificity decides, not which layer a value came
# from. [models].default is exactly what $WM_MODEL carries once the settings
# layer has run, so a per-type entry has to outrank it to mean anything.
pid="$(WM_MODEL=env-model "$SPAWN" --type developer --repo "$WS/repoA" --objective "per-type beats env" 2>/dev/null | tail -1)"
assert_eq "a per-type [models] entry beats \$WM_MODEL" \
  "$(launch_flag "$pid" model)" "--model 'cfg-developer-model'"

# --- [projects] and [harness] land in the environment ------------------------
wm_write_config <<EOF
[projects]
roots = ["~/from-tilde", "$WS"]
ignore = ["ignored-repo"]

[projects.pins]
pinned-name = "$WS/repoB"

[harness]
agent = "$WS/stub.sh"
permission_mode = "acceptEdits"
remote_control = false
tmux_session = "cfg-session"
EOF
# A subshell, so the unsets scope to this one call: env-exports emits nothing for
# a variable the environment already carries, and this test's own harness exports
# most of them.
exports="$(unset WM_ROOTS WM_IGNORE WM_PINS WM_AGENT WM_PERMISSION_MODE \
                 WM_REMOTE_CONTROL WM_TMUX_SESSION; wm_cfg env-exports)"
assert_contains "[projects].roots expands ~" "$exports" "$HOME/from-tilde"
assert_contains "[projects].pins exports the name|path shape" "$exports" "pinned-name|$WS/repoB"
assert_contains "[harness].permission_mode exports" "$exports" "WM_PERMISSION_MODE=acceptEdits"
assert_contains "[harness].tmux_session exports" "$exports" "WM_TMUX_SESSION=cfg-session"
assert_contains "remote_control = false exports as empty, not '1'" "$exports" "WM_REMOTE_CONTROL=''"
assert_contains "env-exports records which variables it set" "$exports" "WM_CONFIG_APPLIED="

# An explicitly-empty WM_REMOTE_CONTROL in the environment means "disabled" and
# is a real answer, so the file must not overwrite it (membership, not truthiness).
empty_rc="$(WM_REMOTE_CONTROL= wm_cfg env-exports)"
assert_not_contains "an explicitly-empty WM_REMOTE_CONTROL is not overwritten" \
  "$empty_rc" "WM_REMOTE_CONTROL="

# Discovery through the file: the pinned name resolves, the ignored repo does not.
"$DISCOVER" --quiet >/dev/null 2>&1
assert_eq "a [projects.pins] entry resolves by name" \
  "$("$DISCOVER" pinned-name 2>/dev/null)" "$WS/repoB"
assert_true "a repo under a configured root is discovered" \
  "'$DISCOVER' repoA >/dev/null 2>&1"
assert_false "a name in [projects].ignore is not discovered" \
  "'$DISCOVER' ignored-repo >/dev/null 2>&1"

# A root whose path contains a space survives the TOML array, which the
# historical whitespace-separated WM_ROOTS could not carry.
SPACED="$(wm_mktemp_dir)/two words"
mkdir -p "$SPACED/spaced-repo"
git -C "$SPACED/spaced-repo" init -q
wm_write_config <<EOF
[projects]
roots = ["$SPACED"]
EOF
"$DISCOVER" --quiet >/dev/null 2>&1
assert_eq "a root path containing a space is scanned" \
  "$("$DISCOVER" spaced-repo 2>/dev/null)" "$SPACED/spaced-repo"

# --- bin/config: the resolved view names its sources ------------------------
wm_write_config <<'EOF'
[prefs]
remote = true

[models]
default = "shown-model"
developer = "shown-developer"
EOF
shown="$(WINGMAN_RUN_ID=$RUN "$CONFIG" 2>&1)"
assert_contains "bin/config attributes a file value to the file" "$shown" "models.default"
assert_contains "bin/config shows the file-provided model" "$shown" "shown-model"
assert_contains "bin/config lists a per-type entry" "$shown" "models.developer"
assert_contains "bin/config marks an unset setting as default" "$shown" "default"
assert_contains "bin/config shows an unanswered preference as unanswered" \
  "$shown" "unanswered"
envshown="$(WINGMAN_RUN_ID=$RUN WM_MODEL=from-the-env "$CONFIG" 2>&1)"
assert_contains "bin/config attributes an environment value to env" "$envshown" "from-the-env"
pathout="$("$CONFIG" --path)"
assert_eq "bin/config --path prints the settings file path" "$pathout" "$WM_CONFIG_TOML"

# --- bin/config --check rejects what would otherwise fail silently ----------
wm_write_config <<'EOF'
[prefs]
verbostiy = "detailed"
EOF
assert_false "an unknown [prefs] key fails --check" "'$CONFIG' --check"
assert_contains "the unknown preference is named" \
  "$("$CONFIG" --check 2>&1)" "unknown preference prefs.verbostiy"

wm_write_config <<'EOF'
[prefs]
pr_comments = "maybe"
EOF
assert_false "an out-of-vocabulary [prefs] value fails --check" "'$CONFIG' --check"
assert_contains "the accepted values are named" "$("$CONFIG" --check 2>&1)" "on|off"

wm_write_config <<'EOF'
[harness]
agnt = "claude"
EOF
assert_false "an unknown setting key fails --check" "'$CONFIG' --check"
assert_contains "the unknown setting is named" \
  "$("$CONFIG" --check 2>&1)" "unknown setting harness.agnt"

wm_write_config <<'EOF'
[nonsense]
x = 1
EOF
assert_false "an unknown table fails --check" "'$CONFIG' --check"
assert_contains "the unknown table is named" "$("$CONFIG" --check 2>&1)" "unknown table [nonsense]"

wm_write_config <<'EOF'
[models]
develper = "sonnet"
EOF
assert_false "a per-type key naming no crew type fails --check" "'$CONFIG' --check"
assert_contains "the bad crew type is named" \
  "$("$CONFIG" --check 2>&1)" "models.develper names no crew type"

wm_write_config <<'EOF'
[projects]
roots = "not-an-array"
EOF
assert_false "a wrong-typed setting fails --check" "'$CONFIG' --check"
assert_contains "the type error is named" \
  "$("$CONFIG" --check 2>&1)" "projects.roots must be an array of strings"

# --- a malformed file is announced, and applies nothing ---------------------
wm_write_config <<'EOF'
[models
default = "never-applied"
EOF
assert_false "malformed TOML fails --check" "'$CONFIG' --check"
assert_contains "the parse error names the file" "$("$CONFIG" --check 2>&1)" "not valid TOML"
unset WM_MODEL
mid="$("$SPAWN" --type software-analyst --repo "$WS/repoA" --objective "malformed config" 2>/dev/null | tail -1)"
assert_true "a spawn still succeeds with a malformed settings file" "[ -n '$mid' ]"
assert_eq "a malformed file applies no model" "$(launch_flag "$mid" model)" ""
assert_contains "sourcing common.sh warns about the malformed file" \
  "$(bash -c '. "'"$TEST_REPO"'/bin/lib/common.sh"' 2>&1)" "is unusable"
# The state engine must keep working, with those preferences simply unanswered -
# the conservative direction, so wingman asks rather than assuming.
assert_eq "a malformed file leaves preferences unanswered, not broken" \
  "$(wm_state pref-get --run-id fresh-run --key remote 2>/dev/null; echo "rc=$?")" "rc=1"
assert_eq "prefs-list still runs against a malformed file" \
  "$(wm_state prefs-list --run-id fresh-run; echo "rc=$?")" "rc=0"

test_summary
