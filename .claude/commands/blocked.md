---
description: List crew members that are blocked and the decision each one needs
allowed-tools: Bash(bin/crew-list:*)
---

Run `bin/crew-list --status blocked`. For each blocked crew member, surface its id
and the exact `blocker` - the decision or input it needs from me. If I answer,
relay my answer down with `bin/crew-say <id> "<answer>"`.
