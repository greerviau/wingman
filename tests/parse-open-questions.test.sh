#!/usr/bin/env bash
# E2E: bin/lib/parse-open-questions.py, the structured open-questions parser
# (design: docs/plans/2026-07-14-structured-open-questions-convention.md).
# Proves the fence extraction, the found:false/true/error shapes, and each
# schema-validation rule (recommended count, option count, duplicate ids,
# malformed JSON, an 'open' question misusing 'options'). Mirrors
# tests/artifact-scan.test.sh's structure: fixtures under a temp dir,
# assert_eq/assert_contains on stdout and exit code.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SCRIPT="$TEST_REPO/bin/lib/parse-open-questions.py"
run() { uv run --no-project --quiet "$SCRIPT" "$@"; }

FIXDIR="$(wm_mktemp_dir)"

# --- 1. no fence -> found:false, exit 0 ---------------------------------------
NOFENCE="$FIXDIR/no-fence.md"
printf '# Plan\nJust prose, no open-questions block.\n' > "$NOFENCE"
out="$(run "$NOFENCE")"; rc=$?
assert_eq "no fence found is not an error" "$rc" "0"
assert_eq "the verdict is found:false" "$out" '{"found": false}'

# --- 2. a valid block with one choice + one open question ---------------------
VALID="$FIXDIR/valid.md"
cat > "$VALID" <<'EOF'
## Open Questions

```wingman-questions
{
  "questions": [
    {
      "id": "cache-ttl",
      "type": "choice",
      "question": "Should the plan cache TTL be 5 minutes or 15 minutes?",
      "options": [
        { "label": "5 minutes", "recommended": true, "detail": "Matches existing TTL." },
        { "label": "15 minutes", "detail": "Fewer cache misses." }
      ],
      "free_text": true
    },
    {
      "id": "launch-date",
      "type": "open",
      "question": "What date should this roll out?",
      "hint": "a target date or milestone"
    }
  ]
}
```
EOF
out="$(run "$VALID")"; rc=$?
assert_eq "a valid block parses cleanly" "$rc" "0"
assert_contains "found:true is in the output" "$out" '"found": true'
assert_contains "the choice question survives intact" "$out" '"id": "cache-ttl"'
assert_contains "the open question survives intact" "$out" '"id": "launch-date"'
assert_contains "the recommended option is preserved" "$out" '"recommended": true'

# --- 3. a choice question with zero recommended options -----------------------
ZERO_REC="$FIXDIR/zero-recommended.md"
cat > "$ZERO_REC" <<'EOF'
```wingman-questions
{"questions": [{"id": "q1", "type": "choice", "question": "Pick one?",
  "options": [{"label": "A", "detail": "a"}, {"label": "B", "detail": "b"}]}]}
```
EOF
out="$(run "$ZERO_REC")"; rc=$?
assert_eq "zero recommended options is an error" "$rc" "1"
assert_contains "the reason names the recommended-count rule" "$out" "recommended"

# --- 4. a choice question with two recommended options ------------------------
TWO_REC="$FIXDIR/two-recommended.md"
cat > "$TWO_REC" <<'EOF'
```wingman-questions
{"questions": [{"id": "q1", "type": "choice", "question": "Pick one?",
  "options": [{"label": "A", "recommended": true, "detail": "a"},
              {"label": "B", "recommended": true, "detail": "b"}]}]}
```
EOF
out="$(run "$TWO_REC")"; rc=$?
assert_eq "two recommended options is an error" "$rc" "1"
assert_contains "the reason names the recommended-count rule" "$out" "recommended"

# --- 5. option count outside 2-4 -----------------------------------------------
ONE_OPT="$FIXDIR/one-option.md"
cat > "$ONE_OPT" <<'EOF'
```wingman-questions
{"questions": [{"id": "q1", "type": "choice", "question": "Pick one?",
  "options": [{"label": "A", "recommended": true, "detail": "a"}]}]}
```
EOF
out="$(run "$ONE_OPT")"; rc=$?
assert_eq "a single option is an error" "$rc" "1"
assert_contains "the reason names the option-count rule" "$out" "2-4 options"

FIVE_OPT="$FIXDIR/five-options.md"
cat > "$FIVE_OPT" <<'EOF'
```wingman-questions
{"questions": [{"id": "q1", "type": "choice", "question": "Pick one?",
  "options": [{"label": "A", "recommended": true, "detail": "a"},
              {"label": "B", "detail": "b"}, {"label": "C", "detail": "c"},
              {"label": "D", "detail": "d"}, {"label": "E", "detail": "e"}]}]}
```
EOF
out="$(run "$FIVE_OPT")"; rc=$?
assert_eq "five options is an error" "$rc" "1"
assert_contains "the reason names the option-count rule" "$out" "2-4 options"

# --- 6. duplicate ids -----------------------------------------------------------
DUP_ID="$FIXDIR/dup-id.md"
cat > "$DUP_ID" <<'EOF'
```wingman-questions
{"questions": [
  {"id": "q1", "type": "open", "question": "First?"},
  {"id": "q1", "type": "open", "question": "Second?"}
]}
```
EOF
out="$(run "$DUP_ID")"; rc=$?
assert_eq "a duplicate id is an error" "$rc" "1"
assert_contains "the reason names the duplicate-id rule" "$out" "duplicate question id"

# --- 7. malformed JSON ----------------------------------------------------------
BAD_JSON="$FIXDIR/bad-json.md"
cat > "$BAD_JSON" <<'EOF'
```wingman-questions
{"questions": [ this is not valid json ] }
```
EOF
out="$(run "$BAD_JSON")"; rc=$?
assert_eq "malformed JSON is an error" "$rc" "1"
assert_contains "the reason names the JSON parse failure" "$out" "malformed JSON"

# --- 8. an open question with an options field is a schema violation ----------
OPEN_WITH_OPTS="$FIXDIR/open-with-options.md"
cat > "$OPEN_WITH_OPTS" <<'EOF'
```wingman-questions
{"questions": [{"id": "q1", "type": "open", "question": "What date?",
  "options": [{"label": "A", "recommended": true, "detail": "a"}, {"label": "B", "detail": "b"}]}]}
```
EOF
out="$(run "$OPEN_WITH_OPTS")"; rc=$?
assert_eq "an open question with options is an error" "$rc" "1"
assert_contains "the reason names the schema misuse" "$out" "must not have an 'options' field"

# --- 9. more than 4 choice questions still returns found:true, all of them ----
MANY="$FIXDIR/many-choices.md"
cat > "$MANY" <<'EOF'
```wingman-questions
{"questions": [
  {"id": "q1", "type": "choice", "question": "Pick 1?", "options": [{"label": "A", "recommended": true, "detail": "a"}, {"label": "B", "detail": "b"}]},
  {"id": "q2", "type": "choice", "question": "Pick 2?", "options": [{"label": "A", "recommended": true, "detail": "a"}, {"label": "B", "detail": "b"}]},
  {"id": "q3", "type": "choice", "question": "Pick 3?", "options": [{"label": "A", "recommended": true, "detail": "a"}, {"label": "B", "detail": "b"}]},
  {"id": "q4", "type": "choice", "question": "Pick 4?", "options": [{"label": "A", "recommended": true, "detail": "a"}, {"label": "B", "detail": "b"}]},
  {"id": "q5", "type": "choice", "question": "Pick 5?", "options": [{"label": "A", "recommended": true, "detail": "a"}, {"label": "B", "detail": "b"}]}
]}
```
EOF
out="$(run "$MANY")"; rc=$?
assert_eq "more than 4 choice questions is not an error - batching is wingman's job" "$rc" "0"
assert_contains "found:true" "$out" '"found": true'
for id in q1 q2 q3 q4 q5; do
  assert_contains "question $id is present in the output" "$out" "\"id\": \"$id\""
done

rm -rf "$FIXDIR"
test_summary
