#!/usr/bin/env bash
# Differential oracle for hooks/lib/cmd_match.py's `wrapper_payloads()`
# option-scan loop (issue #183): generates a broad sweep of `bash` argv
# tails combining `-c` alone, `-c` clustered with one or two of `o`/`O` in
# every order, and a few boolean letters, each wrapped with a modifier
# token/pair (`--norc`, `--rcfile FILE`, `-O extglob`, `+o pipefail`, `--`,
# `-`) both before and after the cluster - then runs REAL bash as the oracle
# and asserts `wrapper_payloads()` lifts the exact same payload real bash
# actually executed. This promotes the ad-hoc script used to review PR #182
# and this fix from a one-off manual check to a permanent regression: the
# next narrowing of this scanner's model gets caught by CI, not by a third
# manual review pass (see docs/plans/2026-08-07-issue-183-cmd-match-option-
# scan-plan.md, section 4.3).
#
# Pass criterion: for every shape where real bash actually executes the
# generated payload as -c code (confirmed via a per-shape marker in stdout),
# wrapper_payloads() must lift that exact payload. A shape where bash
# refuses to run anything (an invalid shopt name, a misplaced long option,
# a script-path-not-found, ...) is symmetric-safe regardless of what the
# scanner does - worst case is an extra-conservative false deny, never a
# wrong allow - so it is excluded from the assertion, matching this
# module's own documented tradeoff, and its count is reported rather than
# silently absorbed into "zero mismatches" (this repo's "no silent caps"
# testing convention).
#
# Scope note: this oracle only invokes real `bash`. The scanner applies the
# same option-scan model to sh/zsh/dash/ksh as a deliberate, pre-existing
# approximation (see cmd-match.test.sh's own sh/zsh/dash/ksh -c cases, which
# only check that lifting occurs, not that each shell's distinct grammar is
# modeled exactly) - extending this oracle to each shell's own real grammar
# is a residual gap, not addressed here.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

_wm_py="$(wm_mktemp_file)"
cat > "$_wm_py" <<'PYEOF'
import itertools
import subprocess
import sys

from cmd_match import wrapper_payloads

# --- 1. generator: bash argv tails -----------------------------------------

# A few boolean letters mixed with plain -c (both orders), to keep the
# existing -lc/-ec/-xc coverage exercised by this same generator - a
# separate axis from the o/O clusters below, not cross-producted with them
# (that combination would inflate the sweep well past what was validated
# during design without adding coverage of issue #183's own bug shape).
_BOOLEAN_LETTERS = ["l", "e", "x"]

# One or two of o/O (in every order the multiset admits), the exact shape of
# issue #183's own bug.
_VALUE_MULTISETS = [["o"], ["O"], ["o", "o"], ["O", "O"], ["o", "O"]]


def _cluster_strings():
    """Every distinct short-option cluster containing exactly one 'c' and
    either 0-1 boolean letter, or 0-2 of o/O, in every order the letters
    admit."""
    seen = set()
    out = []

    def _add_all(letters):
        for perm in sorted(set(itertools.permutations(letters))):
            s = "".join(perm)
            if s not in seen:
                seen.add(s)
                out.append(s)

    _add_all(["c"])
    for bl in _BOOLEAN_LETTERS:
        _add_all(["c", bl])
    for vs in _VALUE_MULTISETS:
        _add_all(["c"] + list(vs))
    return out


# Real shell-option/shopt names only - bash validates -O's argument against
# real shopt names before it will run anything at all, so a placeholder
# string like "val0" would make bash abort before ever reaching the
# payload, which would look like a false mismatch to a naive oracle.
_LOWER_O_NAMES = ["pipefail", "noclobber", "errexit"]
_UPPER_O_NAMES = ["extglob", "nullglob", "posix"]


def _value_tokens_for(cluster, variant):
    """One real shell-option/shopt name per o/O in `cluster`, in order.
    `variant` rotates which name is picked, so the sweep as a whole
    exercises more than one real name per letter, not just the first."""
    lo = up = 0
    toks = []
    for ch in cluster:
        if ch == "o":
            toks.append(_LOWER_O_NAMES[(variant + lo) % len(_LOWER_O_NAMES)])
            lo += 1
        elif ch == "O":
            toks.append(_UPPER_O_NAMES[(variant + up) % len(_UPPER_O_NAMES)])
            up += 1
    return toks


# A modifier token/pair, applied both BEFORE and AFTER the cluster
# (independently, so both positions are exercised) - None means "no
# modifier", tested once (position is meaningless then).
_MODIFIERS = [
    None,
    ("--norc",),
    ("--rcfile", "/dev/null"),
    ("-O", "extglob"),
    ("+o", "pipefail"),
    ("--",),
    ("-",),
]


def shapes():
    """Yield (label, argv_tail, marker) for every generated shape."""
    n = 0
    for cluster in _cluster_strings():
        has_value_letters = ("o" in cluster) or ("O" in cluster)
        variants = (0, 1) if has_value_letters else (0,)
        for variant in variants:
            value_toks = _value_tokens_for(cluster, variant)
            cluster_tok = "-" + cluster
            for mod in _MODIFIERS:
                placements = ("none",) if mod is None else ("before", "after")
                for placement in placements:
                    n += 1
                    marker = "WM_ORACLE_MARK_%d" % n
                    payload = "echo %s" % marker
                    mod_toks = list(mod) if mod else []
                    if placement == "before":
                        tail = mod_toks + [cluster_tok] + value_toks + [payload]
                    elif placement == "after":
                        tail = [cluster_tok] + value_toks + mod_toks + [payload]
                    else:
                        tail = [cluster_tok] + value_toks + [payload]
                    label = "bash %s" % " ".join(tail)
                    yield label, tail, marker


# --- 2. real-bash oracle + 3. guard comparison ------------------------------

total = 0
excluded = 0
mismatches = []

for label, tail, marker in shapes():
    total += 1
    argv = ["bash"] + tail
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=5)
    except subprocess.TimeoutExpired:
        excluded += 1
        continue
    ran_intended_payload = marker in proc.stdout
    if not ran_intended_payload:
        # Bash refused to run anything (invalid shopt name, a misplaced
        # long option, a script-path-not-found, ...) or ran something other
        # than the intended operand as code. Symmetric-safe either way -
        # not asserted on, only counted.
        excluded += 1
        continue
    expected = ["echo %s" % marker]
    got = wrapper_payloads(argv)
    if got != expected:
        mismatches.append((label, argv, expected, got))

ok_overall = not mismatches
summary = (
    "issue #183 oracle: %d shapes generated, %d excluded (bash refused to "
    "run anything, or ran something other than the intended operand - "
    "symmetric-safe either way), %d asserted against wrapper_payloads(), "
    "%d mismatches"
    % (total, excluded, total - excluded, len(mismatches))
)
print(("ok" if ok_overall else "FAIL") + "\t" + summary)
if not ok_overall:
    for label, argv, expected, got in mismatches:
        print("DETAIL\t  %s: argv=%r expected=%r got=%r" % (label, argv, expected, got))

sys.exit(0 if ok_overall else 1)
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
