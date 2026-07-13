# Ticket: wire per-spawn model selection into wingman's orchestrator behavior

Status: proposed (scoping only, no implementation).
Date: 2026-07-11.

## Problem statement

The pilot should be able to ask wingman to spawn a specific crew member on a
specific model (e.g. "spawn a developer for this on Opus", "have the
software-analyst use Sonnet") without changing wingman's own running model or
the model any other crew member uses.

`bin/spawn-crew` already has the mechanical plumbing for this (`--model
<alias|id>`, see below), but nothing in wingman's own operating instructions
(`CLAUDE.md`) or the `lead` playbook tells wingman - or a lead spawning its
own workers - to translate a pilot's model request into that flag. The
capability exists at the script layer and is invisible at the orchestrator
layer, so today a pilot's "use Opus for this one" has no defined path to an
actual `--model opus` on the spawn call.

## Current behavior (verified against the code)

**`bin/spawn-crew --model` is fully implemented, not aspirational:**

- `bin/spawn-crew:23,32` parses `--model <value>` into `$MODEL`.
- `bin/spawn-crew:96`: `[ -n "$MODEL" ] || MODEL="${WM_MODEL:-}"` - an explicit
  `--model` wins; otherwise the `WM_MODEL` env var (settable via
  `config.local.sh` or the environment) is the fallback default; with neither
  set, no `--model` flag is emitted and the `claude` CLI's own default model
  stands.
- `bin/spawn-crew:182`: `[ -n "$MODEL" ] && printf ' --model %s' "$(quote "$MODEL")"` -
  the resolved value is threaded verbatim into the generated launch script
  (`$WM_HOME/crew/<id>.launch.sh`), which execs `claude ... --model <value>
  ...` for that crew member's independent session.
- This is a **per-spawn, per-session** setting: it only affects the one
  `claude` invocation being launched. It has no effect on wingman's own
  running model or on any other crew member's session, so "without changing
  the repo/session's default model" is already satisfied by the existing
  mechanism.
- Test coverage exists for all three precedence levels (`tests/spawn-scope.test.sh:67-77`):
  no flag / no env → no `--model` emitted; `WM_MODEL` set, no flag → env value
  used; both set → explicit flag wins. Introduced in `36971dd` ("feat(spawn):
  WM_MODEL as the default model for crew sessions").

**What is missing is entirely at the orchestrator-behavior layer:**

- `CLAUDE.md`'s "Spawning crew (the recipe)" section shows `[--model
  <alias|id>]` in the usage synopsis, but the "Command vocabulary (pilot →
  you)" section - the part that actually maps pilot phrasing to actions - has
  no entry for a model request. There is no documented rule for wingman to
  recognize "spawn X on Opus" / "use Sonnet for this" and carry it through to
  `--model` on the `bin/spawn-crew` call.
- `playbooks/common/lead.md:28` shows the lead's own spawn recipe as
  `bin/spawn-crew --type <...> --repo <name-or-path> --objective "<task>"
  [--input <plan>]` - `--model` (and `--effort`) are omitted from the example
  entirely. A lead has no documented way to (a) accept a pilot's model
  preference for its effort and pass it down to its own worker spawns, or (b)
  pick a different model for a specific worker within its own team.
- No validation exists anywhere for the value passed to `--model`: an invalid
  alias or id is passed straight through to the `claude` CLI, which is the
  first thing that can reject it. There is no documented expectation for what
  a crew member's status shows if its launch fails this way.
- `.claude/commands/spawn.md` (the `/spawn` skill invoked by the pilot
  directly) parses only type, repo, and objective from `$ARGUMENTS`; it has no
  parsing path for a model token either.

## Desired behavior

1. A pilot directive that names a model for a specific spawn (e.g. "spawn a
   developer on Opus for the migration fix") results in wingman calling
   `bin/spawn-crew ... --model <resolved-value>` for that one spawn, with no
   change to wingman's own model or to any other crew member already running
   or spawned afterward without a model request.
2. `CLAUDE.md`'s "Command vocabulary" section documents this mapping
   explicitly, the same way it documents the repo-scope and lead-appointment
   decisions, so the behavior is reproducible rather than left to per-session
   judgment.
3. `playbooks/common/lead.md` documents the same capability for a lead's own
   worker spawns: a pilot's model preference stated when appointing the lead
   (or given later via `crew-say`) is something the lead can thread onto its
   own `bin/spawn-crew` calls for individual workers, and the lead's example
   recipe (line 28) includes `[--model <alias|id>]` so this isn't only
   discoverable by reading `bin/spawn-crew --help`.
4. The `/spawn` command (`.claude/commands/spawn.md`) accepts an optional
   model token in its argument grammar and passes it through, for the case
   where the pilot invokes the skill directly rather than phrasing a
   directive in prose.
5. Passing an unrecognized model value produces a diagnosable outcome, not a
   silent hang or an opaque `died` status indistinguishable from any other
   launch failure (see edge cases).

## Acceptance criteria

- [ ] `CLAUDE.md`'s command vocabulary includes a rule: when a directive names
      a model for a spawn, wingman passes `--model <value>` on that
      `bin/spawn-crew` call; absent a named model, behavior is unchanged
      (explicit `--model` > `WM_MODEL` > agent default, as today).
- [ ] `playbooks/common/lead.md`'s spawn recipe example includes `--model`
      (and ideally `--effort`, since it has the identical gap) as a
      documented optional flag, with a sentence on how a lead threads a
      pilot-stated model preference to its own worker spawns.
- [ ] A directive like "take the lead on X, use Opus for the developer phase"
      results in the lead passing `--model opus` specifically when it spawns
      the developer, not for every phase indiscriminately (unless the pilot
      says "for everything").
- [ ] `.claude/commands/spawn.md`'s argument grammar documents an optional
      model token and threads it to `--model` when present.
- [ ] Passing an invalid `--model` value produces a status distinguishable
      from other failure modes when inspected via `bin/crew-list` /
      `bin/watch-fleet` (see edge cases below for what "distinguishable"
      requires investigating first).
- [ ] No change to `bin/spawn-crew`'s existing precedence semantics
      (`--model` > `WM_MODEL` > agent default) or to sessions spawned without
      an explicit model request.
- [ ] Test coverage: `tests/spawn-scope.test.sh` already covers the flag
      precedence at the script level; new coverage (or a new test file) is
      needed for whatever orchestrator/lead-level parsing logic this ticket
      adds, plus the `/spawn` skill's argument parsing if that's touched.

## Edge cases

- **Lead → sub-crew model passthrough.** A lead spawns its own workers via
  the same `bin/spawn-crew` script (`playbooks/common/lead.md:28`), so the
  mechanism is available to it for free once documented - but the *decision*
  of which of its workers (if any) inherit a pilot-stated model preference is
  a judgment call the playbook needs to make explicit (all workers? only the
  phase the pilot mentioned? default WM_MODEL still wins for unmentioned
  phases?).
- **Invalid model names/aliases.** Nothing in `bin/spawn-crew` validates the
  value before threading it into the launch script; the `claude` CLI is the
  first thing that can reject it, at process start inside the tmux window.
  Investigate (before implementing) whether that failure currently surfaces
  as `died` (window/pane exits) via `bin/watch-fleet`'s liveness
  reconciliation, and whether that's distinguishable enough from a died
  window caused by something else (crash, killed process) for the pilot to
  know "bad model name" was the cause without attaching to the pane. This may
  only need a documentation fix (tell the pilot to check via
  `bin/crew-takeover` on a `died` member) rather than new code, but that's a
  design decision for the follow-up plan, not this ticket.
- **Model aliases vs. raw IDs.** `bin/spawn-crew` treats `--model` as an
  opaque string; it does not maintain or validate against a known-alias list
  (`opus`, `sonnet`, `haiku`, `fable`, or a raw id like `claude-opus-4-8`).
  This is consistent with today's `claude` CLI behavior (it accepts both) and
  should stay that way - no new alias-resolution layer in wingman is called
  for, since that would duplicate a mapping the CLI already owns and risk
  drifting out of date.
- **`WM_MODEL` interaction.** An orchestrator-level model request for one
  spawn must not be confused with, or accidentally set, the process-wide
  `WM_MODEL` default - it should map only to that single `bin/spawn-crew`
  call's `--model` flag, leaving `WM_MODEL` (and therefore every other spawn
  without an explicit request) untouched.
- **Effort flag has the identical gap.** `--effort <low|medium|high|xhigh|max>`
  is implemented in `bin/spawn-crew` alongside `--model` and has the exact
  same absence from the lead recipe example and the command vocabulary. Worth
  fixing in the same pass for consistency, but is a separate acceptance item,
  not a blocker for this ticket - flag as a follow-up if not bundled in.

## Non-goals

- No change to `bin/spawn-crew`'s flag parsing, precedence logic, or launch
  script generation - that machinery is already correct and tested.
- No new model-alias validation/resolution layer in wingman itself.
- No change to how a crew member's own model can be changed *after* it is
  spawned (e.g. via `/model` inside its own session) - this ticket is about
  the spawn-time choice only.

## Suggested next step

This is scoping only. On approval, the smallest next step is a documentation
and orchestrator-behavior change (a `CLAUDE.md` command-vocabulary entry, a
`playbooks/common/lead.md` recipe/behavior update, and an optional
`.claude/commands/spawn.md` grammar update) plus a short investigation of the
invalid-model failure path - no `bin/spawn-crew` code change is anticipated.
A `software-analyst` → `developer` handoff (or a single `developer` given
this ticket directly, since the scope is small and mostly documentation) is
sufficient; no `architect` phase is warranted.
