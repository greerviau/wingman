#!/usr/bin/env python3
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""user_hook_entry: the single definition of a Claude Code hook entry's shape
and match semantics, shared by bin/lib/install-user-hook.py and
bin/lib/sync-user-hooks.py (issue #231) so the two reconcilers cannot drift
apart on either.

Both reconcilers used to match an existing entry on `command` alone, which
reads an entry already registered with stale `entry_options` (e.g. a
continuity hook's own `timeout`) as "already registered" forever - raising
the manifest/CLI value alone would then change nothing on any machine that
has ever run either reconciler. entry_matches() makes that comparison
attribute-aware, but only for whichever attributes the caller actually
supplies in `entry_options`: a caller that passes `{}` (every existing call
site except the fleet-continuity pair) gets the exact same command-only
match as before.
"""


def desired_entry(command, entry_options):
    """The hook entry dict for `command` carrying whichever of
    asyncRewake/timeout/rewakeSummary `entry_options` sets - the identical
    shape both reconcilers register."""
    entry = {"type": "command", "command": command}
    if entry_options.get("asyncRewake"):
        entry["asyncRewake"] = True
    if "timeout" in entry_options:
        entry["timeout"] = entry_options["timeout"]
    if "rewakeSummary" in entry_options:
        entry["rewakeSummary"] = entry_options["rewakeSummary"]
    return entry


def entry_matches(h, command, entry_options):
    """True iff hook-entry dict `h` is the same registration as
    desired_entry(command, entry_options) would produce - `command` always
    compared, and each of asyncRewake/timeout/rewakeSummary compared only
    when `entry_options` names it. An attribute `entry_options` does not
    name is never compared, so a caller that supplies `{}` matches on
    `command` alone, exactly like the pre-#231 behavior."""
    if not isinstance(h, dict) or h.get("command") != command:
        return False
    if "asyncRewake" in entry_options and bool(h.get("asyncRewake")) != bool(entry_options["asyncRewake"]):
        return False
    if "timeout" in entry_options and h.get("timeout") != entry_options["timeout"]:
        return False
    if "rewakeSummary" in entry_options and h.get("rewakeSummary") != entry_options["rewakeSummary"]:
        return False
    return True
