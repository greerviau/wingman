#!/usr/bin/env bash
# Emulates the verified composer shape via a real in-place screen redraw
# (clear + home), so a settled frame is byte-identical across repeated
# draws and only an actual content/tick change produces a different
# capture - exactly how the real CLI's own TUI repaints, and unlike a
# naive scroll-append emulation (which would leave stale in-flight typing
# frames in the pane's history and make "byte-identical between polls"
# never true even once nothing is actually changing).
# Originally inline in tests/composer-confirm-delivery.test.sh (issue #188);
# extracted to a fixture (issue #236) so tests/watch-fleet.test.sh and
# tests/stall-nudge-confirmation.test.sh can drive the same real composer
# shape instead of grepping tmux scrollback for text that may only have
# been typed, never submitted.
#
# WM_TEST_BUSY=0/1: whether an independent "working... tick=N" line (in the
# transcript area ABOVE the composer's own top rule - never between the two
# rules, matching a live busy capture) repaints on its own clock.
# WM_TEST_SWALLOW=0/1: whether Enter clears the composer (a registered
# submit) or is dropped (composer stays pending, nothing submitted).
# WM_TEST_TICK: the busy repaint's own clock, seconds (default 0.3);
# override to a value slower than WM_SUBMIT_POLL to force at least one
# poll to coincidentally alias (read byte-identical to the previous one)
# while busy is still true elsewhere in the run.
# WM_TEST_TRANSCRIPT (issue #236): an optional fixed line rendered in the
# transcript area immediately above the composer's top rule (same place as
# the busy tick line, and stacked above it when both are set), so a fixture
# can present an API-error signature to api_error_check without leaving
# stray unsubmitted text as the only way to prove what was sent.
# "intr undef" keeps a raw Ctrl-C byte flowing to this loop as ordinary
# input (wm_tmux_send_message's own defensive clear-keys) instead of
# raising SIGINT against the stub itself, matching a real composer that
# treats Ctrl-C as "clear the box" rather than killing the process.
# ENTER/SUBMITTED markers go to a side-channel file (WM_TEST_MARKER,
# required), never to the pane itself, so counting them never perturbs the
# very pane state under test. SUBMITTED carries the submitted text
# (SUBMITTED:<n>:<text>) so a caller can assert WHAT was submitted, not
# merely that something was - existing `grep -c SUBMITTED` assertions are
# unaffected by the added suffix.
stty -echo -icanon intr undef min 0 time 3 2>/dev/null
busy="${WM_TEST_BUSY:-0}"
swallow="${WM_TEST_SWALLOW:-0}"
marker="${WM_TEST_MARKER:?WM_TEST_MARKER required}"
buf=""
submitted=0
tick=0

dashes() { _n="$1"; _s=""; _i=0; while [ "$_i" -lt "$_n" ]; do _s="${_s}─"; _i=$((_i+1)); done; printf '%s' "$_s"; }
D33="$(dashes 33)"
D80="$(dashes 80)"

draw() {
  printf '\033[2J\033[H'
  _footer=5
  _extra=0
  [ "$busy" = 1 ] && _extra=$((_extra+1))
  [ -n "${WM_TEST_TRANSCRIPT:-}" ] && _extra=$((_extra+1))
  _pad=$((24 - _footer - _extra))
  _p=0
  while [ "$_p" -lt "$_pad" ]; do printf '\n'; _p=$((_p+1)); done
  if [ "$busy" = 1 ]; then
    tick=$((tick+1))
    printf 'working... tick=%d\n' "$tick"
  fi
  [ -n "${WM_TEST_TRANSCRIPT:-}" ] && printf '%s\n' "$WM_TEST_TRANSCRIPT"
  printf '%s window %s\n' "$D33" "$D33"
  printf '\xe2\x9d\xaf\xc2\xa0%s\n' "$buf"
  printf '%s\n' "$D80"
  printf '/rc\n'
  printf 'bypass permissions status'
}

draw

while :; do
  IFS= read -r -n1 -t "${WM_TEST_TICK:-0.3}" ch
  rc=$?
  if [ "$rc" != 0 ]; then
    [ "$busy" = 1 ] && draw
    continue
  fi
  case "$ch" in
    ""|$'\r'|$'\n')
      printf 'ENTER\n' >> "$marker"
      if [ "$swallow" != 1 ]; then
        submitted=$((submitted+1))
        printf 'SUBMITTED:%d:%s\n' "$submitted" "$buf" >> "$marker"
        buf=""
      fi
      draw
      ;;
    $'\003') buf=""; draw ;;
    *) buf="$buf$ch"; draw ;;
  esac
done
