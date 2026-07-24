---
description: Send a follow-up message into a crew member's live session
argument-hint: <crew-id> <message>
allowed-tools: Bash(bin/crew-say:*)
---

Parse the first token of `$ARGUMENTS` as `<id>`, the rest as `<message>`.
Run `bin/crew-say "<id>" "<message>"`.
`crew-say` already owns the team guardrail (I may only message my own direct
reports, a sibling under the same lead, or my own lead) and the dialog-freeze
refusal (it declines to send if the target's pane looks like a permission
dialog rather than an idle chat input) - relay either refusal verbatim if it
happens, do not retry with `--force` on my own judgment. A refused or
unconfirmed message is QUEUED automatically (`~/.wingman/outbox/<id>/`) and
the watcher retries it once the pane clears, so a refusal needs no manual
re-send - just relay it.
