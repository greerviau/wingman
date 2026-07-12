#!/usr/bin/env bash
# artifact-scan.sh - condition C's deterministic pre-publish security gate
# (design: docs/plans/2026-07-12-remote-control-visibility-and-auto-reconnect-
# design.md, ask 3a). Run against a crew deliverable BEFORE ever calling the
# Artifact tool on it - this is a check on whether THIS REPO'S OWN internal
# information is safe to host externally (secrets, infra details), a different
# question from the Artifact tool's own built-in refusal categories (which guard
# against misusing the hosting mechanism itself, e.g. phishing).
#
# Usage:
#   artifact-scan.sh <file>
# Prints one verdict line to stdout and exits accordingly:
#   pass                       - clean, safe to publish
#   pass-soft:<reason>         - publish is still allowed, but call the reason
#                                 out to the pilot alongside the Artifact link
#   fail:<reason>               - do not publish; report the local path only
# Exit 0 for pass/pass-soft, 1 for fail - so a caller can gate on exit status
# alone and read the verdict line for the human-facing reason.
#
# Two things required together (location allowlist is coarse defense-in-depth
# only, never sufficient alone; the content scan is the actual decision):
#   1. Location allowlist: only files under this repo's known crew-deliverable
#      directories are even candidates.
#   2. Content scan: gitleaks (a maintained secret-scanning tool, not a
#      hand-rolled regex list that would silently rot as secret formats change)
#      for credentials, plus a small purpose-built regex check for RFC1918
#      private IPv4 ranges and obviously-internal hostname suffixes, plus a
#      soft size/proportion heuristic for a wholesale code dump (as opposed to
#      a design doc's routine short illustrative excerpt).
#
# gitleaks missing is treated as a hard fail, not a silent skip: condition C
# must genuinely pass, and an unscannable file cannot be said to have passed -
# the same conservative-default posture ask 3's condition B already takes
# ("unanswered or ambiguous defaults to not publish").
# bash-3.2-safe.
set -u
. "$(dirname "$0")/common.sh"

FILE="${1:-}"
[ -n "$FILE" ] || { echo "fail:usage: artifact-scan.sh <file>"; exit 1; }
[ -f "$FILE" ] || { echo "fail:no such file: $FILE"; exit 1; }

# --- 1. location allowlist (coarse, cheap, defense-in-depth only) ------------
# Only a crew-deliverable directory is even a candidate, regardless of content -
# a file the crew happened to read elsewhere is never auto-published.
ALLOWLIST_RE="${WM_ARTIFACT_SCAN_ALLOWLIST_RE:-/docs/(plans|analysis|tickets)/}"
_abs="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")"
printf '%s' "$_abs" | grep -qE "$ALLOWLIST_RE" || { echo "fail:not under a crew-deliverable directory (docs/plans, docs/analysis, docs/tickets)"; exit 1; }

# --- 2a. secrets/credentials: gitleaks (maintained tool, not a regex list) ---
if wm_have gitleaks; then
  # --source takes the target file directly (verified: gitleaks scans exactly
  # that file, not its containing directory), so a sibling file's content never
  # affects this file's own verdict.
  if ! gitleaks detect --no-git --source "$_abs" \
        --report-format json --report-path /dev/null \
        --no-banner --exit-code 1 2>/dev/null; then
    echo "fail:matches a credential/secret pattern (gitleaks)"; exit 1
  fi
else
  echo "fail:gitleaks not installed - cannot verify the file is free of secrets (run bin/doctor)"; exit 1
fi

# --- 2b. internal infra identifiers: RFC1918 + internal hostname suffixes ----
# Built as a literal (single-quoted, not a ${VAR:-default} expansion): the
# regex's own literal `}` quantifiers would otherwise terminate a bash
# parameter-expansion default early (confirmed: `${FOO:-a{1,3}b}` evaluates to
# `a{1,3b}`, silently truncating at the first unescaped `}`).
if [ -n "${WM_ARTIFACT_SCAN_INFRA_RE:-}" ]; then
  INFRA_RE="$WM_ARTIFACT_SCAN_INFRA_RE"
else
  INFRA_RE='\b10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b|\b172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]{1,3}\.[0-9]{1,3}\b|\b192\.168\.[0-9]{1,3}\.[0-9]{1,3}\b|[A-Za-z0-9.-]+\.(internal|corp|local)\b'
fi
if grep -qE "$INFRA_RE" "$FILE"; then
  echo "fail:matches an internal IP/hostname pattern (RFC1918 address or .internal/.corp/.local hostname)"; exit 1
fi

# --- 2c. proprietary-code-dump heuristic: soft, not a hard block -------------
# A design doc legitimately and routinely quotes short code excerpts to
# illustrate a point. Flag (never block) when a single fenced code block is
# unusually large, or code blocks make up an unusually large share of the
# document - the shape of a wholesale dump rather than an illustrative excerpt.
CODE_BLOCK_MAX_LINES="${WM_ARTIFACT_SCAN_BLOCK_MAX:-40}"
CODE_SHARE_MAX_PCT="${WM_ARTIFACT_SCAN_SHARE_MAX_PCT:-40}"

total_lines="$(grep -c '' "$FILE" 2>/dev/null || echo 0)"
code_lines=0
max_block=0
in_block=0
block_len=0
while IFS= read -r _line; do
  case "$_line" in
    '```'*)
      if [ "$in_block" = 1 ]; then
        in_block=0
        [ "$block_len" -gt "$max_block" ] && max_block="$block_len"
        code_lines=$((code_lines + block_len))
        block_len=0
      else
        in_block=1
        block_len=0
      fi
      ;;
    *)
      [ "$in_block" = 1 ] && block_len=$((block_len + 1))
      ;;
  esac
done < "$FILE"

soft_reason=""
if [ "$max_block" -gt "$CODE_BLOCK_MAX_LINES" ]; then
  soft_reason="a code block runs $max_block lines (over the ${CODE_BLOCK_MAX_LINES}-line illustrative-excerpt guideline)"
elif [ "$total_lines" -gt 0 ]; then
  share_pct=$(( code_lines * 100 / total_lines ))
  if [ "$share_pct" -ge "$CODE_SHARE_MAX_PCT" ]; then
    soft_reason="code blocks make up ${share_pct}% of the document (over the ${CODE_SHARE_MAX_PCT}% guideline)"
  fi
fi

if [ -n "$soft_reason" ]; then
  echo "pass-soft:$soft_reason - looks more like a wholesale dump than an illustrative excerpt"
  exit 0
fi

echo "pass"
exit 0
