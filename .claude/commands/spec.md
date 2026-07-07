---
description: Spawn a spec crew member to turn a problem into a written plan (or a report)
argument-hint: <repo> <what to plan or investigate>
---

Spawn a **spec** crew member for this directive: `$ARGUMENTS`.

Parse the target repo (first token, resolved via `bin/discover-projects` if it's a
name) and the objective (the rest). Then run:

`bin/spawn-crew --type spec --repo <repo> --objective "<objective>"`

If the directive is an investigation of a bug rather than a feature plan, say so in
the objective so the crew uses report mode and reproduces end-to-end first. Tell me
the crew id you launched and that it's underway; then return control.
