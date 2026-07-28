#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""wm_config - the single reader of wingman's settings file.

The settings file is `config.local.toml` at the wingman repo root: gitignored,
hand-edited, and templated by `config.example.toml`. It is the one declarative
place for the settings a pilot wants to persist across runs, so wingman stops
asking the onboarding-preference questions on every run and every spawn stops
falling through to the agent CLI's own model.

Two consumers, one reader:

  - `bin/lib/common.sh` runs `env-exports` and evals its output, so every bin/
    script picks up the environment-backed settings. It only ever exports a
    variable the environment does not already carry - which is exactly what
    makes an explicit `WM_MODEL=x bin/spawn-crew ...` (and anything
    config.local.sh set, since common.sh sources that first) win over the file.
  - `bin/lib/wm-state.py` imports this module and layers the `[prefs]` table
    underneath its own per-run answer store, so `pref-get`/`prefs-list` - and
    therefore the preferences guard, the nudge, `/prefs`, and every crew member
    reading a preference - see a file-provided answer exactly as if the pilot
    had just given it.

This module deliberately does NOT know what an onboarding preference *means*.
The required key list and each key's value vocabulary live in
`hooks/lib/pilot-prefs.sh`, which is what the guard enforces; `[prefs]` is
passed through here as opaque strings and validated there (and by `bin/doctor`,
which sources that same file). Adding preference #N therefore still touches
only pilot-prefs.sh and CLAUDE.md, never this file.

A settings file that exists but cannot be parsed raises ConfigError rather than
reading as "no settings": a typo must be reported, never silently drop a
setting the pilot believes is in effect.
"""

import argparse
import os
import shlex
import sys
import tomllib

# --- the settings schema -----------------------------------------------------
# Every environment-backed setting: where it lives in the file, the WM_*
# variable it backs, and the kind that drives both its coercion and its
# validation. This table is the whole non-pref surface - `bin/config` renders
# it, `check` validates against it, and `env-exports` exports from it - so a new
# setting of this shape is one row here plus one line in config.example.toml.
SCALAR = "scalar"  # a single value, passed through as a string
FLAG = "flag"      # a bool, exported as "1"/"" (wingman's on-by-default convention)
LIST = "list"      # an array of strings, exported newline-separated
PATHLIST = "paths"  # a LIST whose entries are ~/$VAR-expanded paths
TABLE = "table"    # a name -> path table, exported as newline-separated "name|path"

# (table, key, kind, environment variable, one-line description)
SCHEMA = (
    ("models", "default", SCALAR, "WM_MODEL",
     "default model for every crew spawn"),
    ("effort", "default", SCALAR, "WM_EFFORT",
     "default reasoning effort for every crew spawn"),
    ("projects", "roots", PATHLIST, "WM_ROOTS",
     "extra roots bin/discover-projects scans"),
    ("projects", "ignore", LIST, "WM_IGNORE",
     "project names bin/discover-projects skips"),
    ("projects", "pins", TABLE, "WM_PINS",
     "project name -> explicit path, overriding the scan"),
    ("harness", "agent", SCALAR, "WM_AGENT",
     "the agent CLI a crew session execs"),
    ("harness", "permission_mode", SCALAR, "WM_PERMISSION_MODE",
     "--permission-mode for a crew session"),
    ("harness", "remote_control", FLAG, "WM_REMOTE_CONTROL",
     "launch crew Remote-Control-visible"),
    ("harness", "tmux_session", SCALAR, "WM_TMUX_SESSION",
     "tmux session that hosts crew windows"),
)

# Tables that additionally accept arbitrary crew-type keys alongside `default`
# (see for_type below), so unknown-key detection must not flag them.
PER_TYPE_TABLES = ("models", "effort")
# Every table the file may contain. `prefs` carries no schema here on purpose -
# hooks/lib/pilot-prefs.sh owns its key set.
KNOWN_TABLES = ("prefs",) + PER_TYPE_TABLES + ("projects", "harness")


class ConfigError(Exception):
    """The settings file exists but is unusable, or a setting has the wrong shape."""


# --- loading -----------------------------------------------------------------
def config_path():
    """The settings file path: $WM_CONFIG_TOML if set (tests point it at a
    fixture), else config.local.toml at the wingman repo root."""
    override = os.environ.get("WM_CONFIG_TOML")
    if override:
        return override
    lib_dir = os.path.dirname(os.path.abspath(__file__))          # <repo>/bin/lib
    repo = os.path.dirname(os.path.dirname(lib_dir))              # <repo>
    return os.path.join(repo, "config.local.toml")


def load(path=None):
    """The parsed settings file, or {} when there is no file at all."""
    path = path or config_path()
    try:
        with open(path, "rb") as fh:
            data = tomllib.load(fh)
    except FileNotFoundError:
        return {}
    except OSError as exc:
        raise ConfigError("cannot read %s: %s" % (path, exc))
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError("%s is not valid TOML: %s" % (path, exc))
    if not isinstance(data, dict):
        raise ConfigError("%s must be a TOML table" % path)
    return data


def _expand(value):
    """A path setting as the pilot wrote it, with ~ and $VAR resolved - the file
    is hand-edited, so `roots = ["~/dev"]` has to mean what it looks like."""
    return os.path.expanduser(os.path.expandvars(value))


def _stringify(value):
    """A TOML scalar as the string the rest of wingman passes around. Booleans
    read naturally in the file (`remote = false`) but every consumer - the
    preference store, the WM_* environment, a crew member's pref-get - is
    string-typed, and `true`/`false` is the vocabulary pilot-prefs.sh already
    defines for exactly those keys."""
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


# --- preferences -------------------------------------------------------------
def prefs(data=None):
    """The `[prefs]` table as {key: string value}, opaque by design: this module
    knows neither the required key set nor any key's vocabulary."""
    data = load() if data is None else data
    table = data.get("prefs")
    if table is None:
        return {}
    if not isinstance(table, dict):
        raise ConfigError("[prefs] must be a table of `key = value` pairs")
    out = {}
    for key, value in table.items():
        if isinstance(value, (dict, list)):
            raise ConfigError(
                "prefs.%s must be a single value, not a table or array" % key)
        out[key] = _stringify(value)
    return out


# --- per-crew-type model and effort ------------------------------------------
def _type_keys(crew_type):
    """The `[models]`/`[effort]` lookup keys for one crew type, most specific
    first: the name as given (category-qualified when the caller has it), then
    the bare role name."""
    keys = [crew_type]
    if "/" in crew_type:
        keys.append(crew_type.rsplit("/", 1)[1])
    return keys


def for_type(table_name, crew_type, data=None):
    """The `[models]`/`[effort]` value for one crew type, or None when the file
    names nothing for it.

    Specificity decides: `"software-development/developer"` wins over
    `developer`. `default` is deliberately NOT consulted here - it is exported
    as $WM_MODEL/$WM_EFFORT by env_exports, which is what puts it *below* an
    explicitly-set environment variable in the precedence chain while a per-type
    entry stays above one.
    """
    data = load() if data is None else data
    table = data.get(table_name)
    if table is None:
        return None
    if not isinstance(table, dict):
        raise ConfigError("[%s] must be a table" % table_name)
    for key in _type_keys(crew_type):
        if key in table:
            value = table[key]
            if isinstance(value, (dict, list)):
                raise ConfigError(
                    "%s.%s must be a single value" % (table_name, key))
            return _stringify(value)
    return None


# --- the environment layer ---------------------------------------------------
def _env_value(table, key, kind, raw):
    """One setting coerced to the string shape its WM_* variable carries."""
    where = "%s.%s" % (table, key)
    if kind == FLAG:
        if not isinstance(raw, bool):
            raise ConfigError("%s must be true or false" % where)
        # "1"/empty, matching wingman's on-by-default-empty-to-disable
        # convention for WM_REMOTE_CONTROL and friends.
        return "1" if raw else ""
    if kind in (LIST, PATHLIST):
        if not isinstance(raw, list) or any(not isinstance(x, str) for x in raw):
            raise ConfigError("%s must be an array of strings" % where)
        return "\n".join(_expand(x) if kind == PATHLIST else x for x in raw)
    if kind == TABLE:
        if not isinstance(raw, dict):
            raise ConfigError(
                '%s must be a table of `name = "path"` pairs' % where)
        for name, path in raw.items():
            if not isinstance(path, str):
                raise ConfigError('%s.%s must be a path string' % (where, name))
        return "\n".join("%s|%s" % (n, _expand(p)) for n, p in raw.items())
    if isinstance(raw, (dict, list)):
        raise ConfigError("%s must be a single value" % where)
    return _stringify(raw)


def env_exports(data=None, environ=None):
    """`export WM_X=<quoted>` lines for every environment-backed setting the
    file sets and the environment does not already carry.

    Membership, not truthiness: an explicitly-empty $WM_REMOTE_CONTROL or
    $WM_PERMISSION_MODE means "disabled" (both are read as `${VAR-default}`), so
    an empty value in the environment is a real answer and must not be
    overwritten from the file.
    """
    data = load() if data is None else data
    environ = os.environ if environ is None else environ
    lines = []
    applied = []
    for table, key, kind, var, _desc in SCHEMA:
        if var in environ:
            continue
        section = data.get(table)
        if not isinstance(section, dict) or key not in section:
            continue
        lines.append("export %s=%s" % (
            var, shlex.quote(_env_value(table, key, kind, section[key]))))
        applied.append(var)
    # Which variables this layer set, for any later reader that must tell a
    # file-provided value apart from one the environment carried in. Once these
    # are exported they are indistinguishable by inspection, which would make
    # `bin/config` report every setting the file supplied as `env` (see
    # resolved). Always emitted, empty included, so a stale value from an outer
    # shell can never be mistaken for this process's own.
    lines.append("export WM_CONFIG_APPLIED=%s" % shlex.quote(" ".join(applied)))
    return lines


# --- validation --------------------------------------------------------------
def problems(data=None, known_types=()):
    """Every structural problem in the settings file, as human-readable lines.

    Structural only - an unknown table, an unknown key, a wrong type, a
    per-type entry naming a crew type with no playbook. Whether a `[prefs]`
    value is *valid for its key* is checked where that vocabulary lives
    (hooks/lib/pilot-prefs.sh, via bin/doctor), not here.

    `known_types` is the crew-type list (`bin/spawn-crew --list-types`,
    category-qualified) when the caller has it; passing it turns a typo'd
    per-type key into a named error instead of a silently-inert entry.
    """
    found = []
    if data is None:
        try:
            data = load()
        except ConfigError as exc:
            return [str(exc)]
    schema_keys = {}
    for table, key, kind, _var, _desc in SCHEMA:
        schema_keys.setdefault(table, {})[key] = kind

    bare_types = set()
    for qualified in known_types:
        bare_types.add(qualified)
        if "/" in qualified:
            bare_types.add(qualified.rsplit("/", 1)[1])

    for table, section in data.items():
        if table not in KNOWN_TABLES:
            found.append("unknown table [%s] (known: %s)"
                         % (table, ", ".join(KNOWN_TABLES)))
            continue
        if not isinstance(section, dict):
            found.append("[%s] must be a table" % table)
            continue
        if table == "prefs":
            try:
                prefs(data)
            except ConfigError as exc:
                found.append(str(exc))
            continue
        for key, raw in section.items():
            if table in PER_TYPE_TABLES:
                if key != "default" and known_types and key not in bare_types:
                    found.append(
                        "%s.%s names no crew type - see `bin/spawn-crew "
                        "--list-types`" % (table, key))
                    continue
                kind = schema_keys.get(table, {}).get(key, SCALAR)
            elif key in schema_keys.get(table, {}):
                kind = schema_keys[table][key]
            else:
                known = ", ".join(sorted(schema_keys.get(table, {})))
                found.append("unknown setting %s.%s (known in [%s]: %s)"
                             % (table, key, table, known))
                continue
            try:
                _env_value(table, key, kind, raw)
            except ConfigError as exc:
                found.append(str(exc))
    return found


# --- the resolved view -------------------------------------------------------
def _display(kind, value):
    """One resolved value as a single readable line.

    A LIST/PATHLIST/TABLE setting travels through the environment
    newline-separated, which would break a line-per-setting rendering, so it is
    joined here. A FLAG travels as `1`/empty, which reads as "unset" next to a
    setting that genuinely is - so it is shown as the `true`/`false` the file
    itself uses.
    """
    if kind == FLAG:
        return "true" if value else "false"
    return ", ".join(value.split("\n")) if "\n" in value else value


def resolved(data=None, environ=None):
    """`(name, value, source)` for every environment-backed setting, resolved
    the way a bin/ script actually sees it, with each value rendered as one
    readable line (see _display).

    `source` is `env` when the environment already carries the variable - which
    is also where anything config.local.sh set has landed by the time this runs,
    so the two are genuinely indistinguishable here and are reported as one -
    `config.local.toml` when the file supplied it, and `default` when neither
    did and the consumer falls through to its own built-in.

    $WM_CONFIG_APPLIED is what keeps that first case honest. A caller that has
    sourced bin/lib/common.sh has ALREADY had this file's settings exported into
    its environment, so every one of them would otherwise read back as `env`;
    the variables env_exports names there are attributed to the file instead.
    """
    data = load() if data is None else data
    environ = os.environ if environ is None else environ
    applied = set((environ.get("WM_CONFIG_APPLIED") or "").split())
    rows = []
    for table, key, kind, var, _desc in SCHEMA:
        name = "%s.%s" % (table, key)
        if var in environ and var not in applied:
            rows.append((name, _display(kind, environ[var]), "env"))
            continue
        section = data.get(table)
        if isinstance(section, dict) and key in section:
            try:
                value = _env_value(table, key, kind, section[key])
            except ConfigError as exc:
                rows.append((name, "<invalid: %s>" % exc, "config.local.toml"))
            else:
                rows.append((name, _display(kind, value), "config.local.toml"))
            continue
        rows.append((name, "", "default"))
    # Per-crew-type overrides are open-ended, so they are listed as they are
    # found rather than enumerated from SCHEMA.
    for table in PER_TYPE_TABLES:
        section = data.get(table)
        if not isinstance(section, dict):
            continue
        for key in sorted(section):
            if key == "default":
                continue
            rows.append(("%s.%s" % (table, key), _stringify(section[key]),
                         "config.local.toml"))
    return rows


# --- CLI ---------------------------------------------------------------------
def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="wm_config.py",
        description="read wingman's settings file (config.local.toml)")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("path", help="print the settings file path")
    sub.add_parser("env-exports",
                   help="shell `export WM_X=...` lines for `eval`")
    sub.add_parser("prefs", help="the [prefs] table as key<TAB>value lines")
    sub.add_parser("show",
                   help="name<TAB>value<TAB>source for every resolved setting")

    a = sub.add_parser("for-type",
                       help="the [models]/[effort] value for one crew type")
    a.add_argument("--table", required=True, choices=list(PER_TYPE_TABLES))
    a.add_argument("--type", required=True, dest="crew_type")

    a = sub.add_parser("check", help="report structural problems; exit 1 if any")
    a.add_argument("--known-types", default="",
                   help="newline- or comma-separated crew types to validate "
                        "per-type keys against")

    args = parser.parse_args(argv)

    if args.cmd == "path":
        print(config_path())
        return 0

    try:
        if args.cmd == "env-exports":
            for line in env_exports():
                print(line)
        elif args.cmd == "prefs":
            for key, value in sorted(prefs().items()):
                print("%s\t%s" % (key, value))
        elif args.cmd == "for-type":
            value = for_type(args.table, args.crew_type)
            if value is None:
                return 1
            print(value)
        elif args.cmd == "show":
            for name, value, source in resolved():
                print("%s\t%s\t%s" % (name, value, source))
        elif args.cmd == "check":
            raw = args.known_types.replace(",", "\n")
            types = [t.strip() for t in raw.split("\n") if t.strip()]
            found = problems(known_types=tuple(types))
            for line in found:
                print(line)
            return 1 if found else 0
    except ConfigError as exc:
        sys.stderr.write("%s\n" % exc)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
