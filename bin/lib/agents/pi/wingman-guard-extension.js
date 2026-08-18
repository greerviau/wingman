// wingman-guard-extension.js - the pi-extension guard transport (the
// orchestrator-guard-transports plan, §5.4.5).
//
// Install: none. This file ships in the repo and is loaded by appending
// `-e <abs path> --no-extensions` to pi's own launch line (bin/lib/agents/
// pi.sh's WM_AGENT_GUARD_LAUNCH_FLAGS) - nothing is written outside the
// repo, nothing reconciles, nothing can drift. `-e` loading under
// `--no-extensions` is hands-on confirmed (plan §3.2), so the guard set is
// exactly what wingman supplied and cannot be joined by a project-local
// extension.
//
// The handler shells out to hooks/lib/guard_dispatch.py --dialect pi for
// every decision (guard_policy.py's own evaluators are the single source of
// policy - see that module's own docstring). The shim FAILS CLOSED: it
// blocks unless an explicit, well-formed {"decision": "allow"} verdict came
// back on stdout, and blocks on any spawn/parse failure or unexpected exit
// status - the same inversion as the opencode-plugin shim (an earlier draft
// of that shim only blocked on an explicit deny, under which a spawn
// failure, a non-zero exit with no stdout, or a timeout would all fall
// through as allow). pi's own harness re-throwing a throwing handler as
// "Extension failed, blocking execution" (confirmed by reading
// dist/core/agent-session.js and dist/core/extensions/runner.js - see plan
// §3.2) is defense in depth behind this, not a substitute for it: this
// handler's own normal deny path is a RETURNED {block, reason}, the
// documented channel, not a thrown exception.
//
// registerFlag("wingman-guard-active", ...) has exactly one purpose: to be
// observable by bin/lib/guard-transport.sh's own preflight via
// `pi --offline -e <this file> --help`, which counts occurrences of
// `--wingman-guard-active` in the printed "Extension CLI Flags:" section (1
// if this file loaded, 0 if it did not - pi silently tolerates a broken or
// missing extension, so exit status alone proves nothing; see plan §3.2).
// The flag's own value is never read.

import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// bin/lib/agents/pi/wingman-guard-extension.js -> bin/lib/agents/pi -> ...
// -> repo root, four directories up - computed once from this file's own
// location, matching every other component in this plan's own convention
// (hooks/lib/guard_policy.py's _REPO_ROOT, hooks/*.sh's own HERE/REPO walk).
const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "..");
const DISPATCHER = join(REPO_ROOT, "hooks", "lib", "guard_dispatch.py");
const HOOK_MANIFEST = join(REPO_ROOT, "bin", "lib", "hook_manifest.py");

const WM_UV = process.env.WM_UV || "uv";
const WM_UV_ARGS = process.env.WM_UV ? [] : ["run", "--no-project", "--quiet"];

// The portable guard set for pi, read from bin/lib/user-hooks.json's own
// 'portable' field via hook_manifest.py --print-guards - never hard-coded
// here, so a guard added to the manifest's portable set later reaches this
// extension with nothing else to update (the identical computation bin/lib/
// guard-transport.sh's own self-test invocations and every non-Claude
// reconciler already share). Resolved lazily, on first use, and cached -
// not at module load time: a failure here must reach the SAME fail-closed
// path as a dispatcher failure (a returned {block: true}), never a module-
// load exception, since pi silently tolerates a broken/missing extension
// (plan §3.2) - a load-time throw would disable this guard's ENTIRE guard
// set instead of merely denying one call.
let cachedGuards = null;

function getGuards() {
	if (cachedGuards !== null) {
		return cachedGuards;
	}
	const result = spawnSync(WM_UV, [...WM_UV_ARGS, HOOK_MANIFEST, "--print-guards", "pi", "--repo", REPO_ROOT], {
		encoding: "utf8",
		timeout: 15000,
	});
	if (result.error) {
		throw result.error;
	}
	if (result.status !== 0) {
		throw new Error(`hook_manifest.py --print-guards pi failed (exit ${result.status}): ${result.stderr}`);
	}
	cachedGuards = result.stdout.trim();
	return cachedGuards;
}

function runDispatcher(payload) {
	const args = [...WM_UV_ARGS, DISPATCHER, "--dialect", "pi", "--guards", getGuards()];
	const result = spawnSync(WM_UV, args, {
		input: JSON.stringify(payload),
		encoding: "utf8",
		timeout: 15000,
	});
	if (result.error) {
		throw result.error;
	}
	if (result.status === null) {
		throw new Error(`dispatcher timed out or was killed (signal ${result.signal})`);
	}
	let verdict;
	try {
		verdict = result.stdout ? JSON.parse(result.stdout) : null;
	} catch (e) {
		throw new Error(`dispatcher produced unparseable stdout: ${result.stdout}`);
	}
	return verdict;
}

export default function (pi) {
	pi.registerFlag("wingman-guard-active", {
		description: "internal - observable-only marker that the wingman guard extension loaded",
		type: "boolean",
		default: false,
	});

	pi.on("tool_call", async (event, _ctx) => {
		let verdict;
		try {
			verdict = runDispatcher({
				toolName: event.toolName,
				input: event.input,
				cwd: process.cwd(),
			});
		} catch (err) {
			return { block: true, reason: `wingman guard could not run, so this call is denied: ${err}` };
		}
		if (!verdict || verdict.decision !== "allow") {
			return {
				block: true,
				reason:
					(verdict && verdict.reason) ||
					"wingman guard returned no usable verdict, so this call is denied",
			};
		}
		return undefined;
	});
}
