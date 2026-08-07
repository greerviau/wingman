#!/usr/bin/env bash
# Unit coverage of hooks/lib/cmd_match.py's scanner (issue #56): one
# recursive-descent scan handles quoting, command/process substitution, and
# heredocs together, so a segment that cannot be lexed - anywhere in the
# command, including inside a nested substitution or heredoc body - makes the
# WHOLE command resolve to None (fail closed), never a partial list with the
# bad piece silently dropped. Also covers issue #168: a `bash`/`sh`/`zsh`/
# `dash`/`ksh -c` payload or an `eval` payload is lifted and re-checked as
# its own segment(s), inserted in source order right after the wrapper
# segment - never resolved as a literal command name (a wrong ALLOW against
# a deny-style gate, the bug this closes).
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

# The Python body is written to a file first, NOT fed as a heredoc inside the
# $(...) capture: bash 3.2 (stock macOS) does not parse a command substitution
# recursively, so a heredoc body containing unmatched quotes - which this one
# embeds on purpose as test inputs - breaks the parse of the whole file there.
_wm_py="$(wm_mktemp_file)"
cat > "$_wm_py" <<'PYEOF'
import sys
from cmd_match import command_segments, resolved_segments, resolve_command

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
# Issue #168: bash -c / sh -c / eval wrapper payloads are lifted, not
# resolved as a literal command name.
# ============================================================================

# --- the bypass itself, per the issue's own repro table ---------------------

check("bash -c lifts its payload as a separate segment, wrapper first",
      'bash -c "gh pr merge 5 --squash"',
      [["bash", "-c", "gh pr merge 5 --squash"],
       ["gh", "pr", "merge", "5", "--squash"]])

check("sh -c lifts its payload",
      "sh -c 'gh pr merge 5'",
      [["sh", "-c", "gh pr merge 5"], ["gh", "pr", "merge", "5"]])

check("zsh -c lifts its payload",
      "zsh -c 'gh pr merge 5'",
      [["zsh", "-c", "gh pr merge 5"], ["gh", "pr", "merge", "5"]])

check("dash -c lifts its payload",
      "dash -c 'gh pr merge 5'",
      [["dash", "-c", "gh pr merge 5"], ["gh", "pr", "merge", "5"]])

check("ksh -c lifts its payload",
      "ksh -c 'gh pr merge 5'",
      [["ksh", "-c", "gh pr merge 5"], ["gh", "pr", "merge", "5"]])

check("eval lifts its payload",
      'eval "gh pr merge 5 --squash"',
      [["eval", "gh pr merge 5 --squash"],
       ["gh", "pr", "merge", "5", "--squash"]])

check("eval joins multiple arguments with a space before re-parsing",
      'eval "gh pr" "merge 5"',
      [["eval", "gh pr", "merge 5"], ["gh", "pr", "merge", "5"]])

# --- flag shapes -------------------------------------------------------

check("bash -lc (combined flag cluster) lifts the payload",
      'bash -lc "gh pr merge 5"',
      [["bash", "-lc", "gh pr merge 5"], ["gh", "pr", "merge", "5"]])

check("bash -ec (combined flag cluster) lifts the payload",
      'bash -ec "gh pr merge 5"',
      [["bash", "-ec", "gh pr merge 5"], ["gh", "pr", "merge", "5"]])

check("bash -xc (combined flag cluster) lifts the payload",
      'bash -xc "gh pr merge 5"',
      [["bash", "-xc", "gh pr merge 5"], ["gh", "pr", "merge", "5"]])

check("bash -o pipefail -c lifts the payload (the -o value token is skipped)",
      'bash -o pipefail -c "gh pr merge 5"',
      [["bash", "-o", "pipefail", "-c", "gh pr merge 5"],
       ["gh", "pr", "merge", "5"]])

check("bash --norc -c lifts the payload (the long option is skipped as one token)",
      'bash --norc -c "gh pr merge 5"',
      [["bash", "--norc", "-c", "gh pr merge 5"], ["gh", "pr", "merge", "5"]])

# --- bash's real option grammar: the payload is the first operand once
# option scanning ends, not "the token adjacent to the c letter" - five
# shapes a naive adjacency rule gets wrong (found in review) ----------------

check("bash -co pipefail lifts the payload (c sharing a cluster with the "
      "value-taking o - the o's own value must not be mistaken for the payload)",
      'bash -co pipefail "gh pr merge 5"',
      [["bash", "-co", "pipefail", "gh pr merge 5"], ["gh", "pr", "merge", "5"]])

check("bash -oc pipefail lifts the payload (flag order within the cluster "
      "does not matter)",
      'bash -oc pipefail "gh pr merge 5"',
      [["bash", "-oc", "pipefail", "gh pr merge 5"], ["gh", "pr", "merge", "5"]])

check("bash -c -- lifts the payload (-- between -c and its payload ends "
      "option scanning; the next token is still the operand)",
      'bash -c -- "gh pr merge 5"',
      [["bash", "-c", "--", "gh pr merge 5"], ["gh", "pr", "merge", "5"]])

check("bash -O extglob -c lifts the payload (an unrelated value-taking "
      "short option before -c)",
      'bash -O extglob -c "gh pr merge 5"',
      [["bash", "-O", "extglob", "-c", "gh pr merge 5"], ["gh", "pr", "merge", "5"]])

check("bash --rcfile FILE -c lifts the payload (a value-taking long option "
      "before -c)",
      'bash --rcfile /dev/null -c "gh pr merge 5"',
      [["bash", "--rcfile", "/dev/null", "-c", "gh pr merge 5"],
       ["gh", "pr", "merge", "5"]])

# --- issue #183: a bare "-" and stacked o/O in a -c cluster (found in a
# second review pass, same bug class as the shapes above) ------------------

check("bash -c - lifts the payload (a bare - ends option scanning exactly like --)",
      'bash -c - "gh pr merge 46"',
      [["bash", "-c", "-", "gh pr merge 46"], ["gh", "pr", "merge", "46"]])

check("bash -coO pipefail extglob lifts the payload (two value-taking o/O in one "
      "cluster each consume their own value token)",
      'bash -coO pipefail extglob "gh pr merge 46"',
      [["bash", "-coO", "pipefail", "extglob", "gh pr merge 46"],
       ["gh", "pr", "merge", "46"]])

check("bash -cOo extglob pipefail lifts the payload (order of the stacked o/O within "
      "the cluster does not matter)",
      'bash -cOo extglob pipefail "gh pr merge 46"',
      [["bash", "-cOo", "extglob", "pipefail", "gh pr merge 46"],
       ["gh", "pr", "merge", "46"]])

check("bash -coo pipefail posix lifts the payload (two lowercase o's in one cluster "
      "each consume their own value token)",
      'bash -coo pipefail posix "gh pr merge 46"',
      [["bash", "-coo", "pipefail", "posix", "gh pr merge 46"],
       ["gh", "pr", "merge", "46"]])

check("positional parameters after the payload are not lifted",
      'bash -c "echo hi" arg0 arg1',
      [["bash", "-c", "echo hi", "arg0", "arg1"], ["echo", "hi"]])

# --- multi-command payloads: order preserved, since no-merge-guard.sh's own
# cd-tracking depends on a lifted segment appearing right after its wrapper --

check("a payload joined with && lifts two segments in source order",
      'bash -c "cd /w && gh pr merge 5"',
      [["bash", "-c", "cd /w && gh pr merge 5"],
       ["cd", "/w"], ["gh", "pr", "merge", "5"]])

check("a payload joined with ; lifts two segments in source order",
      'bash -c "echo hi; gh pr merge 5"',
      [["bash", "-c", "echo hi; gh pr merge 5"],
       ["echo", "hi"], ["gh", "pr", "merge", "5"]])

check("a nested bash -c lifts through both levels",
      "bash -c \"bash -c 'gh pr merge 5'\"",
      [["bash", "-c", "bash -c 'gh pr merge 5'"],
       ["bash", "-c", "gh pr merge 5"],
       ["gh", "pr", "merge", "5"]])

# --- prefix normalization: sudo/env/a bare assignment before the wrapper ----

check("sudo bash -c lifts the payload",
      'sudo bash -c "gh pr merge 5"',
      [["sudo", "bash", "-c", "gh pr merge 5"], ["gh", "pr", "merge", "5"]])

check("env FOO=1 bash -c lifts the payload",
      'env FOO=1 bash -c "gh pr merge 5"',
      [["env", "FOO=1", "bash", "-c", "gh pr merge 5"],
       ["gh", "pr", "merge", "5"]])

check("a bare VAR=val assignment before bash -c lifts the payload",
      'FOO=1 bash -c "gh pr merge 5"',
      [["FOO=1", "bash", "-c", "gh pr merge 5"], ["gh", "pr", "merge", "5"]])

# --- resolution of the wrapper segment: the direct regression assertion for
# this bug - the segment must resolve to the shell, never a basename() of
# the payload string -----------------------------------------------------

check_true("resolve_command() on a -c wrapper segment resolves to the shell "
           "itself, not a basename of the payload string",
           resolve_command(["bash", "-c", "gh pr merge 5 --squash"])
           == ("bash", ["bash", "-c", "gh pr merge 5 --squash"]))

# --- preserved behavior --------------------------------------------------

check("bash script.sh (no -c) still resolves to the script path, unaffected",
      "bash script.sh", [["bash", "script.sh"]])
check_true("bash script.sh resolves to the script, not the shell",
           resolve_command(["bash", "script.sh"]) == ("script.sh", ["script.sh"]))

check("bash -c tests/run.sh yields a segment resolving to tests/run.sh "
      "(the no-direct-edit-guard.sh regression case)",
      "bash -c tests/run.sh",
      [["bash", "-c", "tests/run.sh"], ["tests/run.sh"]])
check_true("bash -c tests/run.sh's lifted segment resolves with argv[0] tests/run.sh",
           resolve_command(["tests/run.sh"])[1] == ["tests/run.sh"])

_py_segs = command_segments("python3 -c \"import os; os.system('gh pr merge 5')\"")
check_true("a Python -c payload lifts nothing (stays a single segment)",
           _py_segs is not None and len(_py_segs) == 1)
check_true("a Python -c payload resolves to python3, not a lifted command",
           _py_segs is not None and resolve_command(_py_segs[0])[0] == "python3")
check_true("a Python -c payload never surfaces a separate lifted 'gh pr merge' segment",
           _py_segs is not None
           and not any(seg[:3] == ["gh", "pr", "merge"] for seg in _py_segs))

check("python3 -m pytest is still un-unwrapped (unchanged by this fix)",
      "python3 -m pytest", [["python3", "-m", "pytest"]])

check("eval \"$(ssh-agent -s)\" still yields exactly the substitution's own "
      "lifted segment, with no re-lexed placeholder noise",
      'eval "$(ssh-agent -s)"',
      [["eval", "$(...)"], ["ssh-agent", "-s"]])

# --- fail-closed: an unlexable payload denies the WHOLE command, matching
# bash's own rejection of the same string ------------------------------------

check_none("bash -c with an unlexable payload (bash itself rejects this string)",
           "bash -c \"echo it's fine\"")

check_none("eval with an unlexable payload",
           "eval \"echo 'oops\"")

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
RESULTS="$(PYTHONPATH="$TEST_REPO/hooks/lib" uv run --no-project --quiet python3 "$_wm_py")"

while IFS=$'\t' read -r status rest; do
  case "$status" in
    ok) ok "$rest" ;;
    FAIL) fail "$rest" ;;
    DETAIL) printf '%s\n' "$rest" ;;
  esac
done <<< "$RESULTS"

test_summary
