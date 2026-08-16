#!/usr/bin/env bash
# E2E regression: with no $WM_ORCH_AGENT set, the orchestrator resolves to
# claude and execs it with exactly the pre-existing --add-dir/passthrough
# composition - nothing added or removed. This is the byte-identical merge
# gate the whole orchestrator-adapter mechanism exists to preserve, mirrored
# from tests/agent-adapter-default-regression.test.sh's own crew-side
# discipline - bin/wingman execs directly rather than writing a launch
# script to disk, so a stub `claude` binary captures the real argv instead
# of a launch-script grep.
#
# A "repo mirror" (bin/ symlinked whole, hooks/ individually symlinked) runs
# a real bin/wingman with nothing broken, so the guard-hook-sync gate passes
# and execution reaches the final exec line. Not a git repo, so the
# checkout-freshness advisory fails fast instead of a real network fetch -
# same convention as tests/session-guard-hook-sync.test.sh's own mirror.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

mk_mirror() {
  mkdir -p "$1"
  ln -s "$TEST_REPO/bin" "$1/bin"
  mkdir -p "$1/hooks"
  for f in "$TEST_REPO"/hooks/*; do
    [ -f "$f" ] || continue
    ln -s "$f" "$1/hooks/$(basename "$f")"
  done
}

test_new_home
MIRROR="$(wm_mktemp_dir)/mirror"
mk_mirror "$MIRROR"

STUBDIR="$(wm_mktemp_dir)"
MARKER="$STUBDIR/argv"
cat > "$STUBDIR/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$MARKER"
exit 0
EOF
chmod +x "$STUBDIR/claude"

# tests/lib.sh's default WM_AGENT_BIN_OVERRIDE would win over this file's
# PATH-based stub - unset it here (see tests/agent-descriptor-completeness.test.sh).
unset WM_AGENT_BIN_OVERRIDE
unset WM_ORCH_AGENT

out="$(PATH="$STUBDIR:$PATH" "$MIRROR/bin/wingman" --wingman-default-regression-marker 2>&1)"; rc=$?
wm_stop_guardian
assert_eq "bin/wingman exits 0 on a healthy repo" "$rc" "0"
assert_true "the claude stub was execed (proves WM_AGENT_BIN resolved to 'claude', unchanged)" "[ -f '$MARKER' ]"

# Reconstructed from the same discover-projects logic bin/wingman calls,
# rather than a pinned root list, so the test isn't fragile to the machine
# it runs on.
expected_adddirs=""
while IFS= read -r root; do
  [ -n "$root" ] && expected_adddirs="$expected_adddirs --add-dir $root"
done <<EOF
$("$MIRROR/bin/discover-projects" --roots 2>/dev/null)
EOF
# shellcheck disable=SC2086
set -- $expected_adddirs --wingman-default-regression-marker
expected_argv="$(printf '%s\n' "$@")"

actual_argv="$(cat "$MARKER" 2>/dev/null)"
assert_eq "the composed argv for the default (no \$WM_ORCH_AGENT) case is byte-identical to pre-adapter-port output" \
  "$actual_argv" "$expected_argv"

test_summary
