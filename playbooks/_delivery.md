# Delivery (roles that ship code as a branch/PR)

This fragment is appended to your brief because your role produces a code change that needs to be delivered and shepherded to a conclusion.

**Follow the project's and the human's own delivery workflow first.**
You are a real session running in the target project, so you have already loaded the human's own `CLAUDE.md`, any development-workflow doc it points you at, and their skills.
If they define how work gets isolated, published, reviewed, and landed, follow that - it takes precedence over anything here.
What follows is the **default** to fall back on only when the environment defines no workflow of its own; treat it as sensible defaults, not a mandate, and do not let it override a convention the human already has.

Two things here are **not** defaults you can drop, because the coordination layer depends on them regardless of which workflow you follow:

- **Register your worktree path.** However you create your isolated workspace, record where it is with `$WINGMAN_STATE crew-set --id "$WINGMAN_CREW_ID" --worktree <path>` so teardown can find it. (If `$WINGMAN_WORKTREE` is set - a repo-scoped spawn - that is the path already expected; using it means no registration call is needed.)
- **Report state per the status contract** (appended below) - `working`/`blocked`/`review`/`done` - the same way every role does.

## What "delivered" looks like (deliverable shape)

The shape of your deliverable depends on the target, which `$WINGMAN_IS_GIT` and (when it is true) `$WINGMAN_HAS_REMOTE` tell you.
If both are unset (a global-scope spawn or a resumed session), detect it yourself for the directory you work in: `git -C . rev-parse --show-toplevel` succeeds iff it is a git repo, and `git -C . remote get-url origin` succeeds iff it has a remote named `origin`.
Never treat unset as `false`.

- **`IS_GIT=true, HAS_REMOTE=true`** - isolate in your own workspace off a fresh default branch, implement, and open a PR; then shepherd it to merge or close (below).
- **`IS_GIT=true, HAS_REMOTE=false`** - isolate and commit, but there is nowhere to push or open a PR against; stop after committing, park in `review`, and wait for the requester's acceptance via `bin/crew-say`. `done` on acceptance.
- **`IS_GIT=false`** - write your change as plain files in the project directory; park in `review` and wait for acceptance via `bin/crew-say`. `done` on acceptance.

## Default flow (when the environment defines none)

### Isolate

Work in your own isolated workspace, on a new `<feat|fix>/<short-description>` branch off origin's freshly-fetched default branch, so your setup never races with or clobbers the primary checkout.
However you create that workspace, register the path you actually used (see "Register your worktree path" above) so teardown can find it.
Do this every time you start, including on a resumed or re-taken-over session, so your base is always current with origin.
If `$WINGMAN_WORKTREE` is unset (a global-scope session), pick a path yourself - if the target happens to be the wingman repo itself, name it `<repo-path>-<crew-id>` (the same convention repo scope uses) so it stays covered by wingman's own CLAUDE.md exclusion (`bin/spawn-crew`, issue #213).

### Publish and open a PR

Commit in reviewable stages if the scope is large, then push the branch and open the PR with `gh pr create` (or your forge's CLI).
Write the PR the way this project writes PRs - its own template, and whatever conventions your session already carries for one - rather than to a structure invented here.
Two properties hold whatever that structure turns out to be: the body is **evergreen** (no version-bump or otherwise narrow details that go stale), and it does not advertise itself as agent-generated.
Follow `playbooks/_status-contract.md`'s "PR-facing content" rules.
If your role produces a separate deliverable file (a results file, methods note, or spec), point the PR body at it.
Record the PR as your `--delivery`.

## Getting review feedback (the default is your owner's own channel, not the PR)

**Inter-agent review runs over your owner's own channel.** When a reviewer looks at your work, its verdict and findings reach you as a `bin/crew-say` message (its findings file is its `artifact`), not as PR-thread comments - you are woken by that incoming message while parked in `review`.
Address the feedback in your workspace, push, and report back the same way (`bin/crew-say` to whoever asked), letting your status settle back to `review`.
You do not reply on PR threads by default, and a reviewer does not post to the PR by default; nothing about the review is written to GitHub.

**Writing to the PR is opt-in** (`pr_comments`), read the same way as any other run preference:

```
$WINGMAN_STATE pref-get --run-id "$WINGMAN_RUN_ID" --key pr_comments
```

Only when it prints `on` do you also reply on PR threads for feedback that arrived there: reply inline, threaded to the specific review comment when the point was code-anchored, and use one top-level `gh pr comment` only for feedback that wasn't anchored to a line; open every reply body with `<!-- wingman-crew:$WINGMAN_CREW_ID -->` (it must be first in the body - see `bin/pr-watch`'s header comment for why).
Keep each reply short and specific - one or two sentences naming exactly what changed and where - never a paragraph restating the diff, and reply to every point raised even one you didn't act on, with the specific reasoning.
When it is `off`, unanswered, or unaskable, write nothing to the PR; all feedback stays on your owner's channel.

## Shepherding a PR (when there is one)

After the PR is up you shepherd it toward merge or close - fix CI, resolve conflicts, address review feedback - but **you press the merge button yourself only when this effort has been explicitly granted `allow_merge`** (see Merge authorization).

Watching the PR is optional and forge-specific.
`bin/pr-watch` is one available dependency-watcher for PR-shaped delivery; arm it as a harness-tracked background task per the wake loop in `playbooks/_status-contract.md` when you want to be woken on forge state - on its own, **never foreground, and never detached** (`nohup`, `setsid`, a trailing `&`): `pr-watch` blocks until an event fires, so any other way of running it wedges this session indefinitely, invisible to the stall detector (issue #202). **If you cannot arm it as a background task, arm nothing** - no watcher at all is strictly better than a foreground one.

```
$WINGMAN_BIN/pr-watch --pr <PR URL or number>
```

It blocks and exits with one reason line the instant something actionable happens:

- **`ci-failed: <pr> <checks>`** - read the failing job's logs, fix the cause, push.
- **`conflict: <pr>`** - the base moved; rebase or merge the default branch into your branch, resolve, and push. This is yours to fix like a failing check, never reported upward.
- **`checks-passed: <pr>`** - the PR has settled green (or the repo has no CI) and you do **not** currently hold `allow_merge` for this effort; ready for human eyes.
- **`merge-ready: <pr>`** - the identical settle, but you **do** hold `allow_merge`: attempt `gh pr merge` immediately as your next action (see "Merge authorization" below) - this is not something to wait for a human or lead to prompt. It also fires on the next poll if `allow_merge` is granted *after* the PR already settled (the ordinary way autonomy actually gets granted), with no dependency on any further PR-side change.
- **`merged: <pr>`** / **`closed: <pr>`** - terminal; clean up (below), the engagement is over.
- **`changes-requested: <pr>`** / **`comment: <pr> …`** - these only occur when review is happening *on* the PR (`pr_comments=on`); in the default flow review feedback arrives via `bin/crew-say` instead, and you are woken by that message rather than by pr-watch. Handle a PR-thread event the same way: address it in your workspace, push, and (only under `pr_comments=on`) reply on the thread.

A developer whose delivery has no forge signal to watch (no remote, or a workflow that doesn't use PRs) arms no watcher and simply idles in `review`, since feedback arrives as a message.

### Merge authorization

By default you **cannot** merge this PR - a `PreToolUse` hook (`hooks/no-merge-guard.sh`) denies `gh pr merge`, a `gh api` call hitting the merge endpoint, and a direct push to the default branch, from every crew session.
This is deliberate: you never merge without the human's explicit, per-effort authorization, because your session acts under the human's own GitHub credentials, and an unauthorized agent merge would be indistinguishable from the human's own.
Once the PR is green, `review` is where you stop and wait; the human merges it directly, or grants **this specific effort** merge autonomy (`allow_merge: true` on your record - set only by the human or your owner, never by you on yourself).

**Once granted, attempting the merge is your own next action, not something you wait to be prompted for.** `pr-watch` re-reads your own crew record on every poll, so the moment the PR is green/mergeable and `allow_merge` is true it fires `merge-ready` (see "Shepherding a PR" above) instead of `checks-passed` - on that event, run `gh pr merge` immediately. If `allow_merge` is already true at the moment you first settle into `review`, the same `merge-ready` event fires right then, so there is no separate "settle first, merge later" step to remember.

**Merging requires more than `allow_merge: true`.** Once autonomy is granted, the same hook also requires verifiable evidence of a genuinely separate approving review before a merge succeeds: a real, distinct-account `APPROVED` GitHub review, or the documented comment-fallback verdict from a **different**, real `reviewer` whose own `--delivery` names this PR.
That evidence lives on the forge, so **auto-merge requires `pr_comments=on` for this effort** - the reviewer must record its verdict on GitHub for the gate to see it.
If your effort genuinely needs to merge with no review round at all, that is `review_gate_waived: true` (same actor restriction as `allow_merge`). **This waiver clears wingman's own evidence check only** - if the repository's own branch ruleset separately requires an approving review, the waiver does not and cannot clear that: it is a second, independent gate enforced by GitHub, not by wingman, and no wingman-side field reaches it. Because every crew session shares one forge login while GitHub refuses self-approval (issue #50), such a rule is unmeetable by construction here, not merely unmet - see `docs/guards.md`'s "Two merge gates, not one".
If it is granted and satisfied, `gh pr merge` succeeds, and a `PostToolUse` hook (`hooks/merge-attribution-tracker.sh`) automatically posts a PR comment attributing the merge to you (disclosing that an agent, not the human, merged under the human's credentials) - do not add that marker yourself.

Before reporting `blocked` for **any** blocked or failed merge - whether `hooks/no-merge-guard.sh` denied it or GitHub itself refused it - run `$WINGMAN_BIN/lib/merge-block-diagnose.sh --pr <your PR URL>` and put its verdict and named remedies into your `blocker`, so the human is asked once for everything actually needed rather than one grant at a time:

- **`self-fix`** means the block is yours to fix: a merge conflict, a branch behind its base, or a draft PR. Fix it and retry - do not escalate, exactly as with a routine CI failure.
- **`wingman-gate`** means only wingman's own guard objects; the `blocker` names the missing grant.
- **`forge-gate`** or **`both-gates`** means at least part of the remedy is **operator-only** (the forge's own gate needs an operator-side remedy - an admin override, a genuinely distinct reviewer credential, or a relaxed ruleset); say so explicitly in the `blocker` and name it, rather than asking for `review_gate_waived` alone and discovering the rest on the retry. `both-gates` needs both remedies, asked for in one round.
- **`unknown`** means the diagnostic could not determine the cause; say that plainly rather than guessing at a remedy.
- Never work around the guard - an available bypass (the diagnostic's `bypass: AVAILABLE` line) is not a granted one; this covers `--admin` exactly as it covers everything else `hooks/no-merge-guard.sh` denies.

### State mapping

While you are writing code, fixing CI, or waiting for checks you triggered, there is active work in flight, so you are **`working`**.
Once the PR is green and it is on the humans to review, you are delivered-and-waiting, so you park in **`review`**.
A review comment or requested change (via `bin/crew-say`, or a PR thread under `pr_comments=on`) pulls you back to **`working`**; when you settle green again you return to **`review`**.
A `merge-ready` event is the same shape: it pulls you back to **`working`** while you attempt the merge, and either resolves to **`done`** (the merge succeeds, `merged` fires) or drops you into **`blocked`** (the evidence gate denies it - see Merge authorization) - never straight back to a silent `review`.
The PR merging or closing is your terminal condition - **`done`**, and your owner closes you out.
Raise `blocked` only for a genuine decision you cannot make; routine CI fixes and feedback replies are yours to handle.

The **first** time you settle into `review` for this PR, announce it normally.
Every later return to `review` triggered by your own self-managed churn (a resolved `ci-failed`/`conflict`) is silent - use `crew-set --status review --silent` (see `playbooks/_status-contract.md`, "Re-entering `review` without re-announcing").
A return that answers feedback your owner sent you via `bin/crew-say` **does** announce normally - they're waiting to hear it.

**On (re)start with a PR already open** (e.g. resumed after your window died): do not open a second PR.
Find your existing PR for the branch, set your state to match, and rejoin the watch loop if you were using one.

## Cleanup

Clean up your isolated workspace on merge/close (or when stood down) the way the human's workflow prescribes; the default, if you made a plain git worktree, is:

```
git worktree remove "$WINGMAN_WORKTREE"
```

(Keep the branch/PR; only the local worktree is cleaned up.)
This graceful removal is your responsibility; if you exit non-gracefully, `crew-standdown` force-removes the worktree from the recorded path as a backstop - which is why registering the path (above) matters whatever tool created it.
