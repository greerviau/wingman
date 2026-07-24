#!/usr/bin/env bash
# E2E: the ask store's locked lifecycle (robustness audit findings 1-2).
# ask-reply and ask-resolve now run their whole read-check-write under
# with_locked(ask/<req>.json), and a late reply to an already-timed-out
# request is recorded (late: true) instead of discarded - the delegate spent
# a turn authoring the answer; refusing it left no recovery path.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# --- a late reply after a timeout resolve is recorded, marked late -----------
test_new_home
wm_state ask-new --id ask-late1 --from "" --to dev1 --question "which port?" >/dev/null
out="$(wm_state ask-resolve --id ask-late1 --status timeout --note "no reply in 300s")"
assert_eq "the resolve lands (prints the resulting status)" "$out" "timeout"

out="$(wm_state ask-reply --id ask-late1 --responder dev1 --answer "port 8080" 2>&1)"
assert_contains "a late reply is accepted, not refused" "$out" "ask-late1"
assert_contains "the late reply's output says to surface it over the ordinary channel" "$out" "late"
rec="$(wm_state ask-get --id ask-late1)"
assert_contains "the record is answered" "$rec" '"status": "answered"'
assert_contains "the answer survived" "$rec" "port 8080"
assert_contains "the record is marked late" "$rec" '"late": true'

# --- a resolve NEVER clobbers an already-answered record ---------------------
test_new_home
wm_state ask-new --id ask-cas1 --from "" --to dev1 --question "q" >/dev/null
wm_state ask-reply --id ask-cas1 --responder dev1 --answer "the answer" >/dev/null
out="$(wm_state ask-resolve --id ask-cas1 --status timeout)"
assert_eq "resolve against answered is a no-op printing the real status" "$out" "answered"
rec="$(wm_state ask-get --id ask-cas1)"
assert_contains "the answer is untouched" "$rec" "the answer"

# --- a reply to an undeliverable request is still refused, with guidance -----
test_new_home
wm_state ask-new --id ask-und1 --from lead1 --to dev1 --question "q" >/dev/null
wm_state ask-resolve --id ask-und1 --status undeliverable >/dev/null
out="$(wm_state ask-reply --id ask-und1 --responder dev1 --answer "too late" 2>&1)" && rc=0 || rc=$?
assert_true "a reply to an undeliverable request exits nonzero" "[ $rc -ne 0 ]"
assert_contains "the refusal names the ordinary-channel fallback" "$out" "crew-say"
assert_contains "the refusal names the asker" "$out" "lead1"

# --- the anti-spoof check still holds on the late path -----------------------
test_new_home
wm_state ask-new --id ask-spoof1 --from "" --to dev1 --question "q" >/dev/null
wm_state ask-resolve --id ask-spoof1 --status timeout >/dev/null
out="$(wm_state ask-reply --id ask-spoof1 --responder dev2 --answer "not mine" 2>&1)" && rc=0 || rc=$?
assert_true "a non-addressed responder is refused even on the late path" "[ $rc -ne 0 ]"
assert_contains "the refusal names the anti-spoof rule" "$out" "not the addressed delegate"
rec="$(wm_state ask-get --id ask-spoof1)"
assert_contains "the record stays timeout" "$rec" '"status": "timeout"'

# --- concurrent reply vs resolve: the answer always survives -----------------
# The genuine race the lock closes: a resolve that read `pending` must not
# write a stale `timeout` record over a reply that lands in the same instant.
# Both processes are launched together repeatedly; whatever the interleaving,
# the terminal record must either be answered (reply won or landed late) -
# and when it is, the answer text must be intact.
test_new_home
i=0
while [ "$i" -lt 5 ]; do
  req="ask-race$i"
  wm_state ask-new --id "$req" --from "" --to dev1 --question "q" >/dev/null
  wm_state ask-resolve --id "$req" --status timeout >/dev/null 2>&1 &
  _p1=$!
  wm_state ask-reply --id "$req" --responder dev1 --answer "racing answer" >/dev/null 2>&1 &
  _p2=$!
  wait "$_p1" "$_p2" 2>/dev/null
  rec="$(wm_state ask-get --id "$req")"
  case "$rec" in
    *'"status": "answered"'*)
      case "$rec" in
        *"racing answer"*) ok "race $i: answered record carries the intact answer" ;;
        *) fail "race $i: answered record lost the answer text" ;;
      esac ;;
    *'"status": "timeout"'*)
      # Both processes were waited on. If the reply ran second it lands via
      # the late path (timeout -> answered); if it ran first, the resolve
      # no-ops against answered. Either way a terminal `timeout` means the
      # resolve overwrote a landed reply - exactly the clobber the lock closes.
      fail "race $i: resolve clobbered the reply (answer destroyed)" ;;
    *) fail "race $i: unexpected terminal record: $rec" ;;
  esac
  i=$((i+1))
done

test_summary
