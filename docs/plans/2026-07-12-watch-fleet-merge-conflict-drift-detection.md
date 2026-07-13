# watch-fleet: detect and surface merge-conflict drift on crew-delivered PRs

Date: 2026-07-12
Status: ready for implementation
Scope: repo-scoped (`wingman`), single-role (developer implements directly from this plan)

## Problem

`bin/watch-fleet` wakes wingman (or a lead) on state transitions it can observe
from a crew member's own status file: `blocked`, `review`, `done`, `died`,
`stalled`. It has no notion of the *external* fact that a delivered PR has drifted
out of a mergeable state because of what landed on the base branch after the PR
was opened.

This was observed live: PR #34 was opened by a developer, went `review`, and the
member parked there (correctly, per its playbook - watching its own PR is a
"waiting on an external condition" state). While it waited, PR #32 and PR #33
merged into `main`. GitHub recomputed PR #34's `mergeable`/`mergeStateStatus` to
`CONFLICTING`/`DIRTY`. Nothing in the crew member's own status changed - it is
still legitimately `review` - so nothing about its status file changed, so
`needs-attention` never fired, so neither the owning member nor wingman ever
looked. The only way to catch this today is a human running `gh pr view` by hand
on every open delivery, which defeats the purpose of the watcher.

Note that this repo already has a *different* PR watcher, `bin/pr-watch`
(`bin/lib/pr-eval.py`), armed by a developer against its **own** PR to catch
`merged`/`closed`/`changes-requested`/`ci-failed`/`comment`/`checks-passed`. It
polls `gh pr view` but requests only
`state,mergedAt,statusCheckRollup,reviews,comments,number,url` - it never asks
for `mergeable`/`mergeStateStatus`, so it would not have caught this either, even
though the member was actively watching that exact PR. This plan does not change
`pr-watch`; see "Alternatives considered" for why the fix belongs in
`watch-fleet` instead.

## Current architecture (relevant facts)

Read directly from `bin/watch-fleet` and `bin/lib/wm-state.py`:

- **State store.** `~/.wingman/crew.json` is the roster; `~/.wingman/crew/<id>.json`
  is each member's self-reported live status
  (`STATUS_FIELDS = status, summary, blocker, artifact, delivery, updated`,
  `wm-state.py:46`). `merged()` (`wm-state.py:183`) overlays live onto roster.
  `delivery` is a free-text field a crew member sets via `crew-set --delivery`;
  by convention (`playbooks/software-development/developer.md:36`) it is the full
  PR URL printed by `gh pr create`.
- **Attention model.** `ATTENTION_STATES = blocked, review, done, died, stalled`
  (`wm-state.py:65`). `cmd_needs_attention` (`wm-state.py:733`) emits one TSV row
  `id\tstatus\tupdated\tnote` per live roster member whose `status` is in
  `ATTENTION_STATES` and whose `(id, updated)` tuple is not already
  acked/handled. `updated` is the version stamp: every `crew-set` call bumps it,
  and it is what `ack`/`mark-handled` key on to make an event fire exactly once.
- **Dedup stores.** `acked.json` and `handled.json` (`wm-state.py:886`, `:905`)
  are plain `{id: updated}` dicts, generic over the string used as `id` -
  `cmd_ack`/`cmd_mark_handled` never validate that `id` names a real roster
  member. Both use `with_locked` (`wm-state.py:100`) because more than one
  `watch-fleet` cycle (wingman's + every live lead's) and the Stop hook can touch
  them concurrently.
- **`group-attention`** (`wm-state.py:795`) only special-cases rows whose
  `status` is exactly `"died"` or `"stalled"` (for mass-death/API-outage
  collapsing); every other status value passes through unchanged.
- **`fire()`** (`bin/watch-fleet:434`) is fully generic: it formats
  `"<status>: <id> <note>"` reason lines from whatever `needs-attention` (via
  `group-attention`) emits, writes the wake file, and acks each `(id, updated)`
  it surfaced. It does not know or care what status strings exist.
- **The pane-backstop block** (`bin/watch-fleet:486-550`) is the existing
  precedent for the watcher itself, not the crew member, writing into a member's
  live status file (`crew-set --status blocked`, and `stall-check` internally
  writing `status: stalled`). Critically, it only ever touches members that are
  **provably not currently self-reporting** - a member is only pane-checked once
  it is silent (idle beyond `STALL_IDLE`, or frozen on a prompt). It never writes
  into the status file of an actively-turn-taking member. A conflict-detection
  poll cannot rely on that same precondition: `review`/`working` members with an
  open PR are exactly the members that *are* actively self-reporting. Writing
  poll results into `crew/<id>.json` would race the member's own `crew-set`
  calls (`cmd_crew_set` at `wm-state.py:320` does an unlocked read-modify-write).
  This is the key reason the design below uses a **separate store**, not
  `crew/<id>.json`, for merge-conflict state (see Design, "Where state lives").
- **Test conventions.** `tests/pr-watch.test.sh` and `tests/watch-fleet.test.sh`
  establish the pattern: a fake `gh` shell script swapped in via `WM_GH`,
  `tests/lib.sh` helpers (`test_new_home`, `assert_eq`, `assert_contains`,
  `wm_timeout`, `wm_track`/`wm_kill_tracked` for backgrounded blocking loops).

## Design

### Scope of what gets polled

Poll a crew member's delivery iff:
- its current `status` (merged view) is `review` or `working`, **and**
- its `delivery` field, read fresh from the roster on every poll, matches a
  GitHub PR URL (`^https://github\.com/[^/]+/[^/]+/pull/[0-9]+`).

Deliberately excluded, with reasoning:
- **`blocked`/`stalled`/`died`/`stood-down`.** A blocked or stalled member is
  already being escalated for a different reason; a dead or stood-down one has
  no one to relay to. Once a blocked member returns to `working`/`review` it
  re-enters the polled set on its own.
- **`done`.** Per `CLAUDE.md`'s "Member lifecycle" contract, wingman reaps a
  `done` member (`crew-standdown`) in the *same turn* it observes `done` - by the
  time a later watch-fleet cycle could poll it, it is normally already
  `stood-down`. Polling it is not useless but is rarely load-bearing; leaving it
  out keeps the polled set exactly "things a human or agent could still act on."
- **Non-PR `delivery` values** (a bare branch name, a non-GitHub URL). `gh pr
  view` needs either a full PR URL (resolves owner/repo on its own, works from
  any cwd) or repository context this bash loop does not reliably have (it does
  not `cd` into each member's worktree). Restricting to full PR URLs is the
  correct MVP boundary; see "Open questions" for the bare-reference case.

### Where state lives

A new store, `~/.wingman/mergeability.json`: `{ <crew-id>: {"pr": <url>,
"state": "MERGEABLE"|"CONFLICTING"|"UNKNOWN", "checked": <iso8601>,
"conflict_detected": <iso8601 or null>} }`.

- Keyed by the **real** crew id, one entry per member (a member has one
  delivery at a time in practice).
- `state` is GitHub's answer, collapsed to three values (mapping below).
- `checked` is the timestamp of the last successful *or* failed poll attempt -
  it drives the re-poll cadence (below), independent of whether the state
  changed.
- `conflict_detected` is set to `now()` **only on the edge** where `state`
  transitions into `"CONFLICTING"` from something else, and cleared to `null`
  the moment `state` leaves `"CONFLICTING"`. This is the field that drives
  attention: it is this store's analogue of `crew/<id>.json`'s `updated`, but
  scoped to conflict transitions only, so a PR that stays conflicting across
  many polls fires exactly once, and a PR that resolves and later conflicts
  again fires again.
- Read/written only by `wm-state.py` (new subcommands below), guarded by
  `with_locked` exactly like `acked.json`/`handled.json` - **required**, not
  optional, because more than one `watch-fleet` cycle (wingman's + each live
  lead's, each with disjoint owner-scoped members) can poll concurrently
  against this one shared file.

This keeps `crew/<id>.json` untouched by the watcher for any member that is
actively self-reporting, preserving the invariant the pane-backstop code
already relies on.

### `mergeStateStatus`/`mergeable` → `state` mapping

Fetch both fields (`gh pr view --json mergeStateStatus,mergeable,url,number`) and
combine them, since GitHub computes them asynchronously and either can lag:

- `mergeable == "CONFLICTING"` **or** `mergeStateStatus == "DIRTY"` →
  `"CONFLICTING"`.
- both fields absent/`"UNKNOWN"` (and not already conflicting by the rule above)
  → `"UNKNOWN"` - GitHub has not finished computing it yet (common right after a
  push). This must **not** clear an existing `"CONFLICTING"` flag: leave `state`
  and `conflict_detected` untouched when the new observation is `"UNKNOWN"`
  (record `checked` regardless, so the poll cadence still advances).
- anything else (`MERGEABLE` + `CLEAN`/`BEHIND`/`BLOCKED`/`UNSTABLE`/
  `HAS_HOOKS`/`DRAFT`) → `"MERGEABLE"`. This intentionally does not try to
  surface `BLOCKED` (e.g. missing required review) as an attention event -
  that is a normal, expected `review`-state condition, not drift; scope is
  narrowly "this PR no longer merges cleanly against its base," matching the
  incident.

### New `wm-state.py` subcommands

Add alongside the existing `cmd_*` functions, following their exact style
(argparse subparser, `ensure_home()`, `with_locked` where the store is shared):

1. **`mergeability-poll-list --owner <id> --interval <seconds>`** (pure read,
   no mutation). Iterates `merged(r)` for the owner's scope (same `parent_of`
   filter `cmd_needs_attention` uses; owner `""` = top level), keeps rows whose
   `status` is `review`/`working` and whose `delivery` matches the PR-URL
   pattern, and against the current `mergeability.json` decides "due": due iff
   no entry exists for the id, or `entry["pr"] != delivery` (the PR changed -
   always recheck immediately, ignoring the interval), or
   `now - entry["checked"] >= interval`. Emits TSV `id\tdelivery-url` for due
   rows only. This is the single subprocess call `watch-fleet` makes per loop
   iteration to decide what (if anything) is worth a `gh` round trip that
   iteration - it replaces what would otherwise be one Python spawn per member
   per poll just to check "is it due."

2. **`mergeability-set --id <id> (--pr-json <path|-> | --fail)`** (mutates
   `mergeability.json` under `with_locked`). With `--pr-json`, parses the `gh
   pr view` JSON, applies the mapping above, updates `state`/`checked`/`pr` and
   the edge-triggered `conflict_detected`. With `--fail` (the `gh` call itself
   errored - network, auth, rate limit, PR not found), only bump `checked`
   (enforces the backoff interval so a persistent failure is retried at the
   normal cadence, not hot-looped) and leave `state`/`conflict_detected`
   untouched.

3. Extend **`cmd_needs_attention`**: after the existing roster loop, add a
   second loop over `mergeability.json`'s entries. For each `(id, entry)` with
   `entry.get("conflict_detected")` truthy:
   - re-resolve the real member's current merged row from the roster (it must
     still exist and still be `review`/`working` - re-checked at *emission*
     time, not polling time, so a member that has since gone `blocked`/`died`
     since the last poll is not surfaced under this signal);
   - apply the same `--owner` filter as the primary loop, using the real
     member's `parent_of`;
   - suppress using the **same** ack/handled dedup logic as the primary loop,
     but keyed on the synthetic id `"<id>#conflict"` and `updated =
     entry["conflict_detected"]` - never the real id, so a conflict event and a
     status event for the same member are independent timelines and cannot
     clobber each other's ack state;
   - emit `"<id>#conflict"\t"conflict"\t<conflict_detected>\t<note>"`, where
     `note` explicitly names the real id and the action, e.g.: `PR
     https://github.com/o/r/pull/34 now shows merge conflicts with main
     (mergeStateStatus=DIRTY) - relay to devA via bin/crew-say; do not resolve
     it yourself.`

   Factor the ack/handled suppression check (currently inlined in the primary
   loop, `wm-state.py:775-785`) into a small helper used by both loops, to
   avoid duplicating the `suppress_on`/`only_acked` branching.

   No changes are needed to `group-attention` or `fire()` - both are already
   fully generic over `(id, status, updated, note)` rows (verified by reading
   both; `group-attention` only pattern-matches `status == "died"` or
   `"stalled"`, everything else passes through). No changes are needed to the
   Stop hook or `ack`/`mark-handled` - they are generic string-keyed stores and
   will ack/mark-handle `"<id>#conflict"` exactly like any other id, because
   `fire()`'s per-row ack loop and the Stop hook's `mark-handled` loop both
   iterate whatever `needs-attention` printed.

4. **Cleanup on teardown.** Extend `cmd_standdown` and `cmd_prune` to also
   delete, for every id being stood down / pruned: its `mergeability.json`
   entry, and the `"<id>#conflict"` key from both `acked.json` and
   `handled.json` (all three under their respective `with_locked` sections).
   Without this, a member that is reaped while mid-conflict leaves a permanent
   stale entry that `needs-attention`'s new loop would otherwise keep skipping
   only because the roster-lookup re-check (point 3 above) already excludes
   ids no longer in `review`/`working` - so this is hygiene (bounded file size,
   no confusing leftover `board.md`/`crew-list` output) rather than a
   correctness requirement, but it is cheap and matches how `prune` already
   archives-then-removes.

### `watch-fleet` (bash) changes

Add near the existing tunables (`bin/watch-fleet:105-133`):

```sh
GH="${WM_GH:-gh}"
MERGE_CHECK_INTERVAL="${WM_MERGE_CHECK_INTERVAL:-120}"
```

`WM_GH` reuses the exact knob `pr-watch` already defines, so one env var
retargets both watchers to a wrapper or another forge CLI. 120s (~24 poll
cycles at the default 5s `INTERVAL`) is a deliberately conservative default:
merge-conflict drift is caused by *other PRs merging*, which does not happen on
sub-minute timescales, and `gh pr view` is a single lightweight authenticated
call, but the fleet may have many concurrent deliveries and this must never be
the thing that trips a rate limit or adds latency to the common "nothing to do"
poll.

Whether `gh` is usable is checked once, before the loop (`wm_have "$GH"`); if
absent, the whole feature is silently inert (no error - `gh` is optional
infrastructure pr-watch already treats as best-effort-present, not a
`watch-fleet` hard dependency).

Add a new block in the main loop (`bin/watch-fleet:477-564`), placed after the
existing pane-backstop block and before the closing `needs-attention` check, and
**not** gated on `wm_tmux has-session` (unlike the pane-backstop, this needs no
tmux access at all):

```sh
if [ "$MERGE_CHECK_ENABLED" = 1 ]; then
  _due="$(wm_state mergeability-poll-list --owner "$OWNER" --interval "$MERGE_CHECK_INTERVAL" 2>/dev/null)"
  printf '%s\n' "$_due" | while IFS=$'\t' read -r _id _url; do
    [ -n "$_id" ] || continue
    if _pr_json="$($GH pr view "$_url" --json mergeStateStatus,mergeable,url,number 2>/dev/null)" && [ -n "$_pr_json" ]; then
      printf '%s' "$_pr_json" | wm_state mergeability-set --id "$_id" --pr-json - >/dev/null 2>&1
    else
      wm_state mergeability-set --id "$_id" --fail >/dev/null 2>&1
    fi
  done
fi
```

(`MERGE_CHECK_ENABLED` set once before the loop from `wm_have "$GH"`.) This is
one Python spawn (`mergeability-poll-list`) plus, only for members actually due
this cycle, one `gh` call and one Python spawn each - not one Python spawn per
member per 5s tick. The subsequent unmodified `needs-attention` call at the
bottom of the loop picks up any freshly-set `conflict_detected` on its own; no
extra wiring is needed to connect the poll to the fire.

### Auth / rate-limit handling

- `gh` missing entirely → feature inert (checked once, `wm_have`).
- `gh pr view` failing (expired auth, revoked token, rate-limited, PR
  deleted/404, transient network error) → indistinguishable at this layer, and
  all are handled the same way: `--fail` bumps only `checked`, so the next
  attempt is naturally deferred to the next `MERGE_CHECK_INTERVAL` window
  rather than retried every 5s. No error is surfaced to wingman - a single
  member's conflict-check going dark is not an attention-worthy event by
  itself (unlike the existing API-error nudge, which watches the *crew
  session's own* pane for a stuck agent). If `gh` auth is broken fleet-wide,
  every due member fails identically every interval, silently - this is an
  accepted MVP gap; see "Open questions."
- Load shape: with the default 120s interval and a realistic fleet size (single
  digits to low tens of concurrent deliveries per owner), this is at most ~1
  `gh` call per member every 2 minutes - far under GitHub's authenticated REST
  rate limit (5000/hr) even fully saturated.

### Display: `crew-list` and `board.md`

Add a small helper in `wm-state.py`, `load_mergeability()` (reads
`mergeability.json`, `{}` on missing/invalid), and call it once in
`cmd_crew_list` and `render_board` to annotate each row's dict with
`merge_conflict` (bool) and `merge_checked` (the stored timestamp, or `None`)
before rendering - a pure display annotation, not persisted back to
`crew.json`/`crew/<id>.json`.

- `render_roster_text` / `render_tree_text` (`wm-state.py:1104`, `:1121`):
  alongside the existing `if r.get("delivery"): lines.append("delivery: ...")`,
  add `if r.get("merge_conflict"): lines.append("      CONFLICT: merge
  conflicts with main (checked %s)" % r.get("merge_checked"))` (indentation
  matched to the tree renderer's depth prefix in that function). Plain text,
  no emoji, consistent with the rest of this CLI's output.
- `render_board` (`wm-state.py:1141`): add a `conflict` column to the Active
  table (`| type | id | status | window | repo | summary | blocker | delivery |
  conflict |`), rendering `"CONFLICTING"` or empty per row. The Closed table is
  unaffected (a stood-down member's conflict entry is removed by the standdown
  cleanup above).

This makes the drift visible passively (a plain `bin/crew-list` or reading
`board.md` shows it) in addition to actively (the watcher fires on the
transition) - useful because `needs-attention`'s edge-trigger only fires once;
without the display annotation, a conflict that is still open three cycles
later (e.g. wingman relayed it but the developer hasn't gotten to it yet) would
otherwise be invisible again on the next `bin/crew-list`.

### `CLAUDE.md` changes (wingman's own playbook)

Two small additions, both to sections that already exist:

1. **"The wake loop"** - after the existing bullet list describing `fire()`'s
   reason lines, add a short paragraph: a reason line of the form `conflict:
   <id>#conflict <note>` means `watch-fleet` itself (not the member) detected,
   via a direct `gh pr view` check, that the named member's delivered PR no
   longer merges cleanly against its base. The real crew id is `<id>` (strip
   the `#conflict` suffix); resolve it in `bin/crew-list` as normal. This is
   **not** a new member status and does not change what the member is doing -
   a member can be legitimately `review` (or `working`) with a delivery that is
   also flagged conflicting; both facts are shown side by side in the roster.
2. **"Command vocabulary"** - add a bullet next to the existing "Feedback on
   in-flight work" entry: a `conflict:` event is routed exactly like pilot
   feedback on in-flight work - `bin/crew-say <real-id> "<note>"` to the owning
   member (developer or lead), asking it to rebase/resolve. Wingman never
   edits the conflicted branch itself (this is exactly the kind of direct-edit
   shortcut the delegation guard exists to prevent) and never spawns a new
   member for it - the owning session already holds the context.
3. Also worth one line in **"Report"**: unlike a crew member's own status
   claims, a `conflict:` event is *itself* wingman's own verified read of
   GitHub (the watcher ran `gh pr view` directly) - it can be relayed to the
   pilot as settled fact ("PR #34 now conflicts with main per `gh`"), not
   hedged as a crew self-report, the one exception to the "self-report is a
   claim, not verified truth" rule elsewhere in this doc.

## Files touched

- `bin/lib/wm-state.py` - `mergeability-poll-list`, `mergeability-set`
  subcommands; `load_mergeability()` helper; `cmd_needs_attention` conflict
  loop + shared suppression helper; `cmd_standdown`/`cmd_prune` cleanup;
  `render_roster_text`/`render_tree_text`/`render_board` display; argparse
  wiring in `build_parser()`.
- `bin/watch-fleet` - `GH`/`MERGE_CHECK_INTERVAL`/`MERGE_CHECK_ENABLED`
  tunables; the new polling block in the main loop.
- `CLAUDE.md` - the three additions above.
- `tests/merge-conflict-watch.test.sh` (new) - see below.
- Possibly `tests/lib.sh` if a `make_fake_gh`-style helper is worth hoisting
  out of `tests/pr-watch.test.sh` for reuse; not required (duplicating the
  ~10-line fake is also fine and keeps the two suites independent).

## Testing strategy

Follow the existing conventions in `tests/pr-watch.test.sh` (fake `gh` via
`WM_GH`) and `tests/watch-fleet.test.sh` (`test_new_home`, backgrounded blocking
loop via `wm_track`/`wm_kill_tracked`, `wm_timeout` for foreground runs). New
file `tests/merge-conflict-watch.test.sh`:

1. **Unit-level, via direct `wm_state` calls (no blocking loop):**
   - `mergeability-set --id x --pr-json -` with `mergeable=CONFLICTING` sets
     `state=CONFLICTING` and a non-null `conflict_detected`; calling it again
     with the same input does not change `conflict_detected` (edge-trigger, not
     level-trigger).
   - Feeding `mergeable=MERGEABLE` afterward clears `conflict_detected` to
     null; feeding `CONFLICTING` again after that sets a **new**
     `conflict_detected` (distinct timestamp) - proves resolve-then-reconflict
     re-fires.
   - Feeding `mergeable=UNKNOWN`/`mergeStateStatus=UNKNOWN` after a
     `CONFLICTING` state leaves `state`/`conflict_detected` untouched but bumps
     `checked`.
   - `--fail` bumps only `checked`.
   - `mergeability-poll-list` excludes a `blocked` member, a member with a
     non-PR-URL `delivery`, and a member whose `checked` is within the interval;
     includes a never-checked member and a member whose `delivery` just
     changed (even if within the interval).
   - `needs-attention` emits the synthetic `"<id>#conflict"` row only while
     `conflict_detected` is set and the real member is still `review`/`working`;
     stops emitting it once acked (mirrors `tests/ack-dedup.test.sh`'s pattern)
     and once the real member's status leaves `review`/`working`.
   - `crew-standdown`/`crew-prune` remove the member's `mergeability.json` entry
     and its acked/handled `#conflict` keys.
2. **E2E, via the real blocking loop** (mirrors `tests/watch-fleet.test.sh`'s
   structure, backgrounded + `wm_track`):
   - Spawn a fake member (`crew-add` + `crew-set --status review --delivery
     <fake PR URL>`), point `WM_GH` at a fake `gh` returning
     `mergeable=MERGEABLE`, arm `watch-fleet` with a short
     `WM_MERGE_CHECK_INTERVAL` (e.g. `1`), confirm it keeps blocking.
   - Flip the fake `gh`'s canned response to `mergeable=CONFLICTING`; confirm
     the blocking watcher fires within one cycle with a `conflict:` reason line
     naming the real id, and that `board.md`/`crew-list` show the CONFLICT
     marker.
   - Re-arm; confirm the second arm does **not** re-fire on the same
     still-conflicting PR (ack suppression holds).
   - Flip `gh` back to `mergeable=MERGEABLE`; confirm a subsequent `crew-list`
     no longer shows the marker, and no spurious fire occurs on resolution.
3. Run the whole suite (`tests/run.sh`) at the end to confirm no regression in
   the existing watch-fleet/ack-dedup/group-attention/stall-check tests, since
   this plan adds a second population (`mergeability.json`) that
   `cmd_needs_attention` now reads on every call.

## Open questions / follow-ups

Not blocking for this scope; flag for the pilot or leave as explicit follow-ups:

1. **Bare PR references (no full URL) or non-GitHub forges.** `delivery` is
   free text; a member that records a bare branch name or PR number (not a full
   `github.com/.../pull/N` URL) is silently never polled. Resolving this needs
   per-member repo context (the roster's `repo` field is a local filesystem
   path, not an `owner/repo` slug) - worth a follow-up that threads `-R
   <owner>/<repo>` through from the member's git remote, resolved once at
   `crew-add` time or lazily on first poll.
2. **`blocked` members with an open PR.** Deliberately excluded from the polled
   set (see Design). If a blocked member's PR conflicts while it waits on an
   unrelated decision, that drift is invisible until it returns to
   `working`/`review`. Cheap to add later (same polling loop, just drop the
   status filter) if this proves to matter in practice.
3. **Fleet-wide `gh` auth failure.** Every due member fails its check every
   interval, silently, forever - there is no equivalent of the existing
   API-error nudge/mass-outage-grouping for *this* failure mode. A follow-up
   could count consecutive `--fail` results across the whole due-list in one
   cycle and surface a single low-priority note ("N merge-conflict checks
   failed - `gh` may need re-auth") the same way `group-attention` already
   collapses correlated signals, rather than a silent black hole.
4. **`pr-watch`'s own blind spot.** The crew-level watcher a developer arms on
   its own PR does not request `mergeable`/`mergeStateStatus` either, so a
   developer actively watching its own PR (not yet parked) would also miss this
   class of drift. Out of scope here (this plan is specifically about
   `watch-fleet`'s supervisory blind spot, per the directive), but the same
   mapping logic in `mergeability-set` could be reused by `pr-eval.py` as a new
   `conflict: <pr>` event if the pilot wants the crew-level watcher fixed too.

## Alternatives considered

- **Fold conflict state into the member's own `status`** (e.g. a new terminal
  status `conflicted`, or overwriting `blocker`). Rejected: the directive is
  explicit that a `review` member with a conflicting PR is two independent
  facts, not one replacing the other, and overwriting `status` would also
  race the member's own `crew-set` calls (see "Where state lives" above) in a
  way the existing pane-backstop precedent never has to deal with.
- **Poll from `pr-watch` (crew-level) instead of `watch-fleet` (supervisor-level).**
  Rejected as the primary fix: the whole point of the incident is that a
  crew member parked in `review` is not the one who needs to notice - the
  supervisor does, precisely because the member itself has no reason to keep
  looking once it believes its PR is fine. `pr-watch`'s blind spot (open
  question 4) is real but secondary.
- **A wholly separate wake channel for conflicts** (its own wake file, its own
  arm command). Rejected: the directive and `CLAUDE.md`'s existing "wake loop"
  contract are built around exactly one tracked background task per owner;
  adding a second would double the arming burden on wingman/leads for no
  benefit, when the existing `needs-attention`/`fire()` machinery already
  generalizes to an arbitrary `(id, status, updated, note)` row with zero
  changes required to `fire()` itself.
