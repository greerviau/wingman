#!/usr/bin/env bash
# Regression test for issue #279: BSD sed run under a UTF-8 locale classifies
# the composer anchor's own NBSP (U+00A0, bytes c2 a0) as [[:space:]], so a
# strip built on that POSIX class strips the NBSP right along with any
# trailing padding - after which a genuinely empty composer can never equal
# $WM_COMPOSER_ANCHOR again (see wm_composer_is_empty, bin/lib/common.sh).
#
# No tmux, no fixture, no $WM_TMUX_SESSION: this asserts wm_composer_is_empty
# directly against the byte-exact shapes captured live against a real pane in
# docs/plans/2026-08-07-issue-279-composer-empty-locale-fix-plan.md section 2,
# built here via printf so the test file's own source text carries no raw
# multibyte bytes.
#
# This suite proves the fix is locale-INVARIANT across every locale actually
# available in this CI environment (today just C, C.utf8, POSIX - no BSD
# userland exists here to install). It does not and cannot execute a real BSD
# sed, since none is available in this environment (see the plan's section
# 5.2 for the tradeoff of closing that gap with a macos-latest CI job).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$TEST_REPO/bin/lib/common.sh"

# --- byte-exact composer shapes (plan section 2 / 4 Step 2) ------------------
EMPTY_BARE="$(printf '\xe2\x9d\xaf\xc2\xa0')"                      # anchor+NBSP, no padding (real capture, 2.1)
EMPTY_PADDED="${EMPTY_BARE}                                    "  # anchor+NBSP + trailing ASCII spaces (-J-shaped)
PENDING="${EMPTY_BARE}hello world   "                              # genuinely pending, must stay pending
PENDING_ANCHOR_LOOKALIKE="$(printf '\xe2\x9d\xaf')"                 # anchor glyph alone, NO NBSP - must NOT read as empty

# --- structural guard: the fix must not be a POSIX character class ----------
# A future edit that reintroduces [[:space:]] into wm_composer_is_empty's own
# strip fails this assertion even before any behavioral case below would
# catch it (same "pull the real shipped source, don't duplicate it" technique
# tests/detector-regex-portability.test.sh uses for WM_APIERR_RE).
FN_BODY="$(sed -n '/^wm_composer_is_empty()/,/^}/p' "$TEST_REPO/bin/lib/common.sh")"
if [ -n "$FN_BODY" ]; then
  ok "wm_composer_is_empty extracted a non-empty function body"
else
  fail "wm_composer_is_empty extracted a non-empty function body"
fi
case "$FN_BODY" in
  *'[[:space:]]'*) fail "wm_composer_is_empty must not strip via [[:space:]] (issue #279)" ;;
  *) ok "wm_composer_is_empty does not use [[:space:]]" ;;
esac

# --- behavioral assertions, run once per locale this platform actually has --
# Hardcoding en_US.UTF-8 would make this test silently skip its own point on
# ubuntu-latest, which does not have it installed (see
# tests/detector-regex-portability.test.sh for the same discover-don't-assume
# pattern). LC_ALL=C is always included as a baseline even where locale -a
# omits it explicitly.
_locales="$(locale -a 2>/dev/null)"
case "$_locales" in *"C"*) ;; *) _locales="C
$_locales" ;; esac

for _loc in $_locales; do
  assert_true "wm_composer_is_empty: bare empty composer reads empty (LC_ALL=$_loc)" \
    "LC_ALL='$_loc' wm_composer_is_empty \"\$EMPTY_BARE\""
  assert_true "wm_composer_is_empty: padded empty composer reads empty (LC_ALL=$_loc)" \
    "LC_ALL='$_loc' wm_composer_is_empty \"\$EMPTY_PADDED\""
  assert_false "wm_composer_is_empty: pending composer stays pending (LC_ALL=$_loc)" \
    "LC_ALL='$_loc' wm_composer_is_empty \"\$PENDING\""
  assert_false "wm_composer_is_empty: anchor without NBSP is not empty (LC_ALL=$_loc)" \
    "LC_ALL='$_loc' wm_composer_is_empty \"\$PENDING_ANCHOR_LOOKALIKE\""
done

test_summary
