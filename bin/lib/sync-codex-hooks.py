#!/usr/bin/env python3
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""sync-codex-hooks: reconcile codex's own USER-scope hooks file
($CODEX_HOME/hooks.json, default $HOME/.codex/hooks.json) against
bin/lib/user-hooks.json's orchestrator-active, codex-portable subset (the
orchestrator-guard-transports plan, §5.4.2).

Structurally parallel to bin/lib/sync-grok-hooks.py (a wingman-owned file
rendered fresh and written only when it differs - see that module's own
docstring for why this differs from sync-user-hooks.py's group-by-group
merge into a SHARED settings.json). One combined PreToolUse entry, matcher
`^(Bash|apply_patch|Edit|Write)$` (codex's own documented tool-name set,
plan §5.3), whose command is a single guard_dispatch.py --dialect codex
--guards <all-portable-guard-names> invocation. No repo-scoped file (plan
§5.7 - the project guard scope is not installed by this effort at all).

Two checks this module adds beyond grok's own reconciler, both required
because codex's own launch line carries --dangerously-bypass-hook-trust
(bin/lib/agents/codex.sh) to stop an untrusted-and-therefore-SKIPPED hook
from silently disabling enforcement:

  1. probe_feature_flag(): codex's own [features].hooks toggle (canonical
     key; codex_hooks is a documented deprecated alias that still works) -
     refuse if EITHER reads false in ANY layer codex actually reads,
     including requirements.toml (an admin-managed layer a user cannot
     override - see check_feature_flag_layers()'s own docstring for exactly
     which layers this probes and the honesty caveat on the one whose
     on-disk location was not independently re-confirmed this pass).
     Absent means enabled (the documented default) - only an EXPLICIT false
     refuses.
  2. check_no_foreign_hook_sources(): --dangerously-bypass-hook-trust
     un-gates EVERY enabled hook source for that invocation, not only
     wingman's own - so this refuses outright if any of codex's other four
     documented discovery paths carries a hook definition wingman did not
     write. Refusing on an unexpected source beats silently bypassing trust
     over it.

Both checks are narrow, hand-rolled scanners over TOML's LINE syntax (a
`[section]` header, or a `key = value` assignment), not a full TOML parser -
this repo's own python scripts carry no third-party dependencies
(`dependencies = []` above), and the two things being detected here (a
boolean flag under [features], and whether a [hooks...] table exists at
all) do not need one. A config file this cannot parse at all is not
silently skipped either (see load_toml_lines()).
"""
import argparse
import fcntl
import glob
import json
import os
import re
import stat
import sys

from hook_manifest import default_manifest, default_repo, load_manifest, portable_entries

DIALECT = "codex"
MATCHER = "^(Bash|apply_patch|Edit|Write)$"
TIMEOUT_SECONDS = 30

# The one enterprise-managed layer's on-disk location - named by the plan
# (§3.3: "admins can force them off via requirements.toml's
# [features].hooks = false") but not independently re-confirmed against the
# real binary this pass (no managed-config deployment exists in this
# environment to probe). Mirrors Claude Code's own analogous managed-
# settings convention (/etc/claude-code/managed-settings.json, confirmed
# directly in this same environment via `grok inspect --json`'s own
# managedSettingsPath field) - a reasonable, documented guess, not a
# confirmed fact. If codex's real path differs, this probe simply never
# finds a false there (fails to catch an admin override it should have) -
# it can never cause a FALSE refusal, only a missed one, so it is a safe
# default to ship while flagging the gap honestly rather than skipping the
# check entirely.
REQUIREMENTS_TOML_PATH = "/etc/codex/requirements.toml"


def default_codex_home():
    return os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex")


def hooks_json_path(codex_home):
    return os.path.join(codex_home, "hooks.json")


def guard_names(manifest, repo):
    names = sorted(set(
        hook["guard"] for _group, hook, _command, _event, _matcher in portable_entries(manifest, repo, DIALECT)
        if hook.get("guard")
    ))
    return names


def check_dispatcher(repo):
    dispatcher = os.path.join(repo, "hooks", "lib", "guard_dispatch.py")
    if not os.path.exists(dispatcher):
        print(f"error: dispatcher script not found: {dispatcher}", file=sys.stderr)
        sys.exit(2)
    return dispatcher


def desired_document(manifest, repo, wm_uv):
    dispatcher = check_dispatcher(repo)
    names = guard_names(manifest, repo)
    command = "%s %s --dialect %s --guards %s" % (wm_uv, dispatcher, DIALECT, ",".join(names))
    return {
        "hooks": {
            "PreToolUse": [
                {
                    "matcher": MATCHER,
                    "hooks": [
                        {"type": "command", "command": command, "timeout": TIMEOUT_SECONDS},
                    ],
                }
            ]
        }
    }


# --- narrow TOML line scanning (see module docstring for why not a real parser) --

_SECTION_RE = re.compile(r"^\[([^\[\]]+)\]\s*(#.*)?$")
_BOOL_ASSIGN_RE = re.compile(r"^([A-Za-z0-9_.\"'-]+)\s*=\s*(true|false)\s*(#.*)?$", re.IGNORECASE)


def load_toml_lines(path):
    """Yields (section_or_None, key, bool_value) for every plain
    `key = true|false` assignment line in `path` - section is the most
    recent `[section]` header text (None before the first one, i.e. a
    top-level key). Returns without yielding anything if the file does not
    exist. Any other read error is NOT swallowed - a config file that
    exists but cannot be read is exactly the kind of ambiguity this whole
    module fails closed on."""
    if not os.path.exists(path):
        return
    with open(path) as f:
        text = f.read()
    section = None
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        m = _SECTION_RE.match(stripped)
        if m:
            section = m.group(1).strip()
            continue
        m = _BOOL_ASSIGN_RE.match(stripped)
        if m:
            key = m.group(1).strip().strip("\"'")
            value = m.group(2).lower() == "true"
            yield section, key, value


def _hooks_flag_in_file(path):
    """True/False if this file's own [features] section (or a dotted
    `features.hooks`/`features.codex_hooks` top-level key) sets hooks
    (canonical) or codex_hooks (deprecated alias, plan §3.3) explicitly;
    None if the file does not exist or sets neither. The LAST matching
    assignment in the file wins (TOML's own semantics for a repeated key
    inside the same table - later lines override earlier ones)."""
    result = None
    for section, key, value in load_toml_lines(path):
        if section == "features" and key in ("hooks", "codex_hooks"):
            result = value
        elif section is None and key in ("features.hooks", "features.codex_hooks", "codex_hooks"):
            result = value
    return result


def check_feature_flag_layers(codex_home, repo, requirements_toml):
    """Refuses (returns a reason string) if [features].hooks (or its
    codex_hooks alias) reads explicitly false in ANY layer codex documents
    reading: $CODEX_HOME/config.toml (user), <repo>/.codex/config.toml
    (project - read even though this plan writes no project-scope FILE of
    its own, since a project config a human or another tool wrote could
    still disable hooks wingman then silently fails to enforce), and
    `requirements_toml` (the one admin-managed layer - see
    REQUIREMENTS_TOML_PATH's own honesty caveat on its default value).
    Absence in every layer means enabled (the documented default) - returns
    None (proceed) in that case."""
    layers = [
        os.path.join(codex_home, "config.toml"),
        os.path.join(repo, ".codex", "config.toml"),
        requirements_toml,
    ]
    for path in layers:
        flag = _hooks_flag_in_file(path)
        if flag is False:
            return (
                "codex's [features].hooks (or its deprecated codex_hooks alias) is "
                "explicitly disabled in %s - hooks are documented enabled by default, "
                "so an explicit false anywhere wins. Guard enforcement would be "
                "silently inert under codex with this set. Remove or flip that "
                "setting, or investigate why it is set before proceeding." % path
            )
    return None


def check_no_foreign_hook_sources(codex_home, repo):
    """--dangerously-bypass-hook-trust (bin/lib/agents/codex.sh) un-gates
    EVERY enabled hook source for that invocation, not only the one this
    module writes - so refuses (returns a reason string) if any of codex's
    OTHER four documented discovery paths (plan §3.3) carries a hook
    definition. Refusing on an unexpected source beats bypassing trust over
    it. Returns None (proceed) if none of the other four exist."""
    findings = []

    if _has_hooks_table(os.path.join(codex_home, "config.toml")):
        findings.append("inline [hooks] in %s" % os.path.join(codex_home, "config.toml"))

    repo_hooks_json = os.path.join(repo, ".codex", "hooks.json")
    if os.path.exists(repo_hooks_json):
        findings.append(repo_hooks_json)

    repo_config_toml = os.path.join(repo, ".codex", "config.toml")
    if _has_hooks_table(repo_config_toml):
        findings.append("inline [hooks] in %s" % repo_config_toml)

    # Plugin-bundled hooks/hooks.json - the documented discovery path whose
    # exact on-disk layout was not independently re-confirmed this pass
    # (see this module's own docstring); globbed under the plugins
    # directory codex's own `plugin add`/`plugin list` commands operate on.
    for path in sorted(glob.glob(os.path.join(codex_home, "plugins", "*", "hooks", "hooks.json"))):
        findings.append(path)

    if findings:
        return (
            "codex's launch line carries --dangerously-bypass-hook-trust, which "
            "un-gates EVERY enabled hook source for this invocation, not only "
            "wingman's own - and a hook source wingman did not write was found: "
            "%s. Refusing rather than silently bypassing trust over an unknown "
            "hook. Remove or account for the source above before proceeding." % "; ".join(findings)
        )
    return None


def _has_hooks_table(path):
    if not os.path.exists(path):
        return False
    with open(path) as f:
        text = f.read()
    for line in text.splitlines():
        stripped = line.strip()
        if re.match(r"^\[hooks(\.[^\]]*)?\]", stripped):
            return True
    return False


def load_existing(path):
    if not os.path.exists(path):
        return None
    with open(path) as f:
        text = f.read()
    if not text.strip():
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError as e:
        print(f"error: could not parse existing {path}: {e}", file=sys.stderr)
        sys.exit(2)


def write_document(path, doc):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    mode = None
    if os.path.exists(path):
        mode = stat.S_IMODE(os.stat(path).st_mode)
    tmp_path = f"{path}.tmp-{os.getpid()}"
    with open(tmp_path, "w") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    if mode is not None:
        os.chmod(tmp_path, mode)
    os.replace(tmp_path, path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--settings", default=None, help="path to $CODEX_HOME/hooks.json (default: real path)")
    ap.add_argument("--codex-home", default=None, help="$CODEX_HOME override (default: real env/default)")
    ap.add_argument("--manifest", default=None, help="path to user-hooks.json (default: sibling of this script)")
    ap.add_argument("--repo", default=None, help="repo root the dispatcher command resolves against")
    ap.add_argument("--wm-uv", default="uv run --no-project --quiet", help="the uv invocation prefix to bake into the registered command")
    ap.add_argument("--check", action="store_true", help="report status only, never write")
    ap.add_argument("--requirements-toml", default=None,
                     help="path to the admin-managed requirements.toml layer (default: REQUIREMENTS_TOML_PATH; override for test isolation)")
    args = ap.parse_args()

    codex_home = args.codex_home or default_codex_home()
    settings_path = args.settings or hooks_json_path(codex_home)
    manifest_path = args.manifest or default_manifest()
    repo = args.repo or default_repo()
    requirements_toml = args.requirements_toml or REQUIREMENTS_TOML_PATH

    manifest = load_manifest(manifest_path)

    flag_reason = check_feature_flag_layers(codex_home, repo, requirements_toml)
    if flag_reason:
        print(f"error: {flag_reason}", file=sys.stderr)
        sys.exit(2)

    foreign_reason = check_no_foreign_hook_sources(codex_home, repo)
    if foreign_reason:
        print(f"error: {foreign_reason}", file=sys.stderr)
        sys.exit(2)

    desired = desired_document(manifest, repo, args.wm_uv)
    existing = load_existing(settings_path)

    if existing == desired:
        sys.exit(0)

    if args.check:
        sys.exit(1)

    lock_path = f"{settings_path}.wm-lock"
    parent = os.path.dirname(settings_path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    try:
        lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
    except OSError as e:
        print(f"error: could not open lock file {lock_path}: {e}", file=sys.stderr)
        sys.exit(2)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        existing = load_existing(settings_path)
        if existing != desired:
            write_document(settings_path, desired)
            print(f"wrote codex hooks file: {settings_path}", file=sys.stderr)
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)

    sys.exit(0)


if __name__ == "__main__":
    main()
