---
description: List crew members that are blocked and the decision each one needs
allowed-tools: Bash(bin/crew-list:*), Bash(bin/crew-say:*)
---

Run `bin/crew-list --status blocked` and `bin/crew-list --parked`.
For each blocked crew member, surface its id and the exact `blocker` - the decision or input it needs from me.
For each member with one or more parked items (which may itself be `working`, not `blocked`), surface its id and each `parked[<ref>]` note separately - these are pending decisions that are not currently halting that member's other work.
If I answer either kind, relay my answer down with `bin/crew-say <id> "<answer, naming which ref if there was more than one>"`.
