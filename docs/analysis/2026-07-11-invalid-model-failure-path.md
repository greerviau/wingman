# Investigation: what happens when `--model` is invalid

Date: 2026-07-11.
Scope: the edge case in `docs/tickets/2026-07-11-per-spawn-model-override.md` -
whether an invalid `--model` value surfaces as `died`, and whether that's
distinguishable enough for the pilot to know "bad model name" was the cause
without attaching to the pane.

## Method

Reproduced end-to-end against the actual `claude` CLI (v2.1.207), first
headless (`--print`), then inside a real tmux window using the same launch
shape `bin/spawn-crew` generates (`claude --model <bad> --session-id <sid>
--permission-mode bypassPermissions --name <slug>`, no `--print`).

## Finding: it surfaces as `stalled`, not `died`

The CLI does **not** reject an unrecognized `--model` value at startup. The
TUI opens normally, the invalid model name is shown verbatim in the welcome
header, and the session sits at an idle prompt waiting for input - the
process and its tmux window stay alive.

The rejection happens per-turn instead: when a message is submitted, the
model call fails and the CLI renders a synthetic assistant reply in the chat
("There's an issue with the selected model (`<value>`). It may not exist or
you may not have access to it. Run `/model` to pick a different model.") and
returns to the idle prompt. No tool call runs, so a crew member launched this
way never reaches its own first `wm-state crew-set` - the opening objective
`bin/spawn-crew` sends becomes that first rejected turn.

Consequences for wingman's status machinery:

- The window never closes, so `wm-state reconcile`'s death-flip (comparing
  the roster against live tmux windows) never fires - **`died` does not
  occur** for this failure mode via the normal interactive spawn path.
- The status file was seeded to `working` at spawn (`crew-add`) and is never
  updated, so the member goes silent on both channels `bin/watch-fleet`'s
  stall backstop checks: no pane repaint (the pane is static once the error
  renders) and no status update. After `STALL_IDLE` (180s default) with no
  execution found in the pane's process tree, `wm-state stall-check` flips it
  to **`stalled`**.
- The `stalled` reason text is generic ("no pane output, status update,
  running child process, or CPU activity...") and appends `(last summary:
  ...)` only if the member had ever self-reported - it hadn't, so the reason
  alone does not name the model as the cause. `bin/crew-list` /
  `bin/watch-fleet` cannot distinguish this from any other cause of silent
  stall by text alone.

(A headless/`--print` invocation *does* exit non-zero immediately on an
invalid model, and does not leave a resumable session behind in that
condition - but `bin/spawn-crew` never launches with `--print`, so this path
is not what a pilot will hit.)

## Is it diagnosable?

Yes, via the same remedy already documented for any `stalled` member:
`bin/crew-takeover <id>`. Because the window is alive (unlike a genuine
`died`), takeover resolves to `tmux attach`, and the model error is sitting
directly in the pane's chat transcript - immediately legible to a human, no
guessing required. This matches the ticket's anticipated resolution ("this
may only need a documentation fix... tell the pilot to check via
`bin/crew-takeover`"), just under `stalled` rather than `died`.

## Disposition

No code fix. `CLAUDE.md`'s "Crew stalled" command-vocabulary entry now notes
this specific cause and points at `bin/crew-takeover` as the diagnosis path,
which is sufficient: the failure is silent but not opaque once inspected, and
it already flows through machinery (`stalled` + takeover) that exists for
other silent-failure causes. No new alias-validation layer, and no change to
`wm-state reconcile`/`stall-check`, is warranted - consistent with the
ticket's non-goals.
