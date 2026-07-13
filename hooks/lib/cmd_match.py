"""cmd_match: shared command-shape recognition for wingman's PreToolUse hooks.

Every guard that inspects a Bash tool call needs the same two primitives:
split the command string into invocation segments (one per `;`/`&&`/`||`/pipe
link), and resolve what each segment actually invokes regardless of how it is
typed - a relative path, an absolute path, a leading `$VAR`/`${VAR}` token
(expanded from the hook's own environment, since hooks receive the command
string before shell expansion), or wrapped in `env`/`sudo`/a shell/
`uv run [flags]`. The `$WINGMAN_STATE` case matters most: CLAUDE.md tells
every session to run that literal shape, it arrives at the hook unexpanded,
and its exported value is `uv run --no-project --quiet <abs>/wm-state.py` -
so resolution must expand the variable and then see through uv's own leading
option flags to reach the script name.

Hooks import this via PYTHONPATH=<hooks>/lib under the same `uv run
--no-project python` interpreter they already embed.

Known caveat: the uv flag-skipping treats every leading `-`-token as
value-free. That is exactly right for `$WINGMAN_STATE`'s own flags
(--no-project --quiet), but a value-taking flag (`uv run -p 3.12 pytest`)
misparses - `3.12` is taken as the command, so the segment fails to resolve.
That is a false negative only (a non-standard shape may dodge a deny rule); it
never causes a wrong allow, since an unresolved segment matches no allowlist.
"""
import os
import re
import shlex

_ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_VAR_TOKEN_RE = re.compile(r"^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$")


def basename(tok):
    return tok.rsplit("/", 1)[-1]


def command_segments(cmd_str):
    """Split a Bash command string into token lists, one per invocation segment
    (split on `;`/`&&`/`||`/`|` and newlines). A segment that fails to lex is
    dropped rather than guessed at."""
    segments = []
    for line in cmd_str.split("\n"):
        line = line.strip()
        if not line:
            continue
        try:
            lex = shlex.shlex(line, posix=True, punctuation_chars=";&|")
            lex.whitespace_split = True
            tokens = list(lex)
        except ValueError:
            continue
        current = []
        for tok in tokens:
            if tok and set(tok) <= set(";&|"):
                if current:
                    segments.append(current)
                current = []
            else:
                current.append(tok)
        if current:
            segments.append(current)
    return segments


def resolve_command(tokens):
    """Resolve the command one segment actually invokes: skip leading VAR=val
    assignments, unwrap `env`/`sudo`, wrapper shells (`bash -c ...`), and
    `uv run [flags]`, and return (basename, argv) where argv[0] is the resolved
    command token and argv[1:] its arguments. ("", []) when nothing resolves."""
    i = 0
    while i < len(tokens) and _ASSIGNMENT_RE.match(tokens[i]):
        i += 1
    tokens = tokens[i:]
    if not tokens:
        return ("", [])
    # A hook sees the command string BEFORE shell expansion, so the literal
    # `$WINGMAN_STATE prefs-list ...` shape CLAUDE.md instructs arrives as a
    # `$WINGMAN_STATE` token, not as the uv invocation it expands to. Expand a
    # leading variable token from this hook's own environment - the same
    # environment the tool's shell will expand it from - and resolve the
    # result. An unset variable stays unresolved (("", [])): a false negative
    # only, never a wrong allow.
    m = _VAR_TOKEN_RE.match(tokens[0])
    if m:
        val = os.environ.get(m.group(1), "")
        if not val:
            return ("", [])
        try:
            expanded = shlex.split(val)
        except ValueError:
            return ("", [])
        return resolve_command(expanded + tokens[1:])
    b = basename(tokens[0])
    if b in ("sudo", "env"):
        return resolve_command(tokens[1:])
    if b in ("bash", "sh", "zsh") and len(tokens) > 1:
        rest = [t for t in tokens[1:] if not t.startswith("-")]
        if not rest:
            return ("", [])
        return resolve_command(rest)
    if b == "uv" and len(tokens) > 1 and tokens[1] == "run":
        rest = tokens[2:]
        while rest and rest[0].startswith("-"):
            rest = rest[1:]
        if not rest:
            return ("", [])
        return resolve_command(rest)
    return (b, tokens)


def resolved_segments(cmd_str):
    """Convenience for the common guard shape: every segment of cmd_str,
    resolved. Returns a list of (basename, argv) pairs; an unresolvable
    segment appears as ("", [])."""
    return [resolve_command(seg) for seg in command_segments(cmd_str)]
