---
description: Launch a crew member of any type (any crew/ playbook)
argument-hint: <type> <repo-or-global> <objective>
allowed-tools: Bash(bin/spawn-crew:*), Bash(bin/discover-projects:*)
---

Launch a crew member for this directive: `$ARGUMENTS`.

Parse the first token as the crew **type**, the second as the target **repo**
(resolved via `bin/discover-projects` if it's a name), and the rest as the
**objective**. If a plan/spec file path is given, pass it as `--input`. Then run:

`bin/spawn-crew --type <type> --repo <repo> --objective "<objective>" [--input <path>]`

If the second token is `global` (or the work spans repos / has no single target
repo), ground at global project scope instead:

`bin/spawn-crew --type <type> --scope global --objective "<objective>" [--input <path>]`

If the type isn't recognized, run `bin/spawn-crew --list-types` to show the
available crew types and ask me which to use. Tell me the crew id you launched,
then return control.
