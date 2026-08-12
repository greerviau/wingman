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
stty -echo -icanon intr undef min 0 time 3 2>/dev/null
marker="${WM_TEST_MARKER:?WM_TEST_MARKER required}"
buf=""
submitted=0

dashes() { _n="$1"; _s=""; _i=0; while [ "$_i" -lt "$_n" ]; do _s="${_s}─"; _i=$((_i+1)); done; printf '%s' "$_s"; }
D80="$(dashes 80)"

draw() {
  printf '\033[2J\033[H'
  _pad=18
  _p=0
  while [ "$_p" -lt "$_pad" ]; do printf '\n'; _p=$((_p+1)); done
  printf '%s\n' "$D80"
  printf '%s\n' "$buf"
  printf '%s\n' "$D80"
  printf '\n'
}

draw

while :; do
  IFS= read -r -n1 -t 0.3 ch
  rc=$?
  if [ "$rc" != 0 ]; then
    continue
  fi
  case "$ch" in
    ""|$'\r'|$'\n')
      printf 'ENTER\n' >> "$marker"
      submitted=$((submitted+1))
      printf 'SUBMITTED:%d:%s\n' "$submitted" "$buf" >> "$marker"
      buf=""
      draw
      ;;
    $'\003') buf=""; draw ;;
    *) buf="$buf$ch"; draw ;;
  esac
done
