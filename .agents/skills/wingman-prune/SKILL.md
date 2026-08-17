---
name: wingman-prune
description: Clean the roster by removing fully-closed crew records (archived first)
argument-hint: "[--all-terminal] [--older-than-days N] [--dry-run]"
allowed-tools: Bash(bin/crew-prune:*), Bash($WINGMAN_BIN/crew-prune:*)
---

Run `$WINGMAN_BIN/crew-prune $ARGUMENTS` to clean the roster (if `$WINGMAN_BIN` is unset, fall back to `bin/crew-prune` resolved relative to this repo's own root).
By default it removes only fully-closed (`stood-down`) records, archiving each to `~/.wingman/crew-archive.jsonl` first so nothing is lost.
`--all-terminal` also removes `died` records; `--older-than-days N` restricts to records last updated more than N days ago; `--dry-run` shows what would go without changing anything.
Report how many records were pruned (or, for `--dry-run`, what would be removed).
