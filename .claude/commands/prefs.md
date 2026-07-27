---
description: Confirm onboarding preferences (remote, artifact_linking, verbosity, direct_spawn_visibility, pr_comments) once per run
allowed-tools: AskUserQuestion, Bash(uv run --no-project --quiet bin/lib/wm-state.py prefs-list:*), Bash(uv run --no-project --quiet bin/lib/wm-state.py pref-set:*)
---

1. If `$WINGMAN_RUN_ID` is unset, do nothing and say nothing - this session was
   not launched via `bin/wingman`, so there is no run to scope answers to.
2. Run `uv run --no-project --quiet bin/lib/wm-state.py prefs-list --run-id "$WINGMAN_RUN_ID"`
   and diff its output against the five required keys: `remote`,
   `artifact_linking`, `verbosity`, `direct_spawn_visibility`,
   `pr_comments`. These are the same keys `WM_PREF_KEYS` lists in
   `hooks/lib/pilot-prefs.sh`, which is what the guard enforces - if the two
   ever disagree, that file is authoritative and this one is stale.
3. If nothing is missing, do nothing.
4. Otherwise, say "Before I start working, I need to ask you some preference
   questions:" and call `AskUserQuestion` **once**, batching only the
   still-missing questions into that single call - never split across
   multiple calls:
   - **`remote`**: "Are you watching this session locally, or over Remote
     Control right now?" - *Local at this machine* (`false`) / *Remote
     Control* (`true`).
   - **`artifact_linking`**: "For markdown deliverables (plans/reports), do
     you want them also published as a hosted Artifact link, or just the
     local file path?" - *Also publish as Artifact* (`artifact`) / *Local
     path only* (`local`).
   - **`verbosity`**: "How much should I narrate my own reasoning and
     routing decisions as I work?" - *Concise (state what, not why - the
     default)* (`concise`) / *Detailed (explain reasoning and tradeoffs as I
     go)* (`detailed`).
   - **`direct_spawn_visibility`**: "For work you spawn directly (not
     through a lead) - like a software-analyst and reviewer going back and
     forth on a plan - do you want to see each substantive round as it
     happens, or just the final outcome?" - *Each round (a spawn, a verdict,
     feedback routed - the default)* (`each-round`) / *Summary only (just
     the terminal outcome)* (`summary-only`).
   - **`pr_comments`**: "May crew write to GitHub PRs on your behalf -
     submitting reviews, replying on PR threads, and marking PR provenance -
     or should all inter-agent review feedback stay on wingman's own channel
     (`bin/crew-say`) and off GitHub?" - *Keep it on wingman's channel (the
     default)* (`off`) / *Also write to GitHub PRs* (`on`). Off means a
     reviewer reports its verdict over wingman's own channel and a developer
     takes feedback the same way, with nothing posted to the PR; on restores
     the GitHub-native review flow. Crew auto-merge (a granted `allow_merge`)
     needs verifiable review evidence on the forge, so it requires
     `pr_comments=on` for that effort - see `playbooks/_delivery.md`'s "Merge
     authorization."

   Then cache each answer:
   `uv run --no-project --quiet bin/lib/wm-state.py pref-set --run-id "$WINGMAN_RUN_ID" --key <key> --value <value>`
