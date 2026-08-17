---
description: Stand down a crew member (wrap up, close its window, mark stood-down)
argument-hint: <crew-id>
allowed-tools: Bash(bin/crew-standdown:*), Bash($WINGMAN_BIN/crew-standdown:*)
---

Stand down the crew member `$ARGUMENTS`: run `$WINGMAN_BIN/crew-standdown $ARGUMENTS` (if `$WINGMAN_BIN` is unset, fall back to `bin/crew-standdown` resolved relative to this repo's own root).
Confirm the window is closed and the roster is updated.
Standing down a lead cascades to its whole sub-crew, closing every window.
The crew cleans up its own git worktree per the developer playbook.
