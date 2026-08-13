#!/usr/bin/env bash
# Emulates opencode's own composer shape, hands-on captured against real
# opencode v1.18.17 (issue #25 stage 5, PR #350): a heavy "┃" (U+2503) left
# bar prefixing each row (the idle hint, blank rows, a mode/model footer
# line), closed at the bottom by a row starting "╹" (U+2579) followed by
# "▀" (U+2580, upper half block) repeated - never wingman's own "─"
# (U+2500) rule character wm_composer_text_in's WM_COMPOSER_RULE_RE looks
# for, so a real opencode pane's composer region is structurally
# unrecognizable to wingman's rule-line extraction and every send falls
# through to the whole-pane-checksum confirm path.
#
# WM_TEST_MARKER (required): ENTER/SUBMITTED lines go to this side-channel
# file, never the pane itself, matching composer-stub-pi.sh's own
# convention. Single-write draw() (issue #25 PR #348 round-3 review's own
# atomicity lesson, applied here from the start rather than retrofitted).
stty -echo -icanon intr undef min 0 time 3 2>/dev/null
marker="${WM_TEST_MARKER:?WM_TEST_MARKER required}"
buf=""
submitted=0

dashes() { _ch="$1"; _n="$2"; _s=""; _i=0; while [ "$_i" -lt "$_n" ]; do _s="${_s}${_ch}"; _i=$((_i+1)); done; printf '%s' "$_s"; }
BOTTOM="╹$(dashes '▀' 78)"

draw() {
  _frame=$'\033[2J\033[H'
  _p=0
  while [ "$_p" -lt 16 ]; do _frame="$_frame"$'\n'; _p=$((_p+1)); done
  _frame="$_frame┃"$'\n'
  _frame="$_frame┃  $buf"$'\n'
  _frame="$_frame┃"$'\n'
  _frame="$_frame┃  Build · Big Pickle OpenCode Zen"$'\n'
  _frame="$_frame$BOTTOM"$'\n'
  printf '%s' "$_frame"
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
