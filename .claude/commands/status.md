---
description: Show the current crew roster (who is on what, what is blocked, what is ready)
allowed-tools: Bash(bin/crew-list:*)
---

Run `bin/crew-list` and give me a compact roster: for each crew member the type,
id, **status**, and one-line summary; then a short "needs you" section listing
anything `blocked` (with its blocker) or in `review` with a `delivery`/`artifact`
ready for me to look at.
`bin/crew-list` shows current crew only - closed history (`stood-down`) is hidden;
only run `bin/crew-list --all` if I explicitly ask to see the history.
Do not dump transcripts or file contents.
