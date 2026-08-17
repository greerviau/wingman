#!/usr/bin/env bash
# E2E: the portable command/skill vocabulary tree (crew command vocabulary
# plan, §4.1/§4.2/§9.1). Static file-structure checks only - no tmux, no
# isolated $WINGMAN_HOME needed.
#
# This file is the ONLY mechanical thing holding §9.1's fail-closed decision
# in place: `spawn` and `standdown` are deliberately withheld from
# `.agents/skills/` because no adapter-neutral mechanism can express "this
# skill must never be model-invoked" (opencode discards the only frontmatter
# field that would say so, and has no typed form to fall back on either).
# Without the absence assertions below, `.agents/skills/` having seven of
# eleven verbs looks like an oversight - `wingman-spawn` is the obvious-
# looking omission - and nothing would stop a future change from "fixing"
# it. See CLAUDE.md/AGENTS.md's "a portable crew command vocabulary" note
# for the full reasoning.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

COMMANDS="$TEST_REPO/.claude/commands"
SKILLS="$TEST_REPO/.agents/skills"

REGULAR_FILES="lead prefs spawn standdown"
EXPORTED_VERBS="ask blocked prune say status takeover watch"

# --- 1. every .claude/commands/*.md is either a symlink resolving inside
#        .agents/skills/, or one of the four known claude-only regular files -
for f in "$COMMANDS"/*.md; do
  base="$(basename "$f" .md)"
  is_regular=0
  case " $REGULAR_FILES " in *" $base "*) is_regular=1 ;; esac

  if [ -L "$f" ]; then
    if [ "$is_regular" -eq 1 ]; then
      fail "$base.md is a symlink, but is one of the four commands that must stay a regular file ($REGULAR_FILES)"
    else
      ok "$base.md is a symlink (not one of the four claude-only regular files)"
    fi
    target="$(uv run --no-project --quiet python -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$f")"
    case "$target" in
      "$SKILLS"/*/SKILL.md) ok "$base.md's symlink resolves inside .agents/skills/" ;;
      *) fail "$base.md's symlink resolves OUTSIDE .agents/skills/ (resolved: $target)" ;;
    esac
    if [ -r "$f" ]; then
      ok "$base.md's symlink target is readable"
    else
      fail "$base.md's symlink target is NOT readable (broken symlink?)"
    fi
  else
    if [ "$is_regular" -eq 1 ]; then
      ok "$base.md is a regular file, one of the four known claude-only commands"
    else
      fail "$base.md is a regular file but is not one of the four known claude-only commands ($REGULAR_FILES) - every other verb must be a symlink into .agents/skills/"
    fi
  fi
done

# --- 2. the fail-closed absence: no wingman-spawn/wingman-standdown ever ----
assert_false "no wingman-spawn directory exists under .agents/skills/" "[ -e '$SKILLS/wingman-spawn' ]"
assert_false "no wingman-standdown directory exists under .agents/skills/" "[ -e '$SKILLS/wingman-standdown' ]"
assert_true "spawn.md is a regular file, never a symlink" "[ -f '$COMMANDS/spawn.md' ] && [ ! -L '$COMMANDS/spawn.md' ]"
assert_true "standdown.md is a regular file, never a symlink" "[ -f '$COMMANDS/standdown.md' ] && [ ! -L '$COMMANDS/standdown.md' ]"

# .agents/skills/ contains EXACTLY the seven expected verbs - no more, no
# fewer. This single diff-style assertion is what catches a stray
# wingman-spawn/wingman-standdown directory (or any other unexpected
# addition/removal) as a hard failure rather than something the absence
# checks above alone might miss if the directory list drifts in some other way.
found_dirs="$(ls -1 "$SKILLS" 2>/dev/null | sort)"
expected_dirs="$(for v in $EXPORTED_VERBS; do echo "wingman-$v"; done | sort)"
assert_eq ".agents/skills/ contains exactly the seven expected wingman-<verb> directories" "$found_dirs" "$expected_dirs"

# --- 3. every .agents/skills/*/SKILL.md: name matches its directory, is
#        wingman-prefixed, and description is non-empty -----------------------
for d in "$SKILLS"/*/; do
  dir="$(basename "$d")"
  f="${d}SKILL.md"
  if [ ! -f "$f" ]; then
    fail "$dir/ has no SKILL.md"
    continue
  fi
  name_val="$(grep -m1 '^name:' "$f" | sed 's/^name: *//')"
  assert_eq "$dir/SKILL.md's name frontmatter matches its directory name" "$name_val" "$dir"
  case "$name_val" in
    wingman-*) ok "$dir/SKILL.md's name is wingman-prefixed" ;;
    *) fail "$dir/SKILL.md's name ('$name_val') is not wingman-prefixed" ;;
  esac
  desc_val="$(grep -m1 '^description:' "$f")"
  if [ -n "$desc_val" ]; then
    ok "$dir/SKILL.md has a non-empty description"
  else
    fail "$dir/SKILL.md has a non-empty description"
  fi
done

# --- 4/5. every exported body: no bare bin/<script> invocation (excluding
#          frontmatter), and the $WINGMAN_BIN-unset fallback sentence is
#          present. "bin/wingman", "bin/spawn-crew", and "bin/crew-resume"
#          are never flagged - they name a DIFFERENT script (the thing that
#          exports $WINGMAN_BIN in the first place, or the top-level
#          launcher), never invoked by any of these seven bodies, so
#          rewriting them to $WINGMAN_BIN/... would be circular/wrong. Two
#          narrow carve-out phrases exempt the two places a bare bin/<script>
#          form is deliberately illustrative rather than an instruction to
#          run: the fallback sentence itself ("resolved relative to"), and
#          watch.md's own "unlike a bare `bin/watch-fleet`" contrast (issue
#          #214) - see the plan's own risk note on watch.md needing care
#          rather than a blind substitution.
for v in $EXPORTED_VERBS; do
  f="$SKILLS/wingman-$v/SKILL.md"
  [ -f "$f" ] || { fail "wingman-$v/SKILL.md is missing"; continue; }

  # Strip frontmatter: skip everything up to and including the second '---'.
  body="$(awk 'BEGIN{n=0} /^---$/{n++; next} n>=2{print}' "$f")"

  offending="$(printf '%s\n' "$body" \
    | grep -v 'resolved relative to' \
    | grep -v 'unlike a bare' \
    | grep -oE 'bin/[a-z][a-z0-9_-]*' \
    | grep -vE '^bin/(wingman|spawn-crew|crew-resume)$' \
    | sort -u || true)"
  if [ -z "$offending" ]; then
    ok "wingman-$v/SKILL.md's body carries no bare bin/<script> invocation"
  else
    fail "wingman-$v/SKILL.md's body carries a bare bin/<script> invocation: $offending"
  fi

  if printf '%s\n' "$body" | grep -q 'is unset' && printf '%s\n' "$body" | grep -q 'resolved relative to'; then
    ok "wingman-$v/SKILL.md's body documents the \$WINGMAN_BIN-unset fallback"
  else
    fail "wingman-$v/SKILL.md's body is missing the \$WINGMAN_BIN-unset fallback sentence"
  fi
done

test_summary
