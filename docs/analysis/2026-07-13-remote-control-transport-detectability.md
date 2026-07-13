# Can a Claude Code session tell Remote Control apart from a local terminal turn?

Date: 2026-07-13.

## Question

Is there a signal available to a running Claude Code session (env var, hook input field, session metadata, transport indicator) that distinguishes "this turn arrived via Remote Control" from "this turn was typed at the local terminal"?

## Answer: no, not for the way wingman launches sessions

This was already investigated exhaustively in `docs/plans/2026-07-12-remote-control-visibility-and-auto-reconnect-design.md` (the design doc behind PR #34, "Is 'the pilot is on Remote Control right now' detectable?" section), verified directly against the installed `claude` v2.1.207 binary (`claude --help`, embedded strings). Summary of what was checked, all confirmed absent:

- **Hook payload:** the CLI's complete hook-event table (`PermissionRequest`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Notification`, `Stop`, `PreCompact`, `PostCompact`, `UserPromptSubmit`, `SessionStart`) carries only `session_id`, `tool_name`, `tool_input`, `tool_response` — no client/source/transport field on any event.
- **State file:** no live "remote connected" file exists under `~/.claude` or `~/.claude.json`. The only persisted Remote Control state is two *global, one-time* flags (`hasUsedRemoteControl`, `remoteDialogSeen`) — static, account-wide, not per-session presence.
- **Env var:** `process.env.CLAUDE_CODE_ENTRYPOINT` classifies *how the process itself was launched* (`remote`/`remote_mobile`/`cli`/etc.), not whether a remote viewer is currently attached to an ordinarily-launched session. wingman and every crew member are always launched the ordinary way (`exec claude ...`), so this reads `cli` regardless of whether `--remote-control` is active.
- **Tool query:** the CLI does track a live `clientType`-style notion internally (found in the binary's strings), and it surfaces as a side effect of the built-in `PushNotification` tool's delivery-reason codes (`user_present`, `no_transport`, `remote-control`) — but only when a notification is actually sent, not as a free, silent status query. Using it purely to probe presence would misuse the tool and still costs a real interruption each call.

## Bottom line

The session is genuinely unaware of the transport for a normally-launched interactive session — Remote Control attaches to the same session transparently, with no exposed signal a hook or script can read. This is a real absence in what Claude Code exposes today, not a gap in wingman's design.

This is why PR #34's design falls back to asking the pilot once (`AskUserQuestion`) and caching the answer per wingman run (`$WM_HOME/pilot-location.json`, keyed by `WINGMAN_RUN_ID`) rather than attempting silent detection.
