// wake-loop-probe.js - the executable evidence behind the plan's finding that
// pi has the primitives wingman's wake loop is built from. Not shipped code:
// this is a probe, kept in the repo so the claim stays auditable rather than
// surviving only as prose in a document.
//
// What it demonstrates, and nothing more:
//   1. `agent_settled` fires after a turn fully settles, and fires AGAIN after
//      a turn this probe itself triggered - so the cycle re-arms.
//   2. A BLOCKING wait can be held inside the extension (a real subprocess),
//      which is why pi needs no `run_in_background` equivalent on a
//      model-issued tool call for a watcher to be armed.
//   3. `sendUserMessage` re-invokes the session, and the model genuinely acts
//      in the woken turn.
//
// What it does NOT demonstrate: a continuity transport. hooks/stop-continuity.sh
// is ~950 lines of accounting - singleton claim, spurious-failure budget,
// standdown markers, blocked-owner re-assertion, kill switch - none of which
// this touches.
//
// Run: pi --provider <p> --approve --no-session --no-context-files \
//        --no-extensions -e <this file>
// then send any ordinary opening message. Markers land in $PI_WAKE_PROBE_DIR
// (default: the cwd).
import { spawnSync } from "node:child_process";
import { appendFileSync } from "node:fs";

const DIR = process.env.PI_WAKE_PROBE_DIR || process.cwd();
let rewakes = 0;

export default function (pi) {
  pi.registerFlag("wingman-wake-probe", {
    description: "wake-loop probe (evidence only, not a wingman guard)",
    type: "boolean",
    default: false,
  });

  pi.on("agent_settled", async () => {
    appendFileSync(`${DIR}/settled.marker`, `settled rewakes=${rewakes}\n`);
    if (rewakes >= 1) return;           // one rewake only - never an unbounded loop
    rewakes++;

    // Stands in for a blocking `bin/watch-fleet` arm. Held by the EXTENSION,
    // not by a tool call the model issued - that is the whole point.
    const t0 = Date.now();
    spawnSync("sleep", ["3"]);
    appendFileSync(`${DIR}/watcher.marker`, `blocked_ms=${Date.now() - t0}\n`);

    pi.sendUserMessage(
      `WAKE EVENT. Use the bash tool once to run exactly: touch ${DIR}/rewoke.marker  -- then reply DONE.`,
    );
    appendFileSync(`${DIR}/sent.marker`, "sendUserMessage called\n");
  });
}
