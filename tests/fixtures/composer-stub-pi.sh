#!/usr/bin/env bash
# Emulates pi's own composer shape, hands-on captured against the real pi
# v0.84.1 binary (issue #25 stage 4, PR #348): content rows strictly between
# two solid horizontal rule lines (U+2500 "─", repeated well past
# WM_COMPOSER_RULE_MIN), no leading glyph and no NBSP anchor on the content
# row - unlike tests/fixtures/composer-stub.sh's claude shape (an embedded
# "window" label on the top rule, a "-"+NBSP anchor on the content row),
# which this file deliberately does NOT reuse: the whole point of the
# regression this drives is that pi's rule character byte-matches claude's
# WM_COMPOSER_RULE_RE by coincidence while its content row never matches
# claude's WM_COMPOSER_ANCHOR, so a real in-place redraw of pi's OWN
# (glyph-less) shape is what actually exercises the failure mode, not a
# reskinned copy of claude's stub.
#
# WM_TEST_MARKER (required): ENTER/SUBMITTED lines go to this side-channel
# file, never the pane itself, matching composer-stub.sh's own convention.
#
# WM_TEST_BUSY=0/1 (round-2 review, PR #348): an independent "working...
# tick=N" line, redrawn on its own clock ABOVE the top rule - never between
# the rules, matching composer-stub.sh's own placement - so a whole-pane
# checksum changes on its own regardless of whether the composer itself was
# ever touched. This is what distinguishes a genuine composer-region confirm
# from the pre-#188 whole-pane-checksum fallback: only the former reads the
# COMPOSER's own extracted content specifically, so a live-but-busy pane
# that never actually clears the composer must never falsely confirm.
# WM_TEST_SWALLOW=0/1: whether Enter clears the composer (a registered
# submit) or is dropped (composer stays pending, nothing submitted) -
# mirrors composer-stub.sh's own knob of the same name.
# WM_TEST_TICK: the busy repaint's own clock, seconds (default 0.3).
stty -echo -icanon intr undef min 0 time 3 2>/dev/null
marker="${WM_TEST_MARKER:?WM_TEST_MARKER required}"
busy="${WM_TEST_BUSY:-0}"
swallow="${WM_TEST_SWALLOW:-0}"
buf=""
submitted=0
tick=0

dashes() { _n="$1"; _s=""; _i=0; while [ "$_i" -lt "$_n" ]; do _s="${_s}─"; _i=$((_i+1)); done; printf '%s' "$_s"; }
D80="$(dashes 80)"

# Builds the whole frame into one variable and emits it with a single
# printf (round-3 review, PR #348), rather than the ~6 separate printfs the
# first version of this file used: under real load, a reader (wm_tmux_
# pane_text) could catch the pane between the leading clear/home escape and
# the frame content actually landing, observing a cleared-but-not-yet-
# redrawn screen - composer mode then finds no rule lines, falls through to
# the whole-pane-checksum path, and confirms on the independent busy tick
# alone. Reproduced under 12-way concurrency (round-3 review), traced to
# exactly this non-atomicity, not to anything in the production code. One
# write call cannot itself be observed half-done the same way.
draw() {
  _pad=18
  [ "$busy" = 1 ] && _pad=$((_pad-1))
  _frame=$'\033[2J\033[H'
  _p=0
  while [ "$_p" -lt "$_pad" ]; do _frame="$_frame"$'\n'; _p=$((_p+1)); done
  if [ "$busy" = 1 ]; then
    tick=$((tick+1))
    _frame="$_frame""working... tick=$tick"$'\n'
  fi
  _frame="$_frame$D80"$'\n'
  _frame="$_frame$buf"$'\n'
  _frame="$_frame$D80"$'\n\n'
  printf '%s' "$_frame"
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
