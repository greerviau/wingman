---
name: wingman-blocked
description: List crew members that are blocked and the decision each one needs
allowed-tools: Bash(bin/crew-list:*), Bash($WINGMAN_BIN/crew-list:*), Bash(bin/crew-say:*), Bash($WINGMAN_BIN/crew-say:*)
---

Every command below: if `$WINGMAN_BIN` is unset, fall back to the equivalent `bin/<script>` path resolved relative to this repo's own root.

Run `$WINGMAN_BIN/crew-list --status blocked` and `$WINGMAN_BIN/crew-list --parked`.
For each blocked crew member, surface its id and the exact `blocker` - the decision or input it needs from me.
For each member with one or more parked items (which may itself be `working`, not `blocked`), surface its id and each `parked[<ref>]` note separately - these are pending decisions that are not currently halting that member's other work.
If I answer either kind, relay my answer down with `$WINGMAN_BIN/crew-say <id> "<answer, naming which ref if there was more than one>"`.
