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
un-unwrapped shape (basename `python`/`python3` with `-m` in argv). A wrapper
SHELL's own `-c` payload is a different thing entirely, and IS unwrapped (see
"Wrapper-shell and eval payloads" below): it is shell code handed to that
shell to execute, exactly the kind of thing every guard built on this module
already expects to see through, where a Python `-c` payload is Python source
that must never be resolved into whatever it happens to mention.

False-negative-only caveats (a non-standard shape may dodge a deny rule but
can never slip past a gate, because it resolves to nothing, or to the
interpreter itself, matching no allowlist):

- The interpreter unwrap requires the script token to end in `.py`, keeping it
  to the one shape it is meant for; a non-`.py` first argument leaves the
  segment resolving to the interpreter.

Recognition gaps that are wrong ALLOWS, not false negatives: this module
recognizes a command by resolving argv[0] of each segment, so a shape that
carries the real command as DATA for another program to execute - `xargs
<cmd> ...`, `find ... -exec <cmd> ;`, a command piped into a shell (`echo gh
pr merge 5 | bash`), a substitution in command position (`$(which gh) pr
merge ...`), or a remote/re-entrant wrapper (`ssh <host> "<cmd>"`, `su -c`,
`timeout 30 bash -c ...`) - is not recognized as that command at all: the
segment resolves to `xargs`/`find`/`bash`/`ssh`/the inert placeholder,
matching no guard predicate for the command actually being run. The uv
flag-skipping belongs in this list too, not the false-negative one above: it
treats every leading `-`-token as value-free, which is exactly right for
`$WINGMAN_STATE`'s own flags (--no-project --quiet), but a value-taking flag
misparses (`uv run -p 3.12 gh pr merge 46` resolves argv[0] to `3.12`, the
flag's own value, not `gh`) - the segment resolves to a junk basename that
matches no guard predicate for the command actually being invoked, a wrong
allow, not a harmless miss, even though the real command's tokens remain
present later in argv rather than being carried as another program's data.
Against a deny-style gate every shape above is a wrong allow, not a harmless
miss (issue #168); see docs/guards.md for the guard-facing summary.

Wrapper-shell and eval payloads: `bash`/`sh`/`zsh`/`dash`/`ksh` invoked with a
`-c` payload (including a combined flag cluster like `-lc`) and `eval`
(whose arguments are joined with a single space each, matching bash's own
re-parse semantics, before being treated as one payload) both hand a string
of further shell code to the wrapper. command_segments() re-lexes that
string through itself and inserts the resulting segments immediately after
the wrapper's own segment, in source order - never treating the whole
payload string as a command name, which was issue #168's bug (a payload like
`gh pr merge 5 --squash` used to resolve as a literal command named "gh pr
merge 5 --squash", matching no guard's denylist). The wrapper segment itself
stays in the segment list and resolves to the shell (or to `eval`) - never to
a basename() of the payload - so no consumer sees one real invocation
reported twice, and an allowlist-style guard (pilot-preferences-guard.sh)
keeps denying a wrapped form exactly as it denies an unwrapped `bash`
invocation. A payload that cannot itself be lexed fails the WHOLE command
closed, the same as a substitution's or heredoc's inner text (see the
fail-closed contract below). Order matters: lifting a `cd` inside a payload
inline, immediately after its wrapper segment rather than appended at the
end, is what lets no-merge-guard.sh's linear `cd`-tracker see it in the same
relative position a later top-level `cd` would occupy - the tracker still
treats it as if it persisted past the wrapper's own subshell scope (real bash
does not), a deliberate, documented approximation rather than a soundness
gap, and strictly better than the alternative of a later top-level `cd`
being misapplied to an earlier wrapped merge.

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

Two other constructs the scanner must get right, both found in PR #72's
review of the first version of this rewrite:

- A here-string (`<<<WORD`) is checked for, and handled as an ordinary
  redirect operator, BEFORE the `<<`/`<<-` heredoc check - it feeds one word
  to a single command's stdin on the same line and never spans lines or
  introduces a multi-line terminated body. Treating it as a heredoc (matching
  on the first two `<` and reading `<<<WORD`'s own `WORD` as a heredoc
  delimiter) swallowed every real command up to a later matching line as an
  opaque "body," hiding them from every guard - the exact bypass class this
  module exists to close, just reached through `<<<` instead of the original
  issue #56 repro. It also hard-denied ordinary here-string usage with
  nothing following it (no terminator line was ever found), since idiomatic
  bash here-strings are common (e.g. this repo's own bin/lib/common.sh).
- An unquoted `#` at a word boundary (the start of whatever region _walk()
  is scanning, or preceded by whitespace/`;`/`&`/`|`) starts a comment
  running to the next newline, matching bash and the shlex default
  (`commenters='#'`) the per-line predecessor of this module relied on.
  Comment text is skipped as one atomic span - never quoted, never scanned
  for substitutions or heredocs - so a stray apostrophe, `$(`, backtick, or
  `<<` in a trailing comment can never corrupt the scan into a false-deny.

Output-redirect operators (`>`, `>>`, `&>`, `&>>`, `>|`) are recognized in
_walk()'s own unquoted-only scanning branch and replaced with a padded,
unique sentinel token before the per-line shlex pass runs, so a real operator
is caught regardless of adjacent whitespace and a quoted literal `">"` is
never confused with one (issue #171). `redirect_write_targets()` returns the
token immediately following each such operator in a segment - the path that
segment's shell will write to. `>&` (fd-duplication - `2>&1`, `>&2`) is
deliberately excluded, re-emitted as untouched literal text so it falls
through to the pre-existing `&`-as-punctuation segment split rather than
being mistaken for a write to a file named the following digit; a bash
`>&word` "ambiguous redirect" is consequently not recognized as a write
either, a documented, deliberate false-negative-only gap. Input redirection
(`<`, `<<`, `<<<`) is not a write and is not covered by this recognition.

Residual gaps, deliberately out of scope (see docs/plans/2026-07-13-issue-56-
cmd-match-fail-closed.md): arithmetic expansion (`$((...))`) is not extracted
the way command/process substitution is; a substitution in COMMAND POSITION
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
_SHELL_WRAPPER_NAMES = ("bash", "sh", "zsh", "dash", "ksh")
_INERT_PLACEHOLDERS = frozenset(("$(...)", "`...`", "<(...)", ">(...)"))

_REDIR_TRUNC = "\x00WM_REDIR_GT\x00"
_REDIR_APPEND = "\x00WM_REDIR_GTGT\x00"
_REDIR_CLOBBER = "\x00WM_REDIR_GTBAR\x00"
_REDIR_BOTH = "\x00WM_REDIR_AMPGT\x00"
_REDIR_BOTH_APPEND = "\x00WM_REDIR_AMPGTGT\x00"
_WRITE_REDIRECT_TOKENS = frozenset(
    (_REDIR_TRUNC, _REDIR_APPEND, _REDIR_CLOBBER, _REDIR_BOTH, _REDIR_BOTH_APPEND)
)


def redirect_write_targets(tokens):
    """Given one segment's tokens (as returned by command_segments()), return
    the list of tokens immediately following an output-redirect operator (>,
    >>, &>, &>>, >|) - paths this segment's shell will write to, regardless of
    what command precedes the operator. Never includes an input redirect (<,
    <<, <<<) or fd-duplication (2>&1, >&2), neither of which writes arbitrary
    content to a path - see _walk()'s own handling of `>&` for why the latter
    is excluded rather than merely unmatched."""
    return [
        tokens[i + 1]
        for i, tok in enumerate(tokens)
        if tok in _WRITE_REDIRECT_TOKENS and i + 1 < len(tokens)
    ]


def basename(tok):
    return tok.rsplit("/", 1)[-1]


class _LexFail(Exception):
    """Raised internally by the scanner: an unterminated quote, an unbalanced
    substitution span, or a heredoc whose terminator line is never found.
    Always caught at a command_segments() boundary and turned into None -
    never allowed to propagate to a caller."""


def _parse_heredoc_word(s, k, n):
    """Parse a heredoc delimiter word starting at s[k] (just past `<<`/`<<-`;
    any intervening whitespace is skipped here, not by the caller). Returns
    (word, end, quoted):
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

        # An unquoted `#` at a word boundary (start of this region, or
        # preceded by whitespace/a statement separator) starts a comment
        # running to the next newline - matching bash, and the shlex
        # default (`commenters='#'`) the old per-line path relied on.
        # Comment text is completely inert: never quoted, never scanned for
        # substitutions or heredocs, so a stray apostrophe/`$(`/backtick/`<<`
        # in a trailing comment can never corrupt the scan (a false-deny
        # regression from `main`) - and, since it is skipped as one atomic
        # span rather than walked character-by-character, a `)` or backtick
        # inside a comment can never be mistaken for a substitution's own
        # close either. `#` mid-token (`foo#bar`) is deliberately NOT a
        # comment - only preceded by whitespace/`;`/`&`/`|`/a newline, or the
        # very start of this region.
        if c == "#" and (j == i or s[j - 1] in " \t\n;&|"):
            nl = s.find("\n", j)
            j = nl if nl != -1 else n
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

        # Write-redirect operators (issue #171) - see module docstring for
        # the two-part reasoning (whitespace-independence, quote-ambiguity).
        if c == ">" and j + 1 < n and s[j + 1] == "&":
            # fd-duplication (2>&1, >&2): re-emitted untouched so it falls
            # through to the pre-existing &-as-punctuation segment split,
            # never mistaken for a write to a file named the following digit.
            out.append(">&")
            j += 2
            continue
        if c == "&" and j + 2 < n and s[j + 1] == ">" and s[j + 2] == ">":
            out.append(" " + _REDIR_BOTH_APPEND + " ")
            j += 3
            continue
        if c == "&" and j + 1 < n and s[j + 1] == ">":
            out.append(" " + _REDIR_BOTH + " ")
            j += 2
            continue
        if c == ">" and j + 1 < n and s[j + 1] == ">":
            out.append(" " + _REDIR_APPEND + " ")
            j += 2
            continue
        if c == ">" and j + 1 < n and s[j + 1] == "|":
            out.append(" " + _REDIR_CLOBBER + " ")
            j += 2
            continue
        if c == ">":
            out.append(" " + _REDIR_TRUNC + " ")
            j += 1
            continue

        # A here-string (`<<<WORD`) is fundamentally different from a
        # heredoc (`<<`/`<<-`) and must be checked FIRST: it feeds a single
        # word to one command's stdin on the same line, never introduces a
        # multi-line terminated body, and never spans lines. Treating it as
        # a heredoc (matching on the first two `<` and reading `<<<WORD`'s
        # own `WORD` as a heredoc delimiter) swallows everything up to a
        # later matching line as an opaque "body" - silently hiding whatever
        # real commands are in there from every guard, the exact bypass
        # class this module exists to close. It is a plain redirect operator
        # here: consumed as ordinary text (the same as `main`'s old shlex-
        # per-line path, which tokenized `<<<foo` as one glued token) so the
        # rest of the line keeps scanning normally rather than being
        # swallowed as a heredoc body.
        if c == "<" and j + 2 < n and s[j + 1] == "<" and s[j + 2] == "<":
            out.append("<<<")
            j += 3
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

    # Wrapper-shell (`bash -c ...`) and `eval` payloads are shell code, not a
    # command name: lift each one, re-lexed through this same function, into
    # additional segments inserted immediately after their wrapper segment -
    # BEFORE the pending (substitution/heredoc) loop below, so a segment
    # produced by a recursive call here (which already ran its own wrapper
    # pass) is never re-scanned for wrappers a second time. Inserting inline
    # rather than appending at the end preserves source order, which
    # no-merge-guard.sh's `cd`-tracking depends on (see module docstring).
    expanded = []
    for seg in segments:
        expanded.append(seg)
        for payload in wrapper_payloads(seg):
            sub = command_segments(payload)
            if sub is None:
                return None
            expanded.extend(sub)
    segments = expanded

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


def _strip_prefixes(tokens):
    """Normalize the head of a token list before recognizing what it
    invokes: skip leading VAR=val assignments, expand a leading $VAR/${VAR}
    token from this hook's own environment (a hook sees the command string
    BEFORE shell expansion, so the literal `$WINGMAN_STATE ...` shape
    CLAUDE.md instructs arrives as a `$WINGMAN_STATE` token, not as the uv
    invocation it expands to), and unwrap `env`/`sudo`. This is the shared
    normalization both resolve_command() and wrapper_payloads() need - so
    `sudo bash -c ...`, `env FOO=1 bash -c ...`, and a leading `$VAR` shell
    token are recognized identically by both - factored out once so they can
    never drift apart. Returns [] (never raises) when a leading $VAR is unset
    or fails to expand: a false negative only, never a wrong allow."""
    i = 0
    while i < len(tokens) and _ASSIGNMENT_RE.match(tokens[i]):
        i += 1
    tokens = tokens[i:]
    if not tokens:
        return tokens
    m = _VAR_TOKEN_RE.match(tokens[0])
    if m:
        val = os.environ.get(m.group(1), "")
        if not val:
            return []
        try:
            expanded = shlex.split(val)
        except ValueError:
            return []
        return _strip_prefixes(expanded + tokens[1:])
    b = basename(tokens[0])
    if b in ("sudo", "env"):
        return _strip_prefixes(tokens[1:])
    return tokens


def _payload_list(payload):
    """A payload consisting SOLELY of one of _walk()'s inert substitution
    placeholders is skipped: the real content of that span is already lifted
    separately by _walk()'s own `pending` list, so re-lexing the placeholder
    text would only add a noise segment (e.g. `eval "$(ssh-agent -s)"` must
    keep producing exactly [['eval', '$(...)'], ['ssh-agent', '-s']], not a
    third junk segment from re-lexing the literal text "$(...)")."""
    return [] if payload in _INERT_PLACEHOLDERS else [payload]


_VALUE_TAKING_LONG_OPTS = ("--rcfile", "--init-file")


def wrapper_payloads(tokens):
    """Return the shell-code payload strings the segment `tokens` will
    execute: a wrapper shell's (`bash`/`sh`/`zsh`/`dash`/`ksh`) `-c` payload,
    or `eval`'s arguments (bash joins them with single spaces and re-parses
    the result, so this does too). Empty list for an ordinary segment, or
    for the `bash script.sh` script-path form (no `-c` payload to lift).
    `tokens` need not be pre-normalized - this applies the same prefix
    normalization as resolve_command() (see _strip_prefixes()) internally,
    so a caller can pass either a raw top-level segment or already-stripped
    tokens with identical results.

    Models bash's OWN option-parsing grammar, not "the token adjacent to the
    -c flag": `-c` selects command-string mode, but the payload is the first
    non-option OPERAND once option scanning is done, wherever that lands
    relative to `-c` itself. `-c` sharing a cluster with a value-taking `-o`/
    `-O` (`-co pipefail`, `-oc pipefail`), a `--` between `-c` and its
    payload (`-c -- "<cmd>"`), an unrelated value-taking option before `-c`
    (`-O extglob -c "<cmd>"`, `--rcfile FILE -c "<cmd>"`) all still resolve to
    the correct payload under this model, where "the next token after the
    cluster containing c" gets each of these wrong."""
    tokens = _strip_prefixes(tokens)
    if not tokens:
        return []
    b = basename(tokens[0])
    if b in _SHELL_WRAPPER_NAMES:
        i = 1
        n = len(tokens)
        saw_c = False
        while i < n:
            tok = tokens[i]
            if tok == "--" or tok == "-":
                # End of options; the next token (if any) is the operand,
                # regardless of what it looks like. A bare "-" ends option
                # processing exactly like "--" does. A bare "+" does NOT -
                # bash's own parse_shell_options() only special-cases a
                # leading "-" character for this early-terminator check
                # (confirmed: `bash + -ocO ...` still recognizes -ocO as a
                # real option cluster, while `bash - -ocO ...` treats
                # "-ocO" as a script-path operand and fails to open it);
                # a bare "+" instead falls into the cluster branch below
                # as a harmless no-op (empty letters).
                i += 1
                break
            if tok[0] == "+" or (len(tok) > 1 and tok[0] == "-"):
                if tok.startswith("--"):
                    # A long option: value-taking ones (--rcfile FILE,
                    # --init-file FILE) consume the following token too;
                    # every other long option (--norc, --login, ...) is
                    # boolean and is skipped as one token.
                    i += 2 if tok in _VALUE_TAKING_LONG_OPTS else 1
                    continue
                letters = tok[1:]
                if "c" in letters:
                    saw_c = True
                # -o/-O (or +o/+O) each take their OWN value; a cluster
                # carrying two of them (-coO, -cOo, -coo) consumes two value
                # tokens, not one - bash's parse_shell_options() processes
                # each letter in the cluster in turn, and -o/-O both take an
                # argument every time they appear, not just once per cluster.
                i += 1 + letters.count("o") + letters.count("O")
                continue
            # The first non-option token ends option scanning.
            break
        # Once option scanning ends, the first remaining operand is the -c
        # payload IF -c was seen anywhere among the options scanned;
        # otherwise it is a script path (the `bash script.sh` form), which
        # has no -c payload to lift. No operand at all (only options, or `--`
        # with nothing after it) also has no payload.
        if i < n and saw_c:
            return _payload_list(tokens[i])
        return []
    if b == "eval" and len(tokens) > 1:
        return _payload_list(" ".join(tokens[1:]))
    return []


def resolve_command(tokens):
    """Resolve the command one segment actually invokes: skip leading VAR=val
    assignments, unwrap `env`/`sudo`, a wrapper shell's script-path form
    (`bash script.sh`), and `uv run [flags]`, and return (basename, argv) where
    argv[0] is the resolved command token and argv[1:] its arguments. A wrapper
    shell carrying a `-c` payload resolves to the SHELL, not the payload (see
    the comment below). ("", []) when nothing resolves."""
    tokens = _strip_prefixes(tokens)
    if not tokens:
        return ("", [])
    b = basename(tokens[0])
    if b in _SHELL_WRAPPER_NAMES and len(tokens) > 1:
        # A `-c` payload resolves the segment to the shell ITSELF, never to
        # a basename() of the payload string: the payload's real commands
        # are lifted as separate segments by command_segments() already, so
        # resolving the wrapper to its first payload command would
        # double-report the same invocation to every consumer (see module
        # docstring). The script-path form (no -c payload) keeps today's
        # behavior: drop option tokens and resolve the first remaining one.
        if wrapper_payloads(tokens):
            return (b, tokens)
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
