---
description: Ask a delegate a direct question and wait for its captured answer
argument-hint: <crew-id> <question>
allowed-tools: Bash(bin/crew-ask:*), Read(~/.wingman/ask/*.json)
---

Parse the first token of `$ARGUMENTS` as `<id>`, the rest as `<question>`.

1. Run `bin/crew-ask "<id>" "<question>"`. This writes the framed question to a
   prompt file, delivers a one-line pointer into the delegate's live session,
   and prints a request id - relay the same team-guardrail refusal as `/say` if
   it refuses. If it instead warns the pointer was QUEUED (the pane was not
   deliverable right now), the watcher retries automatically - still arm the
   await as usual, with a longer `--timeout` if the warning suggests one.
2. Arm `bin/crew-ask await --id <req>` as a harness-tracked background task
   (e.g. Bash `run_in_background`), on its own - never bundled onto another
   command. End the turn once armed.
3. On wake, the fire's stdout is one reason line:
   - `answered: <req> <inline answer>` - the common case. The inline answer is
     already in hand; no further read is needed.
   - `answered: <req> <inline answer> (detail: <path>)` - the delegate replied
     via `--answer-file`; the inline text is truncated. Read `<path>`
     (`~/.wingman/ask/<req>.json`) for the full answer before continuing.
   - `undeliverable: <req> <why>` - the delegate died or vanished before
     replying.
   - `unanswered: <req> <why>` - no reply within the timeout. A late reply is
     still recorded on the request if one lands afterward, so re-read
     `~/.wingman/ask/<req>.json` before spending another delegate turn
     re-asking.

   Continue the work that was waiting on the answer. This is a captured reply
   on its own side channel, not a roster event - do not report it as crew
   status.
