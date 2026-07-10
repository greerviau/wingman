---
description: Clean the roster by removing fully-closed crew records (archived first)
argument-hint: "[--all-terminal] [--older-than-days N] [--dry-run]"
allowed-tools: Bash(bin/crew-prune:*)
---

Run `bin/crew-prune $ARGUMENTS` to clean the roster.
By default it removes only fully-closed (`stood-down`) records, archiving each to
`~/.wingman/crew-archive.jsonl` first so nothing is lost.
`--all-terminal` also removes `died` records; `--older-than-days N` restricts to
records last updated more than N days ago; `--dry-run` shows what would go without
changing anything.
Report how many records were pruned (or, for `--dry-run`, what would be removed).
