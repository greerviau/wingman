# Half A live verification: `wm_harness_process_identity` and the four #383 audit defects

Date: 2026-08-19

Implements steps 1-5 of `docs/analysis/2026-08-18-remove-bin-wingman-launcher-spec.md`'s migration plan (§8, "Half A"). Grounded against the checkout current when this doc was written.

## §7 risk 1: process-ancestry hop counts, live-verified per harness

The spec's own pseudocode for `wm_harness_process_identity()` (§4.3) called for live verification against all five harness CLIs before shipping, not an assumed hop count. Each of the five was actually run, and a real bash-tool-call ancestor process was inspected via a diagnostic script capturing the full `pid/ppid/comm/args` chain from itself up to `systemd`.

Credentials on this machine cover only claude and opencode (opencode ships a free default model needing none) for a live end-to-end model turn. codex, grok, and pi were exercised through a minimal local mock OpenAI/Anthropic-compatible backend (`/v1/chat/completions` for grok, `/v1/responses` for codex, a custom `openai-completions` provider entry for pi) that inspects the harness's own `tools` schema and returns a real tool call invoking the diagnostic script — a genuine tool-call round trip through each CLI's own real code, not a stub of the mechanism being tested.

| Harness | Hops to match | Ancestor shape found |
|---|---|---|
| claude | 2 | self → `sh -c <command>` (Claude Code wraps every hook command string in a shell, confirmed even for a bare script path with no shell metacharacters) → `claude` |
| codex | 1 | self → `codex` (the vendored Rust binary) directly; its own `codex.js` launch shim, a further `node` ancestor above that, is never reached |
| grok | 2 | self → grok's own sandboxed `bash -O extglob -c ...` command wrapper (comm `bash`, not a match) → `grok` (the vendored binary); its own node trampoline is likewise never reached |
| opencode | 1 | self → `opencode` directly, a real compiled executable, no wrapper |
| pi | 1 | self → `pi` directly — pi's own Bash tool (`dist/core/tools/bash.js`) calls Node's `spawn()` with an argv array, never `shell: true`/a string command, so there is no wrapper shell to begin with; confirmed by reading the shipped source, not assumed |

All five resolve within 1-2 hops. The bound (`WM_HARNESS_WALK_MAX`, default 12) is generous specifically because the claude/grok cases show a *shell* wrapper can appear at all — a compound or piped real-world command could add another hop by defeating that shell's own tail-call exec optimization (observed directly: Claude Code's `sh -c` persisted as its own live process rather than collapsing, for reasons independent of command shape) — so the walk checks a bound rather than assuming any one fixed depth.

`comm` is what `ps -o comm=` reports, which reflects the *executed file's own basename* — confirmed live that this is unaffected by `argv[0]` (`exec -a NAME cmd` does not change it) and, for a shebang script, shows the *interpreter's* basename, not the script's. This is why codex/opencode/grok surface their own compiled-binary names directly while a bash wrapper always surfaces as `bash`.

## Step 1: `wm_harness_process_identity()`

Added to `bin/lib/harness-identity.sh`, a new file sourced by `bin/lib/common.sh` (so every existing consumer — `bin/watch-fleet`, `bin/spawn-crew`, `bin/crew-resume` — gets it for free) and sourced directly by the four per-tool-call hooks and `hooks/lib/watcher-liveness.sh`, which deliberately avoid `common.sh` itself (its `config.local.toml` load is a real `uv run` subprocess on any machine that has one, unacceptable on a per-tool-call hot path). Every sourcing site tolerates the file being absent (a partial/broken install), degrading to "no computed identity" rather than a raw shell error.

## Steps 2-4: every consumer of `$WINGMAN_RUN_ID`

`hooks/pilot-preferences-guard.sh`, `hooks/pilot-preferences-nudge.sh`, `hooks/artifact-link-guard.sh`, `hooks/pr-open-marker-tracker.sh`, `bin/watch-fleet`'s `$RUNFILE`/`$SUPPRESSEDFILE` stamps, `hooks/lib/watcher-liveness.sh`'s `wm_run_scoped_stamp_active`/`wm_run_scoped_marker_active`, and `bin/spawn-crew`/`bin/crew-resume`'s exported `WINGMAN_RUN_ID` line now all resolve `$WINGMAN_RUN_ID` when genuinely exported (a settable override — existing test fixtures depend on setting it directly), else `wm_harness_process_identity()`.

One correctness point beyond a mechanical substitution: `hooks/pilot-preferences-guard.sh`/`-nudge.sh` used to tell the model it could type the bare `"$WINGMAN_RUN_ID"` shell-variable reference as a shorthand for the escape-hatch command. That shorthand is now offered only when the value is genuinely exported — a computed identity was never exported into the model's own shell, so instructing it to type that reference would resolve to empty there and cache the answer under the wrong key. The primary escape-hatch form (which always embeds the resolved value literally) is unaffected either way.

## Step 5: the four audit defects, reproduced and confirmed fixed

Each row of the spec's own §2 audit table now has a real regression test, added to the existing test suite, that reproduces the exact defect shape via a deterministic fake harness ancestor (`wm_fake_harness_bin`, `tests/lib.sh` — a byte copy of `bash` under a literal `claude`/`codex`/etc. filename, since `ps -o comm=` tracks the executed file's own basename, not `argv[0]` or `exec -a`) rather than depending on whatever real process happens to be running the test suite.

- **`hooks/pilot-preferences-guard.sh` (the audit's "most severe finding")** — `tests/pilot-preferences-guard.test.sh`. Before: no `WINGMAN_RUN_ID` exported → the guard reports `[]` (silent no-op) for every tool call. After: run through a fake `claude` ancestor with no `WINGMAN_RUN_ID` exported, the guard now denies and names a real, non-empty computed run id in its escape hatch.
- **`hooks/artifact-link-guard.sh`** — `tests/artifact-link-guard.test.sh`. Before: `artifact_linking=artifact` cached under a real run id, but no `WINGMAN_RUN_ID` exported at report time → silent allow (`[]`), the publish requirement never checked. After: `artifact_linking=artifact` is cached under the *exact identity the guard will independently compute* (pre-seeded by a helper process sharing the same fake-claude ancestor), and the guard — run with no `WINGMAN_RUN_ID` exported — now denies, naming the deliverable.
- **`bin/watch-fleet` foreign-cycle takeover** — `tests/watch-fleet-lifecycle.test.sh`. Before: an old cycle stamped with one run's id, a new arm with no `WINGMAN_RUN_ID` exported → `owner_lock_alive`'s ownership check is unconditionally true, the foreign cycle is silently adopted as healthy. After: the new arm, run through a fake `claude` ancestor with no `WINGMAN_RUN_ID` exported, computes a real identity that differs from the old cycle's literal stamp, correctly detects it as foreign, and replaces it (`Replacing it with a cycle this run tracks`) — never `healthy`.
- **`hooks/lib/watcher-liveness.sh` marker/kill-stamp scoping (`wm_run_scoped_stamp_active`)** — verified directly (no launcher-based repro needed, unlike the audit's "not independently live-reproduced" note): with the CURRENT-side value literally empty, `wm_run_scoped_stamp_active` returns true against *any* stamp, including a real foreign run's own — the defect. With the computed identity substituted, it correctly rejects a foreign stamp and only defers ("cannot certify, honor it") when the *stored* stamp itself is empty, never merely because the *current* side used to be.

The one case each defect's fix still legitimately defers to legacy "honor it" behavior — neither side resolves at all (`ps` unavailable, or `WM_HARNESS_WALK_MAX=0`, an explicit test-only override) — is also covered, so the fix is proven to change behavior *only* where the audit found a real gap.

## Test suite

Full suite (`tests/run.sh`, 143 files) passes clean in isolation. Six pre-existing tests asserted the old no-op/relayed-empty behavior as correct (`tests/pilot-preferences-guard.test.sh`, `tests/pilot-preferences-nudge.test.sh`, `tests/crew-resume.test.sh`, `tests/watch-fleet-lifecycle.test.sh`, `tests/watch-fleet-classify.test.sh`) — updated to assert the new, fixed behavior, each alongside a `WM_HARNESS_WALK_MAX=0`-forced case preserving coverage of the genuine no-identity-resolvable fallback. `shellcheck -S error` (the CI invocation, both passes) is clean on every changed/added file.

## Explicit exception: none

All five harnesses got a live-verified hop count (the mock-backend approach let codex/grok/pi be tested for real despite this machine holding no working credentials for them) — no harness needed a documented fallback exception.
