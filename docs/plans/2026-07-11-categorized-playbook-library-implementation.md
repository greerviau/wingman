# Implementation plan: A Categorized Playbook Library

Date: 2026-07-11
Status: Ready for review
Type: Implementation plan (the *how*), built from the approved scoping doc
Input: `docs/plans/2026-07-10-categorized-playbook-library.md`
Repo: `wingman`

## 0. Adopted decisions (Open Questions, section 7 of the scoping doc)

The scoping doc left five open questions, each with its own "Recommended" option.
This plan adopts every recommendation as settled scope and does not re-litigate them:

- **Q1 (`lead`/`research` home): adopted `common/`.** Both roles are domain-neutral and get a single source of truth at `playbooks/common/`.
- **Q2 (directory rename): adopted `playbook/` -> `playbooks/`.** Every path in code, docs, and tests below uses the plural.
- **Q3 (`biological-research` placement): adopted as a nested sub-domain** at `playbooks/scientific-research/biological-research/`, not a top-level category.
- **Q4 (category-level shared partials, e.g. `_category.md`): adopted as out of scope.** No category-level partial ships in this build; the `_`-prefix convention already accommodates one later without any resolver change.
- **Q5 (role-set completeness): adopted the listed roles as the v1 shipping set.** Every role named in section 4 of the scoping doc ships; no additional roles are invented, and none are deferred.

## 1. Grounding beyond the scoping doc

The scoping doc's section 5.5 lists `bin/lib/common.sh`, `bin/spawn-crew`, `README.md`, `CLAUDE.md`, and the `.gitignore` comment as the prose/path references to update.
Reading the live tree turned up two more real references the doc's list missed, both must be included or the migration leaves dangling paths:

- **`bin/doctor`** (lines 72-73) hardcodes `$WM_REPO/playbook/developer.md` and `$WM_REPO/playbook/developer.local.md` to sniff whether the active developer playbook mentions `gh`, to decide whether to flag `gh` as a soft dependency. This must move to `$WM_REPO/playbooks/software-development/developer.md` (and the `.local.md` sibling in the same directory).
- **`docs/architecture.md`** contains extensive prose about the crew type system: it names `playbook/_status-contract.md`, describes each of the six existing playbooks by path (`playbook/analyst.md`, `playbook/architect.md`, etc.), and uses "analyst" as the canonical example role throughout (including a `playbook/pi.md` hypothetical). None of this is in the scoping doc's file list, but it goes stale the moment the directory or the `analyst` name changes, so it is included in this plan's doc-update phase (Phase 6).

There is no `playbook/developer.local.md` currently present in this checkout (confirmed by `find`) despite the scoping doc's section 5.1 describing it as "the existing... local override, moved with its role."
`.local.md` files are gitignored and machine-local, so this checkout simply has none; the migration commit only moves tracked files.
If an operator's own machine has a gitignored `playbook/developer.local.md`, moving it to `playbooks/software-development/developer.local.md` is a manual step on their side — `git mv` cannot move a file that isn't tracked in this checkout. This is called out in the doc updates (Phase 6) as a one-line migration note.

The six test files `tests/dead-lead-orphans.test.sh`, `tests/stall-check.test.sh`, `tests/handled-marker.test.sh`, `tests/roster-cleanup.test.sh`, `tests/ack-dedup.test.sh`, and `tests/watch-fleet.test.sh` all call `wm_state crew-add --type analyst ...` directly against the state engine (`bin/lib/wm-state.py`), which does not consult the playbook resolver or validate `--type` against any file on disk — it is a free-form label in the roster record. These do **not** need to change; they are unaffected by the rename and are called out here only so the implementer doesn't spend time on them.

`tests/spawn-scope.test.sh`, by contrast, calls the *real* `bin/spawn-crew --type analyst ...` eight times, which does go through the resolver. Every one of those breaks once `analyst` stops resolving. This file's `--type analyst` occurrences must become `--type software-analyst` (Phase 3).

## 2. Target layout (unchanged from the scoping doc, restated for reference)

```
playbooks/
  _status-contract.md
  common/
    lead.md
    research.md
  software-development/
    software-analyst.md
    architect.md
    developer.md
    reviewer.md
  ai-research/
    research-analyst.md
    experiment-designer.md
    ml-engineer.md
    research-reviewer.md
  data-science/
    data-analyst.md
    data-engineer.md
    data-scientist.md
    analytics-reviewer.md
  scientific-research/
    experimental-designer.md
    experimentalist.md
    analysis-scientist.md
    peer-reviewer.md
    biological-research/
      assay-designer.md
      bioinformatician.md
  business-development/
    market-analyst.md
    gtm-strategist.md
    partnerships-rep.md
  business-operations/
    ops-analyst.md
    finance-analyst.md
    process-designer.md
```

## 3. Phase structure

This plan follows the scoping doc's section 8 build order exactly, as seven phases.
Phases 1-4 are the mechanical resolver/reorg; phases 5-7 are content authoring and docs.
The PR-split recommendation (section 9) groups these phases into two PRs; the phase numbering below is unaffected by that grouping and is the sequence to implement and commit in, regardless of how many PRs they land in.

### Phase 1 — Resolver and enumeration, no content move

Goal: get the recursive-search resolver correct and tested while every playbook file is still flat under the (still-singular) `playbook/` directory. `find` over a flat directory is trivially "recursive" (depth 0), so the new resolver already produces the exact same bare-name resolutions as the old glob-based one — this phase changes *mechanism*, not *behavior*, which is what makes it low-risk to land and verify before any file moves.

**`bin/lib/common.sh` changes.**

Add a single shared path constant right after `WM_REPO` is established (this is what makes the later `playbook` -> `playbooks` rename in Phase 3 a one-line diff instead of a re-edit of every call site):

```bash
# Root of the playbook library: category subdirectories of role files, plus the
# shared _status-contract.md partial at its own top level. (Phase 1: still
# playbook/, singular, flat — Phase 3 flips this to playbooks/ when the files
# move into category subdirectories.)
WM_PLAYBOOKS="$WM_REPO/playbook"
export WM_PLAYBOOKS
```

Replace `wm_crew_types()`:

```bash
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
```

Note: during Phase 1 (files still flat under `playbook/`), every role file's `dirname` is `$WM_PLAYBOOKS` itself, so `cat` is empty and every line is skipped by the `[ "$cat" = "$d" ]` guard — `wm_crew_types` would print nothing yet. That is expected and harmless: `--list-types` is cosmetic, and the resolver (below) does not depend on `wm_crew_types`'s output shape, only on `find` finding the right file. The category-qualified output only starts appearing once Phase 3 moves files into subdirectories. If this temporarily-empty `--list-types` bothers reviewers, it is fine to land Phase 1 and Phase 3 as two commits reviewed together (see section 9) rather than as separately-shippable states.

**`bin/spawn-crew` changes.**

Replace the flat resolution block (currently):

```bash
PLAYBOOK="$WM_REPO/playbook/$TYPE.md"
[ -f "$WM_REPO/playbook/$TYPE.local.md" ] && PLAYBOOK="$WM_REPO/playbook/$TYPE.local.md"
[ -f "$PLAYBOOK" ] || wm_die "no playbook for crew type '$TYPE'. Available: $(wm_crew_types | tr '\n' ' ')- to add it, create playbook/$TYPE.md (or $TYPE.local.md)"
```

with:

```bash
# --- resolve the playbook (local override wins) ------------------------------
# A crew type is valid iff a playbook exists for it under $WM_PLAYBOOKS. A bare
# name (e.g. "developer") is searched across every category - role names are
# kept unique across categories, so every existing and shipped type resolves
# unambiguously. A category-qualified name ("software-development/developer")
# is accepted to break a genuine collision. Add
# $WM_PLAYBOOKS/<category>/<type>.md (tracked) or .local.md (gitignored,
# survives pulls) to define a new type.
PLAYBOOK=""
case "$TYPE" in
  */*)
    # Category-qualified form: resolve directly, local override wins.
    PLAYBOOK="$WM_PLAYBOOKS/$TYPE.md"
    [ -f "$WM_PLAYBOOKS/$TYPE.local.md" ] && PLAYBOOK="$WM_PLAYBOOKS/$TYPE.local.md"
    [ -f "$PLAYBOOK" ] || wm_die "no playbook for crew type '$TYPE'. Available: $(wm_crew_types | tr '\n' ' ')- to add it, create $WM_PLAYBOOKS/$TYPE.md (or $TYPE.local.md)"
    ;;
  *)
    # Bare form: search every category directory for a role file named $TYPE.
    # Collapse a .local.md onto its sibling .md in the same directory (still
    # one candidate directory - local override still wins there); more than
    # one distinct directory is a collision the caller must disambiguate.
    DIRS=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      d="$(dirname "$f")"
      case " $DIRS " in *" $d "*) ;; *) DIRS="$DIRS $d" ;; esac
    done < <(find "$WM_PLAYBOOKS" -type f \( -name "$TYPE.md" -o -name "$TYPE.local.md" \) 2>/dev/null)
    set -- $DIRS
    case "$#" in
      0)
        wm_die "no playbook for crew type '$TYPE'. Available: $(wm_crew_types | tr '\n' ' ')- to add it, create $WM_PLAYBOOKS/<category>/$TYPE.md (or $TYPE.local.md)"
        ;;
      1)
        d="$1"
        ;;
      *)
        QUALIFIED=""
        for d in "$@"; do QUALIFIED="$QUALIFIED ${d#"$WM_PLAYBOOKS"/}/$TYPE"; done
        wm_die "crew type '$TYPE' is ambiguous across categories: pick one of$QUALIFIED"
        ;;
    esac
    PLAYBOOK="$d/$TYPE.md"
    [ -f "$d/$TYPE.local.md" ] && PLAYBOOK="$d/$TYPE.local.md"
    ;;
esac
```

`set -- $DIRS` is safe here: by this point in the script, the original `while [ $# -gt 0 ]` argument-parsing loop has already fully consumed argv (the loop only exits when `$#` reaches 0), so nothing later in `spawn-crew` reads the outer `$1`/`$@`/`$#` again — repurposing them locally for the directory list is not a collision. This intentionally does not quote `$DIRS` when re-splitting it: none of the shipped category or role names contain spaces, and neither does `$WM_REPO` in the supported deployment (a cloned repo path); this is the same implicit assumption the doc's own algorithm makes and matches the codebase's existing style (e.g. the unquoted `GLOBAL_REPO_DIRS` handling a few lines up). Process substitution (`< <(...)`) is used instead of piping into the `while` loop because a pipe would run the loop in a subshell and lose `$DIRS` on exit — process substitution is a core bash feature (not a bash-4+ one), so it stays bash-3.2-safe alongside `find`.

Also update the two remaining path references later in the same file:

- The header comment (line 6) usage string mentions bare type names; leave the enumeration as-is (`<analyst|architect|developer|reviewer|lead>` becomes stale once `analyst` is renamed regardless of categorization — fold that edit into Phase 3, where the rename actually happens) but there is no immediate Phase-1 edit needed here beyond what's already covered.
- Line 142 (system-prompt composition): `cat "$WM_REPO/playbook/_status-contract.md"` becomes `cat "$WM_PLAYBOOKS/_status-contract.md"`.

Run the existing suite (`bash tests/run.sh`) after this phase. Nothing should regress: every current bare `--type` (`analyst`, `architect`, `developer`, `reviewer`, `lead`, `research`) still resolves to the same flat file it did before, just through `find` instead of a glob.

### Phase 2 — Add the resolution test

Add `tests/playbook-resolution.test.sh` now, against the still-flat directory, and get it green against the Phase-1 resolver. Full test content is specified in section 4 below (it is written to work correctly both before and after Phase 3's file moves, since it spawns against whatever `playbooks/` layout is live rather than hardcoding the pre-migration state — the only test in this phase that is inherently Phase-3-dependent is the "bare name resolves to the correct category file" assertion, which checks `software-development/developer.md`; write it now, expect it to fail until Phase 3 lands, and treat that as the expected red-to-green marker for the phase boundary. Alternatively, implement Phase 2 and Phase 3 as two commits reviewed together so the test is only ever run against its final target layout — see section 9 for why this plan recommends landing Phases 1-4 as one PR).

### Phase 3 — Move the existing files, rename the directory, fix every path reference

**Git moves (one commit).** From the repo root:

```bash
mkdir -p playbooks/common playbooks/software-development
git mv playbook/_status-contract.md playbooks/_status-contract.md
git mv playbook/lead.md            playbooks/common/lead.md
git mv playbook/research.md        playbooks/common/research.md
git mv playbook/analyst.md         playbooks/software-development/software-analyst.md
git mv playbook/architect.md       playbooks/software-development/architect.md
git mv playbook/developer.md       playbooks/software-development/developer.md
git mv playbook/reviewer.md        playbooks/software-development/reviewer.md
rmdir playbook   # now empty; fails loudly if anything was missed
```

(No `developer.local.md` move: none exists in this tracked checkout, per section 1 above.)

**Flip the one path constant** in `bin/lib/common.sh`:

```bash
WM_PLAYBOOKS="$WM_REPO/playbooks"
```

**Update `bin/doctor`** (lines 72-73), the reference the scoping doc's file list missed:

```bash
dev_playbook="$WM_REPO/playbooks/software-development/developer.md"
[ -f "$WM_REPO/playbooks/software-development/developer.local.md" ] && dev_playbook="$WM_REPO/playbooks/software-development/developer.local.md"
```

**Update `bin/spawn-crew`'s header comment** (line 6) to reflect the renamed role:

```
#   spawn-crew --type <software-analyst|architect|developer|reviewer|lead> (--repo <path-or-name> | --scope global) \
```

**Update `playbooks/common/lead.md`** (moved, but its prose references the old bare name): the `analyst` -> `software-analyst` rename touches every prose mention of the role, since `lead.md`'s default software pipeline names it explicitly:

- Line ~28: `bin/spawn-crew --type <analyst|architect|developer|reviewer> ...` -> `<software-analyst|architect|developer|reviewer>`
- Line ~47: `Spawn an \`analyst\` to gather requirements ...` -> `Spawn a \`software-analyst\` to gather requirements ...`, and `Iterate it with the analyst via ...` -> `Iterate it with the software-analyst via ...`
- Line ~53: `your analyst/architect deliver a plan` -> `your software-analyst/architect deliver a plan`
- Line ~69: `You may spawn \`analyst\`/\`architect\`/\`developer\`/\`reviewer\` workers` -> `\`software-analyst\`/\`architect\`/\`developer\`/\`reviewer\` workers`

None of `playbooks/common/research.md`, `playbooks/software-development/architect.md`, `playbooks/software-development/developer.md`, or `playbooks/software-development/reviewer.md` reference the bare `analyst` name in their own prose (confirmed by reading each), so no in-file edits are needed beyond the move itself and the mechanical rename inside `software-analyst.md`'s own header (`# Playbook: \`analyst\` crew member` -> `` # Playbook: `software-analyst` crew member ``) and its cross-reference to itself in its "Note on large efforts" section, which already speaks generically ("a separate `architect` member") and needs no change.

**Update `tests/spawn-scope.test.sh`.** Every `--type analyst` becomes `--type software-analyst` (8 occurrences, lines 32, 44, 64, 69, 72, 75, 80, 82 as read). This test exercises generic spawn-scope mechanics (global vs. repo scope, worktree export, model defaults, argument guards) using `analyst` only as a stand-in type — the substitution is mechanical and preserves the test's intent.

**Run the full suite** (`bash tests/run.sh`) and fix any remaining path or type-name regression before moving on. This is the point at which `--type analyst` verifiably stops resolving (by design) everywhere except the six `wm_state crew-add` call sites identified in section 1, which don't go through the resolver at all.

### Phase 4 — Confirm `--list-types` output

No further code change is required here beyond what Phase 1 already wrote: `wm_crew_types` already emits `category/role` lines and, because they're piped through `sort -u`, are already grouped by category (alphabetical sort clusters every `common/*` line together, then every `software-development/*` line, etc.) — this satisfies the scoping doc's "grouped by category" requirement without any extra formatting logic. Once Phase 3's moves land, `bin/spawn-crew --list-types` should print (order illustrative):

```
common/lead
common/research
software-development/architect
software-development/developer
software-development/reviewer
software-development/software-analyst
```

A further human-friendly rendering (category headers with indented roles, as the scoping doc notes in section 5.3) is an explicit presentation nicety layered on top of this machine-readable contract, not required for v1 — skip it; it is cheap to add later as a pure `--list-types`-side formatting pass over `wm_crew_types`'s existing output; recorded as a follow-up in section 10, not built here (nothing in section 4 of the scoping doc requires it, and CLAUDE.md's own guidance is not to add abstraction beyond what's asked for).

Update the resolution test's `--list-types` assertions to match the post-move category-qualified output (see section 4, test 6).

### Phase 5 — Author the new playbooks, one category at a time

Order: `common` (already done as a pure move in Phase 3 — nothing new to write), then `ai-research`, `data-science`, `scientific-research` (+ `biological-research`), `business-development`, `business-operations`. Full content outlines for every new file are in section 5 below. Each mirrors the structure and status-contract wiring of the existing software playbooks (a one-line role statement, a `## Posture` section, a `## Handoff contract` section) and states its handoff explicitly, per the scoping doc's instruction.

### Phase 6 — Update prose docs

`README.md`, `CLAUDE.md`, `docs/architecture.md`, and the `.gitignore` comment. Full diffs are in section 6 below.

### Phase 7 — Manual smoke test

Spawn one member per category with the stub agent (`WM_AGENT` pointed at a script that just sleeps, exactly as `tests/spawn-scope.test.sh` already does) to confirm each new playbook resolves and launches, and that its `sysprompt.md` contains the expected role content plus the trailing status contract. One spawn per top-level category is sufficient (7 spawns: `common/lead`, `software-development/developer`, `ai-research/research-analyst`, `data-science/data-analyst`, `scientific-research/experimental-designer`, `business-development/market-analyst`, `business-operations/ops-analyst`), plus one for the nested sub-domain (`scientific-research/biological-research/assay-designer`) to prove the deeper nesting resolves too.

## 4. `tests/playbook-resolution.test.sh` (section 6 of the scoping doc, in full)

```bash
#!/usr/bin/env bash
# E2E: playbook resolution across playbooks/<category>/<role>.md. Proves bare
# unique names resolve via recursive search, category-qualified names resolve
# directly, .local.md wins over its sibling .md, unknown types are rejected,
# cross-category name collisions error out deterministically listing the
# qualified forms, --list-types emits category-qualified names and excludes
# _-prefixed partials, and the shared status contract is still concatenated
# onto a spawned member's system prompt from its new path. Uses a stub agent
# (WM_AGENT) and an isolated tmux session so no real claude launches and the
# live fleet is untouched.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SPAWN="$TEST_REPO/bin/spawn-crew"

REPO_DIR="$(mktemp -d)/repo"
mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init -q

STUB="$(mktemp -d)/stub.sh"
printf '#!/usr/bin/env bash\nexec sleep 60\n' > "$STUB"
chmod +x "$STUB"

export WM_AGENT="$STUB" WM_SPAWN_DELAY=0 WM_SUBMIT_DELAY=0
test_new_home

cleanup() { tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null; }
trap cleanup EXIT

# --- bare unique name resolves to the correct category file ------------------
id1="$("$SPAWN" --type developer --repo "$REPO_DIR" --objective "bare name" 2>/dev/null | tail -1)"
assert_true "bare --type developer spawns" "[ -n '$id1' ]"
sp1="$WINGMAN_HOME/crew/$id1.sysprompt.md"
assert_true "sysprompt file exists" "[ -f '$sp1' ]"
assert_true "resolves to software-development/developer.md content" \
  "grep -q 'Playbook: \`developer\` crew member' '$sp1'"

# --- category-qualified name resolves directly --------------------------------
id2="$("$SPAWN" --type common/lead --repo "$REPO_DIR" --objective "qualified name" 2>/dev/null | tail -1)"
assert_true "qualified --type common/lead spawns" "[ -n '$id2' ]"
sp2="$WINGMAN_HOME/crew/$id2.sysprompt.md"
assert_true "resolves to common/lead.md content" \
  "grep -q 'Playbook: \`lead\` crew member' '$sp2'"

# --- .local.md wins over its sibling .md --------------------------------------
LOCAL="$TEST_REPO/playbooks/software-development/developer.local.md"
[ -e "$LOCAL" ] && { echo "SKIP: $LOCAL exists; not overwriting"; exit 0; }
echo "local override marker" > "$LOCAL"
cleanup_local() { rm -f "$LOCAL"; cleanup; }
trap cleanup_local EXIT
id3="$("$SPAWN" --type developer --repo "$REPO_DIR" --objective "local override" 2>/dev/null | tail -1)"
sp3="$WINGMAN_HOME/crew/$id3.sysprompt.md"
assert_true "local override content wins over the tracked default" \
  "grep -q 'local override marker' '$sp3'"
rm -f "$LOCAL"
trap cleanup EXIT

# --- unknown type is rejected --------------------------------------------------
if "$SPAWN" --type nonexistent-role --repo "$REPO_DIR" --objective x >/dev/null 2>&1; then rc=0; else rc=$?; fi
assert_true "unknown type is rejected with non-zero exit" "[ $rc -ne 0 ]"

# --- cross-category collision errors deterministically ------------------------
COL_NAME="zzz-collision-fixture"
COL_A="$TEST_REPO/playbooks/software-development/$COL_NAME.md"
COL_B="$TEST_REPO/playbooks/common/$COL_NAME.md"
echo "# fixture A" > "$COL_A"
echo "# fixture B" > "$COL_B"
ERR="$(mktemp)"
cleanup_collision() { rm -f "$COL_A" "$COL_B" "$ERR"; cleanup; }
trap cleanup_collision EXIT
if "$SPAWN" --type "$COL_NAME" --repo "$REPO_DIR" --objective collide >/dev/null 2>"$ERR"; then rc=0; else rc=$?; fi
assert_true "cross-category collision is rejected" "[ $rc -ne 0 ]"
assert_contains "collision error names the software-development form" "$(cat "$ERR")" "software-development/$COL_NAME"
assert_contains "collision error names the common form" "$(cat "$ERR")" "common/$COL_NAME"
rm -f "$COL_A" "$COL_B" "$ERR"
trap cleanup EXIT

# --- --list-types emits category-qualified names, excludes partials -----------
LIST="$("$SPAWN" --list-types)"
assert_contains "list-types includes common/lead" "$LIST" "common/lead"
assert_contains "list-types includes software-development/developer" "$LIST" "software-development/developer"
assert_contains "list-types includes the renamed software-development/software-analyst" "$LIST" "software-development/software-analyst"
assert_false "list-types excludes the analyst bare name (renamed away)" \
  "printf '%s\n' \"$LIST\" | grep -qx 'software-development/analyst'"
assert_false "list-types excludes the _status-contract partial" \
  "printf '%s\n' \"$LIST\" | grep -q '_status-contract'"

# --- the shared status contract is still concatenated from its new path -------
assert_true "sysprompt carries the crew status contract" \
  "grep -q 'Crew status contract' '$sp1'"

test_summary
```

Notes on this test file:

- It follows `tests/spawn-scope.test.sh`'s established pattern exactly: an isolated `mktemp` git repo as the spawn target, a `sleep`-only stub agent so no real `claude` launches, `test_new_home` for an isolated `$WINGMAN_HOME`/tmux session, and the shared `assert_*` helpers from `tests/lib.sh`.
- The `.local.md` and collision fixtures are written directly into the live `playbooks/` tree (there is no isolated fixture repo the way `spawn-scope.test.sh` builds one for its `repoA`/`repoB`, because playbook resolution is inherently rooted at `$WM_REPO/playbooks`, not at a spawn target) — this is safe because the fixture filenames (`developer.local.md`, `zzz-collision-fixture.md`) are cleaned up in `trap`-registered handlers on every exit path, `.local.md` is already gitignored so a leftover would never get committed, and the guard on `LOCAL` skips rather than clobbers if a real operator override happens to exist.
- Add this test's filename to whatever mechanism `tests/run.sh` uses to discover suites — confirm it globs `tests/*.test.sh` (it does, per the existing convention) so no explicit registration is needed.

## 5. New playbook content outlines (Phase 5)

Every new file below is new prose with no prior art in this repo, per the assignment. Each outline gives the shape a fresh `developer` session should write from directly, without further design: the file's opening role statement, its `## Posture` bullets, and its `## Handoff contract`, mirroring the four existing software playbooks' structure (see `playbooks/software-development/architect.md`, `reviewer.md`, `common/research.md` for the literal prose patterns being mirrored). Every file ends with the same one line every existing playbook has: a reference to the appended crew status contract governing state reporting.

Three recurring **contract shapes** are used below, named for the existing playbook each mirrors:

- **Shape A (`architect`/`software-analyst`-like — upstream framing/design).** Writes a file, reports `--status review` with the file as `artifact`, parks in `review` with no watcher, revises the same file on `crew-say` feedback, terminal on the requester's approval/handoff.
- **Shape B (`developer`-like — ships code).** Worktree, implement, commit, push, PR, arms `pr-watch`, parks in `review` while the PR is up, back to `working` on review feedback or CI failure, terminal (`done`) on merge/close.
- **Shape C (`reviewer`/`research`-like — terminal on delivery).** Writes a file (or posts PR review comments), reports it as `artifact`/`summary`, terminal immediately since there is no further revision loop owned by this role.

### 5.1 `ai-research` (chain: `research-analyst -> experiment-designer -> ml-engineer -> research-reviewer`)

**`research-analyst`** — `playbooks/ai-research/research-analyst.md` — Shape A
- Role statement: frames a research question, surveys prior art and baselines, and proposes experiments; does not implement or run anything.
- Deliverable: an experiment proposal / spec file under `docs/plans/`.
- Posture: survey prior art before proposing anything new (don't re-run a known result); state the hypothesis and what evidence would confirm or falsify it; when multiple experiment designs could test the hypothesis, recommend one and record the rest as follow-ups rather than presenting a menu; note any baseline the proposal must beat.
- Handoff: hands the approved proposal to `experiment-designer`.

**`experiment-designer`** — `playbooks/ai-research/experiment-designer.md` — Shape A
- Role statement: turns an approved research proposal into a concrete, reproducible experiment design — the *how* of the research, mirroring `architect`'s relationship to `software-analyst`.
- Deliverable: an experiment design doc under `docs/plans/` naming exact datasets, splits, metrics, baselines, and the ablations that isolate the hypothesis.
- Posture: pin dataset versions and splits explicitly (reproducibility is the deliverable's whole point); specify the metric(s) that actually test the hypothesis, not just what's easy to log; call out compute/time budget and any ablation that would be needed to rule out a confound.
- Handoff: hands the design to `ml-engineer`.

**`ml-engineer`** — `playbooks/ai-research/ml-engineer.md` — Shape B
- Role statement: implements and runs the experiments from an approved design, and captures the metrics/artifacts that answer the research question. Isolates work in its own worktree/branch exactly like `developer`, since the deliverable is real code plus recorded results.
- Deliverable: a results file (metrics, logs, links to run artifacts) under `docs/analysis/`, plus the experiment code as a branch/PR.
- Posture: follow the same dev cycle as `developer` (worktree at `$WINGMAN_WORKTREE`, implement, commit, push, open a PR); write the results file *before* opening the PR so the PR description can point at it; if a run fails or a metric contradicts the hypothesis, report that plainly rather than only reporting favorable runs; validate against the design doc's specified baselines, not an easier substitute.
- Handoff: opens a PR (its `--delivery`) that `research-reviewer` reviews via inline PR comments, exactly as `reviewer` does for a `developer`'s PR; runs `pr-watch` and follows the identical merge/close terminal condition as `developer`.

**`research-reviewer`** — `playbooks/ai-research/research-reviewer.md` — Shape C
- Role statement: critiques methodology, reproducibility, and statistical validity of a proposal, design, or completed experiment; does not implement or fix.
- Deliverable: a review report under `docs/analysis/`, or inline PR review comments when reviewing `ml-engineer`'s PR (mirrors `reviewer`'s own dual mode).
- Posture: check for the concrete failure modes of ML research specifically — data leakage between train/eval, an ablation that doesn't isolate what it claims to, a metric that doesn't actually test the stated hypothesis, insufficient seeds/runs to support the claimed effect size; rank findings by whether they'd overturn the conclusion versus polish.
- Handoff: feeds findings back to `research-analyst` (if the proposal itself is flawed) or `ml-engineer` (if the execution is); terminal once delivered.

### 5.2 `data-science` (chain: `data-analyst -> data-engineer -> data-scientist -> analytics-reviewer`)

**`data-analyst`** — `playbooks/data-science/data-analyst.md` — Shape A
- Role statement: frames the data question and scopes the exploratory analysis needed to answer it.
- Deliverable: an analysis spec (the question, the data sources believed to answer it, and an initial EDA) under `docs/plans/`.
- Posture: state the decision the analysis is meant to inform, not just the question, so downstream scope stays bounded; identify what data exists versus what `data-engineer` will need to build; flag any known data-quality issue up front.
- Handoff: hands to `data-engineer`.

**`data-engineer`** — `playbooks/data-science/data-engineer.md` — Shape B
- Role statement: builds the pipeline or dataset the analysis needs; this is code, so it follows the same dev cycle as `developer`.
- Deliverable: a reproducible dataset/pipeline, shipped as a branch/PR (no separate `docs/` file is required beyond the PR description, mirroring `developer`).
- Posture: make the pipeline re-runnable (pinned sources, a documented refresh procedure) rather than a one-off dump; validate row counts / schema against the analysis spec's stated need before handing off; note any transformation that could bias the downstream analysis.
- Handoff: opens a PR (`--delivery`), watches it through merge exactly like `developer`; hands the resulting dataset/pipeline to `data-scientist`.

**`data-scientist`** — `playbooks/data-science/data-scientist.md` — Shape A
- Role statement: models or analyzes the data to answer the question quantitatively.
- Deliverable: an analysis report or notebook under `docs/analysis/`.
- Posture: state the answer and its confidence interval/uncertainty, not just a point estimate; check for the standard traps (leakage, confounding, multiple-comparison inflation) before presenting a result; when a modeling choice is debatable, recommend one and note the alternative as a follow-up.
- Handoff: hands to `analytics-reviewer`; unlike a pure Shape-C reviewer target, `data-scientist` itself parks in `review` and revises the *same* report in place when `analytics-reviewer`'s feedback arrives (mirroring how `architect` revises on a `reviewer`'s findings), terminal on the requester's acceptance of the analysis.

**`analytics-reviewer`** — `playbooks/data-science/analytics-reviewer.md` — Shape C
- Role statement: validates methodology, leakage, and interpretation of a data-science analysis; does not re-run the analysis itself.
- Deliverable: a review report under `docs/analysis/`.
- Posture: check the join/aggregation logic for silent row duplication or drops; check that the stated conclusion is actually supported by the reported statistics (correlation-vs-causation framing, confidence claims); rank by whether a finding would change the conclusion.
- Handoff: feeds back to `data-scientist`; terminal once delivered.

### 5.3 `scientific-research` (chain: `experimental-designer -> experimentalist -> analysis-scientist -> peer-reviewer`), with `biological-research` sub-domain

**`experimental-designer`** — `playbooks/scientific-research/experimental-designer.md` — Shape A
- Role statement: turns a hypothesis into an experimental design and protocol.
- Deliverable: a protocol document under `docs/plans/` (hypothesis, design, controls, sample size/power, measured variables, and the analysis plan that will test the hypothesis).
- Posture: specify controls and confounds to rule out up front, not after data comes back; state the statistical test the analysis will use *before* execution, so the design is falsifiable rather than fit after the fact; note any resource or ethical constraint on the experiment.
- Handoff: hands the protocol to `experimentalist`.

**`experimentalist`** — `playbooks/scientific-research/experimentalist.md` — Shape C
- Role statement: executes or simulates the protocol and collects data; does not interpret results beyond noting anomalies during collection.
- Deliverable: a results dataset plus a methods log (what was actually done, deviations from protocol, timestamps/conditions) under `docs/analysis/`. If execution requires new simulation/collection code, that code lives in its own worktree/branch as supporting evidence for the results file, but the results-and-methods-log file — not a merged PR — is the deliverable and the terminal condition (there is no "ship to production" concept for a one-off experiment run).
- Posture: log deviations from the protocol as they happen, don't retrofit the log afterward; record raw data before any cleaning/transformation step, so the analysis stage can audit it; flag anomalies during collection rather than silently excluding them.
- Handoff: hands results + methods log to `analysis-scientist`; terminal once delivered (no revision loop is owned by this role — the doc's chain shows no feedback edge back to `experimentalist`).

**`analysis-scientist`** — `playbooks/scientific-research/analysis-scientist.md` — Shape A
- Role statement: analyzes results and tests the hypothesis statistically.
- Deliverable: a findings report under `docs/analysis/` (the test applied, the result, the confidence, and whether the hypothesis is supported, contradicted, or inconclusive).
- Posture: apply the statistical test specified in the protocol, not one chosen after seeing the data; report a null or contradicting result as plainly as a confirming one; separate what the data supports from speculative interpretation.
- Handoff: hands to `peer-reviewer`; parks in `review` and revises the same findings report in place on `peer-reviewer`'s feedback, terminal on acceptance.

**`peer-reviewer`** — `playbooks/scientific-research/peer-reviewer.md` — Shape C
- Role statement: critiques experimental design, execution, and conclusions.
- Deliverable: a peer-review report under `docs/analysis/`.
- Posture: check that the stated conclusion follows from the reported statistics and doesn't overreach the sample/power; check the methods log for protocol deviations that would undermine the result; rank by whether a finding would overturn the conclusion.
- Handoff: feeds back to `analysis-scientist`; terminal once delivered.

**Sub-domain `biological-research`**, nested at `playbooks/scientific-research/biological-research/`:

**`assay-designer`** — `playbooks/scientific-research/biological-research/assay-designer.md` — Shape A (specialized `experimental-designer`)
- Role statement: designs wet-lab or in-silico assays for a biological hypothesis; the biology-specific counterpart of `experimental-designer`.
- Deliverable: an assay protocol under `docs/plans/`, specifying the assay type, readout, controls (positive/negative), and — where applicable — the compound/target identifiers to test.
- Posture: identical to `experimental-designer`'s, plus: ground compound/target claims in the domain databases available to this session (ChEMBL for bioactivity, ClinicalTrials for trial precedent, PubMed/bioRxiv for prior literature) rather than assumption; state assay sensitivity/specificity limits explicitly since a negative result in a low-sensitivity assay is not evidence of absence.
- Handoff: hands the assay protocol into the same `experimentalist -> analysis-scientist -> peer-reviewer` chain as any other `scientific-research` protocol — no separate downstream role is needed for the sub-domain.

**`bioinformatician`** — `playbooks/scientific-research/biological-research/bioinformatician.md` — Shape A (specialized `analysis-scientist`)
- Role statement: analyzes omics/sequence/compound data and queries domain databases; the biology-specific counterpart of `analysis-scientist`.
- Deliverable: a bioinformatics findings report under `docs/analysis/`.
- Posture: identical to `analysis-scientist`'s, plus: cite the specific database records (ChEMBL compound/target IDs, ClinicalTrials NCT numbers, PubMed/bioRxiv identifiers) backing any claim, since these are exactly the kind of external, checkable facts the rest of the codebase already treats as verify-before-asserting; note when a sequence/omics pipeline's reference version or parameters could change the result.
- Handoff: feeds into `peer-reviewer` exactly as `analysis-scientist` does; parks in `review` and revises in place on peer-review feedback, terminal on acceptance.

### 5.4 `business-development` (chain: `market-analyst -> gtm-strategist -> partnerships-rep`)

**`market-analyst`** — `playbooks/business-development/market-analyst.md` — Shape A
- Role statement: researches a market or opportunity and sizes/segments it.
- Deliverable: a market brief under `docs/plans/`.
- Posture: ground sizing/segmentation claims in checkable sources (public filings, industry reports, or the workspace's connected CRM data) rather than plausible-sounding estimates; state the confidence and the method behind any sizing number; when multiple segments look viable, recommend one to pursue first and note the rest as follow-ups.
- Handoff: hands the brief to `gtm-strategist`.

**`gtm-strategist`** — `playbooks/business-development/gtm-strategist.md` — Shape A
- Role statement: turns a market brief into a go-to-market or growth strategy — the *how* of pursuing the opportunity, mirroring `architect`'s relationship to an approved spec.
- Deliverable: a GTM/growth strategy plan under `docs/plans/`.
- Posture: tie the strategy back to the brief's stated sizing/segment, don't silently broaden scope; name the concrete channels, sequencing, and success metric; recommend one strategy and record real alternatives as follow-ups.
- Handoff: hands the strategy to `partnerships-rep`.

**`partnerships-rep`** — `playbooks/business-development/partnerships-rep.md` — Shape C (terminal)
- Role statement: produces outreach materials, proposals, and partnership decks from an approved strategy; does not itself decide to contact anyone.
- Deliverable: a proposal / deck / outreach kit under `docs/plans/`.
- Posture: produce the artifact the strategy calls for; **do not autonomously send outreach** (an email, a Slack message, a CRM update visible to a real prospect or partner) without the requester's explicit confirmation first — this is exactly the "affects shared state, visible to others, hard to reverse" category the rest of this codebase's operating guidance already treats with caution, and a business-development role is the one most likely to reach a real external party through the workspace's connected Salesforce/Slack tools. Draft the send-ready content and say so; leave the actual send as a explicitly-confirmed follow-up action.
- Handoff: terminal; no further role in this chain consumes its output.

### 5.5 `business-operations` (chain: `ops-analyst -> {finance-analyst | process-designer}`)

**`ops-analyst`** — `playbooks/business-operations/ops-analyst.md` — Shape A
- Role statement: analyzes an internal process or financial question and decides which specialist it needs.
- Deliverable: an operations analysis report under `docs/plans/`.
- Posture: state clearly whether the question is financial (routes to `finance-analyst`) or procedural (routes to `process-designer`) and why — the handoff choice is this role's main judgment call; ground any financial figure in the connected accounting/expense tools (QuickBooks, Ramp) rather than an estimate, when those figures are load-bearing for the recommendation.
- Handoff: hands to `finance-analyst` or `process-designer` depending on the question's nature.

**`finance-analyst`** — `playbooks/business-operations/finance-analyst.md` — Shape C (terminal)
- Role statement: builds financial models and reporting from an approved operations question.
- Deliverable: a financial model / report under `docs/analysis/`.
- Posture: this role reaches QuickBooks/Ramp, which can represent and, if driven carelessly, *initiate* real financial actions — **read and report; never create, modify, or approve a transaction, payment, or reimbursement without the requester's explicit confirmation**, mirroring the same external-system caution as `partnerships-rep`, but for money rather than outreach, which is the highest-blast-radius connected system in this library. State assumptions and data sources behind every figure.
- Handoff: terminal; no further role in this chain consumes its output.

**`process-designer`** — `playbooks/business-operations/process-designer.md` — Shape C (terminal)
- Role statement: designs a standard operating procedure or workflow from an approved operations question.
- Deliverable: an SOP / workflow document under `docs/plans/`.
- Posture: write the SOP so someone unfamiliar with the process could follow it (explicit steps, owners, and exception handling), not just a summary of current practice; note any step the SOP assumes but doesn't itself enforce.
- Handoff: terminal; no further role in this chain consumes its output.

## 6. Doc updates (Phase 6)

### `README.md`

- Line 30 table row: `spawns an **analyst** crew → plan → ...` -> `spawns a **software-analyst** crew → plan → ...`
- Line 31: unaffected (says "analyst" generically for investigate mode — update to "software-analyst" for consistency).
- Line 32: `(analyst → architect → developers → reviewer)` -> `(software-analyst → architect → developers → reviewer)`
- Line 33: `` `analyst`, `architect`, `developer`, `reviewer`, `lead`, `research` `` -> `` `software-analyst`, `architect`, `developer`, `reviewer`, `lead`, `research` ``; also add one clause noting the library is now categorized (`bin/spawn-crew --list-types` shows every `category/role`) and that bare names still work when unique.
- Line 45: `The same lifecycle applies to analyst and other crew types ... (\`playbook/_status-contract.md\`)` -> `... applies to software-analyst and other crew types ... (\`playbooks/_status-contract.md\`)`
- Line 53-57 ("Customizing crew behavior" section): update `playbook/` -> `playbooks/` throughout; update the built-ins list's `analyst` -> `software-analyst`; add one sentence: playbooks now live under a category subdirectory (`playbooks/<category>/<role>.md`), and a new type is added the same way, just inside the category it belongs to (or a new category directory, for a genuinely new discipline).
- Line 65-67 ("Run an effort as an org" section): `analyst → architect → developer(s) → reviewer` -> `software-analyst → architect → developer(s) → reviewer`.

### `CLAUDE.md`

- Line 62: `The built-in types are \`analyst\`, \`architect\`, \`developer\`, \`reviewer\`, and \`lead\`` -> `` `software-analyst`, `architect`, `developer`, `reviewer`, and `lead` ``; add a clause noting these are the roles of the `software-development` category and that `bin/spawn-crew --list-types` now shows every category's roles.
- Line 64: `an \`analyst\` for a plan or investigation` -> `a \`software-analyst\` for a plan or investigation`.
- Line 126: rewrite to introduce categories explicitly, replacing the flat built-ins sentence, e.g.: "The built-ins span several categories under `playbooks/<category>/`: `software-development` (`software-analyst`, `architect`, `developer`, `reviewer`), `ai-research`, `data-science`, `scientific-research` (with a `biological-research` sub-domain), `business-development`, `business-operations`, and the domain-neutral `common` category (`lead`, `research`). Any `playbooks/<category>/<type>.md` defines a new type." Keep the sentence that a custom type is standalone unless its own playbook wires a handoff.
- Line 129: `The analyst->developer handoff` -> `The software-analyst->developer handoff`.
- Lines 134-138 (command vocabulary): `analyst` -> `software-analyst` throughout (three occurrences).
- Line 191 heading: `## The analyst → developer handoff` -> `## The software-analyst → developer handoff`.
- Lines 193-196: `analyst` -> `software-analyst` throughout (four occurrences).
- Line 200 ("Appointing a lead"): `an analyst, an architect, ...` -> `a software-analyst, an architect, ...`.
- Anywhere else `playbook/<type>.md` is mentioned as a path (line 35): `playbook/<type>.md` / `playbook/<type>.local.md` -> `playbooks/<category>/<type>.md` / `.local.md`.

### `docs/architecture.md`

Not in the scoping doc's file list (see section 1) but stale without these:

- Line 37: `` (`playbook/_status-contract.md`) `` -> `` (`playbooks/_status-contract.md`) ``.
- Line 72: `an analyst, an architect, ...` -> `a software-analyst, an architect, ...`.
- Line 84: `add named roles (\`playbook/pi.md\`, …)` -> `` add named roles (`playbooks/<category>/pi.md`, …) ``.
- Line 101: `A crew type is defined entirely by a playbook - plain prose in \`playbook/\`` -> `` `playbooks/<category>/` ``.
- Lines 103-108 (the six bullet points naming each playbook by path): update every `playbook/X.md` to `playbooks/<category>/X.md` per the new layout, and rename `playbook/analyst.md` -> `playbooks/software-development/software-analyst.md`; add one new bullet (or a short paragraph) after this list naming the five new categories and their `common`/domain split, so the architecture doc reflects the shipped taxonomy rather than only the original six software roles.
- Line 114: `playbook/<type>.local.md overrides the tracked <type>.md` -> `playbooks/<category>/<type>.local.md overrides the tracked <type>.md`.
- Line 116: `write \`playbook/analyst.local.md\`` -> `` write `playbooks/software-development/software-analyst.local.md` ``.

### `.gitignore`

- The comment above the `*.local.md` line currently reads: `# Per-crew-type playbook overrides (playbook/build.local.md, spec.local.md, ...)`. Update to: `# Per-crew-type playbook overrides (playbooks/<category>/build.local.md, ...)`. No pattern change — `*.local.md` already matches at any depth, confirmed by the scoping doc's own constraint #2 and unaffected by nesting.

## 7. Migration note for operators (fold into README or a short paragraph near the customization section)

If an operator's own machine already has a gitignored `playbook/<type>.local.md` override (none exist in this tracked checkout, but the scoping doc anticipated one for `developer`), it does not move automatically — `git mv` only moves tracked files. Add one sentence to the customization section of `README.md`: "If you have an existing `playbook/<type>.local.md` from before this reorganization, move it yourself to `playbooks/<category>/<type>.local.md` (the category the role now lives under) after pulling this change."

## 8. Testing strategy summary

- Phase 1: full suite green against the (behaviorally unchanged) recursive resolver over the still-flat `playbook/`.
- Phase 2: `tests/playbook-resolution.test.sh` added; expected to only fully pass once Phase 3 lands (see the note in section 3, Phase 2) — recommend implementing Phases 2 and 3 as sequential commits within the same PR so the test is reviewed once, against its final target state.
- Phase 3: full suite green again post-move, including the now-passing resolution test and the updated `tests/spawn-scope.test.sh`.
- Phase 4: resolution test's `--list-types` assertions pass against the post-move category-qualified output.
- Phase 7: manual smoke test, one spawn per new category plus the nested sub-domain, confirming each resolves, launches, and carries the trailing status contract in its `sysprompt.md` — this is manual because it requires observing a live tmux window rather than a scripted assertion, consistent with how the existing suite already treats "does the whole thing actually launch" as a smoke check rather than an automated assertion.
- CI (`.github/workflows/ci.yml`) requires no changes: it already discovers every `tests/*.test.sh` and lints every bash script by shebang; both mechanisms pick up the new test file and the moved/renamed bash files with no config edit.

## 9. PR-split recommendation

**Ship as two PRs, split exactly along the mechanical/content boundary: Phases 1-4 in PR1, Phases 5-7 in PR2.**

**PR1 — resolver and reorganization** (Phases 1-4): the `WM_PLAYBOOKS` constant, the rewritten `wm_crew_types()` and `spawn-crew` resolver, the `tests/playbook-resolution.test.sh` suite, the six `git mv`s plus the `playbook/` -> `playbooks/` rename, the `bin/doctor` fix, the `analyst` -> `software-analyst` rename and its ripple through `playbooks/common/lead.md` and `tests/spawn-scope.test.sh`. This PR is self-contained, fully covered by the automated suite, and reviewable purely on mechanical correctness — does every existing type still resolve, does collision handling work, is bash 3.2 respected — without anyone also having to judge the quality of brand-new domain content in the same diff. It is also the entire "risk" of this effort: a resolver bug here would misroute every crew spawn, so it deserves review isolated from unrelated content decisions.

**PR2 — new playbook content and doc updates** (Phases 5-7): the twenty new playbook files across five categories, plus `README.md`, `CLAUDE.md`, `docs/architecture.md`, and the `.gitignore` comment. This PR changes zero executable code and is reviewable purely on content quality — is the `ai-research` chain's handoff sound, does `finance-analyst`'s caution about QuickBooks/Ramp actually belong there, is the `biological-research` sub-domain's tool grounding correct — a completely different review lens than PR1's. Bundling it with PR1 would force one reviewer to hold both "is the bash correct" and "is this business-development mandate any good" in their head at once, for no shared risk between the two concerns.

This is the lowest-effort split that still separates genuinely independent review concerns (mirrors the exact split the assignment's own item 6 suggested); a single combined PR is not recommended, since it would gate the (fast, low-risk, fully-tested) mechanical change on the (slower, more subjective) content review, and a finer split (e.g. one PR per new category) is not recommended either, since the five new categories share no code dependency that would make merging them independently valuable, and it would only multiply review overhead for content that's genuinely reviewed together (the whole taxonomy, at once, is what makes it coherent).

## 10. Risks and follow-ups

- **Role-name uniqueness across categories is now a library invariant.** The bare-name resolver depends on no two categories shipping the same role name (a collision doesn't break anything — it degrades gracefully into an explicit error — but it does mean a future PR adding a role must check `bin/spawn-crew --list-types | awk -F/ '{print $NF}' | sort | uniq -d` for a clash before shipping. Not required for this build (Q5 fixes the v1 role set, and it has zero collisions today), but worth a one-line note in `docs/architecture.md`'s new categories paragraph for whoever adds the next one.
- **The human-friendly grouped `--list-types` rendering** (category headers, indented roles) is explicitly deferred per section 4 above; today's flat sorted `category/role` output already satisfies the scoping doc's actual requirement.
- **Category-level shared partials** (`playbooks/<category>/_category.md`) are explicitly out of scope per adopted Q4; the `_`-prefix filter already ignores any future file matching that pattern, so adding one later needs no resolver change, only a `spawn-crew` change to also `cat` it into the composed system prompt when present.
- **`biological-research` promotion to a top-level category** is explicitly deferred per adopted Q3; promoting it later is a pure directory move (`git mv playbooks/scientific-research/biological-research playbooks/biological-research`) with no resolver change, since the resolver already treats any depth uniformly.
- **The optional transitional `playbook -> playbooks` symlink** the scoping doc mentions (section 5.5) is not included in this plan: no out-of-tree caller of this path is known to exist (wingman is a single-repo tool with no external consumers of its own `playbook/` path), so the doc's own guidance ("recommended only if such callers are known to exist; otherwise omit it") is to omit it. If one turns up post-migration, it is a one-line addition, not a design change.
