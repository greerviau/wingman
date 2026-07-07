---
description: Show the current crew roster (who is on what, what is blocked, what is ready)
allowed-tools: Bash(bin/crew-list:*)
---

Run `bin/crew-list` and give me a compact roster: for each active crew member the
type, id, status, and one-line summary; then a short "needs you" section listing
anything `blocked` (with its blocker) or `done` with a `delivery` ready for review.
Do not dump transcripts or file contents.
