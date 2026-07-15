#!/usr/bin/env python3
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""usage-statusline: the Claude Code `statusLine` command wingman installs,
user-level, to capture the CLI's own proactive usage-quota signal (issue #24).

Claude Code invokes the configured statusLine command periodically and feeds
it a JSON payload on stdin. For a Claude.ai-subscription session, that
payload carries a `rate_limits` object (populated after the session's first
API response):

  "rate_limits": {
    "five_hour": {"used_percentage": number, "resets_at": number},
    "seven_day": {"used_percentage": number, "resets_at": number}
  }

Both sub-keys are optional (a non-subscription session, or one that hasn't
had its first API response yet, has neither). This is fleet-wide "for free":
`rate_limits` reflects the account's own rolling usage window, shared across
every concurrent session under that login, so a fresh reading from any one
session (wingman's own top-level session, or any crew member) is
representative of the whole fleet's exposure.

Deliberately NOT gated on "is this a wingman session" - the signal is
meaningful regardless of which project the session is rooted in, so even a
pilot's unrelated Claude Code session on the same machine still reports the
same shared account quota.

Writes `$WINGMAN_HOME/usage/<session_id>.json` atomically:
  {"five_hour": {...}, "seven_day": {...}, "captured_at": "<iso8601 utc>"}

Chains to any previously-configured statusline command (--chain) so
installing this never silently changes what the pilot visually sees in
their terminal: with --chain, this script re-execs that command with the
same stdin and passes its stdout straight through unchanged. Without
--chain, it prints nothing (crew sessions run unattended, so no visible
statusline is needed there).

Never raises or exits non-zero: any failure (bad JSON, unwritable
directory, a broken chained command) is swallowed so a broken usage probe
can never break the pilot's terminal or a crew session's startup.
"""
import datetime
import json
import os
import subprocess
import sys
import tempfile


def home():
    return os.path.expanduser(os.environ.get("WINGMAN_HOME") or "~/.wingman")


def write_json_atomic(path, obj):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".tmp.", dir=d)
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(obj, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def capture(stdin_text):
    try:
        payload = json.loads(stdin_text)
    except (ValueError, TypeError):
        return
    if not isinstance(payload, dict):
        return

    session_id = payload.get("session_id")
    rate_limits = payload.get("rate_limits")
    if not session_id or not isinstance(rate_limits, dict):
        return

    five_hour = rate_limits.get("five_hour")
    seven_day = rate_limits.get("seven_day")
    if not isinstance(five_hour, dict):
        five_hour = None
    if not isinstance(seven_day, dict):
        seven_day = None
    if five_hour is None and seven_day is None:
        # No usage data at all yet (a non-subscription session, or one that
        # hasn't had its first API response) - write nothing, so a
        # subscriptionless session never leaves behind a spurious "0% used"
        # reading that would look like a real, fresh signal.
        return

    record = {"captured_at": now_iso()}
    if five_hour is not None:
        record["five_hour"] = five_hour
    if seven_day is not None:
        record["seven_day"] = seven_day

    safe_id = "".join(c if (c.isalnum() or c in "._-") else "_" for c in str(session_id))
    path = os.path.join(home(), "usage", safe_id + ".json")
    try:
        write_json_atomic(path, record)
    except OSError:
        pass


def run_chain(chain_command, stdin_text):
    # chain_command is the pilot's own pre-existing statusLine command, exactly
    # as it was configured - itself a shell command string (it may use pipes,
    # quoting, environment expansion, etc.), not a plain argv list - so it must
    # be re-executed through a shell, the same way Claude Code itself invokes
    # any statusLine command.
    try:
        proc = subprocess.run(
            chain_command,
            shell=True,
            input=stdin_text,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return
    if proc.stdout:
        sys.stdout.write(proc.stdout)


def main():
    argv = sys.argv[1:]
    chain_command = None
    if argv and argv[0] == "--chain" and len(argv) > 1:
        chain_command = argv[1]

    try:
        stdin_text = sys.stdin.read()
    except Exception:
        stdin_text = ""

    try:
        capture(stdin_text)
    except Exception:
        pass

    if chain_command:
        try:
            run_chain(chain_command, stdin_text)
        except Exception:
            pass


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
