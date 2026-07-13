# Review: PR #27 - PreToolUse delegation guard (issue #17, Track A)

Reviewer: crew `review-pr-27-github-com-greervia-reviewer`.
Date: 2026-07-11.
Scope: `github.com/greerviau/wingman` PR #27, branch `feat/pretooluse-delegation-guard`, against issue #17 and the Track A section of `docs/plans/2026-07-11-four-reliability-issues-decomposition.md`.

## Verdict: approve (after fix in `27ebe4c`)

Initial pass (commit `9124892`) found one high-severity, confirmed correctness bug in the Bash test-runner pattern matching.
The developer's follow-up commit `27ebe4c` ("match the invoked command, not a raw substring, in the test-runner guard") fixes it: matching now walks each `;`/`&&`/`||`/pipe-separated segment's tokens (via `shlex`) and checks the command actually being invoked - unwrapping `sudo`/`env`/`bash`/`sh`/`zsh`/`uv run` - against a runner allowlist, instead of a raw substring search over the whole command string.
Re-verification (below) confirms the original false-positive repro table is now allowed, all original true positives (and new wrapper/chaining cases) still deny, and the full test suite is green with no regressions.
Orchestrator/worker scoping, the `Stop`-hook interaction, and test coverage/conventions were correct from the first pass and remain so.

## Method

- Read the PR diff (`gh pr diff 27`) and PR description against the Track A spec.
- Checked out the branch in an isolated worktree and ran `tests/no-direct-edit-guard.test.sh` (43/43 pass) and the full suite `tests/run.sh` (all suites pass, no regressions).
- Manually drove `hooks/no-direct-edit-guard.sh` with hand-built `PreToolUse` JSON payloads across the crew-type matrix and a set of Bash commands the existing test suite does not cover, to probe the "narrow enough" requirement specifically.

## Findings

### 1. [High, confirmed] Test-runner Bash regex matches anywhere in the command line, not just at an actual invocation, denying legitimate orchestration Bash calls

**File:** `hooks/no-direct-edit-guard.sh`, the `test_patterns` list and `any(re.search(p, command) for p in test_patterns)` check (around lines 70-90).

Each pattern (`pytest`, `npm test`, `go test`, `make test`, `tests?/[^\s]*\.test\.sh`, etc.) is matched with `re.search` against the raw command string with only a loose word-boundary/prefix guard.
None of them require the matched token to be the command actually being *run* - a substring occurrence anywhere in the line (inside a `grep` pattern, a `git log --grep`, a filename argument to `cat`, a package name, free text after `echo`) trips the same deny path as an actual `pytest`/`make test` invocation.

**Reproduced** (top-level scope, i.e. wingman's own layer - the scope this guard exists to protect):

| Command | Intent | Guard's verdict |
|---|---|---|
| `cat tests/run.sh` | read a test file to check conventions | **denied** |
| `grep -rn pytest .` | search the codebase for a string | **denied** |
| `git log --grep='fix go test flake'` | search commit history | **denied** |
| `gh pr view 26 \| grep -i 'npm test'` | routine PR inspection | **denied** |
| `pip install pytest-mock` | install a test dependency (e.g. for a plan step) | **denied** |
| `echo 'run make test later'` | anything containing that phrase | **denied** |

`cat tests/run.sh` is the sharpest example: it is precisely the kind of read-only orchestration command a lead or wingman session runs constantly (including this review - I read `tests/run.sh` and `tests/lib.sh` directly to check the new test's conventions), and it is denied outright because the path substring `tests/run.sh` matches the `tests?/run\.sh\b` pattern regardless of which tool is reading it.

**Failure scenario:** A lead session investigating a test failure runs `git log --grep="go test"` to find when a flake was introduced, or a wingman session runs `cat tests/run.sh` to check the test suite's structure before delegating a fix - both are exactly the "generic Bash" orchestration the spec explicitly requires to stay unblocked (`gh`, `git`, `ls`, `grep`, ...), and both get redirected to `bin/spawn-crew` as if they'd tried to run the test suite directly.
At sufficient frequency this reproduces the exact failure mode the spec warns about: breaking a lead's or wingman's own orchestration Bash calls.

**Why the existing test suite didn't catch it:** the "generic Bash stays unblocked" test block (`tests/no-direct-edit-guard.test.sh`, the `for cmd in "gh pr view 26" "git status" "ls -la" "grep -rn foo ." ...` loop) exercises `grep`/`gh`/`cat`/etc. but never with a test-runner word as an argument or search term - so the substring-match behavior has no covering test in either direction.

**Suggested direction (for the developer to design, not prescribed here):** match against the command name actually being invoked - the first token of the command or of each pipeline/`;`/`&&`/`||`-separated segment - against a runner allowlist (`pytest`, `npm`/`yarn`/`pnpm` with a `test` subcommand, `go`, `cargo`, `rspec`, `jest`, `mocha`, `make`, a `tests/*.test.sh` or `tests/run.sh` path used as the segment's own command), rather than a raw substring search over the entire string.
That would still catch `uv run pytest`, `bash tests/run.sh`, `npm test`, etc. (all already covered by the passing test suite) while no longer tripping on the runner word appearing as someone else's argument.

## What was verified as correct

- **Orchestrator-vs-worker scoping (spec point 1):** `bin/spawn-crew`'s env-export block now exports `WINGMAN_CREW_TYPE=$TYPE` right alongside `WINGMAN_CREW_ID`, outside the playbook-resolution region PR #26 owns (confirmed by diff inspection - matches the plan's stated constraint).
  The hook's guard condition (`[ -n "$WINGMAN_CREW_ID" ] && [ "$WINGMAN_CREW_TYPE" != "lead" ] -> exit 0`) correctly leaves top-level wingman (unset `WINGMAN_CREW_ID`) and `lead` guarded, and every worker type (`developer`, `architect`, `reviewer`, `software-analyst`, `research`, and untested custom types by construction, since the check is a `!= "lead"` allowlist-of-one-exclusion, not a denylist) unguarded.
  Verified by the E2E suite and by direct manual runs across the type matrix.
- **`Edit`/`Write`/`NotebookEdit` blocking:** unconditional deny at orchestrator scope, correct `hookSpecificOutput.permissionDecision: "deny"` schema (distinct from `stop-guard.sh`'s `Stop`-hook `decision`/`reason` shape, as it must be for `PreToolUse`).
- **No regression or conflict with `hooks/stop-guard.sh` / the existing `Stop` hook (spec point 3):** `.claude/settings.json`'s diff only adds a new `PreToolUse` array entry alongside the untouched `Stop` entry; the two hooks are independent files with no shared state, and the full test suite (`tests/stop-guard.test.sh` included) still passes unmodified on this branch.
- **Test coverage and conventions (spec point 4, modulo the gap above):** `tests/no-direct-edit-guard.test.sh` follows `tests/lib.sh` conventions where they apply (it is picked up automatically by `tests/run.sh`'s glob; it correctly skips `test_new_home`/`WINGMAN_HOME` isolation since the hook touches no state - only env vars - so there is nothing to isolate).
  43/43 assertions pass; the full suite (`tests/run.sh`, all suites including `tests/playbook-resolution.test.sh`) passes with no regressions on this branch.

## Re-verification of the fix (commit `27ebe4c`)

Re-checked out the branch at `27ebe4c` in a fresh worktree and re-ran everything from the initial pass.

**Original false-positive table - now all allowed (no output):**

| Command | Verdict |
|---|---|
| `cat tests/run.sh` | ALLOWED |
| `grep -rn pytest .` | ALLOWED |
| `git log --grep='fix go test flake'` | ALLOWED |
| `gh pr view 26 \| grep -i 'npm test'` | ALLOWED |
| `pip install pytest-mock` | ALLOWED |
| `echo 'run make test later'` | ALLOWED |

**True positives - still denied, including cases new to this fix's own branching logic (wrapper unwrapping, chaining):**
`pytest tests/`, `npm test`, `npm run test`, `go test ./...`, `cargo test`, `make test`, `uv run pytest`, `python3 -m pytest`, `bash tests/run.sh`, `bash tests/stop-guard.test.sh`, `rspec`, `jest`, `mocha`, `sudo make test`, `env FOO=bar pytest`, `yarn test`, `cd /tmp && pytest`, `echo hi; npm test`, `true && go test ./...`, `bash -c 'pytest'` - all denied correctly.

**Additional edge probes to check the fix itself didn't reintroduce a false positive via its new wrapper-unwrapping logic** - all correctly allowed: `echo 'pytest is a great tool'`, `python -c 'print(1)'`, `npm install`, `npm run build`, `make build`, `cat Makefile | grep test`, `bash -c 'echo pytest'`, `bash -c 'echo hi'`, `sh -c 'grep -rn pytest .'`, `find . -name '*.test.sh'`, `ls tests/`, `bin/spawn-crew --type developer --objective 'run tests'`.

**Test suite:** `tests/no-direct-edit-guard.test.sh` now carries 54 assertions (11 new: 5 true-positive wrapper/chaining cases, 6 codifying the original false-positive repro table), 54/54 pass.
Full suite `tests/run.sh` (16 suites, all previously-passing suites plus this one) - all green, no regressions.

One residual imperfection noted but not worth blocking on: `bash -c '<script body>'` is only handled by stripping leading `-c`-style flags and re-checking the remaining tokens as if they were the next segment's command - which happens to work for the simple cases tested here, but isn't a real shell-script parse, so a `bash -c` body with control flow before the runner invocation (e.g. `bash -c 'if true; then pytest; fi'`) would not be caught as a deny.
This is a false-negative gap, not a regression of the false-positive bug this fix was checked against, and matches the spec's own "use judgment" scoping for the Bash side of this guard - flagging for awareness, not blocking.

## Non-findings considered and ruled out

- Custom/unlisted worker crew types (e.g. a future `data-scientist` playbook): the guard condition is `!= "lead"`, i.e. an allowlist-of-one exclusion rather than a denylist of known worker types, so any new worker type is unguarded by construction without needing a hook update. Correct per spec.
- `WINGMAN_CREW_TYPE` case sensitivity (a hypothetical `--type Lead`): not reachable - `--type` must resolve to an existing playbook filename via `wm_resolve_playbook`, and playbook filenames are lowercase by convention, so a case-mismatched type fails spawn before the env var is ever set.
- JSON-parse failure / malformed hook payload: the Python helper fails open (allows) on a parse exception, matching `stop-guard.sh`'s existing fail-open convention on this repo - not a regression introduced by this PR.
