#!/usr/bin/env bash
# Optional isolated Herdr smoke test. It uses a private named session and never
# stops the ambient default session.
set -u
[ "${WM_RUN_HERDR_SMOKE:-0}" = 1 ] || { echo 'skip: set WM_RUN_HERDR_SMOKE=1 to run'; exit 0; }
command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr is unavailable'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq is unavailable'; exit 0; }
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/tests/lib.sh"
. "$root/bin/lib/common.sh"
. "$root/bin/lib/backends/herdr.sh"
session="wm-smoke-$$"
export HERDR_SESSION="$session"
wm_on_exit 'status="$(HERDR_SESSION="$session" herdr status --json 2>/dev/null || true)"; [ "$(printf "%s" "$status" | jq -r ".server.session // .server.name // empty" 2>/dev/null)" = "$session" ] && HERDR_SESSION="$session" herdr server stop >/dev/null 2>&1 || true'
wm_backend_herdr_version_check || exit 1
wm_backend_herdr_server_ensure "$session" || exit 1
container="$(wm_backend_herdr_container_ensure "$root")" || exit 1
fields="$(wm_backend_herdr_create_task "$container" wm-smoke "$root")" || exit 1
pane="${fields#* }"
target="$session:$pane"
wm_backend_herdr_endpoint_state "$target" | grep -qx alive || exit 1
wm_backend_herdr_capture "$target" 5 >/dev/null || exit 1
wm_backend_herdr_close "$target" || exit 1
echo 'ok: isolated Herdr lifecycle smoke test'
