---
name: wingman-status
description: Show the current crew roster (who is on what, what is blocked, what is ready)
argument-hint: "[--tree] [--owner <lead-id>]"
allowed-tools: Bash(bin/crew-list:*), Bash($WINGMAN_BIN/crew-list:*)
---

Every command below: if `$WINGMAN_BIN` is unset, fall back to `bin/crew-list` resolved relative to this repo's own root.

Run `$WINGMAN_BIN/crew-list $ARGUMENTS` and give me a compact roster: for each crew member the type, id, **status**, and one-line summary; then a short "needs you" section listing anything `blocked` (with its blocker), `stalled` (with the takeover / stand-down remedy), in `review` with a `delivery`/`artifact` ready for me to look at, or carrying one or more `parked` annotations (with each ref and note) even while otherwise `working`.

By default `$WINGMAN_BIN/crew-list` shows your direct reports (a lead shows as one line).
If I pass `--tree`, run `$WINGMAN_BIN/crew-list --tree` to show the whole org indented; if I name a lead, run `$WINGMAN_BIN/crew-list --owner <lead-id>` to drill into that lead's team.
`$WINGMAN_BIN/crew-list` shows current crew only - closed history (`stood-down`) is hidden; only run `$WINGMAN_BIN/crew-list --all` if I explicitly ask to see the history.
Do not dump transcripts or file contents.
