---
description: Show the current crew roster (who is on what, what is blocked, what is ready)
argument-hint: "[--tree] [--owner <lead-id>]"
allowed-tools: Bash(bin/crew-list:*)
---

Run `bin/crew-list $ARGUMENTS` and give me a compact roster: for each crew member
the type, id, **status**, and one-line summary; then a short "needs you" section
listing anything `blocked` (with its blocker) or in `review` with a
`delivery`/`artifact` ready for me to look at.

By default `bin/crew-list` shows your direct reports (a lead shows as one line).
If I pass `--tree`, run `bin/crew-list --tree` to show the whole org indented; if I
name a lead, run `bin/crew-list --owner <lead-id>` to drill into that lead's team.
`bin/crew-list` shows current crew only - closed history (`stood-down`) is hidden;
only run `bin/crew-list --all` if I explicitly ask to see the history.
Do not dump transcripts or file contents.
