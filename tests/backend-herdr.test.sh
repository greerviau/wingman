#!/usr/bin/env bash
# Herdr adapter conformance tests use a fake CLI so the default suite never
# depends on a user's running session.
set -u
TEST_REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$TEST_REPO/tests/lib.sh"

fake="$(mktemp -d "${TMPDIR:-/tmp}/wm-herdr.XXXXXX")"
wm_on_exit 'rm -rf "$fake"'
log="$fake/commands"
cat > "$fake/herdr" <<'EOF'
#!/usr/bin/env bash
printf 'HERDR_SESSION=%s %s\n' "${HERDR_SESSION:-}" "$*" >> "$HERDR_LOG"
case "$1 $2" in
  "status --json") printf '%s\n' '{"client":{"protocol":14,"version":"0.7.1"},"server":{"running":true}}' ;;
  "workspace list") printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"ws1","label":"wingman"}]}}' ;;
  "workspace create") printf '%s\n' '{"result":{"workspace":{"workspace_id":"ws-new"}}}' ;;
  "tab list") printf '%s\n' '{"result":{"tabs":[{"tab_id":"tab1","label":"wm-herdr"}]}}' ;;
  "tab create") printf '%s\n' '{"result":{"tab":{"tab_id":"tab2"},"root_pane":{"pane_id":"p:2"}}}' ;;
  "pane list") printf '%s\n' '{"result":{"panes":[{"tab_id":"tab1","pane_id":"p:1"}]}}' ;;
  "pane read")
    if grep -q 'send-keys' "$HERDR_LOG"; then printf 'after\n'; else printf 'before\n'; fi ;;
  "pane get") printf '%s\n' '{"result":{"pane":{"pane_id":"p:2"}}}' ;;
  "agent get") printf '%s\n' '{"result":{"agent":{"agent_status":"working"}}}' ;;
  "pane run"|"pane send-text"|"pane send-keys"|"pane close") : ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$fake/herdr"
PATH="$fake:$PATH" HERDR_LOG="$log" WM_BACKEND_HERDR_WORKSPACE_LABEL=wingman \
  . "$TEST_REPO/bin/lib/backends/herdr.sh"

export PATH="$fake:$PATH" HERDR_LOG="$log"

assert_true "protocol 14 passes" 'wm_backend_herdr_version_check >/dev/null 2>&1'
assert_true "target parser accepts pane ids containing colons" 'wm_backend_herdr_parse_target "named:p:2" && [ "$WM_BACKEND_HERDR_SESSION" = named ] && [ "$WM_BACKEND_HERDR_PANE" = p:2 ]'
assert_eq "capture returns requested tail" "$(wm_backend_herdr_capture named:p:2 1)" "before"
assert_eq "native working state maps to busy" "$(wm_backend_herdr_busy_state named:p:2)" busy
assert_eq "endpoint read reports alive" "$(wm_backend_herdr_endpoint_state named:p:2)" alive
assert_true "supported keys normalize" '[ "$(wm_backend_herdr_normalize_key C-c)" = ctrl+c ] && [ "$(wm_backend_herdr_normalize_key Escape)" = escape ]'
assert_false "unsupported keys fail before CLI call" 'wm_backend_herdr_normalize_key Tab'
verdict="$(wm_backend_herdr_send_text_submit named:p:2 hello 2 0 0)"
assert_eq "literal text and Enter submit separately" "$verdict" empty
assert_true "close targets the exact pane" 'wm_backend_herdr_close named:p:2'
assert_contains "named session is passed to every command" "$(cat "$log")" "HERDR_SESSION=named"
assert_contains "capture over-fetches" "$(cat "$log")" "pane read p:2 --source recent --lines 200"

test_summary
