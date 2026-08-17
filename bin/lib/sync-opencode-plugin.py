#!/usr/bin/env python3
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""sync-opencode-plugin: render bin/lib/agents/opencode/wingman-guard.js.tmpl
into $HOME/.config/opencode/plugins/wingman-guard.js (the orchestrator-
guard-transports plan, §5.4.4). Global scope only - no project-scoped
plugin (plan §5.7). opencode auto-loads every file in that directory at
startup (plan §3.5); nothing else about this is reconciled or merged the
way sync-user-hooks.py's shared settings.json must be - the rendered file
is wingman's own, written wholesale and only when its content differs from
what is already on disk (the same shape as sync-grok-hooks.py/sync-codex-
hooks.py's own reconcilers).

Renders four placeholders (see the template's own header comment) as JSON-
encoded JS literals - never raw string interpolation, so a path or guards
list containing a quote/backslash cannot break the generated file's own
syntax. Fails closed on every ambiguity: a missing template, a template that
does not contain all four placeholders exactly once, or a dispatcher script
that does not exist.
"""
import argparse
import fcntl
import json
import os
import stat
import subprocess
import sys

from hook_manifest import default_manifest, default_repo, load_manifest, portable_guard_names

DIALECT = "opencode"
TEMPLATE_RELPATH = os.path.join("bin", "lib", "agents", "opencode", "wingman-guard.js.tmpl")
PLACEHOLDERS = ("__WM_UV_JSON__", "__WM_UV_ARGS_JSON__", "__WM_DISPATCHER_JSON__", "__WM_GUARDS_JSON__")


def default_plugin_path():
    return os.path.join(os.path.expanduser("~"), ".config", "opencode", "plugins", "wingman-guard.js")


def check_dispatcher(repo):
    dispatcher = os.path.join(repo, "hooks", "lib", "guard_dispatch.py")
    if not os.path.exists(dispatcher):
        print(f"error: dispatcher script not found: {dispatcher}", file=sys.stderr)
        sys.exit(2)
    return dispatcher


def load_template(repo):
    template_path = os.path.join(repo, TEMPLATE_RELPATH)
    if not os.path.exists(template_path):
        print(f"error: plugin template not found: {template_path}", file=sys.stderr)
        sys.exit(2)
    with open(template_path) as f:
        text = f.read()
    missing = [p for p in PLACEHOLDERS if text.count(p) != 1]
    if missing:
        print(f"error: template {template_path} does not contain each placeholder exactly once: {missing}", file=sys.stderr)
        sys.exit(2)
    return text


def render(repo, wm_uv_argv):
    dispatcher = check_dispatcher(repo)
    manifest = load_manifest(default_manifest())
    names = portable_guard_names(manifest, repo, DIALECT)
    template = load_template(repo)

    uv_bin = wm_uv_argv[0]
    uv_args = wm_uv_argv[1:]

    text = template
    text = text.replace("__WM_UV_JSON__", json.dumps(uv_bin))
    text = text.replace("__WM_UV_ARGS_JSON__", json.dumps(uv_args))
    text = text.replace("__WM_DISPATCHER_JSON__", json.dumps(dispatcher))
    text = text.replace("__WM_GUARDS_JSON__", json.dumps(",".join(names)))
    return text


def load_existing(path):
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return f.read()


def write_file(path, text):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    mode = None
    if os.path.exists(path):
        mode = stat.S_IMODE(os.stat(path).st_mode)
    tmp_path = f"{path}.tmp-{os.getpid()}"
    with open(tmp_path, "w") as f:
        f.write(text)
    if mode is not None:
        os.chmod(tmp_path, mode)
    os.replace(tmp_path, path)


def check_node_syntax(path):
    try:
        result = subprocess.run(["node", "--check", path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
    except (OSError, subprocess.TimeoutExpired) as e:
        print(f"error: could not run `node --check` on {path}: {e}", file=sys.stderr)
        sys.exit(2)
    if result.returncode != 0:
        print(f"error: `node --check {path}` failed:\n{result.stderr.decode(errors='replace')}", file=sys.stderr)
        sys.exit(2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plugin-path", default=None, help="path to render wingman-guard.js to (default: real global plugin path)")
    ap.add_argument("--repo", default=None, help="repo root the template/dispatcher resolve against")
    ap.add_argument("--wm-uv", default="uv run --no-project --quiet", help="the uv invocation prefix to bake into the rendered file")
    ap.add_argument("--check", action="store_true", help="report status only, never write")
    ap.add_argument("--skip-node-check", action="store_true", help="test/dev escape hatch when node is unavailable")
    args = ap.parse_args()

    plugin_path = args.plugin_path or default_plugin_path()
    repo = args.repo or default_repo()
    wm_uv_argv = args.wm_uv.split()
    if not wm_uv_argv:
        print("error: --wm-uv must not be empty", file=sys.stderr)
        sys.exit(2)

    desired = render(repo, wm_uv_argv)
    existing = load_existing(plugin_path)

    if existing == desired:
        sys.exit(0)

    if args.check:
        sys.exit(1)

    lock_path = f"{plugin_path}.wm-lock"
    parent = os.path.dirname(plugin_path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    try:
        lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
    except OSError as e:
        print(f"error: could not open lock file {lock_path}: {e}", file=sys.stderr)
        sys.exit(2)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        existing = load_existing(plugin_path)
        if existing != desired:
            write_file(plugin_path, desired)
            if not args.skip_node_check:
                check_node_syntax(plugin_path)
            print(f"wrote opencode plugin: {plugin_path}", file=sys.stderr)
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)

    sys.exit(0)


if __name__ == "__main__":
    main()
