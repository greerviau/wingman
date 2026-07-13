#!/usr/bin/env bash
# Unit coverage of hooks/lib/cmd_match.py's scanner (issue #56): one
# recursive-descent scan handles quoting, command/process substitution, and
# heredocs together, so a segment that cannot be lexed - anywhere in the
# command, including inside a nested substitution or heredoc body - makes the
# WHOLE command resolve to None (fail closed), never a partial list with the
# bad piece silently dropped.
#
# All the actual test commands and expected values are constructed and
# compared in Python (below) rather than in bash: several of them embed
# apostrophes, backticks, and unbalanced parens on purpose, and building those
# as bash string literals to compare against would itself be exactly the kind
# of fragile, error-prone quoting this fix is about. The Python script prints
# one "ok"/"FAIL" line per case; this wrapper just relays each line to
# lib.sh's own counters so the suite rolls up normally alongside every other
# tests/*.test.sh.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

RESULTS="$(PYTHONPATH="$TEST_REPO/hooks/lib" uv run --no-project --quiet python3 <<'PYEOF'
import sys
from cmd_match import command_segments, resolved_segments

results = []

def check(label, cmd, expect):
    """expect: None for a lex failure, or a list of expected argv lists."""
    got = command_segments(cmd)
    ok = got == expect
    results.append((ok, label, expect, got))

def check_none(label, cmd):
    check(label, cmd, None)

def check_true(label, cond):
    results.append((bool(cond), label, True, cond))

def check_contains(label, cmd, needle):
    got = command_segments(cmd)
    ok = got is not None and any(needle in seg for seg in got)
    results.append((ok, label, "contains %r" % (needle,), got))

# ============================================================================
# Negative: fail closed
# ============================================================================

check_none("a genuinely unterminated quote", "echo 'oops")

check_none("an unbalanced $(...)", "echo $(touch /tmp/x")

check_none("a heredoc whose terminator is never found",
           "cat <<EOF\nhello\nworld\n")

check_none("a heredoc-in-substitution whose terminator is never found",
           'echo "$(cat <<EOF\nhello\n)"')

check_none("an unquoted-delimiter heredoc body with an unpaired backtick",
           "cat <<EOF\nthis has an unpaired ` backtick\nEOF\n")

check_none("a malformed heredoc redirect (no delimiter word)",
           "cat <<\n")

# ============================================================================
# Issue #56's own repro: both segments now visible (no silent drop) - the
# fix does NOT need this specific command to become None; it needs the
# previously-dropped `touch` segment to become VISIBLE, so a caller (e.g.
# pilot-preferences-guard.sh) denies on ITS merits instead of never seeing it.
# ============================================================================

check("issue #56 repro: both segments resolved, none silently dropped",
      "bin/crew-list\ntouch /tmp/x_from_issue56 \\\n",
      [["bin/crew-list"], ["touch", "/tmp/x_from_issue56"]])

# ============================================================================
# Positive - non-heredoc multi-line shapes (r2)
# ============================================================================

check("the documented multi-line crew-set continuation",
      '$WINGMAN_STATE crew-set --id foo \\\n  --status working \\\n  --summary "on it"',
      [["$WINGMAN_STATE", "crew-set", "--id", "foo", "--status", "working",
        "--summary", "on it"]])

check("a multi-line git commit -m message with an apostrophe",
      'git commit -m "First line\nSecond line with an apostrophe: don\'t worry"',
      [["git", "commit", "-m",
        "First line\nSecond line with an apostrophe: don't worry"]])

# ============================================================================
# Positive - bare heredoc shapes (r3)
# ============================================================================

check("an unquoted-delimiter heredoc body with an apostrophe",
      "cat <<EOF\nThis doesn't push to main.\nEOF\n",
      [["cat", "<<EOF"]])

check("a quoted-delimiter heredoc body mentioning a guarded command",
      "cat <<'EOF'\nDon't run gh pr merge 123 --squash directly.\nEOF\n",
      [["cat", "<<EOF"]])

check("a quoted-delimiter heredoc body with an odd number of backticks",
      "cat <<'EOF'\nan odd ` count of backticks in here\nEOF\n",
      [["cat", "<<EOF"]])

# ============================================================================
# Positive - heredoc NESTED inside a substitution (r4, the case that
# regressed): a body containing BOTH an apostrophe AND an unbalanced paren,
# across the double-quoted, unquoted, and backtick substitution forms, plus
# apostrophe-only and paren-only variants - six combinations total, so no
# single case is "the lucky payload" the r4 review warned about.
# ============================================================================

bodies = {
    "apostrophe-only": "This doesn't push to main.",
    "paren-only": "This (has an unbalanced paren.",
    "both": "This doesn't (have both.",
}

for body_label, body in bodies.items():
    dq = 'gh pr create --body "$(cat <<\'EOF\'\n%s\nEOF\n)"' % body
    check_contains("nested heredoc (%s, double-quoted $(...)) lifts the outer command"
                   % body_label, dq, "$(...)")

    unq = "gh pr create --body $(cat <<'EOF'\n%s\nEOF\n)" % body
    check_contains("nested heredoc (%s, unquoted $(...)) lifts the outer command"
                   % body_label, unq, "$(...)")

    bt = "gh pr create --body `cat <<'EOF'\n%s\nEOF\n`" % body
    check_contains("nested heredoc (%s, backtick) lifts the outer command"
                   % body_label, bt, "`...`")

    for label, cmd in (("double-quoted", dq), ("unquoted", unq), ("backtick", bt)):
        got = command_segments(cmd)
        check_true("nested heredoc (%s, %s) does not deny (resolves, not None)"
                   % (body_label, label), got is not None)
        if got is not None:
            check_true("nested heredoc (%s, %s) does not trigger a merge deny "
                       "(no literal merge/gh pr merge text reaches a segment)"
                       % (body_label, label),
                       not any("merge" in tok for seg in got for tok in seg))

# ============================================================================
# Here-strings (<<<) are NOT heredocs (PR #72 review, finding 1 - must-fix):
# a here-string feeds one word to a single command's stdin on the same line
# and never spans lines or introduces a multi-line terminated body.
# Misreading `<<<WORD` as a heredoc whose delimiter is `<WORD` swallows
# whatever real commands follow as an opaque "body," hiding them from every
# guard - the exact bypass class this module exists to close, just via a
# different construct than the original issue #56 repro.
# ============================================================================

check("a here-string does not swallow the following command as a heredoc body",
      "grep x <<<foo\ngh pr merge 5 --squash\n<foo",
      [["grep", "x", "<<<foo"], ["gh", "pr", "merge", "5", "--squash"], ["<foo"]])

check("a plain here-string with a variable is allowed, not hard-denied",
      'grep foo <<< "$var"',
      [["grep", "foo", "<<<", "$var"]])

check("read ... <<< is allowed, not hard-denied",
      'read a b <<< "$line"',
      [["read", "a", "b", "<<<", "$line"]])

check("jq ... <<< is allowed, not hard-denied",
      'jq . <<< "$json"',
      [["jq", ".", "<<<", "$json"]])

# ============================================================================
# `#` comments (PR #72 review, finding 2 - should-fix): a trailing comment is
# completely inert - never quoted, never scanned for substitutions or
# heredocs - matching bash and the old shlex-based path's default
# `commenters='#'`. False-deny only if unhandled (never a bypass), but still
# a regression from main worth closing.
# ============================================================================

check("a trailing comment containing an apostrophe does not corrupt the scan",
      "echo hi  # don't",
      [["echo", "hi"]])

check("a trailing comment containing $(, a backtick, and << does not corrupt the scan",
      "echo hi  # $(foo) `bar` << baz",
      [["echo", "hi"]])

check("a comment can open a command-substitution span (word boundary at region start)",
      "echo $(# comment\ntouch /tmp/x\n)",
      [["echo", "$(...)"], ["touch", "/tmp/x"]])

# ============================================================================
# Substitution / process-substitution lifting
# ============================================================================

check("$(...) lifts its content as an extra segment",
      "bin/crew-list $(touch /tmp/x)",
      [["bin/crew-list", "$(...)"], ["touch", "/tmp/x"]])

check("a backtick substitution lifts its content as an extra segment",
      "bin/crew-list `touch /tmp/x`",
      [["bin/crew-list", "`...`"], ["touch", "/tmp/x"]])

check("<(...) lifts its content as an extra segment",
      "bin/crew-list <(touch /tmp/x)",
      [["bin/crew-list", "<(...)"], ["touch", "/tmp/x"]])

check(">(...) lifts its content as an extra segment",
      "bin/crew-list >(touch /tmp/x)",
      [["bin/crew-list", ">(...)"], ["touch", "/tmp/x"]])

check("single-quoted substitution text is inert",
      "echo '$(touch /tmp/x)'",
      [["echo", "$(touch /tmp/x)"]])

check("a merge command hidden inside a substitution is still lifted",
      'echo "$(gh pr merge 123 --squash)"',
      [["echo", "$(...)"], ["gh", "pr", "merge", "123", "--squash"]])

# A substitution nested two levels deep, including one with a live $(...)
# inside an unquoted heredoc body inside an outer substitution, is still
# found. Unquoted heredoc delimiters throughout, matching real bash: only an
# UNQUOTED delimiter's body undergoes command-substitution expansion at all.
deep = ("bin/crew-list $(cat <<OUTER\n"
        "$(cat <<INNER\n"
        "$(touch /tmp/x)\n"
        "INNER\n"
        ")\n"
        "OUTER\n"
        ")")
check("a substitution nested two levels deep (live sub in innermost heredoc) is still found",
      deep,
      [["bin/crew-list", "$(...)"], ["cat", "<<OUTER"], ["cat", "<<INNER"],
       ["touch", "/tmp/x"]])

# ============================================================================
# resolved_segments() propagates None; a blank/whitespace-only command
# still returns [].
# ============================================================================

check_true("resolved_segments() propagates None on a lex failure",
           resolved_segments("echo 'oops") is None)

check("a blank command returns []", "", [])
check("a whitespace-only command returns []", "   ", [])

# ============================================================================
# Report
# ============================================================================

for ok, label, expect, got in results:
    status = "ok" if ok else "FAIL"
    print("%s\t%s" % (status, label))
    if not ok:
        print("DETAIL\t  expected %r got %r" % (expect, got))

sys.exit(0 if all(r[0] for r in results) else 1)
PYEOF
)"

while IFS=$'\t' read -r status rest; do
  case "$status" in
    ok) ok "$rest" ;;
    FAIL) fail "$rest" ;;
    DETAIL) printf '%s\n' "$rest" ;;
  esac
done <<< "$RESULTS"

test_summary
