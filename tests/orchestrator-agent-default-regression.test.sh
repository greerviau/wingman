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

# --- an unknown $WM_ORCH_AGENT refuses pre-exec and lands in the durable ----
# failure sink, so a systemd-run wingman's own lost stderr still leaves a
# trace bin/doctor can surface.
test_new_home
MIRROR2="$(wm_mktemp_dir)/mirror2"
mk_mirror "$MIRROR2"
unset WM_AGENT_BIN_OVERRIDE
out2="$(WM_ORCH_AGENT=no-such-orchestrator-agent-xyz "$MIRROR2/bin/wingman" 2>&1)"; rc2=$?
wm_stop_guardian
assert_true "an unknown \$WM_ORCH_AGENT refuses to start" "[ $rc2 -ne 0 ]"
assert_contains "the refusal names the unknown agent" "$out2" "no-such-orchestrator-agent-xyz"
assert_true "the launch-failure sink was written" "[ -f '$WINGMAN_HOME/last-launch-failure' ]"
assert_contains "the sink names the orchestrator-agent component" \
  "$(cat "$WINGMAN_HOME/last-launch-failure" 2>/dev/null)" "orchestrator agent"

# --- crew's own $WM_AGENT/[harness.agent] never leak into orchestrator -----
# resolution - the property $WM_ORCH_AGENT exists to guarantee. Proven with a
# deliberately bogus crew-side value: if a future change ever merged the two
# knobs (e.g. ${WM_ORCH_AGENT:-${WM_AGENT:-claude}}), the orchestrator would
# try to resolve this bogus name too and fail loudly instead of staying on
# claude.
test_new_home
MIRROR3="$(wm_mktemp_dir)/mirror3"
mk_mirror "$MIRROR3"
STUBDIR3="$(wm_mktemp_dir)"
MARKER3="$STUBDIR3/invoked"
cat > "$STUBDIR3/claude" <<EOF
#!/usr/bin/env bash
printf 'invoked' > "$MARKER3"
exit 0
EOF
chmod +x "$STUBDIR3/claude"
unset WM_AGENT_BIN_OVERRIDE
unset WM_ORCH_AGENT
out3="$(WM_AGENT=no-such-crew-agent-xyz PATH="$STUBDIR3:$PATH" "$MIRROR3/bin/wingman" 2>&1)"; rc3=$?
wm_stop_guardian
assert_eq "\$WM_AGENT (crew's own knob) does not affect the orchestrator: still exits 0" "$rc3" "0"
assert_true "...and still execs the real claude stub rather than failing to resolve the bogus crew value" \
  "[ -f '$MARKER3' ]"
assert_not_contains "...with no bogus-agent resolution failure leaking through" "$out3" "unknown orchestrator agent"

# ...and the config file's [harness.agent] table (crew's own knob) doesn't
# leak into orchestrator resolution either.
test_new_home
MIRROR4="$(wm_mktemp_dir)/mirror4"
mk_mirror "$MIRROR4"
STUBDIR4="$(wm_mktemp_dir)"
MARKER4="$STUBDIR4/invoked"
cat > "$STUBDIR4/claude" <<EOF
#!/usr/bin/env bash
printf 'invoked' > "$MARKER4"
exit 0
EOF
chmod +x "$STUBDIR4/claude"
wm_write_config <<'EOF'
[harness.agent]
default = "no-such-crew-agent-xyz"
EOF
unset WM_AGENT_BIN_OVERRIDE
unset WM_ORCH_AGENT
out4="$(PATH="$STUBDIR4:$PATH" "$MIRROR4/bin/wingman" 2>&1)"; rc4=$?
wm_stop_guardian
assert_eq "[harness.agent].default (crew's own knob) does not affect the orchestrator: still exits 0" "$rc4" "0"
assert_true "...and still execs the real claude stub" "[ -f '$MARKER4' ]"
assert_not_contains "...with no bogus-agent resolution failure leaking through" "$out4" "unknown orchestrator agent"
wm_rm_config

test_summary
