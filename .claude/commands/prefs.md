---
description: Confirm onboarding preferences (remote, artifact_linking, verbosity, direct_spawn_visibility) once per run
allowed-tools: AskUserQuestion, Bash(uv run --no-project --quiet bin/lib/wm-state.py prefs-list:*), Bash(uv run --no-project --quiet bin/lib/wm-state.py pref-set:*)
---

1. If `$WINGMAN_RUN_ID` is unset, do nothing and say nothing - this session was
   not launched via `bin/wingman`, so there is no run to scope answers to.
2. Run `uv run --no-project --quiet bin/lib/wm-state.py prefs-list --run-id "$WINGMAN_RUN_ID"`
   and diff its output against the four required keys: `remote`,
   `artifact_linking`, `verbosity`, `direct_spawn_visibility`.
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

   Then cache each answer:
   `uv run --no-project --quiet bin/lib/wm-state.py pref-set --run-id "$WINGMAN_RUN_ID" --key <key> --value <value>`
