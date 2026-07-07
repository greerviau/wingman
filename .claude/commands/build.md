---
description: Spawn a build crew member to implement and ship a plan
argument-hint: <repo> <plan-path> [notes]
---

Spawn a **build** crew member for this directive: `$ARGUMENTS`.

Parse the target repo (first token, resolved via `bin/discover-projects` if it's a
name), the plan path (second token), and any notes (the rest). Then run:

`bin/spawn-crew --type build --repo <repo> --input <plan-path> --objective "<notes or 'implement the plan'>"`

Tell me the crew id and that it's underway; I'll hear back when it sets a
`delivery` (PR ready for review). Then return control.
