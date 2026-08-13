#!/usr/bin/env bash
# no-merge-guard.sh - a Claude Code PreToolUse hook (matcher "Bash").
# Mechanically enforces issue #46's requirement: "crew must never merge a PR
# unless the pilot explicitly grants merge autonomy for that effort." Two
# things silently made this true before (nobody had asked for it, and the
# convention was only ever prose in a playbook); this hook makes it
# structurally true instead.
#
# What is denied, for every crew session (WINGMAN_CREW_ID set) by default:
#   - `gh pr merge` (any flags: --merge/--squash/--rebase/--admin/--auto/...).
#   - `gh api` hitting the REST merge endpoint with an explicit PUT method
#     (repos/{owner}/{repo}/pulls/{number}/merge) - a GET on the same path
#     only reads merge status and is left alone.
#   - `gh api graphql` carrying a `mergePullRequest(` mutation.
#   - `git push` whose destination resolves to the repository's default
#     branch (origin/HEAD if resolvable, else the conventional main/master
#     pair) - landing commits on the trunk branch directly is the same
#     merge-equivalent action as pressing the merge button, whether or not a
#     PR exists for them. Pushing a crew member's own feature branch (the
#     normal `developer` "Publish" step) is unaffected: only a push whose
#     resolved destination IS the default branch trips this. The directory
#     used to resolve that destination is not unconditionally the hook
#     payload's own cwd: a `cd <path>` (or `git -C <path>`) earlier in the
#     SAME command chain is tracked and takes precedence, since the payload
#     cwd can name an unrelated checkout of the same repo (a worktree) that
#     sits on a different branch (issue #117).
#
# What lifts the deny: the crew member's own crew.json record carries
# `"allow_merge": true` - set only via `wm-state.py crew-set --id <id>
# --allow-merge true`, itself gated below (see check_allow_merge_grant) so
# that only wingman's own top-level session or a lead (granting to one of
# its OWN workers, never itself) can set it - never the crew member on its
# own id. This is deliberately a live per-effort record, not a spawn-time-only
# env var: the pilot saying "you may merge this one" mid-session must not
# require respawning the developer to take effect, and the record is what
# `bin/crew-list` / board.md make visible for audit, satisfying the "explicit,
# per-effort, and visible" requirement from issue #46 without a hidden
# global switch.
#
# issue #132: `allow_merge: true` alone is no longer sufficient. Because every
# crew session authenticates as the same forge account (issue #50), a
# developer granted merge autonomy could post its own comment-fallback
# `VERDICT: approve` (the same shape a genuinely separate reviewer crew
# member uses - see playbooks/software-development/reviewer.md) and treat
# that as satisfying an effort's own "merge once genuinely reviewed"
# instruction - nothing mechanical stopped it. Once `allow_merge` is granted,
# this hook now ALSO requires verifiable evidence of a genuinely separate
# approving review before letting a merge-equivalent proceed:
#   - a real `APPROVED` review state (any author) - GitHub itself refuses this
#     from the PR's own author, so its mere presence is structurally
#     guaranteed to be a different account; or
#   - a same-login comment-fallback verdict (`COMMENTED`, marker-anchored
#     `<!-- wingman-crew:<id> -->`, `VERDICT: approve`) whose `<id>` is NOT
#     this session's own, and resolves to a real roster record with
#     `type == "reviewer"` and a `delivery` naming this same PR - and, when
#     that record carries a spawn-time review-token commitment (issue #135,
#     see below), a matching `wingman-review-proof` marker in the same
#     comment.
# `review_gate_waived: true` (mirroring `allow_merge`'s own grant shape and
# actor restriction exactly - see check_review_gate_waiver_grant) is the
# explicit, per-effort escape hatch for a requester who has personally
# examined the diff and wants no review round at all. This evidence check
# calls `gh pr view` live (see fetch_reviews) - a security-relevant gate, so a
# resolution failure (network hiccup, unresolvable PR/node id) fails CLOSED
# (denied), unlike hooks/merge-attribution-tracker.sh's best-effort posture.
# `review_gate_waived` clears THIS gate only - it has zero effect on a
# forge-side branch ruleset or classic branch protection rule that
# independently requires an approving review, which this hook has no way to
# satisfy or waive (issue #190). See docs/guards.md's "Two merge gates, not
# one" for the distinction, and bin/lib/merge-block-diagnose.sh for the
# diagnostic that tells the two apart before a session escalates.
#
# issue #132 review (PR #134): the evidence check above trusts a roster
# record's `type`/`delivery` fields (crew.json/crew-archive.jsonl) to tell a
# genuine reviewer's comment-fallback approve from a self-dealing one - but
# the FIRST version of this hook left the write paths to those exact fields
# ungated, so the sessions it polices could write the state it trusts. Two
# reproduced bypasses, same root cause:
#   1. `wm-state crew-add` dedups by id (re-adding an existing id silently
#      replaces the whole record), and check_allow_merge_grant/check_review_
#      gate_waiver_grant only ever inspected `crew-set` segments - so a
#      developer could re-add its OWN record with `--allow-merge
#      --waive-review-gate` and merge unreviewed, bypassing the self-grant
#      restriction entirely.
#   2. `crew-add --type reviewer` (to mint a new id) plus `crew-set
#      --delivery <this PR>` (to point it at the PR being merged) were both
#      similarly ungated, so a developer could fabricate a `type: reviewer`
#      roster record with no real, independently-spawned session behind it,
#      post the marker verdict itself under that forged id, and have the
#      evidence check treat it as genuine.
# check_crew_add_restriction() and check_crew_set_delivery_restriction()
# close both: `wm-state crew-add` is grep-confirmed to be called from exactly
# one place in this codebase (bin/spawn-crew, on behalf of wingman or a lead
# spawning one of its own NEW workers) - so ANY crew-add from a live crew
# session is now denied outright, not just the merge-flag-carrying ones. This
# alone closes bypass 1 (crew-add can no longer replace one's own record at
# all) and the minting half of bypass 2 (a fresh sockpuppet id can no longer
# be created either). `--delivery` gets its own restriction (self-id, or
# wingman, only - every legitimate delivery report in this codebase is
# self-targeted, see playbooks/_status-contract.md) closing the remaining
# half of bypass 2: repointing an *existing* other id's delivery at this PR.
#
# issue #136 (round-2 review of PR #134): verify_reviewer_approval() also
# trusts a roster record's `type` field (must equal "reviewer") - exactly as
# security-relevant as `delivery`, but left ungated. check_crew_set_type_
# restriction() extends the identical self/wingman restriction already
# applied to `--delivery` to `--type` for the same reason. `crew-set` does
# not currently define a `--type` flag at all (wm-state.py's crew-add
# subparser is the only place `--type` is accepted, at creation time), so
# this closes a write path pre-emptively rather than one that's reachable
# today - defense-in-depth against a future `crew-set --type` addition
# silently inheriting an ungated write path.
#
# issue #135: even a genuine `type == reviewer` record with a `delivery`
# naming this PR was not enough - shape 2 has no cryptographic binding at
# all, so any crew session that knows a genuine reviewer's id and the PR
# number (both visible via bin/crew-list/board.md and the PR thread itself)
# could post a LATER `COMMENTED` `VERDICT: approve` bearing that reviewer's
# marker, overriding the real reviewer's verdict ("latest wins"). Closed with
# a spawn-time, per-verdict one-way hash commitment: `bin/spawn-crew` mints a
# random 32-byte token for every `--type reviewer` spawn, held only in that
# member's own process environment (`WM_REVIEW_TOKEN`, never written to any
# file); `wm-state crew-add` derives and stores only
# `sha256(sha256(token||id||verdict))` for each of "approve"/"request
# changes" (`review_commit_approve`/`review_commit_request_changes`); the
# reviewer embeds the *preimage* (`$WINGMAN_STATE review-sign --verdict ...`)
# in a second marker line in its own comment; this hook now requires that
# preimage to hash to the recorded commitment before trusting a `VERDICT:
# approve` from a record that carries one. A record with no commitment on
# file (predates this fix, or was hand-spawned with no token) falls straight
# through to the pre-issue-#135 marker-only acceptance, unchanged. The
# commitment is re-derived whenever a live reviewer's `delivery` is
# genuinely repointed at a different PR (`review_delivery_bound`, a
# dedicated monotonic roster field immune to an intervening `--delivery ""`
# clear) so a proof genuinely posted for one PR cannot keep validating
# against another, and whenever `bin/crew-resume` relaunches a `died`
# reviewer (`--regenerate-review-token`, gated below identically to
# `--allow-merge`/`--review-gate-waived` - see
# check_regenerate_review_token_grant) since the crashed process's token is
# unrecoverable. See `bin/lib/wm-state.py`'"'"'s `_apply_review_token` and
# issue #135 for
# the full design and its threat-model boundary (a genuinely snooping peer
# session on this shared-OS-user architecture is explicitly out of scope -
# see that plan's "constraint that shapes every option" section).
#
# issue #138: both #135-closed shapes could still be STALE relative to the
# PR's current head, distinct from forgery - #135 named this as an explicit
# follow-up. A shape-1 `APPROVED` review submitted before new commits landed
# remains genuinely valid GitHub state, but unless branch protection is
# separately configured to dismiss stale reviews on push (invisible to this
# hook), it stays load-bearing after the PR has moved on. A shape-2 proof is
# worse: a byte-for-byte repost of an OLD, genuinely-issued `VERDICT: approve`
# comment still carries a VALID proof (the hash commitment `review_commit_
# approve` was, before this fix, fixed forever per id+verdict, never bound to
# a specific commit) and would win under "latest verdict per marked id wins".
# Two shortcuts were checked and rejected: comparing GitHub's own `commit.oid`
# on a shape-2 review does not help, since a repost is a brand-new review
# object stamped with whatever is HEAD *at repost time*, not what the stale
# text still means; and a plaintext commit marker (or a hash of a public
# preimage plus a commit SHA) is forgeable by anyone once the round-1 preimage
# has been seen publicly, which it always has by the time a replay is
# possible. What actually works: `review_commit_approve` must be RE-DERIVED
# per commit by the reviewer's own process (the only holder of the token),
# and the result written to the roster (a location the hook trusts and a
# forging session cannot write) before it counts as current. `review-sign`
# gains a `--commit <sha>` argument (used only for `approve`) that derives a
# commit-bound commitment and persists it, alongside the commit SHA itself
# (`review_commit_approve_sha`), onto the calling session's OWN roster
# record - self-scoped by construction, needing no new hook-side gating, the
# same reasoning #135 already used for `review-sign`'s general lack of
# restriction. Shape 1 now additionally requires the latest `APPROVED`
# review's own `commit.oid` to match the PR's current `headRefOid`; shape 2
# now additionally requires `review_commit_approve_sha` (when present) to
# match it too. Both comparisons fail closed on an empty/unresolvable
# `headRefOid` by construction (no populated commit SHA can ever equal an
# empty string). A record with no commit-bound sign yet (predates this fix,
# or a delivery-change/resume regeneration not yet re-signed for a commit)
# falls through to the pre-issue-#138 behavior unchanged - the same bounded,
# additive backward-compat posture #135 established for its own proof check.
# See issue #138
# for the full design, including the two rejected shortcuts and their exact
# failure modes.
#
# The `--allow-merge` grant check does NOT rely on cmd_match.py resolving the
# call to `wm-state.py` (unlike every other hook in this repo): the
# documented invocation shape is `$WINGMAN_STATE crew-set --id ... `, and
# `$WINGMAN_STATE` arrives at a PreToolUse hook as an unexpanded literal
# token (see issue #49) - resolve_command has no way to see through it today.
# Rather than depend on cmd_match's fix landing first (issue #49 / PR #48 are
# both touching hooks/lib/cmd_match.py concurrently with this hook), the
# grant check matches on token presence within a segment (`crew-set` and
# `--allow-merge` appearing anywhere in it) instead of resolving argv[0] at
# all - correct regardless of how $WINGMAN_STATE is spelled, and it never
# collides with cmd_match.py's own file.
#
# Registered user-level by bin/doctor (crew sessions have their project root
# in other repos, where this repo's project settings never load) - same
# reasoning as the delegation guard and the Artifact-publish contract hooks.
#
# issue #25 stage 3 (12a): the decision logic above is now a transport-
# agnostic function, evaluate_no_merge_guard(), in hooks/lib/guard_policy.py
# - this file is the Claude Code entry point only: the bash pre-gate below is
# UNCHANGED (still Claude-specific, still what determines which commands
# reach the parse-fail-closed fallback - see guard_policy.py's own docstring,
# must-fix 1.3), and the short python block after it collects stdin JSON plus
# env vars into a GuardInput and calls the shared core.
# bash-3.2-safe.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
WM_UV="${WM_UV:-uv run --no-project --quiet}"

INPUT="$(cat)"

# Cheap no-op gate: only a command mentioning one of these words can possibly
# match anything below (gh pr merge / gh api .../merge / mergePullRequest all
# contain "merge"; git push contains "push"; the grant-guards need
# "allow-merge" and "review-gate" respectively; the roster-integrity guards
# (issue #132 review) need "crew-add" and "--delivery" - a bare `crew-add
# --type reviewer ...` or `crew-set --delivery ...` carries none of the other
# trigger words; the review-token grant guard (issue #135) needs
# "review-token", covering both `crew-add --review-token` and `crew-set
# --regenerate-review-token`). Precise matching happens in the python block.
#
# issue #136: `crew-set --type` gets its own, narrower arm rather than being
# folded into the bare-alternative list above. Unlike every other trigger
# word here, a bare `*--type*` alternative would NOT be purely additive:
# `--type` is a common flag on many unrelated CLI tools crew members
# legitimately run in arbitrary repos (e.g. `kubectl ... --type=Opaque`), and
# this hook is registered user-level, firing for every crew Bash call in
# every repo, not just wingman's own. A bare `*--type*` alternative would
# newly expose any unrelated, unparseable command containing `--type` (e.g. a
# quoting slip in an otherwise ordinary kubectl/config-tool invocation) to
# the fail-closed PARSE_FAIL_REASON denial below, despite having nothing to
# do with crew-set, merges, or PRs. Requiring `crew-set` and `--type` to both
# appear (in either order) keeps the pre-gate scoped to actual crew-set
# calls, exactly as tightly as the other trigger words already are.
case "$INPUT" in
  *merge*|*push*|*allow-merge*|*review-gate*|*crew-add*|*--delivery*|*review-token*) ;;
  *crew-set*--type*) ;;
  *) exit 0 ;;
esac

printf '%s' "$INPUT" | \
  WINGMAN_HOME="${WINGMAN_HOME:-$HOME/.wingman}" \
  WINGMAN_CREW_ID="${WINGMAN_CREW_ID:-}" \
  WINGMAN_CREW_TYPE="${WINGMAN_CREW_TYPE:-}" \
  PYTHONPATH="$HERE/lib${PYTHONPATH:+:$PYTHONPATH}" $WM_UV python -c '
import json, os, sys

from guard_policy import GuardDenied, GuardInput, evaluate_no_merge_guard

try:
    data = json.load(sys.stdin)
except Exception:
    data = {}

tool_input = data.get("tool_input", {}) or {}
gi = GuardInput(
    tool_name=data.get("tool_name") or "",
    command=tool_input.get("command", "") or "",
    cwd=data.get("cwd") or os.getcwd(),
    crew_id=os.environ.get("WINGMAN_CREW_ID", ""),
    crew_type=os.environ.get("WINGMAN_CREW_TYPE", ""),
    file_path="",
    notebook_path="",
    project_dir=os.environ.get("CLAUDE_PROJECT_DIR", ""),
    home=os.path.expanduser(os.environ.get("WINGMAN_HOME") or "~/.wingman"),
)

try:
    evaluate_no_merge_guard(gi)
except GuardDenied as e:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": str(e),
        }
    }))
sys.exit(0)
' 2>/dev/null

exit 0
