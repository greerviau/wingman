---
description: Stand down a crew member (wrap up, close its window, mark stood-down)
argument-hint: <crew-id>
allowed-tools: Bash(bin/crew-standdown:*)
---

Stand down the crew member `$ARGUMENTS`: run `bin/crew-standdown $ARGUMENTS`.
Confirm the window is closed and the roster is updated. Standing down a lead
cascades to its whole sub-crew, closing every window. The crew cleans up its own
git worktree per the developer playbook.
