---
name: wingman-takeover
description: Print the exact command to take the wheel of a crew member
argument-hint: <crew-id>
allowed-tools: Bash(bin/crew-takeover:*), Bash($WINGMAN_BIN/crew-takeover:*)
---

Run `$WINGMAN_BIN/crew-takeover $ARGUMENTS` (if `$WINGMAN_BIN` is unset, fall back to `bin/crew-takeover` resolved relative to this repo's own root) and relay the command it prints so I can take the wheel.
Remind me I detach with `Ctrl-b d` to hand back, and that the crew keeps running either way.
