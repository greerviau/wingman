#!/usr/bin/env bash
# E2E: docs/guards.md names every hook script in bin/lib/user-hooks.json
# (issue #241) - the third list (manifest, bin/doctor, docs) that used to
# drift independently; cheap to check, and stops it from drifting again.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

DOC="$TEST_REPO/docs/guards.md"
MANIFEST="$TEST_REPO/bin/lib/user-hooks.json"

scripts="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$MANIFEST'))
seen = set()
for g in d['groups']:
    for h in g['hooks']:
        seen.add(h['script'].rsplit('/', 1)[-1])
for s in sorted(seen):
    print(s)
")"

while IFS= read -r script; do
  [ -n "$script" ] || continue
  assert_contains "docs/guards.md mentions $script" "$(cat "$DOC")" "$script"
done <<EOF
$scripts
EOF

test_summary
