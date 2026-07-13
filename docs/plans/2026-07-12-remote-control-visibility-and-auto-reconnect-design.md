# Design: Remote Control visibility, auto-recovery, and Artifact publishing for crew deliverables

Date: 2026-07-12.
Status: proposed, awaiting approval.

## Problem

The pilot asked for three quality-of-life improvements to how Claude Code's Remote Control feature interacts with wingman's crew workflow:

1. Every crew member wingman spawns via `bin/spawn-crew` should also be visible/reachable via Remote Control, the same way the pilot already sees the main wingman session - not only reachable via `tmux attach`.
2. Remote Control should stay active and recover automatically if it disconnects, rather than requiring the pilot to notice and manually restore it.
   This is not hypothetical: wingman's own Remote Control session has already dropped at least once (`Remote Control disconnected - Transport closed: this connection is no longer usable`), and the pilot had to ask a crew member to look into it before it was restored.
3. Crew deliverables (reports, plans) should be automatically published as web-viewable Artifacts when that actually helps - concretely validated by a markdown report that rendered badly when sent via `SendUserFile` over Remote Control, but rendered well once published as an Artifact instead.
   This is scoped in with three explicit constraints: not unconditional (only when it helps), only when the pilot is genuinely remote (not local, where a hosted URL is pointless and adds needless exposure), and with a concrete security mechanism (Artifacts are hosted on claude.ai, not local infrastructure, and may contain sensitive content).
4. When the pilot is genuinely remote, wingman should format URLs it surfaces (Artifact links, GitHub PR/issue links, crew `delivery` references) as markdown links with descriptive text rather than bare URLs, since a bare URL is least usable in exactly that context (read on a phone or in a browser, not a terminal that might auto-linkify). This reuses the same remote/local signal as item 3 rather than introducing a second detection mechanism.

This document investigates how Remote Control actually works, then designs against all three asks.
Ask 1 turns out to be straightforward.
Ask 2 splits into two materially different cases - crew sessions and wingman's own session - because of a real, structural constraint explained below; the recommendation is asymmetric on purpose rather than forcing one mechanism onto both.
Ask 3 turns out to hinge on a second real constraint - whether "is the pilot remote right now" is detectable at all - investigated in the same evidence-first way as asks 1 and 2, with a concrete fallback designed against the answer; that same fallback signal ends up gating two separate behaviors (publishing an Artifact, and formatting URLs as descriptive links), covered as asks 3a and 3b below.

## Investigation

All claims below were verified directly against this machine's installed Claude Code build (`claude` v2.1.207) rather than assumed: `claude --help`, `claude remote-control --help`, and `strings` against the installed binary at `/home/agents/.local/share/claude/versions/2.1.207` (a compiled native build, so the CLI's own embedded help text, log strings, and hook-event table are literal, unambiguous evidence, not inference). Where a claim could not be verified this way, it is marked as such.

### How Remote Control works

Remote Control connects a local, already-running `claude` process to `claude.ai/code` or the Claude mobile app, so the pilot can view and type into that session from a phone or browser.
The local process makes only outbound connections (poll/registration against the Anthropic API over TLS); it never opens an inbound port.
It requires a `claude.ai` subscription login (`oauthAccount` in `~/.claude.json`, already present and in use in this environment) - API-key-only auth does not support it.

There are three distinct ways a session becomes Remote-Control-visible, all confirmed directly:

- **`--remote-control [name]`** - a flag on the ordinary `claude` command, verified via `claude --help`: "Start an interactive session with Remote Control enabled (optionally named)." This is set once, at launch, on an otherwise-normal interactive session.
- **`/remote-control`** - an in-session slash command, confirmed by several embedded strings in the binary (`Run /remote-control to retry`, and the slash command appearing in help/status text describing "Keep working from anywhere ... claude.ai/code"). It both enables Remote Control on an already-running session and is the documented way to retry after a drop.
- **`claude remote-control`** - a separate subcommand (confirmed via `claude remote-control --help`, though it does not appear in the top-level `claude --help` command list) that runs as a persistent multi-session *server* in one directory: it pre-spawns one session and can spawn more on demand (up to `--capacity`, default 32), each isolated in its own git worktree (`--spawn=worktree`) or sharing a directory (`--spawn=same-dir`). This is a different mechanism from the first two - it is Anthropic's own on-demand multi-session bridge, not a way to expose an *externally launched* process like a crew member.

`~/.claude.json`'s `hasUsedRemoteControl` and `remoteDialogSeen` are global (machine/account-wide, not per-project, not per-session) tracking flags - confirmed by inspecting the file directly. This means the one-time consent dialog Remote Control shows the very first time it is used has, in this environment, already been dismissed once (by the pilot's own wingman session) and will not reappear for any subsequent session on this machine, crew included.

One claim from an initial pass by the `claude-code-guide` agent could **not** be verified and should be treated as unconfirmed: a `/config` toggle to "Enable Remote Control for all sessions" globally.
No such string or setting exists anywhere in the installed binary's embedded strings, and there is no `remoteControl` namespace documented in `settings.json`.
Global always-on enablement, if it exists at all, is not a verified mechanism; the three items above are.

### Multiple concurrent sessions

Confirmed: nothing in the CLI ties one machine or one account to a single Remote-Control-visible session.
Each `claude --remote-control` (or `/remote-control`-enabled) process registers itself independently; N independent processes each show up as N independently reachable sessions.
This is exactly the shape of a wingman fleet (a handful of independent `claude` processes, each its own tmux window, each its own `--session-id`), so there is no architectural mismatch to work around for ask 1.
The only related capacity limit found (`--capacity`, default 32) belongs to the `claude remote-control` server subcommand's own on-demand spawning, not to how many independently-launched processes can each carry the flag - it is not applicable here.

### What causes a disconnect, and what recovers it automatically

The embedded strings expose the actual transport and retry logic, not just its user-facing message:

- The transport (an SSE/WebSocket-style connection, `SSETransport` in the code) has a real reconnect loop: on a connection error it schedules a retry with **exponential backoff** (`Math.min(base * 2^attempt, cap)`, jittered), and a **liveness timer** that forces a reconnect if no frames arrive within a timeout window. This confirms disconnects from ordinary causes (laptop sleep, a network blip, a brief server hiccup) are already handled automatically, with no user action, most of the time.
- That retry is **bounded**, not infinite. The strings `" recovery exhausted after "`, `" attempts"`, and `"Transport recovery exhausted (code "` / `"Transport closed: "` are constructed together into exactly the message the pilot saw: `Remote Control disconnected - Transport closed: this connection is no longer usable`. Once the retry budget (attempts, or an elapsed-time cap - the bridge/server path separately exposes `connGiveUpMs`/`generalGiveUpMs` server-side config knobs for the analogous give-up threshold) is exhausted, the session gives up **permanently** and does not retry again on its own.
- Recovery past that point requires an explicit action: re-run `/remote-control` in the same still-running session (confirmed via the `Run /remote-control to retry` string), or, for the `claude remote-control` server subcommand, re-invoke the command entirely (`Re-run \`claude remote-control\` to try again`).

This matches the pilot's actual experience precisely: the automatic reconnect logic exists and handles transient blips, but a disconnect severe or long enough exhausts it, after which nothing further happens until a human (or something acting on a human's behalf) explicitly retries.

### No hook event exists for this

The CLI's own embedded hook-event table (from its built-in documentation string, reproduced verbatim) is: `PermissionRequest`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Notification`, `Stop`, `PreCompact`, `PostCompact`, `UserPromptSubmit`, `SessionStart`.
There is no Remote-Control-specific event, and `Notification`'s documented matcher is "Notification type" with no evidence in the strings that a Remote Control state change is one of the notification types it fires on.
This rules out a hook-based detection mechanism outright: it is not a gap in wingman's use of hooks, it is an absence in what Claude Code exposes.
The only signal available to something *external* to the disconnected session is the same one the pilot used: the disconnect banner rendered into the pane's own visible text.

### `bin/spawn-crew`'s launch recipe (current state)

Read directly from `bin/spawn-crew`: every crew member is launched via a generated per-member script (`$WM_HOME/crew/<id>.launch.sh`) that does `cd <repo>`, exports `WINGMAN_HOME`/`WINGMAN_CREW_ID`/`WINGMAN_CREW_TYPE`/`WINGMAN_STATE`/`WINGMAN_BIN`(/`WINGMAN_WORKTREE`), then `exec claude` with `--permission-mode <mode>` (default `bypassPermissions`), `--session-id <uuid>`, `--name <id>`, optionally `--model`/`--effort`, `--add-dir` for `$WM_HOME` and the repo (plus every discovered repo in global scope), and `--append-system-prompt`.
Nothing in this recipe touches Remote Control today - crew are reachable only via `tmux attach` (or `bin/crew-takeover`, which prints that same command).

### How wingman's own session is launched

`bin/wingman` is a thin convenience wrapper: it collects `--add-dir` flags for discovered project roots and then `exec claude $adddirs "$@"` in the wingman repo.
It passes no `--remote-control` flag; nothing in this repo enables Remote Control for wingman's own session at launch.
The pilot must therefore be enabling it via the in-session `/remote-control` slash command (confirmed to exist) after starting wingman - consistent with the global `remoteDialogSeen`/`hasUsedRemoteControl` flags already being `true` on this machine.

A second, load-bearing fact comes from `bin/spawn-crew`'s own comments and `bin/watch-fleet`'s header: wingman's own session commonly runs as a **window inside the same tmux session** (`$WM_TMUX_SESSION`, default `wingman`) that crew windows are created in - `bin/spawn-crew` explicitly guards against "the pilot runs wingman in a tmux window named 'wingman'" when picking a `new-window` target.
`bin/watch-fleet`'s own header states plainly that it "therefore never tries to inject keystrokes into wingman's terminal" - by design, not by oversight.
Both facts matter directly for the ask 2 design below.

### Is "the pilot is on Remote Control right now" detectable? (for ask 3)

Ask 3 only makes sense if something can tell a running session (or wingman/`bin/watch-fleet` from outside it) whether the pilot is currently viewing it remotely versus sitting at the local terminal.
This was investigated as thoroughly as asks 1 and 2, across every surface examined so far plus the ones specific to this question, rather than assumed either way:

- **The hook input schema is exhaustive and was fully reproduced from the CLI's own embedded docs above:** `session_id`, `tool_name`, `tool_input`, `tool_response` (`PostToolUse` only). There is no client/source/transport field on any hook payload, for any of the ten documented hook events. A hook cannot tell.
- **No live "remote connected" state file exists anywhere under `~/.claude` or `~/.claude.json`.** Both were searched directly for this investigation (and for the ask-2 investigation above, which already covers the same ground for the disconnect signature). The only persisted Remote Control state found is the two *global, one-time* dialog-seen flags (`hasUsedRemoteControl`, `remoteDialogSeen`) - static booleans about whether the feature has ever been used on this machine, not live per-session presence. A file cannot tell.
- **`process.env.CLAUDE_CODE_ENTRYPOINT`** (confirmed via the binary's strings, used to classify telemetry into `claude_code_remote`/`claude_code_cli`/`claude_code_vscode`/etc.) describes how *this process itself* was launched (e.g., a worker spawned by the `claude remote-control` bridge/server subcommand gets `remote`/`remote_mobile`/`remote_desktop`/etc.), not whether a remote viewer is currently attached to an *ordinarily-launched* interactive session.
  wingman and every crew member are always launched the ordinary way (`exec claude ...` from `bin/wingman` / the generated launch script), never through the bridge subcommand, so this env var reads `cli` (the default) regardless of whether `--remote-control` is also passed or later toggled on via `/remote-control`. An env var cannot tell, for the way wingman actually launches sessions.
- **The CLI does track a live notion of this internally** - the binary defines an in-process state object with a `clientType` field (`Mvr()`/`P8o(e)` getter/setter pairs found in the strings) and a `user_present` reason code used specifically to decide notification delivery (see below) - but this state lives only in the CLI's own JS runtime memory. Nothing in the investigation found it serialized to disk, exposed to hooks, or exposed through any tool result as a queryable status.
- **The closest first-party mechanism to "does the CLI know if I'm remote" is the built-in `PushNotification` tool**, and its own description confirms the underlying check exists: "If Remote Control is connected, it also pushes to their phone... When the user is actively at the terminal, your output already reaches them - a notification on top of it would be a duplicate, so the tool skips it and says so." The binary's strings confirm the actual reason codes behind that behavior: `user_present` ("Not sent because you're active in this terminal."), `no_transport`, and `remote-control` ("Terminal and mobile notification sent.").
  This is real evidence that the CLI internally distinguishes "pilot is locally present" from "pilot is only reachable via Remote Control" - but it is exposed **only as a side effect of actually sending a notification**, not as a free, silent status query. Using `PushNotification` purely to probe presence would misuse the tool against its own explicit purpose (it exists for something worth interrupting for, and its own description warns that over-notifying "is annoying in a way that accumulates") and would still cost a real interruption every time it was invoked - the opposite of a cheap detection signal.

**Conclusion: not reliably or silently detectable**, by any channel this investigation could find - hook payload, settings/state file, environment variable, or tool query - given how wingman actually launches sessions.
This is the same category of finding as ask 2's "no hook event exists for this": a real absence in what Claude Code exposes today, not a gap in wingman's own design to route around.
The design below follows the pilot's own instruction for exactly this outcome: ask once, rather than silently guessing either way.

## Design

### Ask 1: crew visibility by default

Add one flag to the generated launch script in `bin/spawn-crew`, in the same conditional style already used for `--model`/`--effort`:

```
[ -n "$REMOTE_CONTROL" ] && printf ' --remote-control %s' "$(quote "wm-$ID")"
```

with `REMOTE_CONTROL` sourced the same way `MODEL`/`PERM_MODE` already are - an env var, `WM_REMOTE_CONTROL`, defaulting to enabled (e.g. `"${WM_REMOTE_CONTROL-1}"`) and disabled by setting it empty, mirroring `WM_PERMISSION_MODE`'s existing convention exactly so there is only one pattern to learn.
The Remote-Control-visible name is `wm-$ID` - the same `wm-` prefix already used for the tmux window name (`$WINDOW`), so a crew member reads identically in `claude.ai/code`, the terminal title, and `tmux list-windows`.
`--remote-control-session-name-prefix` is not needed: it only affects auto-generated names, and every crew member already gets an explicit one.

No other change is required to make this visible-by-default:

- Every crew process already runs as an ordinary interactive session (never `-p`/`--print`), which is what `--remote-control` requires.
- Auth is already `claude.ai`-subscription-based on this machine (confirmed in `~/.claude.json`), and the one-time consent dialog is a global flag already dismissed - crew do not re-trigger it.
- Multiple concurrent Remote-Control-visible processes are confirmed to each register independently with no cross-session limit relevant at wingman's crew scale (single digits to low tens).
- Being reachable/typeable from `claude.ai/code` is not a new risk to a crew member's playbook: `CLAUDE.md`'s status contract already anticipates "a human can attach... and type directly" and instructs a member to treat a redirect as authoritative. Remote Control is simply one more channel into the same already-designed-for behavior, not a new one.

**One thing to verify empirically before flipping the default on, that this investigation could not settle from the CLI/binary alone:** whether `--remote-control` on a session whose account cannot use it (no subscription, e.g. a pure API-key or Bedrock/Vertex deployment - `--bare`'s help text calls these out as a real, supported auth mode) fails soft (session starts normally, Remote Control quietly unavailable) or fails hard (session refuses to start at all).
The strings `Remote Control is only available with claude.ai subscriptions...` and `Error: You must be logged in to use Remote Control.` exist, but which code path they sit on (a warning banner vs. a fatal startup error) was not distinguishable from the binary's strings alone.
If it fails hard, `WM_REMOTE_CONTROL=1` as an unconditional default would break every crew spawn on a non-subscription deployment - a severe regression, not a cosmetic one.
The fix if that turns out to be true is unchanged (the same env var already provides an opt-out); the only requirement is that whoever implements this spawns one real test crew member with the flag first and confirms it degrades gracefully, before relying on the default being safe everywhere.
This is the one open verification step in an otherwise low-risk change.

### Ask 2: auto-detect and recover a dropped connection

The investigation surfaces a hard asymmetry that the design has to respect rather than paper over: **wingman's own session and a crew member's session are not the same kind of recovery problem**, because of who can safely act on the disconnect signal.

**Crew: full automatic recovery is achievable, and uses a mechanism wingman already has.**
`bin/watch-fleet` already captures crew pane text every cycle and pattern-matches it for a different purpose (`prompt_freeze_check`, detecting a frozen permission/trust dialog by its generic multi-option shape).
The same capture can be pattern-matched a second way, for the literal disconnect banner text (`Remote Control disconnected`, `Transport closed`, `Transport recovery exhausted` - all confirmed exact substrings the CLI emits).
When a crew member's pane shows this signature, `bin/watch-fleet` can recover it exactly the way it already delivers the opening objective and `crew-say` messages to a crew pane: via `wm_tmux_send_message`, typing `/remote-control` and Enter into that member's window.
This is not a new class of action - it is the existing message-delivery primitive, aimed at a pane it already has a target for (crew windows are recorded in `crew.json`, with their `window` field), triggered by a new reason.
Concretely:

- Add a new detector alongside `prompt_freeze_check` in `bin/watch-fleet`, e.g. `remote_control_dropped_check`, matching the disconnect substrings against the same per-cycle pane capture (reuse the existing capture; do not re-`capture-pane` a second time per member).
- On match, call `wm_tmux_send_message "$WM_TMUX_SESSION:$_win" "/remote-control"` for that member, then record the recovery attempt (a per-member cooldown/hash file, the same pattern `prompt_freeze_check` already uses via `$WM_HOME/pane-<id>.hash`, so a still-broken connection is not retried every single cycle in a tight loop - once per some minimum interval is enough).
- This does **not** need to become a new crew status (`blocked`/`stalled`/etc.) the way a frozen prompt does, because - unlike a frozen prompt - it is something wingman's own tooling can fully resolve without a human decision. It only needs to surface to the pilot if the retry itself does not clear on the next cycle (i.e., escalate to a status note only when automatic recovery is itself failing repeatedly), keeping it a purely quiet, self-healing background repair the overwhelming majority of the time - which is exactly what the pilot asked for.

**Wingman's own session: full automatic recovery is not safely achievable, and this is a real constraint, not an oversight to route around.**
Two structural facts combine to rule it out:

1. There is no hook for this event (confirmed above from the CLI's own complete hook-event table), so wingman cannot be handed the disconnect as structured data the moment it happens.
2. `bin/watch-fleet` deliberately never injects keystrokes into wingman's own terminal, and that restraint is correct, not just cautious: the only way for anything (wingman itself included) to act on the disconnect is to type `/remote-control` into the same pane wingman's own turn is running in.
   The instant that keystroke-sending Bash tool call is issued, that very pane is mid-render of the tool call itself - it is not idle the way an independently-running crew pane is when `wm_tmux_send_message`'s readiness/confirm loop targets it from outside.
   A process cannot reliably deliver synthetic input into its own controlling pane at a moment guaranteed idle, because issuing the delivery is itself an action in that same pane.
   This is a genuine limitation of the harness's single-pane model, not a gap in wingman's design; forcing a self-injection "fix" here would trade a rare, visible failure (today's manual notice-and-ask) for an unreliable, silent one (a self-typed keystroke racing the tool-call render, landing wrong, or corrupting the input box).

The achievable compromise is **detect automatically, notify immediately, let the pilot supply the one keystroke** - which still fully closes the actual gap the pilot described ("without depending on the pilot noticing manually"), because detection (not the final keypress) is what today's failure mode was missing:

- At wingman startup (in `bin/wingman`, or wherever wingman's own turn first runs `wm_state init`), register wingman's own pane identity once: if `$TMUX_PANE` is set (wingman is running inside tmux - the common case the existing code already assumes elsewhere), write it (or the window name via `tmux display-message -p '#{window_name}'`) to a small, well-known file, e.g. `$WM_HOME/self-pane`, following the same plain-file convention `pane-<id>.hash` already uses rather than inventing a new subsystem.
- Extend `bin/watch-fleet`'s own cycle (the one wingman arms for itself, `--owner ""`) to also read-only capture that registered pane (if the file exists) and run the same disconnect-signature match against it - never `wm_tmux_send_message` against it, only detection.
- On a match, fire the wake exactly the way a `blocked`/`stalled`/frozen-prompt event already does today (this is the existing wake contract, not a new one: the cycle exits, the harness re-invokes wingman, the reason line says what happened).
  Wingman's very next turn reports it to the pilot immediately and explicitly - "Remote Control disconnected on this session; run `/remote-control` to restore it" - the moment it happens, not whenever the pilot next happens to scroll past the banner or ask a crew member to check.

**The hard limitation to state plainly:** this detection path only works if wingman's own session runs inside a tmux pane wingman can name at startup.
If the pilot instead runs wingman in a plain terminal or a GUI tab with no tmux underneath at all, there is no addressable pane for anything to read, and this half of the design has no channel to attach to - today's manual-notice behavior is what remains in that setup, because nothing in Claude Code exposes a non-pane-based signal for this event (confirmed above: no hook, no settings key, no subcommand for querying another session's live connection state from outside it).
The existing code already assumes wingman-in-a-tmux-window is a normal, supported setup (`bin/spawn-crew`'s own comment about `new-window` target collision), so this is a documented precondition, not a new requirement being invented for this feature.

### Ask 3: pilot-location-gated behaviors

Condition B below (confirmed-remote-or-local) turns out to gate two independent behaviors, not one, both raised by the pilot as part of the same Remote Control quality-of-life effort: whether to auto-publish a deliverable as an Artifact, and whether to format URLs (Artifact links, GitHub PR/issue links, crew `delivery` references) as markdown links with descriptive text rather than bare URLs.
Both behaviors are designed against the single shared signal built below - there is deliberately no second detection path.

### Ask 3a: publish crew deliverables as Artifacts when it helps

Today, per `playbooks/_status-contract.md`, a crew member's `review` state carries only a **path** in `--artifact` - wingman (and every playbook) already follows "relay the pointer, not the payload" (`CLAUDE.md`), so no crew member proactively pushes file content to the pilot today except by the general-purpose `SendUserFile`/`Artifact` tools available to any session, used at the acting session's own discretion.
The pilot's validated pain point sits exactly there: a markdown report pushed via `SendUserFile` rendered badly when viewed over Remote Control; the same content published via `Artifact` rendered well.
The design has to decide, concretely, **when** a deliverable should be published as an Artifact instead of (or alongside) just naming its local path - not leave it to per-session discretion, since that is what produced the inconsistent behavior the pilot already hit.

Three conditions gate the decision, all required together, none sufficient alone:

#### Condition A - the content is actually rendering-sensitive

This is the easy condition. Every crew deliverable produced by the existing playbooks (`software-analyst`, `architect`, a `research`-type report) is exactly the kind of content that suffers when flattened to a chat attachment: prose with headers, tables, and code fences - structure that a proper renderer (Artifact) preserves and a raw-text/file-attachment view does not.
A one-line status update, a PR URL, or a short chat answer is not a candidate at all - there is no rendering to lose, so this condition simply excludes those by construction rather than needing a separate check. Concretely: this applies to a markdown file that is itself the `--artifact` deliverable of a `review`-state transition; it does not apply to anything else a session might say or send.

#### Condition B - the pilot is confirmed remote right now, not assumed

This is where the detectability finding above applies directly. Since there is no reliable signal, the design must ask rather than guess, exactly as the pilot specified, and must bound how often it asks:

- **Ask once, cache for the rest of the *pilot's working session*, not per-deliverable and not per-crew-member.** "Per crew member" would be the wrong scope: each crew member is an independent process with no shared memory, so naively asking "once per session" inside each member's own conversation would still mean the pilot gets asked once per software-analyst, once per architect, once per research report, etc. - a repeated annoyance the pilot did not ask for and would reasonably read as a regression. The right scope is the pilot's actual working session with wingman as a whole.
- Concretely: a small shared file, e.g. `$WM_HOME/pilot-location.json` (`{"remote": true|false, "wingman_run_id": "..."}`), written once and read by anyone who needs it. `$WINGMAN_HOME` is already exported into every crew member's environment (confirmed in `bin/spawn-crew`'s generated launch script), so this needs no new plumbing to reach crew.
- **Invalidation is keyed to a wingman run, not a wall-clock TTL.** Wingman stamps a fresh `wingman_run_id` (any unique value - a timestamp or uuid) into this file once at its own startup (alongside `wm_state init`, next to the `$WM_HOME/self-pane` write from ask 2). Whoever needs the answer compares the file's `wingman_run_id` against wingman's current one (also exported, e.g. via a new `WINGMAN_RUN_ID` env var alongside `WINGMAN_HOME`); a mismatch (or a missing file) means "not yet answered for this run," so the asking party (whichever crew member or wingman itself hits the need first) asks once via `AskUserQuestion` ("Are you viewing this session via Remote Control right now, or are you local at this machine?") and writes the fresh answer + current run id for everyone else to reuse. A new wingman process (a fresh sit-down, or a fresh remote connection) naturally gets a fresh answer, which is the right boundary - a wall-clock TTL would either re-ask mid-session for no reason or go stale across a genuine context switch (the pilot walks away and switches to the phone) with no better way to catch that switch anyway, since nothing here is watching for it live.
- **Unanswered or ambiguous defaults to "local."** If the file cannot be written/read for some reason, or the question cannot be asked (e.g., a fully unattended path with no one to answer), the conservative default is to *not* publish - the cost of an unnecessary local-only pointer is negligible; the cost of a needless hosted-URL exposure for something that turns out to be sensitive is not. This mirrors the same conservative-default posture already used for the security gate below.
- **This is a real, stated limitation, not a hidden one:** because there is no live signal, a cached answer can go stale within a single wingman run if the pilot's actual location changes mid-session (they were local when asked, then later switch to the phone, or vice versa) - the design has no way to detect that switch and does not claim to.

#### Condition C - the content passes a concrete, deterministic security gate

The pilot was explicit that "be careful" is not an acceptable answer here, so the mechanism has to be a real check, not a judgment call left to whichever session is about to publish. Two things are worth separating clearly, because they solve different problems:

- **The `Artifact` tool's own built-in refusal categories** (no impersonation of a real person/org, no fabricated records, no credential-collection forms, no content targeting a private individual) are aimed at *misuse of the hosting mechanism itself* (phishing, fraud, harassment). They say nothing about whether *this repo's own internal information* is safe to host externally, which is the pilot's actual concern (secrets, infra details, proprietary code) - a materially different risk. Do not rely on the tool's existing guardrails to cover this; they were not designed to.
- **A dedicated pre-publish content scan is the deterministic mechanism**, run against the file before every auto-publish decision, gated on an allowlist of locations *and* a pattern scan of content, both required:
  1. **Location allowlist (coarse, cheap, defense-in-depth only - not sufficient alone):** only files under this repo's known crew-deliverable directories (`docs/plans/`, `docs/analysis/`, `docs/tickets/`) are even candidates. A file the crew happened to read elsewhere is never auto-published regardless of its content.
  2. **Content scan (the actual decision, must pass):**
     - **Secrets/credentials:** run an existing, actively-maintained secret-scanning tool (e.g. `gitleaks`) against the file rather than hand-rolling and maintaining a regex list. Secret formats (cloud-provider key prefixes, token shapes) change over time; a maintained ruleset is the correct long-term-maintainability choice here, not a one-off pattern list that silently rots.
     - **Internal infra identifiers:** a small, purpose-built regex check for RFC1918 private IPv4 ranges (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) and obviously-internal hostname suffixes (`.internal`, `.corp`, `.local`, or any internal domain the repo/organization is known to use). This space is small and stable enough that a maintained third-party tool is not needed.
     - **Proprietary code exposure:** not pattern-matchable the way secrets are (a design doc legitimately and routinely quotes short code excerpts to illustrate a point - this document does exactly that, quoting fragments of `bin/spawn-crew` and `bin/watch-fleet`). Treat this as a soft size/proportion heuristic instead of a hard block: flag (do not auto-block) when a single quoted code block is unusually large (e.g. tens of lines) or code blocks make up an unusually large share of the document, since that shape suggests a wholesale dump rather than an illustrative excerpt.
  - **On any hard hit (secrets or infra identifiers): do not auto-publish.** Fall back to today's default (report the local path only) and say plainly why - "skipped publishing as an Artifact: this draft matches a credential/internal-hostname pattern; here's the local path instead" - so the pilot is not left wondering why this one deliverable behaved differently.
  - **On a soft hit (the code-proportion heuristic): publish is still allowed, but call it out** in the same message, so the pilot's attention is drawn to it rather than silently hosted without comment.

One more fact about the actual exposure model is worth stating precisely rather than glossed over, since it is the whole reason condition C exists: per the `Artifact` tool's own description, an Artifact "starts private" and is "default-private," but the description also frames this as *not publicly listed/discoverable* rather than *access-controlled to the pilot's account* - "the user can later choose to share" a link that, once it exists, is a URL. This investigation found no evidence one way or the other about whether an unlisted Artifact additionally requires the viewer to be authenticated as the pilot; the tool's own description is the only source available here, and it is phrased in terms of listing/discovery, not authentication.
The design should not overclaim a stronger guarantee than that wording supports - "unlisted" is the safe way to describe it, not "private to the pilot."

### Putting conditions A, B, and C together

The concrete trigger: when a crew member (or wingman, if it is the one relaying/handing off a file) is about to surface a markdown deliverable to the pilot (the existing `review`-state artifact handoff is the one clear, repeatable point this already happens at) -

1. Check condition A (is this a markdown deliverable at all) - if not, nothing changes from today.
2. Check condition B (read/ask-and-cache the shared remote/local answer) - if local (or unknown), report the path only, exactly as today.
3. Check condition C (location allowlist + content scan) - if it fails, report the path only and say why.
4. Only if all three pass: publish via the `Artifact` tool and report the resulting URL alongside (not instead of) the local path, so the pilot always still has the local file as ground truth regardless of which channel they read it from.

This keeps today's behavior as the default in every case except the narrow one the pilot actually asked for (remote, rendering-sensitive, and clean), which is the concrete meaning of "not unconditional."

### Ask 3b: hyperlink URLs with descriptive text when the pilot is confirmed remote

The pilot's second behavioral ask: when wingman (or a crew member, for a `delivery`/`artifact` report that reaches the pilot directly) surfaces a URL - an Artifact link from 3a, a GitHub PR/issue link, any `delivery` reference - it should render it as a markdown link with descriptive text (`[PR #29 ready for review](https://github.com/...)`) rather than a bare URL, specifically when the pilot is remote.
The reasoning is the mirror image of the `SendUserFile`-vs-`Artifact` finding that motivated 3a: a bare URL read on a phone or in a browser over `claude.ai/code` is exactly the context where a plain-text link is least usable, and where a clickable, labeled link matters most - a local terminal may auto-linkify a bare URL (or the pilot is comfortable copy-pasting it) in a way a remote chat view does not necessarily do consistently.

This reuses condition B exactly as built above - **no second detection mechanism, no second question to the pilot.** The same `$WM_HOME/pilot-location.json` read (keyed to `WINGMAN_RUN_ID`, ask-once-per-run, defaults to "local"/unknown on any doubt) that gates 3a's Artifact-publish decision also gates this formatting choice:

- **Remote (cache says `true`):** format every URL wingman or a crew member surfaces to the pilot as a markdown link with short, descriptive text describing what it points to (the deliverable, the PR/issue and its state, etc.), never a bare URL pasted inline.
- **Local or unknown (cache says `false`, or the file is missing/unread):** today's behavior is unchanged - bare URLs are fine, since the pilot is either at the local terminal (where this was never the pain point) or the signal genuinely could not be obtained, in which case the conservative default (do the less presumptive thing) matches the same posture condition B already takes for 3a.

This is a **presentation-only** behavior - it changes how wingman/crew phrase a message to the pilot, not what gets published, hosted, or scanned, so none of condition C's security gate applies here: a GitHub PR URL or a local file path is not new exposure just because it is wrapped in link syntax. It belongs in wingman's own conversational behavior (documented in `CLAUDE.md` once implemented) rather than in a script, since it governs how a session phrases its own output rather than a mechanical file operation - unlike 3a's Artifact-publish step, there is no separate tool invocation to gate, just a formatting convention to follow once condition B's answer is known.

## Recommendation

Build all three pieces - crew default-visibility (ask 1), the crew-side auto-reconnect (the achievable half of ask 2), and the two pilot-location-gated behaviors (ask 3a's Artifact-publish path and ask 3b's link-formatting behavior) - as one coordinated change, since they share the same file surface (`bin/spawn-crew`'s generated launch recipe, `bin/watch-fleet`, `$WM_HOME` state conventions, `playbooks/_status-contract.md`) and the same underlying evidence-first standard.
Ask 3b in particular is not additional design work: it consumes the same condition-B cache 3a already builds, so implementing it is a `CLAUDE.md` behavioral note plus consistent phrasing, not a new mechanism.
Build wingman's own detect-and-notify half of ask 2 alongside it; it is a small, separate addition (one registration write, one read-only check in the existing cycle) with no shared risk to the crew-side change, but delivering it in the same pass avoids a second design/review round over the same investigation.

This is the lowest-effort option that actually solves each problem, not a compromise chosen for cost:

- Full silent auto-recovery for wingman's own Remote Control session (ask 2) is not a materially viable alternative given the structural self-injection constraint above, so there is no second, more-complete option being set aside here - detect-and-notify is the ceiling of what Claude Code's current interface permits for that one case, and it converts the pilot's actual complaint (nobody noticed for a while) into a non-issue (surfaced the moment it happens) even though it does not eliminate the one remaining keystroke.
- Silently auto-publishing every crew deliverable as an Artifact (ask 3a), or conversely gating every publish behind an explicit human confirmation, are both rejected in favor of the three-condition gate above: the former ignores the pilot's own "not unconditional" and security constraints outright, the latter reintroduces exactly the manual friction the pilot is trying to remove for the common, clean case. The deterministic content scan (reusing a maintained secret-scanner rather than a hand-rolled pattern list) is the concrete mechanism the pilot asked for in place of "just be careful," and the ask-once-per-run cache is the concrete mechanism in place of either guessing at or ignoring the remote/local question.
- A second detection path for ask 3b (e.g. asking again, or inferring remoteness from message content/context) is rejected outright: it would duplicate condition B's cache for no benefit and risk the two behaviors disagreeing about the pilot's location within the same run. One shared signal, two consumers, is both the simplest and the only internally-consistent option.

**Sequencing suggestion for implementation** (not binding, since this is analyst-phase scope): the `--remote-control` flag addition to `bin/spawn-crew` is mechanical and independently shippable first; the crew-side `remote_control_dropped_check` addition to `bin/watch-fleet` is naturally sequenced right after it (there is nothing to detect on a crew pane until crew are actually launched with the flag); wingman's own self-registration + detection is the smallest, most independent piece and can land in any order relative to the other two. Ask 3 (both 3a's Artifact-publish gate and 3b's link-formatting behavior) is independent of all of the above - it does not depend on ask 1 or ask 2 shipping first - and can be sequenced in parallel or afterward; its own internal order is condition B's shared-cache plumbing first (needed by 3a and 3b alike), then 3a's content-scan gate and `_status-contract.md` wiring, then 3b's `CLAUDE.md` behavioral note, which only needs the cache and can land in either order relative to 3a's content-scan work.

## Files touched (for the implementing developer)

- `bin/spawn-crew` - add the `WM_REMOTE_CONTROL`-gated `--remote-control "wm-$ID"` flag to the generated launch script, alongside the existing `MODEL`/`EFFORT` conditional-append block.
- `bin/watch-fleet` - add a `remote_control_dropped_check` (or similarly named) detector next to `prompt_freeze_check`, reusing the per-cycle pane capture; on match, call the existing `wm_tmux_send_message` helper with `/remote-control` for a crew member's window, with a per-member cooldown so a still-broken connection is not retried every cycle.
- `bin/watch-fleet` (or `bin/wingman`) - add read-only detection of wingman's own registered pane (`$WM_HOME/self-pane`, written once at wingman startup if `$TMUX_PANE` is set), firing the existing wake mechanism on a match; no injection into that pane.
- `bin/wingman` - write `$WM_HOME/self-pane` once at startup, best-effort (silently skip if not running inside tmux).
- `CLAUDE.md` - a short note under "The wake loop" or a new subsection documenting the new wake reason (`remote-control-dropped` or similar) for wingman's own session, and a note in the crew-spawn recipe description (`bin/` / spawning section) that crew are Remote-Control-visible by default via `WM_REMOTE_CONTROL`.
- `README.md` - the "Autonomous by default" / "Take the wheel any time" sections currently describe `tmux attach` as the way to reach a crew member; add one line noting Remote Control as the additional, default-on channel.
- `tests/watch-fleet.test.sh` - extend with coverage for the new detector (a captured pane containing the disconnect banner triggers the recovery message; a clean pane does not), following the existing stubbed-`WM_AGENT` E2E convention so no real `claude`/Remote Control account is needed to test it.
- `playbooks/_status-contract.md` - document the ask-3 gate (conditions A/B/C) at the `review`-state artifact handoff, since this is the one shared point every crew type already passes through; a member checks the shared remote/local cache, runs the content scan, and either publishes + reports the URL alongside the path, or reports the path only (with a one-line reason if a scan hit suppressed it).
- A new small helper (either a `bin/lib/common.sh` function or a `wm-state.py` subcommand, whichever fits the existing pattern better at implementation time) - read/write `$WM_HOME/pilot-location.json` (condition B's shared cache) keyed by a `WINGMAN_RUN_ID` wingman stamps once at its own startup and exports alongside `WINGMAN_HOME`.
- `bin/wingman` - stamp and export `WINGMAN_RUN_ID` at startup (a fresh value per run), alongside the existing `$WM_HOME/self-pane` write from ask 2.
- The content-scan gate itself (condition C) - a small script (e.g. `bin/lib/artifact-scan.sh` or similar) wrapping `gitleaks` (or an equivalent maintained secret scanner) plus the small RFC1918/internal-hostname regex check and the code-block-proportion heuristic; invoked by a crew member before calling the `Artifact` tool. `bin/doctor` gains a dependency check/install step for the scanner, matching how it already handles `claude`/`git`/`tmux`/`uv`/`uuidgen`/`gh`.
- `CLAUDE.md` - a short note that crew deliverables may surface as an Artifact URL alongside the local path when the pilot is confirmed remote and the content passes the security scan, so wingman's own relay behavior ("relay the pointer, not the payload") is understood to mean "the pointer, and an Artifact URL when the gate says so" rather than being contradicted by it.
- `CLAUDE.md` - a short behavioral note for ask 3b: when condition B's cache says the pilot is remote, format URLs (Artifact links, GitHub PR/issue links, `delivery` references) as markdown links with descriptive text (`[PR #29 ready for review](https://github.com/...)`) rather than bare URLs; when local or unknown, today's plain-URL behavior is unchanged. This is a pure phrasing convention with no script to write - it belongs next to the ask-3a Artifact-relay note above since both read the same cache.

## Testing strategy

- Unit-level (bash E2E, matching this repo's existing convention of a stubbed agent CLI and no live tmux/`claude` dependency beyond what `tests/lib.sh` already sets up): feed `bin/watch-fleet`'s new detector a captured-pane fixture containing each of the three confirmed disconnect substrings and confirm it fires the recovery send; feed it a clean/idle pane and confirm it does not.
- Cooldown behavior: confirm the detector does not re-send `/remote-control` on every single cycle while the pane still shows the disconnected banner (avoid a tight retry loop against a connection that is not actually going to recover from a slash command alone, e.g. if the account itself lost its subscription).
- Manual, one-time, against a real account (cannot be scripted): spawn one real crew member with `WM_REMOTE_CONTROL=1` and confirm it actually appears as an independent session in `claude.ai/code`; this is also the moment to resolve the one open verification item above (does `--remote-control` degrade gracefully without subscription auth).
- Manual: register wingman's own pane, simulate a disconnect (or wait for a real one), and confirm the wake fires with a legible reason line and wingman surfaces the "run `/remote-control`" prompt on its very next turn.
- Ask-3 unit-level: fixture files with known-planted secrets/private-IP strings/oversized code blocks confirm the scan blocks (or soft-flags) correctly; a clean plan/report fixture confirms it passes. The shared-cache read/write (condition B) is testable without a real account - it is plain file I/O keyed by a run id, matching this repo's existing test conventions for `$WM_HOME` state.
- Ask-3a manual: with the cache seeded `remote: true` and a clean fixture doc, confirm a crew member publishes via `Artifact` and reports both the URL and the local path; with `remote: false`, confirm it reports the path only; with a planted-secret fixture and `remote: true`, confirm it still reports the path only, with the stated reason.
- Ask-3b manual: with the cache seeded `remote: true`, confirm wingman/a crew member phrases a PR link or Artifact link as a descriptive markdown link rather than a bare URL; with `remote: false` (or the cache unseeded), confirm today's plain-URL phrasing is unchanged. No new fixture machinery is needed beyond what 3a's cache testing already covers, since 3b reads the identical file.

## Open questions / risks

1. **Unverified from the CLI alone:** does `--remote-control` fail soft or hard on a session whose auth cannot use it? Resolve empirically before defaulting `WM_REMOTE_CONTROL` on for any deployment that might run without `claude.ai` subscription auth (see "Ask 1" above).
2. **Account-wide session ceiling:** no evidence of one was found for independently-launched `--remote-control` processes (as opposed to the `claude remote-control` server subcommand's own `--capacity`), but this was not something that could be tested directly (it would require actually running many concurrent Remote-Control-visible sessions against a live account). Low risk at wingman's typical crew scale (cost discipline already caps fleets to a handful of concurrent members), but worth a mental note if a future large fan-out effort is ever run.
3. **wingman-not-in-tmux deployments:** the detect-and-notify half of ask 2 for wingman's own session has no effect if wingman is not itself running inside a tmux pane. This is a real, stated limitation rather than a bug - there is no channel to build around it with what Claude Code currently exposes.
4. **The `/config` "enable for all sessions" claim:** flagged above as unverified/likely not a real setting. If it turns out to exist after all (worth a quick manual check inside a real interactive session before implementation begins), it would not change the crew-visibility design (the explicit per-launch flag is more precise and controllable anyway) but could simplify wingman's own initial enablement.
5. **Ask 3's cached remote/local answer can go stale within a single wingman run** if the pilot's actual location changes mid-session (see condition B) - stated plainly above as a real limitation, not solved here, because nothing in the investigation found a live signal to watch for that change. This affects both consumers of the cache identically: a stale answer means 3a may under- or over-publish, and 3b may format links wrong for the pilot's actual current location, until the next wingman run re-asks.
6. **Ask 3's Artifact-hosting exposure model is stated from the tool's own description only** ("unlisted," not confirmed to be additionally access-controlled to the pilot's account) - this investigation could not go further than that wording; if a stronger or weaker guarantee is confirmed before implementation, condition C's framing should be adjusted accordingly rather than assuming either direction.
7. **`gitleaks` (or an equivalent) is an external dependency this repo does not currently have** - a real, if small, addition to `bin/doctor`'s dependency list. If the pilot would rather not add a new required dependency, the fallback is a smaller hand-rolled secret regex set with the explicit tradeoff that it needs manual upkeep as secret formats evolve - the design's recommendation is the maintained tool for that reason, but this is a legitimate place for the pilot to weigh in before implementation.
