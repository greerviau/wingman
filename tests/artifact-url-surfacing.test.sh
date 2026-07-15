#!/usr/bin/env bash
# E2E: `crew-set` auto-derives `artifact_url` from the durable Artifact-publish
# marker (hooks/artifact-publish-tracker.sh writes it; hooks/artifact-link-guard.sh
# already trusts it to gate the call) instead of relying on a crew member to
# hand-type the URL into free text wingman never reads (issue #110). No real
# crew/tmux/claude needed - cmd_crew_set is exercised directly through wm_state.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

wm_realpath() { uv run --no-project --quiet python -c "
import os, sys
print(os.path.realpath(sys.argv[1]))" "$1"; }

sha_of() { uv run --no-project --quiet python -c "
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest())" "$1"; }

# write_marker <sid> <realpath> <status> [<url>] [<sha256>]
# Hand-builds a marker entry matching hooks/artifact-publish-tracker.sh's own
# shape (see tests/artifact-publish-tracker.test.sh), so this file can test
# cmd_crew_set's consumption of it without going through the hook itself.
write_marker() {
  uv run --no-project --quiet python -c "
import json, os, sys
sid, path, status, url, sha = sys.argv[1:6]
d = os.path.join(os.environ['WINGMAN_HOME'], 'artifact-markers')
os.makedirs(d, exist_ok=True)
mpath = os.path.join(d, sid + '.json')
try:
    with open(mpath) as fh:
        store = json.load(fh)
except (OSError, ValueError):
    store = {}
entry = {'status': status}
if url:
    entry['url'] = url
if sha:
    entry['sha256'] = sha
store[path] = entry
with open(mpath, 'w') as fh:
    json.dump(store, fh)
" "$1" "$2" "$3" "${4:-}" "${5:-}"
}

test_new_home
WORK="$(wm_mktemp_dir)"

# --- 1. happy path: a published, sha-matched marker surfaces artifact_url ------
DOC1="$WORK/plan1.md"
printf '# plan one\n' > "$DOC1"
DOC1_REAL="$(wm_realpath "$DOC1")"
wm_state crew-add --id m1 --type developer --objective x --repo /tmp --window wm-m1 --session-id sess-m1 >/dev/null
write_marker sess-m1 "$DOC1_REAL" published "https://claude.ai/code/artifact/m1" "$(sha_of "$DOC1")"
wm_state crew-set --id m1 --status review --artifact "$DOC1" --summary "plan ready" >/dev/null

assert_contains "the happy-path marker's URL lands in crew-list --json" \
  "$(wm_state crew-list --json)" '"artifact_url": "https://claude.ai/code/artifact/m1"'
assert_contains "the board's Active table carries the URL" \
  "$(awk '/## Active/{f=1} /## Closed/{f=0} f' "$WINGMAN_HOME/board.md")" "https://claude.ai/code/artifact/m1"

# --- 2. a stale marker (edited after publish, never republished) yields nothing -
DOC2="$WORK/plan2.md"
printf '# plan two\n' > "$DOC2"
DOC2_REAL="$(wm_realpath "$DOC2")"
wm_state crew-add --id m2 --type developer --objective x --repo /tmp --window wm-m2 --session-id sess-m2 >/dev/null
write_marker sess-m2 "$DOC2_REAL" published "https://claude.ai/code/artifact/m2" "$(sha_of "$DOC2")"
printf '# plan two, edited\n' >> "$DOC2"   # invalidates the recorded sha256
wm_state crew-set --id m2 --status review --artifact "$DOC2" --summary "plan ready" >/dev/null
assert_contains "a stale (sha-mismatched) marker leaves artifact_url unset" \
  "$(wm_state crew-get --id m2)" '"artifact_url": null'

# --- 3. no marker at all leaves artifact_url unset (local-only case) -----------
DOC3="$WORK/plan3.md"
printf '# plan three\n' > "$DOC3"
wm_state crew-add --id m3 --type developer --objective x --repo /tmp --window wm-m3 --session-id sess-m3 >/dev/null
wm_state crew-set --id m3 --status review --artifact "$DOC3" --summary "plan ready" >/dev/null
assert_contains "no marker at all leaves artifact_url unset" \
  "$(wm_state crew-get --id m3)" '"artifact_url": null'

# --- 4. an explicit --artifact-url wins over a valid marker --------------------
DOC4="$WORK/plan4.md"
printf '# plan four\n' > "$DOC4"
DOC4_REAL="$(wm_realpath "$DOC4")"
wm_state crew-add --id m4 --type developer --objective x --repo /tmp --window wm-m4 --session-id sess-m4 >/dev/null
write_marker sess-m4 "$DOC4_REAL" published "https://claude.ai/code/artifact/m4-auto" "$(sha_of "$DOC4")"
wm_state crew-set --id m4 --status review --artifact "$DOC4" --artifact-url "https://example.invalid/manual" --summary "plan ready" >/dev/null
assert_contains "an explicit --artifact-url overrides the marker's own URL" \
  "$(wm_state crew-get --id m4)" '"artifact_url": "https://example.invalid/manual"'

# --- 5. an explicit clear reverts artifact_url to unset ------------------------
wm_state crew-set --id m4 --artifact-url "" >/dev/null
assert_contains "an explicit --artifact-url \"\" clears a previously-set value" \
  "$(wm_state crew-get --id m4)" '"artifact_url": null'

# --- 6. needs-attention prefers artifact_url over the local artifact path ------
DOC6="$WORK/plan6.md"
printf '# plan six\n' > "$DOC6"
DOC6_REAL="$(wm_realpath "$DOC6")"
wm_state crew-add --id m6 --type developer --objective x --repo /tmp --window wm-m6 --session-id sess-m6 >/dev/null
write_marker sess-m6 "$DOC6_REAL" published "https://claude.ai/code/artifact/m6" "$(sha_of "$DOC6")"
wm_state crew-set --id m6 --status review --artifact "$DOC6" --summary "plan ready" >/dev/null
na="$(wm_state needs-attention)"
row="$(printf '%s\n' "$na" | grep '^m6	')"
assert_contains "needs-attention's note is the hosted URL, not the local path" "$row" "https://claude.ai/code/artifact/m6"
assert_not_contains "needs-attention's note is not the local artifact path once a URL exists" "$row" "$DOC6"

# --- 7. the roster mirror survives a status-file loss --------------------------
rm -f "$WINGMAN_HOME/crew/m6.json"
assert_contains "crew.json alone (status file removed) still carries the mirrored artifact_url" \
  "$(wm_state crew-list --json)" '"artifact_url": "https://claude.ai/code/artifact/m6"'

# --- 8. rendering coverage across every human-readable surface, plus a Closed row
assert_contains "render_roster_text shows the artifact-url line" \
  "$(wm_state crew-list)" "artifact-url: https://claude.ai/code/artifact/m1"
assert_contains "render_tree_text shows the artifact-url line" \
  "$(wm_state crew-list --tree)" "artifact-url: https://claude.ai/code/artifact/m1"

wm_state crew-set --id m1 --status done --summary "shipped" >/dev/null
assert_contains "the board's Closed table also carries the URL" \
  "$(awk '/## Closed/{f=1} f' "$WINGMAN_HOME/board.md")" "https://claude.ai/code/artifact/m1"

test_summary
