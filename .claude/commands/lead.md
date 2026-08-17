---
description: Appoint a lead to own a large, end-to-end effort with its own crew
argument-hint: <objective> (or <repo-or-global> <objective>)
allowed-tools: Bash(bin/spawn-crew:*), Bash($WINGMAN_BIN/spawn-crew:*), Bash(bin/discover-projects:*), Bash($WINGMAN_BIN/discover-projects:*)
---

Appoint a **lead** to own this effort end-to-end: `$ARGUMENTS`.
Every command below: if `$WINGMAN_BIN` is unset, fall back to the equivalent `bin/<script>` path resolved relative to this repo's own root.

A lead runs its own crew (software-analyst → architect → developers → reviewer), sequences the phases, integrates the results, and rolls a single status line up to me.
Use this for a large, multi-phase, or multi-repo effort; for a small single-role task use `/spawn` instead.

Parse the arguments: if the first token names a repo (resolve it via `$WINGMAN_BIN/discover-projects`), spawn the lead there; otherwise, if the work spans repos or the repo is unclear, ground it globally.
Then run one of:

`$WINGMAN_BIN/spawn-crew --type lead --repo <repo> --objective "<the whole effort>"`
`$WINGMAN_BIN/spawn-crew --type lead --scope global --objective "<the whole effort>"`

Give the lead the **full** objective (not a decomposed piece) - it decomposes and hires its own crew from there.
Then arm the watcher if it isn't already live, tell me the lead's crew id, and return control.
From then on surface only the lead's rolled-up line; I can drill into its team with `/status --owner <lead-id>` or `/status --tree`.
