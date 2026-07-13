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

A Python interpreter in front of a script (`python3 <abs>/wm-state.py ...`,
`uv run --no-project --quiet python <abs>/wm-state.py ...`) is unwrapped the
same way, so the script - not the interpreter - is what resolves. `-c` (inline
code) and `-m` (module) are deliberately NOT unwrapped: they are not script
invocations, inline code must never be resolved into whatever it happens to
mention, and hooks/no-direct-edit-guard.sh detects a test runner on exactly the
un-unwrapped shape (basename `python`/`python3` with `-m` in argv).

Known caveats, both false-negative-only:

- The uv flag-skipping treats every leading `-`-token as value-free. That is
  exactly right for `$WINGMAN_STATE`'s own flags (--no-project --quiet), but a
  value-taking flag (`uv run -p 3.12 pytest`) misparses - `3.12` is taken as the
  command, so the segment fails to resolve.
- The interpreter unwrap requires the script token to end in `.py`, keeping it
  to the one shape it is meant for; a non-`.py` first argument leaves the
  segment resolving to the interpreter.

Neither ever causes a wrong allow: an unresolved segment (or one resolving to
the interpreter) matches no allowlist, so a non-standard shape may dodge a deny
rule but can never slip past a gate.

Fail-closed contract for command_segments()/resolved_segments(): a command
that cannot be fully lexed - a genuinely unterminated quote, an unbalanced
command-substitution span, or a heredoc whose terminator is never found -
resolves the WHOLE command to None, never a partial/truncated segment list.
Claude Code executes the raw command string exactly as typed regardless of
what a hook can parse from it, so silently dropping the unlexable piece (as a
prior version of this module did) lets a malformed multi-segment command
smuggle a segment past every guard built on this module. Every caller MUST
treat None as "deny" (or, for the two PostToolUse recorders, "nothing to
record") - never as "no segments, nothing to check".

Quoting, command substitution ($(...), backticks, <(...), >(...)), and heredoc
recognition are all done by ONE recursive-descent scan (_walk(), below) - not
by a quote-aware pass for logical lines plus a separate pass to find where a
substitution ends. That independence was tried and found broken: a heredoc
nested inside a substitution's own content (the idiomatic real-world shape,
e.g. `gh pr create --body "$(cat <<'EOF' ... EOF)"`) is invisible to whichever
pass is currently walking through it - an apostrophe or stray paren in the
heredoc's own prose corrupts a quote/paren-tracking pass that doesn't know a
heredoc body is passing through, and a heredoc-aware pass that isn't also
tracking substitution nesting ends the wrong span at the heredoc's own raw
newline. _walk() is the single piece of machinery used both to build the
top-level logical lines AND to find where a nested substitution span ends, so
a heredoc encountered at either level is recognized and consumed as one
opaque, atomic unit of text - never lexed as shell code, never scanned for
nested substitutions - by whichever concern is currently walking through it.

A substitution's content is never kept verbatim in the outer logical line
(that only happened to be safe when an outer double-quote coincidentally
protected it, and broke for the unquoted and backtick forms): _walk() always
substitutes a fixed, inert placeholder (`"$(...)"`, `` "`...`" ``, `"<(...)"`,
`">(...)"` at the unquoted level; the unquoted variants without their wrapping
quotes when already inside a double-quoted string) into the outer line, and
separately records the span's real, untouched inner text to be recursively
re-checked through command_segments() on its own - so detection is unaffected
by the placeholder, but the outer line is always safe to lex regardless of
what the substitution's own content contains.

Residual gaps, deliberately out of scope (see docs/plans/2026-07-13-issue-56-
cmd-match-fail-closed.md): arithmetic expansion (`$((...))`) is not extracted
the way command/process substitution is; redirection (`> /path`) is not
treated as a risk this module addresses; a substitution in COMMAND POSITION
(`$(which gh) pr merge ...`) resolves to this module's inert placeholder
rather than a real command name, so a guard matching on argv[0] does not catch
it as that command - not a regression (the unfixed prior behavior already
missed this shape for an unrelated tokenization reason), but not closed by
this module either.
"""
import os
import re
import shlex

_ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_VAR_TOKEN_RE = re.compile(r"^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$")
_PY_RE = re.compile(r"^python[0-9.]*$")


def basename(tok):
    return tok.rsplit("/", 1)[-1]


class _LexFail(Exception):
    """Raised internally by the scanner: an unterminated quote, an unbalanced
    substitution span, or a heredoc whose terminator line is never found.
    Always caught at a command_segments() boundary and turned into None -
    never allowed to propagate to a caller."""


def _parse_heredoc_word(s, k, n):
    """Parse a heredoc delimiter word starting at s[k] (just past `<<`/`<<-`
    and any intervening whitespace already skipped by the caller... actually
    this also skips that whitespace itself). Returns (word, end, quoted):
    `word` is the dequoted delimiter text (None if no word could be parsed at
    all - a malformed redirect), `end` is the index just past the word as
    written (quotes/backslashes included, for keeping the raw token text in
    the outer logical line), and `quoted` is True iff the delimiter was
    single-quoted, double-quoted, or backslash-escaped anywhere - the real
    bash signal that the body undergoes NO expansion at all."""
    while k < n and s[k] in " \t":
        k += 1
    if k >= n or s[k] == "\n":
        return None, k, False
    chars = []
    quoted = False
    while k < n and s[k] not in " \t\n":
        ch = s[k]
        if ch == "\\" and k + 1 < n:
            chars.append(s[k + 1])
            k += 2
            quoted = True
        elif ch in ("'", '"'):
            qc = ch
            k += 1
            end = s.find(qc, k)
            if end == -1:
                return None, k, False
            chars.append(s[k:end])
            k = end + 1
            quoted = True
        else:
            chars.append(ch)
            k += 1
    word = "".join(chars)
    if not word:
        return None, k, False
    return word, k, quoted


def _read_heredoc_body(s, start, n, word, strip_tabs):
    """Read a heredoc body from `start` (just past the newline that ended the
    redirect's own line) up to and including its terminator line. Returns
    (body_text, end) where `end` is just past the terminator line's own
    newline (or the end of the string, if the terminator was the last line
    with no trailing newline). Raises _LexFail if no line matching the
    delimiter is found before the end of the string - a deliberate, safe
    false-deny: bash itself treats this as valid (running the heredoc to
    end-of-file with only a warning), but real usage essentially never
    produces this shape on purpose, and this module fails closed on it."""
    pos = start
    while True:
        nl = s.find("\n", pos)
        line_end = nl if nl != -1 else n
        line = s[pos:line_end]
        candidate = line.lstrip("\t") if strip_tabs else line
        if candidate == word:
            body = s[start:pos]
            end = nl + 1 if nl != -1 else n
            return body, end
        if nl == -1:
            raise _LexFail("unterminated heredoc (delimiter %r never found)" % word)
        pos = nl + 1


def _walk(s, i, n, close):
    """The single recursive-descent primitive behind both top-level logical-
    line scanning and substitution-span-end finding.

    Walks s[i:n], tracking quote state, backslash escaping, heredoc bodies
    (recognized via `<<`/`<<-` outside any quoting, and consumed as one
    opaque atomic unit of text - never lexed as code, never scanned for
    nested substitutions, wherever encountered), and substitution openers
    ($( ` <( >( ), which are recursively skipped via this same function (so a
    heredoc nested inside a substitution is opaque to whichever level is
    currently walking through it, and a substitution nested inside another is
    threaded through correctly regardless of paren-depth bookkeeping).

    `close` is None for a top-level scan (or an already-extracted
    substitution/heredoc-body's content, fed back in as its own top-level
    text) that runs to the end of s; it is ')' or '`' when hunting for a
    specific substitution's own matching close.

    Returns (end, logical_lines, pending):
      end - for close=None, always n; for close=<char>, the index just past
        the matching close.
      logical_lines - ordinary code lines (heredoc bodies never included,
        quote-embedded newlines never treated as a line boundary) for the
        caller's own per-line shlex call. Substitution spans are replaced
        with an inert placeholder here, never their literal text.
      pending - [("code", inner_text), ...] for every substitution span found
        at this level, and [("heredoc", body_text), ...] for every UNQUOTED-
        delimiter heredoc found at this level, to be recursed into. A span-
        end search (close=<char>) discards this return value - the
        substitution's real content is re-derived once, correctly, by
        recursing command_segments() on the extracted span text itself,
        rather than accumulated twice.

    Raises _LexFail on an unterminated quote, a heredoc whose terminator line
    is never found, a malformed heredoc redirect (no delimiter word), or (for
    close=<char>) reaching the end of the string with no matching close.
    """
    logical_lines = []
    out = []
    pending = []
    heredoc_queue = []
    quote = None
    j = i

    def flush():
        if out:
            line = "".join(out)
            if line.strip():
                logical_lines.append(line)
            del out[:]

    while True:
        if j >= n:
            if close is not None:
                raise _LexFail("unterminated substitution (no matching %r)" % close)
            break
        c = s[j]

        if quote == "'":
            out.append(c)
            j += 1
            if c == "'":
                quote = None
            continue

        if quote == '"':
            if c == "\\" and j + 1 < n and s[j + 1] in ("$", "`", '"', "\\", "\n"):
                out.append(c)
                out.append(s[j + 1])
                j += 2
                continue
            if c == '"':
                out.append(c)
                quote = None
                j += 1
                continue
            if c == "$" and j + 1 < n and s[j + 1] == "(":
                end, _, _ = _walk(s, j + 2, n, ")")
                pending.append(("code", s[j + 2:end - 1]))
                out.append("$(...)")
                j = end
                continue
            if c == "`":
                end, _, _ = _walk(s, j + 1, n, "`")
                pending.append(("code", s[j + 1:end - 1]))
                out.append("`...`")
                j = end
                continue
            out.append(c)
            j += 1
            continue

        # --- unquoted ---
        if c == "\\":
            if j + 1 < n and s[j + 1] == "\n":
                j += 2  # line continuation: swallowed, no line break emitted
                continue
            if j + 1 < n:
                out.append(c)
                out.append(s[j + 1])
                j += 2
                continue
            out.append(c)
            j += 1
            continue

        if c == "'":
            quote = c
            out.append(c)
            j += 1
            continue
        if c == '"':
            quote = c
            out.append(c)
            j += 1
            continue

        if close == ")" and c == ")":
            return j + 1, logical_lines, pending
        if close == "`" and c == "`":
            return j + 1, logical_lines, pending

        if c == "$" and j + 1 < n and s[j + 1] == "(":
            end, _, _ = _walk(s, j + 2, n, ")")
            pending.append(("code", s[j + 2:end - 1]))
            out.append('"$(...)"')
            j = end
            continue
        if c == "`":
            end, _, _ = _walk(s, j + 1, n, "`")
            pending.append(("code", s[j + 1:end - 1]))
            out.append('"`...`"')
            j = end
            continue
        if c == "<" and j + 1 < n and s[j + 1] == "(":
            end, _, _ = _walk(s, j + 2, n, ")")
            pending.append(("code", s[j + 2:end - 1]))
            out.append('"<(...)"')
            j = end
            continue
        if c == ">" and j + 1 < n and s[j + 1] == "(":
            end, _, _ = _walk(s, j + 2, n, ")")
            pending.append(("code", s[j + 2:end - 1]))
            out.append('">(...)"')
            j = end
            continue

        if c == "<" and j + 1 < n and s[j + 1] == "<":
            k = j + 2
            strip_tabs = False
            if k < n and s[k] == "-":
                strip_tabs = True
                k += 1
            word, k2, quoted_word = _parse_heredoc_word(s, k, n)
            if word is None:
                raise _LexFail("malformed heredoc redirect")
            out.append(s[j:k2])
            heredoc_queue.append((word, strip_tabs, quoted_word))
            j = k2
            continue

        if c == "\n":
            flush()
            j += 1
            if heredoc_queue:
                for word, strip_tabs, quoted_word in heredoc_queue:
                    body, j = _read_heredoc_body(s, j, n, word, strip_tabs)
                    if not quoted_word:
                        pending.append(("heredoc", body))
                heredoc_queue = []
            continue

        out.append(c)
        j += 1

    flush()
    if quote is not None:
        raise _LexFail("unterminated quote")
    if heredoc_queue:
        raise _LexFail("unterminated heredoc (redirect line never ended)")
    return n, logical_lines, pending


def _extract_substitutions_heredoc_body(body):
    """Scan `body` - an UNQUOTED-delimiter heredoc's literal text - for
    $(...)/backtick spans, under bash's narrower heredoc-expansion rules:
    unlike command position, plain `'`/`"` characters are never quote
    syntax here (they are literal heredoc prose); only `$(...)` and
    backticks are recognized, each found span's own true end (heredoc- and
    quote-aware, so a substitution nested in a heredoc nested in this
    heredoc still resolves correctly) located via the same _walk(). Returns
    a list of the spans' real inner texts, to be recursed into via
    command_segments(). Raises _LexFail if a span never closes (including
    the real bash ambiguity of an unpaired backtick in such a body)."""
    pending = []
    n = len(body)
    i = 0
    while i < n:
        c = body[i]
        if c == "$" and i + 1 < n and body[i + 1] == "(":
            end, _, _ = _walk(body, i + 2, n, ")")
            pending.append(body[i + 2:end - 1])
            i = end
            continue
        if c == "`":
            end, _, _ = _walk(body, i + 1, n, "`")
            pending.append(body[i + 1:end - 1])
            i = end
            continue
        i += 1
    return pending


def command_segments(cmd_str):
    """Split a Bash command string into token lists, one per invocation
    segment (split on `;`/`&&`/`||`/`|`). Quoting, command/process
    substitution, and heredocs are all resolved by one recursive-descent scan
    (see module docstring); a command substitution's/backtick's/process
    substitution's own content, and an unquoted heredoc's body, are
    recursively re-checked and their own segments appended.

    Fails CLOSED: a segment that cannot be lexed - anywhere in the command,
    including inside a nested substitution or heredoc body - makes the WHOLE
    command resolve to None, never a partial list with the bad piece merely
    missing. A blank or whitespace-only command is well-formed (trivially)
    and still returns []; only an actual lex failure returns None. Every
    caller MUST check for None and fail closed (deny) on it."""
    try:
        _, logical_lines, pending = _walk(cmd_str, 0, len(cmd_str), None)
    except _LexFail:
        return None

    segments = []
    for line in logical_lines:
        try:
            lex = shlex.shlex(line, posix=True, punctuation_chars=";&|")
            lex.whitespace_split = True
            tokens = list(lex)
        except ValueError:
            return None
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

    for kind, text in pending:
        if kind == "code":
            sub = command_segments(text)
            if sub is None:
                return None
            segments.extend(sub)
        else:  # "heredoc" - an unquoted-delimiter body, scanned for $(...)/`...`
            try:
                inner_spans = _extract_substitutions_heredoc_body(text)
            except _LexFail:
                return None
            for inner in inner_spans:
                sub = command_segments(inner)
                if sub is None:
                    return None
                segments.extend(sub)

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
    # A Python interpreter in front of a script resolves to the script, so
    # `python3 <abs>/wm-state.py pref-set` reads as a wm-state.py call rather
    # than as `python3`. Value-free interpreter flags only: `-c` (inline code)
    # and `-m` (module) are not script invocations and are deliberately NOT
    # unwrapped - inline code must never be resolved into whatever it happens
    # to mention, and hooks/no-direct-edit-guard.sh matches `python -m pytest`
    # on exactly this shape (basename `python` with `-m` present in argv).
    if _PY_RE.match(b) and len(tokens) > 1:
        rest = tokens[1:]
        while rest and rest[0].startswith("-") and rest[0] not in ("-c", "-m"):
            rest = rest[1:]
        if rest and rest[0].endswith(".py"):
            return resolve_command(rest)
        return (b, tokens)
    return (b, tokens)


def resolved_segments(cmd_str):
    """Convenience for the common guard shape: every segment of cmd_str,
    resolved. Returns a list of (basename, argv) pairs, or None when
    command_segments() itself fails closed (see its docstring) - callers must
    check for None and fail closed on it, exactly like command_segments()."""
    segments = command_segments(cmd_str)
    if segments is None:
        return None
    return [resolve_command(seg) for seg in segments]
