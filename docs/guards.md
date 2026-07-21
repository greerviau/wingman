# Guards, safety, and autonomous mode

How wingman's rules are enforced mechanically rather than by prompt discipline, and how crew run unattended safely.
Part of the [architecture reference](architecture.md); for day-to-day use see the [README](../README.md).

## Mechanical guards

The rules stated in prose across these docs and `CLAUDE.md` are also enforced mechanically, via Claude Code `PreToolUse`/`PostToolUse` hooks in `hooks/`, not left to prompt discipline alone:

- `hooks/no-direct-edit-guard.sh` blocks wingman's own top-level session (and any lead) from editing code or running long investigations directly - heavy work always goes to a crew member.
- `hooks/no-merge-guard.sh` denies `gh pr merge` and equivalents from every crew session unless that specific effort was granted `--allow-merge` - and, once granted, also requires verifiable evidence of a genuinely separate approving review (a real distinct-account `APPROVED` GitHub review, or the documented marker-and-roster-verified comment-fallback `VERDICT: approve` from a different, real `reviewer` crew member, cryptographically bound to that reviewer via a spawn-time hash commitment so a later comment cannot forge its way past the gate under a genuine reviewer's marker - issue #135) before the merge actually succeeds, unless the effort's `review_gate_waived` field was also explicitly granted (issue #132); `hooks/merge-attribution-tracker.sh` posts a PR comment attributing an authorized merge to the crew member that made it (a disclosure invariant, so it fires whenever a crew session actually merges - the opt-in auto-merge path, which requires `pr_comments=on` anyway - and is not itself gated on the preference), and `hooks/pr-open-marker-tracker.sh` prepends the same `<!-- wingman-crew:<id> -->` marker to the body of every PR a crew member opens via `gh pr create` **when `pr_comments=on`** (writing to a PR is opt-in; the marker's only consumer is this review/merge machinery). Inter-agent review is otherwise `crew-say`-native and writes nothing to the forge; because the merge gate reads its review evidence from the forge, an effort granted `allow_merge` needs `pr_comments=on` so a reviewer's verdict is recorded where the gate can see it.
- `hooks/no-watcher-kill-guard.sh` denies a `kill`/`pkill`/`tmux kill-window`/`tmux kill-session` whose target resolves to a live `watch-fleet` cycle, so the wake loop's own process can't be killed by accident.
- `hooks/no-interactive-prompt-guard.sh` denies `AskUserQuestion`, `EnterPlanMode`, and `ExitPlanMode` outright for every crew session (worker or lead) - only the top-level wingman session is ever actually watched by a human in real time, so a crew session calling one of these would hang waiting for a choice nobody is present to make, or have a later-arriving keystroke misread as input to an unrelated pending dialog. The denial redirects to `playbooks/_status-contract.md`'s `blocked` state instead (see "`blocked` for a human dependency" there).
- `hooks/api-outage-spawn-guard.sh` denies new crew spawns while a fleet-wide API outage is detected as active.
- `hooks/usage-limit-spawn-guard.sh` denies new crew spawns while a fleet-wide usage-quota window is approaching its cap or the pilot chose to wait for it to reset; both this and the outage guard share their `PreToolUse` machinery (`hooks/lib/spawn_pause_guard.py`) rather than duplicating it.
- `hooks/artifact-link-guard.sh` and `hooks/artifact-publish-tracker.sh` enforce the Artifact-publish contract - a markdown deliverable is published as a hosted link only when the pilot asked for that and a content scan passes.
- `hooks/pilot-preferences-guard.sh` denies every other tool call in a fresh run until the onboarding-preference questions are answered.

Each of these exists because relying on the equivalent prose instruction alone had already failed at least once in this project's history; the hook is a backstop, not a replacement for the playbook text.

The two spawn-pause guards (outage, usage-limit) react to the fleet-wide state machines described in [fleet resilience](fleet-resilience.md).

## Checkout freshness (advisory, not a hook)

Not every risk this project has hit can be intercepted by a `PreToolUse` hook: "about to assert that file X currently does/doesn't do Y" is a claim made in prose, inside a plan or a review finding, not a distinguishable tool call the way `gh pr merge` or an unpublished-artifact report is.
A repo-scoped crew session other than `developer` (which already isolates into a fresh worktree every run) is `cd`'d directly into the target project's existing checkout, which can silently lag `origin/<default-branch>` if nobody has fetched or pulled it recently - a stale read has already produced one confirmed false finding, filed and then retracted as issue #142.
`bin/lib/git-freshness-check.sh` makes the fix to this - checking freshness before making such a claim - cheap and consistent instead of an ad hoc `git log`/`git status` improvisation: it fetches `origin` (read-only against the working tree, index, and `HEAD`) and reports whether the checkout as a whole is caught up with `origin/<default-branch>`, plus, given path arguments, whether each named file's content specifically differs between `HEAD` and `origin/<default-branch>`.
`playbooks/_status-contract.md`'s "Your checkout is a claim, not verified freshness" is the shared convention that tells every git-backed session to run it before asserting a file's current state, with targeted pointers at the three points in the software-development playbooks where this risk is most concentrated (`software-analyst.md`, `reviewer.md`, `architect.md`).

## Autonomous mode and interactive gates

Because no human sits at a crew member's terminal, `bin/spawn-crew` launches each member with `--permission-mode bypassPermissions` (`WM_PERMISSION_MODE`) so a gated tool call auto-approves instead of hanging on a prompt forever.
Set `WM_PERMISSION_MODE=` (empty) to fall back to interactive prompting.

Two one-time interactive gates remain that no flag bypasses:

- Claude Code's Bypass-Permissions acceptance (once, ever).
- Each repo's first-time workspace-trust dialog (once per repo).

`bin/spawn-crew` checks both non-interactively before ever opening a crew window: `bin/lib/claude-gate-check.py` reads `skipDangerousModePermissionPrompt` from the user settings file and `projects[<repo>].hasTrustDialogAccepted` from `~/.claude.json`, the same two fields Claude Code itself persists on acceptance. Trust is hierarchical in Claude Code - accepting it for a directory trusts every descendant - so the trust check walks from the repo path up through each ancestor to `/`, treating the repo as trusted if any of them carries `hasTrustDialogAccepted: true`, not only the exact repo path.
`bin/doctor` is meant to have already cleared the (global) Bypass-Permissions gate during onboarding; `spawn-crew` re-checks it as a safety net, and always checks the (per-repo) trust gate fresh, since trust is granted per directory.
Either check failing refuses the spawn outright - no tmux window, no crew record - with a message naming the exact remedy, rather than opening a window that would only freeze on the dialog.
The watcher's reactive pane-scrape detection (and a per-tool prompt when bypass is off) remains as a backstop for anything this preflight can't cover - a never-before-touched `--add-dir` target in a global-scope spawn, or a signal that drifts after a future Claude Code release - flipping the crew member to `blocked` and waking the pilot to approve once via `bin/crew-takeover`.
After that, crew in that repo run fully unattended.

These two gates are Claude Code's own built-in dialogs, distinct from `hooks/no-interactive-prompt-guard.sh` above: that hook stops a crew session's own turn from opening a *second*, independent human-wait state by calling `AskUserQuestion`/`EnterPlanMode`/`ExitPlanMode` itself, rather than covering a gate Claude Code presents outside any tool call.
