#!/usr/bin/env bash
# Harmless stand-in for the real `claude` CLI, used as the suite's default
# WM_AGENT (tests/lib.sh) so a test that forgets to stub its own agent never
# falls through to launching a real Claude Code session. 86400s (not a
# shorter bounded sleep) so it cannot expire mid-file in a long-running suite
# like watch-fleet.test.sh and produce a time-dependent flake; a plain
# integer rather than GNU coreutils' "infinity" keeps this portable to BSD
# sleep (macOS).
exec sleep 86400
